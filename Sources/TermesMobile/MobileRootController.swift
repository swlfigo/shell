import UIKit
import SnapKit
import Combine
import TermesKit

final class MobileRootController: UISplitViewController, UISplitViewControllerDelegate {
  override var canBecomeFirstResponder: Bool { true }
  private let workspace: MobileWorkspace
  private let vaults: MobileVaultsController
  private let detail = UINavigationController()
  private lazy var sessionWorkspace = MobileWorkspaceController(workspace: workspace)
  private var subscriptions = Set<AnyCancellable>()

  init(workspace: MobileWorkspace) {
    self.workspace = workspace
    vaults = MobileVaultsController(workspace: workspace)
    super.init(style: .doubleColumn)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    delegate = self
    preferredDisplayMode = .oneBesideSecondary
    preferredSplitBehavior = .tile
    minimumPrimaryColumnWidth = 290
    maximumPrimaryColumnWidth = 420
    preferredPrimaryColumnWidth = 340
    setViewController(UINavigationController(rootViewController: vaults), for: .primary)
    setViewController(detail, for: .secondary)
    if let session = workspace.selectedSession { showSession(session) }
    else { showWelcome() }
    vaults.onOpenSession = { [weak self] in self?.showSession($0) }
    workspace.$selectedSessionID.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] _ in
      guard let self else { return }
      if let session = self.workspace.selectedSession { self.showSession(session) }
      else { self.showWelcome(); self.show(.primary) }
    }.store(in: &subscriptions)
    workspace.$error.receive(on: RunLoop.main).sink { [weak self] _ in self?.showPendingError() }.store(in: &subscriptions)
    workspace.appearance.$settings.sink { [weak self] settings in
      self?.overrideUserInterfaceStyle = settings.theme == .system ? .unspecified : settings.theme == .dark ? .dark : .light
    }.store(in: &subscriptions)
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    if workspace.selectedSession == nil { becomeFirstResponder() }
    showPendingError()
  }

  private func showPendingError() {
    guard isViewLoaded, view.window != nil, presentedViewController == nil, let message = workspace.error else { return }
    workspace.error = nil
    presentError(message)
  }

  private func showSession(_ session: MobileSession) {
    if detail.topViewController !== sessionWorkspace { detail.setViewControllers([sessionWorkspace], animated: false) }
    sessionWorkspace.render()
    show(.secondary)
  }

  private func showWelcome() {
    let welcome = MobileWelcomeController()
    welcome.onAddHost = { [weak self] in self?.vaults.editHost(nil) }
    detail.setViewControllers([welcome], animated: false)
  }

  // Window-scoped commands follow the selected pane, including compact layouts.
  // A presented editor owns its keyboard; workspace commands must not reach it.
  private var hasPresentedSheet: Bool {
    func hasSheet(_ controller: UIViewController) -> Bool {
      controller.presentedViewController != nil || controller.children.contains(where: hasSheet)
    }
    return hasSheet(self)
  }
  private var canUseTerminalTools: Bool {
    guard let session = workspace.selectedSession else { return false }
    return session.manager.state == .connected || session.hasConnected && !session.manager.state.isActive
  }

  override var keyCommands: [UIKeyCommand]? {
    func command(_ input: String, _ flags: UIKeyModifierFlags = .command, _ title: String, _ action: Selector) -> UIKeyCommand {
      let key = UIKeyCommand(input: input, modifierFlags: flags, action: action)
      key.discoverabilityTitle = title
      key.wantsPriorityOverSystemBehavior = true
      return key
    }
    var commands = [
      command("t", .command, "新建连接标签", #selector(newConnectionTab)),
      command("d", .command, "复制当前会话", #selector(duplicateCurrentSession)),
      command("w", .command, "关闭当前会话", #selector(closeCurrentSession)),
      command(",", .command, "设置", #selector(openSettings)),
      command("[", [.command, .shift], "上一个标签", #selector(previousTab)),
      command("]", [.command, .shift], "下一个标签", #selector(nextTab)),
      command("h", [.command, .shift], "返回 Vaults", #selector(returnToVaults)),
      command("f", [.command, .alternate], "搜索主机", #selector(searchHosts))
    ]
    commands.append(contentsOf: [
      command("f", .command, "搜索终端历史", #selector(searchTerminal)),
      command("g", .command, "下一个匹配", #selector(nextTerminalMatch)),
      command("g", [.command, .shift], "上一个匹配", #selector(previousTerminalMatch)),
      command("e", [.command, .shift], "导出终端输出", #selector(exportTerminalOutput))
    ])
    if workspace.selectedSession?.terminalController.isSearching == true {
      commands.append(command(UIKeyCommand.inputEscape, [], "关闭终端搜索", #selector(closeTerminalSearch)))
    }
    if UIApplication.shared.supportsMultipleScenes {
      commands.append(command("n", .command, "新建窗口", #selector(newWorkspaceWindow)))
    }
    for index in 1...9 {
      commands.append(command(String(index), .command, "标签 \(index)", #selector(selectNumberedTab)))
    }
    return commands
  }

  override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
    guard keyCommands?.contains(where: { $0.action == action }) == true else {
      return super.canPerformAction(action, withSender: sender)
    }
    guard !hasPresentedSheet else { return false }
    if [#selector(searchTerminal), #selector(nextTerminalMatch), #selector(previousTerminalMatch),
        #selector(exportTerminalOutput)].contains(action) { return canUseTerminalTools }
    if [#selector(closeCurrentSession), #selector(duplicateCurrentSession), #selector(closeTerminalSearch)].contains(action) {
      return workspace.selectedSession != nil
    }
    if action == #selector(nextTab) || action == #selector(previousTab) { return workspace.layout.tabs.count > 1 }
    if action == #selector(selectNumberedTab), let key = sender as? UIKeyCommand, let number = Int(key.input ?? "") {
      return workspace.layout.tabs.indices.contains(number - 1)
    }
    return true
  }

  @objc func newConnectionTab(_ sender: Any?) {
    guard !hasPresentedSheet else { return }
    let picker = MobileVaultsController(workspace: workspace, choosingNewSession: true)
    picker.onOpenSession = { [weak self, weak picker] session in
      picker?.dismiss(animated: true) { self?.showSession(session); session.terminalController.showKeyboard() }
    }
    presentSheet(picker)
  }

  @objc func duplicateCurrentSession(_ sender: Any?) {
    guard !hasPresentedSheet, let session = workspace.selectedSession else { return }
    if let copy = workspace.duplicate(session) { focusSession(copy) }
  }
  @objc func closeCurrentSession(_ sender: Any?) {
    guard !hasPresentedSheet else { return }
    sessionWorkspace.closeFocusedSession()
  }
  @objc func openSettings(_ sender: Any?) {
    guard !hasPresentedSheet else { return }
    presentSheet(MobileSettingsController(appearance: workspace.appearance))
  }
  @objc func newWorkspaceWindow(_ sender: Any?) {
    guard !hasPresentedSheet, UIApplication.shared.supportsMultipleScenes else { return }
    UIApplication.shared.requestSceneSessionActivation(nil, userActivity: nil, options: nil)
  }
  @objc func selectNumberedTab(_ sender: UIKeyCommand) {
    guard !hasPresentedSheet, let number = Int(sender.input ?? "") else { return }
    workspace.selectTab(at: number - 1)
    if let session = workspace.selectedSession { focusSession(session) }
  }
  @objc func previousTab(_ sender: Any?) { cycleTab(by: -1) }
  @objc func nextTab(_ sender: Any?) { cycleTab(by: 1) }
  private func cycleTab(by offset: Int) {
    guard !hasPresentedSheet else { return }
    workspace.cycleTab(by: offset)
    if let session = workspace.selectedSession { focusSession(session) }
  }
  private func focusSession(_ session: MobileSession) {
    showSession(session)
    sessionWorkspace.render()
    session.terminalController.showKeyboard()
  }
  @objc func returnToVaults(_ sender: Any?) {
    guard !hasPresentedSheet else { return }
    workspace.selectedSession?.terminalController.hideKeyboard()
    show(.primary)
  }
  @objc func searchHosts(_ sender: Any?) {
    guard !hasPresentedSheet else { return }
    show(.primary)
    vaults.focusSearch()
  }
  @objc func searchTerminal(_ sender: Any?) {
    guard !hasPresentedSheet, canUseTerminalTools else { return }
    workspace.selectedSession?.terminalController.showSearch()
  }
  @objc func nextTerminalMatch(_ sender: Any?) {
    guard !hasPresentedSheet, canUseTerminalTools else { return }
    workspace.selectedSession?.terminalController.navigateSearch(forward: true)
  }
  @objc func previousTerminalMatch(_ sender: Any?) {
    guard !hasPresentedSheet, canUseTerminalTools else { return }
    workspace.selectedSession?.terminalController.navigateSearch(forward: false)
  }
  @objc func closeTerminalSearch(_ sender: Any?) {
    guard !hasPresentedSheet else { return }
    workspace.selectedSession?.terminalController.closeSearch()
  }
  @objc func exportTerminalOutput(_ sender: Any?) {
    guard !hasPresentedSheet, canUseTerminalTools else { return }
    workspace.selectedSession?.terminalController.exportOutput(from: self)
  }

  func splitViewController(_ svc: UISplitViewController, topColumnForCollapsingToProposedTopColumn proposedTopColumn: UISplitViewController.Column) -> UISplitViewController.Column {
    workspace.selectedSessionID == nil ? .primary : .secondary
  }
}

private final class MobileWelcomeController: UIViewController {
  var onAddHost: (() -> Void)?

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Termes"
    view.backgroundColor = .systemBackground
    let heading = MobileUI.label("你的远程工作区", style: .title2)
    let body = MobileUI.label("选择一台主机开始连接。\n会话会在切换页面时保留。", color: .secondaryLabel)
    heading.textAlignment = .center; body.textAlignment = .center
    let button = MobileUI.button("新建主机", symbol: "plus", filled: true) { [weak self] in self?.onAddHost?() }
    let stack = MobileUI.stack([MobileUI.symbol("terminal"), heading, body, button], spacing: 20)
    view.addSubview(stack)
    stack.snp.makeConstraints { make in
      make.center.equalTo(view.safeAreaLayoutGuide)
      make.width.lessThanOrEqualTo(360)
      make.leading.greaterThanOrEqualTo(view.safeAreaLayoutGuide).offset(24)
      make.trailing.lessThanOrEqualTo(view.safeAreaLayoutGuide).offset(-24)
    }
  }
}
