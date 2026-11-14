import XCTest

/// Runs against the actual app and Meta DAT MockDeviceKit, with no backend.
/// A generated HEVC file supplies moving frames; the guide is explicitly demo.
@MainActor
final class DebugInputUITests: XCTestCase {
  private var app: XCUIApplication!

  override func setUp() {
    super.setUp()
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments = ["--museum-ui-test", "-museum.debugInput", "video"]
  }

  override func tearDown() {
    if let app {
      let screenshot = XCTAttachment(screenshot: app.screenshot())
      screenshot.lifetime = .keepAlways; screenshot.name = name
      add(screenshot)
      let tree = XCTAttachment(string: app.debugDescription)
      tree.lifetime = .keepAlways; tree.name = "Accessibility tree"
      add(tree)
      app.terminate()
    }
    super.tearDown()
  }

  private func reveal(_ element: XCUIElement, upward: Bool = true) {
    for _ in 0..<12 {
      if element.exists && element.isHittable { return }
      if upward { app.swipeUp() } else { app.swipeDown() }
    }
    XCTAssertTrue(element.exists && element.isHittable, "Could not reveal \(element)")
  }
  private func stateContains(_ value: String, timeout: TimeInterval = 15) {
    let element = app.descendants(matching: .any)["camera-state"].firstMatch
    XCTAssertTrue(NSPredicate(format: "value CONTAINS %@", value).evaluate(with: element)
      || XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", value), object: element)], timeout: timeout) == .completed,
      "Expected \(value); actual \(element.value ?? "missing"); \(app.staticTexts["camera-error"].firstMatch.label)")
  }
  private func narrationContains(_ value: String, timeout: TimeInterval = 10) {
    let element = app.descendants(matching: .any)["narration"].firstMatch
    XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", value), object: element)], timeout: timeout) == .completed,
      "Expected narration \(value); actual \(element.value ?? "missing")")
  }
  private func launchVideo() {
    app.launchEnvironment["MUSE_UI_TEST_VIDEO"] = "museum-ui-fixture.mp4"
    app.launch()
    let start = app.buttons["start-preview"]
    XCTAssertTrue(start.waitForExistence(timeout: 15))
    XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: start)], timeout: 15) == .completed,
      "Video import or SDK initialization failed: \(app.debugDescription)")
    reveal(start); start.tap()
    stateContains("streaming=true", timeout: 30)
    let state = app.descendants(matching: .any)["camera-state"].firstMatch.value as? String ?? ""
    XCTAssertFalse(state.hasPrefix("frames=0;"), "Stream state alone must not pass as video frames")
  }

  func testVideoReplayAndOfflineTour() {
    launchVideo()
    let preview = app.descendants(matching: .any)["mock-display"].firstMatch
    XCTAssertTrue(preview.waitForExistence(timeout: 10))
    let layout = app.buttons["load-layout"]
    reveal(layout, upward: false)
    XCTAssertTrue(layout.isEnabled); layout.tap()
    XCTAssertTrue(app.staticTexts["Offline layout example"].firstMatch.waitForExistence(timeout: 10))
    let point = app.buttons["point-4"]
    reveal(point); point.tap()
    let narration = app.descendants(matching: .any)["narration"].firstMatch
    XCTAssertTrue((narration.value as? String)?.contains("selected=4") == true)
    let rate = app.buttons["speech-rate"]
    reveal(rate, upward: false); rate.tap()
    app.buttons["1.5×"].firstMatch.tap()
    XCTAssertTrue(app.staticTexts["speech-rate-value"].label == "1.5×")
    let captions = app.switches["captions"]
    reveal(captions); XCTAssertEqual(captions.value as? String, "0")
    captions.tap(); XCTAssertEqual(captions.value as? String, "1")
    let end = app.buttons["end-visit"]
    reveal(end); end.tap()
    stateContains("frames=0; streaming=false")
    let replay = app.buttons["replay-video"]
    reveal(replay, upward: false); replay.tap()
    stateContains("streaming=true", timeout: 30)
  }

  func testNoVideoAndSimulatorCameraGuard() {
    app.launch()
    XCTAssertTrue(app.buttons["start-preview"].waitForExistence(timeout: 15))
    XCTAssertFalse(app.buttons["start-preview"].isEnabled)
    XCTAssertFalse(app.buttons["load-layout"].isEnabled)
    app.buttons["input-source"].tap()
    app.buttons["iPhone back camera"].firstMatch.tap()
    let start = app.buttons["start-preview"]
    reveal(start); XCTAssertTrue(start.isEnabled); start.tap()
    let error = app.staticTexts["camera-error"]
    reveal(error)
    XCTAssertTrue(error.label.contains("Simulator has no iPhone camera"))
    stateContains("frames=0; streaming=false")
  }

  func testNativeHUDAndAutomaticTour() {
    launchVideo()
    let layout = app.buttons["load-layout"]
    reveal(layout, upward: false); layout.tap()
    // This transition requires the real speech service's completion delegate,
    // not a mocked timer. It does not establish audible or Bluetooth quality.
    narrationContains("selected=1;", timeout: 45)
    narrationContains("playing=true")
    let pause = app.buttons["toggle-playback"]
    reveal(pause); pause.tap(); narrationContains("playing=false")
    let more = app.buttons["More points ›"]
    reveal(more, upward: false); more.tap()
    let fourth = app.buttons["4. Test point 4"]
    reveal(fourth); fourth.tap(); narrationContains("selected=4;")
    let hud = XCTAttachment(screenshot: app.screenshot())
    hud.lifetime = .keepAlways; hud.name = "Native DAT HUD after point 4 click"
    add(hud)
  }

  func testBackgroundStopReplayAndRealSource() {
    launchVideo()
    XCUIDevice.shared.press(.home)
    app.activate()
    stateContains("frames=0; streaming=false")
    let replay = app.buttons["replay-video"]
    reveal(replay, upward: false); replay.tap()
    stateContains("streaming=true", timeout: 30)
    let source = app.buttons["input-source"]
    reveal(source, upward: false); source.tap()
    app.buttons["Real glasses"].firstMatch.tap()
    stateContains("source=glasses")
    stateContains("frames=0; streaming=false")
    XCTAssertFalse(app.buttons["start-preview"].isEnabled)
    XCTAssertTrue(app.buttons["Register with Meta AI"].exists)
  }

  func testRejectsEmptyVideo() {
    app.launchEnvironment["MUSE_UI_TEST_VIDEO"] = "museum-ui-empty.mp4"
    app.launch()
    let error = app.staticTexts["camera-error"]
    XCTAssertTrue(error.waitForExistence(timeout: 15))
    reveal(error)
    XCTAssertTrue(error.label.contains("empty"))
    XCTAssertFalse(app.buttons["start-preview"].isEnabled)
    stateContains("frames=0; streaming=false")
  }
}
