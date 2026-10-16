import UIKit
import UniformTypeIdentifiers
import Combine
import TermesKit

final class MobileLibraryController: UITableViewController, UIDocumentPickerDelegate {
  private let workspace: MobileWorkspace
  init(workspace: MobileWorkspace) { self.workspace = workspace; super.init(style: .insetGrouped) }
  required init?(coder: NSCoder) { fatalError("unsupported") }
  override func viewDidLoad() {
    super.viewDidLoad(); title = "资料库"
    navigationItem.leftBarButtonItem = UIBarButtonItem(title: "完成", primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
  }
  override func numberOfSections(in tableView: UITableView) -> Int { 3 }
  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? 4 : section == 1 ? 2 : 1 }
  override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { ["Vaults", "主机导入导出", "工作区"][section] }
  override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
    section == 1 ? "导出与 Mac 通用的主机和密钥元数据。密码、私钥内容和口令只保存在当前设备，导入后需补录凭据。"
      : section == 2 ? "自动保存标签与分屏布局。重启后手动重新连接。此操作也会备份无法读取的旧工作区。" : nil
  }
  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = UITableViewCell()
    let labels = [["Keychain", "端口转发", "Snippets", "本机文件"], ["导入主机", "导出主机"], ["保存当前工作区"]]
    let symbols = [["key", "arrow.left.arrow.right", "text.alignleft", "folder"], ["square.and.arrow.down", "square.and.arrow.up"], ["rectangle.3.group"]]
    cell.textLabel?.text = labels[indexPath.section][indexPath.row]
    cell.imageView?.image = UIImage(systemName: symbols[indexPath.section][indexPath.row])
    cell.accessoryType = .disclosureIndicator
    cell.accessibilityIdentifier = "library.\(indexPath.section).\(indexPath.row)"
    return cell
  }
  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    if indexPath.section == 0 {
      let controller: UIViewController
      switch indexPath.row {
      case 0: controller = MobileKeysController(profiles: workspace.profiles)
      case 1: controller = MobileForwardHostsController(workspace: workspace)
      case 2: controller = MobileSnippetsController(store: workspace.snippets)
      default: controller = MobileLocalFilesController(style: .insetGrouped)
      }
      navigationController?.pushViewController(controller, animated: true)
    } else if indexPath.section == 1 {
      if indexPath.row == 0 {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json], asCopy: true)
        picker.delegate = self; present(picker, animated: true)
      } else { exportHosts() }
    } else {
      workspace.persistWorkspace(replacingUnreadable: true)
      if let message = workspace.error { workspace.error = nil; presentError(message) }
      else {
        let alert = UIAlertController(title: "工作区已保存", message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default)); present(alert, animated: true)
      }
    }
  }
  private func exportHosts() {
    Task {
      do {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Termes-Hosts.json")
        let snapshot = try ConnectionSnapshot(profiles: workspace.profiles.profiles(), keys: workspace.profiles.keys())
        _ = try await FileSyncProvider(fileURL: url).push(snapshot, baseVersion: nil)
        share(url)
      } catch { presentError(error.localizedDescription) }
    }
  }
  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let url = urls.first else { return }
    do {
      let scoped = url.startAccessingSecurityScopedResource()
      defer { if scoped { url.stopAccessingSecurityScopedResource() } }
      guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 4 * 1024 * 1024 else { throw WorkspaceStoreError.invalidSnapshot }
      let data = try Data(contentsOf: url)
      guard data.count <= 4 * 1024 * 1024 else { throw WorkspaceStoreError.invalidSnapshot }
      let snapshot = try JSONDecoder().decode(ConnectionSnapshot.self, from: data)
      guard snapshot.profiles.count <= 2048, snapshot.keys.count <= 2048,
            Set(snapshot.profiles.map(\.id)).count == snapshot.profiles.count,
            Set(snapshot.keys.map(\.id)).count == snapshot.keys.count,
            snapshot.profiles.allSatisfy({ !$0.name.isEmpty && !$0.hostname.isEmpty && !$0.username.isEmpty && (1...65535).contains($0.port) }) else {
        throw ProfileServiceError.invalidConnection
      }
      confirm("导入 \(snapshot.profiles.count) 台主机？", message: "按更新时间合并同一条记录。已打开的会话会保留原目标。", actionTitle: "导入") { [weak self] in
        do { try self?.workspace.profiles.importSnapshot(snapshot) } catch { self?.presentError(error.localizedDescription) }
      }
    } catch { presentError(error.localizedDescription) }
  }
}

final class MobileKeysController: UITableViewController {
  private let profiles: ConnectionProfileService
  private var items: [SSHKeyInfo] = []
  private var observer: AnyCancellable?
  init(profiles: ConnectionProfileService) { self.profiles = profiles; super.init(style: .insetGrouped) }
  required init?(coder: NSCoder) { fatalError("unsupported") }
  override func viewDidLoad() {
    super.viewDidLoad(); title = "Keychain"
    navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .add, primaryAction: UIAction { [weak self] _ in self?.edit(nil) })
    navigationItem.rightBarButtonItem?.accessibilityIdentifier = "keys.add"
    observer = profiles.didChange.sink { [weak self] in self?.reload() }; reload()
  }
  private func reload() {
    do {
      items = try profiles.keyInfo(); tableView.reloadData()
      tableView.backgroundView = items.isEmpty ? MobileUI.label("点击 + 导入并复用私钥。", color: .secondaryLabel) : nil
    } catch { tableView.backgroundView = MobileUI.label(error.localizedDescription, color: .systemRed) }
  }
  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { items.count }
  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let item = items[indexPath.row]
    let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
    cell.textLabel?.text = item.key.name
    cell.detailTextLabel?.numberOfLines = 0
    cell.detailTextLabel?.text = "\(item.key.keyType ?? "私钥") · \(item.hasLocalCredential ? "本机凭据可用" : "需补录凭据")\n\(item.key.fingerprint ?? "无指纹")\n关联：\(item.connections.map(\.name).joined(separator: "、"))"
    cell.imageView?.image = UIImage(systemName: "key"); cell.accessoryType = .disclosureIndicator
    cell.accessibilityIdentifier = "key.\(item.key.name)"
    return cell
  }
  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    let item = items[indexPath.row]
    let alert = UIAlertController(title: item.key.name, message: item.key.fingerprint, preferredStyle: .actionSheet)
    alert.addAction(UIAlertAction(title: "重命名", style: .default) { [weak self] _ in
      self?.prompt("私钥名称", value: item.key.name) { name in
        do { _ = try self?.profiles.renameKey(item.key.id, name: name) } catch { self?.presentError(error.localizedDescription) }
      }
    })
    alert.addAction(UIAlertAction(title: "替换私钥或补录凭据", style: .default) { [weak self] _ in self?.edit(item) })
    alert.addAction(UIAlertAction(title: "删除私钥", style: .destructive) { [weak self] _ in
      self?.confirm("删除私钥？", message: item.connections.isEmpty ? item.key.name : "仍被以下主机使用：\(item.connections.map(\.name).joined(separator: "、"))。请先更换主机凭据。") {
        do { try self?.profiles.deleteKey(item.key.id) } catch { self?.presentError(error.localizedDescription) }
      }
    })
    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
    alert.popoverPresentationController?.sourceView = tableView; alert.popoverPresentationController?.sourceRect = tableView.rectForRow(at: indexPath)
    present(alert, animated: true)
  }
  private func edit(_ item: SSHKeyInfo?) {
    navigationController?.pushViewController(MobileKeyEditorController(profiles: profiles, item: item), animated: true)
  }
}

private final class MobileKeyEditorController: MobileFormController, UIDocumentPickerDelegate {
  private let profiles: ConnectionProfileService
  private let item: SSHKeyInfo?
  private var name: UITextField!, passphrase: UITextField!, key: UITextView!
  init(profiles: ConnectionProfileService, item: SSHKeyInfo?) { self.profiles = profiles; self.item = item; super.init(nibName: nil, bundle: nil) }
  required init?(coder: NSCoder) { fatalError("unsupported") }
  override func viewDidLoad() {
    super.viewDidLoad(); title = item == nil ? "导入私钥" : "替换私钥"
    navigationItem.rightBarButtonItem = UIBarButtonItem(title: "保存", primaryAction: UIAction { [weak self] _ in self?.save() })
    navigationItem.rightBarButtonItem?.accessibilityIdentifier = "keyEditor.save"
    name = field("名称", text: item?.key.name ?? "", id: "keyEditor.name"); name.isEnabled = item == nil
    content.addArrangedSubview(MobileUI.button("选择私钥文件", symbol: "doc", id: "keyEditor.import") { [weak self] in
      let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true); picker.delegate = self
      self?.present(picker, animated: true)
    })
    key = textEditor("私钥内容", id: "keyEditor.content")
    passphrase = field("私钥口令（可选）", id: "keyEditor.passphrase", secure: true)
    content.addArrangedSubview(MobileUI.label("支持 OpenSSH 和 PEM 私钥，最大 1 MiB。凭据保存在当前设备的系统钥匙串。", style: .footnote, color: .secondaryLabel))
    content.addArrangedSubview(errorLabel)
  }
  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let url = urls.first else { return }
    do {
      let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
      guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 1_048_576 else { throw MobileValidationError.invalidKey }
      let data = try Data(contentsOf: url)
      guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8) else { throw MobileValidationError.invalidKey }
      key.text = text; if item == nil { name.text = url.lastPathComponent }
    } catch { errorLabel.text = error.localizedDescription }
  }
  private func save() {
    let perform = { [weak self] in
      guard let self else { return }
      do {
        let data = Data(key.text.utf8), phrase = passphrase.text.flatMap { $0.isEmpty ? nil : $0 }
        guard !data.isEmpty, data.count <= 1_048_576 else { throw MobileValidationError.invalidKey }
        if let item {
          _ = try profiles.replaceKey(item.key.id, data: data, passphrase: phrase, expected: item.key, expectedProfileIds: item.connections.map(\.id))
        } else { _ = try profiles.importKey(data: data, name: name.text ?? "", passphrase: phrase) }
        key.text = ""; passphrase.text = ""; navigationController?.popViewController(animated: true)
      } catch { errorLabel.text = error.localizedDescription }
    }
    if let item, !item.connections.isEmpty {
      confirm("替换共享私钥？", message: "下次连接以下主机时使用新私钥：\(item.connections.map(\.name).joined(separator: "、"))。当前会话保留。", actionTitle: "替换", action: perform)
    } else { perform() }
  }
}
