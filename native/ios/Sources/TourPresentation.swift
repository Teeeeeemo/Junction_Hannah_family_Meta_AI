import Foundation

/// Pure tour progression, shared by speech and the two presentation surfaces.
struct TourStop: Sendable {
  let number: Int?
  let title: String
  let sentences: [String]

  init(number: Int?, title: String, text: String) {
    self.number = number; self.title = title
    var sentences: [String] = []
    text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .bySentences) { value, _, _, _ in
      if let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { sentences.append(value) }
    }
    self.sentences = sentences
  }
}

struct TourProgress: Sendable {
  private(set) var stops: [TourStop]
  private(set) var stopIndex = 0
  private(set) var sentenceIndex = 0
  private(set) var finished = false
  private(set) var automatic = true
  init(stops: [TourStop]) {
    self.stops = stops.filter { !$0.sentences.isEmpty }
    finished = self.stops.isEmpty
  }
  var current: TourStop? { !finished && stops.indices.contains(stopIndex) ? stops[stopIndex] : nil }
  var sentence: String { current?.sentences[sentenceIndex] ?? "" }
  var retainedNumber: Int? { stops.indices.contains(stopIndex) ? stops[stopIndex].number : nil }
  mutating func advanceSentence() {
    guard let current else { return }
    if sentenceIndex + 1 < current.sentences.count { sentenceIndex += 1 }
    else if automatic { nextStop() }
    else { finished = true }
  }
  mutating func nextStop() {
    guard stops.indices.contains(stopIndex) else { return }
    sentenceIndex = 0
    if stopIndex + 1 < stops.count { stopIndex += 1; finished = false }
    else { finished = true }
  }
  @discardableResult mutating func select(number: Int?) -> Bool {
    guard let index = stops.firstIndex(where: { $0.number == number }) else { return false }
    stopIndex = index; sentenceIndex = 0; finished = false; automatic = false; return true
  }
  mutating func replayCurrent() { sentenceIndex = 0; finished = stops.isEmpty }
  mutating func replace(stops: [TourStop]) {
    let number = retainedNumber
    self.stops = stops.filter { !$0.sentences.isEmpty }
    guard let index = self.stops.firstIndex(where: { $0.number == number }) else {
      stopIndex = 0; sentenceIndex = 0; finished = true; return
    }
    stopIndex = index
    if self.stops.indices.contains(stopIndex) { sentenceIndex = min(sentenceIndex, self.stops[stopIndex].sentences.count - 1) }
    else { sentenceIndex = 0; finished = true }
  }
  mutating func restart() { stopIndex = 0; sentenceIndex = 0; finished = stops.isEmpty; automatic = true }
}

struct TourPoint: Sendable { let number: Int; let title: String }
struct TourSnapshot: Sendable {
  var artworkTitle = ""
  var sectionTitle = ""
  var selectedNumber: Int?
  var points: [TourPoint] = []
  var sentence = ""
  var playing = false
  var paused = false
  var finished = false
  var subtitles = false
  var rateLabel = "1×"
  var language = "en"
}

enum HUDLayout {
  static let pointsPerPage = 3
  /// One short caption at most. Speech always retains the full sentence.
  static func compact(_ text: String, latin: Int, cjk: Int) -> String {
    let text = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    let hasCJK = text.unicodeScalars.contains { (0x2E80...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }
    let limit = hasCJK ? cjk : latin
    return text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
  }
  static func page(containing number: Int?, points: [TourPoint]) -> Int {
    guard let number, let index = points.firstIndex(where: { $0.number == number }) else { return 0 }
    return index / pointsPerPage
  }
  static func points(on page: Int, from points: [TourPoint]) -> [TourPoint] {
    let start = max(0, page) * pointsPerPage
    guard start < points.count else { return [] }
    return Array(points[start..<min(start + pointsPerPage, points.count)])
  }
}
