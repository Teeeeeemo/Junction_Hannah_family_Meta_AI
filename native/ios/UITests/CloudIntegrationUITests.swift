import XCTest

/// Opt-in paid service acceptance: real DAT-decoded public artwork video,
/// HTTPS backend, Gemini search/ROI and native PCM playback. No microphone.
@MainActor
final class CloudIntegrationUITests: XCTestCase {
  private var app: XCUIApplication!
  private var observedState = ""
  override func setUpWithError() throws {
    try super.setUpWithError()
    guard ProcessInfo.processInfo.environment["MUSE_CLOUD_TEST"] == "1" else {
      throw XCTSkip("Run scripts/test-ios-cloud.sh explicitly for real Gemini acceptance.")
    }
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments = ["--museum-ui-test", "--museum-cloud-test", "-museum.debugInput", "video"]
    app.launchEnvironment["MUSE_UI_TEST_VIDEO"] = "museum-cloud-artwork.mp4"
  }
  override func tearDown() {
    if let app {
      let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.lifetime = .keepAlways
      screenshot.name = "Native real Gemini acceptance"; add(screenshot)
      let tree = XCTAttachment(string: app.debugDescription); tree.lifetime = .keepAlways
      tree.name = "Cloud acceptance accessibility state"; add(tree)
      app.terminate()
    }
    super.tearDown()
  }
  private var narration: XCUIElement { app.descendants(matching: .any)["narration"].firstMatch }
  private var state: String {
    let value = narration.value as? String ?? ""
    observedState = value
    return value
  }
  private func integer(_ key: String) -> Int64 {
    let prefix = key + "="
    return state.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
      .first { $0.hasPrefix(prefix) }.flatMap { Int64($0.dropFirst(prefix.count)) } ?? 0
  }
  private func wait(_ description: String, timeout: TimeInterval = 60, _ condition: @escaping () -> Bool) {
    let predicate = NSPredicate { _, _ in condition() }
    let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: timeout)
    // Failure diagnostics must not perform another potentially stuck AX query.
    XCTAssertEqual(result, .completed, "\(description); last observed state=\(observedState)")
  }
  private func reveal(_ element: XCUIElement, upward: Bool = true) {
    for _ in 0..<14 {
      let viewport = app.windows.firstMatch.frame.inset(by: UIEdgeInsets(top: 64, left: 2, bottom: 38, right: 2))
      if element.exists && !element.frame.isEmpty && viewport.contains(element.frame) && element.isHittable { return }
      let moveUp = element.exists ? element.frame.midY > viewport.midY : upward
      let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.025, dy: moveUp ? 0.75 : 0.25))
      let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.025, dy: moveUp ? 0.25 : 0.75))
      start.press(forDuration: 0.01, thenDragTo: end)
    }
    XCTAssertTrue(element.exists && element.isHittable, "Could not reveal cloud acceptance control")
  }
  func testRealArtworkAndNativeGeminiVoice() {
    app.launch()
    let start = app.buttons["start-preview"]
    XCTAssertTrue(start.waitForExistence(timeout: 30))
    wait("HTTPS backend connection", timeout: 30) {
      self.app.staticTexts["camera-status"].firstMatch.label.contains("Backend connected")
    }
    reveal(start); XCTAssertTrue(start.isEnabled); start.tap()
    wait("Real DAT video frames", timeout: 30) {
      (self.app.descendants(matching: .any)["camera-state"].firstMatch.value as? String ?? "").contains("streaming=true")
    }
    XCTAssertTrue(narration.waitForExistence(timeout: 150), "Real search/lock/ROI did not produce a guide")
    wait("Native PCM received and actually played", timeout: 90) {
      self.state.contains("voice=gemini") && self.integer("liveBytes") > 0 && self.integer("livePlayed") > 0
    }
    let initial = XCTAttachment(string: state); initial.name = "Actual native PCM playback counters"; initial.lifetime = .keepAlways; add(initial)
    wait("Narration playing") { self.state.contains("playing=true") }
    let pause = app.buttons["toggle-playback"]
    reveal(pause); pause.tap(); wait("Phone pause stops playing") { self.state.contains("playing=false") }
    let point = app.buttons["point-1"]
    let beforePoint = integer("livePlayed")
    reveal(point); point.tap(); wait("Phone selects real point one") { self.state.contains("selected=1;") }
    wait("Selected detail native audio actually completes a buffer", timeout: 90) { self.integer("livePlayed") > beforePoint }

    // A question starts a fresh answer even when the visitor paused narration.
    wait("Selected detail is playing before pause") { self.state.contains("playing=true") }
    reveal(pause); pause.tap()
    wait("Selected detail paused before question") { self.state.contains("playing=false") }

    let field = app.textFields["Ask about this detail"].firstMatch
    reveal(field); field.tap()
    let beforeAnswer = integer("livePlayed")
    field.typeText("Describe the visible colours of this detail in one short sentence.\n")
    wait("Question after pause plays audio and waits for continue", timeout: 90) {
      self.integer("livePlayed") > beforeAnswer && self.state.contains("awaitingContinue=true") && self.state.contains("playing=false")
    }
    XCTAssertTrue(state.contains("selected=1;"), "Question must retain the selected point")
    let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !self.state.contains("selected=1;") }, object: nil)
    changed.isInverted = true
    XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 3), .completed, "Question must not auto-advance")
    let final = XCTAttachment(string: state); final.name = "Question finished and retained current point"; final.lifetime = .keepAlways; add(final)
  }
}
