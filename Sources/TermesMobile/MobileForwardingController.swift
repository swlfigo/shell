import UIKit
import Combine
import SSHCore
import TermesKit

final class MobileForwardHostsController: UITableViewController {
  private let workspace: MobileWorkspace
  private var observer: AnyCancellable?
  init(workspace: MobileWorkspace) { self.workspace = workspace; super.init(style: .insetGrouped) }
  required init?(coder: NSCoder) { fatalError("unsupported") }
  override func viewDidLoad() {
    super.viewDidLoad(); title = "端口转发"
    navigationItem.leftBarButtonItem = UIBarButtonItem(title: "完成", primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
    observer = workspace.$hosts.receive(on: RunLoop.main).sink { [weak self] _ in self?.tableView.reloadData() }
  }
  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { workspace.hosts.count }
  override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
    "选择主机管理规则。可以先保存规则，连接 SSH 后手动启动。"
  }
  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let host = workspace.hosts[indexPath.row]
    let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
    cell.textLabel?.text = host.name; cell.detailTextLabel?.text = "\(host.username)@\(host.hostname)"
    cell.accessoryType = .disclosureIndicator; cell.accessibilityIdentifier = "forwardHost.\(host.name)"
    return cell
  }
  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    let host = workspace.hosts[indexPath.row]
    tableView.deselectRow(at: indexPath, animated: true)
    Task { [weak self] in
      guard let self else { return }
      do {
        let model = try await workspace.forwardingManager(for: host)
        let controller = MobileForwardingController(model: model, name: host.name)
        controller.onConnect = { [weak self, workspace] in
          self?.dismiss(animated: true) { _ = workspace.open(host) }
        }
        navigationController?.pushViewController(controller, animated: true)
      } catch { presentError(error.localizedDescription) }
    }
  }
}

final class MobileForwardingController: UITableViewController {
  let model: LocalForwardManager
  var onConnect: (() -> Void)?
  private let name: String
  private var subscriptions = Set<AnyCancellable>()
  init(model: LocalForwardManager, name: String) { self.model = model; self.name = name; super.init(style: .insetGrouped) }
  required init?(coder: NSCoder) { fatalError("unsupported") }
  override func viewDidLoad() {
    super.viewDidLoad(); title = "端口转发 · \(name)"
    navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .add, primaryAction: UIAction { [weak self] _ in self?.edit(nil) })
    navigationItem.rightBarButtonItem?.accessibilityIdentifier = "forwards.add"
    if navigationController?.viewControllers.first === self {
      navigationItem.leftBarButtonItem = UIBarButtonItem(title: "完成", primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
    }
    model.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.render() }.store(in: &subscriptions)
    render()
  }
  private func render() {
    navigationItem.rightBarButtonItem?.isEnabled = model.canSave
    tableView.reloadData()
  }
  override func numberOfSections(in tableView: UITableView) -> Int { 2 }
  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? 1 : model.rules.count }
  override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { section == 0 ? "SSH 连接" : "已保存规则" }
  override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
    section == 1 ? (model.storageError ?? "规则会保留。断开连接时停止转发，重连后手动启动。iOS 后台可能暂停连接。") : nil
  }
  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
    if indexPath.section == 0 {
      cell.accessibilityIdentifier = "forwards.connection"
      cell.textLabel?.text = model.isConnected ? "已连接" : model.isLoading ? "正在读取规则…" : "未连接 · 连接主机"
      cell.detailTextLabel?.text = model.destination?.displayName
      cell.textLabel?.textColor = model.isConnected ? .systemGreen : .label
      return cell
    }
    let rule = model.rules[indexPath.row], config = rule.configuration
    cell.textLabel?.text = "\(config.mobileTitle) · \(config.listenHost):\(config.localPort)"
    cell.detailTextLabel?.numberOfLines = 0
    cell.detailTextLabel?.text = (config.kind == .socks ? "SOCKS5" : "→ \(config.targetHost):\(config.targetPort)")
      + "\n" + rule.mobileStatus + (rule.clientError.map { "\n\($0)" } ?? "")
    cell.accessoryType = .disclosureIndicator; cell.accessibilityIdentifier = "forward.\(config.localPort)"
    return cell
  }
  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    if indexPath.section == 0 { if !model.isConnected { onConnect?() }; return }
    let rule = model.rules[indexPath.row]
    let menu = UIAlertController(title: rule.configuration.mobileTitle, message: rule.mobileStatus, preferredStyle: .actionSheet)
    if rule.canEdit {
      let start = UIAlertAction(title: "启动", style: .default) { [weak self] _ in self?.model.start(rule.id) }
      start.isEnabled = model.isConnected; menu.addAction(start)
      menu.addAction(UIAlertAction(title: "编辑", style: .default) { [weak self] _ in self?.edit(rule) })
      menu.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in
        self?.confirm("删除转发规则？", message: "\(rule.configuration.localPort)") {
          do { try self?.model.remove(rule.id, expected: rule.configuration) } catch { self?.presentError(error.localizedDescription) }
        }
      })
    } else if rule.state != .stopping {
      menu.addAction(UIAlertAction(title: "停止", style: .destructive) { [weak self] _ in self?.model.stop(rule.id) })
    }
    menu.addAction(UIAlertAction(title: "取消", style: .cancel))
    menu.popoverPresentationController?.sourceView = tableView.cellForRow(at: indexPath)
    menu.popoverPresentationController?.sourceRect = tableView.cellForRow(at: indexPath)?.bounds ?? .zero
    present(menu, animated: true)
  }
  private func edit(_ rule: LocalForwardRule?) {
    navigationController?.pushViewController(MobileForwardEditorController(model: model, rule: rule), animated: true)
  }
}

private final class MobileForwardEditorController: MobileFormController {
  private let model: LocalForwardManager
  private let rule: LocalForwardRule?
  private let kind = UISegmentedControl(items: ["本地", "远端", "SOCKS5"])
  private var listenHost: UITextField!, localPort: UITextField!, targetHost: UITextField!, targetPort: UITextField!
  private let hint = MobileUI.label("", style: .footnote, color: .secondaryLabel)
  init(model: LocalForwardManager, rule: LocalForwardRule?) { self.model = model; self.rule = rule; super.init(nibName: nil, bundle: nil) }
  required init?(coder: NSCoder) { fatalError("unsupported") }
  override func viewDidLoad() {
    super.viewDidLoad(); title = rule == nil ? "新建转发" : "编辑转发"
    navigationItem.rightBarButtonItem = UIBarButtonItem(title: "保存", primaryAction: UIAction { [weak self] _ in self?.save() })
    navigationItem.rightBarButtonItem?.accessibilityIdentifier = "forwardEditor.save"
    kind.selectedSegmentIndex = rule?.configuration.kind == .remote ? 1 : rule?.configuration.kind == .socks ? 2 : 0
    kind.accessibilityIdentifier = "forwardEditor.kind"; content.addArrangedSubview(kind)
    listenHost = field("监听地址", text: rule?.configuration.listenHost ?? "127.0.0.1", id: "forwardEditor.listenHost")
    localPort = field("监听端口", text: rule.map { String($0.configuration.localPort) } ?? "", id: "forwardEditor.localPort")
    localPort.keyboardType = .numberPad
    targetHost = field("目标地址", text: rule?.configuration.targetHost ?? "127.0.0.1", id: "forwardEditor.targetHost")
    targetPort = field("目标端口", text: rule.map { String($0.configuration.targetPort) } ?? "", id: "forwardEditor.targetPort")
    targetPort.keyboardType = .numberPad
    kind.addAction(UIAction { [weak self] _ in self?.render() }, for: .valueChanged)
    content.addArrangedSubview(hint); content.addArrangedSubview(errorLabel); render()
  }
  private func render() {
    let remote = kind.selectedSegmentIndex == 1, socks = kind.selectedSegmentIndex == 2
    listenHost.isEnabled = remote
    if !remote { listenHost.text = "127.0.0.1" }
    targetHost.isEnabled = !socks; targetPort.isEnabled = !socks
    hint.text = remote ? "服务器监听指定端口，目标地址由这台设备访问。" : socks
      ? "在这台设备的 127.0.0.1 上提供 SOCKS5 代理，通过服务器访问目标地址。"
      : "这台设备监听指定端口，目标地址由 SSH 服务器访问。"
  }
  private func save() {
    let socks = kind.selectedSegmentIndex == 2
    let configuration = LocalForwardConfiguration(localPort: Int(localPort.text ?? "") ?? -1,
      targetHost: socks ? "" : targetHost.text ?? "", targetPort: socks ? 0 : Int(targetPort.text ?? "") ?? -1,
      kind: kind.selectedSegmentIndex == 1 ? .remote : socks ? .socks : .local, listenHost: listenHost.text ?? "")
    do {
      _ = try model.save(id: rule?.id, configuration: configuration, expected: rule?.configuration)
      navigationController?.popViewController(animated: true)
    } catch { errorLabel.text = error.localizedDescription }
  }
}

private extension LocalForwardConfiguration {
  var mobileTitle: String { kind == .remote ? "远端转发" : kind == .socks ? "SOCKS5 代理" : "本地转发" }
}
private extension LocalForwardRule {
  var mobileStatus: String {
    switch state {
    case .stopped: return "已停止"
    case .starting: return "正在启动…"
    case .stopping: return "正在停止…"
    case .running(let port, let clients): return "运行中 · 端口 \(port) · \(clients) 个连接"
    case .failed(let message): return "失败：\(message)"
    }
  }
}
