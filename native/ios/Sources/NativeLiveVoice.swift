import Foundation
import Combine
@preconcurrency import AVFoundation

/// Authenticated backend WSS + native PCM audio. No cloud key or TTS fallback.
@MainActor final class NativeLiveVoice: ObservableObject {
  @Published private(set) var status = "Gemini Live disconnected"
  @Published private(set) var ready = false
  @Published private(set) var listening = false
  @Published private(set) var outputRoute = "System output"
  @Published private(set) var receivedPCMBytes = 0
  @Published private(set) var completedPCMFrames: Int64 = 0
  var onCaption: ((String) -> Void)?
  var onFinished: (() -> Void)?
  var onInterrupted: (() -> Void)?
  var onSelect: ((Int) -> Void)?
  var onRate: ((Double) -> Void)?
  var onLanguage: ((String) -> Void)?
  var onCommand: ((String, Double?) -> Void)?
  var onError: ((String) -> Void)?
  private var socket: URLSessionWebSocketTask?
  private var receiver: Task<Void, Never>?
  private var sender: Task<Void, Never>?
  private var timeout: Task<Void, Never>?
  private var captionClock: Task<Void, Never>?
  private var generation = 0
  private var audioGeneration = 0
  private var wire = LivePlaybackState()
  private var captions = LiveSentenceBuffer()
  private var engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private let speed = AVAudioUnitTimePitch()
  private let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
  private var graphAttached = false
  private var pendingBuffers = 0
  private var scheduledFrames: Int64 = 0
  private var playedFrames: Int64 = 0
  private var lastPacketFrames: Int64 = 0
  private var captionQueue: [(Int64, String)] = []
  private var turnEnded = false
  private var receivedAudio = false
  private var paused = false
  private var pendingSay: (String, MuseumGuide, String?)?
  private var currentGuide: MuseumGuide?
  private var language = "en"
  private var rate: Double = 1
  private var microphoneGeneration = 0
  private var vadFrames = 0
  private var lastInterrupt = Date.distantPast
  private var knownCaption: String?
  private var observers: [NSObjectProtocol] = []
  private var pendingSends = 0
  private var narrationTurn = false

  init() {
    let center = NotificationCenter.default
    for name in [NSNotification.Name.AVAudioEngineConfigurationChange, AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification] {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
        let name = notification.name
        let interruption = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        let route = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        Task { @MainActor [weak self] in
          guard let self, self.ready else { return }
          let disrupted = name == AVAudioSession.interruptionNotification && interruption == AVAudioSession.InterruptionType.began.rawValue
          let routeChanged = name == AVAudioSession.routeChangeNotification && [AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue, AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue].contains(route ?? 0)
          let engineStopped = name == NSNotification.Name.AVAudioEngineConfigurationChange && !self.engine.isRunning && (self.listening || self.pendingBuffers > 0)
          guard disrupted || routeChanged || engineStopped else { return }
          self.stopMicrophone(restartPlayback: false); self.clearAudio(); self.engine.stop()
          try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
          self.status = "Audio route changed. Resume the point or enable the microphone again."
          self.onInterrupted?(); self.onError?(self.status)
        }
      })
    }
  }

  func connect(backend: MuseumBackend, guide: MuseumGuide, language: String) async {
    disconnect()
    receivedPCMBytes = 0; completedPCMFrames = 0
    guard guide.mode == "gemini" else { return }
    let run = generation
    currentGuide = guide; self.language = language
    status = "Connecting Gemini Live · Aoede"
    do {
      let connection = try await backend.liveSocket()
      guard run == generation, !Task.isCancelled else { return }
      socket = connection; wire = LivePlaybackState(); connection.resume()
      send(["type": "start", "context": try object(guide), "language": language, "playbackRate": rate])
      receiver = Task { [weak self] in
        do {
          while !Task.isCancelled {
            let message = try await connection.receive()
            guard let self, self.generation == run else { return }
            let data: Data
            switch message { case .data(let bytes): data = bytes; case .string(let string): data = Data(string.utf8); @unknown default: continue }
            if let event = try self.wire.receive(data) { try self.handle(event) }
          }
        } catch {
          guard !Task.isCancelled, let self, self.generation == run else { return }
          self.fail("Gemini Live connection closed. Reconnect voice to continue.")
        }
      }
      timeout = Task { [weak self] in
        try? await Task.sleep(for: .seconds(18))
        guard !Task.isCancelled, let self, run == self.generation, !self.ready else { return }
        self.fail("Gemini Live did not become ready. Check backend access and reconnect.")
      }
    } catch { if run == generation { fail(error.localizedDescription) } }
  }
  func say(_ text: String, guide: MuseumGuide, currentDetailID: String?) {
    pendingSay = (text, guide, currentDetailID)
    guard ready, !paused else { return }
    interrupt()
    wire.beginResponse(); knownCaption = text; narrationTurn = true
    pendingSay = nil
    do {
      send(["type": "context", "context": try object(guide), "language": language, "currentDetailId": currentDetailID ?? ""])
      send(["type": "text", "text": "Read this museum narration once, without extra introductions or changing the selected point: " + text])
      status = "Gemini Live · Aoede · waiting for audio"
      armTurnTimeout()
    } catch { fail(error.localizedDescription) }
  }
  func ask(_ text: String, guide: MuseumGuide, currentDetailID: String?) {
    guard ready, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    interrupt(); paused = false; wire.beginResponse(); narrationTurn = false; onInterrupted?()
    do {
      send(["type": "context", "context": try object(guide), "language": language, "currentDetailId": currentDetailID ?? ""])
      send(["type": "text", "text": text]); armTurnTimeout()
    } catch { fail(error.localizedDescription) }
  }
  func interrupt() {
    clearAudio(); pendingSay = nil
    if ready { wire.interrupt(); send(["type": "interrupt", "playbackId": wire.playbackID]) }
  }
  func pause() { paused = true; player.pause(); status = "Gemini Live paused" }
  func prepareNarration() { paused = false }
  var hasRetainedPlayback: Bool { pendingSay != nil || pendingBuffers > 0 }
  func resume() {
    paused = false
    if let (text, guide, detail) = pendingSay { say(text, guide: guide, currentDetailID: detail); return }
    if pendingBuffers > 0 { player.play(); status = "Gemini Live · Aoede" }
    finishIfDrained()
  }
  func setRate(_ value: Double) {
    guard [0.75,1,1.25,1.5,1.75,2].contains(value) else { return }
    rate = value; speed.rate = Float(value)
    if ready { send(["type": "playback_rate", "rate": value]) }
  }
  func setLanguage(_ value: String, guide: MuseumGuide) {
    language = value; currentGuide = guide
    if ready, let context = try? object(guide) { send(["type": "context", "context": context, "language": value]) }
  }
  /// Relocation changes factual context without starting or interrupting audio.
  func updateContext(guide: MuseumGuide, currentDetailID: String?) {
    currentGuide = guide
    if ready, let context = try? object(guide) {
      send(["type": "context", "context": context, "language": language, "currentDetailId": currentDetailID ?? ""])
    }
  }
  func startMicrophone() async {
    guard ready, !listening else { return }
    microphoneGeneration += 1; let micRun = microphoneGeneration, run = generation
    let permission = await AVAudioApplication.requestRecordPermission()
    guard run == generation, micRun == microphoneGeneration, ready else { return }
    guard permission else { onError?("Allow Microphone access in iPhone Settings to talk to Gemini."); return }
    do {
      engine.stop()
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .defaultToSpeaker])
      try session.setActive(true)
      let input = engine.inputNode
      guard input.inputFormat(forBus: 0).channelCount > 0 else { throw audioFailure("No microphone is available. Use the text question field.") }
      try input.setVoiceProcessingEnabled(true)
      attachGraph()
      let source = input.outputFormat(forBus: 0)
      guard source.sampleRate > 0, source.channelCount > 0,
        let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
        let converter = AVAudioConverter(from: source, to: target) else { throw audioFailure("Microphone PCM conversion is unavailable.") }
      input.installTap(onBus: 0, bufferSize: 2048, format: source) { [weak self] buffer, _ in
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16_000 / source.sampleRate)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        let once = AudioInputOnce()
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
          if !once.take() { status.pointee = .noDataNow; return nil }
          status.pointee = .haveData; return buffer
        }
        guard error == nil, output.frameLength > 0, let samples = output.int16ChannelData?[0] else { return }
        let data = Data(bytes: samples, count: Int(output.frameLength) * 2)
        var energy: Double = 0
        for index in 0..<Int(output.frameLength) { let value = Double(samples[index]) / 32768; energy += value * value }
        let speaking = sqrt(energy / Double(output.frameLength)) > 0.025
        Task { @MainActor [weak self] in
          guard let self, self.generation == run, self.microphoneGeneration == micRun, self.listening else { return }
          self.vadFrames = speaking ? self.vadFrames + 1 : 0
          if self.vadFrames == 2, Date().timeIntervalSince(self.lastInterrupt) > 1 {
            // Keep the upstream VAD session alive; clear local sound immediately.
            self.lastInterrupt = Date(); self.wire.beginLocalSpeech(); self.clearAudio(); self.onInterrupted?()
          }
          self.send(["type": "audio", "data": data.base64EncodedString()])
        }
      }
      listening = true; try engine.start(); if !paused, pendingBuffers > 0 { player.play() }
      refreshRoute(); status = "Gemini Live · listening · echo cancellation enabled"
    } catch { stopMicrophone(); onError?(error.localizedDescription) }
  }
  func stopMicrophone(restartPlayback: Bool = true) {
    microphoneGeneration += 1
    let wasListening = listening
    if wasListening { engine.inputNode.removeTap(onBus: 0); send(["type": "audio_end"]) }
    listening = false; vadFrames = 0
    if wasListening {
      engine.stop(); try? engine.inputNode.setVoiceProcessingEnabled(false)
      if restartPlayback, ready {
        do {
          try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
          try engine.start(); if !paused, pendingBuffers > 0 { player.play() }; refreshRoute()
        } catch { onError?("Audio route could not restart. Reconnect Gemini Live.") }
      }
    }
  }
  func disconnect() {
    generation += 1; stopMicrophone(restartPlayback: false); clearAudio()
    receiver?.cancel(); receiver = nil; sender?.cancel(); sender = nil
    timeout?.cancel(); timeout = nil
    socket?.cancel(with: .normalClosure, reason: nil); socket = nil
    ready = false; pendingSay = nil; currentGuide = nil; pendingSends = 0; paused = false
    engine.stop(); status = "Gemini Live disconnected"
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }
  private func attachGraph() {
    guard !graphAttached else { return }
    engine.attach(player); engine.attach(speed)
    engine.connect(player, to: speed, format: format)
    engine.connect(speed, to: engine.mainMixerNode, format: format)
    speed.rate = Float(rate); graphAttached = true
  }
  private func play(_ data: Data) throws {
    attachGraph()
    if !engine.isRunning {
      let session = AVAudioSession.sharedInstance()
      if !listening { try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers]) }
      try session.setActive(true); try engine.start(); refreshRoute()
    }
    let count = data.count / 2
    guard pendingBuffers < 256, scheduledFrames - playedFrames + Int64(count) <= 24_000 * 90,
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
      let floats = buffer.floatChannelData?[0] else { throw audioFailure("Live audio queue exceeded its limit. Reconnect voice.") }
    buffer.frameLength = AVAudioFrameCount(count)
    data.withUnsafeBytes { bytes in
      for index in 0..<count {
        let value = Int16(bitPattern: UInt16(bytes[index * 2]) | UInt16(bytes[index * 2 + 1]) << 8)
        floats[index] = Float(value) / 32768
      }
    }
    let run = audioGeneration
    pendingBuffers += 1; receivedAudio = true; scheduledFrames += Int64(count); lastPacketFrames = Int64(count)
    receivedPCMBytes += data.count
    if let knownCaption { captionQueue = [(0, knownCaption)]; self.knownCaption = nil }
    player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, self.audioGeneration == run else { return }
        self.pendingBuffers -= 1; self.playedFrames += Int64(count)
        self.completedPCMFrames += Int64(count)
        self.flushCaptions(); self.finishIfDrained()
      }
    }
    if !paused { player.play() }
    if captionClock == nil {
      captionClock = Task { [weak self] in
        while !Task.isCancelled {
          guard let self, self.audioGeneration == run else { return }
          self.flushCaptions()
          try? await Task.sleep(for: .milliseconds(40))
        }
      }
    }
    status = paused ? "Gemini Live paused" : "Gemini Live · Aoede · PCM 24 kHz"
  }
  private func handle(_ event: LiveEvent) throws {
    switch event {
    case .ready:
      ready = true; timeout?.cancel(); status = "Gemini Live ready · Aoede"
      if let (text, guide, detail) = pendingSay { say(text, guide: guide, currentDetailID: detail) }
    case .resumed: status = "Gemini Live resumed · Aoede"
    case .audio(let bytes): try play(bytes)
    case .transcript(let role, let text):
      if role == "user" { paused = false; narrationTurn = false; onInterrupted?() }
      else if !narrationTurn { queueCaptions(captions.push(text)) }
    case .interrupted: clearAudio(); onInterrupted?()
    case .turnComplete:
      queueCaptions(captions.finish()); turnEnded = true; finishIfDrained()
    case .select(let number): onSelect?(number)
    case .rate(let value): setRate(value); onRate?(value)
    case .language(let value): onLanguage?(value)
    case .command(let action, let value): onCommand?(action, value)
    case .error(let message): fail(message)
    case .closed: fail("Gemini Live closed. Reconnect to continue.")
    }
  }
  private func queueCaptions(_ sentences: [String]) {
    for sentence in sentences { captionQueue.append((max(playedFrames, scheduledFrames - lastPacketFrames), sentence)) }
    flushCaptions()
  }
  private func flushCaptions() {
    guard !paused, player.isPlaying,
      let actual = player.lastRenderTime.flatMap({ player.playerTime(forNodeTime: $0)?.sampleTime }) else { return }
    while let next = captionQueue.first, next.0 <= max(playedFrames, actual) {
      captionQueue.removeFirst(); onCaption?(next.1)
    }
  }
  private func finishIfDrained() {
    guard turnEnded, pendingBuffers == 0, !paused else { return }
    turnEnded = false; timeout?.cancel(); captionClock?.cancel(); captionClock = nil
    if receivedAudio { flushCaptions(); onFinished?() }
    else { fail("Gemini Live returned no playable audio. Reconnect voice; offline speech is a separate choice.") }
  }
  private func clearAudio() {
    audioGeneration += 1; player.stop()
    pendingBuffers = 0; scheduledFrames = 0; playedFrames = 0; lastPacketFrames = 0
    turnEnded = false; receivedAudio = false; captions.reset(); captionQueue = []; knownCaption = nil; narrationTurn = false
    timeout?.cancel(); captionClock?.cancel(); captionClock = nil
  }
  private func send(_ message: [String: Any]) {
    guard let socket, let data = try? JSONSerialization.data(withJSONObject: message),
      let string = String(data: data, encoding: .utf8) else { return }
    if message["type"] as? String == "audio", pendingSends >= 32 { return }
    pendingSends += 1
    let previous = sender, run = generation
    sender = Task { [weak self] in
      await previous?.value
      guard !Task.isCancelled, let self, self.generation == run else { return }
      defer { if self.generation == run { self.pendingSends -= 1 } }
      do { try await socket.send(.string(string)) }
      catch { if self.generation == run { self.fail("Could not send to Gemini Live. Reconnect voice.") } }
    }
  }
  private func armTurnTimeout() {
    timeout?.cancel(); let run = audioGeneration
    timeout = Task { [weak self] in
      try? await Task.sleep(for: .seconds(90))
      guard !Task.isCancelled, let self, self.audioGeneration == run else { return }
      self.fail("Gemini Live response timed out. The current point was preserved.")
    }
  }
  private func object(_ guide: MuseumGuide) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(guide)) }
  private func refreshRoute() { outputRoute = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portName).joined(separator: ", ") }
  private func audioFailure(_ text: String) -> NSError { NSError(domain: "MuseumLiveAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
  private func fail(_ message: String) { disconnect(); status = message; onError?(message) }
}

/// Converter requests are synchronous but @Sendable; protect the one-shot flag.
private final class AudioInputOnce: @unchecked Sendable {
  private let lock = NSLock()
  private var available = true
  func take() -> Bool { lock.lock(); defer { lock.unlock() }; let value = available; available = false; return value }
}
