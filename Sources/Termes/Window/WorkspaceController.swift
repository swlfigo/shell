import AppKit
import TermesKit

/// Owns all main windows, workspace persistence, and atomic transfers of live panes.
@MainActor
final class WorkspaceController {
  private let services: AppServices
  private(set) var windows: [MainWindowController] = []
  private(set) var selectedWindowID: UUID?
  private var pendingSave: Task<Void, Never>?
  private var isUpdating = false
  private var isTerminating = false
  private var processActivity: WorkspaceProcessActivity?
  var onSaveError: ((String) -> Void)?
  private var reportedError: String?

  init(services: AppServices) { self.services = services }

  func restore(showWindows: Bool = true) {
    guard windows.isEmpty else { return }
    isUpdating = true
    if let snapshot = services.workspace.snapshot, !snapshot.windows.isEmpty {
      for saved in snapshot.windows {
        let window = openWindow(restoring: saved, show: false)
        window.showVaults(nil)
        if showWindows { window.showWindow(nil) }
      }
      selectedWindowID = snapshot.selectedWindowID ?? windows.first?.workspaceID
      if showWindows { windows.first { $0.workspaceID == selectedWindowID }?.window?.makeKeyAndOrderFront(nil) }
    } else { _ = openWindow(show: showWindows) }
    isUpdating = false
  }

  @discardableResult
  func openWindow(restoring saved: WorkspaceWindow? = nil, empty: Bool = true, show: Bool = true) -> MainWindowController {
    let controller = MainWindowController(services: services, restoring: saved, empty: empty)
    controller.workspaceController = self
    controller.onChange = { [weak self] in
      self?.refreshProcessActivity(); self?.scheduleSave()
    }
    controller.workspaceView?.onSidebarChange = { [weak self] in self?.scheduleSave() }
    controller.onBecomeKey = { [weak self, weak controller] in
      guard let self, let controller else { return }
      self.selectedWindowID = controller.workspaceID; self.scheduleSave()
    }
    controller.onClose = { [weak self] closed in
      guard let self else { return }
      self.windows.removeAll { $0 === closed }
      if self.selectedWindowID == closed.workspaceID { self.selectedWindowID = self.windows.last?.workspaceID }
      self.refreshProcessActivity()
      // Actual disposal removes this window from the restore set; hiding keeps it intact.
      if !self.isUpdating && !self.isTerminating { _ = self.saveNow() }
    }
    if saved == nil, let key = NSApp.keyWindow, let window = controller.window {
      window.setFrameTopLeftPoint(NSPoint(x: key.frame.minX + 24, y: key.frame.maxY - 24))
    }
    windows.append(controller); selectedWindowID = controller.workspaceID
    if show { controller.showWindow(nil) }
    scheduleSave()
    return controller
  }

  /// Ordering windows out leaves their controllers, sessions, transfers and tools alive.
  func runInBackground() {
    for window in windows { window.hideInBackground() }
    refreshProcessActivity()
    _ = saveNow(reportError: false)
  }

  func reopenWindows() {
    guard !isTerminating else { return }
    guard !windows.isEmpty else { openWindow(); return }
    let selected = windows.first { $0.workspaceID == selectedWindowID } ?? windows.last
    for controller in windows where controller.window?.isVisible != true || controller.window?.isMiniaturized == true {
      controller.restoreFromBackground()
    }
    selected?.restoreFromBackground()
  }

  private func refreshProcessActivity() {
    if !isTerminating && windows.contains(where: { $0.activeSessionCount > 0 }) {
      if processActivity == nil { processActivity = WorkspaceProcessActivity() }
    } else { processActivity = nil }
  }

  var snapshot: WorkspaceSnapshot {
    let saved = windows.map(\.restorationSnapshot)
    return WorkspaceSnapshot(windows: saved,
      selectedWindowID: saved.contains { $0.id == selectedWindowID } ? selectedWindowID : saved.last?.id)
  }

  private func scheduleSave() {
    guard !isUpdating, !isTerminating else { return }
    pendingSave?.cancel()
    pendingSave = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
      _ = self?.saveNow()
    }
  }

  @discardableResult
  func saveNow(reportError: Bool = true) -> Bool {
    pendingSave?.cancel(); pendingSave = nil
    do {
      try services.workspace.save(snapshot)
      reportedError = nil; return true
    } catch {
      let message = services.workspace.error ?? error.localizedDescription
      if reportError && reportedError != message { reportedError = message; onSaveError?(message) }
      return false
    }
  }

  func prepareToTerminate(save: Bool = true) {
    if save { _ = saveNow(reportError: false) }
    isTerminating = true
    processActivity = nil
    for window in windows { window.disconnectAll() }
  }

  private func source(of payload: TabDragPayload) -> MainWindowController? {
    windows.first { $0.token == payload.windowToken && $0.layout.tabs.contains { $0.id == payload.tabId } }
  }

  func canMove(_ payload: TabDragPayload, to destination: MainWindowController) -> Bool {
    guard let source = source(of: payload), source !== destination,
          windows.contains(where: { $0 === destination }), source.canTransfer, destination.canTransfer else { return false }
    return true
  }

  func canMerge(_ payload: TabDragPayload, to destination: MainWindowController) -> Bool {
    guard !destination.isShowingVaults, canMove(payload, to: destination), let source = source(of: payload),
          let tab = source.layout.tabs.first(where: { $0.id == payload.tabId }) else { return false }
    return !tab.isWorkspace
  }

  @discardableResult
  func moveTab(_ payload: TabDragPayload, to destination: MainWindowController, at index: Int) -> Bool {
    guard canMove(payload, to: destination), let source = source(of: payload) else { return false }
    var from = source.layout, to = destination.layout
    guard let tab = from.takeTab(payload.tabId), to.insertTab(tab, at: index) else { return false }
    return transfer(tab.paneIds, from: source, layout: from, to: destination, layout: to)
  }

  @discardableResult
  func mergeTab(_ payload: TabDragPayload, to destination: MainWindowController, pane: UUID, edge: PaneEdge) -> Bool {
    guard canMerge(payload, to: destination), let source = source(of: payload),
          destination.layout.selectedTab?.paneIds.contains(pane) == true else { return false }
    var from = source.layout, to = destination.layout
    guard let tab = from.takeTab(payload.tabId), to.insertTab(tab, at: to.tabs.count),
          to.merge(tab: tab.id, into: pane, edge: edge) else { return false }
    return transfer(tab.paneIds, from: source, layout: from, to: destination, layout: to)
  }

  /// Menu moves can extract one pane or keep an entire workspace tree intact.
  @discardableResult
  func move(from source: MainWindowController, pane: UUID?, tab: UUID?, to token: String?, show: Bool = true) -> Bool {
    guard windows.contains(where: { $0 === source }), source.canTransfer else { return false }
    var from = source.layout
    let moving = pane.flatMap { from.takePane($0) } ?? (pane == nil ? tab.flatMap { from.takeTab($0) } : nil)
    guard let moving, moving.paneIds.allSatisfy({ source.pane(id: $0) != nil }) else { return false }
    let destination: MainWindowController
    if let token {
      guard let found = windows.first(where: { $0.token == token }), found !== source, found.canTransfer else { return false }
      destination = found
    } else {
      isUpdating = true
      destination = openWindow(empty: true, show: false)
      isUpdating = false
    }
    var to = destination.layout
    guard to.insertTab(moving, at: to.tabs.count) else { return false }
    let success = transfer(moving.paneIds, from: source, layout: from, to: destination, layout: to, show: show)
    if !success && token == nil { destination.window?.close() }
    return success
  }

  private func transfer(_ ids: [UUID], from source: MainWindowController, layout from: WindowLayout,
                        to destination: MainWindowController, layout to: WindowLayout, show: Bool = true) -> Bool {
    guard ids.allSatisfy({ source.pane(id: $0) != nil && destination.pane(id: $0) == nil }) else { return false }
    isUpdating = true
    let moving = source.release(ids, layout: from)
    destination.receive(moving, layout: to)
    selectedWindowID = destination.workspaceID
    if show { destination.showWindow(nil); destination.window?.makeKeyAndOrderFront(nil) }
    destination.focusedPane?.takeFocus()
    source.finishTransfer()
    isUpdating = false
    _ = saveNow()
    return true
  }

  func tearOff(_ payload: TabDragPayload, at point: NSPoint, show: Bool = true) {
    guard let source = source(of: payload), source.canTransfer else { return }
    // A rejected drop inside an app window is a cancellation, not a new window request.
    guard !NSApp.windows.contains(where: { $0.isVisible && $0.frame.contains(point) }) else { return }
    guard move(from: source, pane: nil, tab: payload.tabId, to: nil, show: show), let destination = windows.last else { return }
    if let window = destination.window {
      let frame = NSRect(x: point.x - window.frame.width / 2, y: point.y - window.frame.height + 20,
                         width: window.frame.width, height: window.frame.height)
      window.setFrame(MainWindowController.visibleFrame(frame), display: show)
      _ = saveNow()
    }
  }
}

/// Keep active SSH work eligible to run while hidden or minimized, without preventing sleep.
private final class WorkspaceProcessActivity {
  private let token = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
    reason: "保持 SSH 会话、文件传输和端口转发运行")
  deinit { ProcessInfo.processInfo.endActivity(token) }
}
