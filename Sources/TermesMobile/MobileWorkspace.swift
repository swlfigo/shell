import Foundation
import Combine
import TermesKit
import SSHCore

enum MobileValidationError: LocalizedError {
  case passwordRequired, keyRequired, invalidKey, profileChanged

  var errorDescription: String? {
    switch self {
    case .passwordRequired: return "请输入登录密码。"
    case .keyRequired: return "请选择已保存的私钥，或导入私钥文件。"
    case .invalidKey: return "无法读取私钥，请检查格式和私钥口令。文件大小不能超过 1 MiB。"
    case .profileChanged: return "主机配置已更新，请从主机列表打开新会话。原会话的终端输出已保留。"
    }
  }
}

struct MobileHostDraft {
  enum Authentication: String, CaseIterable {
    case password = "密码", privateKey = "导入私钥", existingKey = "已存私钥"
  }

  let profileID: UUID?
  var name = ""
  var hostname = ""
  var port = "22"
  var username = "root"
  var jumpProfileID: UUID?
  var replaceCredential = true
  var authentication: Authentication = .password
  var password = ""
  var privateKey = ""
  var keyName = ""
  var passphrase = ""
  var existingKeyID: UUID?

  init(profile: ConnectionProfile? = nil) {
    profileID = profile?.id
    if let profile {
      name = profile.name; hostname = profile.hostname
      port = String(profile.port); username = profile.username
      jumpProfileID = profile.jumpProfileId; replaceCredential = false
      if case .privateKey(let id, _) = profile.auth {
        authentication = .existingKey; existingKeyID = id
      }
    }
  }

  var hasValidAddress: Bool {
    [name, hostname, username].allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      && Int(port).map { (1...65535).contains($0) } == true
  }

  func credential() throws -> NewCredential? {
    guard replaceCredential else { return nil }
    switch authentication {
    case .password:
      guard !password.isEmpty else { throw MobileValidationError.passwordRequired }
      return .password(password)
    case .existingKey:
      guard let existingKeyID else { throw MobileValidationError.keyRequired }
      return .existingKey(existingKeyID)
    case .privateKey:
      let data = Data(privateKey.utf8)
      let phrase = passphrase.isEmpty ? nil : passphrase
      guard !data.isEmpty, data.count <= 1_048_576,
            PrivateKeyIdentity.inspect(data, passphrase: phrase) != nil else {
        throw MobileValidationError.invalidKey
      }
      return .privateKey(data: data, name: keyName.isEmpty ? "\(name) 私钥" : keyName, passphrase: phrase)
    }
  }
}

/// A session owns its terminal independently of controller navigation and view recreation.
@MainActor
final class MobileSession: Identifiable {
  let id = UUID()
  let profileID: UUID
  let profile: ConnectionProfile
  let name: String
  let address: String
  let manager: SessionManager
  lazy var terminalController = MobileTerminalController(manager: manager)
  private var connectionTask: Task<Void, Never>?

  init(profile: ConnectionProfile, manager: SessionManager) {
    self.profile = profile
    profileID = profile.id; name = profile.name
    address = "\(profile.username)@\(profile.hostname):\(profile.port)"
    self.manager = manager
  }

  func connect(_ config: ConnectionConfig) {
    guard !manager.state.isActive else { return }
    // Install the output consumer before starting the transport, even while off screen.
    terminalController.loadViewIfNeeded()
    connectionTask?.cancel()
    connectionTask = Task { [manager] in
      guard !Task.isCancelled else { return }
      await manager.connect(config)
    }
  }

  func disconnect() {
    connectionTask?.cancel(); connectionTask = nil
    manager.disconnect()
    terminalController.hideKeyboard()
  }

  func close() {
    disconnect()
    manager.serverMonitor.close()
    terminalController.shutdown()
  }
}

@MainActor
final class MobileWorkspace: ObservableObject {
  let profiles: ConnectionProfileService
  let appearance: AppearanceStore
  private let knownHosts: KnownHostsStore
  private let forwards: LocalForwardStore
  private var profileChanges: AnyCancellable?
  @Published private(set) var hosts: [ConnectionProfile] = []
  @Published private(set) var keys: [SSHKey] = []
  @Published private(set) var sessions: [MobileSession] = []
  @Published var selectedSessionID: UUID?
  @Published var error: String?

  init(directory: URL? = nil, secrets: (any SecretStoring)? = nil) {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let dir = directory ?? ApplicationDataDirectory.current(in: support)
    var startupError: String?
    do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    catch { startupError = "无法创建本地数据目录：\(error.localizedDescription)" }
    profiles = ConnectionProfileService(
      connections: ConnectionStore(fileURL: dir.appendingPathComponent("connections.json")),
      keys: KeyStore(fileURL: dir.appendingPathComponent("keys.json")),
      secrets: secrets ?? KeychainSecretStore(service: ApplicationIdentity.credentialService))
    appearance = AppearanceStore(fileURL: dir.appendingPathComponent("appearance.json"))
    knownHosts = KnownHostsStore(fileURL: dir.appendingPathComponent("known_hosts.json"))
    forwards = LocalForwardStore(fileURL: dir.appendingPathComponent("local-forwards.json"))
    reloadHosts()
    if let startupError { error = startupError }
    profileChanges = profiles.didChange.sink { [weak self] in self?.reloadHosts() }
  }

  var selectedSession: MobileSession? { sessions.first { $0.id == selectedSessionID } }

  func reloadHosts() {
    do { hosts = try profiles.profiles(); keys = try profiles.keys() }
    catch { self.error = error.localizedDescription }
  }

  @discardableResult
  func save(_ draft: MobileHostDraft) throws -> ConnectionProfile {
    guard draft.hasValidAddress, let port = Int(draft.port) else { throw ProfileServiceError.invalidConnection }
    let credential = try draft.credential()
    let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let hostname = draft.hostname.trimmingCharacters(in: .whitespacesAndNewlines)
    let username = draft.username.trimmingCharacters(in: .whitespacesAndNewlines)
    if let id = draft.profileID {
      var profile = try profiles.updateConnection(id, name: name, hostname: hostname, port: port,
        username: username, jumpProfileId: draft.jumpProfileID)
      if let credential { profile = try profiles.updateCredential(for: id, credential: credential) }
      return profile
    }
    guard let credential else { throw ProfileServiceError.credentialMissing }
    return try profiles.saveConnection(name: name, hostname: hostname, port: port, username: username,
      credential: credential, jumpProfileId: draft.jumpProfileID)
  }

  func delete(_ profile: ConnectionProfile) {
    do { try profiles.deleteConnection(profile.id) }
    catch { self.error = error.localizedDescription }
  }

  @discardableResult
  func open(_ profile: ConnectionProfile, newSession: Bool = false) -> MobileSession? {
    do {
      let config = try profiles.makeConfig(for: profile.id)
      if !newSession, let existing = sessions.last(where: {
        $0.profile == profile && (!$0.manager.state.isActive || $0.manager.currentConfig == config)
      }) {
        selectedSessionID = existing.id
        if !existing.manager.state.isActive { existing.connect(config) }
        return existing
      }
      let session = MobileSession(profile: profile,
        manager: SessionManager(knownHosts: knownHosts, forwardStore: forwards))
      sessions.append(session); selectedSessionID = session.id
      session.connect(config)
      return session
    } catch { self.error = error.localizedDescription; return nil }
  }

  func reconnect(_ session: MobileSession) {
    do {
      guard let current = try profiles.profiles().first(where: { $0.id == session.profileID }) else {
        throw ProfileServiceError.profileNotFound
      }
      guard current == session.profile else { throw MobileValidationError.profileChanged }
      session.connect(try profiles.makeConfig(for: session.profileID))
    }
    catch { self.error = error.localizedDescription }
  }

  func close(_ session: MobileSession) {
    guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
    session.close(); sessions.remove(at: index)
    if selectedSessionID == session.id {
      selectedSessionID = sessions.isEmpty ? nil : sessions[min(index, sessions.count - 1)].id
    }
  }
}
