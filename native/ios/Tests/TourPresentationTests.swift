import Foundation

@main struct TourPresentationTests {
  static func main() {
    var checks = 0
    func check(_ result: @autoclosure () -> Bool, _ message: String) {
      precondition(result(), message); checks += 1
    }
    let overview = TourStop(number: nil, title: "Overview", text: "The painting was made in 1889. Look at the cypress.")
    let first = TourStop(number: 1, title: "Cypress", text: "A dark tree. It links earth and sky.")
    let second = TourStop(number: 2, title: "Mountains", text: "Blue hills in the distance.")
    var tour = TourProgress(stops: [overview, first, second])
    check(tour.current?.number == nil && tour.sentence == "The painting was made in 1889.", "Begin with one complete overview sentence")
    tour.advanceSentence()
    check(tour.sentence == "Look at the cypress.", "Advance by a sentence, never by a transport chunk")
    tour.advanceSentence()
    check(tour.current?.number == 1 && tour.sentence == "A dark tree.", "Overview automatically advances to point 1")
    check(tour.select(number: 2) && tour.sentence == "Blue hills in the distance.", "Selecting a point replaces current narration immediately")
    tour.advanceSentence()
    check(tour.finished && tour.current == nil && tour.sentence.isEmpty, "Last point finishes without looping")
    check(tour.select(number: 1) && !tour.finished && tour.sentence == "A dark tree.", "Completed tour can be interrupted by a new selection")
    check(!tour.select(number: 99) && tour.current?.number == 1, "Unknown point does not corrupt tour state")
    tour.restart()
    check(tour.current?.number == nil && tour.sentenceIndex == 0, "Replay restarts at the introduction")
    let chinese = TourStop(number: 1, title: "柏树", text: "请看右侧的柏树。它连接天空与大地！")
    check(chinese.sentences == ["请看右侧的柏树。", "它连接天空与大地！"], "Chinese sentence boundaries")
    let empty = TourStop(number: nil, title: "Empty", text: "  \n ")
    check(TourProgress(stops: [empty]).finished, "Empty speech never hangs the queue")
    check(!TourSnapshot().subtitles, "Glasses subtitles are off by default")
    let points = (1...8).map { TourPoint(number: $0, title: "Detail \($0)") }
    check(HUDLayout.points(on: 0, from: points).map(\.number) == [1, 2, 3], "Only three detail buttons per page")
    check(HUDLayout.page(containing: 7, points: points) == 2, "Current spoken point selects its own page")
    check(HUDLayout.points(on: 2, from: points).map(\.number) == [7, 8], "Last detail page is bounded")
    check(HUDLayout.points(on: 3, from: points).isEmpty, "Out-of-range page is safe")
    let caption = HUDLayout.compact(String(repeating: "文", count: 200), latin: 88, cjk: 32)
    check(caption.count == 32 && caption.hasSuffix("…"), "CJK captions cannot grow to a paragraph")
    let emoji = HUDLayout.compact(String(repeating: "👨‍👩‍👧‍👦", count: 30), latin: 16, cjk: 7)
    check(emoji.count == 16 && emoji.hasSuffix("…"), "Clamping preserves grapheme clusters")
    func ready(_ mode: DebugInputMode, sdk: Bool = true, backend: Bool = false, registration: Bool = false, video: Bool = false) -> Bool {
      DebugInputPolicy.canStart(mode: mode, sdkReady: sdk, backendReady: backend, registered: registration, videoReady: video)
    }
    check(!ready(.glasses, registration: true), "Real glasses still require backend readiness")
    check(!ready(.glasses, backend: true), "Real glasses still require actual Meta registration")
    check(ready(.glasses, backend: true, registration: true), "Configured real-device route remains available")
    check(ready(.phoneCamera), "Phone simulation does not require real Meta registration or backend")
    check(!ready(.video), "Video mode cannot start without an imported file")
    check(ready(.video, video: true), "Imported video can preview without cloud or hardware")
    check(!ready(.phoneCamera, sdk: false), "SDK setup failure must not access Wearables.shared")
    check(DebugInputMode.initial(stored: nil, simulator: true) == .video, "Simulator defaults to replay")
    check(DebugInputMode.initial(stored: nil, simulator: false) == .glasses, "Phone retains explicit hardware default")
    check(DebugInputMode.initial(stored: "phoneCamera", simulator: false) == .phoneCamera, "User-selected no-glasses mode persists")
    check(DebugInputMode.initial(stored: "invalid", simulator: false) == .glasses, "Unknown saved source is safe")
    let example = MuseumGuide.layoutExample(language: "en")
    check(example.mode == "demo" && example.artwork.id == "layout-example", "Offline fixture is never marked as Gemini recognition")
    check(example.details.map(\.number) == [1, 2, 3, 4], "Offline layout fixture exercises the next page")
    check(example.overview.contains("not recognition") && MuseumGuide.layoutExample(language: "zh").overview.contains("不是对当前画面"), "Both spoken fixture introductions disclose their origin")
    print("Passed \(checks) native tour/presentation/input-policy checks. Audio, SDK mocks and optical layout still require runtime validation.")
  }
}
