import UIKit
import Combine
import TermesKit

final class MobileConnectionProgressController: UITableViewController {
  private let model: ConnectionProgressModel
  private var changes: AnyCancellable?

  init(model: ConnectionProgressModel) { self.model = model; super.init(style: .insetGrouped) }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "连接详情"
    navigationItem.rightBarButtonItem = UIBarButtonItem(title: "完成", primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
    changes = model.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.tableView.reloadData() }
  }
  override func numberOfSections(in tableView: UITableView) -> Int { model.nodes.count + 1 }
  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    section < model.nodes.count ? model.nodes[section].steps.count : model.logs.count
  }
  override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    if section == model.nodes.count { return "连接日志 · 第 \(model.attempt) 次连接" }
    let endpoint = model.nodes[section].endpoint
    return (endpoint.isJumpHost ? "跳板机 · " : "目标 · ") + endpoint.hostname
  }
  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
    cell.selectionStyle = .none
    var content = cell.defaultContentConfiguration()
    if indexPath.section < model.nodes.count {
      content.text = ["建立连接", "主机校验", "身份认证", "准备终端", "连接就绪"][indexPath.row]
      let step = model.nodes[indexPath.section].steps[indexPath.row]
      let symbol: String, color: UIColor
      switch step {
      case .succeeded: symbol = "checkmark.circle.fill"; color = .systemGreen
      case .failed(let reason): symbol = "xmark.circle.fill"; color = .systemRed; content.secondaryText = reason
      case .running:
        symbol = "circle.dotted"; color = .systemOrange
        let spinner = UIActivityIndicatorView(style: .medium); spinner.startAnimating(); cell.accessoryView = spinner
      case .waitingForTrust: symbol = "questionmark.shield"; color = .systemOrange
      case .cancelled: symbol = "minus.circle"; color = .secondaryLabel
      case .waiting: symbol = "circle"; color = .tertiaryLabel
      }
      content.image = UIImage(systemName: symbol); content.imageProperties.tintColor = color
    } else {
      let log = model.logs[indexPath.row]
      content.text = log.text; content.textProperties.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
      content.secondaryText = log.timestamp.formatted(date: .omitted, time: .standard)
      content.secondaryTextProperties.color = .secondaryLabel
    }
    cell.contentConfiguration = content
    return cell
  }
  override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
    guard indexPath.section == model.nodes.count else { return nil }
    let text = model.logs[indexPath.row].text
    return UIContextMenuConfiguration(actionProvider: { _ in
      UIMenu(children: [UIAction(title: "复制日志", image: UIImage(systemName: "doc.on.doc")) { _ in UIPasteboard.general.string = text }])
    })
  }
}
