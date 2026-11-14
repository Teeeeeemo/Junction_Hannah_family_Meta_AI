import XCTest
import UIKit

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

  private var viewport: CGRect {
    // Exclude the status bar/home indicator. WKWebView can report an offscreen
    // DOM button as hittable, so isHittable alone is not a visibility test.
    app.windows.firstMatch.frame.inset(by: UIEdgeInsets(top: 64, left: 2, bottom: 38, right: 2))
  }
  private func fullyVisible(_ element: XCUIElement) -> Bool {
    guard element.exists else { return false }
    let frame = element.frame
    return !frame.isEmpty && !frame.isInfinite && !frame.isNull && viewport.contains(frame)
  }
  private func reveal(_ element: XCUIElement, upward: Bool = true) {
    for _ in 0..<12 {
      if fullyVisible(element) && element.isHittable { return }
      let moveUp = element.exists ? element.frame.midY > viewport.midY : upward
      // The left gutter belongs to the phone ScrollView, outside the embedded
      // DAT WKWebView. A centre-screen swipe can scroll the preview instead.
      let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.025, dy: moveUp ? 0.75 : 0.25))
      let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.025, dy: moveUp ? 0.25 : 0.75))
      start.press(forDuration: 0.01, thenDragTo: end)
    }
    XCTAssertTrue(fullyVisible(element) && element.isHittable,
      "Could not reveal \(element); frame=\(element.frame); viewport=\(viewport)")
  }
  private func checkpoint(_ label: String) {
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = label; screenshot.lifetime = .keepAlways; add(screenshot)
    let tree = XCTAttachment(string: app.debugDescription)
    tree.name = label + " accessibility tree"; tree.lifetime = .keepAlways; add(tree)
  }
  private func tapVisibleCoordinate(_ element: XCUIElement) {
    var previous = CGRect.null
    var stableSamples = 0
    let stable = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
      guard fullyVisible(element) else { stableSamples = 0; return false }
      let frame = element.frame
      stableSamples = frame == previous ? stableSamples + 1 : 0
      previous = frame
      return stableSamples >= 1
    }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [stable], timeout: 5), .completed,
      "Element must settle entirely onscreen before a real touch: \(element)")
    let frame = element.frame
    XCTAssertTrue(viewport.contains(frame))
    // UIKit menu activation-point metadata is invalid on this runtime despite
    // a valid visible frame. This sends an actual screen touch, not a DAT click
    // identifier or a direct call into application state.
    app.coordinate(withNormalizedOffset: .zero)
      .withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
  }
  private func selectMenu(_ identifier: String, option: String) {
    let control = app.buttons[identifier]
    reveal(control); control.tap()
    // Scope to the system menu: the DAT preview also contains a 1× button.
    let item = app.collectionViews.buttons[option].firstMatch
    XCTAssertTrue(item.waitForExistence(timeout: 5), "Missing menu option \(option)")
    tapVisibleCoordinate(item)
    XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"), object: item)], timeout: 5) == .completed,
      "Menu selection did not dismiss \(option)")
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
  private func remainsStopped(for duration: TimeInterval = 2) {
    let state = app.descendants(matching: .any)["camera-state"].firstMatch
    let resumed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      let value = state.value as? String ?? ""
      return !value.contains("frames=0; streaming=false") || !value.contains("sessionActive=false")
    }, object: nil)
    resumed.isInverted = true
    XCTAssertEqual(XCTWaiter.wait(for: [resumed], timeout: duration), .completed,
      "A released session was changed by a late frame/state callback: \(state.value ?? "missing")")
    XCTAssertFalse(app.descendants(matching: .any)["mock-display"].firstMatch.exists)
    XCTAssertFalse(app.descendants(matching: .any)["narration"].firstMatch.exists)
    XCTAssertFalse(app.staticTexts["camera-error"].exists, "Stopped sessions must not receive stale errors")
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
    stateContains("mockPaired=1")
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
    let pause = app.buttons["toggle-playback"]
    reveal(pause); pause.tap(); narrationContains("playing=false")
    for rate in ["1.5×", "0.75×", "1×", "1.25×", "1.75×", "2×"] {
      selectMenu("speech-rate", option: rate)
      XCTAssertEqual(app.staticTexts["speech-rate-value"].label, rate)
      narrationContains("rate=\(rate)")
      narrationContains("selected=4;")
      narrationContains("playing=false")
    }
    checkpoint("All six speech rates selected through the real menu")
    let captions = app.switches["captions"]
    reveal(captions); XCTAssertEqual(captions.value as? String, "0")
    // SwiftUI exposes the whole labelled row as a Switch, with the actual
    // UIKit switch nested at its trailing edge. Touch the visible control;
    // the row's activation point can land on non-interactive label text.
    let captionControl = captions.switches.firstMatch
    XCTAssertTrue(captionControl.exists)
    tapVisibleCoordinate(captionControl); XCTAssertEqual(captions.value as? String, "1")
    let hud = app.webViews.firstMatch
    let caption = hud.staticTexts.matching(NSPredicate(format:
      "label BEGINSWITH %@ OR label BEGINSWITH %@ OR label BEGINSWITH %@",
      "Testing point 4.", "Select another number to interrupt", "This content is not from the current frame.")).firstMatch
    XCTAssertTrue(caption.waitForExistence(timeout: 5))
    reveal(hud)
    checkpoint("Captions enabled in native DAT preview")
    reveal(captions); tapVisibleCoordinate(captionControl); XCTAssertEqual(captions.value as? String, "0")
    XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
      object: caption)], timeout: 5) == .completed)
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
    selectMenu("input-source", option: "iPhone back camera")
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
    reveal(more, upward: false); checkpoint("Native More points is visibly onscreen"); tapVisibleCoordinate(more)
    let fourth = app.buttons["4. Test point 4"]
    reveal(fourth); checkpoint("Native point 4 before actual touch"); tapVisibleCoordinate(fourth); narrationContains("selected=4;")
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
    selectMenu("input-source", option: "Real glasses")
    stateContains("source=glasses")
    stateContains("frames=0; streaming=false")
    stateContains("sessionActive=false")
    stateContains("mockEnabled=false")
    stateContains("mockPaired=0")
    XCTAssertFalse(app.buttons["start-preview"].isEnabled)
    let register = app.buttons["Register with Meta AI"]
    if !register.exists {
      let settings = app.buttons["Connection settings"]
      reveal(settings); settings.tap()
    }
    reveal(register)
    XCTAssertTrue(register.exists)
    remainsStopped()
    selectMenu("input-source", option: "Video replay")
    stateContains("source=video")
    stateContains("mockEnabled=true")
    reveal(app.buttons["start-preview"]); app.buttons["start-preview"].tap()
    stateContains("streaming=true", timeout: 30)
    selectMenu("input-source", option: "iPhone back camera")
    stateContains("source=phoneCamera")
    stateContains("sessionActive=false")
    stateContains("frames=0; streaming=false")
    remainsStopped()
    checkpoint("All input sources switched and active sessions released")
  }

  func testRepeatedStopStartReleasesSessionAndIsolatesLateCallbacks() {
    launchVideo()
    for cycle in 1...3 {
      stateContains("sessionActive=true")
      let layout = app.buttons["load-layout"]
      reveal(layout); layout.tap()
      let point = app.buttons["point-4"]
      reveal(point); point.tap(); narrationContains("selected=4;")
      let end = app.buttons["end-visit"]
      reveal(end); end.tap()
      stateContains("frames=0; streaming=false")
      stateContains("sessionActive=false")
      stateContains("connecting=false")
      stateContains("mockPaired=0")
      remainsStopped()
      checkpoint("Stop cycle \(cycle) releases camera display and narration")
      let replay = app.buttons["replay-video"]
      reveal(replay); replay.tap()
      stateContains("streaming=true", timeout: 30)
      stateContains("sessionActive=true")
      XCTAssertFalse(app.descendants(matching: .any)["narration"].firstMatch.exists,
        "A new session must not inherit a late guide or speech completion")
    }
    let end = app.buttons["end-visit"]
    reveal(end); end.tap(); stateContains("sessionActive=false"); remainsStopped()
  }

  func testInterruptedNarrationCannotAdvanceAfterNewSelectionIsPaused() {
    launchVideo()
    let layout = app.buttons["load-layout"]
    reveal(layout); layout.tap()
    let fourth = app.buttons["point-4"]
    reveal(fourth); fourth.tap(); narrationContains("selected=4;")
    let second = app.buttons["point-2"]
    reveal(second); second.tap(); narrationContains("selected=2;")
    let pause = app.buttons["toggle-playback"]
    reveal(pause); pause.tap(); narrationContains("playing=false")
    let narration = app.descendants(matching: .any)["narration"].firstMatch
    let staleCompletion = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
      let value = narration.value as? String ?? ""
      return !value.contains("selected=2;") || !value.contains("playing=false")
    }, object: nil)
    staleCompletion.isInverted = true
    XCTAssertEqual(XCTWaiter.wait(for: [staleCompletion], timeout: 4), .completed,
      "An interrupted utterance must not advance or resume the paused selection")
    checkpoint("Point 2 remains paused after interrupting point 4")
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
