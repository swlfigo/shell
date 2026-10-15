import AppKit
import Combine
import TermesKit
import SSHCore

/// One system window: custom tab bar + pane container, driven by a `WindowLayout` model.
/// Every structural change goes through `layout`, then `render()` rebuilds what is visible.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, TabBarViewDelegate, PaneContainerDelegate {
  /// Runtime drag identity and persistent workspace identity have separate lifetimes.
  let token = UUID().uuidString
  let workspaceID: UUID
  weak var workspaceController: WorkspaceController?
  /// Called from `windowWillClose`; the app delegate drops its reference.
  var onClose: ((MainWindowController) -> Void)?
  var onChange: (() -> Void)?
  var onBecomeKey: (() -> Void)?
  private let services: AppServices
  private let runCloseAlert: @MainActor (NSAlert) -> NSApplication.ModalResponse
  private(set) var layout = WindowLayout()
  private var panes: [UUID: SessionPaneController] = [:]
  private var paneObservers: [UUID: AnyCancellable] = [:]
  private let tabBar: TabBarView
  private let container = PaneContainerView()
  let sidebar: ServerSidebarViewController
  let vaults: VaultsViewController
  private(set) var isShowingVaults = true
  private(set) var workspaceView: WorkspaceView?
  private var appearanceObserver: AnyCancellable?
  private var connectionEditorSheet: NSWindow?
  private var clickMonitor: Any?
  private(set) var snippetInvocation: SnippetInvocationViewController?
  private var snippetInvocationWindow: NSWindow?
  private var normalFrame: NSRect?
  private var isFullScreenTransition = false
  private var isClosing = false

  init(services: AppServices, restoring snapshot: WorkspaceWindow? = nil, empty: Bool = true,
       runCloseAlert: @escaping @MainActor (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() }) {
    self.services = services
    self.runCloseAlert = runCloseAlert
    workspaceID = snapshot?.id ?? UUID()
    let servers = ServerListModel(service: services.profiles)
    sidebar = ServerSidebarViewController(model: servers)
    vaults = VaultsViewController(services: services, model: servers)
    tabBar = TabBarView(windowToken: token)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 740),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.tabbingMode = .disallowed
    window.isReleasedWhenClosed = false
    // Our validated workspace file owns restoration rather than AppKit view archiving.
    window.isRestorable = false
    window.title = "Termes"
    super.init(window: window)
    window.delegate = self
    buildContent(in: window)
    appearanceObserver = services.appearance.$settings.sink { [weak self] settings in
      self?.window?.appearance = settings.theme.nativeAppearance
    }
    // SwiftTerm's first-responder hooks are not overridable, so pane focus follows clicks.
    clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
      MainActor.assumeIsolated { self?.focusPane(at: event) }
      return event
    }
    window.center()
    if let snapshot {
      layout = snapshot.layout
      isShowingVaults = snapshot.layout.tabs.isEmpty
      for saved in snapshot.panes {
        let pane = makePane(id: saved.id)
        pane.restore(saved.connection)
      }
      workspaceView?.restoreSidebar(visible: snapshot.sidebarVisible)
      if let frame = snapshot.frame {
        window.setFrame(Self.visibleFrame(NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)), display: false)
      }
      render()
    } else if !empty { addTab(makePane()) }
    else { render() }
    normalFrame = window.frame
  }
  required init?(coder: NSCoder) { fatalError("unsupported") }

  var activeSessionCount: Int { panes.values.filter { $0.session.state.isActive }.count }
  var unfinishedTransferCount: Int { panes.values.reduce(0) { $0 + $1.unfinishedTransferCount } }
  var activeForwardCount: Int { panes.values.reduce(0) { $0 + $1.activeForwardCount } }
  var focusedPane: SessionPaneController? {
    isShowingVaults ? nil : layout.selectedTab.flatMap { panes[$0.focusedPane] }
  }

  func disconnectAll() {
    for p in panes.values { p.session.disconnect() }
  }

  private func buildContent(in window: NSWindow) {
    tabBar.delegate = self
    container.delegate = self
    let root = WorkspaceView(sidebar: sidebar.view, tabBar: tabBar, container: container)
    root.installVaults(vaults.view)
    root.onShowVaults = { [weak self] in self?.showVaults(nil) }
    root.onToggleVaultsNavigation = { [weak self] in self?.vaults.toggleNavigation() }
    vaults.hosts.onOpen = { [weak self] id in self?.openSavedConnection(id: id) }
    vaults.hosts.onEdit = { [weak self] id in self?.editSavedConnection(id: id) }
    vaults.hosts.onNew = { [weak self] in self?.newTab(nil) }
    vaults.forwarding.onConnect = { [weak self] id in
      guard let self else { return }
      if let destination = try? self.services.profiles.forwardingDestination(for: id),
         let pane = self.panes.values.first(where: { $0.session.state == .connected && $0.session.currentConfig.map(LocalForwardDestination.init(config:)) == destination }),
         let tab = self.layout.tab(containing: pane.id) {
        self.layout.select(tab: tab.id); self.layout.focus(pane: pane.id)
        self.isShowingVaults = false; self.render()
      } else { self.openSavedConnection(id: id) }
    }
    vaults.forwarding.liveManager = { [weak self] destination in
      guard let self else { return nil }
      let matching = self.panes.values.filter { $0.session.portForwards.destination == destination }
      return (matching.first { $0.session.state == .connected } ?? matching.first)?.session.portForwards
    }
    sidebar.onOpen = { [weak self] id in self?.openSavedConnection(id: id) }
    sidebar.onEdit = { [weak self] id in self?.editSavedConnection(id: id) }
    sidebar.onNew = { [weak self] in self?.newTab(nil); self?.workspaceView?.dismissOverlay() }
    sidebar.onDismiss = { [weak self] in self?.workspaceView?.dismissOverlay(); self?.focusedPane?.takeFocus() }
    workspaceView = root
    window.contentView = root
    window.contentMinSize = LayoutMetrics.windowMin
  }

  // MARK: - Panes

  private func makePane(id: UUID = UUID()) -> SessionPaneController {
    let pane = SessionPaneController(session: services.makeSession(), profiles: services.profiles, appearance: services.appearance, id: id)
    adopt(pane)
    return pane
  }

  private func adopt(_ pane: SessionPaneController) {
    pane.actions = PaneActions(
      detach: { [weak self] id in self?.detachPane(id) },
      toggleMaximize: { [weak self] id in self?.toggleMaximize(id) },
      close: { [weak self] id in self?.requestClose(panes: [id]) })
    pane.actions?.snippetMenu = { [weak self] in self?.makeSnippetMenu() ?? NSMenu() }
    pane.actions?.moveMenu = { [weak self] id in self?.makeMoveMenu(pane: id) ?? NSMenu() }
    panes[pane.id] = pane
    paneObservers[pane.id] = pane.changes.sink { [weak self] in self?.refreshChrome(); self?.onChange?() }
  }

  private func addTab(_ pane: SessionPaneController, after tab: UUID? = nil) {
    isShowingVaults = false
    layout.addTab(pane: pane.id, after: tab)
    render()
  }

  private func detachPane(_ id: UUID) {
    guard layout.detach(pane: id) != nil else { return }
    render()
  }

  private func toggleMaximize(_ id: UUID) {
    layout.toggleMaximize(pane: id)
    render()
  }

  /// Confirms when any of the panes has an active session, then disconnects and removes them.
  /// Removing the last session returns to Vaults.
  func requestClose(panes ids: [UUID]) {
    let active = ids.compactMap { panes[$0] }.filter { $0.session.state.isActive }
    guard active.isEmpty || confirmClose(active) else { return }
    for id in ids {
      layout.close(pane: id)
      panes.removeValue(forKey: id)?.close()
      paneObservers[id] = nil
    }
    onChange?()
    if layout.tabs.isEmpty { isShowingVaults = true }
    render()
  }

  private func confirmClose(_ active: [SessionPaneController]) -> Bool {
    let alert = NSAlert()
    alert.messageText = active.count == 1
      ? "关闭后将断开与 \(active[0].label?.name ?? "该主机") 的连接"
      : "将断开 \(active.count) 个活动会话"
    alert.addButton(withTitle: "关闭")
    alert.addButton(withTitle: "取消")
    return runCloseAlert(alert) == .alertFirstButtonReturn
  }

  // MARK: - Rendering

  /// Clicking anywhere in a workspace pane focuses it.
  private func focusPane(at event: NSEvent) {
    guard !isShowingVaults, event.window === window, let tab = layout.selectedTab, tab.isWorkspace else { return }
    for id in tab.paneIds where id != tab.focusedPane {
      guard let v = panes[id]?.view, v.window != nil,
            v.bounds.contains(v.convert(event.locationInWindow, from: nil)) else { continue }
      layout.focus(pane: id)
      for (pid, pane) in panes { pane.isFocused = pid == id }
      refreshChrome()
      panes[id]?.takeFocus()
      onChange?()
      return
    }
  }

  /// Window minimum = max(480×320, tab bar + the visible tree's minimum); grows the window if needed.
  private func updateMinSize(for tab: Tab) {
    guard let window else { return }
    let node = tab.maximizedPane.map { PaneNode.pane($0) } ?? tab.root
    let m = node.minimumSize(pane: LayoutMetrics.paneMin, divider: LayoutMetrics.divider)
    workspaceView?.treeMinimumWidth = max(LayoutMetrics.windowMin.width, CGFloat(m.width))
    let minSize = NSSize(width: max(LayoutMetrics.windowMin.width, CGFloat(m.width)),
                         height: max(LayoutMetrics.windowMin.height, CGFloat(m.height) + LayoutMetrics.tabBarHeight))
    window.contentMinSize = minSize
    let content = window.contentRect(forFrameRect: window.frame)
    guard content.width < minSize.width || content.height < minSize.height else { return }
    let height = max(content.height, minSize.height)
    let grown = NSRect(x: content.minX, y: content.maxY - height,
                       width: max(content.width, minSize.width), height: height)
    window.setFrame(window.frameRect(forContentRect: grown), display: true)
  }

  private func render() {
    if isShowingVaults || layout.tabs.isEmpty {
      isShowingVaults = true
      workspaceView?.isShowingVaults = true
      workspaceView?.treeMinimumWidth = LayoutMetrics.windowMin.width
      window?.contentMinSize = LayoutMetrics.windowMin
      for pane in panes.values { pane.isFocused = false }
      refreshChrome(); onChange?(); return
    }
    workspaceView?.isShowingVaults = false
    guard let tab = layout.selectedTab else { container.clear(); refreshChrome(); onChange?(); return }
    var views: [UUID: NSView] = [:]
    for id in tab.paneIds { views[id] = panes[id]?.view }
    container.render(root: tab.root, maximized: tab.maximizedPane, views: views)
    updateMinSize(for: tab)
    for (id, pane) in panes {
      let owner = layout.tab(containing: id)
      pane.isInWorkspace = owner?.isWorkspace ?? false
      pane.isMaximized = owner?.maximizedPane == id
      pane.isFocused = id == tab.focusedPane
    }
    refreshChrome()
    panes[tab.focusedPane]?.takeFocus()
    onChange?()
  }

  private func refreshChrome() {
    let items = layout.tabs.map { tab in
      TabBarItem(
        id: tab.id,
        title: tab.isWorkspace
          ? TabTitle.workspace(paneCount: tab.paneIds.count)
          : TabTitle.single(name: panes[tab.focusedPane]?.label?.name),
        status: TabTitle.aggregate(tab.paneIds.compactMap { panes[$0]?.session.state.status }))
    }
    tabBar.update(items: items, selected: isShowingVaults ? nil : layout.selectedTabId)
    window?.title = isShowingVaults ? "Termes · Vaults" : items.first { $0.id == layout.selectedTabId }?.title ?? "Termes"
    sidebar.model.updateSessions(panes.values.compactMap { pane in
      pane.label?.profileID.map { ServerSessionInfo(profileID: $0, state: pane.session.state,
        destination: pane.session.currentConfig.map(LocalForwardDestination.init(config:))) }
    })
  }

  // MARK: - Menu actions (nil-targeted items reach the key window's controller)

  /// ⌘D: same config, new tab right after the current one, connected immediately.
  @objc func duplicateSession(_ sender: Any?) {
    guard !isShowingVaults, let tab = layout.selectedTab, let source = panes[tab.focusedPane], source.session.state.isActive,
          let config = source.session.currentConfig else { return }
    let label = source.label
      ?? SessionLabel(name: "\(config.username)@\(config.hostname)", username: config.username)
    let pane = makePane()
    addTab(pane, after: tab.id)
    pane.connect(config, label: label, restoration: source.restorationSnapshot.connection)
  }

  /// 连接 → 打开已存连接: connects in the current tab if it is a never-connected single pane,
  /// otherwise in a new tab after it.
  @objc func openSavedConnection(_ sender: NSMenuItem) {
    guard let profileId = sender.representedObject as? UUID else { return }
    openSavedConnection(id: profileId)
  }

  func openSavedConnection(id profileId: UUID) {
    let config: ConnectionConfig
    let profile: ConnectionProfile
    do {
      guard let saved = try services.profiles.profiles().first(where: { $0.id == profileId }) else { throw ProfileServiceError.profileNotFound }
      profile = saved
      config = try services.profiles.makeConfig(for: profileId)
    } catch {
      if (error as? ProfileServiceError) == .credentialMissing {
        let target = savedConnectionTarget()
        target.prepareSavedConnection(profileId)
        workspaceView?.dismissOverlay()
        return
      }
      let alert = NSAlert()
      alert.messageText = error.localizedDescription
      alert.runModal()
      return
    }
    let label = SessionLabel(name: profile.name, username: config.username, profileID: profileId)
    let target = savedConnectionTarget()
    workspaceView?.dismissOverlay()
    target.connect(config, label: label)
  }

  private func savedConnectionTarget() -> SessionPaneController {
    let target: SessionPaneController
    if !isShowingVaults, let tab = layout.selectedTab, !tab.isWorkspace, let current = panes[tab.focusedPane],
       current.session.state == .idle {
      target = current
    } else {
      target = makePane()
      addTab(target, after: layout.selectedTabId)
    }
    return target
  }

  func editSavedConnection(id: UUID) {
    guard connectionEditorSheet == nil, let window else { return }
    do {
      guard let profile = try services.profiles.profiles().first(where: { $0.id == id }) else { throw ProfileServiceError.profileNotFound }
      let controller = ConnectionEditorViewController(profile: profile, profiles: services.profiles) { [weak self] in
        guard let self, let sheet = self.connectionEditorSheet else { return }
        self.window?.endSheet(sheet)
      }
      let sheet = NSWindow(contentViewController: controller)
      sheet.title = "编辑服务器信息"; sheet.styleMask = [.titled]; sheet.isRestorable = false
      connectionEditorSheet = sheet
      window.beginSheet(sheet) { [weak self] _ in self?.connectionEditorSheet = nil }
    } catch { NSAlert(error: error).runModal() }
  }

  @objc func toggleSidebar(_ sender: Any?) {
    if isShowingVaults { vaults.toggleNavigation(); return }
    let focusedSearch = sidebar.searchField.currentEditor() === window?.firstResponder
    let focusedTable = window?.firstResponder === sidebar.table
    workspaceView?.toggleSidebar()
    if sidebar.view.isHidden && (focusedSearch || focusedTable) { focusedPane?.takeFocus() }
  }
  @objc func searchServers(_ sender: Any?) {
    if isShowingVaults { vaults.focusSearch() }
    else { workspaceView?.revealSidebar(); sidebar.focusSearch() }
  }

  @objc func showVaults(_ sender: Any?) {
    window?.makeFirstResponder(nil)
    isShowingVaults = true
    vaults.forwarding.refresh()
    render()
  }

  private func makeSnippetMenu() -> NSMenu {
    let menu = NSMenu()
    do {
      var groups: [String: NSMenu] = [:]
      for snippet in try services.snippets.all() {
        let target: NSMenu
        if snippet.group.isEmpty { target = menu }
        else if let existing = groups[snippet.group] { target = existing }
        else {
          let group = NSMenu(title: snippet.group)
          let item = NSMenuItem(title: snippet.group, action: nil, keyEquivalent: "")
          item.submenu = group; menu.addItem(item); groups[snippet.group] = group; target = group
        }
        let item = NSMenuItem(title: snippet.name, action: #selector(insertSnippet(_:)), keyEquivalent: "")
        item.target = self; item.representedObject = snippet.id; item.toolTip = snippet.command
        target.addItem(item)
      }
      if menu.items.isEmpty {
        let item = NSMenuItem(title: "还没有常用命令", action: nil, keyEquivalent: ""); item.isEnabled = false; menu.addItem(item)
      }
    } catch {
      let item = NSMenuItem(title: "读取失败，请打开常用命令管理", action: nil, keyEquivalent: ""); item.isEnabled = false; menu.addItem(item)
    }
    return menu
  }

  @objc func newTab(_ sender: Any?) { addTab(makePane(), after: layout.selectedTabId) }

  @objc func manageLocalForwards(_ sender: Any?) {
    if isShowingVaults { vaults.select(.portForwarding) }
    else { focusedPane?.showLocalForwards() }
  }
  @objc func toggleSessionTools(_ sender: Any?) { focusedPane?.toggleTools() }
  @objc func toggleServerMonitor(_ sender: Any?) { focusedPane?.toggleMonitor() }
  @objc func showConnectionLogs(_ sender: Any?) { focusedPane?.showConnectionLogs() }

  /// Resolve the latest saved text and the currently focused pane at click time.
  @objc func insertSnippet(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? UUID,
          let pane = focusedPane,
          pane.session.state == .connected else { return }
    do {
      guard let snippet = try services.snippets.all().first(where: { $0.id == id }) else { return }
      if snippet.needsPreview { showSnippetPreview(snippet, pane: pane) }
      else { pane.insertSnippet(snippet) }
    } catch { NSAlert(error: error).runModal() }
  }

  private func showSnippetPreview(_ snippet: Snippet, pane: SessionPaneController) {
    guard snippetInvocation == nil, let window else { return }
    let version = pane.session.connectionVersion
    let page = SnippetInvocationViewController(snippet: snippet, destination: pane.label?.name ?? "当前服务器")
    page.onInsert = { [weak self, weak pane] parameters in
      guard let self, let pane, self.panes[pane.id] === pane,
            self.focusedPane === pane, pane.session.state == .connected,
            pane.session.connectionVersion == version else {
        throw SnippetInvocationError.sessionChanged
      }
      guard let current = try self.services.snippets.all().first(where: { $0.id == snippet.id }) else {
        throw SnippetError.notFound
      }
      guard current == snippet else { throw SnippetInvocationError.snippetChanged }
      guard pane.insertSnippet(snippet, parameters: parameters) else { throw SnippetInvocationError.sessionChanged }
    }
    page.onDismiss = { [weak self] in self?.dismissSnippetPreview() }
    let sheet = NSWindow(contentViewController: page)
    sheet.styleMask = [.titled, .resizable]
    sheet.title = "预览常用命令"
    sheet.contentMinSize = NSSize(width: 560, height: 500)
    sheet.isReleasedWhenClosed = false; sheet.isRestorable = false
    snippetInvocation = page; snippetInvocationWindow = sheet
    window.beginSheet(sheet)
  }

  private func dismissSnippetPreview() {
    if let sheet = snippetInvocationWindow {
      window?.endSheet(sheet)
      sheet.orderOut(nil)
    }
    snippetInvocation = nil; snippetInvocationWindow = nil
  }

  @objc func closeFocusedPane(_ sender: Any?) {
    if isShowingVaults { window?.performClose(sender); return }
    guard let focused = layout.selectedTab?.focusedPane else { return }
    requestClose(panes: [focused])
  }

  @objc func selectNextTab(_ sender: Any?) {
    if isShowingVaults { layout.selectTab(at: 0) } else { layout.selectNext() }
    isShowingVaults = false
    render()
  }

  @objc func selectPreviousTab(_ sender: Any?) {
    if isShowingVaults { layout.selectTab(at: layout.tabs.count - 1) } else { layout.selectPrevious() }
    isShowingVaults = false
    render()
  }

  @objc func selectTabByNumber(_ sender: NSMenuItem) {
    layout.selectTab(at: sender.tag)
    isShowingVaults = false
    render()
  }

  // MARK: - TabBarViewDelegate

  func tabBar(_ bar: TabBarView, select id: UUID) {
    layout.select(tab: id)
    isShowingVaults = false
    render()
  }

  func tabBar(_ bar: TabBarView, close id: UUID) {
    guard let tab = layout.tabs.first(where: { $0.id == id }) else { return }
    requestClose(panes: tab.paneIds)
  }

  func tabBarAddTab(_ bar: TabBarView) { newTab(nil) }

  func tabBar(_ bar: TabBarView, move id: UUID, to index: Int) {
    layout.moveTab(id, to: index)
    refreshChrome()
    onChange?()
  }

  func tabBar(_ bar: TabBarView, canAccept payload: TabDragPayload) -> Bool {
    if payload.windowToken == token { return layout.tabs.contains { $0.id == payload.tabId } }
    return workspaceController?.canMove(payload, to: self) == true
  }

  func tabBar(_ bar: TabBarView, drop payload: TabDragPayload, at index: Int) -> Bool {
    if payload.windowToken == token {
      guard layout.tabs.contains(where: { $0.id == payload.tabId }) else { return false }
      tabBar(bar, move: payload.tabId, to: index); return true
    }
    return workspaceController?.moveTab(payload, to: self, at: index) == true
  }

  func tabBar(_ bar: TabBarView, dragEnded payload: TabDragPayload, at point: NSPoint) {
    workspaceController?.tearOff(payload, at: point)
  }

  func tabBar(_ bar: TabBarView, menuFor id: UUID) -> NSMenu? {
    let menu = NSMenu()
    let move = NSMenuItem(title: "移动标签到窗口", action: nil, keyEquivalent: "")
    move.submenu = makeMoveMenu(tab: id); menu.addItem(move)
    return menu
  }

  // MARK: - PaneContainerDelegate

  func paneContainer(_ c: PaneContainerView, didResizeSplit id: UUID, fractions: [Double]) {
    layout.setFractions(fractions, split: id)
    onChange?()
  }

  func paneContainer(_ c: PaneContainerView, canAccept payload: TabDragPayload) -> Bool {
    if payload.windowToken != token { return workspaceController?.canMerge(payload, to: self) == true }
    guard payload.tabId != layout.selectedTabId,
          let tab = layout.tabs.first(where: { $0.id == payload.tabId }) else { return false }
    return !tab.isWorkspace
  }

  func paneContainer(_ c: PaneContainerView, drop payload: TabDragPayload, onto pane: UUID, edge: PaneEdge) {
    _ = paneContainer(c, performDrop: payload, onto: pane, edge: edge)
  }

  func paneContainer(_ c: PaneContainerView, performDrop payload: TabDragPayload, onto pane: UUID, edge: PaneEdge) -> Bool {
    guard paneContainer(c, canAccept: payload) else { return false }
    if payload.windowToken != token { return workspaceController?.mergeTab(payload, to: self, pane: pane, edge: edge) == true }
    guard layout.merge(tab: payload.tabId, into: pane, edge: edge) else { return false }
    render(); return true
  }

  // MARK: - NSWindowDelegate

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard sender.attachedSheet == nil else { return false }
    hideInBackground()
    onChange?()
    return false // Red close hides the window; explicit tab-close and app-quit end sessions.
  }

  func hideInBackground() { window?.orderOut(nil) }

  func restoreFromBackground() {
    guard !isClosing, let window else { return }
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
    focusedPane?.takeFocus()
  }

  func windowWillClose(_ notification: Notification) {
    isClosing = true
    snippetInvocation?.cancel()
    dismissSnippetPreview()
    if let monitor = clickMonitor {
      NSEvent.removeMonitor(monitor)
      clickMonitor = nil
    }
    for p in panes.values { p.close() }
    panes.removeAll()
    paneObservers.removeAll()
    appearanceObserver = nil
    onClose?(self)
  }

  func windowDidBecomeKey(_ notification: Notification) { onBecomeKey?() }
  func windowDidMove(_ notification: Notification) { recordNormalFrame() }
  func windowDidResize(_ notification: Notification) { recordNormalFrame() }
  func windowWillEnterFullScreen(_ notification: Notification) { normalFrame = window?.frame; isFullScreenTransition = true }
  func windowDidEnterFullScreen(_ notification: Notification) { isFullScreenTransition = false }
  func windowWillExitFullScreen(_ notification: Notification) { isFullScreenTransition = true }
  func windowDidExitFullScreen(_ notification: Notification) { isFullScreenTransition = false; recordNormalFrame() }
  func windowDidFailToEnterFullScreen(_ window: NSWindow) { isFullScreenTransition = false; recordNormalFrame() }
  func windowDidFailToExitFullScreen(_ window: NSWindow) { isFullScreenTransition = false }

  private func recordNormalFrame() {
    if !isFullScreenTransition && window?.styleMask.contains(.fullScreen) == false { normalFrame = window?.frame }
    if !isClosing { onChange?() }
  }

  var restorationSnapshot: WorkspaceWindow {
    let rect = normalFrame ?? window?.frame
    return WorkspaceWindow(id: workspaceID, layout: layout,
      panes: layout.allPaneIds.compactMap { panes[$0]?.restorationSnapshot },
      frame: rect.map { WorkspaceFrame(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height) },
      sidebarVisible: workspaceView?.sidebarPreferredVisible ?? true)
  }

  func pane(id: UUID) -> SessionPaneController? { panes[id] }
  var canTransfer: Bool { !isClosing && window?.attachedSheet == nil }

  /// All preflight checks happen before this synchronous ownership transaction.
  func release(_ ids: [UUID], layout next: WindowLayout) -> [SessionPaneController] {
    window?.makeFirstResponder(nil)
    let moving = ids.compactMap { panes.removeValue(forKey: $0) }
    for pane in moving { paneObservers[pane.id] = nil; pane.actions = nil; pane.isFocused = false }
    layout = next
    // Unmount the old container before the destination mounts the same live views.
    render()
    return moving
  }

  func receive(_ moving: [SessionPaneController], layout next: WindowLayout) {
    for pane in moving { adopt(pane) }
    isShowingVaults = false
    layout = next; render()
  }

  func finishTransfer() {
    if layout.tabs.isEmpty { window?.close() }
  }

  private struct MoveRequest { let pane: UUID?; let tab: UUID?; let windowToken: String? }

  func makeMoveMenu(pane: UUID? = nil, tab: UUID? = nil) -> NSMenu {
    let menu = NSMenu(title: "移动到窗口")
    menu.autoenablesItems = false
    let new = menu.addItem(withTitle: "新窗口", action: #selector(moveToWindow(_:)), keyEquivalent: "")
    new.target = self; new.representedObject = MoveRequest(pane: pane, tab: tab, windowToken: nil)
    new.isEnabled = canTransfer && workspaceController != nil
    for (index, destination) in (workspaceController?.windows ?? []).enumerated() where destination !== self {
      let item = menu.addItem(withTitle: "窗口 \(index + 1) · \(destination.window?.title ?? "Termes")", action: #selector(moveToWindow(_:)), keyEquivalent: "")
      item.target = self; item.representedObject = MoveRequest(pane: pane, tab: tab, windowToken: destination.token)
      item.isEnabled = canTransfer && destination.canTransfer
    }
    return menu
  }

  @objc private func moveToWindow(_ sender: NSMenuItem) {
    guard let request = sender.representedObject as? MoveRequest, let workspaceController else { return }
    workspaceController.move(from: self, pane: request.pane, tab: request.tab, to: request.windowToken)
  }

  @objc func moveCurrentTabToNewWindow(_ sender: Any?) {
    guard !isShowingVaults else { return }
    workspaceController?.move(from: self, pane: nil, tab: layout.selectedTabId, to: nil)
  }

  static func visibleFrame(_ frame: NSRect) -> NSRect {
    let screens = NSScreen.screens.map(\.visibleFrame)
    guard let screen = screens.max(by: { $0.intersection(frame).width * $0.intersection(frame).height < $1.intersection(frame).width * $1.intersection(frame).height }) else { return frame }
    let size = NSSize(width: min(max(frame.width, LayoutMetrics.windowMin.width), screen.width),
                      height: min(max(frame.height, LayoutMetrics.windowMin.height), screen.height))
    return NSRect(x: min(max(frame.minX, screen.minX), screen.maxX - size.width),
                  y: min(max(frame.minY, screen.minY), screen.maxY - size.height), width: size.width, height: size.height)
  }
}

extension MainWindowController: NSMenuItemValidation {
  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    switch item.action {
    case #selector(moveCurrentTabToNewWindow(_:)):
      return !isShowingVaults && workspaceController != nil && canTransfer && layout.selectedTab != nil
    case #selector(toggleSidebar(_:)):
      item.state = sidebar.view.isHidden ? .off : .on
      return true
    case #selector(showConnectionLogs(_:)):
      return !(focusedPane?.session.connectionProgress.logs.isEmpty ?? true)
    case #selector(toggleServerMonitor(_:)):
      item.state = focusedPane?.monitorVC != nil ? .on : .off
      return focusedPane?.progressVC == nil && (focusedPane?.session.state == .connected || focusedPane?.monitorVC != nil)
    case #selector(toggleSessionTools(_:)):
      item.state = focusedPane?.isToolsVisible == true ? .on : .off
      return focusedPane?.progressVC == nil && (focusedPane?.session.state == .connected || focusedPane?.toolsView != nil)
    case #selector(insertSnippet(_:)):
      return focusedPane?.session.state == .connected
    case #selector(duplicateSession(_:)):
      guard !isShowingVaults, let focused = layout.selectedTab?.focusedPane, let session = panes[focused]?.session else { return false }
      return session.state.isActive && session.currentConfig != nil
    case #selector(selectTabByNumber(_:)):
      return item.tag < layout.tabs.count
    default:
      return true
    }
  }
}

enum SnippetInvocationError: LocalizedError {
  case sessionChanged, snippetChanged
  var errorDescription: String? {
    switch self {
    case .sessionChanged: return "目标会话或焦点已变化，请取消并在需要的终端重新选择命令。"
    case .snippetChanged: return "该常用命令已在其他窗口修改，请取消并重新选择以核对最新内容。"
    }
  }
}
