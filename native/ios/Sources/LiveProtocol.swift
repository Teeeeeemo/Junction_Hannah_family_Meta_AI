import Foundation

enum LiveEvent: Equatable, Sendable {
  case ready, resumed, interrupted, turnComplete, closed
  case audio(Data), transcript(role: String, text: String)
  case select(Int), rate(Double), language(String), command(String, Double?), error(String)
}

/// Wire-level validation is independent of AVAudioEngine and the network.
/// A socket generation is checked by the transport; playback IDs isolate turns.
struct LivePlaybackState: Sendable {
  private(set) var playbackID = 0
  private(set) var outputSuppressed = false
  mutating func interrupt() { playbackID += 1; outputSuppressed = true }
  mutating func beginResponse() { outputSuppressed = false }
  mutating func beginLocalSpeech() { outputSuppressed = true }
  mutating func receive(_ data: Data) throws -> LiveEvent? {
    guard data.count <= 2_000_000,
      let message = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let type = message["type"] as? String else { throw failure("Invalid Live event.") }
    guard let id = message["playbackId"] as? Int, id == playbackID else { return nil }
    switch type {
    case "ready": return .ready
    case "resumed": return .resumed
    case "interrupted": outputSuppressed = false; return .interrupted
    case "turn_complete": return outputSuppressed ? nil : .turnComplete
    case "closed": return .closed
    case "error": return .error(message["message"] as? String ?? "Gemini Live failed.")
    case "transcript":
      guard let role = message["role"] as? String, let text = message["text"] as? String,
        text.count <= 12_000 else { throw failure("Invalid Live transcript.") }
      if role == "user" { outputSuppressed = false }
      else if outputSuppressed { return nil }
      return .transcript(role: role, text: text)
    case "audio":
      guard !outputSuppressed else { return nil }
      let mime = message["mimeType"] as? String ?? "audio/pcm;rate=24000"
      guard mime == "audio/pcm;rate=24000", let encoded = message["data"] as? String,
        let pcm = Data(base64Encoded: encoded), !pcm.isEmpty, pcm.count.isMultiple(of: 2),
        pcm.count <= 1_000_000 else { throw failure("Expected mono PCM16 audio at 24 kHz.") }
      return .audio(pcm)
    case "command":
      switch message["action"] as? String {
      case "select_detail":
        guard let number = message["number"] as? Double, number.rounded() == number,
          (1...8).contains(number) else { return nil }
        return .select(Int(number))
      case "set_playback_speed":
        guard let rate = message["rate"] as? Double, [0.75,1,1.25,1.5,1.75,2].contains(rate) else { return nil }
        return .rate(rate)
      case "language":
        guard let language = message["language"] as? String, ["en", "zh"].contains(language) else { return nil }
        return .language(language)
      case "pause", "resume", "next", "zoom", "sources":
        return .command(message["action"] as! String, message["value"] as? Double)
      default: return nil
      }
    default: return nil
    }
  }
  private func failure(_ text: String) -> NSError {
    NSError(domain: "MuseumLive", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
  }
}

struct LiveSentenceBuffer: Sendable {
  private var pending = ""
  mutating func push(_ delta: String) -> [String] {
    pending += delta
    var result: [String] = []
    var search = pending.startIndex
    while search < pending.endIndex, let end = pending[search...].firstIndex(where: { "。！？!?\n.".contains($0) }) {
      let boundary = pending.index(after: end)
      // A decimal period is retained until its following character arrives.
      if pending[end] == ".", end > pending.startIndex, pending[pending.index(before: end)].isNumber,
        boundary == pending.endIndex || pending[boundary].isNumber {
        if boundary == pending.endIndex { break }
        search = boundary; continue
      }
      let sentence = String(pending[..<boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
      if !sentence.isEmpty { result.append(sentence) }
      pending = String(pending[boundary...])
      search = pending.startIndex
    }
    return result
  }
  mutating func finish() -> [String] {
    defer { pending = "" }
    let tail = pending.trimmingCharacters(in: .whitespacesAndNewlines)
    return tail.isEmpty ? [] : [tail]
  }
  mutating func reset() { pending = "" }
}
