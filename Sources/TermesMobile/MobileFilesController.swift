import UIKit
import UniformTypeIdentifiers
import Combine
import SSHCore
import TermesKit

enum MobileFileStorage {
  static var documents: URL {
    #if DEBUG
    if ProcessInfo.processInfo.environment["TERMES_UI_TESTING"] == "1" {
      let url = FileManager.default.temporaryDirectory.appendingPathComponent("Termes-UITests/Documents", isDirectory: true)
      try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      return url
    }
    #endif
    return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
  }
  static func downloads() throws -> URL {
    let url = documents.appendingPathComponent("Downloads", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
  /// Copy provider documents into the sandbox so paused/retried tasks retain access.
  static func stage(_ urls: [URL]) throws -> [URL] {
    let directory = documents.appendingPathComponent("Imports", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    do {
      var copies: [URL] = []
      for url in urls {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let destination = directory.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: destination)
        copies.append(destination)
      }
      return try UploadSelection.validated(copies)
    } catch { try? FileManager.default.removeItem(at: directory); throw error }
  }
}

/// The session owns the model and queue; dismissing this sheet leaves transfers running.
final class MobileFilesController: UITableViewController, UIDocumentPickerDelegate {
  let model: FileBrowserModel
  private var subscriptions = Set<AnyCancellable>()
  private var uploadDirectory: String?
  private var uploadEntries: [SFTPEntry] = []
  private let pathButton = UIButton(type: .system)
  init(model: FileBrowserModel) { self.model = model; super.init(style: .insetGrouped) }
  required init?(coder: NSCoder) { fatalError("unsupported") }
  override func viewDidLoad() {
    super.viewDidLoad(); title = "文件"
    navigationItem.leftBarButtonItem = UIBarButtonItem(title: "完成", primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
    let menu = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: fileMenu())
    menu.accessibilityIdentifier = "files.menu"; menu.accessibilityLabel = "文件操作"
    let up = UIBarButtonItem(image: UIImage(systemName: "arrow.up"), primaryAction: UIAction { [weak self] _ in self?.model.goUp() })
    up.accessibilityLabel = "上级目录"; up.accessibilityIdentifier = "files.up"
    navigationItem.rightBarButtonItems = [menu, up]
    pathButton.contentHorizontalAlignment = .leading
    pathButton.titleLabel?.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    pathButton.titleLabel?.lineBreakMode = .byTruncatingMiddle
    pathButton.accessibilityIdentifier = "files.path"
    pathButton.addAction(UIAction { [weak self] _ in
      guard let self else { return }
      prompt("前往远端目录", value: model.directory ?? ".", actionTitle: "前往") { [weak self] in self?.model.navigate($0) }
    }, for: .touchUpInside)
    let header = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 52))
    header.addSubview(pathButton); pathButton.snp.makeConstraints { $0.edges.equalToSuperview().inset(12) }
    tableView.tableHeaderView = header
    refreshControl = UIRefreshControl()
    refreshControl?.addAction(UIAction { [weak self] _ in self?.model.refresh() }, for: .valueChanged)
    model.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.render() }.store(in: &subscriptions)
    model.transfers.$jobs.receive(on: RunLoop.main).sink { [weak self] _ in self?.render() }.store(in: &subscriptions)
    if model.directory == nil && model.isConnected && !model.isBrowsingBusy { model.refresh() }
    render()
  }
  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    if model.directory != nil && model.isConnected { model.refresh() }
  }
  private func render() {
    pathButton.setTitle(model.directory ?? "远端目录", for: .normal)
    pathButton.isEnabled = model.isConnected && !model.isBrowsingBusy
    navigationItem.rightBarButtonItems?.forEach { $0.isEnabled = model.isConnected && !model.isBrowsingBusy }
    // Local files and existing transfers remain accessible while disconnected.
    navigationItem.rightBarButtonItems?.first?.isEnabled = true
    navigationItem.rightBarButtonItems?.first?.menu = fileMenu()
    if !model.isBrowsingBusy { refreshControl?.endRefreshing() }
    tableView.reloadData()
  }
  private func fileMenu() -> UIMenu {
    let attributes: UIMenuElement.Attributes = model.isConnected && !model.isBrowsingBusy && model.directory != nil ? [] : .disabled
    return UIMenu(children: [
      UIAction(title: "新建目录", image: UIImage(systemName: "folder.badge.plus"), attributes: attributes) { [weak self] _ in
        self?.prompt("新建目录") { self?.model.createDirectory(name: $0) }
      },
      UIAction(title: "上传文件", image: UIImage(systemName: "arrow.up.doc"), attributes: attributes) { [weak self] _ in self?.pickUpload(folder: false) },
      UIAction(title: "上传文件夹", image: UIImage(systemName: "folder"), attributes: attributes) { [weak self] _ in self?.pickUpload(folder: true) },
      UIAction(title: "本机文件", image: UIImage(systemName: "iphone")) { [weak self] _ in self?.showLocalFiles() },
      UIAction(title: "清除已完成传输", image: UIImage(systemName: "checkmark.circle")) { [weak self] _ in self?.model.transfers.clearFinished() }
    ])
  }
  override func numberOfSections(in tableView: UITableView) -> Int { 2 }
  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? model.entries.count : model.transfers.jobs.count }
  override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { section == 0 ? "远端文件" : "传输队列" }
  override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
    section == 0 ? (model.error ?? model.status) : "下载保存在本机 Downloads。轻点传输可暂停、继续、重试或取消；关闭文件页面后任务继续。"
  }
  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
    cell.detailTextLabel?.numberOfLines = 0
    if indexPath.section == 0 {
      let entry = model.entries[indexPath.row]
      cell.textLabel?.text = entry.name
      cell.detailTextLabel?.text = [entry.size.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .file) }, entry.permissions.map { String(format: "%04o", $0 & 0o7777) }].compactMap { $0 }.joined(separator: " · ")
      cell.imageView?.image = UIImage(systemName: entry.kind == .directory ? "folder" : "doc")
      cell.accessoryType = .disclosureIndicator; cell.accessibilityIdentifier = "remoteFile.\(entry.name)"
    } else {
      let job = model.transfers.jobs[indexPath.row]
      cell.textLabel?.text = "\(job.isUpload ? "↑" : "↓") \(job.name) · \(job.state.title)"
      var progress = "\(job.completedItems)/\(job.totalItems) 项"
      if let bytes = job.progress {
        progress += " · \(ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes.completed), countStyle: .file))"
        if let total = bytes.total { progress += " / \(ByteCountFormatter.string(fromByteCount: Int64(clamping: total), countStyle: .file))" }
      }
      cell.detailTextLabel?.text = progress + (job.error.map { "\n\($0)" } ?? "")
      cell.accessibilityIdentifier = "transfer.\(job.name)"
    }
    return cell
  }
  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    if indexPath.section == 1 { showTransfer(model.transfers.jobs[indexPath.row], at: indexPath); return }
    let entry = model.entries[indexPath.row]
    guard model.isConnected, !model.isBrowsingBusy else { return }
    if entry.kind == .directory { model.navigate(entry.path) }
    else { showEntry(entry, at: indexPath) }
  }
  override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
    guard indexPath.section == 0 else { return nil }
    let entry = model.entries[indexPath.row]
    return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
      UIMenu(children: self?.entryActions(entry).map(\.action) ?? [])
    })
  }
  private func entryActions(_ entry: SFTPEntry) -> [MobileFileAction] {
    let enabled = model.isConnected && !model.isBrowsingBusy
    var actions: [MobileFileAction] = []
    if entry.kind == .file {
      actions.append(MobileFileAction(title: "编辑文本", image: UIImage(systemName: "pencil"), attributes: enabled ? [] : .disabled) { [weak self] in
        guard let self else { return }
        presentSheet(MobileRemoteEditorController(model: model.makeEditor(for: entry)))
      })
    }
    if entry.kind == .file || entry.kind == .directory || entry.kind == .symbolicLink {
      actions.append(MobileFileAction(title: "下载到本机", image: UIImage(systemName: "arrow.down.doc"), attributes: enabled ? [] : .disabled) { [weak self] in self?.download(entry) })
    }
    if entry.kind == .file || entry.kind == .directory {
      actions.append(MobileFileAction(title: "权限", image: UIImage(systemName: "lock"), attributes: enabled ? [] : .disabled) { [weak self] in
        guard let self else { return }; presentSheet(MobilePermissionsController(model: model.makePermissionsEditor(for: entry)))
      })
    }
    actions.append(MobileFileAction(title: "重命名", image: UIImage(systemName: "pencil.line"), attributes: enabled ? [] : .disabled) { [weak self] in
      self?.prompt("重命名", value: entry.name) { self?.model.rename(entry, to: $0) }
    })
    actions.append(MobileFileAction(title: "删除", image: UIImage(systemName: "trash"), attributes: enabled ? .destructive : [.destructive, .disabled]) { [weak self] in
      self?.confirm("删除远端条目？", message: entry.path + (entry.kind == .directory ? "\n仅支持删除空目录。" : "")) { self?.model.remove(entry) }
    })
    return actions
  }
  private func showEntry(_ entry: SFTPEntry, at indexPath: IndexPath) {
    // A context menu also gives directories these actions without navigating into them.
    let alert = UIAlertController(title: entry.name, message: nil, preferredStyle: .actionSheet)
    for action in entryActions(entry) {
      alert.addAction(UIAlertAction(title: action.title, style: action.attributes.contains(.destructive) ? .destructive : .default) { _ in
        action.handler()
      })
    }
    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
    anchor(alert, at: indexPath); present(alert, animated: true)
  }
  private func anchor(_ alert: UIAlertController, at indexPath: IndexPath) {
    alert.popoverPresentationController?.sourceView = tableView
    alert.popoverPresentationController?.sourceRect = tableView.rectForRow(at: indexPath)
  }
  private func download(_ entry: SFTPEntry) {
    do {
      let directory = try MobileFileStorage.downloads()
      _ = try RemotePath.child(entry.name, in: directory.path)
      let target = directory.appendingPathComponent(entry.name)
      if FileManager.default.fileExists(atPath: target.path) {
        guard entry.kind != .directory else { presentError("本机已有同名目录，请先在“文件”App 中移动或重命名，再下载。"); return }
        confirm("替换本机文件？", message: entry.name, actionTitle: "替换") { [weak self] in self?.model.download(entry, to: target, overwrite: true) }
      } else { model.download(entry, to: target) }
    } catch { presentError(error.localizedDescription) }
  }
  private func pickUpload(folder: Bool) {
    guard model.isConnected, !model.isBrowsingBusy, let directory = model.directory else { presentError("请先连接并打开远端目录。"); return }
    uploadDirectory = directory; uploadEntries = model.entries
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: folder ? [.folder] : [.item], asCopy: true)
    picker.allowsMultipleSelection = true; picker.delegate = self
    present(picker, animated: true)
  }
  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let directory = uploadDirectory else { return }
    let entries = uploadEntries
    Task { [weak self] in
      do {
        let copies = try await Task.detached(priority: .userInitiated) { try MobileFileStorage.stage(urls) }.value
        guard let self else { return }; submitUploads(copies, directory: directory, entries: entries)
      } catch { self?.presentError(error.localizedDescription) }
    }
  }
  private func submitUploads(_ urls: [URL], directory: String, entries: [SFTPEntry], presenter: UIViewController? = nil) {
    let presenter = presenter ?? self
    guard model.isConnected else { presenter.presentError("SSH 已断开。请重连后再上传。"); return }
    let conflicts = Set(urls.map(\.lastPathComponent)).intersection(entries.map(\.name))
    let submit = { [weak self] in
      guard let self else { return }
      _ = model.transfers.upload(urls, directory: directory, overwriting: conflicts)
    }
    if conflicts.isEmpty { submit() }
    else { presenter.confirm("替换远端同名文件？", message: conflicts.sorted().joined(separator: "\n") + "\n同名目录不会合并或覆盖。", actionTitle: "上传并替换", action: submit) }
  }
  private func showLocalFiles() {
    let local = MobileLocalFilesController()
    local.onUpload = { [weak self, weak local] url in
      guard let self, let directory = model.directory else { return }
      submitUploads([url], directory: directory, entries: model.entries, presenter: local)
    }
    navigationController?.pushViewController(local, animated: true)
  }
  private func showTransfer(_ job: FileTransferJob, at indexPath: IndexPath) {
    let alert = UIAlertController(title: job.name, message: job.error ?? job.state.title, preferredStyle: .actionSheet)
    if job.state == .running || job.state == .queued {
      alert.addAction(UIAlertAction(title: "暂停", style: .default) { [weak self] _ in self?.model.transfers.pause(job.id) })
    }
    if job.state == .paused || job.state == .failed {
      let resume = UIAlertAction(title: job.state == .failed ? "重试" : "继续", style: .default) { [weak self] _ in self?.model.transfers.resume(job.id) }
      resume.isEnabled = model.isConnected; alert.addAction(resume)
    }
    if ![.completed, .cancelled, .cancelling].contains(job.state) {
      alert.addAction(UIAlertAction(title: "取消传输", style: .destructive) { [weak self] _ in self?.model.transfers.cancel(job.id) })
    }
    if job.state == .completed && !job.isUpload {
      alert.addAction(UIAlertAction(title: "共享或存储到文件", style: .default) { [weak self] _ in self?.share(URL(fileURLWithPath: job.destination)) })
    }
    alert.addAction(UIAlertAction(title: "关闭", style: .cancel)); anchor(alert, at: indexPath)
    present(alert, animated: true)
  }
}

final class MobileLocalFilesController: UITableViewController {
  var onUpload: ((URL) -> Void)?
  private let model = LocalFileBrowserModel(initialDirectory: MobileFileStorage.documents)
  private var subscriptions = Set<AnyCancellable>()
  override func viewDidLoad() {
    super.viewDidLoad(); title = "本机文件"
    if navigationController?.viewControllers.first === self {
      navigationItem.leftBarButtonItem = UIBarButtonItem(title: "完成", primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
    }
    navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "arrow.up"), primaryAction: UIAction { [weak self] _ in
      guard let self, let directory = model.directory,
            directory.standardizedFileURL.resolvingSymlinksInPath() != MobileFileStorage.documents.standardizedFileURL.resolvingSymlinksInPath() else { return }
      model.goUp()
    })
    model.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.tableView.reloadData() }.store(in: &subscriptions)
    model.refresh()
  }
  override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); model.refresh() }
  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { model.entries.count }
  override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? { model.error ?? model.directory?.lastPathComponent }
  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let entry = model.entries[indexPath.row]
    let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
    cell.textLabel?.text = entry.name; cell.imageView?.image = UIImage(systemName: entry.kind == .directory ? "folder" : "doc")
    cell.accessibilityIdentifier = "localFile.\(entry.name)"; cell.accessoryType = .disclosureIndicator
    return cell
  }
  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    let entry = model.entries[indexPath.row]
    tableView.deselectRow(at: indexPath, animated: true)
    if entry.kind == .directory { model.navigate(entry.url) } else { share(entry.url, source: tableView.cellForRow(at: indexPath)) }
  }
  override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
    let entry = model.entries[indexPath.row]
    return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
      var actions = [UIAction(title: "共享或存储到文件", image: UIImage(systemName: "square.and.arrow.up")) { _ in self?.share(entry.url) }]
      if self?.onUpload != nil && (entry.kind == .file || entry.kind == .directory) {
        actions.append(UIAction(title: "上传到当前远端目录", image: UIImage(systemName: "arrow.up.doc")) { _ in
          self?.onUpload?(entry.url)
        })
      }
      return UIMenu(children: actions)
    })
  }
}

@MainActor
private struct MobileFileAction {
  let title: String
  let image: UIImage?
  let attributes: UIMenuElement.Attributes
  let handler: () -> Void
  init(title: String, image: UIImage?, attributes: UIMenuElement.Attributes, handler: @escaping () -> Void) {
    self.title = title; self.image = image; self.attributes = attributes; self.handler = handler
  }
  var action: UIAction { UIAction(title: title, image: image, attributes: attributes) { _ in handler() } }
}
