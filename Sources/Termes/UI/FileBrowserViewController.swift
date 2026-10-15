import AppKit
import Combine
import TermesKit
import SSHCore

@MainActor
final class FileBrowserViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
  let model: FileBrowserModel
  let table = NSTableView()
  let pathField = NSTextField()
  let localBrowser: LocalFileBrowserViewController
  private let serverName: String
  private let usesCompactTabs: Bool
  private var editorWindows: [String: RemoteFileEditorWindowController] = [:]
  private let remoteRoot = FileLayoutView()
  private let heading = NSTextField(labelWithString: "服务器文件 · 拖入文件上传到当前目录")
  private var uploadSheetPending = false
  private let statusLabel = NSTextField(wrappingLabelWithString: "")
  private let progressBar = NSProgressIndicator()
  private let progressLabel = NSTextField(labelWithString: "")
  private let tableScroll = FileUploadDropScrollView()
  private let scroll = NSScrollView()
  private let document = FlippedFileView()
  private lazy var transferQueue = FileTransferQueueViewController(queue: model.transfers)
  private var observer: AnyCancellable?
  private var displayedEntries: [SFTPEntry] = []
  private(set) var showsTransferQueue = false
  private var previousJobCount = 0
  let transferDisclosure = NSButton(title: "传输队列（0）", target: nil, action: nil)
  private lazy var moreActions = button("更多文件操作", #selector(showFileActions))
  private lazy var up = button("上级", #selector(goUp))
  private lazy var refresh = button("刷新", #selector(refreshFiles))
  private lazy var upload = button("上传…", #selector(uploadFile))
  private lazy var download = button("下载…", #selector(downloadFile))
  private lazy var mkdir = button("新建目录…", #selector(makeDirectory))
  private lazy var rename = button("重命名…", #selector(renameFile))
  private lazy var delete = button("删除…", #selector(deleteFile))
  private lazy var edit = button("编辑…", #selector(editFile))
  private lazy var permissions = button("权限…", #selector(editPermissions))
  private lazy var cancel = button("取消", #selector(cancelTransfer))

  init(model: FileBrowserModel, localModel: LocalFileBrowserModel = LocalFileBrowserModel(), serverName: String = "服务器",
       usesCompactTabs: Bool = false) {
    self.model = model
    self.serverName = serverName; self.usesCompactTabs = usesCompactTabs
    localBrowser = LocalFileBrowserViewController(model: localModel)
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError("unsupported") }

  override func loadView() {
    addChild(localBrowser)
    addChild(transferQueue)
    view = LocalRemoteFilesView(local: localBrowser.view, remote: remoteRoot, usesTabs: usesCompactTabs)
    localBrowser.onUpload = { [weak self] urls in self?.requestUpload(urls) }
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.documentView = document
    remoteRoot.addSubview(scroll)
    remoteRoot.onLayout = { [weak self] in self?.layoutContent() }
    heading.font = .boldSystemFont(ofSize: 12)
    heading.lineBreakMode = .byTruncatingTail
    heading.toolTip = "拖入本机文件或文件夹上传到当前远端目录，可多选；文件夹保留子目录和空目录。"
    if usesCompactTabs {
      heading.stringValue = "拖入文件上传到当前目录"; heading.font = .systemFont(ofSize: 11); heading.textColor = .secondaryLabelColor
      for (button, symbol, label) in [(up, "arrow.up", "上级目录"), (refresh, "arrow.clockwise", "刷新远端文件"),
                                      (upload, "arrow.up.doc", "上传文件或文件夹…"), (download, "arrow.down.doc", "下载选中条目…"),
                                      (moreActions, "ellipsis", "更多文件操作")] {
        button.title = ""; button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.isBordered = false; button.toolTip = label; button.setAccessibilityLabel(label)
      }
      for button in [mkdir, rename, delete, edit, permissions] { button.isHidden = true }
    }
    transferDisclosure.isBordered = false; transferDisclosure.alignment = .left; transferDisclosure.font = .systemFont(ofSize: 11, weight: .medium)
    transferDisclosure.imagePosition = .imageLeft
    transferDisclosure.target = self; transferDisclosure.action = #selector(toggleTransferQueue)
    transferDisclosure.setAccessibilityLabel("展开或收起传输队列")
    transferDisclosure.isHidden = !usesCompactTabs; moreActions.isHidden = !usesCompactTabs
    pathField.usesSingleLineMode = true
    pathField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    pathField.placeholderString = "远端目录（回车打开）"
    pathField.setAccessibilityLabel("远端目录")
    pathField.target = self; pathField.action = #selector(openPath)
    for (id, title, width) in [("name", "名称", 180.0), ("size", "大小", 75.0), ("mode", "权限", 82.0), ("date", "修改时间", 125.0)] {
      let column = NSTableColumn(identifier: .init(id))
      column.title = title; column.width = width; column.minWidth = id == "name" ? 100 : 60
      table.addTableColumn(column)
    }
    table.columnAutoresizingStyle = .noColumnAutoresizing
    table.allowsMultipleSelection = false
    table.dataSource = self; table.delegate = self
    table.target = self; table.doubleAction = #selector(openDirectory)
    table.setAccessibilityLabel("远端文件列表")
    table.registerForDraggedTypes([.fileURL])
    tableScroll.hasVerticalScroller = true; tableScroll.hasHorizontalScroller = true
    tableScroll.documentView = table
    tableScroll.readFiles = { [weak self] pasteboard in self?.droppedFiles(from: pasteboard) }
    tableScroll.onDrop = { [weak self] files in self?.requestUpload(files) }
    progressBar.style = .bar
    progressLabel.font = .systemFont(ofSize: 10)
    progressLabel.textColor = .secondaryLabelColor
    statusLabel.font = .systemFont(ofSize: 11)
    statusLabel.maximumNumberOfLines = 3
    for v in [heading, pathField, up, refresh, upload, download, mkdir, rename, delete, edit, permissions, moreActions,
              tableScroll, progressBar, progressLabel, cancel, statusLabel, transferDisclosure] {
      document.addSubview(v)
    }
    document.addSubview(transferQueue.view)
    observer = model.objectWillChange.sink { [weak self] in
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.render() } }
    }
    render()
  }

  func start() { _ = view; localBrowser.start(); model.refresh() }
  func shutdown() { observer = nil; localBrowser.shutdown(); model.shutdown() }

  private func button(_ title: String, _ action: Selector) -> NSButton {
    let button = NSButton(title: title, target: self, action: action)
    button.bezelStyle = .rounded; button.controlSize = .small
    return button
  }

  private func layoutContent() {
    scroll.frame = remoteRoot.bounds
    let width = max(220, scroll.contentSize.width)
    if usesCompactTabs { layoutCompact(width: width); return }
    let height = max(548, scroll.contentSize.height)
    document.frame = NSRect(x: 0, y: 0, width: width, height: height)
    heading.frame = NSRect(x: 8, y: 6, width: width - 16, height: 18)
    pathField.frame = NSRect(x: 8, y: 32, width: width - 16, height: 24)
    for (index, button) in [up, refresh, upload, download].enumerated() {
      button.frame = NSRect(x: 6 + CGFloat(index) * (width - 12) / 4, y: 60, width: (width - 12) / 4, height: 24)
    }
    for (index, button) in [mkdir, rename, delete].enumerated() {
      button.frame = NSRect(x: 6 + CGFloat(index) * (width - 12) / 3, y: 87, width: (width - 12) / 3, height: 24)
    }
    for (index, button) in [edit, permissions].enumerated() {
      button.frame = NSRect(x: 6 + CGFloat(index) * (width - 12) / 2, y: 114, width: (width - 12) / 2, height: 24)
    }
    tableScroll.frame = NSRect(x: 8, y: 144, width: width - 16, height: height - 420)
    progressBar.frame = NSRect(x: 8, y: height - 268, width: width - 76, height: 14)
    cancel.frame = NSRect(x: width - 62, y: height - 275, width: 54, height: 26)
    progressLabel.frame = NSRect(x: 8, y: height - 249, width: width - 16, height: 16)
    statusLabel.frame = NSRect(x: 8, y: height - 230, width: width - 16, height: 40)
    transferQueue.view.frame = NSRect(x: 8, y: height - 184, width: width - 16, height: 178)
  }

  private func layoutCompact(width: CGFloat) {
    let hasProgress = model.isBusy || model.progress != nil
    let queueHeight: CGFloat = showsTransferQueue ? 178 : 0
    let progressHeight: CGFloat = hasProgress ? 42 : 0
    let height = max(320 + queueHeight + progressHeight, scroll.contentSize.height)
    document.frame = NSRect(x: 0, y: 0, width: width, height: height)
    pathField.frame = NSRect(x: 8, y: 8, width: width - 76, height: 24)
    up.frame = NSRect(x: width - 62, y: 7, width: 24, height: 26)
    refresh.frame = NSRect(x: width - 34, y: 7, width: 24, height: 26)
    heading.frame = NSRect(x: 8, y: 46, width: max(0, width - 108), height: 16)
    for (index, button) in [upload, download, moreActions].enumerated() {
      button.frame = NSRect(x: width - 92 + CGFloat(index) * 28, y: 40, width: 24, height: 26)
    }
    let bottom = height - queueHeight - progressHeight - 70
    tableScroll.frame = NSRect(x: 8, y: 76, width: width - 16, height: max(100, bottom - 82))
    progressBar.frame = NSRect(x: 8, y: bottom + 4, width: width - 76, height: 14)
    cancel.frame = NSRect(x: width - 62, y: bottom - 3, width: 54, height: 26)
    progressLabel.frame = NSRect(x: 8, y: bottom + 22, width: width - 16, height: 16)
    progressBar.isHidden = !hasProgress; progressLabel.isHidden = !hasProgress; cancel.isHidden = !hasProgress
    statusLabel.frame = NSRect(x: 8, y: bottom + progressHeight + 4, width: width - 16, height: 34)
    transferDisclosure.frame = NSRect(x: 8, y: height - queueHeight - 30, width: width - 16, height: 24)
    transferQueue.view.isHidden = !showsTransferQueue
    transferQueue.view.frame = NSRect(x: 8, y: height - queueHeight, width: width - 16, height: queueHeight)
  }

  @objc func toggleTransferQueue() { showsTransferQueue.toggle(); render() }

  func fileActionsMenu() -> NSMenu {
    let menu = NSMenu(); menu.autoenablesItems = false
    for button in [mkdir, rename, edit, permissions, delete] {
      let item = menu.addItem(withTitle: button.title, action: button.action, keyEquivalent: "")
      item.target = self; item.isEnabled = button.isEnabled
    }
    return menu
  }
  @objc private func showFileActions() {
    fileActionsMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: moreActions.bounds.maxY), in: moreActions)
  }

  private var selected: SFTPEntry? {
    displayedEntries.indices.contains(table.selectedRow) ? displayedEntries[table.selectedRow] : nil
  }

  private func render() {
    if displayedEntries != model.entries {
      let path = selected?.path
      displayedEntries = model.entries
      table.reloadData()
      if let row = displayedEntries.firstIndex(where: { $0.path == path }) {
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
      } else { table.deselectAll(nil) }
    }
    if pathField.currentEditor() == nil { pathField.stringValue = model.directory ?? "" }
    let enabled = model.isConnected && !model.isBrowsingBusy && !uploadSheetPending
    pathField.isEnabled = enabled
    up.isEnabled = enabled && model.directory != nil
    refresh.isEnabled = enabled
    upload.isEnabled = enabled && model.directory != nil
    localBrowser.canUpload = canReceiveUpload
    mkdir.isEnabled = upload.isEnabled
    rename.isEnabled = enabled && selected != nil
    delete.isEnabled = rename.isEnabled
    edit.isEnabled = enabled && selected?.kind == .file
    permissions.isEnabled = enabled && (selected?.kind == .file || selected?.kind == .directory)
    moreActions.isEnabled = enabled
    download.isEnabled = enabled && (selected?.kind == .file || selected?.kind == .symbolicLink || selected?.kind == .directory)
    table.isEnabled = enabled
    cancel.isEnabled = model.isBusy
    statusLabel.stringValue = model.error ?? model.status
    statusLabel.textColor = model.error == nil ? .secondaryLabelColor : .systemRed
    statusLabel.toolTip = statusLabel.stringValue
    progressBar.isIndeterminate = model.isBusy && model.progress?.total == nil
    progressBar.isHidden = !model.isBusy && model.progress == nil
    if progressBar.isIndeterminate { progressBar.startAnimation(nil) } else { progressBar.stopAnimation(nil) }
    if let p = model.progress {
      progressBar.maxValue = Double(max(1, p.total ?? p.completed))
      progressBar.doubleValue = Double(p.completed)
      let completed = ByteCountFormatter.string(fromByteCount: Int64(clamping: p.completed), countStyle: .file)
      let total = p.total.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .file) }
      progressLabel.stringValue = total.map { "\(completed) / \($0)" } ?? completed
    } else { progressBar.doubleValue = 0; progressLabel.stringValue = model.isBusy ? "正在处理…" : "" }
    if usesCompactTabs {
      let count = model.transfers.jobs.count
      if count > previousJobCount { showsTransferQueue = true }
      previousJobCount = count
      transferDisclosure.title = "传输队列（\(count)）"
      transferDisclosure.image = NSImage(systemSymbolName: showsTransferQueue ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
      layoutContent()
    }
  }

  private var canReceiveUpload: Bool {
    model.isConnected && !model.isBrowsingBusy && model.directory != nil && !uploadSheetPending
  }

  /// Finder and the local table both export public.file-url; use the same validation and
  /// confirmation path as the upload button.
  func droppedFiles(from pasteboard: NSPasteboard) -> [URL]? {
    guard canReceiveUpload,
          let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
          let files = try? UploadSelection.validated(urls), !files.isEmpty else { return nil }
    return files
  }
  func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo,
                 proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
    guard info.draggingSourceOperationMask.contains(.copy), droppedFiles(from: info.draggingPasteboard) != nil else { return [] }
    tableView.setDropRow(-1, dropOperation: .on)
    return .copy
  }
  func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo,
                 row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
    guard let files = droppedFiles(from: info.draggingPasteboard) else { return false }
    requestUpload(files)
    return true
  }

  func requestUpload(_ urls: [URL]) {
    guard canReceiveUpload, let directory = model.directory else { return }
    let files: [URL]
    do { files = try UploadSelection.validated(urls) }
    catch {
      guard let window = view.window else { return }
      let alert = NSAlert(); alert.messageText = "无法上传"; alert.informativeText = error.localizedDescription
      alert.beginSheetModal(for: window)
      return
    }
    let collisions = model.entries.filter { entry in files.contains { $0.lastPathComponent == entry.name } }
    guard !collisions.isEmpty else { model.upload(files); return }
    // A directory cannot be replaced by file contents. Links/special entries also require
    // explicit manual resolution rather than silently changing their type.
    if collisions.contains(where: { entry in
      entry.kind != .file || files.contains { url in
        url.lastPathComponent == entry.name &&
          (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeDirectory
      }
    }) {
      guard let window = view.window else { return }
      let alert = NSAlert(); alert.messageText = "目标名称已被占用"
      alert.informativeText = "文件夹不会与已有目标合并或替换目录、链接及特殊文件。请重命名本机条目或选择其他远端目录。"
      alert.beginSheetModal(for: window)
      return
    }
    guard let window = view.window else { return }
    uploadSheetPending = true
    render()
    let alert = NSAlert(); alert.messageText = "覆盖 \(collisions.count) 个远端文件？"; alert.alertStyle = .warning
    let preview = collisions.prefix(5).map(\.name).joined(separator: "\n")
    alert.informativeText = "目标目录：\(directory)\n\(preview)\(collisions.count > 5 ? "\n…" : "")\n上传完成后替换这些文件，其他文件按顺序上传。"
    alert.addButton(withTitle: "覆盖并上传"); alert.addButton(withTitle: "取消")
    let names = Set(collisions.map(\.name))
    alert.beginSheetModal(for: window) { [weak self] response in
      guard let self else { return }
      self.uploadSheetPending = false
      self.render()
      guard response == .alertFirstButtonReturn, self.canReceiveUpload, self.model.directory == directory else { return }
      self.model.upload(files, overwriting: names)
    }
  }

  func numberOfRows(in tableView: NSTableView) -> Int { displayedEntries.count }
  func tableViewSelectionDidChange(_ notification: Notification) { render() }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let entry = displayedEntries[row]
    let text: String
    switch tableColumn?.identifier.rawValue {
    case "mode": text = entry.permissions.flatMap { try? UnixPermissions($0).octal } ?? "—"
    case "size": text = entry.kind == .directory ? "目录" : entry.size.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .file) } ?? "—"
    case "date": text = entry.modifiedAt.map { $0.formatted(date: .numeric, time: .shortened) } ?? "—"
    default: text = (entry.kind == .directory ? "▸ " : entry.kind == .symbolicLink ? "↗ " : "") + entry.name
    }
    let field = NSTextField(labelWithString: text)
    field.font = .systemFont(ofSize: 12); field.lineBreakMode = .byTruncatingMiddle
    field.toolTip = entry.path
    return field
  }

  @objc private func openPath() { model.navigate(pathField.stringValue) }
  @objc private func goUp() { model.goUp() }
  @objc private func refreshFiles() { model.refresh() }
  @objc private func cancelTransfer() { model.cancel() }
  @objc private func openDirectory() {
    guard model.isConnected, !model.isBrowsingBusy, let entry = selected,
          entry.kind == .directory || entry.kind == .symbolicLink else { return }
    model.navigate(entry.path)
  }

  @objc private func uploadFile() {
    guard let window = view.window, model.isConnected, !model.isBrowsingBusy else { return }
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
    panel.prompt = "上传"
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let self else { return }
      self.requestUpload(panel.urls)
    }
  }

  @objc private func downloadFile() {
    guard let window = view.window, let entry = selected, model.isConnected, !model.isBrowsingBusy else { return }
    if entry.kind == .directory {
      let panel = NSOpenPanel()
      panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
      panel.prompt = "下载到此文件夹"
      panel.message = "下载 \(entry.name) 及其全部内容。同名目标已存在时不会合并或覆盖。"
      panel.beginSheetModal(for: window) { [weak self] response in
        guard response == .OK, let self, let url = panel.url else { return }
        self.model.download(entry, to: url.appendingPathComponent(entry.name, isDirectory: true))
      }
      return
    }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = entry.name; panel.prompt = "下载"
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let self, let url = panel.url else { return }
      self.model.download(entry, to: url, overwrite: FileManager.default.fileExists(atPath: url.path))
    }
  }

  @objc private func makeDirectory() {
    promptName("新建目录", initial: "", button: "创建") { [weak self] name in self?.model.createDirectory(name: name) }
  }
  @objc private func editPermissions() {
    guard let entry = selected, view.window != nil else { return }
    let controller = RemotePermissionsViewController(model: model.makePermissionsEditor(for: entry))
    controller.onDismiss = { [weak self] in self?.model.refresh() }
    presentAsSheet(controller)
  }
  @objc private func editFile() {
    guard let entry = selected else { return }
    if let existing = editorWindows[entry.path] { existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return }
    let window = RemoteFileEditorWindowController(model: model.makeEditor(for: entry), serverName: serverName)
    window.onClosed = { [weak self] in self?.editorWindows.removeValue(forKey: entry.path); self?.model.refresh() }
    editorWindows[entry.path] = window
    window.showWindow(nil); window.window?.makeKeyAndOrderFront(nil)
  }
  @objc private func renameFile() {
    guard let entry = selected else { return }
    promptName("重命名", initial: entry.name, button: "重命名") { [weak self] name in self?.model.rename(entry, to: name) }
  }
  @objc private func deleteFile() {
    guard let entry = selected else { return }
    confirm("删除 \(entry.name)？", detail: "此操作无法撤销。仅删除文件或空目录；符号链接只删除链接。", button: "删除") { [weak self] in
      self?.model.remove(entry)
    }
  }

  private func promptName(_ title: String, initial: String, button: String, completion: @escaping @MainActor (String) -> Void) {
    guard let window = view.window, model.isConnected, !model.isBrowsingBusy else { return }
    let alert = NSAlert(); alert.messageText = title
    alert.addButton(withTitle: button); alert.addButton(withTitle: "取消")
    let field = NSTextField(string: initial)
    field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
    field.setAccessibilityLabel("文件名称")
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    alert.beginSheetModal(for: window) { response in
      if response == .alertFirstButtonReturn { completion(field.stringValue) }
    }
  }
  private func confirm(_ title: String, detail: String, button: String, completion: @escaping @MainActor () -> Void) {
    guard let window = view.window, model.isConnected, !model.isBrowsingBusy else { return }
    let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail; alert.alertStyle = .warning
    alert.addButton(withTitle: button); alert.addButton(withTitle: "取消")
    alert.beginSheetModal(for: window) { response in if response == .alertFirstButtonReturn { completion() } }
  }
}

/// Functional controls for queued batches; visual redesign remains a later task.
@MainActor
final class FileTransferQueueViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
  let queue: FileTransferQueue
  let table = NSTableView()
  private let heading = NSTextField(labelWithString: "传输队列 · 最多 2 批并行")
  private let scroll = NSScrollView()
  private var observer: AnyCancellable?
  private var displayed: [FileTransferJob] = []
  private lazy var pause = NSButton(title: "暂停", target: self, action: #selector(pauseJob))
  private lazy var resume = NSButton(title: "继续 / 重试", target: self, action: #selector(resumeJob))
  private lazy var cancel = NSButton(title: "取消任务", target: self, action: #selector(cancelJob))
  private lazy var clear = NSButton(title: "清除已结束", target: self, action: #selector(clearJobs))
  init(queue: FileTransferQueue) { self.queue = queue; super.init(nibName: nil, bundle: nil) }
  required init?(coder: NSCoder) { fatalError("unsupported") }
  override func loadView() {
    let root = FileLayoutView(); view = root
    heading.font = .boldSystemFont(ofSize: 11)
    heading.toolTip = "普通文件继续已传部分，当前文件夹重新传输。收起工具或切换标签保留队列；断开连接暂停，关闭会话取消。队列暂不跨应用重启保存。"
    let column = NSTableColumn(identifier: .init("job")); column.title = "任务 / 状态"; column.width = 220
    table.addTableColumn(column); table.headerView = nil; table.rowHeight = 38
    table.dataSource = self; table.delegate = self
    table.setAccessibilityLabel("传输队列")
    scroll.documentView = table; scroll.hasVerticalScroller = true
    for child in [heading, scroll, pause, resume, cancel, clear] { root.addSubview(child) }
    for button in [pause, resume, cancel, clear] { button.bezelStyle = .rounded; button.controlSize = .small }
    root.onLayout = { [weak self] in self?.layoutContent() }
    observer = queue.objectWillChange.sink { [weak self] in
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.render() } }
    }
    render()
  }
  private func layoutContent() {
    let width = view.bounds.width, height = view.bounds.height
    heading.frame = NSRect(x: 0, y: height - 18, width: width, height: 18)
    scroll.frame = NSRect(x: 0, y: 58, width: width, height: max(20, height - 80))
    for (index, button) in [pause, resume, cancel, clear].enumerated() {
      button.frame = NSRect(x: CGFloat(index % 2) * width / 2, y: index < 2 ? 29 : 0, width: width / 2, height: 26)
    }
  }
  private var selected: FileTransferJob? { displayed.indices.contains(table.selectedRow) ? displayed[table.selectedRow] : nil }
  private func render() {
    let id = selected?.id
    displayed = queue.jobs
    table.reloadData()
    if let row = displayed.firstIndex(where: { $0.id == id }) {
      table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    } else { table.deselectAll(nil) }
    pause.isEnabled = selected.map { [.queued, .running].contains($0.state) } ?? false
    resume.isEnabled = queue.isConnected && (selected.map { [.paused, .failed].contains($0.state) } ?? false)
    cancel.isEnabled = selected.map { ![.completed, .cancelled, .cancelling].contains($0.state) } ?? false
    clear.isEnabled = displayed.contains { [.completed, .cancelled].contains($0.state) }
  }
  func numberOfRows(in tableView: NSTableView) -> Int { displayed.count }
  func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }
  private func updateButtons() {
    pause.isEnabled = selected.map { [.queued, .running].contains($0.state) } ?? false
    resume.isEnabled = queue.isConnected && (selected.map { [.paused, .failed].contains($0.state) } ?? false)
    cancel.isEnabled = selected.map { ![.completed, .cancelled, .cancelling].contains($0.state) } ?? false
  }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let job = displayed[row]
    let percent = job.progress.flatMap { p -> String? in
      guard let total = p.total, total > 0 else { return nil }
      return " · \(Int(min(100, Double(p.completed) / Double(total) * 100)))%"
    } ?? ""
    let text = "\(job.isUpload ? "↑" : "↓") \(job.currentName ?? job.name)\n\(job.state.title) · \(job.completedItems)/\(job.totalItems)\(percent)"
    let field = NSTextField(labelWithString: text); field.font = .systemFont(ofSize: 10)
    field.maximumNumberOfLines = 2; field.lineBreakMode = .byTruncatingMiddle
    field.toolTip = "\(job.destination)\(job.error.map { "\n" + $0 } ?? "")"
    field.setAccessibilityLabel(text + " " + (job.error ?? ""))
    field.textColor = job.error == nil ? .labelColor : .systemRed
    return field
  }
  @objc private func pauseJob() { if let selected { queue.pause(selected.id) } }
  @objc private func resumeJob() { if let selected { queue.resume(selected.id) } }
  @objc private func cancelJob() { if let selected { queue.cancel(selected.id) } }
  @objc private func clearJobs() { queue.clearFinished() }
}

final class FlippedFileView: NSView { override var isFlipped: Bool { true } }
final class FileLayoutView: ChromeView {
  var onLayout: (() -> Void)?
  override func layout() { super.layout(); onLayout?() }
}

/// The scroll view is also a destination so an empty table and its blank area accept files.
final class FileUploadDropScrollView: NSScrollView {
  var readFiles: ((NSPasteboard) -> [URL]?)?
  var onDrop: (([URL]) -> Void)?
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    registerForDraggedTypes([.fileURL])
    wantsLayer = true
  }
  required init?(coder: NSCoder) { fatalError("unsupported") }
  private func canAccept(_ info: any NSDraggingInfo) -> Bool {
    info.draggingSourceOperationMask.contains(.copy) && readFiles?(info.draggingPasteboard) != nil
  }
  private func highlight(_ active: Bool) {
    layer?.borderColor = NSColor.controlAccentColor.cgColor
    layer?.borderWidth = active ? 2 : 0
  }
  override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
    let accepted = canAccept(sender); highlight(accepted)
    return accepted ? .copy : []
  }
  override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
  override func draggingExited(_ sender: (any NSDraggingInfo)?) { highlight(false) }
  override func draggingEnded(_ sender: any NSDraggingInfo) { highlight(false) }
  override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { canAccept(sender) }
  override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    defer { highlight(false) }
    guard sender.draggingSourceOperationMask.contains(.copy), let files = readFiles?(sender.draggingPasteboard), let onDrop else { return false }
    onDrop(files)
    return true
  }
}

/// Wide panes show files beside the terminal; narrow split panes stack them vertically.
final class TerminalFilesView: NSView {
  let terminal: NSView
  let files: NSView
  init(terminal: NSView, files: NSView) {
    self.terminal = terminal; self.files = files
    super.init(frame: .zero)
    for child in [terminal, files] {
      child.translatesAutoresizingMaskIntoConstraints = true
      child.autoresizingMask = []
      addSubview(child)
    }
  }
  required init?(coder: NSCoder) { fatalError("unsupported") }
  override func layout() {
    super.layout()
    if bounds.width >= 700 {
      let width = bounds.width >= 1_100 ? min(800, bounds.width * 0.65) : min(440, bounds.width * 0.5)
      terminal.frame = NSRect(x: 0, y: 0, width: bounds.width - width - 1, height: bounds.height)
      files.frame = NSRect(x: bounds.width - width, y: 0, width: width, height: bounds.height)
    } else {
      let height = bounds.height * 0.5
      files.frame = NSRect(x: 0, y: 0, width: bounds.width, height: height)
      terminal.frame = NSRect(x: 0, y: height + 1, width: bounds.width, height: max(0, bounds.height - height - 1))
    }
    files.needsLayout = true
  }
}
