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
    print("Passed \(checks) session-lifetime checks, including queued old HUD actions after stop/restart.")
  }
}
