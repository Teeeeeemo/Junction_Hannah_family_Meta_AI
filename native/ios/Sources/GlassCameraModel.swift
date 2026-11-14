import Foundation
import Combine
import UIKit
import MWDATCore
import MWDATCamera

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
  let narration = TourNarrator()
  private let wearables: (any WearablesInterface)?
  private let selector: AutoDeviceSelector?
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
    guard configurationError == nil else {
      wearables = nil; selector = nil
      error = configurationError ?? "Meta DAT configuration failed."
      return
    }
    let wearables = Wearables.shared
    self.wearables = wearables
    selector = AutoDeviceSelector(wearables: wearables, filter: { $0.supportsDisplay() })
    output.onError = { [weak self] in self?.error = "Display: " + $0 }
    output.onSelect = { [weak self] in self?.narration.select(number: $0) }
    output.onTogglePlayback = { [weak self] in self?.narration.toggle() }
    output.onNext = { [weak self] in self?.narration.next() }
    output.onCycleRate = { [weak self] in self?.narration.cycleRate() }
    narration.onSnapshot = { [weak self] in self?.output.show($0) }
    narration.onError = { [weak self] in self?.error = $0 }
    registrationTask = Task { [weak self, wearables] in
      for await state in wearables.registrationStateStream() {
        guard !Task.isCancelled else { return }
        self?.registered = state == .registered
        if state != .registered { self?.stop() }
      }
    }
  }
  func register() async {
    guard let wearables else { return }
    do { try await wearables.startRegistration() }
    catch { self.error = error.localizedDescription }
  }
  func handleURL(_ url: URL) async {
    guard let wearables else { return }
    guard URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true else { return }
    do { _ = try await wearables.handleUrl(url) }
    catch { self.error = error.localizedDescription }
  }
  func connectBackend(link: String) async {
    do { try await backend.connect(entryLink: link); backendReady = true; error = ""; status = "Backend connected. Start the glasses camera." }
    catch { backendReady = false; self.error = error.localizedDescription }
  }
  /// Called only from the explicitly labelled camera-permission button.
  func startCamera() async {
    guard let wearables, let selector, registered, backendReady, session == nil, !connecting else { return }
    connecting = true
    defer { if session == nil { connecting = false } }
    do {
      if try await wearables.checkPermissionStatus(.camera) != .granted {
        guard try await wearables.requestPermission(.camera) == .granted else {
          error = "Glasses camera permission was not granted."; return
        }
      }
      generation += 1; let run = generation
      attemptedAutomaticScan = false; frameCount = 0; guide = nil; error = ""
      let connected = try wearables.createSession(deviceSelector: selector); session = connected
      sessionTask = Task { [weak self] in
        for await state in connected.stateStream() {
          guard !Task.isCancelled, let self, run == self.generation else { return }
          if state == .started && self.camera == nil { self.attachCamera(to: connected, run: run) }
          if state == .stopped { self.stop(); return }
        }
      }
      errorTask = Task { [weak self] in
        for await error in connected.errorStream() {
          guard !Task.isCancelled, let self, run == self.generation else { return }
          self.error = error.localizedDescription; self.stop()
        }
      }
      try connected.start(); status = "Connecting to the glasses…"
      deadlineTask = Task { [weak self] in
        try? await Task.sleep(for: .seconds(20))
        guard !Task.isCancelled, let self, run == self.generation, self.frameCount == 0 else { return }
        self.stop(); self.error = "No glasses video frames arrived. Check the connection, permissions and device updates."
      }
    } catch { stop(); self.error = error.localizedDescription }
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
        Task { @MainActor [weak self] in guard let self, run == self.generation else { return }; self.streaming = active }
      }.store(in: tokens)
      do { try output.attach(to: connected) } catch { self.error = "Display: " + error.localizedDescription }
      camera.stream.start(); status = "Waiting for glasses camera frames…"
    } catch { stop(); self.error = error.localizedDescription }
  }
  private func receive(_ frame: ImmutableFrame, run: Int) {
    guard run == generation, camera != nil else { return }
    preview = frame.image; frameCount += 1; lastFrameAt = Date(); streaming = true; connecting = false
    if frameCount >= 8 && !attemptedAutomaticScan {
      attemptedAutomaticScan = true; analyzeCurrentFrame()
    }
  }
  func analyzeCurrentFrame() {
    guard !recognizing, streaming, let preview, Date().timeIntervalSince(lastFrameAt) < 1 else { return }
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
        self.status = "Recognized from the glasses camera."
      } catch { if !Task.isCancelled && run == self.generation { self.error = error.localizedDescription; self.status = "Scan failed. Reframe and tap Scan again." } }
      if run == self.generation { self.recognizing = false }
    }
  }
  func stop() {
    generation += 1; analysisTask?.cancel(); deadlineTask?.cancel(); sessionTask?.cancel(); errorTask?.cancel()
    tokens.clear(); output.stop(); narration.stop(); camera?.stop(); camera = nil; session?.stop(); session = nil
    streaming = false; connecting = false; recognizing = false; preview = nil; guide = nil; frameCount = 0; status = "Camera stopped."
  }
  func shutdown() { stop(); registrationTask?.cancel() }
}
