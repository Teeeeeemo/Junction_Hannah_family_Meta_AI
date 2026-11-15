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
  @Published private(set) var artworkSearch: MuseumArtworkSearch?
  @Published private(set) var trackingStatus = "idle"
  @Published private(set) var trackedDetailBox: [Double]?
  @Published private(set) var zoomImage: UIImage?
  @Published private(set) var zoom = 1
  @Published private(set) var translating = false
  @Published private(set) var recoveryCount = 0
  @Published private(set) var recoveredPCMBase: Int64 = 0
  @Published var showingSources = false
  @Published var referenceArtworkID = ""
  @Published private(set) var inputMode: DebugInputMode
  @Published private(set) var changingInput = false
  @Published private(set) var sdkReady = false
  @Published private(set) var sessionActive = false
  @Published private(set) var debugPreview: UIView?
  @Published private(set) var phoneQuestionEditing = false
  var phoneInputContext: Int { generation }
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
  private let tracker = ArtworkTracker()
  private var trackingTask: Task<Void, Never>?
  private var recoveryTask: Task<Void, Never>?
  private var recoveryTimeout: Task<Void, Never>?
  @Published private var recovery = ArtworkRecoveryState()
  var recoveryPhase: String { String(describing: recovery.phase) }
  var hudSendCount: Int {
    #if DEBUG
    output.debugSendCount
    #else
    0
    #endif
  }
  private var trackingEnabled = false
  private var selectionVersion = 0
  private var lastSelection: Int?
  private var languageVersion = 0
  private var artworkVersion = 0
  private var frameWatchdog: Task<Void, Never>?
  private var lastTrackedImage: UIImage?
  private var lastTrackingAt = Date.distantPast
  private var detailRegistry = MuseumDetailRegistry()
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
  #if DEBUG
  private var testInputStallUntil: Date?
  private var testInputStallCompleted = false
  private var testPointAudioBaseline: Int64?
  private var testGapRecoveryBaseline: Int?
  private var testHUDRefreshTask: Task<Void, Never>?
  #endif
  var injectedInputGap: Bool {
    #if DEBUG
    testInputStallCompleted
    #else
    false
    #endif
  }
  var injectedGapRecoveryBaseline: Int {
    #if DEBUG
    testGapRecoveryBaseline ?? -1
    #else
    -1
    #endif
  }

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
    narration.onSnapshot = { [weak self] value in
      guard let self else { return }
      if value.selectedNumber != self.lastSelection {
        self.selectionVersion += 1; self.lastSelection = value.selectedNumber
        self.trackedDetailBox = nil; self.zoomImage = nil; self.output.showInspection(nil)
      }
      self.output.show(value)
    }
    narration.onError = { [weak self] in self?.error = $0 }
    narration.onLanguage = { [weak self] value in Task { await self?.changeLanguage(value) } }
    narration.onCommand = { [weak self] action, value in
      if action == "zoom", let value { self?.setZoom(Int(value)) }
      if action == "sources" { self?.showingSources = true }
    }
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
    artworkVersion += 1; languageVersion += 1; translating = false
    trackingTask?.cancel(); trackingTask = nil; trackingEnabled = false
    trackedDetailBox = nil; zoomImage = nil; lastTrackedImage = nil; output.showInspection(nil)
    let example = MuseumGuide.layoutExample(language: language)
    guide = example; narration.load(example, language: language)
    status = "OFFLINE LAYOUT EXAMPLE — not recognition of the current frame."
    #if DEBUG
    if ProcessInfo.processInfo.arguments.contains("--museum-ui-test"),
      ProcessInfo.processInfo.arguments.contains("--museum-hud-focus-test") {
      testHUDRefreshTask?.cancel()
      testHUDRefreshTask = Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: .milliseconds(500))
          guard !Task.isCancelled, let self, self.streaming, self.guide?.mode == "demo" else { return }
          // Exercise the real DAT preview refresh; no model/audio/frame result is injected.
          self.output.show(self.narration.snapshot)
        }
      }
    }
    #endif
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
    #if DEBUG
    // Opt-in failure injection drops real decoded deliveries. It never creates
    // frames, recognition results, or audio, and is absent from Release builds.
    if ProcessInfo.processInfo.arguments.contains("--museum-cloud-test"),
      ProcessInfo.processInfo.environment["MUSE_UI_TEST_INPUT_STALL"] == "1" {
      if !testInputStallCompleted, testInputStallUntil == nil,
        guide?.mode == "gemini", narration.selectedNumber == 1, narration.playing, !narration.awaitingContinue {
        if testPointAudioBaseline == nil { testPointAudioBaseline = narration.livePlayedFrames }
        if narration.livePlayedFrames > (testPointAudioBaseline ?? .max) {
          testInputStallUntil = Date().addingTimeInterval(1.4)
          print("MUSE_TEST_INPUT_STALL_BEGIN point=1")
        }
      }
      if let until = testInputStallUntil {
        if Date() < until { return }
        testInputStallUntil = nil; testInputStallCompleted = true
        print("MUSE_TEST_INPUT_STALL_END")
      }
    }
    #endif
    preview = frame.image; frameCount += 1; lastFrameAt = Date(); streaming = true; connecting = false
    if frameWatchdog == nil {
      frameWatchdog = Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: .milliseconds(100))
          guard !Task.isCancelled, let self, self.generation == run else { return }
          let freshness = TrackingFreshnessPolicy.evaluate(frameAge: Date().timeIntervalSince(self.lastFrameAt),
            resultAge: self.trackedDetailBox == nil ? 0 : Date().timeIntervalSince(self.lastTrackingAt))
          if freshness != .fresh {
            self.trackedDetailBox = nil; self.zoomImage = nil; self.lastTrackedImage = nil; self.output.showInspection(nil)
            self.narration.setLocated(false)
            if self.trackingEnabled { self.trackingStatus = "lost — waiting for a fresh tracking result" }
            if self.trackingEnabled, Date().timeIntervalSince(self.lastFrameAt) > 0.3 {
              // Hide stale geometry immediately, but retain the Vision worker:
              // a transient delivery gap must not permanently disable updates.
              // Fresh frames still have to pass Vision confidence and age gates.
              self.trackingStatus = "lost — input stalled; waiting for fresh frames"
              if freshness == .rescan {
                #if DEBUG
                if self.testInputStallUntil != nil {
                  self.testGapRecoveryBaseline = self.recoveryCount
                  print("MUSE_TEST_INPUT_STALL_OBSERVED point=1 recoveries=\(self.recoveryCount)")
                }
                #endif
                self.trackingEnabled = false
                self.trackingTask?.cancel(); self.trackingTask = nil
                self.recovery.interrupt(afterFrame: self.frameCount)
                self.trackingStatus = self.recovery.phase == .failed
                  ? "lost — recovery interrupted; scan again" : "lost — waiting to verify the artwork again"
                if self.recovery.phase == .failed {
                  self.failRecovery("Input interrupted again during verification. Tap Scan again.", run: run, context: self.artworkVersion)
                }
                await self.tracker.reset()
              }
            }
          }
          if Date().timeIntervalSince(self.lastFrameAt) > 1 { self.streaming = false }
        }
      }
    }
    updateTracking(frame.image, run: run)
    if backendReady, !recognizing, guide?.mode == "gemini", recovery.begin(frameToken: frameCount) {
      recoverArtwork(frame, number: frameCount, run: run)
    }
    if frameCount >= 8 && !attemptedAutomaticScan && backendReady {
      attemptedAutomaticScan = true; analyzeCurrentFrame()
    }
    if !backendReady && guide == nil { status = "SIMULATION · preview only. Connect the backend for recognition, or load the offline layout example." }
  }
  func analyzeCurrentFrame(confirmedCandidateID: String? = nil) {
    guard backendReady, !recognizing, streaming else { return }
    guard let preview, Date().timeIntervalSince(lastFrameAt) < 1 else {
      error = "No recent frame is available. Replay the video or reconnect the camera before scanning."; return
    }
    recoveryTask?.cancel(); recoveryTimeout?.cancel(); recovery.reset()
    let previous = artworkSearch
    let priorIdentity = guide?.recognition?.selectedCandidate?.identityKey
    let priorProgress = narration.progressSnapshot, priorPaused = narration.paused, priorAwaitingContinue = narration.awaitingContinue
    artworkVersion += 1; let context = artworkVersion
    languageVersion += 1; translating = false
    trackingTask?.cancel(); trackingTask = nil; lastTrackedImage = nil
    narration.stop(); guide = nil; trackingEnabled = false; trackedDetailBox = nil; zoomImage = nil; output.showInspection(nil)
    recognizing = true; status = "Searching for an exhibited artwork…"; error = ""
    let initialFrame = ImmutableFrame(image: preview), initialNumber = frameCount, run = generation, language = language, artworkID = referenceArtworkID
    analysisTask = Task { [weak self, backend] in
      guard let self, !Task.isCancelled, run == self.generation, context == self.artworkVersion else { return }
      defer { if run == self.generation { self.recognizing = false } }
      do {
        await self.tracker.reset()
        var frame = initialFrame, number = initialNumber, search = previous
        for attempt in 0..<3 {
          guard !Task.isCancelled, run == self.generation else { return }
          let captured = frame
          guard let jpeg = await Task.detached(priority: .userInitiated, operation: { captured.image.jpegData(compressionQuality: 0.9) }).value else { throw self.failure("Could not encode the camera frame.") }
          let result = try await backend.searchArtwork(jpeg: jpeg, language: language, previous: search, confirmedCandidateId: confirmedCandidateID)
          guard !Task.isCancelled, run == self.generation else { return }
          search = result; self.artworkSearch = result; self.status = result.reason
          if result.status == "locked" { break }
          if result.status != "searching" || attempt == 2 { return }
          let deadline = Date().addingTimeInterval(2)
          while self.frameCount <= number {
            try await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled, run == self.generation, Date() < deadline else { throw self.failure("No newer frame arrived. Replay or reframe before searching again.") }
          }
          guard let next = self.preview, Date().timeIntervalSince(self.lastFrameAt) < 1 else { throw self.failure("No fresh frame is available.") }
          frame = ImmutableFrame(image: next); number = self.frameCount
        }
        guard let lock = search, lock.status == "locked", let candidate = lock.selectedCandidate else { return }
        guard let image = frame.image.cgImage, candidate.box.count == 4 else { throw self.failure("The artwork region is invalid.") }
        let values = candidate.box
        let cropRect = CGRect(x: values[0] * Double(image.width), y: values[1] * Double(image.height),
          width: values[2] * Double(image.width), height: values[3] * Double(image.height)).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard cropRect.width >= 96, cropRect.height >= 96, let cropped = image.cropping(to: cropRect) else { throw self.failure("Move closer: the artwork has too few original pixels for reliable details.") }
        let roi = MuseumROI(frameId: "\(run):\(number)", frameWidth: image.width, frameHeight: image.height,
          box: [cropRect.minX / Double(image.width), cropRect.minY / Double(image.height), cropRect.width / Double(image.width), cropRect.height / Double(image.height)])
        if candidate.kind == "planar" {
          let seed = await self.tracker.start(cgImage: image, artworkBox: roi.box, frameToken: number)
          guard run == self.generation, !Task.isCancelled else { return }
          self.trackingEnabled = seed.status == "ready"; self.trackingStatus = seed.status
        } else { self.trackingStatus = "3D tracking is not supported in this build" }
        let crop = ImmutableFrame(image: UIImage(cgImage: cropped))
        guard let jpeg = await Task.detached(priority: .userInitiated, operation: { crop.image.jpegData(compressionQuality: 0.95) }).value else { throw self.failure("Could not encode the original-pixel artwork crop.") }
        self.status = "Artwork locked. Analyzing its original-pixel crop…"
        let analysis = try await backend.analyze(jpeg: jpeg, language: language, lock: lock, roi: roi, artworkId: artworkID.isEmpty ? nil : artworkID)
        guard !Task.isCancelled, run == self.generation else { return }
        let result = self.detailRegistry.reconcile(analysis)
        guard !result.details.isEmpty else { throw self.failure("No reliably matched details remain. Start a new visit before identifying new points.") }
        self.guide = result
        let sameWork = priorIdentity != nil && priorIdentity == result.recognition?.selectedCandidate?.identityKey
        self.narration.load(result, language: language, backend: backend,
          resumeProgress: sameWork ? priorProgress : nil, resumePaused: sameWork && priorPaused,
          resumeAwaitingContinue: sameWork && priorAwaitingContinue)
        self.narration.setLocated(self.trackingStatus == "tracking")
        self.status = self.inputMode.isMock ? "Recognized from the simulated input — not physical glasses." : "Recognized from the glasses camera."
      } catch { if !Task.isCancelled && run == self.generation { self.error = error.localizedDescription; self.status = "Scan failed. Reframe and tap Scan again." } }
    }
  }
  /// A bounded re-identification of the same planar artwork. Reuses its existing
  /// annotations; this does not claim perspective correction or new detections.
  private func recoverArtwork(_ initialFrame: ImmutableFrame, number initialNumber: Int, run: Int) {
    artworkVersion += 1; let context = artworkVersion
    trackingTask?.cancel(); trackingTask = nil; trackingEnabled = false
    recognizing = true; error = ""; status = "Verifying the artwork after the input interruption…"
    recoveryTimeout?.cancel()
    recoveryTimeout = Task { [weak self] in
      try? await Task.sleep(for: .seconds(45))
      guard !Task.isCancelled, let self, self.generation == run, self.artworkVersion == context,
        self.recovery.phase != .idle else { return }
      self.failRecovery("Artwork verification timed out. Tap Scan again.", run: run, context: context)
    }
    recoveryTask = Task { [weak self, backend] in
      guard let self else { return }
      defer {
        if self.generation == run && self.artworkVersion == context {
          self.recognizing = false; self.recoveryTimeout?.cancel(); self.recoveryTask = nil
        }
      }
      do {
        var frame = initialFrame, number = initialNumber
        // Retain the identity reference, but require fresh visual observations.
        // Hints carry no selection or pre-interruption stability count.
        guard let hints = self.guide?.recognition?.identityHints() else {
          throw self.failure("No reliable artwork identity reference is available. Tap Scan again.")
        }
        var lock: MuseumArtworkSearch? = hints
        for attempt in 0..<3 {
          guard !Task.isCancelled, run == self.generation, context == self.artworkVersion,
            self.recovery.observe(frameToken: number) else { throw self.failure("No fresh observation is available.") }
          let captured = frame
          guard let jpeg = await Task.detached(priority: .userInitiated, operation: {
            captured.image.jpegData(compressionQuality: 0.9)
          }).value else { throw self.failure("Could not encode the recovery frame.") }
          let result = try await backend.searchArtwork(jpeg: jpeg, language: self.language,
            previous: lock, confirmedCandidateId: nil)
          guard !Task.isCancelled, run == self.generation, context == self.artworkVersion else { return }
          lock = result
          if result.status == "locked", self.recovery.observationCount >= 2 { break }
          guard result.status == "searching", attempt < 2 else {
            throw self.failure("The same artwork could not be verified. Tap Scan again.")
          }
          let deadline = Date().addingTimeInterval(2)
          while self.frameCount <= number {
            try await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled, run == self.generation, context == self.artworkVersion,
              Date() < deadline else { throw self.failure("No new camera frame arrived.") }
          }
          guard let next = self.preview, Date().timeIntervalSince(self.lastFrameAt) < 1 else {
            throw self.failure("The camera input is not fresh.")
          }
          frame = ImmutableFrame(image: next); number = self.frameCount
        }
        guard let lock, let candidate = lock.selectedCandidate, let image = frame.image.cgImage,
          candidate.box.count == 4 else { throw self.failure("No reliable planar artwork region is available.") }
        let box = candidate.box
        let rect = CGRect(x: box[0] * Double(image.width), y: box[1] * Double(image.height),
          width: box[2] * Double(image.width), height: box[3] * Double(image.height))
          .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let roi = MuseumROI(frameId: "\(run):\(number)", frameWidth: image.width, frameHeight: image.height,
          box: [rect.minX / Double(image.width), rect.minY / Double(image.height),
            rect.width / Double(image.width), rect.height / Double(image.height)])
        guard let currentGuide = self.guide else { throw self.failure("The active guide changed.") }
        if let reason = currentGuide.relocalizationFailure(to: lock, roi: roi) {
          #if DEBUG
          let oldIdentity = currentGuide.recognition?.selectedCandidate?.identityKey ?? "missing"
          print("MUSE_RECOVERY_REJECT reason=\(reason) oldIdentity=\(oldIdentity.prefix(160)) newIdentity=\(candidate.identityKey.prefix(160)) candidate=\(candidate.box) roi=\(roi.box) frame=\(roi.frameWidth)x\(roi.frameHeight)")
          #endif
          throw self.failure("The artwork identity or full visible region changed. Tap Scan again.")
        }
        let seed = await self.tracker.start(cgImage: image, artworkBox: roi.box, frameToken: number)
        guard !Task.isCancelled, run == self.generation, context == self.artworkVersion else { return }
        // Merge into the latest guide, so a concurrent language change survives.
        guard seed.status == "ready", let latest = self.guide?.relocalized(to: lock, roi: roi),
          self.recovery.seeded() else { throw self.failure("The artwork could not be tracked. Tap Scan again.") }
        self.guide = latest; self.artworkSearch = lock
        self.narration.updateLocationContext(latest)
        self.trackingEnabled = true; self.trackingStatus = "ready — waiting for a fresh tracking result"
        self.status = "Same artwork verified. Locating the selected detail…"
        let deadline = Date().addingTimeInterval(3)
        while self.recovery.phase == .awaitingTracking {
          try await Task.sleep(for: .milliseconds(60))
          guard !Task.isCancelled, run == self.generation, context == self.artworkVersion else { return }
          if self.recovery.phase != .awaitingTracking { break }
          guard Date() < deadline else { throw self.failure("No fresh detail location was recovered. Tap Scan again.") }
        }
        if self.recovery.phase == .idle { self.status = "Artwork tracking recovered. Your selected point is unchanged." }
      } catch {
        if !Task.isCancelled { self.failRecovery(error.localizedDescription, run: run, context: context) }
      }
    }
  }
  private func failRecovery(_ message: String, run: Int, context: Int) {
    guard generation == run, artworkVersion == context, recovery.phase != .idle else { return }
    recovery.fail(); recoveryTask?.cancel(); recoveryTimeout?.cancel()
    trackingTask?.cancel(); trackingTask = nil
    recognizing = false; trackingEnabled = false
    trackedDetailBox = nil; zoomImage = nil; lastTrackedImage = nil; output.showInspection(nil)
    narration.setLocated(false); trackingStatus = "lost — verification failed; scan again"
    error = message; status = "Tracking is paused. Reframe the artwork and tap Scan again."
  }
  private func updateTracking(_ image: UIImage, run: Int) {
    guard trackingEnabled, trackingTask == nil, let cgImage = image.cgImage else { return }
    let version = selectionVersion, number = frameCount, context = artworkVersion
    let capturedAt = Date()
    let detail = guide?.details.first { $0.number == narration.selectedNumber }
    let box = detail.flatMap { guide?.frameBox(for: $0) }
    trackingTask = Task { [weak self, tracker] in
      let result = await tracker.update(cgImage: cgImage, detailBox: box, frameToken: number)
      guard let self, run == self.generation, context == self.artworkVersion, !Task.isCancelled,
        self.recovery.canAcceptTrackingResults else { return }
      self.trackingTask = nil
      guard let result else { return }
      guard Date().timeIntervalSince(capturedAt) <= 0.3 else {
        self.trackedDetailBox = nil; self.zoomImage = nil; self.lastTrackedImage = nil
        self.output.showInspection(nil); self.narration.setLocated(false); return
      }
      self.trackingStatus = result.status
      guard version == self.selectionVersion else { return }
      let located = result.status == "tracking" && (self.narration.selectedNumber == nil || result.detailBox != nil)
      if self.recovery.phase == .awaitingTracking {
        guard self.recovery.acceptTracking(frameToken: number, fresh: true, detailLocated: located) else {
          self.failRecovery("A reliable current detail location was not found. Tap Scan again.", run: run, context: context)
          return
        }
        self.recoveryTimeout?.cancel()
        self.recoveredPCMBase = self.narration.livePlayedFrames
        self.recoveryCount += 1
      }
      self.trackedDetailBox = result.detailBox
      self.lastTrackedImage = image
      self.lastTrackingAt = Date()
      self.narration.setLocated(located)
      self.refreshInspection(image)
    }
  }
  func setZoom(_ value: Int) {
    guard [1,2,4].contains(value) else { return }
    zoom = value; if let lastTrackedImage { refreshInspection(lastTrackedImage) }
  }
  /// The mock web preview manages its own focus. Only detach its phone view;
  /// the DAT session, sends, camera, tracking and audio keep running.
  func setPhoneQuestionEditing(_ editing: Bool, context: Int) {
    guard context == generation, inputMode.isMock, sessionActive, let debugPreview else { return }
    if editing { debugPreview.removeFromSuperview() }
    if phoneQuestionEditing != editing { phoneQuestionEditing = editing }
  }
  private func refreshInspection(_ image: UIImage) {
    guard zoom > 1, let values = trackedDetailBox, values.count == 4, let cg = image.cgImage else {
      zoomImage = nil; output.showInspection(nil); return
    }
    // Both rates crop the same detail-centered base range; no super-resolution.
    let base = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    let range = CGRect(x: base.midX - base.width / Double(zoom), y: base.midY - base.height / Double(zoom),
      width: base.width * 2 / Double(zoom), height: base.height * 2 / Double(zoom))
    let rect = CGRect(x: range.minX * Double(cg.width), y: range.minY * Double(cg.height),
      width: range.width * Double(cg.width), height: range.height * Double(cg.height)).integral.intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
    zoomImage = cg.cropping(to: rect).map { UIImage(cgImage: $0) }
    output.showInspection(zoomImage)
  }
  func changeLanguage(_ value: String) async {
    guard ["en","zh"].contains(value), value != language, !translating else { return }
    languageVersion += 1; let version = languageVersion, run = generation, context = artworkVersion
    guard let guide else { language = value; return }
    translating = true
    defer { if version == languageVersion { translating = false } }
    do {
      let translated = guide.mode == "demo" ? MuseumGuide.layoutExample(language: value) : try await backend.translate(guide, language: value)
      guard version == languageVersion, run == generation, context == artworkVersion else { return }
      guard let merged = self.guide?.mergingTranslation(translated) else {
        throw failure("The translated guide no longer matches the current artwork details.")
      }
      self.guide = merged; language = value; narration.replaceTranslation(merged, language: value)
    } catch { if version == languageVersion, run == generation { self.error = "Translation: " + error.localizedDescription } }
  }
  private func failure(_ text: String) -> NSError { NSError(domain: "MuseumGuide", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
  func stop() {
    phoneQuestionEditing = false
    recoveryTask?.cancel(); recoveryTask = nil; recoveryTimeout?.cancel(); recoveryTimeout = nil; recovery.reset()
    recoveryCount = 0; recoveredPCMBase = 0
    #if DEBUG
    testHUDRefreshTask?.cancel(); testHUDRefreshTask = nil
    testInputStallUntil = nil; testInputStallCompleted = false
    testPointAudioBaseline = nil; testGapRecoveryBaseline = nil
    #endif
    videoImportID = UUID()
    languageVersion += 1; translating = false
    artworkVersion += 1; frameWatchdog?.cancel(); frameWatchdog = nil; lastTrackedImage = nil
    detailRegistry.reset()
    trackingTask?.cancel(); trackingTask = nil; trackingEnabled = false; trackingStatus = "idle"
    trackedDetailBox = nil; zoomImage = nil; artworkSearch = nil; selectionVersion += 1
    generation += 1; analysisTask?.cancel(); deadlineTask?.cancel(); sessionTask?.cancel(); errorTask?.cancel()
    tokens.clear(); output.stop(); narration.stop(); camera?.stop(); camera = nil; session?.stop(); session = nil
    debugDevice.stop(); debugPreview = nil; sessionActive = false
    streaming = false; connecting = false; recognizing = false; preview = nil; guide = nil; frameCount = 0; status = "Camera stopped."
  }
  func shutdown() { stop(); registrationTask?.cancel() }
}
