import Foundation
import Combine
@preconcurrency import AVFoundation

enum TourVoiceMode: String, CaseIterable { case gemini, offline }

/// One progression state for phone, DAT, cloud audio, and explicit offline TTS.
@MainActor
final class TourNarrator: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
  static let rates: [Double] = [0.75, 1, 1.25, 1.5, 1.75, 2]
  @Published private(set) var sentence = ""
  @Published private(set) var sectionTitle = ""
  @Published private(set) var selectedNumber: Int?
  @Published private(set) var playing = false
  @Published private(set) var paused = false
  @Published private(set) var finished = false
  @Published private(set) var rate: Double = 1
  @Published private(set) var audioOutput = "System output"
  @Published private(set) var voiceMode: TourVoiceMode = .gemini
  @Published private(set) var voiceStatus = "Gemini Live disconnected"
  @Published private(set) var listening = false
  @Published private(set) var awaitingContinue = false
  @Published private(set) var locationBlocked = false
  @Published private(set) var liveReceivedBytes = 0
  @Published private(set) var livePlayedFrames: Int64 = 0
  @Published var subtitles = false { didSet { publish() } }
  var onSnapshot: ((TourSnapshot) -> Void)?
  var onError: ((String) -> Void)?
  var onLanguage: ((String) -> Void)?
  var onCommand: ((String, Double?) -> Void)?
  let live = NativeLiveVoice()
  private let synthesizer = AVSpeechSynthesizer()
  private var progress = TourProgress(stops: [])
  private var utteranceID: ObjectIdentifier?
  private var artworkTitle = ""
  private var points: [TourPoint] = []
  private var language = "en"
  private var guide: MuseumGuide?
  private var backend: MuseumBackend?
  private var connectionTask: Task<Void, Never>?
  private var tourGeneration = 0
  private var subscriptions = Set<AnyCancellable>()
  private var waitingForLocation = false

  override init() {
    super.init(); synthesizer.delegate = self
    synthesizer.usesApplicationAudioSession = true
    live.onCaption = { [weak self] text in guard let self else { return }; self.sentence = text; self.publish() }
    live.onFinished = { [weak self] in
      guard let self, self.voiceMode == .gemini, self.playing else { return }
      if self.awaitingContinue { self.playing = false; self.paused = true; self.publish() }
      else { self.progress.advanceSentence(); self.speakCurrent() }
    }
    live.onInterrupted = { [weak self] in
      guard let self else { return }
      self.awaitingContinue = true; self.playing = true; self.paused = false
      self.voiceStatus = "Gemini Live · listening / answering"; self.publish()
    }
    live.onSelect = { [weak self] in self?.select(number: $0) }
    live.onRate = { [weak self] value in self?.setRate(value) }
    live.onLanguage = { [weak self] value in self?.onLanguage?(value) }
    live.onCommand = { [weak self] action, value in
      guard let self else { return }
      switch action {
      case "pause": self.pause()
      case "resume": self.resume()
      case "next": self.next()
      default: self.onCommand?(action, value)
      }
    }
    live.onError = { [weak self] text in
      guard let self else { return }
      self.playing = false; self.paused = true; self.publish(); self.onError?(text)
    }
    live.$status.sink { [weak self] in self?.voiceStatus = $0 }.store(in: &subscriptions)
    live.$listening.sink { [weak self] in self?.listening = $0 }.store(in: &subscriptions)
    live.$outputRoute.sink { [weak self] in self?.audioOutput = $0 }.store(in: &subscriptions)
    live.$receivedPCMBytes.sink { [weak self] in self?.liveReceivedBytes = $0 }.store(in: &subscriptions)
    live.$completedPCMFrames.sink { [weak self] in self?.livePlayedFrames = $0 }.store(in: &subscriptions)
  }
  var rateLabel: String { Self.label(for: rate) }
  static func label(for value: Double) -> String { String(format: "%g×", value) }
  var snapshot: TourSnapshot {
    TourSnapshot(artworkTitle: artworkTitle, sectionTitle: sectionTitle, selectedNumber: selectedNumber,
      points: points, sentence: sentence, playing: playing, paused: paused, finished: finished,
      subtitles: subtitles, rateLabel: rateLabel, language: language)
  }
  private func stops(_ guide: MuseumGuide, language: String) -> [TourStop] {
    [TourStop(number: nil, title: language == "zh" ? "先认识这幅作品" : "The whole story", text: guide.overview)] + guide.details.sorted { $0.number < $1.number }.map {
      TourStop(number: $0.number, title: $0.title, text: $0.description)
    }
  }
  var progressSnapshot: TourProgress { progress }
  func load(_ guide: MuseumGuide, language: String, backend: MuseumBackend? = nil,
    resumeProgress: TourProgress? = nil, resumePaused: Bool = false, resumeAwaitingContinue: Bool = false) {
    stop(); self.language = language; self.guide = guide; self.backend = backend
    artworkTitle = guide.artwork.title
    points = guide.details.sorted { $0.number < $1.number }.map { TourPoint(number: $0.number, title: $0.title) }
    progress = TourProgress(stops: stops(guide, language: language))
    if var retained = resumeProgress {
      retained.replace(stops: stops(guide, language: language)); progress = retained
      selectedNumber = retained.retainedNumber; sectionTitle = retained.current?.title ?? ""
      sentence = retained.sentence; finished = retained.finished
      paused = resumePaused || resumeAwaitingContinue; awaitingContinue = resumeAwaitingContinue
    }
    voiceMode = guide.mode == "demo" ? .offline : .gemini
    if !paused && !finished { speakCurrent() } else { publish() }
    if voiceMode == .gemini { reconnectVoice() }
  }
  func replaceTranslation(_ guide: MuseumGuide, language: String) {
    let wasPlaying = playing, wasPaused = paused
    cancelUtterance(); self.guide = guide; self.language = language; artworkTitle = guide.artwork.title
    points = guide.details.sorted { $0.number < $1.number }.map { TourPoint(number: $0.number, title: $0.title) }
    progress.replace(stops: stops(guide, language: language))
    live.setLanguage(language, guide: guide)
    if wasPlaying && !awaitingContinue { speakCurrent() }
    else { sentence = progress.sentence; sectionTitle = progress.current?.title ?? sectionTitle; paused = wasPaused; publish() }
  }
  func selectVoice(_ mode: TourVoiceMode) {
    guard mode != voiceMode else { return }
    cancelUtterance(); live.disconnect(); voiceMode = mode
    if mode == .gemini { reconnectVoice() }
    else { voiceStatus = "Explicit offline iOS system speech"; speakCurrent() }
  }
  func reconnectVoice() {
    guard voiceMode == .gemini, let guide, guide.mode == "gemini", let backend else {
      if voiceMode == .gemini { onError?("Connect the backend and recognize an artwork before starting Gemini Live.") }; return
    }
    connectionTask?.cancel(); let run = tourGeneration
    connectionTask = Task { [weak self] in
      guard let self else { return }
      guard self.tourGeneration == run, self.voiceMode == .gemini else { return }
      await self.live.connect(backend: backend, guide: guide, language: self.language)
      guard !Task.isCancelled, self.tourGeneration == run, self.voiceMode == .gemini else { return }
      if !self.paused && !self.awaitingContinue { self.speakCurrent() }
    }
  }
  func select(number: Int?) {
    guard progress.select(number: number) else { return }
    if guide?.mode == "gemini", number != nil { locationBlocked = true }
    awaitingContinue = false; waitingForLocation = false
    cancelUtterance(); speakCurrent()
  }
  func next() { cancelUtterance(); awaitingContinue = false; progress.nextStop(); speakCurrent() }
  func toggle() { if playing && !awaitingContinue { pause() } else { resume() } }
  func pause(forLocation: Bool = false) {
    waitingForLocation = forLocation
    if voiceMode == .gemini { live.pause() }
    else if !synthesizer.pauseSpeaking(at: .immediate) { cancelUtterance() }
    playing = false; paused = true; publish()
  }
  func resume() {
    guard !locationBlocked || progress.current?.number == nil else { waitingForLocation = true; publish(); return }
    if awaitingContinue {
      awaitingContinue = false; cancelUtterance(); if progress.finished { progress.replayCurrent() }; speakCurrent(); return
    }
    if paused, voiceMode == .gemini, !progress.finished {
      if live.hasRetainedPlayback { live.resume(); paused = false; playing = true; publish() }
      else { speakCurrent() }
      return
    }
    if paused, voiceMode == .offline, synthesizer.continueSpeaking() { paused = false; playing = true; refreshRoute(); publish(); return }
    if progress.finished { progress.replayCurrent() }
    speakCurrent()
  }
  func ask(_ text: String) {
    guard voiceMode == .gemini, live.ready, let guide else { onError?("Questions require a ready Gemini Live connection."); return }
    awaitingContinue = true; paused = false; playing = true
    live.ask(text, guide: guide, currentDetailID: guide.details.first { $0.number == selectedNumber }?.id); publish()
  }
  func toggleMicrophone() {
    if listening { live.stopMicrophone() }
    else if voiceMode == .gemini { Task { await live.startMicrophone() } }
  }
  func setLocated(_ located: Bool) {
    let blocked = guide?.mode == "gemini" && !located
    guard blocked != locationBlocked else { return }
    locationBlocked = blocked
    if blocked, selectedNumber != nil, playing, !awaitingContinue {
      waitingForLocation = true; pause(forLocation: true)
    } else if !blocked, waitingForLocation {
      waitingForLocation = false; paused = false; speakCurrent()
    }
    publish()
  }
  func setRate(_ value: Double) {
    guard Self.rates.contains(value), value != rate else { return }
    let resume = playing
    rate = value
    if voiceMode == .gemini { live.setRate(value); publish() }
    else if resume { cancelUtterance(); speakCurrent() }
    else if paused { cancelUtterance(); paused = true; publish() }
    else { publish() }
  }
  func cycleRate() { setRate(Self.rates[((Self.rates.firstIndex(of: rate) ?? 1) + 1) % Self.rates.count]) }
  func stop() {
    tourGeneration += 1; connectionTask?.cancel(); connectionTask = nil
    cancelUtterance(); live.disconnect(); progress = TourProgress(stops: [])
    guide = nil; backend = nil; artworkTitle = ""; points = []; sentence = ""; sectionTitle = ""; selectedNumber = nil
    playing = false; paused = false; finished = false; awaitingContinue = false; waitingForLocation = false; locationBlocked = false; publish()
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }
  private func cancelUtterance() {
    utteranceID = nil; synthesizer.stopSpeaking(at: .immediate); live.interrupt(); playing = false; paused = false
  }
  private func speakCurrent() {
    guard let current = progress.current else {
      playing = false; paused = false; finished = progress.finished; sentence = ""; publish()
      if voiceMode == .offline { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
      return
    }
    if guide?.mode == "gemini", current.number != nil, current.number != selectedNumber { locationBlocked = true }
    sectionTitle = current.title; selectedNumber = current.number; finished = false
    if locationBlocked && current.number != nil { waitingForLocation = true; playing = false; paused = true; publish(); return }
    paused = false
    if voiceMode == .gemini {
      sentence = ""; playing = true
      if let guide {
        live.prepareNarration()
        live.say(progress.sentence, guide: guide, currentDetailID: guide.details.first { $0.number == current.number }?.id)
      }
      publish(); return
    }
    sentence = progress.sentence; voiceStatus = "Explicit offline iOS system speech"
    do {
      let audio = AVAudioSession.sharedInstance()
      try audio.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers]); try audio.setActive(true)
      let utterance = AVSpeechUtterance(string: sentence)
      guard let voice = AVSpeechSynthesisVoice(language: language == "zh" ? "zh-CN" : "en-US") else {
        throw NSError(domain: "MuseumSpeech", code: 1, userInfo: [NSLocalizedDescriptionKey: "Install a system speech voice for the selected language in iPhone Settings."])
      }
      utterance.voice = voice
      utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Float(rate)))
      utteranceID = ObjectIdentifier(utterance); playing = true; refreshRoute(); publish(); synthesizer.speak(utterance)
    } catch { playing = false; publish(); onError?("Speech: " + error.localizedDescription) }
  }
  private func refreshRoute() { audioOutput = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portName).joined(separator: ", ") }
  private func publish() { onSnapshot?(snapshot) }
  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
    let id = ObjectIdentifier(utterance)
    Task { @MainActor [weak self] in guard let self, self.utteranceID == id else { return }; self.refreshRoute() }
  }
  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    let id = ObjectIdentifier(utterance)
    Task { @MainActor [weak self] in
      guard let self, self.utteranceID == id else { return }
      self.utteranceID = nil; self.progress.advanceSentence(); self.speakCurrent()
    }
  }
}
