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
  let id: UUID
  let profileID: UUID
  let profile: ConnectionProfile
  let name: String
  let address: String
  let manager: SessionManager
  lazy var terminalController = MobileTerminalController(manager: manager)
  private var connectionTask: Task<Void, Never>?
  private var stateChange: AnyCancellable?
  private(set) var fileBrowser: FileBrowserModel?
  private(set) var hasConnected = false
  var hasUnfinishedWork: Bool {
    manager.state.isActive || fileBrowser?.transfers.jobs.contains(where: { ![.completed, .cancelled].contains($0.state) }) == true
  }

  init(id: UUID = UUID(), profile: ConnectionProfile, manager: SessionManager) {
    self.id = id
    self.profile = profile
    profileID = profile.id; name = profile.name
    address = "\(profile.username)@\(profile.hostname):\(profile.port)"
    self.manager = manager
    stateChange = manager.$state.sink { [weak self] state in
      if state == .connected { self?.hasConnected = true }
      self?.fileBrowser?.setConnected(state == .connected)
    }
  }

  func files() -> FileBrowserModel {
    if let fileBrowser { return fileBrowser }
    let browser = FileBrowserModel { [weak manager] in
      guard let manager else { throw SFTPError.notConnected }
      return try await manager.openSFTP()
    }
    browser.setConnected(manager.state == .connected)
    fileBrowser = browser
    return browser
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
    fileBrowser?.shutdown()
    disconnect()
    manager.serverMonitor.close()
    terminalController.shutdown()
  }
}

@MainActor
final class MobileWorkspace: ObservableObject {
  let windowID: UUID
  private let dataDirectory: URL
  let profiles: ConnectionProfileService
  let appearance: AppearanceStore
  let snippets: SnippetStore
  private let knownHosts: KnownHostsStore
  let forwards: LocalForwardStore
  private let workspaceStore: WorkspaceStore
  private var offlineForwards: [LocalForwardDestination: LocalForwardManager] = [:]
  private var isRestoring = false
  private var profileChanges: AnyCancellable?
  @Published private(set) var hosts: [ConnectionProfile] = []
  @Published private(set) var keys: [SSHKey] = []
  @Published private(set) var sessions: [MobileSession] = []
  @Published private(set) var layout = WindowLayout()
  @Published var selectedSessionID: UUID? {
    didSet {
      if let id = selectedSessionID, let tab = layout.tab(containing: id) {
        layout.select(tab: tab.id); layout.focus(pane: id)
      }
      persistWorkspace()
    }
  }
  @Published var error: String?

  init(directory: URL? = nil, secrets: (any SecretStoring)? = nil,
       sharing source: MobileWorkspace? = nil, windowID: UUID? = nil) {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let dir = directory ?? source?.dataDirectory ?? ApplicationDataDirectory.current(in: support)
    dataDirectory = dir
    var startupError: String?
    do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    catch { startupError = "无法创建本地数据目录：\(error.localizedDescription)" }
    profiles = source?.profiles ?? ConnectionProfileService(
      connections: ConnectionStore(fileURL: dir.appendingPathComponent("connections.json")),
      keys: KeyStore(fileURL: dir.appendingPathComponent("keys.json")),
      secrets: secrets ?? KeychainSecretStore(service: ApplicationIdentity.credentialService))
    appearance = source?.appearance ?? AppearanceStore(fileURL: dir.appendingPathComponent("appearance.json"))
    knownHosts = source?.knownHosts ?? KnownHostsStore(fileURL: dir.appendingPathComponent("known_hosts.json"))
    forwards = source?.forwards ?? LocalForwardStore(fileURL: dir.appendingPathComponent("local-forwards.json"))
    snippets = source?.snippets ?? SnippetStore(fileURL: dir.appendingPathComponent("snippets.json"))
    workspaceStore = source?.workspaceStore ?? WorkspaceStore(fileURL: dir.appendingPathComponent("workspace.json"))
    self.windowID = windowID ?? workspaceStore.snapshot?.selectedWindowID ?? workspaceStore.snapshot?.windows.first?.id ?? UUID()
    reloadHosts()
    restoreWorkspace()
    if let message = workspaceStore.error { error = message }
    if let startupError { error = startupError }
    profileChanges = profiles.didChange.sink { [weak self] in self?.reloadHosts() }
  }

  var selectedSession: MobileSession? { sessions.first { $0.id == selectedSessionID } }

  func selectTab(at index: Int) {
    guard layout.tabs.indices.contains(index) else { return }
    selectedSessionID = layout.tabs[index].focusedPane
  }

  func cycleTab(by offset: Int) {
    guard !layout.tabs.isEmpty, let index = layout.tabs.firstIndex(where: { $0.id == layout.selectedTabId }) else { return }
    selectTab(at: (index + offset % layout.tabs.count + layout.tabs.count) % layout.tabs.count)
  }

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
      guard let profile = try profiles.profiles().first(where: { $0.id == profile.id }) else {
        throw ProfileServiceError.profileNotFound
      }
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
      sessions.append(session)
      layout.addTab(pane: session.id)
      selectedSessionID = session.id
      session.connect(config)
      return session
    } catch { self.error = error.localizedDescription; return nil }
  }

  @discardableResult
  func duplicate(_ session: MobileSession) -> MobileSession? {
    if let config = session.manager.currentConfig {
      let copy = MobileSession(profile: session.profile,
        manager: SessionManager(knownHosts: knownHosts, forwardStore: forwards))
      sessions.append(copy); layout.addTab(pane: copy.id); selectedSessionID = copy.id
      copy.connect(config)
      return copy
    }
    guard hosts.first(where: { $0.id == session.profileID }) == session.profile else {
      error = MobileValidationError.profileChanged.localizedDescription; return nil
    }
    return open(session.profile, newSession: true)
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
    layout.close(pane: session.id)
    if selectedSessionID == session.id {
      selectedSessionID = layout.selectedTab?.focusedPane
    }
    persistWorkspace()
  }

  func forwardingManager(for profile: ConnectionProfile) async throws -> LocalForwardManager {
    let destination = try profiles.forwardingDestination(for: profile.id)
    if let live = sessions.last(where: { $0.manager.portForwards.destination == destination && $0.manager.state == .connected }) {
      return live.manager.portForwards
    }
    if let existing = offlineForwards[destination] { return existing }
    let manager = LocalForwardManager(store: forwards) { _ in throw LocalForwardError.notConnected }
    offlineForwards[destination] = manager
    await manager.bindDestination(destination)
    return manager
  }

  func merge(_ source: MobileSession, beside target: MobileSession, edge: PaneEdge) {
    guard let tab = layout.tab(containing: source.id), !tab.isWorkspace,
          layout.merge(tab: tab.id, into: target.id, edge: edge) else { return }
    selectedSessionID = source.id
  }

  func detach(_ session: MobileSession) {
    guard let tab = layout.detach(pane: session.id) else { return }
    layout.select(tab: tab); selectedSessionID = session.id
  }

  func toggleMaximize(_ session: MobileSession) {
    layout.toggleMaximize(pane: session.id); persistWorkspace()
  }

  func setFractions(_ fractions: [Double], split: UUID) {
    layout.setFractions(fractions, split: split); persistWorkspace()
  }

  func transfer(_ session: MobileSession, to destination: MobileWorkspace) {
    guard destination !== self, sessions.contains(where: { $0 === session }),
          !destination.sessions.contains(where: { $0.id == session.id }) else { return }
    sessions.removeAll { $0.id == session.id }; layout.close(pane: session.id)
    if selectedSessionID == session.id { selectedSessionID = layout.selectedTab?.focusedPane }
    persistWorkspace()
    destination.sessions.append(session); destination.layout.addTab(pane: session.id)
    destination.selectedSessionID = session.id
  }

  func discardWindow() {
    for session in sessions { close(session) }
    guard let snapshot = workspaceStore.snapshot else { return }
    let windows = snapshot.windows.filter { $0.id != windowID }
    do { try workspaceStore.save(WorkspaceSnapshot(windows: windows, selectedWindowID: windows.first?.id)) }
    catch { self.error = error.localizedDescription }
  }

  func persistWorkspace(replacingUnreadable: Bool = false) {
    guard !isRestoring else { return }
    do {
      if replacingUnreadable { try workspaceStore.preserveUnreadableFile() }
      guard !workspaceStore.isWriteProtected else { return }
      let window = WorkspaceWindow(id: windowID, layout: layout, panes: sessions.map {
        WorkspacePane(id: $0.id, connection: ConnectionDraft(profile: $0.profile))
      })
      var windows = workspaceStore.snapshot?.windows ?? []
      if let index = windows.firstIndex(where: { $0.id == windowID }) { windows[index] = window }
      else { windows.append(window) }
      try workspaceStore.save(WorkspaceSnapshot(windows: windows, selectedWindowID: windowID))
      if replacingUnreadable { error = nil }
    } catch { self.error = error.localizedDescription }
  }

  private func restoreWorkspace() {
    guard let window = workspaceStore.snapshot?.windows.first(where: { $0.id == windowID }) else { return }
    isRestoring = true
    defer { isRestoring = false }
    sessions = window.panes.map { pane in
      let draft = pane.connection
      let matching = hosts.first { $0.id == draft.profileID && ConnectionDraft(profile: $0) == draft }
      let auth: AuthRef = draft.authentication == .privateKey && draft.keyID != nil
        ? .privateKey(keyId: draft.keyID!, hasPassphrase: false) : .password
      let profile = matching ?? ConnectionProfile(id: draft.profileID ?? UUID(), name: draft.name,
        hostname: draft.hostname, port: Int(draft.port) ?? 22, username: draft.username,
        auth: auth, jumpProfileId: draft.jumpProfileID)
      // Restore structure only. Connections and credentials are resolved on explicit reconnect.
      return MobileSession(id: pane.id, profile: profile,
        manager: SessionManager(knownHosts: knownHosts, forwardStore: forwards))
    }
    layout = window.layout
    selectedSessionID = layout.selectedTab?.focusedPane
  }
}
