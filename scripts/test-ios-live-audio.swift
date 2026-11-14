import Foundation
import AVFoundation

// This is synthesized test PCM rendered through Apple's real audio units.
// It does not contact Gemini or exercise microphone/Bluetooth routes.
let sampleRate = 24_000.0
let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

func require(_ result: @autoclosure () -> Bool, _ message: String) throws {
  if !result() { throw NSError(domain: "MuseumLiveAudioCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
func pcmTone(seconds: Double, frequency: Double = 440) -> Data {
  var bytes = Data(capacity: Int(seconds * sampleRate) * 2)
  for index in 0..<Int(seconds * sampleRate) {
    let value = Int16(0.6 * 32767 * sin(2 * .pi * frequency * Double(index) / sampleRate))
    let bits = UInt16(bitPattern: value)
    bytes.append(UInt8(truncatingIfNeeded: bits)); bytes.append(UInt8(truncatingIfNeeded: bits >> 8))
  }
  return bytes
}
// Identical signed PCM16 little-endian -> Float32 conversion to NativeLiveVoice.play.
func decode(_ data: Data) throws -> AVAudioPCMBuffer {
  try require(!data.isEmpty && data.count.isMultiple(of: 2), "PCM must contain whole signed 16-bit samples")
  let count = data.count / 2
  guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
    let floats = buffer.floatChannelData?[0] else { throw NSError(domain: "MuseumLiveAudioCheck", code: 2) }
  buffer.frameLength = AVAudioFrameCount(count)
  data.withUnsafeBytes { bytes in
    for index in 0..<count {
      let value = Int16(bitPattern: UInt16(bytes[index * 2]) | UInt16(bytes[index * 2 + 1]) << 8)
      floats[index] = Float(value) / 32768
    }
  }
  return buffer
}
final class OfflineGraph {
  let engine = AVAudioEngine()
  let player = AVAudioPlayerNode()
  let speed = AVAudioUnitTimePitch()
  init(rate: Double) throws {
    engine.attach(player); engine.attach(speed)
    engine.connect(player, to: speed, format: format)
    engine.connect(speed, to: engine.mainMixerNode, format: format)
    speed.rate = Float(rate)
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
    engine.prepare(); try engine.start()
  }
  deinit { player.stop(); engine.stop() }
  func render(seconds: Double) throws -> [Float] {
    let target = Int(seconds * sampleRate)
    let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512)!
    var result: [Float] = []; result.reserveCapacity(target)
    var retries = 0
    while result.count < target {
      let requested = AVAudioFrameCount(min(512, target-result.count))
      switch try engine.renderOffline(requested, to: buffer) {
      case .success:
        guard let samples = buffer.floatChannelData?[0] else { throw NSError(domain: "MuseumLiveAudioCheck", code: 3) }
        result.append(contentsOf: UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
        retries = 0
      case .cannotDoInCurrentContext: retries += 1
      case .insufficientDataFromInputNode: throw NSError(domain: "MuseumLiveAudioCheck", code: 4, userInfo: [NSLocalizedDescriptionKey: "Offline graph unexpectedly requested input audio"])
      case .error: throw NSError(domain: "MuseumLiveAudioCheck", code: 5)
      @unknown default: throw NSError(domain: "MuseumLiveAudioCheck", code: 6)
      }
      try require(retries < 1000, "Offline rendering did not make progress")
    }
    return result
  }
}
func activeRange(_ samples: [Float]) -> Range<Int>? {
  guard let first = samples.firstIndex(where: { abs($0) > 0.015 }),
    let last = samples.lastIndex(where: { abs($0) > 0.015 }) else { return nil }
  return first..<(last+1)
}
func peak(_ samples: [Float]) -> Float { samples.reduce(0) { max($0, abs($1)) } }

do {
  print("rendering=offline source=synthetic PCM16LE output=mono Float32 sampleRate=24000Hz")
  let extremes = try decode(Data([0,128,0,0,255,127]))
  try require(extremes.floatChannelData![0][0] == -1 && extremes.floatChannelData![0][1] == 0 && extremes.floatChannelData![0][2] > 0.9999, "PCM signedness/endian conversion changed")
  let pcm = pcmTone(seconds: 2)
  var durations: [Double] = []
  for rate in [0.75, 1, 1.25, 1.5, 1.75, 2] {
    let graph = try OfflineGraph(rate: rate)
    graph.player.scheduleBuffer(try decode(pcm)); graph.player.play()
    let rendered = try graph.render(seconds: 2/rate + 0.7)
    guard let active = activeRange(rendered) else { throw NSError(domain: "MuseumLiveAudioCheck", code: 7, userInfo: [NSLocalizedDescriptionKey: "Audio unit returned silence at rate \(rate)"]) }
    let actual = Double(active.count)/sampleRate, expected = 2/rate
    try require(abs(actual-expected) < 0.12, "Rate \(rate) produced \(actual)s rather than \(expected)s")
    try require(peak(rendered) > 0.2 && rendered.allSatisfy(\.isFinite), "Invalid or attenuated PCM output")
    durations.append(actual)
    print(String(format: "rate=%.2fx inputFrames=%d activeFrames=%d activeSeconds=%.5f expectedSeconds=%.5f firstActiveFrame=%d", rate, pcm.count/2, active.count, actual, expected, active.lowerBound))
  }
  try require(zip(durations, durations.dropFirst()).allSatisfy({ $0 > $1 }), "Six rates must produce strictly shorter actual audio")

  let graph = try OfflineGraph(rate: 1)
  let old = try decode(pcmTone(seconds: 2, frequency: 330))
  graph.player.scheduleBuffer(old); graph.player.scheduleBuffer(old); graph.player.play()
  let before = try graph.render(seconds: 0.2)
  try require(peak(before) > 0.2, "Stop test must begin with real playing audio")
  graph.player.stop() // NativeLiveVoice.clearAudio uses this exact queue-clearing primitive.
  let tail = try graph.render(seconds: 0.4)
  graph.player.play() // Without scheduling anything: stopped buffers must not restart.
  let emptyReplay = try graph.render(seconds: 0.5)
  try require(peak(emptyReplay) < 0.0001, "Stopping and playing replayed old queued audio")
  graph.player.scheduleBuffer(try decode(pcmTone(seconds: 0.15, frequency: 880)))
  let fresh = try graph.render(seconds: 0.8)
  guard let active = activeRange(fresh) else { throw NSError(domain: "MuseumLiveAudioCheck", code: 8) }
  let freshSeconds = Double(active.count)/sampleRate
  try require(abs(freshSeconds-0.15) < 0.12, "New short audio contains old queued buffers")
  let tailEnd = activeRange(tail).map { Double($0.upperBound)/sampleRate } ?? 0
  try require(tailEnd < 0.3, "Audio unit retained an interruption tail longer than 300ms")
  print(String(format: "stopQueue oldQueuedSeconds=4 renderedBeforeStop=0.2 tailEndSeconds=%.5f emptyReplayPeak=%.8f newActiveSeconds=%.5f", tailEnd, peak(emptyReplay), freshSeconds))
  print("PASS: real AVAudioEngine offline rendering, all six playback rates, signed PCM conversion, and stop/restart queue isolation. Synthetic PCM only; Gemini, iOS routes, microphone and Bluetooth untested.")
} catch {
  FileHandle.standardError.write(Data("FAIL: \(error.localizedDescription)\n".utf8))
  exit(1)
}
