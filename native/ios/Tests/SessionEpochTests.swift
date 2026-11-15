import Foundation

@main struct SessionEpochTests {
  static func main() {
    var checks = 0
    func check(_ value: @autoclosure () -> Bool, _ message: String) {
      precondition(value(), message); checks += 1
    }
    var session = SessionEpoch()
    check(session.current == nil, "No callback is authorized before a session begins")
    let first = session.begin()
    check(session.accepts(first), "The active session accepts its own callback")

    // Capture an actual queued action before stopping. Deliver it after stop
    // and after restart, exactly where asynchronous SDK handlers can arrive.
    var selections: [Int] = []
    let oldClick = { if session.accepts(first) { selections.append(4) } }
    session.invalidate()
    oldClick()
    check(selections.isEmpty, "A queued HUD click must be inert after stop")
    check(session.current == nil, "Stop releases the active token")
    let second = session.begin()
    oldClick()
    check(selections.isEmpty, "Restart must never reauthorize an old HUD click")
    check(!session.accepts(first), "Old camera/display callbacks stay invalid after restart")
    check(session.accepts(second), "Restart authorizes the new session")
    if session.accepts(second) { selections.append(2) }
    check(selections == [2], "The new session still handles genuine input")

    let third = session.begin()
    check(!session.accepts(second) && session.accepts(third), "Replacing an active session invalidates earlier callbacks")
    session.invalidate(); session.invalidate()
    check(!session.accepts(third), "Repeated release remains safe")
    for _ in 0..<100 {
      let token = session.begin()
      check(session.accepts(token), "Repeated startup accepts the current token")
      check(!session.accepts(first), "Repeated startup cannot revive the original token")
      session.invalidate()
      check(!session.accepts(token), "Every release invalidates its own callbacks")
    }
    let sessionChecks = checks
    var recovery = ArtworkRecoveryState()
    check(recovery.phase == .idle && recovery.lastObservationFrame == -1 && recovery.observationCount == 0,
      "Recovery begins without a pending interruption")
    check(recovery.canAcceptTrackingResults, "Ordinary tracking is authorized while no recovery is pending")
    check(!recovery.begin(frameToken: 1) && !recovery.observe(frameToken: 1) && !recovery.seeded(),
      "No recovery work is authorized before an interruption")
    check(!recovery.acceptTracking(frameToken: 1, fresh: true, detailLocated: true), "Ordinary tracking cannot complete an unstarted recovery")
    recovery.interrupt(afterFrame: 10)
    check(recovery.phase == .waitingForFrame && recovery.lastObservationFrame == 10 && recovery.observationCount == 0,
      "A long gap waits beyond its frozen frame boundary")
    check(!recovery.canAcceptTrackingResults, "Old tracking callbacks are blocked while waiting for recovery frames")
    recovery.interrupt(afterFrame: 20)
    check(recovery.lastObservationFrame == 10 && recovery.phase == .waitingForFrame, "Repeated watchdog events must not requeue or move the boundary")
    check(!recovery.begin(frameToken: 9) && !recovery.begin(frameToken: 10), "A recovery cannot reuse pre-gap frames")
    check(!recovery.observe(frameToken: 11) && !recovery.seeded(), "Waiting is not a search or a seed")
    check(recovery.begin(frameToken: 11), "The first genuinely new frame starts exactly one search")
    check(recovery.phase == .searching && recovery.observationCount == 0 && recovery.lastObservationFrame == 10,
      "Beginning a request does not fabricate an observation")
    check(!recovery.canAcceptTrackingResults, "Old tracking cannot bypass fresh artwork identification during search")
    check(!recovery.begin(frameToken: 12), "More camera frames cannot start parallel searches")
    recovery.interrupt(afterFrame: 30)
    check(recovery.phase == .searching && recovery.lastObservationFrame == 10, "A repeated gap cannot reset an in-flight search budget")
    check(!recovery.observe(frameToken: 10), "Pre-gap responses cannot count as fresh observations")
    check(recovery.observe(frameToken: 11) && recovery.observationCount == 1, "The first search observation consumes one attempt")
    check(!recovery.observe(frameToken: 11) && !recovery.observe(frameToken: 9) && recovery.observationCount == 1,
      "Duplicate and older frames cannot fabricate temporal stability")
    check(!recovery.seeded() && recovery.phase == .searching, "One observation cannot authorize a seed")
    check(recovery.observe(frameToken: 12) && recovery.observationCount == 2, "A distinct second observation can establish a lock")
    check(recovery.seeded() && recovery.phase == .awaitingTracking, "A seed only advances to waiting for tracking")
    check(recovery.canAcceptTrackingResults, "After seeding, fresh tracking results may be evaluated by the age and detail gates")
    check(!recovery.seeded() && !recovery.observe(frameToken: 13) && !recovery.begin(frameToken: 13), "Seeding cannot restart searching or spend more observations")
    check(!recovery.acceptTracking(frameToken: 12, fresh: true, detailLocated: true), "The seed frame itself cannot restore playback")
    check(!recovery.acceptTracking(frameToken: 11, fresh: true, detailLocated: true), "An older frame cannot restore playback")
    check(!recovery.acceptTracking(frameToken: 13, fresh: false, detailLocated: true), "Stale geometry never completes recovery")
    check(!recovery.acceptTracking(frameToken: 13, fresh: true, detailLocated: false), "Fresh artwork tracking without the selected detail is insufficient")
    check(recovery.phase == .awaitingTracking, "Rejected geometry leaves recovery blocked")
    check(recovery.acceptTracking(frameToken: 13, fresh: true, detailLocated: true) && recovery.phase == .idle,
      "Only fresh tracking of the selected detail completes recovery")
    check(recovery.canAcceptTrackingResults, "Successful recovery reauthorizes ordinary tracking")
    check(!recovery.acceptTracking(frameToken: 14, fresh: true, detailLocated: true), "Recovery completes only once")

    recovery.interrupt(afterFrame: 20)
    check(recovery.phase == .waitingForFrame && recovery.observationCount == 0 && recovery.lastObservationFrame == 20,
      "A later interruption starts a new bounded episode after success")
    check(recovery.begin(frameToken: 21), "A new episode waits for its own fresh frame")
    for frame in 21...23 { check(recovery.observe(frameToken: frame), "At most three distinct observations are available") }
    check(!recovery.observe(frameToken: 24) && recovery.observationCount == 3 && recovery.lastObservationFrame == 23,
      "The fourth observation is rejected without moving the accepted frame")
    check(recovery.seeded(), "The third bounded observation may still provide a usable seed")
    recovery.interrupt(afterFrame: 25)
    check(recovery.phase == .failed, "Another interruption before fresh tracking exhausts this recovery")
    check(!recovery.canAcceptTrackingResults && !recovery.acceptTracking(frameToken: 26, fresh: true, detailLocated: true),
      "A late successful tracking callback cannot authorize geometry after recovery failed")
    for frame in 26...30 {
      recovery.interrupt(afterFrame: frame)
      check(!recovery.begin(frameToken: frame) && !recovery.observe(frameToken: frame) && !recovery.seeded() &&
        !recovery.acceptTracking(frameToken: frame, fresh: true, detailLocated: true) && recovery.phase == .failed,
        "A failed episode cannot create a cloud request storm")
    }
    recovery.reset()
    check(recovery.phase == .idle && recovery.lastObservationFrame == -1 && recovery.observationCount == 0,
      "Explicit reset releases both failure and frame history")
    check(recovery.canAcceptTrackingResults, "Reset restores the ordinary tracking policy for a new session")
    recovery.fail()
    check(recovery.phase == .failed, "An explicit search failure latches even before seeding")
    recovery.reset(); recovery.interrupt(afterFrame: 1)
    check(recovery.begin(frameToken: 2), "Reset authorizes a genuinely new recovery attempt")
    recovery.fail()
    check(recovery.phase == .failed && !recovery.begin(frameToken: 3), "A search error also requires an explicit reset")
    print("Passed \(sessionChecks) session-lifetime checks and \(checks - sessionChecks) bounded artwork recovery checks.")
  }
}
