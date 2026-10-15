import AppKit
import Combine
import TermesKit
import SnapKit
import SSHCore

/// Header-button callbacks into the owning window controller.
struct PaneActions {
  var detach: @MainActor (UUID) -> Void
  var toggleMaximize: @MainActor (UUID) -> Void
  var close: @MainActor (UUID) -> Void
  var snippetMenu: (@MainActor () -> NSMenu)? = nil
  var moveMenu: (@MainActor (UUID) -> NSMenu)? = nil
}

/// One SSH session in one pane. Owns its `SessionManager` for the pane's whole life and swaps
/// the connect page ↔ terminal. Tab switches, merges and detaches only re-parent `view`.
@MainActor
final class SessionPaneController: NSViewController {
  let id: UUID
  let session: SessionManager
  var unfinishedTransferCount: Int {
    fileVC?.model.transfers.jobs.filter { ![.completed, .cancelled].contains($0.state) }.count ?? 0
  }
  var activeForwardCount: Int {
    session.portForwards.rules.filter {
      switch $0.state { case .starting, .running, .stopping: return true; default: return false }
    }.count
  }
  private let profiles: ConnectionProfileService
  private(set) var label: SessionLabel?
  /// Fires after the session state or the label changed (tab bar / window title refresh).
  let changes = PassthroughSubject<Void, Never>()
  var actions: PaneActions?
  var isInWorkspace = false { didSet { updateChrome() } }
  var isFocused = false { didSet { updateChrome() } }
  var isMaximized = false { didSet { updateChrome() } }

  private var stateObserver: AnyCancellable?
  private var appearanceObserver: AnyCancellable?
  private var appearanceSettings = AppearanceSettings()
  private var connectVC: ConnectViewController?
  private var lastConnection: ConnectionDraft?
  private var terminalVC: TerminalViewController?
  private(set) var progressVC: ConnectionProgressViewController?
  private(set) var progressWindow: ConnectionProgressWindowController?
  private var dismissedProgressID: UUID?
  private var fileVC: FileBrowserViewController?
  private(set) var monitorVC: ServerMonitorViewController?
  private var terminalMonitorView: TerminalMonitorView?
  private(set) var toolsView: SessionToolsView?
  private var toolsScroll: SessionToolsScrollView?
  private(set) var isToolsVisible = false
  private(set) var forwardWindow: NSWindowController?
  private var closed = false
  private var hovering = false
  private let root = PaneRootView(frame: NSRect(x: 0, y: 0, width: 820, height: 540))
  private let contentHost = NSView()
  private var contentConstraints: [ObjectIdentifier: [Constraint]] = [:]
  private let titleLabel = NSTextField(labelWithString: "")
  private let subtitleLabel = NSTextField(labelWithString: "")
  private let header = NSStackView()
  private lazy var disconnectButton = Self.iconButton("bolt.slash", tip: "断开连接", target: self, action: #selector(disconnectTapped))
  private lazy var filesButton = Self.iconButton("folder", tip: "服务器文件", target: self, action: #selector(showFilesTool))
  private lazy var toolsButton: NSButton = {
    let button = NSButton(title: "工具", target: self, action: #selector(toggleTools))
    button.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: nil)
    button.imagePosition = .imageLeft; button.isBordered = false; button.font = .systemFont(ofSize: 12, weight: .medium)
    button.setAccessibilityLabel("显示或收起服务器工具面板")
    button.snp.makeConstraints { make in make.size.equalTo(NSSize(width: 64, height: 24)) }
    return button
  }()
  private lazy var moreButton = Self.iconButton("ellipsis", tip: "更多会话操作", target: self, action: #selector(showPaneMenu))
  private lazy var detachButton = Self.iconButton("rectangle.portrait.and.arrow.right", tip: "移回标签栏",
                                                  target: self, action: #selector(detachTapped))
  private lazy var maximizeButton = Self.iconButton("arrow.up.left.and.arrow.down.right", tip: "最大化",
                                                    target: self, action: #selector(maximizeTapped))
  private lazy var closeButton = Self.iconButton("xmark", tip: "关闭", target: self, action: #selector(closeTapped))

  init(session: SessionManager, profiles: ConnectionProfileService, appearance: AppearanceStore? = nil, id: UUID = UUID()) {
    self.id = id
    self.session = session
    self.profiles = profiles
    super.init(nibName: nil, bundle: nil)
    stateObserver = session.$state.sink { [weak self] state in
      // $state publishes in willSet; hop to the next runloop turn so session.state is current too.
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply(state) } }
    }
    appearanceObserver = appearance?.$settings.sink { [weak self] value in
      self?.appearanceSettings = value; self?.terminalVC?.applyAppearance(value)
    }
  }
  required init?(coder: NSCoder) { fatalError("unsupported") }

  override func loadView() {
    titleLabel.font = .boldSystemFont(ofSize: 12)
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    subtitleLabel.font = .systemFont(ofSize: 11)
    subtitleLabel.textColor = .secondaryLabelColor
    subtitleLabel.lineBreakMode = .byTruncatingTail
    subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let identity = NSStackView(views: [titleLabel, subtitleLabel])
    identity.orientation = .vertical; identity.alignment = .leading; identity.spacing = 2
    identity.setContentHuggingPriority(.defaultLow, for: .horizontal)
    identity.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    for label in [titleLabel, subtitleLabel] {
      label.snp.makeConstraints { make in make.width.equalTo(identity.snp.width) }
    }
    filesButton.toolTip = "浏览远端文件（SFTP）"
    for v in [identity, filesButton, toolsButton, moreButton, disconnectButton, detachButton, maximizeButton, closeButton] {
      header.addArrangedSubview(v)
    }
    header.orientation = .horizontal
    header.distribution = .fill
    header.alignment = .centerY
    header.spacing = 4
    header.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 8)
    let column = NSStackView(views: [header, contentHost])
    column.orientation = .vertical
    column.spacing = 0
    column.distribution = .fill
    contentHost.setContentHuggingPriority(.defaultLow, for: .vertical)
    root.addSubview(column)
    column.snp.makeConstraints { make in make.edges.equalToSuperview().inset(2).labeled("Pane.column") }
    for child in [header, contentHost] {
      child.snp.makeConstraints { make in make.leading.trailing.equalToSuperview() }
    }
    root.wantsLayer = true
    root.onHover = { [weak self] inside in
      self?.hovering = inside
      self?.updateChrome()
    }
    root.onLayout = { [weak self] in
      guard let self else { return }
      let compact = self.root.bounds.width < 420
      if self.subtitleLabel.isHidden != compact { self.subtitleLabel.isHidden = compact }
      let hideFiles = compact || self.terminalVC == nil
      if self.filesButton.isHidden != hideFiles { self.filesButton.isHidden = hideFiles }
    }
    root.onAppearance = { [weak self] in self?.updateChrome() }
    view = root
  }

  /// Starts a connection from outside the connect page (duplicate / open saved connection).
  func connect(_ config: ConnectionConfig, label: SessionLabel, restoration: ConnectionDraft? = nil) {
    lastConnection = restoration ?? label.profileID.flatMap { id in
      (try? profiles.profiles())?.first(where: { $0.id == id }).map(ConnectionDraft.init(profile:))
    } ?? ConnectionDraft(name: label.name, hostname: config.hostname, port: String(config.port), username: config.username,
                        authentication: config.auth.isPrivateKey ? .privateKey : .password)
    if let lastConnection { connectVC?.restore(lastConnection) }
    setLabel(label)
    let session = session
    Task { await session.connect(config, cols: 80, rows: 24) }
  }

  var restorationSnapshot: WorkspacePane {
    let draft = session.state.isActive ? lastConnection ?? connectVC?.connectionDraft
      : connectVC?.connectionDraft ?? lastConnection
    return WorkspacePane(id: id, connection: draft ?? ConnectionDraft())
  }

  func restore(_ draft: ConnectionDraft) {
    lastConnection = draft
    _ = view; showConnect(error: nil)
    connectVC?.restore(draft)
    let value = connectVC?.connectionDraft ?? draft
    if !value.name.isEmpty || !value.hostname.isEmpty {
      setLabel(SessionLabel(name: value.name.isEmpty ? "\(value.username)@\(value.hostname)" : value.name,
                            username: value.username, profileID: value.profileID))
    }
  }

  func prepareSavedConnection(_ id: UUID) {
    guard session.state == .idle else { return }
    _ = view
    showConnect(error: nil)
    connectVC?.selectProfile(id)
    connectVC?.showError("该连接缺少本机凭据，请补录后点「更新凭据」，再连接。")
    takeFocus()
  }

  func takeFocus() {
    guard isFocused, !closed, !view.isHiddenOrHasHiddenAncestor else { return }
    if let progressVC { progressVC.focusAction() }
    else if let terminalVC {
      terminalVC.focusTerminal()
    } else {
      connectVC?.focusFirstField()
    }
  }

  @discardableResult
  func insertSnippet(_ snippet: Snippet, parameters: [String: String] = [:]) -> Bool {
    guard terminalVC != nil, session.insertSnippet(snippet, parameters: parameters) else { return false }
    takeFocus()
    return true
  }

  /// Ends the session for good and releases its views; the window controller then drops the pane.
  func close() {
    closed = true
    stateObserver = nil
    appearanceObserver = nil
    session.disconnect()
    forwardWindow?.close()
    forwardWindow = nil
    progressWindow?.close(); progressWindow = nil
    hideProgress()
    tearDownTerminal()
    if let c = connectVC {
      unembed(c)
      connectVC = nil
    }
    view.removeFromSuperview()
  }

  func showLocalForwards() {
    guard !closed else { return }
    if forwardWindow == nil {
      let controller = LocalForwardViewController(model: session.portForwards)
      let window = NSWindow(contentViewController: controller)
      window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
      window.contentMinSize = NSSize(width: 600, height: 430)
      window.isReleasedWhenClosed = false
      window.isRestorable = false
      window.center()
      forwardWindow = NSWindowController(window: window)
    }
    forwardWindow?.window?.title = "端口转发 · \(label?.name ?? "新建连接")"
    forwardWindow?.showWindow(nil)
    forwardWindow?.window?.makeKeyAndOrderFront(nil)
  }

  func showConnectionLogs() {
    guard !closed, !session.connectionProgress.logs.isEmpty else { return }
    if progressWindow == nil {
      progressWindow = ConnectionProgressWindowController(session: session, serverName: label?.name ?? "服务器")
    }
    progressWindow?.showWindow(nil); progressWindow?.window?.makeKeyAndOrderFront(nil)
  }

  // MARK: - State → content

  private func apply(_ state: SessionManager.State) {
    guard !closed else { return }
    _ = view
    switch state {
    case .idle, .disconnected:
      hideProgress()
      showConnect(error: nil)
    case .failed:
      var message: String?
      if case .failed(let m) = state { message = m }
      showConnect(error: message)
      showProgress()
    case .connecting, .needsHostKeyConfirm, .reconnecting:
      if terminalVC == nil && connectVC == nil { showConnect(error: nil) }
      terminalVC?.apply(state)
      fileVC?.model.setConnected(false)
      showProgress()
    case .connected:
      hideProgress()
      showTerminal()
      terminalVC?.apply(state)
      fileVC?.model.setConnected(state == .connected)
    }
    updateChrome()
    changes.send()
  }

  private func setLabel(_ newLabel: SessionLabel) {
    label = newLabel
    progressVC?.setServerName(newLabel.name)
    progressWindow?.setServerName(newLabel.name)
    updateChrome()
    changes.send()
  }

  private func showConnect(error: String?) {
    tearDownTerminal()
    if connectVC == nil {
      let vc = ConnectViewController(session: session, profiles: profiles) { [weak self] label in
        self?.lastConnection = self?.connectVC?.connectionDraft
        self?.setLabel(label)
      }
      embed(vc)
      connectVC = vc
      vc.onDraftChange = { [weak self] in self?.changes.send() }
      if let lastConnection { vc.restore(lastConnection) }
      vc.isDefaultActionEnabled = isFocused
      // The page is created a runloop turn after render()'s takeFocus(), so focus it here.
      if isFocused { vc.focusFirstField() }
    }
    connectVC?.showError(error)
  }

  private func showTerminal() {
    guard terminalVC == nil else { return }
    if let c = connectVC {
      unembed(c)
      connectVC = nil
    }
    let vc = TerminalViewController(session: session)
    embed(vc)
    vc.applyAppearance(appearanceSettings)
    terminalVC = vc
    if isFocused {
      DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.takeFocus() } }
    }
  }

  private func showProgress() {
    guard dismissedProgressID != session.connectionProgress.attemptID else { return }
    if progressVC == nil {
      let controller = ConnectionProgressViewController(session: session, serverName: label?.name ?? "服务器")
      controller.onClose = { [weak self] in
        guard let self else { return }
        self.dismissedProgressID = self.session.connectionProgress.attemptID
        self.hideProgress(); self.updateChrome(); self.takeFocus()
      }
      addChild(controller); progressVC = controller
    }
    guard let progressVC else { return }
    unpinContent(progressVC.view)
    for child in contentHost.subviews { child.isHidden = true }
    pinContent(progressVC.view)
    connectVC?.isDefaultActionEnabled = false
    if isFocused { progressVC.focusAction() }
  }
  private func hideProgress() {
    if let progressVC { progressVC.shutdown(); unembed(progressVC) }
    progressVC = nil
    for child in contentHost.subviews { child.isHidden = false }
  }

  private func tearDownTerminal() {
    closeMonitor()
    closeFiles()
    toolsView?.removeFromSuperview(); toolsView = nil
    toolsScroll?.removeFromSuperview(); toolsScroll = nil
    if let terminalMonitorView { unpinContent(terminalMonitorView) }
    terminalMonitorView = nil
    isToolsVisible = false
    guard let t = terminalVC else { return }
    t.teardown()
    unembed(t)
    terminalVC = nil
  }

  @objc func toggleFiles() {
    guard progressVC == nil else { return }
    if fileVC != nil {
      closeFiles()
      if monitorVC != nil { toolsView?.select(.overview) } else { isToolsVisible = false }
      renderTerminalContent()
      takeFocus()
    } else {
      guard session.state == .connected, terminalVC != nil else { return }
      ensureFiles(); makeToolsView(); toolsView?.select(.files); isToolsVisible = true
      renderTerminalContent()
    }
    updateChrome()
  }

  private func closeFiles() {
    fileVC?.shutdown()
    if let fileVC { unembed(fileVC) }
    fileVC = nil
    toolsView?.setContents(overview: monitorVC?.view, files: nil)
  }

  @objc func toggleMonitor() {
    guard progressVC == nil else { return }
    if monitorVC != nil {
      closeMonitor()
      if fileVC != nil { toolsView?.select(.files) } else { isToolsVisible = false }
      renderTerminalContent(); takeFocus()
    }
    else {
      guard !closed, session.state == .connected, terminalVC != nil else { return }
      ensureMonitor(); makeToolsView(); toolsView?.select(.overview); isToolsVisible = true
      renderTerminalContent()
    }
    updateChrome()
  }

  private func closeMonitor() {
    monitorVC?.onRender = nil
    monitorVC?.shutdown()
    if let monitorVC { unembed(monitorVC) }
    monitorVC = nil
    toolsView?.setContents(overview: nil, files: fileVC?.view)
    toolsView?.updateSummary(from: nil)
  }

  @objc func toggleTools() {
    guard !closed, progressVC == nil, terminalVC != nil else { return }
    if isToolsVisible {
      isToolsVisible = false; renderTerminalContent(); updateChrome(); takeFocus()
    } else { selectTool(toolsView?.selectedTool ?? .overview) }
  }

  @objc private func showFilesTool() { selectTool(.files) }

  func selectTool(_ tool: SessionTool) {
    let connected = session.state == .connected
    let hasContent = tool == .overview ? monitorVC != nil : fileVC != nil
    guard !closed, progressVC == nil, terminalVC != nil, connected || hasContent else { return }
    // The first file page enables its status strip. Later file/collapse switches honor an
    // explicit monitor stop; opening Overview is the action that enables sampling again.
    if connected && (tool == .overview || toolsView == nil) { ensureMonitor() }
    if tool == .files && connected { ensureFiles() }
    makeToolsView(); toolsView?.select(tool); isToolsVisible = true
    renderTerminalContent(); updateChrome()
  }

  private func makeToolsView() {
    guard toolsView == nil else { return }
    let tools = SessionToolsView(frame: .zero)
    tools.onSelect = { [weak self] in self?.selectTool($0) }
    tools.onCollapse = { [weak self] in self?.toggleTools() }
    toolsView = tools; toolsScroll = SessionToolsScrollView(tools: tools)
  }

  private func ensureFiles() {
    guard fileVC == nil else { return }
    let session = session
    let files = FileBrowserViewController(model: FileBrowserModel { try await session.openSFTP() },
      serverName: label?.name ?? "服务器", usesCompactTabs: true)
    addChild(files); fileVC = files; files.start()
  }

  private func ensureMonitor() {
    guard monitorVC == nil else { return }
    let controller = ServerMonitorViewController(model: session.serverMonitor, serverName: label?.name ?? "服务器")
    controller.showsCompactHeader = true
    controller.onClose = { [weak self] in self?.toggleMonitor() }
    controller.onRender = { [weak self, weak controller] in self?.toolsView?.updateSummary(from: controller) }
    addChild(controller); monitorVC = controller; controller.start()
  }

  /// Tab switches update the inspector without re-parenting the terminal. Collapsing the
  /// inspector reclaims its space but leaves the child controllers and their tasks alive.
  private func renderTerminalContent() {
    guard let terminalVC else { return }
    toolsView?.setContents(overview: monitorVC?.view, files: fileVC?.view)
    toolsView?.updateSummary(from: monitorVC)
    if isToolsVisible, let toolsScroll {
      if terminalMonitorView == nil {
        unpinContent(terminalVC.view)
        let container = TerminalMonitorView(workspace: terminalVC.view, monitor: toolsScroll)
        terminalMonitorView = container; pinContent(container)
      }
      terminalMonitorView?.needsLayout = true
    } else {
      guard terminalMonitorView != nil || terminalVC.view.superview !== contentHost else { return }
      unpinContent(terminalVC.view); toolsScroll?.removeFromSuperview()
      if let terminalMonitorView { unpinContent(terminalMonitorView) }
      terminalMonitorView = nil
      pinContent(terminalVC.view)
    }
  }

  private func embed(_ child: NSViewController) {
    addChild(child)
    pinContent(child.view)
  }

  private func pinContent(_ v: NSView) {
    unpinContent(v)
    contentHost.addSubview(v)
    let constraints = v.snp.prepareConstraints { make in
      make.edges.equalToSuperview().labeled("Pane.content")
    }
    contentConstraints[ObjectIdentifier(v)] = constraints
    constraints.forEach { $0.activate() }
  }

  /// SnapKit keeps constraint references on a view after AppKit removes it. Release only
  /// this host's attachment constraints before moving a live terminal or overlay elsewhere.
  private func unpinContent(_ v: NSView) {
    contentConstraints.removeValue(forKey: ObjectIdentifier(v))?.forEach { $0.deactivate() }
    v.removeFromSuperview()
  }

  private func unembed(_ child: NSViewController) {
    unpinContent(child.view)
    child.removeFromParent()
  }

  // MARK: - Chrome

  private func updateChrome() {
    guard isViewLoaded else { return }
    header.isHidden = false
    titleLabel.stringValue = TabTitle.single(name: label?.name)
    titleLabel.toolTip = titleLabel.stringValue
    let endpoint = session.currentConfig.map { "\($0.username)@\($0.hostname):\($0.port)" }
    subtitleLabel.stringValue = session.state.displayText + (endpoint.map { " · \($0)" } ?? "")
    subtitleLabel.toolTip = subtitleLabel.stringValue
    subtitleLabel.isHidden = root.bounds.width < 420
    disconnectButton.isHidden = !session.state.isActive
    filesButton.isHidden = terminalVC == nil || root.bounds.width < 420
    filesButton.isEnabled = progressVC == nil && (session.state == .connected || fileVC != nil)
    filesButton.contentTintColor = isToolsVisible && toolsView?.selectedTool == .files ? .controlAccentColor : .labelColor
    filesButton.toolTip = "打开工具面板中的服务器文件（SFTP）"
    toolsButton.isHidden = terminalVC == nil
    toolsButton.isEnabled = progressVC == nil && (session.state == .connected || toolsView != nil)
    toolsButton.contentTintColor = isToolsVisible ? .controlAccentColor : .labelColor
    toolsButton.toolTip = isToolsVisible ? "收起工具，保留目录、传输和监控" : "展开服务器工具"
    let showTools = isInWorkspace
    detachButton.isHidden = !showTools
    maximizeButton.isHidden = !showTools
    closeButton.isHidden = !showTools
    maximizeButton.toolTip = isMaximized ? "还原" : "最大化"
    root.layer?.borderWidth = isInWorkspace ? (isFocused ? 2 : 1) : 0
    root.effectiveAppearance.performAsCurrentDrawingAppearance {
      root.layer?.borderColor = (isFocused ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
    }
    connectVC?.isDefaultActionEnabled = isFocused && progressVC == nil
  }

  @objc private func disconnectTapped() { session.disconnect() }
  @objc private func showPaneMenu() {
    let menu = NSMenu()
    let forwards = menu.addItem(withTitle: "端口转发…", action: #selector(openForwards), keyEquivalent: "")
    forwards.target = self
    let logs = menu.addItem(withTitle: "连接日志…", action: #selector(openLogs), keyEquivalent: "")
    logs.target = self; logs.isEnabled = !session.connectionProgress.logs.isEmpty
    if let snippets = actions?.snippetMenu?() {
      let item = NSMenuItem(title: "插入常用命令", action: nil, keyEquivalent: "")
      item.submenu = snippets; item.isEnabled = session.state == .connected; menu.addItem(item)
    }
    if let moveMenu = actions?.moveMenu?(id) {
      menu.addItem(.separator())
      let item = NSMenuItem(title: "移动会话到窗口", action: nil, keyEquivalent: "")
      item.submenu = moveMenu; menu.addItem(item)
    }
    menu.autoenablesItems = false
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: moreButton.bounds.maxY), in: moreButton)
  }
  @objc private func openForwards() { showLocalForwards() }
  @objc private func openLogs() { showConnectionLogs() }
  @objc private func detachTapped() { actions?.detach(id) }
  @objc private func maximizeTapped() { actions?.toggleMaximize(id) }
  @objc private func closeTapped() { actions?.close(id) }

  private static func iconButton(_ symbol: String, tip: String, target: AnyObject, action: Selector) -> NSButton {
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage()
    let button = NSButton(image: image, target: target, action: action)
    button.isBordered = false
    button.toolTip = tip
    button.setAccessibilityLabel(tip)
    button.snp.makeConstraints { make in make.size.equalTo(NSSize(width: 22, height: 24)) }
    return button
  }
}

private extension AuthMethod {
  var isPrivateKey: Bool { if case .privateKey = self { return true }; return false }
}

/// Pane root view: reports hover (for the header tool buttons); its layer draws the focus border.
final class PaneRootView: ChromeView {
  var onHover: ((Bool) -> Void)?
  var onLayout: (() -> Void)?
  var onAppearance: (() -> Void)?
  override func layout() { super.layout(); onLayout?() }
  override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); onAppearance?() }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas { removeTrackingArea(area) }
    addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                   owner: self, userInfo: nil))
  }

  override func mouseEntered(with event: NSEvent) { onHover?(true) }
  override func mouseExited(with event: NSEvent) { onHover?(false) }
}
