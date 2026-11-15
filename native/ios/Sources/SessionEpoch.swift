import Foundation

/// Authorizes asynchronous work for exactly one active device session.
/// Tokens are opaque so an old task cannot infer or recreate a new lifetime.
struct SessionEpoch: Sendable {
  struct Token: Equatable, Sendable { fileprivate let id = UUID() }
  private(set) var current: Token?
  mutating func begin() -> Token {
    let token = Token(); current = token; return token
  }
  mutating func invalidate() { current = nil }
  func accepts(_ token: Token) -> Bool { current == token }
}

/// Bounds one recovery episode. Identity validation and asynchronous task
/// lifetimes belong to the caller; a seed never authorizes visible geometry.
struct ArtworkRecoveryState: Sendable {
  enum Phase: Sendable { case idle, waitingForFrame, searching, awaitingTracking, failed }
  private(set) var phase: Phase = .idle
  private(set) var lastObservationFrame = -1
  private(set) var observationCount = 0
  var canAcceptTrackingResults: Bool { phase == .idle || phase == .awaitingTracking }
  mutating func interrupt(afterFrame: Int) {
    switch phase {
    case .idle:
      phase = .waitingForFrame; lastObservationFrame = afterFrame; observationCount = 0
    case .awaitingTracking: phase = .failed
    case .waitingForFrame, .searching, .failed: break
    }
  }
  mutating func begin(frameToken: Int) -> Bool {
    guard phase == .waitingForFrame, frameToken > lastObservationFrame else { return false }
    phase = .searching; return true
  }
  mutating func observe(frameToken: Int) -> Bool {
    guard phase == .searching, frameToken > lastObservationFrame, observationCount < 3 else { return false }
    lastObservationFrame = frameToken; observationCount += 1; return true
  }
  mutating func seeded() -> Bool {
    guard phase == .searching, observationCount >= 2 else { return false }
    phase = .awaitingTracking; return true
  }
  mutating func acceptTracking(frameToken: Int, fresh: Bool, detailLocated: Bool) -> Bool {
    guard phase == .awaitingTracking, frameToken > lastObservationFrame, fresh, detailLocated else { return false }
    phase = .idle; return true
  }
  mutating func fail() { phase = .failed }
  mutating func reset() { self = ArtworkRecoveryState() }
}
