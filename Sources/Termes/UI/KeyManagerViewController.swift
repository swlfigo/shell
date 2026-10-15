import AppKit
import SnapKit
import Combine
import TermesKit
import SSHCore

@MainActor
final class KeyManagerViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
  private let profiles: ConnectionProfileService
  private var observer: AnyCancellable?
  private(set) var keys: [SSHKeyInfo] = []
  let table = NSTableView()
  let detailLabel = NSTextField(wrappingLabelWithString: "")
  let errorLabel = NSTextField(wrappingLabelWithString: "")
  let fingerprintLabel = NSTextField(wrappingLabelWithString: "")
  private let renameButton = NSButton(title: "重命名…", target: nil, action: nil)
  private let deleteButton = NSButton(title: "删除…", target: nil, action: nil)
  private let replaceButton = NSButton(title: "替换私钥…", target: nil, action: nil)
  private let copyButton = NSButton(title: "复制指纹", target: nil, action: nil)

  init(profiles: ConnectionProfileService) {
    self.profiles = profiles
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError("unsupported") }

  override func loadView() {
    view = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
    for (id, title, width) in [("name", "名称", 260.0), ("status", "本机凭据", 150.0), ("usage", "使用情况", 150.0)] {
      let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
      column.title = title
      column.width = width
      column.minWidth = 90
      table.addTableColumn(column)
    }
    table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    table.autoresizingMask = [.width]
    table.allowsMultipleSelection = false
    table.dataSource = self
    table.delegate = self
    table.setAccessibilityLabel("已存私钥")
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.scrollerStyle = .legacy
    scroll.documentView = table
    let add = NSButton(title: "导入私钥…", target: self, action: #selector(importTapped))
    renameButton.target = self
    renameButton.action = #selector(renameTapped)
    deleteButton.target = self
    deleteButton.action = #selector(deleteTapped)
    replaceButton.target = self; replaceButton.action = #selector(replaceTapped)
    copyButton.target = self; copyButton.action = #selector(copyFingerprint)
    for button in [add, replaceButton, renameButton, copyButton, deleteButton] { button.bezelStyle = .rounded }
    let buttons = NSStackView(views: [add, replaceButton, renameButton, copyButton, deleteButton])
    buttons.spacing = 8
    detailLabel.preferredMaxLayoutWidth = 580
    detailLabel.maximumNumberOfLines = 3
    errorLabel.preferredMaxLayoutWidth = 580
    errorLabel.maximumNumberOfLines = 2
    errorLabel.textColor = .systemRed
    errorLabel.isHidden = true
    fingerprintLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    fingerprintLabel.maximumNumberOfLines = 2; fingerprintLabel.isSelectable = true
    let stack = NSStackView(views: [scroll, fingerprintLabel, detailLabel, errorLabel, buttons])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    view.addSubview(stack)
    stack.snp.makeConstraints { make in make.edges.equalToSuperview().inset(20).labeled("KeyManager.column") }
    scroll.snp.makeConstraints { make in
      make.width.equalTo(stack.snp.width)
      make.height.greaterThanOrEqualTo(120)
    }
    for label in [detailLabel, fingerprintLabel, errorLabel] {
      label.snp.makeConstraints { make in make.width.equalTo(stack.snp.width) }
    }
    scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
    reloadKeys()
    observer = profiles.didChange.sink { [weak self] in self?.reloadKeys() }
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    if let clip = table.superview as? NSClipView, table.frame.width != clip.bounds.width {
      table.setFrameSize(NSSize(width: clip.bounds.width, height: table.frame.height))
      table.sizeLastColumnToFit()
    }
    detailLabel.preferredMaxLayoutWidth = max(1, view.bounds.width - 40)
    errorLabel.preferredMaxLayoutWidth = max(1, view.bounds.width - 40)
  }

  private var selected: SSHKeyInfo? {
    keys.indices.contains(table.selectedRow) ? keys[table.selectedRow] : nil
  }

  func reloadKeys() {
    let id = selected?.key.id
    do {
      keys = try profiles.keyInfo()
      table.reloadData()
      if let id, let row = keys.firstIndex(where: { $0.key.id == id }) {
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
      } else { table.deselectAll(nil) }
      updateSelection()
    } catch { showError(error) }
  }

  func numberOfRows(in tableView: NSTableView) -> Int { keys.count }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard keys.indices.contains(row) else { return nil }
    let info = keys[row]
    let text: String
    switch tableColumn?.identifier.rawValue {
    case "name": text = info.key.name
    case "status": text = info.hasLocalCredential ? "可用" : "缺少凭据"
    default: text = "\(info.connections.count) 个连接"
    }
    let label = NSTextField(labelWithString: text)
    label.lineBreakMode = .byTruncatingTail
    label.toolTip = text
    return label
  }

  func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }

  private func updateSelection() {
    renameButton.isEnabled = selected != nil
    deleteButton.isEnabled = selected != nil
    replaceButton.isEnabled = selected != nil
    copyButton.isEnabled = selected?.key.fingerprint != nil
    guard let info = selected else {
      fingerprintLabel.stringValue = ""
      fingerprintLabel.toolTip = nil
      detailLabel.stringValue = keys.isEmpty ? "尚无私钥。导入后可在连接页复用。" : "选择私钥查看关联连接。"
      detailLabel.toolTip = nil
      return
    }
    fingerprintLabel.stringValue = (info.key.keyType ?? "未知类型") + " · " + (info.key.fingerprint ?? "无法计算指纹")
    fingerprintLabel.toolTip = fingerprintLabel.stringValue
    let names = info.connections.map(\.name).joined(separator: "、")
    detailLabel.stringValue = names.isEmpty ? "未被连接使用，可删除。" : "使用此私钥：\(names)。删除前需先为这些连接更换凭据或删除连接。"
    if !info.hasLocalCredential {
      detailLabel.stringValue += " 缺少本机凭据，请在连接页重新选择私钥文件并更新凭据。"
    }
    detailLabel.toolTip = detailLabel.stringValue
  }

  @discardableResult
  func importKey(data: Data, name: String, passphrase: String?) -> Bool {
    do {
      let existingIds = Set(keys.map { $0.key.id })
      let key = try profiles.importKey(data: data, name: name, passphrase: passphrase)
      reloadKeys()
      if let row = keys.firstIndex(where: { $0.key.id == key.id }) {
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
      }
      errorLabel.isHidden = true
      if existingIds.contains(key.id) {
        detailLabel.stringValue = "相同公钥已存在，沿用“\(key.name)”及原凭据；要更换私钥文件或口令，请使用替换私钥。"
        detailLabel.toolTip = detailLabel.stringValue
      }
      return true
    } catch { showError(error); return false }
  }

  @discardableResult
  func replaceKey(_ info: SSHKeyInfo, data: Data, passphrase: String?) -> Bool {
    do {
      _ = try profiles.replaceKey(info.key.id, data: data, passphrase: passphrase,
        expected: info.key, expectedProfileIds: info.connections.map(\.id))
      reloadKeys(); errorLabel.isHidden = true
      return true
    } catch { showError(error); return false }
  }

  @objc private func copyFingerprint() {
    guard let fingerprint = selected?.key.fingerprint else { return }
    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(fingerprint, forType: .string)
  }

  @objc private func replaceTapped() {
    guard let info = selected, let window = view.window else { return }
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.showsHiddenFiles = true
    panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
    panel.beginSheetModal(for: window) { [weak self, weak window] response in
      guard response == .OK, let url = panel.url, let self, let window else { return }
      do {
        let data = try Data(contentsOf: url)
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        password.placeholderString = "新私钥口令（未加密则留空）"
        password.setAccessibilityLabel("替换私钥口令")
        let alert = NSAlert()
        alert.messageText = "读取替换私钥"
        alert.informativeText = "文件：\(url.lastPathComponent)\n输入口令后核对新指纹和引用连接。"
        alert.accessoryView = password
        alert.addButton(withTitle: "继续"); alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self, weak window] response in
          defer { password.stringValue = "" }
          guard response == .alertFirstButtonReturn, let self, let window else { return }
          let passphrase = password.stringValue
          guard let identity = PrivateKeyIdentity.inspect(data, passphrase: passphrase) else {
            self.showError(ProfileServiceError.invalidPrivateKey); return
          }
          let confirmation = NSAlert()
          confirmation.messageText = "替换私钥“\(info.key.name)”？"
          let names = info.connections.prefix(8).map { String($0.name.prefix(80)) }.joined(separator: "、")
          let usage = info.connections.isEmpty ? "此私钥尚未被引用。"
            : "影响 \(info.connections.count) 个连接：\(names)\(info.connections.count > 8 ? "等" : "")。"
          confirmation.informativeText = "新类型：\(identity.keyType)\n原指纹：\(info.key.fingerprint ?? "未知")\n新指纹：\(identity.fingerprint)\n\(usage)\n保留名称和 ID，替换本机私钥及口令。正在运行的会话保留原配置，后续登录使用新私钥。"
          confirmation.addButton(withTitle: "替换"); confirmation.addButton(withTitle: "取消")
          confirmation.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            _ = self?.replaceKey(info, data: data, passphrase: passphrase)
          }
        }
      } catch { self.showError(error) }
    }
  }

  @discardableResult
  func renameKey(_ id: UUID, name: String) -> Bool {
    do {
      try profiles.renameKey(id, name: name)
      errorLabel.isHidden = true
      return true
    } catch { showError(error); return false }
  }

  @discardableResult
  func deleteKey(_ id: UUID) -> Bool {
    do {
      try profiles.deleteKey(id)
      errorLabel.isHidden = true
      return true
    } catch { showError(error); return false }
  }

  private func showError(_ error: Error) {
    errorLabel.stringValue = error.localizedDescription
    errorLabel.toolTip = error.localizedDescription
    errorLabel.isHidden = false
  }

  @objc private func importTapped() {
    guard let window = view.window else { return }
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.showsHiddenFiles = true
    panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
    panel.beginSheetModal(for: window) { [weak self, weak window] response in
      guard response == .OK, let url = panel.url, let self, let window else { return }
      do {
        let data = try Data(contentsOf: url)
        let name = NSTextField(string: url.lastPathComponent)
        let passphrase = NSSecureTextField()
        passphrase.placeholderString = "私钥口令（可选）"
        let fields = NSStackView(views: [name, passphrase])
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.spacing = 10
        fields.frame = NSRect(x: 0, y: 0, width: 300, height: 60)
        for field in [name, passphrase] {
          field.snp.makeConstraints { make in make.width.equalTo(fields.snp.width) }
        }
        name.setAccessibilityLabel("私钥名称")
        passphrase.setAccessibilityLabel("私钥口令")
        let alert = NSAlert()
        alert.messageText = "导入私钥"
        alert.informativeText = "输入名称和私钥口令。私钥及口令只保存在本机 Keychain。"
        alert.accessoryView = fields
        alert.addButton(withTitle: "导入")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
          defer { passphrase.stringValue = "" }
          guard response == .alertFirstButtonReturn else { return }
          _ = self?.importKey(data: data, name: name.stringValue, passphrase: passphrase.stringValue)
        }
      } catch { self.showError(error) }
    }
  }

  @objc private func renameTapped() {
    guard let info = selected, let window = view.window else { return }
    let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
    name.stringValue = info.key.name
    let alert = NSAlert()
    alert.messageText = "重命名私钥"
    alert.accessoryView = name
    alert.addButton(withTitle: "保存")
    alert.addButton(withTitle: "取消")
    alert.beginSheetModal(for: window) { [weak self] response in
      guard response == .alertFirstButtonReturn else { return }
      _ = self?.renameKey(info.key.id, name: name.stringValue)
    }
  }

  @objc private func deleteTapped() {
    guard let info = selected, let window = view.window else { return }
    guard info.connections.isEmpty else {
      showError(ProfileServiceError.keyInUse(profileIds: info.connections.map(\.id)))
      return
    }
    let alert = NSAlert()
    alert.messageText = "删除私钥“\(info.key.name)”？"
    alert.informativeText = "将删除私钥元数据及本机 Keychain 中的私钥和口令。"
    alert.addButton(withTitle: "删除")
    alert.addButton(withTitle: "取消")
    alert.beginSheetModal(for: window) { [weak self] response in
      guard response == .alertFirstButtonReturn else { return }
      // Recheck references in the service: another window may have saved a connection meanwhile.
      _ = self?.deleteKey(info.key.id)
    }
  }
}
