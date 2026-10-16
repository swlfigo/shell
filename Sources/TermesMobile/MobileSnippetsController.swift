import UIKit
import Combine
import TermesKit

final class MobileSnippetsController: UITableViewController, UISearchResultsUpdating {
  private let store: SnippetStore
  private let session: MobileSession?
  private var items: [Snippet] = []
  private var observer: AnyCancellable?
  private let search = UISearchController(searchResultsController: nil)
  private var groups: [(String, [Snippet])] {
    let query = search.searchBar.text ?? ""
    let filtered = items.filter { query.isEmpty || "\($0.name) \($0.group) \($0.command)".localizedCaseInsensitiveContains(query) }
    return Dictionary(grouping: filtered, by: \.group).sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
      .map { ($0.key.isEmpty ? "未分组" : $0.key, $0.value) }
  }

  init(store: SnippetStore, session: MobileSession? = nil) {
    self.store = store; self.session = session
    super.init(style: .insetGrouped)
  }
  required init?(coder: NSCoder) { fatalError("unsupported") }
  override func viewDidLoad() {
    super.viewDidLoad(); title = "Snippets"
    search.searchResultsUpdater = self; search.obscuresBackgroundDuringPresentation = false
    search.searchBar.placeholder = "搜索命令、脚本或分组"
    navigationItem.searchController = search
    navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .add, primaryAction: UIAction { [weak self] _ in self?.edit(nil) })
    navigationItem.rightBarButtonItem?.accessibilityIdentifier = "snippets.add"
    navigationItem.leftBarButtonItem = UIBarButtonItem(title: "完成", primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
    observer = store.didChange.sink { [weak self] in self?.reload() }
    reload()
  }
  private func reload() {
    do {
      items = try store.all(); tableView.reloadData()
      tableView.backgroundView = items.isEmpty ? MobileUI.label("还没有常用命令。点击 + 新建。", color: .secondaryLabel) : nil
    } catch { tableView.backgroundView = MobileUI.label(error.localizedDescription, color: .systemRed) }
  }
  func updateSearchResults(for searchController: UISearchController) { tableView.reloadData() }
  override func numberOfSections(in tableView: UITableView) -> Int { groups.count }
  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { groups[section].1.count }
  override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { groups[section].0 }
  override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
    session.map { "插入到「\($0.name)」，按回车执行。参数值会按原样替换。" }
  }
  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let item = groups[indexPath.section].1[indexPath.row]
    let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
    cell.textLabel?.text = item.name; cell.detailTextLabel?.text = item.command
    cell.detailTextLabel?.numberOfLines = 2
    cell.imageView?.image = UIImage(systemName: item.kind == .script ? "doc.text" : "terminal")
    cell.accessoryType = .disclosureIndicator; cell.accessibilityIdentifier = "snippet.\(item.name)"
    return cell
  }
  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    let snippet = groups[indexPath.section].1[indexPath.row]
    if let session {
      navigationController?.pushViewController(MobileSnippetInvocationController(snippet: snippet, session: session), animated: true)
    } else { edit(snippet) }
  }
  private func edit(_ snippet: Snippet?) {
    navigationController?.pushViewController(MobileSnippetEditorController(store: store, snippet: snippet), animated: true)
  }
  override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
    let snippet = groups[indexPath.section].1[indexPath.row]
    return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
      UIMenu(children: [
        UIAction(title: "编辑", image: UIImage(systemName: "pencil")) { _ in self?.edit(snippet) },
        UIAction(title: "删除", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
          self?.confirm("删除常用命令？", message: snippet.name) {
            do { try self?.store.delete(snippet.id) } catch { self?.presentError(error.localizedDescription) }
          }
        }
      ])
    })
  }
}

private final class MobileSnippetEditorController: MobileFormController {
  private let store: SnippetStore
  private let snippet: Snippet?
  private var name: UITextField!, group: UITextField!, command: UITextView!
  private let kind = UISegmentedControl(items: ["命令", "多行脚本"])
  private let parameters = UISwitch()
  init(store: SnippetStore, snippet: Snippet?) { self.store = store; self.snippet = snippet; super.init(nibName: nil, bundle: nil) }
  required init?(coder: NSCoder) { fatalError("unsupported") }
  override func viewDidLoad() {
    super.viewDidLoad(); title = snippet == nil ? "新建常用命令" : "编辑常用命令"
    navigationItem.rightBarButtonItem = UIBarButtonItem(title: "保存", primaryAction: UIAction { [weak self] _ in self?.save() })
    navigationItem.rightBarButtonItem?.accessibilityIdentifier = "snippetEditor.save"
    name = field("名称", text: snippet?.name ?? "", id: "snippetEditor.name")
    group = field("分组", text: snippet?.group ?? "", id: "snippetEditor.group")
    kind.selectedSegmentIndex = snippet?.kind == .script ? 1 : 0
    kind.accessibilityIdentifier = "snippetEditor.kind"; content.addArrangedSubview(kind)
    command = textEditor("内容", text: snippet?.command ?? "", id: "snippetEditor.command")
    parameters.isOn = snippet?.usesParameters ?? false; parameters.accessibilityIdentifier = "snippetEditor.parameters"
    let row = MobileUI.stack([MobileUI.label("启用参数模板"), parameters], axis: .horizontal)
    row.distribution = .equalSpacing; content.addArrangedSubview(row)
    content.addArrangedSubview(MobileUI.label("用 {{name}} 定义参数。插入前填写参数并预览；插入后按回车执行。", style: .footnote, color: .secondaryLabel))
    content.addArrangedSubview(errorLabel)
  }
  private func save() {
    do {
      _ = try store.save(id: snippet?.id, name: name.text ?? "", command: command.text, group: group.text,
        kind: kind.selectedSegmentIndex == 1 ? .script : .command, usesParameters: parameters.isOn, expected: snippet)
      navigationController?.popViewController(animated: true)
    } catch { errorLabel.text = error.localizedDescription }
  }
}

final class MobileSnippetInvocationController: MobileFormController {
  private let snippet: Snippet
  private let session: MobileSession
  private var fields: [String: UITextField] = [:]
  private var preview: UITextView!
  private var insertButton: UIButton!
  private var observer: AnyCancellable?
  init(snippet: Snippet, session: MobileSession) { self.snippet = snippet; self.session = session; super.init(nibName: nil, bundle: nil) }
  required init?(coder: NSCoder) { fatalError("unsupported") }
  override func viewDidLoad() {
    super.viewDidLoad(); title = snippet.name
    content.addArrangedSubview(MobileUI.label("目标：\(session.name) · \(session.address)", style: .subheadline, color: .secondaryLabel))
    for name in snippet.parameterNames {
      let input = field(name, id: "snippetParameter.\(name)")
      input.addAction(UIAction { [weak self] _ in self?.render() }, for: .editingChanged)
      fields[name] = input
    }
    preview = textEditor("插入预览", id: "snippet.preview"); preview.isEditable = false
    insertButton = MobileUI.button("插入终端", symbol: "text.insert", filled: true, id: "snippet.insert") { [weak self] in self?.insert() }
    content.addArrangedSubview(insertButton); content.addArrangedSubview(errorLabel)
    observer = session.manager.$state.receive(on: RunLoop.main).sink { [weak self] _ in self?.render() }
    render()
  }
  private var values: [String: String] { fields.mapValues { $0.text ?? "" } }
  private func render() {
    do { preview.text = try snippet.resolvedCommand(parameters: values); errorLabel.text = "" }
    catch { preview.text = ""; errorLabel.text = error.localizedDescription }
    insertButton.isEnabled = session.manager.state == .connected && !preview.text.isEmpty
    if session.manager.state != .connected { errorLabel.text = "目标会话未连接，请连接后再插入。" }
  }
  private func insert() {
    guard session.manager.insertSnippet(snippet, parameters: values) else {
      errorLabel.text = "无法插入，请检查参数与目标会话状态。"; return
    }
    dismiss(animated: true) { [weak session] in session?.terminalController.showKeyboard() }
  }
}
