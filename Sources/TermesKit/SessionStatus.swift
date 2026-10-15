import Foundation

/// Severity behind a tab's status dot; a workspace shows the maximum of its panes.
/// `.idle` = no dot (named so it never collides with `Optional.none`).
public enum SessionStatus: Int, Comparable, Sendable {
  case idle, connected, pending, problem
  public static func < (a: SessionStatus, b: SessionStatus) -> Bool { a.rawValue < b.rawValue }
}

extension SessionManager.State {
  /// Closing or quitting would drop a session the user is using or about to use.
  public var isActive: Bool {
    switch self {
    case .connecting, .needsHostKeyConfirm, .connected, .reconnecting: return true
    case .idle, .failed, .disconnected: return false
    }
  }

  public var status: SessionStatus {
    switch self {
    case .idle: return .idle
    case .connected: return .connected
    case .connecting, .needsHostKeyConfirm, .reconnecting: return .pending
    case .failed, .disconnected: return .problem
    }
  }

  public var displayText: String {
    switch self {
    case .idle: return "未连接"
    case .connecting: return "连接中"
    case .needsHostKeyConfirm: return "等待信任"
    case .connected: return "已连接"
    case .reconnecting: return "重连中"
    case .failed: return "连接失败"
    case .disconnected: return "已断开"
    }
  }
}

/// What a pane shows for its session: the saved-connection name (or "user@host") and the user.
public struct SessionLabel: Equatable, Sendable {
  public var name: String
  public var username: String
  public var profileID: UUID?
  public init(name: String, username: String, profileID: UUID? = nil) {
    self.name = name
    self.username = username
    self.profileID = profileID
  }
}

public enum TabTitle {
  public static func single(name: String?) -> String {
    guard let name, !name.isEmpty else { return "新建连接" }
    return name
  }

  public static func workspace(paneCount: Int) -> String { "工作区 (\(paneCount))" }

  /// The worst status wins; `.idle` when there are no panes.
  public static func aggregate(_ statuses: [SessionStatus]) -> SessionStatus { statuses.max() ?? .idle }
}

/// Pasteboard payload of a dragged tab: the window it came from and the tab's id.
public struct TabDragPayload: Equatable, Sendable {
  public let windowToken: String
  public let tabId: UUID

  public init(windowToken: String, tabId: UUID) {
    self.windowToken = windowToken
    self.tabId = tabId
  }

  public var encoded: String { "\(windowToken)|\(tabId.uuidString)" }

  public init?(encoded: String) {
    let parts = encoded.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2, !parts[0].isEmpty, let id = UUID(uuidString: String(parts[1])) else { return nil }
    self.init(windowToken: String(parts[0]), tabId: id)
  }
}
