import Foundation

enum DebugInputMode: String, CaseIterable, Sendable {
  case glasses, phoneCamera, video
  var isMock: Bool { self != .glasses }
  var needsVideo: Bool { self == .video }
  static func initial(stored: String?, simulator: Bool) -> Self {
    stored.flatMap(Self.init(rawValue:)) ?? (simulator ? .video : .glasses)
  }
}

enum DebugInputPolicy {
  static func canStart(mode: DebugInputMode, sdkReady: Bool, backendReady: Bool,
    registered: Bool, videoReady: Bool) -> Bool {
    guard sdkReady else { return false }
    switch mode {
    case .glasses: return backendReady && registered
    case .phoneCamera: return true
    case .video: return videoReady
    }
  }
}
