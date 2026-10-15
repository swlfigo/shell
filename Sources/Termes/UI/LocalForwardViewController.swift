import AppKit
import SnapKit
import Combine
import TermesKit
import SSHCore

@MainActor
final class LocalForwardViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSComboBoxDelegate {
  let model: LocalForwardManager
  let table = NSTableView()
  let localPortField = NSTextField()
  let targetHostField = NSTextField()
  let targetPortField = NSTextField()
  let kindPopup = NSPopUpButton()
  let listenHostField = NSComboBox()
  private let localPortLabel = NSTextField(labelWithString: "本机端口")
  private let targetHostLabel = NSTextField(labelWithString: "目标主机")
  private let listenHostLabel = NSTextField(labelWithString: "监听")
  private let listenHosts = ["127.0.0.1", "::1", "0.0.0.0", "::"]
  let statusLabel = NSTextField(wrappingLabelWithString: "")
  private(set) var editingID: UUID?
  private var editingBase: LocalForwardConfiguration?
  private var displayedDestination: LocalForwardDestination?
  private let hintLabel = NSTextField(wrappingLabelWithString: "")
  private var rows: [LocalForwardRule] = []
  private var reloading = false
  private var observer: AnyCancellable?
  private lazy var saveButton = button("保存规则", #selector(saveTapped))
  private lazy var startButton = button("启动", #selector(startTapped))
  private lazy var stopButton = button("停止", #selector(stopTapped))
  private lazy var removeButton = button("移除规则", #selector(removeTapped))
  private lazy var reloadButton = button("重新载入", #selector(reloadTapped))

  init(model: LocalForwardManager) {
    self.model = model
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError("unsupported") }

  override func loadView() {
    view = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 460))
    for (id, title, width) in [("local", "本机地址", 140.0), ("target", "目标地址", 260.0), ("state", "状态", 230.0)] {
      let column = NSTableColumn(identifier: .init(id))
      column.title = title; column.width = width; column.minWidth = 120
      table.addTableColumn(column)
    }
    table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    table.autoresizingMask = [.width]
    table.dataSource = self; table.delegate = self
    table.target = self; table.action = #selector(ruleClicked)
    table.setAccessibilityLabel("端口转发规则")
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true; scroll.scrollerStyle = .legacy
    scroll.documentView = table
    let stack = NSStackView()
    stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
    view.addSubview(stack)
    stack.snp.makeConstraints { make in make.edges.equalToSuperview().inset(20).labeled("LocalForward.column") }
    stack.addArrangedSubview(scroll)
    scroll.snp.makeConstraints { make in
      make.width.equalTo(stack.snp.width)
      make.height.greaterThanOrEqualTo(120)
    }
    scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
    kindPopup.addItems(withTitles: ["本地转发", "SOCKS5 代理", "远端转发"])
    kindPopup.setAccessibilityLabel("转发类型")
    kindPopup.target = self; kindPopup.action = #selector(kindChanged)
    listenHostField.addItems(withObjectValues: listenHosts)
    listenHostField.stringValue = "127.0.0.1"
    listenHostField.placeholderString = "服务器监听地址"
    listenHostField.toolTip = "服务器监听地址，可输入指定 IP 或主机名。实际绑定由服务器配置决定。"
    listenHostField.setAccessibilityLabel("服务器监听地址")
    listenHostField.snp.makeConstraints { make in make.width.equalTo(170) }
    listenHostField.delegate = self
    listenHostField.target = self; listenHostField.action = #selector(kindChanged)
    for (title, field, placeholder) in [("本机端口", localPortField, "例如：8080"),
                                       ("目标主机", targetHostField, "例如：127.0.0.1"),
                                       ("目标端口", targetPortField, "例如：80")] {
      let label = field === localPortField ? localPortLabel : (field === targetHostField ? targetHostLabel : NSTextField(labelWithString: title))
      label.snp.makeConstraints { make in make.width.equalTo(76) }
      field.usesSingleLineMode = true; field.placeholderString = placeholder
      field.setAccessibilityLabel(title)
      field.setContentHuggingPriority(.defaultLow, for: .horizontal)
      let controls: [NSView] = field === localPortField ? [label, field, kindPopup]
        : (field === targetHostField ? [label, field, listenHostLabel, listenHostField] : [label, field])
      let row = NSStackView(views: controls)
      row.spacing = 8
      stack.addArrangedSubview(row)
      row.snp.makeConstraints { make in make.width.equalTo(stack.snp.width) }
    }
    let hint = hintLabel
    hint.textColor = .secondaryLabelColor; hint.font = .systemFont(ofSize: 11)
    hint.maximumNumberOfLines = 3
    stack.addArrangedSubview(hint)
    hint.snp.makeConstraints { make in make.width.equalTo(stack.snp.width) }
    statusLabel.maximumNumberOfLines = 3
    statusLabel.font = .systemFont(ofSize: 11)
    stack.addArrangedSubview(statusLabel)
    statusLabel.snp.makeConstraints { make in make.width.equalTo(stack.snp.width) }
    let buttons = NSStackView(views: [button("新建", #selector(newTapped)), saveButton,
                                      startButton, stopButton, removeButton, reloadButton])
    buttons.spacing = 8
    stack.addArrangedSubview(buttons)
    observer = model.objectWillChange.sink { [weak self] in
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.render() } }
    }
    render()
  }

  private func button(_ title: String, _ action: Selector) -> NSButton {
    let button = NSButton(title: title, target: self, action: action)
    button.bezelStyle = .rounded
    return button
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    if let clip = table.enclosingScrollView?.contentView {
      table.setFrameSize(NSSize(width: clip.bounds.width, height: table.frame.height))
      let width = max(0, clip.bounds.width - table.intercellSpacing.width * 3)
      let fractions = [0.25, 0.4, 0.35]
      for (column, fraction) in zip(table.tableColumns, fractions) {
        column.width = width * fraction
      }
    }
  }

  private var selected: LocalForwardRule? { rows.first { $0.id == editingID } }
  private var kind: LocalForwardKind {
    switch kindPopup.indexOfSelectedItem { case 1: return .socks; case 2: return .remote; default: return .local }
  }
  private var listenHost: String { listenHostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }

  private func render() {
    if displayedDestination != model.destination {
      displayedDestination = model.destination
      editingID = nil; editingBase = nil
      kindPopup.selectItem(at: 0)
      listenHostField.stringValue = "127.0.0.1"
      for field in [localPortField, targetHostField, targetPortField] { field.stringValue = "" }
    }
    let persistence = model.persistsRules ? "规则按 SSH 目标保存，重启后保留；始终需手动启动。" : "规则仅保留在当前会话，重连后需手动启动。"
    let destination = model.destination.map { "SSH：\($0.displayName)。" } ?? ""
    let detail: String
    switch kind {
    case .socks: detail = "仅监听本机 127.0.0.1。SOCKS5 无需认证，仅支持 TCP；客户端指定目标，域名在 SSH 服务器解析。"
    case .local: detail = "仅监听本机 127.0.0.1。目标从 SSH 服务器访问；127.0.0.1 指服务器自身。"
    case .remote: detail = "请求服务器监听 \(listenHost)。目标从本机访问；127.0.0.1 指本机自身。实际监听地址由服务器 GatewayPorts 控制。"
    }
    hintLabel.stringValue = destination + detail + persistence
    hintLabel.toolTip = hintLabel.stringValue
    reloading = true
    rows = model.rules
    table.reloadData()
    if let editingID, let row = rows.firstIndex(where: { $0.id == editingID }) {
      table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    } else { table.deselectAll(nil) }
    reloading = false
    let editable = !model.isLoading && (selected?.canEdit ?? true)
    localPortField.isEnabled = editable; kindPopup.isEnabled = editable
    for field in [targetHostField, targetPortField] { field.isEnabled = editable && kind != .socks }
    listenHostField.isHidden = kind != .remote; listenHostField.isEnabled = editable
    listenHostLabel.isHidden = kind != .remote
    localPortLabel.stringValue = kind == .remote ? "服务器端口" : "本机端口"
    localPortField.setAccessibilityLabel(localPortLabel.stringValue)
    targetHostLabel.stringValue = kind == .remote ? "本机目标" : "目标主机"
    targetHostField.setAccessibilityLabel(targetHostLabel.stringValue)
    table.tableColumns[0].title = "监听地址"
    saveButton.isEnabled = editable && model.canSave
    startButton.isEnabled = !model.isLoading && model.isConnected && selected?.canEdit == true
    reloadButton.isHidden = !model.persistsRules
    reloadButton.isEnabled = !model.isLoading && model.destination != nil
    switch selected?.state {
    case .starting, .running: stopButton.isEnabled = true
    default: stopButton.isEnabled = false
    }
    removeButton.isEnabled = !model.isLoading && selected?.canEdit == true
    if model.isLoading { showStatus("正在切换 SSH 目标并关闭旧转发…", error: false) }
    else if let error = model.storageError { showStatus(error + " 修复文件后可点重新载入。", error: true) }
    else if !model.canSave { showStatus(LocalForwardStoreError.destinationRequired.localizedDescription, error: false) }
    else if editingID != nil && (selected == nil || selected?.configuration != editingBase) {
      showStatus(LocalForwardStoreError.changedElsewhere.localizedDescription, error: true)
    } else if let rule = selected {
      if case .failed(let message) = rule.state { showStatus(message, error: true) }
      else if let message = rule.clientError { showStatus(message, error: true) }
      else { showStatus(model.isConnected ? Self.stateText(rule.state) : "SSH 未连接，转发已停止。", error: false) }
    } else { showStatus(model.isConnected ? "保存规则后选中并启动。" : "可先保存规则，连接 SSH 后启动。", error: false) }
  }

  private func showStatus(_ message: String, error: Bool) {
    statusLabel.stringValue = message
    statusLabel.toolTip = message
    statusLabel.textColor = error ? .systemRed : .secondaryLabelColor
  }

  @discardableResult
  func saveChanges() -> Bool {
    guard displayedDestination == model.destination else {
      showStatus(LocalForwardStoreError.loading.localizedDescription, error: true)
      return false
    }
    guard let local = Int(localPortField.stringValue),
          let remote = kind == .socks ? 0 : Int(targetPortField.stringValue) else {
      showStatus(LocalForwardError.invalidConfiguration.localizedDescription, error: true)
      return false
    }
    do {
      editingID = try model.save(id: editingID,
        configuration: .init(localPort: local, targetHost: kind == .socks ? "" : targetHostField.stringValue,
                             targetPort: remote, kind: kind, listenHost: kind == .remote ? listenHost : "127.0.0.1"), expected: editingBase)
      editingBase = model.rules.first { $0.id == editingID }?.configuration
      render()
      return true
    } catch { showStatus(error.localizedDescription, error: true); return false }
  }

  func newRule() {
    editingID = nil
    editingBase = nil
    kindPopup.selectItem(at: 0)
    listenHostField.stringValue = "127.0.0.1"
    for field in [localPortField, targetHostField, targetPortField] { field.stringValue = "" }
    render()
    view.window?.makeFirstResponder(localPortField)
  }

  func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let rule = rows[row]
    let text: String
    switch tableColumn?.identifier.rawValue {
    case "local":
      let host = rule.configuration.listenHost.contains(":") ? "[\(rule.configuration.listenHost)]" : rule.configuration.listenHost
      text = (rule.configuration.kind == .remote ? "请求服务器 " : "") + "\(host):\(rule.configuration.localPort)"
    case "target":
      if rule.configuration.kind == .socks { text = "SOCKS5 · 客户端指定目标" }
      else {
        let host = rule.configuration.targetHost.contains(":") ? "[\(rule.configuration.targetHost)]" : rule.configuration.targetHost
        text = (rule.configuration.kind == .remote ? "本机 " : "") + "\(host):\(rule.configuration.targetPort)"
      }
    default: text = Self.stateText(rule.state)
    }
    let field = NSTextField(labelWithString: text)
    field.lineBreakMode = .byTruncatingMiddle; field.toolTip = text
    return field
  }
  func tableViewSelectionDidChange(_ notification: Notification) {
    loadSelectedRule()
  }

  private func loadSelectedRule() {
    guard !reloading, rows.indices.contains(table.selectedRow) else { return }
    let rule = rows[table.selectedRow]
    editingID = rule.id
    editingBase = rule.configuration
    kindPopup.selectItem(at: rule.configuration.kind == .socks ? 1 : (rule.configuration.kind == .remote ? 2 : 0))
    listenHostField.stringValue = rule.configuration.listenHost
    localPortField.stringValue = String(rule.configuration.localPort)
    targetHostField.stringValue = rule.configuration.targetHost
    targetPortField.stringValue = rule.configuration.kind == .socks ? "" : String(rule.configuration.targetPort)
    render()
  }

  /// NSTableView doesn't publish a selection change when clicking the selected row.
  /// An explicit click still reloads the preset so a stale draft can be recovered.
  @objc private func ruleClicked() { loadSelectedRule() }

  private static func stateText(_ state: LocalForwardRule.State) -> String {
    switch state {
    case .stopped: return "已停止"
    case .starting: return "正在启动…"
    case .stopping: return "正在停止…"
    case .running(_, let clients): return "监听中 · \(clients) 个客户端"
    case .failed(let message): return "失败：\(message)"
    }
  }

  @objc private func newTapped() { newRule() }
  @objc private func kindChanged() { render() }
  func comboBoxSelectionDidChange(_ notification: Notification) {
    if let value = listenHostField.objectValueOfSelectedItem as? String { listenHostField.stringValue = value }
    render()
  }
  @objc private func saveTapped() { _ = saveChanges() }
  @objc private func startTapped() {
    guard let editingID else { return }
    guard selected?.configuration == editingBase else {
      showStatus(LocalForwardStoreError.changedElsewhere.localizedDescription, error: true); return
    }
    model.start(editingID)
  }
  @objc private func stopTapped() { if let editingID { model.stop(editingID) } }
  @objc private func removeTapped() {
    guard let editingID, selected?.canEdit == true else { return }
    do { try model.remove(editingID, expected: editingBase); newRule() }
    catch { showStatus(error.localizedDescription, error: true) }
  }
  @objc private func reloadTapped() { model.reloadSavedRules() }
}
