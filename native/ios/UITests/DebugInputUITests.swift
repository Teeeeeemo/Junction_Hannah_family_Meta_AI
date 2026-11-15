import XCTest
import UIKit

/// The offline and real-service tests use the same physical text-entry path.
@MainActor
func textInteractionViewport(in app: XCUIApplication) -> CGRect {
  var viewport = app.windows.firstMatch.frame.inset(by: UIEdgeInsets(top: 64, left: 2, bottom: 38, right: 2))
  let keyboard = app.keyboards.firstMatch
  if keyboard.exists {
    let frame = keyboard.frame
    if frame.intersects(viewport) { viewport.size.height = max(0, min(viewport.maxY, frame.minY) - viewport.minY) }
  }
  return viewport
}

@MainActor
func focusTextFieldWithScreenTouch(_ field: XCUIElement, in app: XCUIApplication) {
  var previous = CGRect.null
  var stableSamples = 0
  let stable = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
    guard field.exists, field.isHittable else { stableSamples = 0; return false }
    let frame = field.frame
    guard !frame.isEmpty, !frame.isInfinite, !frame.isNull, textInteractionViewport(in: app).contains(frame) else {
      stableSamples = 0; return false
    }
    stableSamples = frame == previous ? stableSamples + 1 : 0
    previous = frame
    return stableSamples >= 1
  }, object: nil)
  let result = XCTWaiter.wait(for: [stable], timeout: 5)
  XCTAssertEqual(result, .completed, "Question field must settle onscreen before an actual touch")
  guard result == .completed else { return }
  let frame = field.frame
  app.coordinate(withNormalizedOffset: .zero)
    .withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
  XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5),
    "The actual question-field touch must open the keyboard before typing")
}

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

  func testQuestionFieldAcceptsTextWithoutCloudSubmission() {
    exerciseQuestionField()
  }

  func testQuestionFieldRetainsFocusAcrossHUDRefreshes() {
    app.launchArguments.append("--museum-hud-focus-test")
    exerciseQuestionField(retainAcrossHUDRefreshes: true)
  }

  func testQuestionDoneRestoresDATPreviewAndCallbacks() {
    app.launchArguments.append("--museum-hud-focus-test")
    exerciseQuestionField(retainAcrossHUDRefreshes: true)
    let beforeDoneFrames = cameraCount("frames")
    let done = app.buttons["question-done"]
    reveal(done); tapVisibleCoordinate(done)
    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)], timeout: 5), .completed,
      "Done must end editing and dismiss the keyboard")

    let preview = app.descendants(matching: .any)["mock-display"].firstMatch
    reveal(preview, upward: false)
    let hud = preview.webViews.firstMatch
    XCTAssertTrue(hud.waitForExistence(timeout: 10), "The same actual DAT preview must reattach after Done")
    XCTAssertTrue(hud.buttons["Play"].waitForExistence(timeout: 5), "Restored HUD must show the current paused state")
    let more = hud.buttons["More points ›"]
    reveal(more, upward: false); tapVisibleCoordinate(more)
    let fourth = hud.buttons["4. Test point 4"]
    reveal(fourth); tapVisibleCoordinate(fourth)
    narrationContains("selected=4;")
    XCTAssertTrue(hud.buttons["Pause"].waitForExistence(timeout: 5),
      "A real DAT selection callback must update the restored HUD with the latest playing state")

    // Reuse the same session and SDK view for a second complete editing cycle.
    let field = app.textFields["Ask about this detail"].firstMatch
    reveal(field); focusTextFieldWithScreenTouch(field, in: app)
    let beforeSecondEdit = field.value as? String ?? ""
    let insertion = " Another visible shape."
    field.typeText(insertion)
    let secondEdit = field.value as? String ?? ""
    XCTAssertTrue(secondEdit.contains(insertion))
    XCTAssertEqual(secondEdit.replacingOccurrences(of: insertion, with: ""), beforeSecondEdit)
    retainsQuestionFocus(field, text: secondEdit)
    reveal(done); tapVisibleCoordinate(done)
    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)], timeout: 5), .completed)
    reveal(preview, upward: false)
    let restoredAgain = preview.webViews.firstMatch
    XCTAssertTrue(restoredAgain.waitForExistence(timeout: 10), "Done must restore the SDK view on repeated editing")
    let hudPause = restoredAgain.buttons["Pause"]
    XCTAssertTrue(hudPause.waitForExistence(timeout: 5), "The repeated restore must retain point four's current playing state")
    reveal(hudPause); tapVisibleCoordinate(hudPause)
    narrationContains("selected=4;"); narrationContains("playing=false")
    XCTAssertTrue(restoredAgain.buttons["Play"].waitForExistence(timeout: 5),
      "The real restored DAT Pause callback must publish the latest paused state")
    XCTAssertGreaterThan(cameraCount("frames"), beforeDoneFrames, "Camera frames must continue through preview restoration")
    stateContains("streaming=true"); stateContains("sessionActive=true")
    let error = app.staticTexts["camera-error"].firstMatch
    XCTAssertFalse(error.exists && error.label.lowercased().contains("display"), "Editing must not cause a display error")
    checkpoint("Done restores the live DAT preview and real point selection callbacks")
  }

  private func cameraCount(_ key: String) -> Int64 {
    let state = app.descendants(matching: .any)["camera-state"].firstMatch.value as? String ?? ""
    let prefix = key + "="
    return state.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
      .first { $0.hasPrefix(prefix) }.flatMap { Int64($0.dropFirst(prefix.count)) } ?? -1
  }

  private func retainsQuestionFocus(_ field: XCUIElement, text: String) {
    let before = cameraCount("hudSends"), beforeFrames = cameraCount("frames")
    XCTAssertGreaterThanOrEqual(before, 0, "The actual SDK send counter must be available")
    let lost = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
      !field.exists || !app.keyboards.firstMatch.exists || (field.value as? String) != text
    }, object: nil)
    lost.isInverted = true
    let result = XCTWaiter.wait(for: [lost], timeout: 3)
    let after = cameraCount("hudSends"), afterFrames = cameraCount("frames")
    let evidence = XCTAttachment(string:
      "HUD sends before=\(before); after=\(after); frames before=\(beforeFrames); after=\(afterFrames); keyboard and text retention result=\(result.rawValue)")
    evidence.name = "Question focus across actual HUD sends"
    evidence.lifetime = .keepAlways; add(evidence)
    XCTAssertEqual(result, .completed, "HUD updates must retain the keyboard and the visitor's text")
    XCTAssertGreaterThanOrEqual(after - before, 3, "At least three actual SDK sends must occur during text entry")
    XCTAssertGreaterThanOrEqual(beforeFrames, 0, "The actual frame counter must be available")
    XCTAssertGreaterThan(afterFrames, beforeFrames, "Real camera frames must continue during question editing")
  }

  private func exerciseQuestionField(retainAcrossHUDRefreshes: Bool = false) {
    launchVideo()
    let layout = app.buttons["load-layout"]
    reveal(layout); layout.tap()
    // An offline guide has no backend. Selecting this voice only exposes the
    // normal question form; reconnectVoice refuses to start a cloud session.
    let pause = app.buttons["toggle-playback"]
    reveal(pause); pause.tap(); narrationContains("playing=false")
    selectMenu("Voice source, Offline iOS speech", option: "Gemini Live · Aoede")
    narrationContains("voice=gemini")
    let field = app.textFields["Ask about this detail"].firstMatch
    reveal(field); focusTextFieldWithScreenTouch(field, in: app)
    let question = "Describe the visible colours."
    field.typeText(question)
    XCTAssertEqual(field.value as? String, question)
    if retainAcrossHUDRefreshes { retainsQuestionFocus(field, text: question) }
    reveal(field); focusTextFieldWithScreenTouch(field, in: app)
    let followUp = " And one shape?"
    field.typeText(followUp)
    let edited = field.value as? String ?? ""
    // A real second touch places the caret inside existing text. Verify the
    // inserted characters and preservation of the original, wherever it lands.
    XCTAssertTrue(edited.contains(followUp))
    XCTAssertEqual(edited.replacingOccurrences(of: followUp, with: ""), question)
    if retainAcrossHUDRefreshes { retainsQuestionFocus(field, text: edited) }
    checkpoint("Question field accepts visitor text without submitting or connecting")
  }

  func testPlaybackControlsStayAnchoredWhileWaitingForAudio() {
    launchVideo()
    let layout = app.buttons["load-layout"]
    reveal(layout); layout.tap()
    let pause = app.buttons["toggle-playback"]
    reveal(pause); tapVisibleCoordinate(pause); narrationContains("playing=false")
    selectMenu("Voice source, Offline iOS speech", option: "Gemini Live · Aoede")
    narrationContains("voice=gemini")

    // Demo mode refuses a backend connection, while retaining its current text.
    // Selecting a detail then uses the real Gemini waiting-for-audio path and
    // clears the caption without producing or submitting a network request.
    let narration = app.descendants(matching: .any)["narration"].firstMatch
    let caption = app.staticTexts["current-caption"]
    XCTAssertTrue(caption.exists)
    XCTAssertFalse(caption.label.isEmpty)
    reveal(pause)
    let before = pause.frame.minY - narration.frame.minY
    checkpoint("Playback control position before waiting for audio")

    let first = app.buttons["point-1"]
    reveal(first); tapVisibleCoordinate(first)
    narrationContains("selected=1;")
    narrationContains("voice=gemini")
    reveal(pause, upward: false)
    let after = pause.frame.minY - narration.frame.minY
    let metrics = XCTAttachment(string: "Playback relative y before=\(before); after=\(after)")
    metrics.name = "Playback controls relative to narration card"
    metrics.lifetime = .keepAlways; add(metrics)
    checkpoint("Playback control position while waiting for audio")
    XCTAssertLessThanOrEqual(abs(after - before), 1,
      "Clearing a caption while waiting for audio must not move playback controls within their card")
  }
}
