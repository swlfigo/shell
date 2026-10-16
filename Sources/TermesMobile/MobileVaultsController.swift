import UIKit
import SnapKit
import Combine
import TermesKit

final class MobileVaultsController: UITableViewController, UISearchResultsUpdating {
  let workspace: MobileWorkspace
  var onOpenSession: ((MobileSession) -> Void)?
  private var subscriptions = Set<AnyCancellable>()
  private let search = UISearchController(searchResultsController: nil)
  private var filteredHosts: [ConnectionProfile] {
    let query = search.searchBar.text ?? ""
    return workspace.hosts.filter { query.isEmpty || "\($0.name) \($0.hostname) \($0.username)".localizedCaseInsensitiveContains(query) }
  }
  private var hostsSection: Int { workspace.sessions.isEmpty ? 0 : 1 }

  init(workspace: MobileWorkspace) {
    self.workspace = workspace
    super.init(style: .insetGrouped)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Vaults"
    navigationItem.largeTitleDisplayMode = .always
    navigationController?.navigationBar.prefersLargeTitles = true
    search.searchResultsUpdater = self
    search.obscuresBackgroundDuringPresentation = false
    search.searchBar.placeholder = "搜索主机、地址或用户名"
    navigationItem.searchController = search
    navigationItem.hidesSearchBarWhenScrolling = false
    definesPresentationContext = true
    tableView.keyboardDismissMode = .onDrag
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "host")
    tableView.register(MobileSessionCell.self, forCellReuseIdentifier: "session")
    let add = UIBarButtonItem(systemItem: .add, primaryAction: UIAction { [weak self] _ in self?.editHost(nil) })
    add.accessibilityLabel = "新建主机"; add.accessibilityIdentifier = "hosts.add"
    let library = UIBarButtonItem(image: UIImage(systemName: "square.grid.2x2"), primaryAction: UIAction { [weak self] _ in
      guard let self else { return }; presentSheet(MobileLibraryController(workspace: workspace))
    })
    library.accessibilityLabel = "资料库"; library.accessibilityIdentifier = "library.open"
    var buttons = [add, library]
    if UIApplication.shared.supportsMultipleScenes {
      let window = UIBarButtonItem(image: UIImage(systemName: "rectangle.badge.plus"), primaryAction: UIAction { _ in
        UIApplication.shared.requestSceneSessionActivation(nil, userActivity: nil, options: nil)
      })
      window.accessibilityLabel = "新建窗口"; window.accessibilityIdentifier = "workspace.newWindow"
      buttons.append(window)
    }
    navigationItem.rightBarButtonItems = buttons
    let settings = UIBarButtonItem(image: UIImage(systemName: "gearshape"), primaryAction: UIAction { [weak self] _ in self?.showSettings() })
    settings.accessibilityLabel = "设置"; settings.accessibilityIdentifier = "settings.open"
    navigationItem.leftBarButtonItem = settings
    Publishers.CombineLatest(workspace.$hosts, workspace.$sessions).receive(on: RunLoop.main).sink { [weak self] _, _ in
      self?.tableView.reloadData()
    }.store(in: &subscriptions)
    workspace.$selectedSessionID.receive(on: RunLoop.main).sink { [weak self] _ in self?.tableView.reloadData() }.store(in: &subscriptions)
  }

  func updateSearchResults(for searchController: UISearchController) { tableView.reloadData() }
  override func numberOfSections(in tableView: UITableView) -> Int { hostsSection + 1 }
  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    section == hostsSection ? max(1, filteredHosts.count) : workspace.sessions.count
  }
  override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    section == hostsSection ? "主机 · \(workspace.hosts.count)" : "会话 · \(workspace.sessions.count)"
  }
  override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
    section == hostsSection ? "轻点主机即可连接，长按可编辑或打开新会话。" : nil
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    if indexPath.section != hostsSection {
      let cell = tableView.dequeueReusableCell(withIdentifier: "session", for: indexPath) as! MobileSessionCell
      let session = workspace.sessions[indexPath.row]
      cell.configure(session, selected: session.id == workspace.selectedSessionID)
      return cell
    }
    guard !filteredHosts.isEmpty else { return emptyCell() }
    let profile = filteredHosts[indexPath.row]
    let cell = tableView.dequeueReusableCell(withIdentifier: "host", for: indexPath)
    var content = cell.defaultContentConfiguration()
    content.text = profile.name
    content.textProperties.font = .preferredFont(forTextStyle: .headline)
    content.secondaryText = "\(profile.username)@\(profile.hostname)\(profile.port == 22 ? "" : ":\(profile.port)")" + (profile.jumpProfileId == nil ? "" : "\n通过跳板机")
    content.secondaryTextProperties.color = .secondaryLabel
    content.secondaryTextProperties.font = .preferredFont(forTextStyle: .caption1)
    content.image = UIImage(systemName: "server.rack")
    content.imageProperties.tintColor = .systemTeal
    content.imageToTextPadding = 14
    cell.contentConfiguration = content
    cell.accessoryType = .disclosureIndicator
    cell.accessibilityIdentifier = "host.\(profile.name)"
    cell.accessibilityTraits.insert(.button)
    return cell
  }

  private func emptyCell() -> UITableViewCell {
    let cell = UITableViewCell()
    cell.selectionStyle = .none
    let empty = workspace.hosts.isEmpty
    let title = MobileUI.label(empty ? "连接你的第一台服务器" : "没有匹配的主机", style: .headline)
    let description = MobileUI.label(empty ? "保存主机，在 iPhone 和 iPad 上\n随时进入远程终端。" : "试试其他名称、地址或用户名。", style: .subheadline, color: .secondaryLabel)
    title.textAlignment = .center; description.textAlignment = .center
    let stack = MobileUI.stack([MobileUI.symbol(empty ? "server.rack" : "magnifyingglass", size: 36), title, description], spacing: 16)
    if empty {
      stack.addArrangedSubview(MobileUI.button("新建主机", symbol: "plus", filled: true, id: "hosts.empty.add") { [weak self] in self?.editHost(nil) })
    }
    cell.contentView.addSubview(stack)
    stack.snp.makeConstraints { $0.edges.equalToSuperview().inset(UIEdgeInsets(top: 32, left: 16, bottom: 32, right: 16)) }
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    if indexPath.section != hostsSection { onOpenSession?(workspace.sessions[indexPath.row]); workspace.selectedSessionID = workspace.sessions[indexPath.row].id }
    else if !filteredHosts.isEmpty { open(filteredHosts[indexPath.row]) }
  }

  private func open(_ profile: ConnectionProfile, newSession: Bool = false) {
    search.isActive = false
    if let session = workspace.open(profile, newSession: newSession) { onOpenSession?(session) }
  }

  func editHost(_ profile: ConnectionProfile?) {
    let editor = MobileHostEditorController(workspace: workspace, profile: profile)
    editor.onSave = { [weak self, weak editor] profile, connect in
      editor?.dismiss(animated: true) { if connect { self?.open(profile) } }
    }
    let navigation = UINavigationController(rootViewController: editor)
    navigation.modalPresentationStyle = .formSheet
    (splitViewController ?? self).present(navigation, animated: true)
  }

  private func showSettings() {
    let navigation = UINavigationController(rootViewController: MobileSettingsController(appearance: workspace.appearance))
    navigation.modalPresentationStyle = .formSheet
    present(navigation, animated: true)
  }

  override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
    if indexPath.section != hostsSection {
      let session = workspace.sessions[indexPath.row]
      return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
        UIMenu(children: [UIAction(title: "关闭会话", image: UIImage(systemName: "xmark"), attributes: .destructive) { _ in self?.close(session) }])
      })
    }
    guard !filteredHosts.isEmpty else { return nil }
    let profile = filteredHosts[indexPath.row]
    return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
      UIMenu(children: [
        UIAction(title: "连接", image: UIImage(systemName: "terminal")) { _ in self?.open(profile) },
        UIAction(title: "在新会话中连接", image: UIImage(systemName: "plus.square")) { _ in self?.open(profile, newSession: true) },
        UIAction(title: "编辑主机", image: UIImage(systemName: "pencil")) { _ in self?.editHost(profile) },
        UIAction(title: "删除主机", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in self?.delete(profile) },
      ])
    })
  }

  override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
    if indexPath.section != hostsSection {
      let session = workspace.sessions[indexPath.row]
      return UISwipeActionsConfiguration(actions: [UIContextualAction(style: .destructive, title: "关闭") { [weak self] _, _, done in self?.close(session); done(true) }])
    }
    guard !filteredHosts.isEmpty else { return nil }
    let profile = filteredHosts[indexPath.row]
    let edit = UIContextualAction(style: .normal, title: "编辑") { [weak self] _, _, done in self?.editHost(profile); done(true) }
    edit.backgroundColor = .systemBlue
    let delete = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, done in self?.delete(profile); done(true) }
    return UISwipeActionsConfiguration(actions: [delete, edit])
  }

  private func delete(_ profile: ConnectionProfile) {
    let alert = UIAlertController(title: "删除主机？", message: "删除「\(profile.name)」及其保存的密码。已打开的会话会保留。", preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
    alert.addAction(UIAlertAction(title: "删除", style: .destructive) { [weak self] _ in self?.workspace.delete(profile) })
    present(alert, animated: true)
  }

  private func close(_ session: MobileSession) {
    guard session.hasUnfinishedWork else { workspace.close(session); return }
    let alert = UIAlertController(title: "关闭会话？", message: "此操作会断开 SSH、停止端口转发并取消此会话的文件传输。", preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
    alert.addAction(UIAlertAction(title: "断开并关闭", style: .destructive) { [weak self] _ in self?.workspace.close(session) })
    present(alert, animated: true)
  }
}

private final class MobileSessionCell: UITableViewCell {
  private var stateChange: AnyCancellable?

  func configure(_ session: MobileSession, selected: Bool) {
    accessibilityIdentifier = "session.\(session.profileID)"
    accessoryType = selected ? .checkmark : .none
    stateChange = session.manager.$state.sink { [weak self] state in
      guard let self else { return }
      var content = self.defaultContentConfiguration()
      content.text = session.name; content.secondaryText = state.displayText
      content.image = UIImage(systemName: "terminal")
      content.imageProperties.tintColor = state.mobileColor
      self.contentConfiguration = content
    }
  }
  override func prepareForReuse() { super.prepareForReuse(); stateChange = nil }
}
