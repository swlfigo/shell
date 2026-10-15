import AppKit
import TermesKit
import SSHCore

/// App-wide services shared by every window and pane.
@MainActor
final class AppServices {
  let profiles: ConnectionProfileService
  let snippets: SnippetStore
  let localForwards: LocalForwardStore
  let appearance: AppearanceStore
  let workspace: WorkspaceStore
  let startupDataWarning: String?
  private let knownHosts: KnownHostsStore

  init(directory: URL? = nil, secrets: (any SecretStoring)? = nil, applicationSupportDirectory: URL? = nil) {
    let dir: URL
    if let directory {
      dir = directory
      startupDataWarning = nil
    } else {
      let support = applicationSupportDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      do {
        dir = try ApplicationDataDirectory.prepare(in: support)
        startupDataWarning = nil
      } catch {
        let legacy = ApplicationDataDirectory.legacy(in: support)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: legacy.path, isDirectory: &isDirectory), isDirectory.boolValue {
          dir = legacy
          startupDataWarning = "本次继续使用原有数据目录，下次启动会重试迁移。\n\(error.localizedDescription)"
        } else {
          dir = ApplicationDataDirectory.current(in: support)
          startupDataWarning = "本地数据目录无法迁移或创建，请检查目录及权限。\n\(error.localizedDescription)"
        }
      }
    }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let secrets = secrets ?? LegacyCompatibleSecretStore(
      primary: KeychainSecretStore(service: ApplicationIdentity.credentialService),
      legacy: KeychainSecretStore(service: ApplicationIdentity.legacyCredentialService))
    profiles = ConnectionProfileService(
      connections: ConnectionStore(fileURL: dir.appendingPathComponent("connections.json")),
      keys: KeyStore(fileURL: dir.appendingPathComponent("keys.json")),
      secrets: secrets)
    snippets = SnippetStore(fileURL: dir.appendingPathComponent("snippets.json"))
    localForwards = LocalForwardStore(fileURL: dir.appendingPathComponent("local-forwards.json"))
    appearance = AppearanceStore(fileURL: dir.appendingPathComponent("appearance.json"))
    workspace = WorkspaceStore(fileURL: dir.appendingPathComponent("workspace.json"))
    knownHosts = KnownHostsStore(fileURL: dir.appendingPathComponent("known_hosts.json"))
  }

  /// A fresh session for a new pane; all panes share one known-hosts store.
  func makeSession() -> SessionManager { SessionManager(knownHosts: knownHosts, forwardStore: localForwards) }
}

/// Size constants (spec §3.3).
enum LayoutMetrics {
  static let paneMin = PaneSize(width: 240, height: 140)
  static let divider: Double = 1
  static let windowMin = NSSize(width: 480, height: 320)
  static let tabBarHeight: CGFloat = 38
}
