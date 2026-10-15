import AppKit
import Combine
import TermesKit

@MainActor
final class ServerSidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
  let model: ServerListModel
  let searchField = NSSearchField()
  let table = ServerTableView()
  let openButton = NSButton(title: "连接", target: nil, action: nil)
  let editButton = NSButton(title: "编辑…", target: nil, action: nil)
  var onOpen: ((UUID) -> Void)?
  var onEdit: ((UUID) -> Void)?
  var onNew: (() -> Void)?
  var onDismiss: (() -> Void)?
  private let root = SidebarRootView(frame: .zero)
  private let heading = NSTextField(labelWithString: "服务器")
  private let emptyLabel = NSTextField(wrappingLabelWithString: "")
  private let scroll = NSScrollView()
  private let addButton = NSButton()
  private let commands = NSButton(title: "常用命令", target: nil, action: nil)
  private let keys = NSButton(title: "私钥", target: nil, action: nil)
  private let settings = NSButton(title: "设置", target: nil, action: nil)
  private var rows: [ConnectionProfile] = []
  private var observer: AnyCancellable?
  private var refreshing = false

  init(model: ServerListModel) { self.model = model; super.init(nibName: nil, bundle: nil) }
  required init?(coder: NSCoder) { fatalError("unsupported") }
  override func loadView() {
    root.fillColor = TermesColors.sidebar
    root.onLayout = { [weak self] in self?.layoutContent() }
    heading.font = .boldSystemFont(ofSize: 15)
    addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "新建连接")
    addButton.isBordered = false; addButton.target = self; addButton.action = #selector(newTapped)
    addButton.toolTip = "新建连接 (⌘T)"; addButton.setAccessibilityLabel("新建连接")
    searchField.placeholderString = "搜索名称、主机或用户名"
    searchField.setAccessibilityLabel("搜索服务器")
    searchField.delegate = self
    searchField.sendsSearchStringImmediately = true
    let column = NSTableColumn(identifier: .init("server")); column.width = 220
    table.addTableColumn(column); table.headerView = nil; table.rowHeight = 74
    table.intercellSpacing = NSSize(width: 0, height: 4)
    table.backgroundColor = .clear; table.selectionHighlightStyle = .regular
    table.dataSource = self; table.delegate = self
    table.target = self; table.doubleAction = #selector(openTapped)
    table.setAccessibilityLabel("已保存服务器")
    table.onOpen = { [weak self] in self?.openTapped() }
    table.onDismiss = { [weak self] in self?.onDismiss?() }
    scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
    scroll.automaticallyAdjustsContentInsets = false; scroll.documentView = table
    emptyLabel.textColor = .secondaryLabelColor; emptyLabel.alignment = .center
    emptyLabel.font = .systemFont(ofSize: 12)
    openButton.target = self; openButton.action = #selector(openTapped)
    editButton.target = self; editButton.action = #selector(editTapped)
    for button in [openButton, editButton] { button.bezelStyle = .rounded }
    for (button, symbol, action) in [
      (commands, "terminal", #selector(AppDelegate.manageSnippets)),
      (keys, "key", #selector(AppDelegate.manageKeys)),
      (settings, "gearshape", #selector(AppDelegate.showAppearance)),
    ] {
      button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: button.title)
      button.imagePosition = .imageLeading; button.alignment = .left; button.isBordered = false
      button.action = action; button.setAccessibilityLabel(button.title)
    }
    for view in [heading, addButton, searchField, scroll, emptyLabel, openButton, editButton, commands, keys, settings] {
      root.addSubview(view)
    }
    view = root
    reload()
    observer = model.objectWillChange.sink { [weak self] in
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.reload() } }
    }
  }

  func focusSearch() { _ = view; view.window?.makeFirstResponder(searchField) }
  func controlTextDidChange(_ obj: Notification) { model.search = searchField.stringValue; reload() }
  func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard rows.indices.contains(row) else { return nil }
    let profile = rows[row]
    let cell = ServerCellView()
    cell.name.stringValue = profile.name
    let host = profile.hostname.contains(":") ? "[\(profile.hostname)]" : profile.hostname
    cell.endpoint.stringValue = "\(profile.username)@\(host)" + (profile.port == 22 ? "" : ":\(profile.port)")
    cell.status.stringValue = model.sessionText(for: profile.id)
    cell.status.textColor = model.status(for: profile.id) == .idle ? .secondaryLabelColor : TabItemView.color(for: model.status(for: profile.id))
    cell.toolTip = "\(profile.name)\n\(cell.endpoint.stringValue)\n\(cell.status.stringValue)"
    cell.setAccessibilityLabel("\(profile.name)，\(cell.endpoint.stringValue)，\(cell.status.stringValue)")
    return cell
  }
  func tableViewSelectionDidChange(_ notification: Notification) {
    guard !refreshing else { return }
    let index = table.selectedRow
    model.select(rows.indices.contains(index) ? rows[index].id : nil)
    updateButtons()
  }
  private func reload() {
    guard isViewLoaded else { return }
    refreshing = true
    rows = model.filteredProfiles
    searchField.stringValue = model.search
    table.reloadData()
    if let id = model.selectedID, let index = rows.firstIndex(where: { $0.id == id }) {
      table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    } else { table.deselectAll(nil) }
    refreshing = false
    emptyLabel.stringValue = model.error ?? (model.profiles.isEmpty ? "还没有保存服务器\n点 ＋ 新建并保存连接" : "没有匹配的服务器")
    emptyLabel.isHidden = !rows.isEmpty && model.error == nil
    updateButtons(); root.needsLayout = true
  }
  private func updateButtons() {
    let visibleSelection = rows.contains { $0.id == model.selectedID }
    openButton.isEnabled = visibleSelection && model.error == nil
    editButton.isEnabled = openButton.isEnabled
  }
  @objc private func openTapped() {
    guard openButton.isEnabled, let id = model.selectedID else { return }
    onOpen?(id)
  }
  @objc private func editTapped() {
    guard editButton.isEnabled, let id = model.selectedID else { return }
    onEdit?(id)
  }
  @objc private func newTapped() { onNew?() }
  private func layoutContent() {
    let width = root.bounds.width, height = root.bounds.height
    heading.frame = NSRect(x: 14, y: height - 32, width: width - 56, height: 20)
    addButton.frame = NSRect(x: width - 38, y: height - 36, width: 26, height: 28)
    searchField.frame = NSRect(x: 12, y: height - 70, width: width - 24, height: 28)
    scroll.frame = NSRect(x: 6, y: 134, width: width - 12, height: max(0, height - 214))
    table.tableColumns.first?.width = scroll.contentSize.width
    emptyLabel.frame = NSRect(x: 18, y: max(134, height - 142), width: width - 36, height: 52)
    openButton.frame = NSRect(x: 12, y: 100, width: 112, height: 28)
    editButton.frame = NSRect(x: 132, y: 100, width: width - 144, height: 28)
    for (index, button) in [settings, keys, commands].enumerated() {
      button.frame = NSRect(x: 14, y: 8 + CGFloat(index) * 28, width: width - 28, height: 26)
    }
  }
}

final class ServerTableView: NSTableView {
  var onOpen: (() -> Void)?
  var onDismiss: (() -> Void)?
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 36 || event.keyCode == 76 { onOpen?() }
    else if event.keyCode == 53 { onDismiss?() }
    else { super.keyDown(with: event) }
  }
}

private final class SidebarRootView: ChromeView {
  var onLayout: (() -> Void)?
  override func layout() { super.layout(); onLayout?() }
}

private final class ServerCellView: NSTableCellView {
  let name = NSTextField(labelWithString: "")
  let endpoint = NSTextField(labelWithString: "")
  let status = NSTextField(labelWithString: "")
  private let icon = NSImageView()
  override init(frame: NSRect) {
    super.init(frame: frame)
    icon.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)
    name.font = .boldSystemFont(ofSize: 13)
    endpoint.font = .systemFont(ofSize: 11); endpoint.textColor = .secondaryLabelColor
    status.font = .systemFont(ofSize: 10)
    for label in [name, endpoint, status] { label.lineBreakMode = .byTruncatingTail }
    for view in [icon, name, endpoint, status] { addSubview(view) }
  }
  required init?(coder: NSCoder) { fatalError("unsupported") }
  override func layout() {
    super.layout()
    icon.frame = NSRect(x: 6, y: 31, width: 22, height: 22)
    name.frame = NSRect(x: 36, y: 49, width: max(0, bounds.width - 42), height: 18)
    endpoint.frame = NSRect(x: 36, y: 29, width: max(0, bounds.width - 42), height: 16)
    status.frame = NSRect(x: 36, y: 10, width: max(0, bounds.width - 42), height: 16)
  }
}
