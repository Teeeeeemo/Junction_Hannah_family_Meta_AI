import Foundation
import Combine
import UIKit
import MWDATCore
import MWDATCamera
import MWDATMockDevice

/// UIImage is immutable here: it crosses to the encoder without modification.
private struct ImmutableFrame: @unchecked Sendable { let image: UIImage }

@MainActor
final class GlassCameraModel: ObservableObject {
  @Published var status = "Register with Meta AI to connect the glasses."
  @Published var error = ""
  @Published var preview: UIImage?
  @Published var guide: MuseumGuide?
  @Published var frameCount = 0
  @Published var backendReady = false
  @Published var registered = false
  @Published var streaming = false
  @Published var recognizing = false
  @Published var connecting = false
  @Published var language = "en"
  @Published private(set) var inputMode: DebugInputMode
  @Published private(set) var changingInput = false
  @Published private(set) var sdkReady = false
  @Published private(set) var sessionActive = false
  @Published private(set) var debugPreview: UIView?
  @Published private(set) var videoName = ""
  let narration = TourNarrator()
  private var wearables: (any WearablesInterface)?
  private var selector: AutoDeviceSelector?
  private let debugDevice = DebugDeviceController()
  private let videos = DebugVideoStore()
  private var videoURL: URL?
  private var videoImportID = UUID()
  private var registrationVersion = 0
  private let backend = MuseumBackend()
  private let output = GlassesDisplay()
  private let tokens = ListenerTokenBag()
  private var session: DeviceSession?
  private var camera: MWDATCamera.Camera?
  private var registrationTask: Task<Void, Never>?
  private var sessionTask: Task<Void, Never>?
  private var errorTask: Task<Void, Never>?
  private var deadlineTask: Task<Void, Never>?
  private var analysisTask: Task<Void, Never>?
  private var generation = 0
  private var lastFrameAt = Date.distantPast
  private var attemptedAutomaticScan = false

  init(configurationError: String?) {
    #if targetEnvironment(simulator)
    inputMode = .initial(stored: UserDefaults.standard.string(forKey: "museum.debugInput"), simulator: true)
    #else
    inputMode = .initial(stored: UserDefaults.standard.string(forKey: "museum.debugInput"), simulator: false)
    #endif
    output.onError = { [weak self] in self?.error = "Display: " + $0 }
    output.onSelect = { [weak self] in self?.narration.select(number: $0) }
    output.onTogglePlayback = { [weak self] in self?.narration.toggle() }
    output.onNext = { [weak self] in self?.narration.next() }
    output.onCycleRate = { [weak self] in self?.narration.cycleRate() }
    narration.onSnapshot = { [weak self] in self?.output.show($0) }
    narration.onError = { [weak self] in self?.error = $0 }
    guard configurationError == nil else {
      error = configurationError ?? "Meta DAT configuration failed."
      return
    }
    if inputMode.isMock { MockDeviceKit.shared.enable() }
    bindWearables()
  }
  private func bindWearables() {
    registrationVersion += 1; let version = registrationVersion
    registrationTask?.cancel()
    let wearables = Wearables.shared
    self.wearables = wearables; sdkReady = true
    selector = AutoDeviceSelector(wearables: wearables, filter: { $0.supportsDisplay() })
    registrationTask = Task { [weak self, wearables] in
      for await state in wearables.registrationStateStream() {
        guard !Task.isCancelled, let self, self.registrationVersion == version else { return }
        self.registered = state == .registered
        if state != .registered && !self.inputMode.isMock { self.stop() }
      }
    }
  }
  var videoReady: Bool { videoURL != nil }
  var canStart: Bool {
    !changingInput && !connecting && !sessionActive && DebugInputPolicy.canStart(mode: inputMode,
      sdkReady: sdkReady, backendReady: backendReady, registered: registered, videoReady: videoReady)
  }
  func setInputMode(_ mode: DebugInputMode) async {
    guard mode != inputMode, !changingInput, !connecting else { return }
    changingInput = true; stop()
    registrationVersion += 1; registrationTask?.cancel(); registered = false
    if sdkReady { await debugDevice.disable() }
    inputMode = mode; UserDefaults.standard.set(mode.rawValue, forKey: "museum.debugInput")
    do {
      if !sdkReady { try Wearables.configure() }
      if mode.isMock { MockDeviceKit.shared.enable() }
      bindWearables(); error = ""
      status = mode.isMock ? "Simulation selected. No physical glasses or Meta AI registration required." : "Real glasses selected. Register with Meta AI and connect the backend."
    } catch { sdkReady = false; wearables = nil; selector = nil; self.error = "Meta DAT configuration: " + error.localizedDescription }
    changingInput = false
  }
  func importVideo(from url: URL) async {
    guard inputMode == .video, !changingInput, !connecting else { return }
    changingInput = true; stop()
    let request = UUID(); videoImportID = request
    defer { changingInput = false }
    do {
      let copy = try await videos.importVideo(from: url)
      guard request == videoImportID else { await videos.remove(copy); return }
      let previous = videoURL; videoURL = copy; videoName = url.lastPathComponent
      if sdkReady { error = "" }
      status = "Video ready. Start the simulated preview."
      if let previous { await videos.remove(previous) }
    } catch { if request == videoImportID { self.error = "Video import: " + error.localizedDescription } }
  }
  func replayVideo() async {
    guard inputMode == .video, videoReady, !changingInput, !connecting else { return }
    stop(); await startCamera()
  }
  func loadLayoutExample() {
    guard inputMode.isMock, streaming, !recognizing else { return }
    attemptedAutomaticScan = true
    let example = MuseumGuide.layoutExample(language: language)
    guide = example; narration.load(example, language: language)
    status = "OFFLINE LAYOUT EXAMPLE — not recognition of the current frame."
  }
  func register() async {
    guard !inputMode.isMock, let wearables else { return }
    do { try await wearables.startRegistration() }
    catch { self.error = error.localizedDescription }
  }
  func handleURL(_ url: URL) async {
    guard !inputMode.isMock, let wearables else { return }
    guard URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true else { return }
    do { _ = try await wearables.handleUrl(url) }
    catch { self.error = error.localizedDescription }
  }
  func connectBackend(link: String) async {
    do { try await backend.connect(entryLink: link); backendReady = true; error = ""; status = "Backend connected. Start the camera or simulated preview." }
    catch { backendReady = false; self.error = error.localizedDescription }
  }
  /// Called only from the explicitly labelled camera-permission button.
  func startCamera() async {
    guard canStart else { return }
    generation += 1; let run = generation
    connecting = true
    status = inputMode.isMock ? "Preparing simulated input…" : "Preparing glasses connection…"
    defer { if session == nil { connecting = false } }
    do {
      let selected: any DeviceSelector
      if inputMode.isMock {
        selected = try await debugDevice.prepare(mode: inputMode, video: videoURL)
        guard run == generation else { return }
        debugPreview = debugDevice.preview; bindWearables()
      } else {
        guard let selector else { return }; selected = selector
      }
      guard let wearables, run == generation else { return }
      if try await wearables.checkPermissionStatus(.camera) != .granted {
        guard try await wearables.requestPermission(.camera) == .granted else {
          stop()
          error = "Glasses camera permission was not granted."; return
        }
      }
      guard run == generation else { return }
      attemptedAutomaticScan = false; frameCount = 0; guide = nil; error = ""
      let connected = try wearables.createSession(deviceSelector: selected); session = connected; sessionActive = true
      // Install the SDK listeners before start(). The mock session can reach
      // .started synchronously, before a newly created Task starts executing.
      let states = connected.stateStream()
      let errors = connected.errorStream()
      sessionTask = Task { [weak self] in
        for await state in states {
          guard !Task.isCancelled, let self, run == self.generation else { return }
          if state == .started && self.camera == nil { self.attachCamera(to: connected, run: run) }
          if state == .stopped { self.stop(); return }
        }
      }
      errorTask = Task { [weak self] in
        for await error in errors {
          guard !Task.isCancelled, let self, run == self.generation else { return }
          self.error = error.localizedDescription; self.stop()
        }
      }
      try connected.start(); status = inputMode.isMock ? "Starting simulated DAT camera and Display…" : "Connecting to the glasses…"
      deadlineTask = Task { [weak self] in
        try? await Task.sleep(for: .seconds(20))
        guard !Task.isCancelled, let self, run == self.generation, self.frameCount == 0 else { return }
        let simulated = self.inputMode.isMock
        self.stop(); self.error = simulated ? "No simulated frames arrived. Check Camera permission, or replay a playable HEVC MP4/MOV video." : "No glasses video frames arrived. Check the connection, permissions and device updates."
      }
    } catch { if run == generation { stop(); self.error = error.localizedDescription } }
  }
  private func attachCamera(to connected: DeviceSession, run: Int) {
    do {
      guard let camera = try connected.addCamera(config: StreamConfiguration(videoCodec: .raw, resolution: .medium, frameRate: 15)) else { return }
      self.camera = camera
      camera.stream.videoFramePublisher.listen { [weak self] frame in
        guard let image = frame.makeUIImage() else { return }
        let immutable = ImmutableFrame(image: image)
        Task { @MainActor [weak self] in self?.receive(immutable, run: run) }
      }.store(in: tokens)
      camera.stream.errorPublisher.listen { [weak self] error in
        let message = error.localizedDescription
        Task { @MainActor [weak self] in guard let self, run == self.generation else { return }; self.stop(); self.error = message }
      }.store(in: tokens)
      camera.stream.statePublisher.listen { [weak self] state in
        let active = state == .streaming
        // A stream-state event alone does not prove usable frames arrived.
        // Only receive() enables frame-dependent controls.
        Task { @MainActor [weak self] in guard let self, run == self.generation else { return }; if !active { self.streaming = false } }
      }.store(in: tokens)
      do { try output.attach(to: connected) } catch { self.error = "Display: " + error.localizedDescription }
      camera.stream.start(); status = inputMode.isMock ? "Waiting for simulated camera frames…" : "Waiting for glasses camera frames…"
    } catch { stop(); self.error = error.localizedDescription }
  }
  private func receive(_ frame: ImmutableFrame, run: Int) {
    guard run == generation, camera != nil else { return }
    preview = frame.image; frameCount += 1; lastFrameAt = Date(); streaming = true; connecting = false
    if frameCount >= 8 && !attemptedAutomaticScan && backendReady {
      attemptedAutomaticScan = true; analyzeCurrentFrame()
    }
    if !backendReady && guide == nil { status = "SIMULATION · preview only. Connect the backend for recognition, or load the offline layout example." }
  }
  func analyzeCurrentFrame() {
    guard backendReady, !recognizing, streaming else { return }
    guard let preview, Date().timeIntervalSince(lastFrameAt) < 1 else {
      error = "No recent frame is available. Replay the video or reconnect the camera before scanning."; return
    }
    narration.stop(); guide = nil
    recognizing = true; status = "Recognizing the artwork…"; error = ""
    let frame = ImmutableFrame(image: preview), run = generation, language = language
    analysisTask = Task { [weak self, backend] in
      let jpeg = await Task.detached(priority: .userInitiated) {
        let image = frame.image; let scale = min(1, 900 / max(image.size.width, image.size.height))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: image.size.width * scale, height: image.size.height * scale), format: format).image { _ in
          image.draw(in: CGRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale))
        }.jpegData(compressionQuality: 0.8)
      }.value
      guard let self, !Task.isCancelled, run == self.generation else { return }
      do {
        guard let jpeg else { throw NSError(domain: "MuseumCompanion", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not encode the live camera frame."]) }
        let result = try await backend.analyze(jpeg: jpeg, language: language)
        guard !Task.isCancelled, run == self.generation else { return }
        self.guide = result
        self.narration.load(result, language: language)
        self.status = self.inputMode.isMock ? "Recognized from the simulated input — not physical glasses." : "Recognized from the glasses camera."
      } catch { if !Task.isCancelled && run == self.generation { self.error = error.localizedDescription; self.status = "Scan failed. Reframe and tap Scan again." } }
      if run == self.generation { self.recognizing = false }
    }
  }
  func stop() {
    videoImportID = UUID()
    generation += 1; analysisTask?.cancel(); deadlineTask?.cancel(); sessionTask?.cancel(); errorTask?.cancel()
    tokens.clear(); output.stop(); narration.stop(); camera?.stop(); camera = nil; session?.stop(); session = nil
    debugDevice.stop(); debugPreview = nil; sessionActive = false
    streaming = false; connecting = false; recognizing = false; preview = nil; guide = nil; frameCount = 0; status = "Camera stopped."
  }
  func shutdown() { stop(); registrationTask?.cancel() }
}
