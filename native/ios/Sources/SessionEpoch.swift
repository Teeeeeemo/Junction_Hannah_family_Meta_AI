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
