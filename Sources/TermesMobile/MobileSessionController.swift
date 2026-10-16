import UIKit
import SnapKit
import Combine
import TermesKit

final class MobileSessionController: UIViewController {
  private let workspace: MobileWorkspace
  let session: MobileSession
  var onNavigationChange: (() -> Void)?
  var showsSessionTabs = true
  private var subscriptions = Set<AnyCancellable>()
  private let tabsScroll = UIScrollView()
  private let tabs = MobileUI.stack(axis: .horizontal, spacing: 8)
  private let statusDot = UIView()
  private let statusLabel = MobileUI.label("", style: .caption1)
  private let addressLabel = MobileUI.label("", style: .caption2, color: .secondaryLabel)
  private let terminalContainer = UIView()
  private let overlay = UIScrollView()
  private let overlayStack = MobileUI.stack(spacing: 20)
  private let disconnectedBanner = MobileUI.stack(axis: .horizontal)
  private let failureLabel = MobileUI.label("", style: .caption1, color: .secondaryLabel)
  private var keyboardButton: UIBarButtonItem!
  private var monitorButton: UIBarButtonItem!
  private var menuButton: UIBarButtonItem!
  private var hasConnected: Bool { session.hasConnected }

  init(workspace: MobileWorkspace, session: MobileSession) {
    self.workspace = workspace; self.session = session
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = session.name
    view.backgroundColor = .systemBackground
    navigationItem.largeTitleDisplayMode = .never
    keyboardButton = UIBarButtonItem(image: UIImage(systemName: "keyboard"), primaryAction: UIAction { [weak self] _ in self?.session.terminalController.showKeyboard() })
    keyboardButton.accessibilityLabel = "显示键盘"; keyboardButton.accessibilityIdentifier = "terminal.keyboard"
    monitorButton = UIBarButtonItem(image: UIImage(systemName: "chart.xyaxis.line"), primaryAction: UIAction { [weak self] _ in self?.showMonitor() })
    monitorButton.accessibilityLabel = "服务器监控"; monitorButton.accessibilityIdentifier = "terminal.monitor"
    menuButton = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: UIMenu())
    menuButton.accessibilityLabel = "会话操作"; menuButton.accessibilityIdentifier = "terminal.menu"
    navigationItem.rightBarButtonItems = [menuButton, keyboardButton, monitorButton]

    tabsScroll.showsHorizontalScrollIndicator = false
    tabsScroll.addSubview(tabs)
    tabs.snp.makeConstraints { make in
      make.edges.equalTo(tabsScroll.contentLayoutGuide).inset(UIEdgeInsets(top: 5, left: 12, bottom: 5, right: 12))
      make.height.equalTo(tabsScroll.frameLayoutGuide).offset(-10)
    }
    tabsScroll.snp.makeConstraints { $0.height.equalTo(46).priority(999) }
    statusDot.layer.cornerRadius = 4
    statusDot.snp.makeConstraints { $0.size.equalTo(8) }
    addressLabel.text = session.address
    addressLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    addressLabel.lineBreakMode = .byTruncatingMiddle; addressLabel.numberOfLines = 1
    let info = UIButton(type: .infoLight)
    info.accessibilityLabel = "连接详情"
    info.accessibilityIdentifier = "terminal.progress"
    info.addAction(UIAction { [weak self] _ in self?.showProgress() }, for: .touchUpInside)
    let status = MobileUI.stack([statusDot, statusLabel, addressLabel, info], axis: .horizontal, spacing: 8)
    status.alignment = .center
    statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
    let statusContainer = UIView(); statusContainer.backgroundColor = .secondarySystemBackground
    statusContainer.addSubview(status)
    status.snp.makeConstraints { $0.edges.equalToSuperview().inset(UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)) }
    disconnectedBanner.isLayoutMarginsRelativeArrangement = true
    disconnectedBanner.layoutMargins = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
    disconnectedBanner.alignment = .center
    disconnectedBanner.backgroundColor = .secondarySystemBackground
    disconnectedBanner.addArrangedSubview(failureLabel)
    let reconnect = MobileUI.button("重新连接") { [weak self] in self?.reconnect() }
    reconnect.setContentCompressionResistancePriority(.required, for: .horizontal)
    disconnectedBanner.addArrangedSubview(reconnect)
    let stack = MobileUI.stack([tabsScroll, statusContainer, disconnectedBanner, terminalContainer], spacing: 0)
    view.addSubview(stack)
    stack.snp.makeConstraints { make in
      make.top.leading.trailing.equalTo(view.safeAreaLayoutGuide)
      make.bottom.equalTo(view.keyboardLayoutGuide.snp.top)
    }

    let terminal = session.terminalController
    if terminal.parent != nil {
      terminal.willMove(toParent: nil); terminal.view.removeFromSuperview(); terminal.removeFromParent()
    }
    addChild(terminal)
    terminalContainer.addSubview(terminal.view)
    terminal.view.snp.makeConstraints { $0.edges.equalToSuperview() }
    terminal.didMove(toParent: self)
    buildOverlay()
    session.manager.$state.receive(on: RunLoop.main).sink { [weak self] state in self?.render(state) }.store(in: &subscriptions)
    workspace.$sessions.receive(on: RunLoop.main).sink { [weak self] sessions in self?.updateTabs(sessions) }.store(in: &subscriptions)
    workspace.appearance.$settings.receive(on: RunLoop.main).sink { [weak self] _ in self?.applyAppearance() }.store(in: &subscriptions)
    registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (controller: MobileSessionController, _: UITraitCollection) in controller.applyAppearance() }
    render(session.manager.state)
    applyAppearance()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    session.terminalController.hideKeyboard()
  }

  private func buildOverlay() {
    overlay.backgroundColor = .systemBackground
    terminalContainer.addSubview(overlay)
    overlay.snp.makeConstraints { $0.edges.equalToSuperview() }
    let content = UIView(); overlay.addSubview(content)
    content.snp.makeConstraints { make in
      make.edges.equalTo(overlay.contentLayoutGuide)
      make.width.equalTo(overlay.frameLayoutGuide)
      make.height.greaterThanOrEqualTo(overlay.frameLayoutGuide)
    }
    content.addSubview(overlayStack)
    overlayStack.alignment = .center
    overlayStack.snp.makeConstraints { make in
      make.center.equalToSuperview()
      make.width.lessThanOrEqualTo(440)
      make.leading.greaterThanOrEqualToSuperview().offset(24)
      make.trailing.lessThanOrEqualToSuperview().offset(-24)
      make.top.greaterThanOrEqualToSuperview().offset(24)
      make.bottom.lessThanOrEqualToSuperview().offset(-24)
    }
  }

  private func updateTabs(_ sessions: [MobileSession]) {
    tabs.arrangedSubviews.forEach { $0.removeFromSuperview() }
    tabsScroll.isHidden = !showsSessionTabs || sessions.count < 2
    for item in sessions {
      let button = MobileUI.button(item.name, filled: item.id == session.id, id: "sessionTab.\(item.name)") { [weak self] in self?.workspace.selectedSessionID = item.id }
      tabs.addArrangedSubview(button)
    }
  }

  private func applyAppearance() {
    session.terminalController.apply(workspace.appearance.settings, dark: traitCollection.userInterfaceStyle == .dark)
  }

  private func render(_ state: SessionManager.State) {
    statusDot.backgroundColor = state.mobileColor; statusLabel.text = state.displayText
    keyboardButton.isEnabled = state == .connected
    disconnectedBanner.isHidden = state.isActive || !hasConnected
    if case .failed(let message) = state { failureLabel.text = message }
    else { failureLabel.text = "连接已断开，终端输出已保留。" }
    overlay.isHidden = state == .connected || (hasConnected && !state.isActive)
    overlayStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    if !overlay.isHidden {
      switch state {
      case .needsHostKeyConfirm(let fingerprint): renderTrust(fingerprint)
      case .connecting, .reconnecting:
        let spinner = UIActivityIndicatorView(style: .large); spinner.startAnimating()
        overlayStack.addArrangedSubview(spinner)
        addOverlayLabel(state.displayText, style: .title3)
        addOverlayLabel(session.address, style: .caption1, color: .secondaryLabel)
        overlayStack.addArrangedSubview(MobileUI.button("查看连接详情") { [weak self] in self?.showProgress() })
        if case .reconnecting = state {
          overlayStack.addArrangedSubview(MobileUI.button("立即重试", filled: true) { [weak self] in self?.session.manager.retryReconnectNow() })
        }
        overlayStack.addArrangedSubview(MobileUI.button("取消连接") { [weak self] in self?.session.disconnect() })
      case .failed, .disconnected, .idle:
        overlayStack.addArrangedSubview(MobileUI.symbol("network.slash"))
        addOverlayLabel(state.displayText, style: .title3)
        addOverlayLabel(failureLabel.text ?? "", style: .subheadline, color: .secondaryLabel)
        overlayStack.addArrangedSubview(MobileUI.button("重新连接", symbol: "arrow.clockwise", filled: true, id: "terminal.reconnect") { [weak self] in self?.reconnect() })
        overlayStack.addArrangedSubview(MobileUI.button("查看连接详情") { [weak self] in self?.showProgress() })
      case .connected: break
      }
    }
    updateMenu(state)
  }

  private func addOverlayLabel(_ text: String, style: UIFont.TextStyle, color: UIColor = .label) {
    let label = MobileUI.label(text, style: style, color: color); label.textAlignment = .center
    overlayStack.addArrangedSubview(label)
  }

  private func renderTrust(_ fingerprint: String) {
    let attempt = session.manager.connectionProgress.attemptID
    overlayStack.addArrangedSubview(MobileUI.symbol("checkmark.shield"))
    addOverlayLabel("确认服务器身份", style: .title3)
    if let endpoint = session.manager.pendingHostKeyEndpoint {
      addOverlayLabel("\(endpoint.hostname):\(endpoint.port)", style: .subheadline)
    }
    addOverlayLabel("首次连接此服务器。请与服务器管理员提供的指纹核对后再信任。", style: .subheadline, color: .secondaryLabel)
    let text = UITextView()
    text.text = fingerprint; text.isEditable = false; text.isScrollEnabled = false
    text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    text.backgroundColor = .tertiarySystemFill; text.layer.cornerRadius = 10
    text.textContainerInset = .init(top: 12, left: 12, bottom: 12, right: 12)
    overlayStack.addArrangedSubview(text)
    text.snp.makeConstraints { $0.width.equalTo(overlayStack) }
    overlayStack.addArrangedSubview(MobileUI.button("信任并连接", filled: true, id: "hostTrust.accept") { [weak self] in
      self?.session.manager.confirmHostKey(true, attemptID: attempt, fingerprint: fingerprint)
    })
    overlayStack.addArrangedSubview(MobileUI.button("取消连接", id: "hostTrust.reject") { [weak self] in
      self?.session.manager.confirmHostKey(false, attemptID: attempt, fingerprint: fingerprint)
    })
  }

  private func updateMenu(_ state: SessionManager.State) {
    var actions: [UIMenuElement] = [UIAction(title: "连接详情", image: UIImage(systemName: "list.bullet.rectangle")) { [weak self] _ in self?.showProgress() }]
    actions.append(UIAction(title: "服务器监控", image: UIImage(systemName: "chart.xyaxis.line")) { [weak self] _ in self?.showMonitor() })
    let terminalTools: UIMenuElement.Attributes = state == .connected || hasConnected && !state.isActive ? [] : .disabled
    actions.append(UIAction(title: "搜索终端历史", image: UIImage(systemName: "magnifyingglass"), attributes: terminalTools) { [weak self] _ in
      self?.session.terminalController.showSearch()
    })
    actions.append(UIAction(title: "导出终端输出", image: UIImage(systemName: "square.and.arrow.up"), attributes: terminalTools) { [weak self] _ in
      guard let self else { return }; session.terminalController.exportOutput(from: self)
    })
    actions.append(UIAction(title: "文件", image: UIImage(systemName: "folder")) { [weak self] _ in
      guard let self else { return }; session.terminalController.hideKeyboard()
      presentSheet(MobileFilesController(model: session.files()))
    })
    actions.append(UIAction(title: "端口转发", image: UIImage(systemName: "arrow.left.arrow.right")) { [weak self] _ in
      guard let self else { return }; session.terminalController.hideKeyboard()
      presentSheet(MobileForwardingController(model: session.manager.portForwards, name: session.name))
    })
    actions.append(UIAction(title: "插入常用命令", image: UIImage(systemName: "text.insert")) { [weak self] _ in
      guard let self else { return }; session.terminalController.hideKeyboard()
      presentSheet(MobileSnippetsController(store: workspace.snippets, session: session))
    })
    actions.append(UIAction(title: "复制到新标签", image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in
      guard let self else { return }; workspace.duplicate(session)
    })
    if workspace.layout.tab(containing: session.id)?.isWorkspace == true {
      actions.append(UIAction(title: "最大化或还原窗格", image: UIImage(systemName: "arrow.up.left.and.arrow.down.right")) { [weak self] _ in
        guard let self else { return }; workspace.toggleMaximize(session)
      })
      actions.append(UIAction(title: "移到独立标签", image: UIImage(systemName: "rectangle.on.rectangle")) { [weak self] _ in
        guard let self else { return }; workspace.detach(session)
      })
    }
    let candidates = workspace.sessions.filter { $0.id != session.id && workspace.layout.tab(containing: $0.id)?.isWorkspace == false }
    for edge in [PaneEdge.right, .bottom] where !candidates.isEmpty {
      let choices = candidates.map { item in
        UIAction(title: item.name) { [weak self] _ in
          guard let self else { return }; workspace.merge(item, beside: session, edge: edge)
        }
      }
      actions.append(UIMenu(title: edge == .right ? "合并到右侧分屏" : "合并到下方分屏", children: choices))
    }
    if let app = UIApplication.shared.delegate as? MobileAppDelegate {
      let windows = app.otherWorkspaces(than: workspace)
      if !windows.isEmpty {
        let choices = windows.enumerated().map { index, destination in
          UIAction(title: "窗口 \(index + 1)：\(destination.selectedSession?.name ?? "空白工作区")") { [weak self] _ in
            guard let self else { return }; workspace.transfer(session, to: destination)
          }
        }
        actions.append(UIMenu(title: "移到其他窗口", children: choices))
      }
    }
    if case .reconnecting = state {
      actions.append(UIAction(title: "立即重试", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in self?.session.manager.retryReconnectNow() })
    }
    if state.isActive {
      actions.append(UIAction(title: "断开连接", image: UIImage(systemName: "bolt.slash"), attributes: .destructive) { [weak self] _ in self?.confirmDisconnect() })
    } else {
      actions.append(UIAction(title: "重新连接", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in self?.reconnect() })
    }
    actions.append(UIAction(title: "关闭会话", image: UIImage(systemName: "xmark"), attributes: .destructive) { [weak self] _ in self?.closeSession() })
    menuButton.menu = UIMenu(children: actions)
    onNavigationChange?()
  }

  func refreshNavigation() { updateMenu(session.manager.state) }

  private func reconnect() { workspace.reconnect(session) }
  private func showMonitor() {
    guard presentedViewController == nil else { return }
    session.terminalController.hideKeyboard()
    let controller = MobileServerMonitorController(model: session.manager.serverMonitor, serverName: session.name)
    let navigation = UINavigationController(rootViewController: controller)
    navigation.modalPresentationStyle = .formSheet
    navigation.preferredContentSize = CGSize(width: 760, height: 900)
    present(navigation, animated: true)
  }
  private func showProgress() {
    session.terminalController.hideKeyboard()
    let controller = MobileConnectionProgressController(model: session.manager.connectionProgress)
    let navigation = UINavigationController(rootViewController: controller)
    navigation.modalPresentationStyle = .formSheet
    present(navigation, animated: true)
  }
  private func confirmDisconnect() {
    let alert = UIAlertController(title: "断开 SSH 连接？", message: "终端输出会保留，可随时重新连接。", preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
    alert.addAction(UIAlertAction(title: "断开连接", style: .destructive) { [weak self] _ in self?.session.disconnect() })
    present(alert, animated: true)
  }
  @objc func closeSession() {
    guard session.hasUnfinishedWork else { workspace.close(session); return }
    let alert = UIAlertController(title: "关闭会话？", message: "此操作会断开 SSH、停止端口转发并取消此会话的文件传输。", preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
    alert.addAction(UIAlertAction(title: "断开并关闭", style: .destructive) { [weak self] _ in
      guard let self else { return }; self.workspace.close(self.session)
    })
    present(alert, animated: true)
  }

}
