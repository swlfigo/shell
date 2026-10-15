import Foundation

/// Only non-secret connection information can enter a workspace file.
public struct ConnectionDraft: Codable, Equatable, Sendable {
  public enum Authentication: String, Codable, Sendable { case password, privateKey }
  public var profileID: UUID?
  public var name: String
  public var hostname: String
  public var port: String
  public var username: String
  public var authentication: Authentication
  public var keyID: UUID?
  public var jumpProfileID: UUID?

  public init(profileID: UUID? = nil, name: String = "", hostname: String = "", port: String = "22",
              username: String = "", authentication: Authentication = .password,
              keyID: UUID? = nil, jumpProfileID: UUID? = nil) {
    self.profileID = profileID; self.name = name; self.hostname = hostname; self.port = port
    self.username = username; self.authentication = authentication; self.keyID = keyID
    self.jumpProfileID = jumpProfileID
  }

  public init(profile: ConnectionProfile) {
    self.init(profileID: profile.id, name: profile.name, hostname: profile.hostname,
              port: String(profile.port), username: profile.username, jumpProfileID: profile.jumpProfileId)
    if case .privateKey(let id, _) = profile.auth { authentication = .privateKey; keyID = id }
  }
}

public struct WorkspacePane: Codable, Equatable, Sendable {
  public var id: UUID
  public var connection: ConnectionDraft
  public init(id: UUID, connection: ConnectionDraft) { self.id = id; self.connection = connection }
}

public struct WorkspaceFrame: Codable, Equatable, Sendable {
  public var x: Double
  public var y: Double
  public var width: Double
  public var height: Double
  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x; self.y = y; self.width = width; self.height = height
  }
}

public struct WorkspaceWindow: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public var layout: WindowLayout
  public var panes: [WorkspacePane]
  public var frame: WorkspaceFrame?
  public var sidebarVisible: Bool
  public init(id: UUID = UUID(), layout: WindowLayout, panes: [WorkspacePane],
              frame: WorkspaceFrame? = nil, sidebarVisible: Bool = true) {
    self.id = id; self.layout = layout; self.panes = panes; self.frame = frame; self.sidebarVisible = sidebarVisible
  }
}

public struct WorkspaceSnapshot: Codable, Equatable, Sendable {
  public var version: Int
  public var windows: [WorkspaceWindow]
  public var selectedWindowID: UUID?
  public init(windows: [WorkspaceWindow], selectedWindowID: UUID? = nil, version: Int = 1) {
    self.version = version; self.windows = windows; self.selectedWindowID = selectedWindowID
  }

  public func validate() throws {
    guard version == 1 else { throw WorkspaceStoreError.unsupportedVersion }
    guard windows.count <= 64, Set(windows.map(\.id)).count == windows.count,
          selectedWindowID == nil || windows.contains(where: { $0.id == selectedWindowID }) else {
      throw WorkspaceStoreError.invalidSnapshot
    }
    var paneIDs = Set<UUID>(), tabIDs = Set<UUID>(), splitIDs = Set<UUID>()
    func validateNode(_ node: PaneNode, parent: SplitAxis? = nil, depth: Int = 0) throws {
      guard depth <= 32 else { throw WorkspaceStoreError.invalidSnapshot }
      switch node {
      case .pane(let id):
        guard paneIDs.insert(id).inserted, paneIDs.count <= 2048 else { throw WorkspaceStoreError.invalidSnapshot }
      case .split(let id, let axis, let children, let fractions):
        guard splitIDs.insert(id).inserted, children.count >= 2, children.count <= 2048,
              children.count == fractions.count, axis != parent,
              fractions.allSatisfy({ $0.isFinite && $0 > 0 }),
              abs(fractions.reduce(0, +) - 1) <= 1e-9 else { throw WorkspaceStoreError.invalidSnapshot }
        for child in children { try validateNode(child, parent: axis, depth: depth + 1) }
      }
    }
    for window in windows {
      let layout = window.layout
      guard layout.tabs.count <= 256,
            layout.tabs.isEmpty ? layout.selectedTabId == nil : layout.tabs.contains(where: { $0.id == layout.selectedTabId }) else {
        throw WorkspaceStoreError.invalidSnapshot
      }
      for tab in layout.tabs {
        guard tabIDs.insert(tab.id).inserted else { throw WorkspaceStoreError.invalidSnapshot }
        try validateNode(tab.root)
        guard tab.paneIds.contains(tab.focusedPane),
              tab.maximizedPane == nil || (tab.isWorkspace && tab.paneIds.contains(tab.maximizedPane!)) else {
          throw WorkspaceStoreError.invalidSnapshot
        }
      }
      guard window.panes.count == layout.allPaneIds.count,
            Set(window.panes.map(\.id)) == Set(layout.allPaneIds) else { throw WorkspaceStoreError.invalidSnapshot }
      for pane in window.panes {
        let c = pane.connection
        guard [c.name, c.hostname, c.username, c.port].allSatisfy({ $0.utf8.count <= 4096 && !$0.contains("\0") }) else {
          throw WorkspaceStoreError.invalidSnapshot
        }
      }
      if let f = window.frame {
        guard [f.x, f.y, f.width, f.height].allSatisfy(\.isFinite),
              abs(f.x) <= 1_000_000, abs(f.y) <= 1_000_000,
              (100...100_000).contains(f.width), (100...100_000).contains(f.height) else {
          throw WorkspaceStoreError.invalidSnapshot
        }
      }
    }
  }
}

public enum WorkspaceStoreError: LocalizedError {
  case invalidSnapshot, unsupportedVersion, protectedFile
  public var errorDescription: String? {
    switch self {
    case .invalidSnapshot: return "工作区数据无效或超过支持的大小。"
    case .unsupportedVersion: return "工作区来自暂不支持的版本。"
    case .protectedFile: return "原工作区无法读取，已保留原文件；可在窗口菜单中重新保存工作区。"
    }
  }
}

/// Failed reads protect the original file until the user explicitly saves a new workspace.
@MainActor
public final class WorkspaceStore {
  public private(set) var snapshot: WorkspaceSnapshot?
  public private(set) var error: String?
  public private(set) var isWriteProtected = false
  private let fileURL: URL
  private static let maximumBytes = 4 * 1024 * 1024

  public init(fileURL: URL) {
    self.fileURL = fileURL
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
    do {
      let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      guard size <= Self.maximumBytes else { throw WorkspaceStoreError.invalidSnapshot }
      let data = try Data(contentsOf: fileURL)
      guard data.count <= Self.maximumBytes else { throw WorkspaceStoreError.invalidSnapshot }
      let value = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
      try value.validate(); snapshot = value
    } catch {
      isWriteProtected = true
      self.error = "工作区恢复失败，原数据已保留。本次打开空白窗口。\n\(error.localizedDescription)"
    }
  }

  public func save(_ value: WorkspaceSnapshot) throws {
    guard !isWriteProtected else { throw WorkspaceStoreError.protectedFile }
    do {
      try value.validate()
      let data = try JSONEncoder().encode(value)
      guard data.count <= Self.maximumBytes else { throw WorkspaceStoreError.invalidSnapshot }
      try data.write(to: fileURL, options: [.atomic])
      snapshot = value; error = nil
    } catch { self.error = "工作区保存失败：\(error.localizedDescription)"; throw error }
  }

  /// Preserve an unreadable file as a sibling backup before allowing automatic saves again.
  public func preserveUnreadableFile() throws {
    guard isWriteProtected else { return }
    if FileManager.default.fileExists(atPath: fileURL.path) {
      let backup = fileURL.deletingLastPathComponent().appendingPathComponent("workspace-backup-\(UUID().uuidString).json")
      try FileManager.default.copyItem(at: fileURL, to: backup)
    }
    isWriteProtected = false
  }
}
