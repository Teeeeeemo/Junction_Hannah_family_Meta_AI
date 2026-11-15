import XCTest

/// Opt-in paid service acceptance: real DAT-decoded public artwork video,
/// HTTPS backend, Gemini search/ROI and native PCM playback. No microphone.
@MainActor
final class CloudIntegrationUITests: XCTestCase {
  private var app: XCUIApplication!
  private var observedState = ""
  private var observedCameraState = ""
  override func setUpWithError() throws {
    try super.setUpWithError()
    guard ProcessInfo.processInfo.environment["MUSE_CLOUD_TEST"] == "1" else {
      throw XCTSkip("Run scripts/test-ios-cloud.sh explicitly for real Gemini acceptance.")
    }
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments = ["--museum-ui-test", "--museum-cloud-test", "-museum.debugInput", "video"]
    app.launchEnvironment["MUSE_UI_TEST_VIDEO"] = "museum-cloud-artwork.mp4"
    app.launchEnvironment["MUSE_UI_TEST_INPUT_STALL"] = "1"
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
  private func integer(_ key: String, from value: String? = nil, missing: Int64 = 0) -> Int64 {
    let prefix = key + "="
    return (value ?? state).split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
      .first { $0.hasPrefix(prefix) }.flatMap { Int64($0.dropFirst(prefix.count)) } ?? missing
  }
  private func wait(_ description: String, timeout: TimeInterval = 60, _ condition: @escaping () -> Bool) {
    let predicate = NSPredicate { _, _ in condition() }
    let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: timeout)
    // Failure diagnostics must not perform another potentially stuck AX query.
    XCTAssertEqual(result, .completed,
      "\(description); last observed state=\(observedState); camera state=\(observedCameraState)")
  }
  private func reveal(_ element: XCUIElement, upward: Bool = true) {
    for _ in 0..<14 {
      let viewport = textInteractionViewport(in: app)
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
    // No Next/skip/point click: real overview completion must select point one.
    wait("Real overview naturally completes and automatically selects point one", timeout: 90) {
      self.state.contains("selected=1;")
    }
    let automatic = XCTAttachment(string: state)
    automatic.name = "Overview naturally completed and selected point one without a tap"
    automatic.lifetime = .keepAlways; add(automatic)
    // Take this after observing point one: intro PCM cannot satisfy this gate.
    let beforePoint = integer("livePlayed")
    wait("Automatically selected detail actually plays native PCM", timeout: 90) {
      let narration = self.state
      return narration.contains("selected=1;") && self.integer("livePlayed", from: narration) > beforePoint
    }
    let firstSelectedPlayback = integer("livePlayed")

    // Preserve the original point-one recovery and post-recovery audio gates.
    wait("Selected detail is playing before pause") { self.state.contains("playing=true") }
    // Demo continuity (0.2.2): the interruption hides geometry but does not
    // silence narration, so the automatic tour may advance past point one
    // while the same artwork is re-verified in the background.
    wait("Controlled input interruption recovers tracking while native narration keeps playing", timeout: 90) {
      self.observedCameraState = self.app.descendants(matching: .any)["camera-state"].firstMatch.value as? String ?? "missing"
      let camera = self.observedCameraState, narration = self.state
      let gapBaseline = self.integer("gapBaseline", from: camera, missing: -1)
      let recoveredPCMBase = self.integer("recoveredPCMBase", from: camera, missing: -1)
      let played = self.integer("livePlayed", from: narration)
      return camera.contains("injectedGap=true") && gapBaseline >= 0
        && self.integer("recoveries", from: camera) > gapBaseline
        && camera.contains("recovery=idle") && narration.contains("voice=gemini")
        && narration.contains("awaitingContinue=false") && recoveredPCMBase >= 0
        && played > recoveredPCMBase && played > firstSelectedPlayback
    }
    let cameraState = observedCameraState
    let recoveredCamera = XCTAttachment(string: cameraState)
    recoveredCamera.name = "Camera recovery counters after selected detail playback"
    recoveredCamera.lifetime = .keepAlways; add(recoveredCamera)
    let selectedPlayback = XCTAttachment(string: state)
    selectedPlayback.name = "Selected detail actual PCM playback before pause"
    selectedPlayback.lifetime = .keepAlways; add(selectedPlayback)
    XCTAssertGreaterThan(integer("recoveries", from: cameraState), integer("gapBaseline", from: cameraState, missing: -1),
      "The controlled input interruption must complete real reidentification and fresh Vision tracking; camera state=\(cameraState)")
    // The tour may already have finished its last point; only pause if playing.
    if state.contains("playing=true") { reveal(pause); pause.tap() }
    wait("Phone pauses the automatic tour before a manual selection") { self.state.contains("playing=false") }

    let second = app.buttons["point-2"]
    let beforeSecondDetail = integer("livePlayed")
    reveal(second); second.tap()
    wait("Phone actually changes from point one to point two") { self.state.contains("selected=2;") }
    wait("Manually selected point two actually plays native PCM", timeout: 90) {
      let narration = self.state
      return narration.contains("selected=2;") && narration.contains("playing=true")
        && narration.contains("locationBlocked=false") && self.integer("livePlayed", from: narration) > beforeSecondDetail
    }
    let changedPoint = XCTAttachment(string: state)
    changedPoint.name = "Phone changed to point two and played its actual native PCM"
    changedPoint.lifetime = .keepAlways; add(changedPoint)
    reveal(pause); pause.tap()
    wait("Manually selected point two paused before question") { self.state.contains("playing=false") }
    XCTAssertTrue(state.contains("selected=2;"), "The question must start from paused point two")

    // A question starts a fresh answer even when the visitor paused narration.
    let field = app.textFields["Ask about this detail"].firstMatch
    reveal(field); focusTextFieldWithScreenTouch(field, in: app)
    let beforeAnswer = integer("livePlayed")
    field.typeText("Describe the visible colours of this detail in one short sentence.\n")
    wait("Question after pause plays audio and waits for continue", timeout: 90) {
      self.integer("livePlayed") > beforeAnswer && self.state.contains("awaitingContinue=true") && self.state.contains("playing=false")
    }
    XCTAssertTrue(state.contains("selected=2;"), "Question must retain the manually selected point two")
    XCTAssertTrue(app.webViews.firstMatch.buttons["Play"].waitForExistence(timeout: 5),
      "The first submitted question must restore the actual DAT HUD for Continue")
    let firstAnswer = XCTAttachment(string: state)
    firstAnswer.name = "First question after pause played and waits for Continue"
    firstAnswer.lifetime = .keepAlways; add(firstAnswer)

    let beforeContinue = integer("livePlayed")
    reveal(pause); pause.tap()
    wait("Continue resumes the same detail with actual PCM", timeout: 90) {
      let narration = self.state
      return narration.contains("awaitingContinue=false") && narration.contains("selected=2;")
        && narration.contains("playing=true") && self.integer("livePlayed", from: narration) > beforeContinue
    }
    let continued = XCTAttachment(string: state)
    continued.name = "Continue resumed selected detail with actual PCM"
    continued.lifetime = .keepAlways; add(continued)

    reveal(field); focusTextFieldWithScreenTouch(field, in: app)
    let beforeSecondAnswer = integer("livePlayed")
    field.typeText("Which visible shape stands out in this detail?\n")
    wait("Second question plays actual PCM and waits for Continue", timeout: 90) {
      let narration = self.state
      return self.integer("livePlayed", from: narration) > beforeSecondAnswer
        && narration.contains("awaitingContinue=true") && narration.contains("playing=false")
    }
    XCTAssertTrue(state.contains("selected=2;"), "The second question must retain the manually selected point two")
    XCTAssertTrue(app.webViews.firstMatch.buttons["Play"].waitForExistence(timeout: 5),
      "The second submitted question must restore the actual DAT HUD for Continue")
    let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !self.state.contains("selected=2;") }, object: nil)
    changed.isInverted = true
    XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 3), .completed, "Question must not auto-advance")
    let final = XCTAttachment(string: state); final.name = "Second question finished and retained current point"; final.lifetime = .keepAlways; add(final)
  }
}
