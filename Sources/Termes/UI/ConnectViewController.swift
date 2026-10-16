import AppKit
import Combine
import TermesKit
import SnapKit
import SSHCore

@MainActor
final class ConnectViewController: NSViewController {
  private let session: SessionManager
  private let onLabel: (SessionLabel) -> Void
  private var profilesObserver: AnyCancellable?
  private var draftObserver: AnyCancellable?
  var onDraftChange: (() -> Void)?
  private let profiles: ConnectionProfileService

  private let nameField = NSTextField()
  private let hostField = NSTextField()
  private let portField = NSTextField(string: "22")
  private let userField = NSTextField()
  private let authControl = NSSegmentedControl(labels: ["密码", "私钥文件"], trackingMode: .selectOne,
                                               target: nil, action: nil)
  private let passwordField = NSSecureTextField()
  private let keyButton = NSButton(title: "选择私钥文件", target: nil, action: nil)
  private let keyLabel = NSTextField(labelWithString: "未选择")
  private let passphraseField = NSSecureTextField()
  private let errorLabel = NSTextField(wrappingLabelWithString: "")
  private let restorationLabel = NSTextField(wrappingLabelWithString: "")
  private let connectButton = NSButton(title: "连接", target: nil, action: nil)
  private var passwordRow: NSStackView!
  private var keyRow: NSStackView!
  private var keyControlsWidth: [Constraint] = []
  private var passphraseRow: NSStackView!
  private var keyData: Data?
  private let savedPopup = NSPopUpButton(frame: .zero, pullsDown: false)
  private let jumpPopup = JumpHostPopup()
  private let keyPopup = NSPopUpButton(frame: .zero, pullsDown: false)
  private let saveButton = NSButton(title: "保存连接", target: nil, action: nil)
  private let deleteButton = NSButton(title: "删除", target: nil, action: nil)
  private let editButton = NSButton(title: "编辑信息…", target: nil, action: nil)
  private var editorSheet: NSWindow?
  private let formScroll = NSScrollView()
  private let formStack = NSStackView()
  private let actionRow = NSStackView()
  private var formRows: [(row: NSStackView, label: NSTextField, fullWidth: [Constraint])] = []
  private var actionWidths: [Constraint] = []
  private var compactForm: Bool?
  private var savedIds: [UUID] = []  // parallel to savedPopup items 1...
  private var keyIds: [UUID] = []  // parallel to keyPopup items 1...
  private var reuseKeyId: UUID?
  private var selectedProfileId: UUID? {
    savedIds[safe: savedPopup.indexOfSelectedItem - 1]
  }
  /// Return triggers 连接 only on the focused pane's page; a window has one Return default button.
  var isDefaultActionEnabled = false {
    didSet { connectButton.keyEquivalent = isDefaultActionEnabled ? "\r" : "" }
  }

  init(session: SessionManager, profiles: ConnectionProfileService, onLabel: @escaping (SessionLabel) -> Void) {
    self.session = session
    self.profiles = profiles
    self.onLabel = onLabel
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError("unsupported") }

  override func loadView() {
    let root = ChromeView(frame: NSRect(x: 0, y: 0, width: 820, height: 540))
    func row(_ title: String, _ field: NSView) -> NSStackView {
      let label = NSTextField(labelWithString: title)
      label.alignment = .right
      label.snp.makeConstraints { make in make.width.equalTo(70) }
      let s = NSStackView(views: [label, field])
      s.orientation = .horizontal
      s.alignment = .centerY
      s.spacing = 8
      field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      field.setContentHuggingPriority(.defaultLow, for: .horizontal)
      let fullWidth = field.snp.prepareConstraints { make in
        make.width.equalTo(s.snp.width).labeled("Connect.compactField")
      }
      formRows.append((s, label, fullWidth))
      return s
    }
    nameField.placeholderString = "可选，例如：生产服务器"
    nameField.setAccessibilityLabel("服务器名称")
    nameField.toolTip = "用于识别服务器和显示标签；留空使用用户名@主机"
    hostField.placeholderString = "example.com"
    hostField.setAccessibilityLabel("主机")
    portField.setAccessibilityLabel("端口")
    userField.placeholderString = "root"
    userField.setAccessibilityLabel("用户名")
    passwordField.setAccessibilityLabel("密码")
    passphraseField.setAccessibilityLabel("私钥口令")
    passphraseField.placeholderString = "可选"
    authControl.selectedSegment = 0
    authControl.target = self
    authControl.action = #selector(authChanged)
    keyButton.target = self
    keyButton.action = #selector(chooseKey)
    keyLabel.textColor = .secondaryLabelColor
    keyLabel.lineBreakMode = .byTruncatingMiddle
    keyLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    errorLabel.textColor = .systemRed
    errorLabel.isHidden = true
    errorLabel.preferredMaxLayoutWidth = 320
    connectButton.bezelStyle = .rounded
    connectButton.keyEquivalent = isDefaultActionEnabled ? "\r" : ""
    connectButton.target = self
    connectButton.action = #selector(connect)

    passwordRow = row("密码", passwordField)
    keyPopup.target = self
    keyPopup.action = #selector(keyPopupChanged)
    savedPopup.target = self
    savedPopup.action = #selector(savedChanged)
    jumpPopup.target = self; jumpPopup.action = #selector(draftSelectionChanged)
    saveButton.target = self
    saveButton.action = #selector(saveTapped)
    deleteButton.target = self
    deleteButton.action = #selector(deleteTapped)
    editButton.target = self
    editButton.action = #selector(editTapped)
    let keyControls = NSStackView(views: [keyPopup, keyButton, keyLabel])
    keyControls.orientation = .vertical
    keyControls.alignment = .leading
    for control in [keyPopup, keyButton, keyLabel] {
      control.snp.makeConstraints { make in make.width.equalTo(keyControls.snp.width) }
      control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    keyRow = row("私钥", keyControls)
    // Nested stacks can otherwise collapse to the popup's minimum width (39 pt),
    // even though the outer row spans the form. Match the other fields in wide mode.
    keyControlsWidth = keyControls.snp.prepareConstraints { make in
      make.width.equalTo(keyRow.snp.width).offset(-78).labeled("Connect.wideKeyControls")
    }
    passphraseRow = row("口令", passphraseField)
    for button in [saveButton, deleteButton, connectButton] {
      actionRow.addArrangedSubview(button)
      actionWidths += button.snp.prepareConstraints { make in make.width.equalTo(actionRow.snp.width) }
    }
    actionRow.spacing = 8
    let heading = NSTextField(labelWithString: "连接服务器")
    heading.font = .boldSystemFont(ofSize: 22)
    let description = NSTextField(wrappingLabelWithString: "选择已保存的服务器，或填写新的 SSH 连接信息。")
    description.font = .systemFont(ofSize: 12); description.textColor = .secondaryLabelColor
    restorationLabel.font = .systemFont(ofSize: 12); restorationLabel.textColor = .secondaryLabelColor
    restorationLabel.isHidden = true
    let formControls: [NSView] = [heading, description, restorationLabel,
      row("已存", savedPopup),
      editButton,
      row("名称", nameField),
      row("主机", hostField), row("端口", portField), row("用户名", userField),
      row("跳板机", jumpPopup), row("认证", authControl), passwordRow, keyRow, passphraseRow, errorLabel,
      actionRow,
    ]
    for control in formControls {
      formStack.addArrangedSubview(control)
      control.snp.makeConstraints { make in make.leading.trailing.equalTo(formStack) }
    }
    formStack.orientation = .vertical
    formStack.alignment = .leading
    formStack.spacing = 12
    let document = ConnectFormDocumentView()
    document.addSubview(formStack)
    formScroll.hasVerticalScroller = true
    formScroll.autohidesScrollers = true
    // Keep the clip width stable when a short split pane starts scrolling.
    formScroll.scrollerStyle = .overlay
    formScroll.drawsBackground = false
    formScroll.automaticallyAdjustsContentInsets = false
    formScroll.documentView = document
    root.addSubview(formScroll)
    formScroll.snp.makeConstraints { make in make.edges.equalToSuperview().labeled("Connect.scroll") }
    document.snp.makeConstraints { make in
      make.width.equalTo(formScroll.contentView.snp.width)
      make.height.greaterThanOrEqualTo(formScroll.contentView.snp.height)
      make.height.equalTo(formStack.snp.height).offset(40).priority(.low)
    }
    formStack.snp.makeConstraints { make in
      make.center.equalToSuperview()
      make.top.greaterThanOrEqualToSuperview().offset(20)
      make.leading.greaterThanOrEqualToSuperview().offset(16)
      make.width.lessThanOrEqualTo(420)
      // NSWindow's user size has priority 500. The preferred form width must yield to it.
      make.width.equalToSuperview().offset(-32).priority(450).labeled("Connect.preferredWidth")
    }
    view = root
    updateFormLayout()
    reloadSaved()
    authChanged()
    // Saves/deletes/imports from any window or pane refresh this page's lists.
    profilesObserver = profiles.didChange.sink { [weak self] in self?.reloadSaved() }
    draftObserver = NotificationCenter.default.publisher(for: NSControl.textDidChangeNotification).sink { [weak self] note in
      guard let self, let field = note.object as? NSTextField,
            [self.nameField, self.hostField, self.portField, self.userField].contains(where: { $0 === field }) else { return }
      self.onDraftChange?()
    }
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    updateFormLayout()
  }

  private func updateFormLayout() {
    let compact = view.bounds.width < 420
    errorLabel.preferredMaxLayoutWidth = min(420, max(1, view.bounds.width - 32))
    restorationLabel.preferredMaxLayoutWidth = min(420, max(1, view.bounds.width - 32))
    guard compactForm != compact else { return }
    compactForm = compact
    keyControlsWidth.forEach { $0.deactivate() }
    formRows.flatMap(\.fullWidth).forEach { $0.deactivate() }
    actionWidths.forEach { $0.deactivate() }
    for (row, label, fullWidth) in formRows {
      row.orientation = compact ? .vertical : .horizontal
      row.alignment = compact ? .leading : .centerY
      label.alignment = compact ? .left : .right
      // NSStackView defers rebuilding its generated axis constraints, especially on
      // hidden authentication rows. Flush them before activating the new field widths.
      row.needsUpdateConstraints = true
      row.updateConstraintsForSubtreeIfNeeded()
      if compact { fullWidth.forEach { $0.activate() } }
    }
    if !compact { keyControlsWidth.forEach { $0.activate() } }
    actionRow.orientation = compact ? .vertical : .horizontal
    actionRow.alignment = compact ? .leading : .centerY
    actionRow.needsUpdateConstraints = true
    actionRow.updateConstraintsForSubtreeIfNeeded()
    if compact { actionWidths.forEach { $0.activate() } }
  }

  func focusFirstField() {
    let field: NSView = selectedProfileId == nil ? hostField
      : (authControl.selectedSegment == 0 ? passwordField : keyPopup)
    view.window?.makeFirstResponder(field)
    field.scrollToVisible(field.bounds)
  }

  /// Explicitly opening a saved server can lead here to repair a missing local credential.
  func selectProfile(_ id: UUID) {
    _ = view
    reloadSaved()
    guard let index = savedIds.firstIndex(of: id) else { return }
    savedPopup.selectItem(at: index + 1); savedChanged()
  }

  var connectionDraft: ConnectionDraft {
    ConnectionDraft(profileID: selectedProfileId, name: nameField.stringValue, hostname: hostField.stringValue,
      port: portField.stringValue, username: userField.stringValue,
      authentication: authControl.selectedSegment == 1 ? .privateKey : .password,
      keyID: reuseKeyId, jumpProfileID: jumpPopup.selectedProfileId)
  }

  /// Restored pages remain disconnected; saved references always use the latest saved target.
  func restore(_ draft: ConnectionDraft) {
    _ = view
    if let id = draft.profileID, savedIds.contains(id) {
      selectProfile(id)
    } else {
      savedPopup.selectItem(at: 0); savedChanged()
      nameField.stringValue = draft.name; hostField.stringValue = draft.hostname
      portField.stringValue = draft.port; userField.stringValue = draft.username
      authControl.selectedSegment = draft.authentication == .privateKey ? 1 : 0
      jumpPopup.reload((try? profiles.profiles()) ?? [], selected: draft.jumpProfileID)
      if let id = draft.keyID, let index = keyIds.firstIndex(of: id) { keyPopup.selectItem(at: index + 1) }
      keyPopupChanged(); authChanged()
    }
    if let id = draft.profileID, !savedIds.contains(id) {
      restorationLabel.stringValue = "原已存连接已删除；请核对连接信息并补录凭据。"
    } else if draft.profileID != nil {
      restorationLabel.stringValue = "工作区已恢复，点击「连接」使用本机已存凭据。"
    } else if let id = draft.keyID, !keyIds.contains(id) {
      restorationLabel.stringValue = "原私钥已不可用；请重新选择私钥后连接。"
    } else {
      restorationLabel.stringValue = "工作区已恢复。核对连接信息后点击「连接」。"
    }
    restorationLabel.isHidden = draft.hostname.isEmpty && draft.profileID == nil
  }

  @objc private func draftSelectionChanged() { onDraftChange?() }

  func showError(_ message: String?) {
    _ = view
    if let message {
      showFailure("连接/认证失败: \(message)")
    } else {
      errorLabel.isHidden = true
    }
  }

  @objc private func authChanged() {
    let isKey = authControl.selectedSegment == 1
    passwordRow.isHidden = isKey
    keyRow.isHidden = !isKey
    passphraseRow.isHidden = !isKey
    onDraftChange?()
  }

  @objc private func chooseKey() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.showsHiddenFiles = true
    panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      keyData = try Data(contentsOf: url)  // memory only
      keyLabel.stringValue = url.lastPathComponent
      showError(nil)
    } catch {
      keyData = nil
      keyLabel.stringValue = "未选择"
      errorLabel.stringValue = "读取私钥失败: \(error.localizedDescription)"
      errorLabel.isHidden = false
    }
  }

  @objc private func keyPopupChanged() {
    let i = keyPopup.indexOfSelectedItem
    reuseKeyId = i >= 1 && i - 1 < keyIds.count ? keyIds[i - 1] : nil
    keyButton.isHidden = reuseKeyId != nil
    keyLabel.isHidden = reuseKeyId != nil
    onDraftChange?()
  }

  @objc private func savedChanged() {
    updateSelectionControls()
    errorLabel.isHidden = true
    // Never carry a typed credential from one saved host to another.
    passwordField.stringValue = ""
    passphraseField.stringValue = ""
    keyData = nil
    keyLabel.stringValue = "未选择"
    keyPopup.selectItem(at: 0)
    keyPopupChanged()
    do {
      if let id = selectedProfileId, let p = try profiles.profiles().first(where: { $0.id == id }) {
        nameField.stringValue = p.name
        hostField.stringValue = p.hostname
        portField.stringValue = String(p.port)
        userField.stringValue = p.username
        jumpPopup.reload(try profiles.profiles(), selected: p.jumpProfileId, excluding: p.id)
        switch p.auth {
        case .password: authControl.selectedSegment = 0
        case .privateKey: authControl.selectedSegment = 1
        }
      } else {
        nameField.stringValue = ""
        jumpPopup.reload(try profiles.profiles(), selected: nil)
      }
      authChanged()
    } catch { showFailure(error.localizedDescription) }
    onDraftChange?()
  }

  private func updateSelectionControls() {
    let saved = selectedProfileId != nil
    jumpPopup.isEnabled = !saved
    deleteButton.isEnabled = saved
    editButton.isHidden = !saved
    saveButton.title = saved ? "更新凭据" : "保存连接"
    // Connect uses the saved target. Keep its displayed address read-only to avoid implying
    // that edits to these fields would change the host receiving the saved credentials.
    for field in [nameField, hostField, portField, userField] { field.isEnabled = !saved }
  }

  @objc private func editTapped() {
    guard editorSheet == nil, let parent = view.window, let id = selectedProfileId else { return }
    do {
      guard let profile = try profiles.profiles().first(where: { $0.id == id }) else {
        throw ProfileServiceError.profileNotFound
      }
      let editor = ConnectionEditorViewController(profile: profile, profiles: profiles) { [weak self, weak parent] in
        guard let self, let sheet = self.editorSheet else { return }
        parent?.endSheet(sheet)
      }
      let sheet = NSWindow(contentViewController: editor)
      sheet.title = "编辑连接信息"
      sheet.styleMask = [.titled]
      sheet.isRestorable = false
      editorSheet = sheet
      parent.beginSheet(sheet) { [weak self] _ in self?.editorSheet = nil }
    } catch { showFailure(error.localizedDescription) }
  }

  @objc private func saveTapped() {
    if let id = selectedProfileId {
      guard let credential = currentCredential() else { return }
      do {
        try profiles.updateCredential(for: id, credential: credential)
        savedChanged()  // clear typed secrets after they have been stored
      } catch {
        showFailure((error as? ProfileServiceError) == .credentialMissing
          ? "该私钥缺少本机凭据，请选择私钥文件重新导入" : error.localizedDescription)
      }
      return
    }
    guard let (host, _, user) = currentTarget() else { return }
    guard let profile = saveCurrent(name: connectionLabel(host: host, user: user).name),
          let index = savedIds.firstIndex(of: profile.id) else { return }
    savedPopup.selectItem(at: index + 1)
    savedChanged()
  }

  @objc private func deleteTapped() {
    let i = savedPopup.indexOfSelectedItem
    guard i >= 1, i - 1 < savedIds.count else { return }
    let alert = NSAlert()
    alert.messageText = "删除连接\"\(savedPopup.titleOfSelectedItem ?? "")\"?"
    alert.addButton(withTitle: "删除")
    alert.addButton(withTitle: "取消")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    do {
      try profiles.deleteConnection(savedIds[i - 1])
      reloadSaved()
    } catch { showFailure(error.localizedDescription) }
  }

  private func showFailure(_ text: String) {
    errorLabel.stringValue = text
    errorLabel.isHidden = false
    if view.window != nil {
      view.layoutSubtreeIfNeeded()
      errorLabel.scrollToVisible(errorLabel.bounds)
    }
  }

  func reloadSaved() {
    let selectedProfile = savedPopup.indexOfSelectedItem >= 1 ? savedIds[safe: savedPopup.indexOfSelectedItem - 1] : nil
    savedPopup.removeAllItems()
    savedPopup.addItem(withTitle: "新建连接…")
    let selectedJump = jumpPopup.selectedProfileId
    let list = (try? profiles.profiles()) ?? []
    savedIds = list.map(\.id)
    for p in list { savedPopup.addItem(withTitle: p.name) }
    if let selectedProfile, let idx = savedIds.firstIndex(of: selectedProfile) { savedPopup.selectItem(at: idx + 1) }
    let storedJump = list.first { $0.id == selectedProfileId }?.jumpProfileId
    jumpPopup.reload(list, selected: selectedProfileId == nil ? selectedJump : storedJump,
                     excluding: selectedProfileId)
    updateSelectionControls()
    // Clear credential drafts when another pane/window edits this profile's target.
    // A name-only change leaves the user's in-progress credential update intact.
    if let id = selectedProfileId, let profile = list.first(where: { $0.id == id }) {
      nameField.stringValue = profile.name
      if hostField.stringValue != profile.hostname || portField.stringValue != String(profile.port)
          || userField.stringValue != profile.username || selectedJump != profile.jumpProfileId { savedChanged() }
    } else if selectedProfile != nil {
      savedChanged() // deletion must not leave a credential draft targeting an unrelated host
    }

    let selectedKey = reuseKeyId
    keyPopup.removeAllItems()
    keyPopup.addItem(withTitle: "导入新私钥…")
    let keys = (try? profiles.keys()) ?? []
    keyIds = keys.map(\.id)
    for k in keys { keyPopup.addItem(withTitle: k.name) }
    if let selectedKey, let idx = keyIds.firstIndex(of: selectedKey) { keyPopup.selectItem(at: idx + 1) }
    keyPopupChanged()
  }

  private func connectSaved(id: UUID) {
    do {
      let cfg = try profiles.makeConfig(for: id)
      if let p = try profiles.profiles().first(where: { $0.id == id }) { onLabel(SessionLabel(name: p.name, username: p.username, profileID: p.id)) }
      errorLabel.isHidden = true
      let session = session
      Task { await session.connect(cfg, cols: 80, rows: 24) }
    } catch {
      showFailure((error as? ProfileServiceError) == .credentialMissing
                  ? "该连接缺少本机凭据，请填写密码或选择私钥文件，点「更新凭据」后再连接" : error.localizedDescription)
    }
  }

  @discardableResult
  private func saveCurrent(name: String) -> ConnectionProfile? {
    guard let (host, port, user) = currentTarget(), let cred = currentCredential() else { return nil }
    do {
      let p = try profiles.saveConnection(name: name, hostname: host, port: port, username: user, credential: cred,
                                          jumpProfileId: jumpPopup.selectedProfileId)
      errorLabel.isHidden = true
      if case .privateKey = cred, case .privateKey(let keyId, _) = p.auth {
        // Imported key is now stored; reuse it so a second save does not import it again.
        keyData = nil
        keyLabel.stringValue = "未选择"
        reuseKeyId = keyId
      }
      reloadSaved()
      return p
    } catch { showFailure(error.localizedDescription); return nil }
  }

  /// Validated host/port/user from the form, or nil (after showing an error).
  private func currentTarget() -> (String, Int, String)? {
    let host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
    let user = userField.stringValue
    guard !host.isEmpty, !user.isEmpty, let port = Int(portField.stringValue), (1...65535).contains(port) else {
      showFailure("请填写有效的主机、端口和用户名")
      return nil
    }
    return (host, port, user)
  }

  /// The same display name is used for saved profiles and one-off sessions.
  func connectionLabel(host: String, user: String) -> SessionLabel {
    let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return SessionLabel(name: name.isEmpty ? "\(user)@\(host)" : name, username: user)
  }

  /// Credential from the form, or nil (after showing an error).
  private func currentCredential() -> NewCredential? {
    if authControl.selectedSegment == 0 {
      guard !passwordField.stringValue.isEmpty else { showFailure("请输入密码"); return nil }
      return .password(passwordField.stringValue)
    }
    if let reuseKeyId { return .existingKey(reuseKeyId) }
    guard let keyData else { showFailure("请选择私钥文件"); return nil }
    let pp = passphraseField.stringValue
    return .privateKey(data: keyData, name: keyLabel.stringValue, passphrase: pp.isEmpty ? nil : pp)
  }

  @objc private func connect() {
    restorationLabel.isHidden = true
    let i = savedPopup.indexOfSelectedItem
    if i >= 1, i - 1 < savedIds.count { connectSaved(id: savedIds[i - 1]); return }
    guard let (host, port, user) = currentTarget(), let cred = currentCredential() else { return }
    errorLabel.isHidden = true
    let auth: AuthMethod
    switch cred {
    case .password(let p): auth = .password(p)
    case .privateKey(let data, _, let pp): auth = .privateKey(data: data, passphrase: pp)
    case .existingKey(let keyId):
      do {
        let config = try profiles.makeConfig(hostname: host, port: port, username: user, existingKeyId: keyId,
                                             jumpProfileId: jumpPopup.selectedProfileId)
        onLabel(connectionLabel(host: host, user: user))
        let session = session
        Task { await session.connect(config, cols: 80, rows: 24) }
      } catch { showFailure(error.localizedDescription) }
      return
    }
    do {
      let config = ConnectionConfig(hostname: host, port: port, username: user, auth: auth,
                                    jumpHosts: try profiles.jumpHosts(for: jumpPopup.selectedProfileId))
      onLabel(connectionLabel(host: host, user: user))
      let session = session
      Task { await session.connect(config, cols: 80, rows: 24) }
    } catch { showFailure(error.localizedDescription) }
  }
}

private extension Array {
  subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// Keeps the first form row at the top when a short pane needs vertical scrolling.
private final class ConnectFormDocumentView: NSView {
  override var isFlipped: Bool { true }
}
