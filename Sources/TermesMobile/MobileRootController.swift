import UIKit
import SnapKit
import Combine
import TermesKit

final class MobileRootController: UISplitViewController, UISplitViewControllerDelegate {
  private let workspace: MobileWorkspace
  private let vaults: MobileVaultsController
  private let detail = UINavigationController()
  private var sessionControllers: [UUID: MobileSessionController] = [:]
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
    showWelcome()
    vaults.onOpenSession = { [weak self] in self?.showSession($0) }
    workspace.$selectedSessionID.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] _ in
      guard let self else { return }
      if let session = self.workspace.selectedSession { self.showSession(session) }
      else { self.showWelcome(); self.show(.primary) }
    }.store(in: &subscriptions)
    workspace.$sessions.sink { [weak self] sessions in
      self?.sessionControllers = self?.sessionControllers.filter { id, _ in sessions.contains { $0.id == id } } ?? [:]
    }.store(in: &subscriptions)
    workspace.$error.receive(on: RunLoop.main).sink { [weak self] _ in self?.showPendingError() }.store(in: &subscriptions)
    workspace.appearance.$settings.sink { [weak self] settings in
      self?.overrideUserInterfaceStyle = settings.theme == .system ? .unspecified : settings.theme == .dark ? .dark : .light
    }.store(in: &subscriptions)
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    showPendingError()
  }

  private func showPendingError() {
    guard isViewLoaded, view.window != nil, presentedViewController == nil, let message = workspace.error else { return }
    workspace.error = nil
    presentError(message)
  }

  private func showSession(_ session: MobileSession) {
    let controller = sessionControllers[session.id] ?? MobileSessionController(workspace: workspace, session: session)
    sessionControllers[session.id] = controller
    if detail.topViewController !== controller { detail.setViewControllers([controller], animated: false) }
    show(.secondary)
  }

  private func showWelcome() {
    let welcome = MobileWelcomeController()
    welcome.onAddHost = { [weak self] in self?.vaults.editHost(nil) }
    detail.setViewControllers([welcome], animated: false)
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
