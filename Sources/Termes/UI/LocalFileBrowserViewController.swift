import AppKit
import Combine
import TermesKit

@MainActor
final class LocalFileBrowserViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
  let model: LocalFileBrowserModel
  let table = NSTableView()
  let pathField = NSTextField()
  var onUpload: (([URL]) -> Void)?
  var canUpload = false { didSet { if isViewLoaded { render() } } }
  private let heading = NSTextField(labelWithString: "本机文件")
  private let status = NSTextField(labelWithString: "")
  private let scroll = NSScrollView()
  private let tableScroll = NSScrollView()
  private let document = FlippedFileView()
  private var entries: [LocalFileEntry] = []
  private var observer: AnyCancellable?
  private lazy var up = button("上级", #selector(goUp))
  private lazy var choose = button("选文件夹…", #selector(chooseDirectory))
  private lazy var refresh = button("刷新", #selector(refreshFiles))
  private lazy var upload = button("上传选中", #selector(uploadSelected))

  init(model: LocalFileBrowserModel = LocalFileBrowserModel()) {
    self.model = model; super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError("unsupported") }

  override func loadView() {
    let root = FileLayoutView(frame: NSRect(x: 0, y: 0, width: 340, height: 300))
    view = root
    scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
    scroll.documentView = document
    root.addSubview(scroll)
    root.onLayout = { [weak self] in self?.layoutContent() }
    heading.font = .boldSystemFont(ofSize: 12)
    pathField.usesSingleLineMode = true
    pathField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    pathField.placeholderString = "本机目录（回车打开）"
    pathField.setAccessibilityLabel("本机目录")
    pathField.target = self; pathField.action = #selector(openPath)
    for (id, title, width) in [("name", "名称", 180.0), ("size", "大小", 80.0)] {
      let column = NSTableColumn(identifier: .init(id))
      column.title = title; column.width = width; column.minWidth = id == "name" ? 100 : 60
      table.addTableColumn(column)
    }
    table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    table.allowsMultipleSelection = true
    table.dataSource = self; table.delegate = self
    table.target = self; table.doubleAction = #selector(openDirectory)
    table.setAccessibilityLabel("本机文件列表")
    table.setDraggingSourceOperationMask(.copy, forLocal: true)
    table.setDraggingSourceOperationMask(.copy, forLocal: false)
    tableScroll.hasVerticalScroller = true; tableScroll.hasHorizontalScroller = true
    tableScroll.documentView = table
    status.font = .systemFont(ofSize: 11); status.lineBreakMode = .byTruncatingTail
    for v in [heading, pathField, up, choose, refresh, upload, tableScroll, status] { document.addSubview(v) }
    observer = model.objectWillChange.sink { [weak self] in
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.render() } }
    }
    render()
  }

  func start() { _ = view; model.refresh() }
  func shutdown() { observer = nil; model.shutdown() }

  private func button(_ title: String, _ action: Selector) -> NSButton {
    let button = NSButton(title: title, target: self, action: action)
    button.bezelStyle = .rounded; button.controlSize = .small
    return button
  }
  private func layoutContent() {
    scroll.frame = view.bounds
    let width = max(220, scroll.contentSize.width), height = max(220, scroll.contentSize.height)
    document.frame = NSRect(x: 0, y: 0, width: width, height: height)
    heading.frame = NSRect(x: 8, y: 6, width: width - 16, height: 18)
    pathField.frame = NSRect(x: 8, y: 28, width: width - 16, height: 24)
    for (index, button) in [up, choose, refresh, upload].enumerated() {
      button.frame = NSRect(x: 6 + CGFloat(index) * (width - 12) / 4, y: 56, width: (width - 12) / 4, height: 24)
    }
    tableScroll.frame = NSRect(x: 8, y: 85, width: width - 16, height: height - 115)
    status.frame = NSRect(x: 8, y: height - 24, width: width - 16, height: 20)
    if let clip = table.superview as? NSClipView {
      table.setFrameSize(NSSize(width: max(260, clip.bounds.width), height: table.frame.height))
      table.sizeLastColumnToFit()
    }
  }

  var selectedURLs: [URL] {
    table.selectedRowIndexes.compactMap { entries.indices.contains($0) ? entries[$0] : nil }
      .filter { $0.kind == .file || $0.kind == .directory }.map(\.url)
  }
  private func render() {
    if entries != model.entries {
      let selection = Set(table.selectedRowIndexes.compactMap { entries.indices.contains($0) ? entries[$0].url : nil })
      entries = model.entries
      table.reloadData()
      table.selectRowIndexes(IndexSet(entries.indices.filter { selection.contains(entries[$0].url) }), byExtendingSelection: false)
    }
    if pathField.currentEditor() == nil { pathField.stringValue = model.directory?.path ?? "" }
    // A slow filesystem must not prevent choosing another path while it is loading.
    pathField.isEnabled = true
    up.isEnabled = !model.isBusy && model.directory != nil
    refresh.isEnabled = !model.isBusy
    upload.isEnabled = canUpload && !model.isBusy && !selectedURLs.isEmpty && selectedURLs.count == table.selectedRowIndexes.count
    status.stringValue = model.error ?? (model.isBusy ? "正在读取本机目录…" : "\(entries.count) 项 · 拖动文件到服务器列表上传")
    status.textColor = model.error == nil ? .secondaryLabelColor : .systemRed
    status.toolTip = status.stringValue
  }
  func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
  func tableViewSelectionDidChange(_ notification: Notification) { render() }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let entry = entries[row]
    let text: String
    if tableColumn?.identifier.rawValue == "size" {
      text = entry.kind == .directory ? "目录" : entry.kind == .symbolicLink ? "链接" :
        entry.size.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .file) } ?? "—"
    } else { text = (entry.kind == .directory ? "▸ " : entry.kind == .symbolicLink ? "↗ " : "") + entry.name }
    let field = NSTextField(labelWithString: text)
    field.font = .systemFont(ofSize: 12); field.lineBreakMode = .byTruncatingMiddle; field.toolTip = entry.url.path
    return field
  }
  func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
    guard canUpload, !model.isBusy, entries.indices.contains(row),
          entries[row].kind == .file || entries[row].kind == .directory else { return nil }
    // NSURL exports the same public.file-url format Finder uses.
    return entries[row].url as NSURL
  }
  @objc private func openPath() { model.navigate(path: pathField.stringValue) }
  @objc private func goUp() { model.goUp() }
  @objc private func refreshFiles() { model.refresh() }
  @objc private func uploadSelected() { if upload.isEnabled { onUpload?(selectedURLs) } }
  @objc private func openDirectory() {
    guard !model.isBusy, entries.indices.contains(table.clickedRow) else { return }
    let entry = entries[table.clickedRow]
    if entry.kind == .directory || entry.kind == .symbolicLink { model.navigate(entry.url) }
  }
  @objc private func chooseDirectory() {
    guard let window = view.window else { return }
    let panel = NSOpenPanel()
    panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
    panel.directoryURL = model.directory; panel.prompt = "打开文件夹"
    panel.beginSheetModal(for: window) { [weak self] result in
      if result == .OK, let url = panel.url { self?.model.navigate(url) }
    }
  }
}

final class LocalRemoteFilesView: ChromeView {
  let local: NSView
  let remote: NSView
  let locationControl = NSSegmentedControl(labels: ["远端", "本机"], trackingMode: .selectOne, target: nil, action: nil)
  let usesTabs: Bool
  override var isFlipped: Bool { true }
  init(local: NSView, remote: NSView, usesTabs: Bool = false) {
    self.local = local; self.remote = remote; self.usesTabs = usesTabs
    super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 480))
    fillColor = .windowBackgroundColor
    for child in [local, remote] { addSubview(child) }
    if usesTabs {
      locationControl.selectedSegment = 0; locationControl.target = self; locationControl.action = #selector(locationChanged)
      locationControl.segmentDistribution = .fillEqually
      locationControl.setAccessibilityLabel("文件位置：远端或本机")
      addSubview(locationControl); locationChanged()
    }
  }
  required init?(coder: NSCoder) { fatalError("unsupported") }
  @objc func locationChanged() {
    guard usesTabs else { return }
    local.isHidden = locationControl.selectedSegment != 1; remote.isHidden = locationControl.selectedSegment == 1
    needsLayout = true
  }
  override func layout() {
    super.layout()
    if usesTabs {
      locationControl.frame = NSRect(x: 12, y: 8, width: max(0, bounds.width - 24), height: 26)
      for index in 0..<2 { locationControl.setWidth(max(0, (locationControl.frame.width - 4) / 2), forSegment: index) }
      let body = NSRect(x: 0, y: 44, width: bounds.width, height: max(0, bounds.height - 44))
      local.frame = body; remote.frame = body
    } else if bounds.width >= 620 {
      let width = (bounds.width - 1) * 0.5
      local.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
      remote.frame = NSRect(x: width + 1, y: 0, width: bounds.width - width - 1, height: bounds.height)
    } else {
      let height = min(240, bounds.height * 0.35)
      local.frame = NSRect(x: 0, y: 0, width: bounds.width, height: height)
      remote.frame = NSRect(x: 0, y: height + 1, width: bounds.width, height: max(0, bounds.height - height - 1))
    }
    local.needsLayout = true; remote.needsLayout = true
  }
}
