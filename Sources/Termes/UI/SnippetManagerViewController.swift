import AppKit
import SnapKit
import Combine
import TermesKit

@MainActor
final class SnippetManagerViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
  private let store: SnippetStore
  private var observer: AnyCancellable?
  private var reloading = false
  private var original: Snippet?
  private(set) var editingID: UUID?
  private(set) var snippets: [Snippet] = []
  let table = NSTableView()
  let nameField = NSTextField()
  let commandField = NSTextField()
  let groupField = NSComboBox()
  let kindPopup = NSPopUpButton(frame: .zero, pullsDown: false)
  let templateButton = NSButton(checkboxWithTitle: "参数模板（{{name}}）", target: nil, action: nil)
  let scriptView = NSTextView()
  private let scriptScroll = NSScrollView()
  private var commandRow: NSStackView!
  private var lastKind: Snippet.Kind = .command
  private var selectedKind: Snippet.Kind { kindPopup.indexOfSelectedItem == 1 ? .script : .command }
  private var commandText: String { selectedKind == .script ? scriptView.string : commandField.stringValue }
  let errorLabel = NSTextField(wrappingLabelWithString: "")
  private let deleteButton = NSButton(title: "删除…", target: nil, action: nil)

  init(store: SnippetStore) {
    self.store = store
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError("unsupported") }

  override func loadView() {
    view = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 480))
    for (id, title, width) in [("name", "名称", 160.0), ("group", "分组", 100.0), ("kind", "类型", 90.0), ("command", "内容", 300.0)] {
      let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
      column.title = title
      column.width = width
      column.minWidth = 40
      table.addTableColumn(column)
    }
    table.columnAutoresizingStyle = .noColumnAutoresizing
    table.autoresizingMask = [.width]
    table.allowsMultipleSelection = false
    table.dataSource = self
    table.delegate = self
    table.setAccessibilityLabel("常用命令列表")
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.scrollerStyle = .legacy
    scroll.documentView = table
    let new = NSButton(title: "新建", target: self, action: #selector(newTapped))
    let save = NSButton(title: "保存", target: self, action: #selector(saveTapped))
    deleteButton.target = self
    deleteButton.action = #selector(deleteTapped)
    for button in [new, save, deleteButton] { button.bezelStyle = .rounded }
    let buttons = NSStackView(views: [new, save, deleteButton])
    let hint = NSTextField(wrappingLabelWithString: "命令插入后按回车执行；脚本或参数模板先预览。参数按原文替换，可在模板中添加引号。内容以普通文本保存在本机，请勿保存密码。")
    hint.textColor = .secondaryLabelColor
    hint.maximumNumberOfLines = 3
    errorLabel.textColor = .systemRed
    errorLabel.maximumNumberOfLines = 3
    errorLabel.isHidden = true
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    stack.addArrangedSubview(scroll)
    scroll.snp.makeConstraints { make in
      make.width.equalTo(stack.snp.width)
      make.height.greaterThanOrEqualTo(120)
    }
    scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
    let editor = NSStackView()
    editor.orientation = .vertical; editor.alignment = .leading; editor.spacing = 10
    let nameLabel = NSTextField(labelWithString: "名称")
    let groupLabel = NSTextField(labelWithString: "分组")
    nameLabel.snp.makeConstraints { make in make.width.equalTo(44) }
    nameField.setAccessibilityLabel("常用命令名称")
    groupField.setAccessibilityLabel("常用命令分组")
    groupField.placeholderString = "未分组"
    groupField.snp.makeConstraints { make in make.width.equalTo(150) }
    nameField.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let metadata = NSStackView(views: [nameLabel, nameField, groupLabel, groupField])
    metadata.spacing = 8
    editor.addArrangedSubview(metadata)
    kindPopup.addItems(withTitles: ["单行命令", "多行脚本"])
    kindPopup.target = self; kindPopup.action = #selector(kindChanged)
    kindPopup.setAccessibilityLabel("常用命令类型")
    editor.addArrangedSubview(NSStackView(views: [kindPopup, templateButton]))
    commandField.usesSingleLineMode = true
    commandField.setAccessibilityLabel("常用命令内容")
    commandField.setContentHuggingPriority(.defaultLow, for: .horizontal)
    commandRow = NSStackView(views: [NSTextField(labelWithString: "命令"), commandField])
    commandRow.spacing = 8
    editor.addArrangedSubview(commandRow)
    scriptView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    scriptView.isRichText = false
    scriptView.allowsUndo = true
    scriptView.isAutomaticQuoteSubstitutionEnabled = false
    scriptView.isAutomaticDashSubstitutionEnabled = false
    scriptView.isAutomaticTextReplacementEnabled = false
    scriptView.isAutomaticSpellingCorrectionEnabled = false
    scriptView.isContinuousSpellCheckingEnabled = false
    scriptView.isVerticallyResizable = true
    scriptView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    scriptView.isHorizontallyResizable = false
    scriptView.textContainer?.widthTracksTextView = true
    scriptView.autoresizingMask = [.width]
    scriptView.setAccessibilityLabel("多行脚本内容")
    scriptScroll.documentView = scriptView
    scriptScroll.hasVerticalScroller = true
    scriptScroll.borderType = .bezelBorder
    scriptScroll.snp.makeConstraints { make in make.height.equalTo(130) }
    editor.addArrangedSubview(scriptScroll)
    scriptScroll.isHidden = true
    commandField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    nameField.placeholderString = "例如：查看磁盘空间"
    commandField.placeholderString = "df -h"
    for label in [hint, errorLabel] {
      editor.addArrangedSubview(label)
      label.snp.makeConstraints { make in make.width.equalTo(editor.snp.width) }
    }
    editor.addArrangedSubview(buttons)
    for row in [metadata, commandRow!, scriptScroll] {
      row.snp.makeConstraints { make in make.width.equalTo(editor.snp.width) }
    }
    let formScroll = NSScrollView()
    formScroll.hasVerticalScroller = true
    formScroll.scrollerStyle = .legacy
    let document = SnippetFormDocumentView()
    formScroll.documentView = document
    document.addSubview(editor)
    document.snp.makeConstraints { make in make.width.equalTo(formScroll.contentView.snp.width) }
    editor.snp.makeConstraints { make in make.edges.equalToSuperview() }
    stack.addArrangedSubview(formScroll)
    formScroll.snp.makeConstraints { make in
      make.width.equalTo(stack.snp.width)
      make.height.greaterThanOrEqualTo(180)
      make.height.equalTo(220).priority(.high)
    }
    view.addSubview(stack)
    stack.snp.makeConstraints { make in make.edges.equalToSuperview().inset(20).labeled("SnippetManager.column") }
    reloadSnippets()
    observer = store.didChange.sink { [weak self] in self?.reloadSnippets() }
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    if let clip = table.superview as? NSClipView {
      let available = max(160, clip.bounds.width - table.intercellSpacing.width * 4)
      for (column, fraction) in zip(table.tableColumns, [0.25, 0.18, 0.16, 0.41]) {
        column.width = available * fraction
      }
      table.setFrameSize(NSSize(width: clip.bounds.width, height: table.frame.height))
    }
    if !scriptScroll.isHidden {
      scriptView.minSize = scriptScroll.contentSize
      scriptView.setFrameSize(NSSize(width: scriptScroll.contentSize.width,
        height: max(scriptView.frame.height, scriptScroll.contentSize.height)))
      scriptView.sizeToFit()
    }
  }

  private var hasDraftChanges: Bool {
    nameField.stringValue != (original?.name ?? "") || commandText != (original?.command ?? "")
      || groupField.stringValue != (original?.group ?? "") || selectedKind != (original?.kind ?? .command)
      || (templateButton.state == .on) != (original?.usesParameters ?? false)
  }

  func reloadSnippets() {
    do {
      let items = try store.all()
      let preserveDraft = hasDraftChanges
      reloading = true
      defer { reloading = false }
      snippets = items
      let groupDraft = groupField.stringValue
      groupField.removeAllItems()
      var groups = Set<String>()
      for item in items where !item.group.isEmpty && groups.insert(item.group).inserted { groupField.addItem(withObjectValue: item.group) }
      groupField.stringValue = groupDraft
      table.reloadData()
      if let row = snippets.firstIndex(where: { $0.id == editingID }) {
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        if !preserveDraft { loadEditor(snippets[row]) }
      } else {
        table.deselectAll(nil)
        if !preserveDraft { loadEditor(nil) }
      }
      deleteButton.isEnabled = snippets.contains { $0.id == editingID }
    } catch { showError(error) }
  }

  func numberOfRows(in tableView: NSTableView) -> Int { snippets.count }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard snippets.indices.contains(row) else { return nil }
    let item = snippets[row]
    let text: String
    switch tableColumn?.identifier.rawValue {
    case "name": text = item.name
    case "group": text = item.group.isEmpty ? "未分组" : item.group
    case "kind": text = (item.kind == .script ? "脚本" : "命令") + (item.usesParameters ? "模板" : "")
    default: text = item.command.replacingOccurrences(of: "\n", with: " ↵ ")
    }
    let label = NSTextField(labelWithString: text)
    label.lineBreakMode = .byTruncatingTail
    label.toolTip = text
    return label
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    guard !reloading, snippets.indices.contains(table.selectedRow) else { return }
    loadEditor(snippets[table.selectedRow])
    errorLabel.isHidden = true
    deleteButton.isEnabled = true
  }

  private func loadEditor(_ snippet: Snippet?) {
    original = snippet
    editingID = snippet?.id
    nameField.stringValue = snippet?.name ?? ""
    commandField.stringValue = snippet?.command ?? ""
    scriptView.string = snippet?.command ?? ""
    scriptView.undoManager?.removeAllActions()
    groupField.stringValue = snippet?.group ?? ""
    lastKind = snippet?.kind ?? .command
    kindPopup.selectItem(at: lastKind == .script ? 1 : 0)
    templateButton.state = snippet?.usesParameters == true ? .on : .off
    renderKind()
  }

  func newSnippet() {
    _ = view
    view.window?.makeFirstResponder(nil)
    table.deselectAll(nil)
    loadEditor(nil)
    errorLabel.isHidden = true
    deleteButton.isEnabled = false
    view.window?.makeFirstResponder(nameField)
  }

  @discardableResult
  func saveChanges() -> Bool {
    _ = view
    view.window?.makeFirstResponder(nil)
    do {
      let saved = try store.save(id: editingID, name: nameField.stringValue, command: commandText,
        group: groupField.stringValue, kind: selectedKind, usesParameters: templateButton.state == .on, expected: original)
      loadEditor(saved)
      reloadSnippets()
      table.scrollRowToVisible(table.selectedRow)
      errorLabel.isHidden = true
      return true
    } catch { showError(error); return false }
  }

  @discardableResult
  func deleteSnippet(_ id: UUID) -> Bool {
    do {
      try store.delete(id)
      if editingID == id { newSnippet() }
      errorLabel.isHidden = true
      return true
    } catch { showError(error); return false }
  }

  private func showError(_ error: Error) {
    errorLabel.stringValue = error.localizedDescription
    errorLabel.isHidden = false
  }

  @objc private func kindChanged() {
    if selectedKind != lastKind {
      if selectedKind == .script { scriptView.string = commandField.stringValue }
      else { commandField.stringValue = scriptView.string }
      lastKind = selectedKind
    }
    renderKind()
  }
  private func renderKind() {
    commandRow.isHidden = selectedKind == .script
    scriptScroll.isHidden = selectedKind != .script
  }

  @objc private func newTapped() { newSnippet() }
  @objc private func saveTapped() { saveChanges() }
  @objc private func deleteTapped() {
    guard let item = snippets.first(where: { $0.id == editingID }), let window = view.window else { return }
    let alert = NSAlert()
    alert.messageText = "删除常用命令“\(item.name)”？"
    alert.addButton(withTitle: "删除")
    alert.addButton(withTitle: "取消")
    alert.beginSheetModal(for: window) { [weak self] response in
      guard response == .alertFirstButtonReturn else { return }
      self?.deleteSnippet(item.id)
    }
  }
}

private final class SnippetFormDocumentView: NSView {
  override var isFlipped: Bool { true }
}
