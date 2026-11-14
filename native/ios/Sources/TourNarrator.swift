import Foundation
import Combine
@preconcurrency import AVFoundation

/// System speech runs locally. Audio follows iOS's selected media output,
/// including the glasses when their Bluetooth audio route is selected.
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
  @Published var subtitles = false { didSet { publish() } }
  var onSnapshot: ((TourSnapshot) -> Void)?
  var onError: ((String) -> Void)?
  private let synthesizer = AVSpeechSynthesizer()
  private var progress = TourProgress(stops: [])
  private var utteranceID: ObjectIdentifier?
  private var artworkTitle = ""
  private var points: [TourPoint] = []
  private var language = "en"

  override init() {
    super.init(); synthesizer.delegate = self
    synthesizer.usesApplicationAudioSession = true
  }
  var rateLabel: String { Self.label(for: rate) }
  static func label(for value: Double) -> String { String(format: "%g×", value) }
  var snapshot: TourSnapshot {
    TourSnapshot(artworkTitle: artworkTitle, sectionTitle: sectionTitle, selectedNumber: selectedNumber,
      points: points, sentence: sentence, playing: playing, paused: paused, finished: finished,
      subtitles: subtitles, rateLabel: rateLabel, language: language)
  }
  func load(_ guide: MuseumGuide, language: String) {
    stop(); self.language = language; artworkTitle = guide.artwork.title
    let details = guide.details.sorted { $0.number < $1.number }
    points = details.map { TourPoint(number: $0.number, title: $0.title) }
    progress = TourProgress(stops: [TourStop(number: nil, title: language == "zh" ? "先认识这幅作品" : "The whole story", text: guide.overview)] + details.map {
      TourStop(number: $0.number, title: $0.title, text: $0.description)
    })
    speakCurrent()
  }
  func select(number: Int?) {
    guard progress.select(number: number) else { return }
    cancelUtterance(); speakCurrent()
  }
  func next() { cancelUtterance(); progress.nextStop(); speakCurrent() }
  func toggle() {
    if playing {
      if !synthesizer.pauseSpeaking(at: .immediate) { cancelUtterance() }
      playing = false; paused = true; publish()
    } else if paused {
      if synthesizer.continueSpeaking() { paused = false; playing = true; refreshRoute(); publish() }
      else { speakCurrent() }
    } else {
      if progress.finished { progress.restart() }
      speakCurrent()
    }
  }
  func setRate(_ value: Double) {
    guard Self.rates.contains(value), value != rate else { return }
    let resume = playing
    rate = value
    // Apple's rate must be set before enqueueing. Restart only this sentence,
    // never the whole tour; old utterance callbacks are ignored by identity.
    if resume { cancelUtterance(); speakCurrent() }
    else if paused { cancelUtterance(); paused = true; publish() }
    else { publish() }
  }
  func cycleRate() {
    let index = Self.rates.firstIndex(of: rate) ?? 1
    setRate(Self.rates[(index + 1) % Self.rates.count])
  }
  func stop() {
    cancelUtterance(); progress = TourProgress(stops: [])
    artworkTitle = ""; points = []; sentence = ""; sectionTitle = ""; selectedNumber = nil
    playing = false; paused = false; finished = false; publish()
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }
  private func cancelUtterance() {
    utteranceID = nil; synthesizer.stopSpeaking(at: .immediate); playing = false; paused = false
  }
  private func speakCurrent() {
    guard let current = progress.current else {
      playing = false; paused = false; finished = progress.finished; sentence = ""; publish()
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
      return
    }
    sentence = progress.sentence; sectionTitle = current.title; selectedNumber = current.number
    finished = false; paused = false
    do {
      let audio = AVAudioSession.sharedInstance()
      try audio.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
      try audio.setActive(true)
      let utterance = AVSpeechUtterance(string: sentence)
      guard let voice = AVSpeechSynthesisVoice(language: language == "zh" ? "zh-CN" : "en-US") else {
        throw NSError(domain: "MuseumSpeech", code: 1, userInfo: [NSLocalizedDescriptionKey: "Install a system speech voice for the selected language in iPhone Settings."])
      }
      utterance.voice = voice
      utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Float(rate)))
      utteranceID = ObjectIdentifier(utterance); playing = true; refreshRoute(); publish()
      synthesizer.speak(utterance)
    } catch { playing = false; publish(); onError?("Speech: " + error.localizedDescription) }
  }
  private func refreshRoute() {
    audioOutput = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portName).joined(separator: ", ")
  }
  private func publish() { onSnapshot?(snapshot) }
  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
    let id = ObjectIdentifier(utterance)
    Task { @MainActor [weak self] in
      guard let self, self.utteranceID == id else { return }; self.refreshRoute()
    }
  }
  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    let id = ObjectIdentifier(utterance)
    Task { @MainActor [weak self] in
      guard let self, self.utteranceID == id else { return }
      self.utteranceID = nil; self.progress.advanceSentence(); self.speakCurrent()
    }
  }
}
