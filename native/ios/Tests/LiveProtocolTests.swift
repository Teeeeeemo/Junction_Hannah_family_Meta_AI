import Foundation

@main struct LiveProtocolTests {
  static func main() throws {
    func check(_ value: Bool, _ message: String = "Live protocol assertion") { precondition(value, message) }
    var state = LivePlaybackState()
    func event(_ json: String) throws -> LiveEvent? { try state.receive(Data(json.utf8)) }
    check(try event("{\"type\":\"ready\",\"playbackId\":0}") == .ready)
    state.interrupt()
    check(try event("{\"type\":\"audio\",\"playbackId\":0,\"data\":\"AAAA\"}") == nil, "Late audio from the previous selection must be rejected")
    check(try event("{\"type\":\"turn_complete\",\"playbackId\":0}") == nil)
    check(try event("{\"type\":\"resumed\",\"playbackId\":1}") == .resumed)
    state.beginResponse()
    check(try event("{\"type\":\"audio\",\"playbackId\":1,\"mimeType\":\"audio/pcm;rate=24000\",\"data\":\"AAD/fwCA\"}") == .audio(Data([0,0,255,127,0,128])))
    do { _ = try event("{\"type\":\"audio\",\"playbackId\":1,\"mimeType\":\"audio/pcm;rate=16000\",\"data\":\"AAAA\"}"); preconditionFailure("Wrong output sample rate accepted") } catch { }
    do { _ = try event("{\"type\":\"audio\",\"playbackId\":1,\"data\":\"AA==\"}"); preconditionFailure("Incomplete PCM sample accepted") } catch { }
    check(try event("{\"type\":\"command\",\"playbackId\":1,\"action\":\"set_playback_speed\",\"rate\":1.75}") == .rate(1.75))
    check(try event("{\"type\":\"command\",\"playbackId\":1,\"action\":\"set_playback_speed\",\"rate\":3}") == nil)
    check(try event("{\"type\":\"command\",\"playbackId\":1,\"action\":\"select_detail\",\"number\":4}") == .select(4))
    check(try event("{\"type\":\"command\",\"playbackId\":1,\"action\":\"select_detail\",\"number\":4.5}") == nil)
    state.beginLocalSpeech()
    check(try event("{\"type\":\"audio\",\"playbackId\":1,\"data\":\"AAAAAA==\"}") == nil, "Local voice onset must suppress same-turn late audio")
    check(try event("{\"type\":\"turn_complete\",\"playbackId\":1}") == nil)
    check(try event("{\"type\":\"interrupted\",\"playbackId\":1}") == .interrupted)
    check(try event("{\"type\":\"audio\",\"playbackId\":1,\"data\":\"AAAAAA==\"}") != nil, "Upstream interruption authorizes new response")
    check(try event("{\"type\":\"closed\",\"playbackId\":1}") == .closed)
    var captions = LiveSentenceBuffer()
    precondition(captions.push("A detail") == [])
    precondition(captions.push(". 下一") == ["A detail."])
    precondition(captions.push("句。尾") == ["下一句。"])
    precondition(captions.finish() == ["尾"])
    captions.reset(); precondition(captions.finish().isEmpty)
    precondition(captions.push("Use 1.5 times. Next sentence.") == ["Use 1.5 times.", "Next sentence."], "Decimal points must not block following sentence boundaries")
    print("Passed native Live protocol checks: event epochs, PCM format, commands and caption boundaries.")
  }
}
