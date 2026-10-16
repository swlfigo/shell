import AppKit
import Darwin
import CryptoKit
import XCTest
import SSHCore
import TermesKit
import SwiftTerm
@testable import Termes

@MainActor
private final class WorkspaceTabDrag: NSObject, NSDraggingInfo {
  let draggingPasteboard: NSPasteboard
  var draggingDestinationWindow: NSWindow?
  var draggingSourceOperationMask: NSDragOperation = .move
  var draggingLocation: NSPoint = .zero
  var draggedImageLocation: NSPoint { .zero }
  nonisolated var draggedImage: NSImage? { nil }
  var draggingSource: Any? { nil }
  var draggingSequenceNumber: Int { 1 }
  var draggingFormation: NSDraggingFormation = .default
  var animatesToDestination = false
  var numberOfValidItemsForDrop = 0
  var springLoadingHighlight: NSSpringLoadingHighlight { .none }
  init(_ payload: TabDragPayload, window: NSWindow?, point: NSPoint = .zero) {
    draggingPasteboard = NSPasteboard.withUniqueName()
    draggingPasteboard.setString(payload.encoded, forType: .termesTab)
    draggingDestinationWindow = window; draggingLocation = point
  }
  func slideDraggedImage(to screenPoint: NSPoint) {}
  nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
  func resetSpringLoading() {}
  func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?, classes: [AnyClass],
    searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

@MainActor
final class WorkspaceTransferTests: XCTestCase {
  private func fixture() throws -> (AppServices, WorkspaceController) {
    _ = NSApplication.shared
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("termes-transfer-\(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    let services = AppServices(directory: dir, secrets: InMemorySecretStore())
    return (services, WorkspaceController(services: services))
  }
  private func close(_ workspace: WorkspaceController) {
    workspace.prepareToTerminate()
    for window in workspace.windows { window.close() }
  }
  private func availablePort() throws -> Int {
    let socket = try ForwardTestSocket.listener()
    defer { Darwin.close(socket) }
    return try ForwardTestSocket.boundPort(socket).port
  }
  private func wait(_ predicate: () -> Bool, timeout: TimeInterval = 30,
    file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(15)) }
    guard predicate() else { XCTFail("timed out", file: file, line: line); throw CancellationError() }
  }

  func test_actual_tab_drop_transfers_ownership_and_closes_empty_source_without_closing_pane() throws {
    let (_, workspace) = try fixture(); defer { close(workspace) }
    let source = workspace.openWindow(empty: false, show: false), destination = workspace.openWindow(empty: false, show: false)
    let pane = try XCTUnwrap(source.focusedPane)
    pane.restore(.init(name: "未保存", hostname: "draft.test", username: "root"))
    let view = pane.view, session = pane.session, tab = try XCTUnwrap(source.layout.selectedTab)
    let bar = try XCTUnwrap(destination.workspaceView?.tabBar)
    let drag = WorkspaceTabDrag(.init(windowToken: source.token, tabId: tab.id), window: destination.window)
    XCTAssertEqual(bar.draggingEntered(drag), .move)
    XCTAssertTrue(bar.performDragOperation(drag))
    XCTAssertEqual(workspace.windows.count, 1); XCTAssertTrue(workspace.windows.first === destination)
    XCTAssertTrue(destination.focusedPane === pane); XCTAssertTrue(pane.view === view); XCTAssertTrue(pane.session === session)
    XCTAssertEqual(pane.session.state, .idle); XCTAssertTrue(pane.view.window === destination.window)
    XCTAssertEqual(destination.layout.tabs.first?.id, tab.id)
    XCTAssertFalse(bar.performDragOperation(drag), "stale source payload must not move another pane")
    assertInvariants(destination.layout)
  }

  func test_workspace_tab_move_keeps_nested_tree_maximize_and_rebinds_pane_actions() throws {
    let (_, workspace) = try fixture(); defer { close(workspace) }
    let source = workspace.openWindow(empty: false, show: false), target = workspace.openWindow(empty: false, show: false)
    let a = try XCTUnwrap(source.focusedPane)
    source.newTab(nil); let b = try XCTUnwrap(source.focusedPane)
    source.selectPreviousTab(nil)
    let container = try XCTUnwrap(source.workspaceView?.container)
    source.paneContainer(container, drop: .init(windowToken: source.token, tabId: source.layout.tabs[1].id), onto: a.id, edge: .right)
    b.actions?.toggleMaximize(b.id)
    XCTAssertTrue(source.layout.selectedTab?.isWorkspace == true)
    let tree = try XCTUnwrap(source.layout.selectedTab)
    source.newTab(nil) // Leave a background source tab behind.
    XCTAssertTrue(workspace.moveTab(.init(windowToken: source.token, tabId: tree.id), to: target, at: 1))
    XCTAssertEqual(target.layout.selectedTab, tree); XCTAssertEqual(source.layout.tabs.count, 1)
    XCTAssertTrue(target.focusedPane === b); XCTAssertTrue(target.pane(id: a.id) === a)
    b.actions?.detach(b.id)
    XCTAssertEqual(target.layout.tabs.count, 3); XCTAssertEqual(source.layout.tabs.count, 1)
    XCTAssertFalse(b.isInWorkspace)
    assertInvariants(source.layout); assertInvariants(target.layout)
  }

  func test_single_pane_cross_window_merge_uses_drop_zone_and_preserves_view_instances() throws {
    let (_, workspace) = try fixture(); defer { close(workspace) }
    let source = workspace.openWindow(empty: false, show: false), target = workspace.openWindow(empty: false, show: false)
    let a = try XCTUnwrap(source.focusedPane), b = try XCTUnwrap(target.focusedPane)
    let container = try XCTUnwrap(target.workspaceView?.container)
    target.workspaceView?.layoutSubtreeIfNeeded()
    let frame = b.view.convert(b.view.bounds, to: nil)
    let drag = WorkspaceTabDrag(.init(windowToken: source.token, tabId: source.layout.tabs[0].id),
      window: target.window, point: .init(x: frame.maxX - 10, y: frame.midY))
    XCTAssertEqual(container.draggingEntered(drag), .move)
    XCTAssertTrue(container.performDragOperation(drag))
    XCTAssertEqual(target.layout.selectedTab?.paneIds, [b.id, a.id])
    XCTAssertTrue(target.focusedPane === a); XCTAssertTrue(a.view.window === target.window)
    XCTAssertTrue(b.view.window === target.window); XCTAssertEqual(workspace.windows.count, 1)
    assertInvariants(target.layout)
  }

  func test_menu_extracts_one_workspace_pane_to_new_window_and_keeps_other_sessions() throws {
    let (_, workspace) = try fixture(); defer { close(workspace) }
    let source = workspace.openWindow(empty: false, show: false), a = try XCTUnwrap(source.focusedPane)
    source.newTab(nil); let b = try XCTUnwrap(source.focusedPane)
    source.selectPreviousTab(nil)
    source.paneContainer(try XCTUnwrap(source.workspaceView?.container), drop: .init(windowToken: source.token, tabId: source.layout.tabs[1].id), onto: a.id, edge: .bottom)
    XCTAssertTrue(source.layout.selectedTab?.isWorkspace == true)
    let menu = try XCTUnwrap(b.actions?.moveMenu?(b.id)), item = try XCTUnwrap(menu.items.first)
    XCTAssertEqual(item.title, "新窗口"); XCTAssertTrue(item.isEnabled)
    XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
    let destination = try XCTUnwrap(workspace.windows.last)
    XCTAssertEqual(workspace.windows.count, 2); XCTAssertTrue(destination.focusedPane === b)
    XCTAssertTrue(source.focusedPane === a); XCTAssertFalse(a.isInWorkspace)
    XCTAssertEqual(destination.layout.allPaneIds, [b.id]); assertInvariants(source.layout)
  }

  func test_unknown_self_stale_and_modal_destination_moves_are_rejected_without_mutation() throws {
    let (_, workspace) = try fixture(); defer { close(workspace) }
    let source = workspace.openWindow(empty: false, show: false), target = workspace.openWindow(empty: false, show: false)
    let payload = TabDragPayload(windowToken: source.token, tabId: source.layout.tabs[0].id)
    let before = workspace.snapshot
    XCTAssertFalse(workspace.moveTab(payload, to: source, at: 0))
    XCTAssertFalse(workspace.moveTab(.init(windowToken: "unknown", tabId: payload.tabId), to: target, at: 0))
    XCTAssertFalse(workspace.moveTab(.init(windowToken: source.token, tabId: UUID()), to: target, at: 0))
    XCTAssertFalse(workspace.move(from: source, pane: UUID(), tab: payload.tabId, to: nil, show: false))
    XCTAssertFalse(workspace.mergeTab(payload, to: target, pane: UUID(), edge: .left))
    XCTAssertEqual(workspace.snapshot, before)
    let sheet = NSWindow(); sheet.isReleasedWhenClosed = false
    target.window?.beginSheet(sheet)
    let modalSnapshot = workspace.snapshot
    XCTAssertFalse(workspace.moveTab(payload, to: target, at: 0))
    XCTAssertEqual(workspace.snapshot, modalSnapshot)
    target.window?.endSheet(sheet); sheet.close()
    XCTAssertEqual(source.layout, before.windows[0].layout); XCTAssertEqual(target.layout, before.windows[1].layout)
  }

  func test_drag_outside_creates_one_window_but_rejected_drop_inside_does_not() throws {
    let (_, workspace) = try fixture(); defer { close(workspace) }
    let source = workspace.openWindow(empty: false), pane = try XCTUnwrap(source.focusedPane)
    let payload = TabDragPayload(windowToken: source.token, tabId: source.layout.tabs[0].id)
    workspace.tearOff(payload, at: .init(x: source.window!.frame.midX, y: source.window!.frame.midY), show: false)
    XCTAssertEqual(workspace.windows.count, 1); XCTAssertTrue(source.focusedPane === pane)
    workspace.tearOff(payload, at: .init(x: -50_000, y: -50_000), show: false)
    XCTAssertEqual(workspace.windows.count, 1)
    let new = try XCTUnwrap(workspace.windows.first)
    XCTAssertFalse(new === source); XCTAssertTrue(new.focusedPane === pane)
    XCTAssertTrue(NSScreen.screens.contains { $0.visibleFrame.contains(new.window!.frame) })
    workspace.tearOff(payload, at: .init(x: -50_000, y: -50_000), show: false)
    XCTAssertTrue(workspace.windows.first === new)
  }

  func test_live_ssh_input_sftp_queue_monitor_history_and_forward_survive_last_source_window_move() async throws {
    let (services, workspace) = try fixture(); defer { close(workspace) }
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    try await server.enableTCPForwarding()
    let saved = try services.profiles.saveConnection(name: "移动中的服务器", hostname: server.host, port: server.port,
      username: server.username, credential: .password(server.password))
    let source = workspace.openWindow(empty: false, show: false), target = workspace.openWindow(empty: false, show: false)
    source.openSavedConnection(id: saved.id)
    let pane = try XCTUnwrap(source.focusedPane)
    try await wait {
      if case .needsHostKeyConfirm = pane.session.state { pane.session.confirmHostKey(true) }
      return pane.session.state == .connected && pane.children.contains { $0 is TerminalViewController }
    }
    let terminal = try XCTUnwrap(pane.children.compactMap { $0 as? TerminalViewController }.first)
    let buffer = terminalIdentity(terminal.terminalView), version = pane.session.connectionVersion
    pane.toggleMonitor(); pane.toggleFiles()
    let files = try XCTUnwrap(pane.children.compactMap { $0 as? FileBrowserViewController }.first)
    let monitor = try XCTUnwrap(pane.monitorVC)
    try await wait { files.model.directory != nil && !files.model.isBrowsingBusy && !monitor.model.history.isEmpty }
    monitor.model.pause(); let history = monitor.model.history
    let local = FileManager.default.temporaryDirectory.appendingPathComponent("transfer-\(UUID()).bin")
    addTeardownBlock { try? FileManager.default.removeItem(at: local) }
    try Data(repeating: 73, count: 16 * 1024 * 1024).write(to: local)
    let port = try availablePort()
    let forward = try pane.session.portForwards.save(configuration: .init(localPort: port, targetHost: "localhost", targetPort: 2222))
    pane.session.portForwards.start(forward)
    try await wait { if case .running = pane.session.portForwards.rules.first?.state { return true }; return false }
    pane.session.sendInput(Data("printf '%s%s\\n' 'MOVE_' 'INPUT_PRESERVED'".utf8))
    try await Task.sleep(for: .milliseconds(50))
    files.model.upload(local)
    try await wait { files.model.transfers.jobs.first?.state == .running }
    let queue = files.model.transfers, queueID = try XCTUnwrap(queue.jobs.first?.id)
    let payload = TabDragPayload(windowToken: source.token, tabId: source.layout.tabs[0].id)
    XCTAssertTrue(workspace.moveTab(payload, to: target, at: 1))
    XCTAssertEqual(workspace.windows.count, 1); XCTAssertTrue(target.focusedPane === pane)
    XCTAssertEqual(pane.session.state, .connected); XCTAssertEqual(pane.session.connectionVersion, version)
    XCTAssertTrue(target.window?.firstResponder === terminal.terminalView)
    XCTAssertTrue(terminalIdentity(terminal.terminalView) == buffer); XCTAssertTrue(files.model.transfers === queue)
    XCTAssertTrue(pane.monitorVC === monitor); XCTAssertEqual(monitor.model.history, history)
    XCTAssertEqual(queue.jobs.first?.id, queueID)
    pane.session.sendInput(Data("\r".utf8))
    try await wait { String(decoding: terminal.terminalView.getBufferAsData(), as: UTF8.self).contains("MOVE_INPUT_PRESERVED") }
    try await wait { queue.jobs.first?.state == .completed }
    let greeting = try await ForwardTestSocket.exchange(port: port, data: Data())
    XCTAssertTrue(String(decoding: greeting, as: UTF8.self).contains("SSH-"))
    let data = try await server.execute(["sha256sum", files.model.directory! + "/" + local.lastPathComponent])
    let hash = SHA256.hash(data: try Data(contentsOf: local)).map { String(format: "%02x", $0) }.joined()
    XCTAssertTrue(data.hasPrefix(hash))
    XCTAssertEqual(source.sidebar.model.sessions.count, 0); XCTAssertEqual(target.sidebar.model.sessionText(for: saved.id), "已连接")
    pane.session.portForwards.stop(forward)
  }

  func test_host_key_confirmation_continues_in_destination_and_quit_restores_target() async throws {
    let (services, workspace) = try fixture(); defer { close(workspace) }
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    let saved = try services.profiles.saveConnection(name: "待信任", hostname: server.host, port: server.port,
      username: server.username, credential: .password(server.password))
    let source = workspace.openWindow(empty: false, show: false)
    source.openSavedConnection(id: saved.id); let pane = try XCTUnwrap(source.focusedPane)
    try await wait { if case .needsHostKeyConfirm = pane.session.state { return pane.progressVC != nil }; return false }
    let progress = try XCTUnwrap(pane.progressVC), version = pane.session.connectionVersion
    XCTAssertTrue(workspace.move(from: source, pane: pane.id, tab: nil, to: nil, show: false))
    XCTAssertTrue(pane.progressVC === progress); XCTAssertEqual(pane.session.connectionVersion, version)
    pane.session.confirmHostKey(true)
    try await wait { pane.session.state == .connected }
    XCTAssertTrue(workspace.saveNow())
    XCTAssertEqual(services.workspace.snapshot?.windows.first?.panes.first?.connection.profileID, saved.id)
  }

  func test_scrolled_chinese_ssh_logs_survive_tear_off_live_resize_and_drop_back_into_original_window() async throws {
    let (services, workspace) = try fixture(); defer { close(workspace) }
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    try services.appearance.update(.init(theme: .dark, terminalTheme: .termiusDark,
      terminalFontSize: 15, terminalFontName: "Monaco"))
    let saved = try services.profiles.saveConnection(name: "历史日志", hostname: server.host, port: server.port,
      username: server.username, credential: .password(server.password))
    let source = workspace.openWindow(empty: false, show: false), original = try XCTUnwrap(source.window)
    source.openSavedConnection(id: saved.id)
    let pane = try XCTUnwrap(source.focusedPane)
    try await wait {
      if case .needsHostKeyConfirm = pane.session.state { pane.session.confirmHostKey(true) }
      return pane.session.state == .connected && pane.children.contains { $0 is TerminalViewController }
    }
    let controller = try XCTUnwrap(pane.children.compactMap { $0 as? TerminalViewController }.first)
    let terminal = controller.terminalView, buffer = terminalIdentity(terminal), version = pane.session.connectionVersion
    source.newTab(nil); let other = try XCTUnwrap(source.focusedPane)
    source.selectPreviousTab(nil)
    XCTAssertTrue(source.focusedPane === pane); XCTAssertEqual(source.layout.tabs.count, 2)
    original.setContentSize(.init(width: 2020, height: 960)); source.workspaceView?.layoutSubtreeIfNeeded()

    let message = "【专家：金融体系将继续保持对实体经济高质量发展的有力支持】金十数据10月14日讯，近期，人民币政策消息"
    let logs = (0..<80).map { "2|flashnews | 2026/10/14 17:14:25.123456 jin10 recv id=\($0) published=2026-10-14 09:14:25 preview=\"" + message + "\"" }
    // Receive colored UTF-8 logs through a real PTY, rather than replacing onData or feeding a new view.
    let script = "printf '%s\\n' " + logs.map { "'\u{1b}[32m\($0)\u{1b}[0m'" }.joined(separator: " ") + "\nprintf 'REFLOW_%s\\n' 'READY'\n"
    _ = try await server.execute(["sh", "-c", "cat > /config/termes-reflow-logs.sh <<'TERMES_LOGS'\n\(script)TERMES_LOGS\n"])
    pane.session.sendInput(Data("sh /config/termes-reflow-logs.sh\r".utf8))
    try await wait { terminalLogicalLines(terminal).contains("REFLOW_READY") }
    func check(_ owner: MainWindowController, _ stage: String) {
      assertTerminalLines(terminalLogicalLines(terminal).filter { $0.hasPrefix("2|flashnews | ") }, logs, context: stage)
      XCTAssertTrue(terminalIdentity(terminal) == buffer, stage)
      XCTAssertTrue(terminal.window === owner.window, stage)
      XCTAssertEqual(pane.session.state, .connected, stage)
      XCTAssertEqual(pane.session.connectionVersion, version, stage)
      XCTAssertEqual(pane.session.lastSize?.cols, terminal.terminalDimensions.cols, stage)
      XCTAssertEqual(pane.session.lastSize?.rows, terminal.terminalDimensions.rows, stage)
      XCTAssertLessThan(terminal.scrollPosition, 1, stage)
    }
    terminal.scroll(toPosition: 0.3); XCTAssertLessThan(terminal.scrollPosition, 1)
    check(source, "initial history")
    let payload = TabDragPayload(windowToken: source.token, tabId: try XCTUnwrap(source.layout.selectedTab?.id))
    workspace.tearOff(payload, at: .init(x: -50_000, y: -50_000), show: false)
    let detached = try XCTUnwrap(workspace.windows.last)
    XCTAssertFalse(detached === source); XCTAssertTrue(source.focusedPane === other)
    XCTAssertEqual(workspace.windows.count, 2)
    for width in stride(from: 660.0, through: 2020.0, by: 9.0) {
      detached.window?.setContentSize(.init(width: width, height: 960))
      detached.workspaceView?.layoutSubtreeIfNeeded()
    }
    check(detached, "detached and continuously widened")
    let bar = try XCTUnwrap(source.workspaceView?.tabBar)
    let returning = WorkspaceTabDrag(.init(windowToken: detached.token, tabId: try XCTUnwrap(detached.layout.selectedTab?.id)), window: original)
    XCTAssertEqual(bar.draggingEntered(returning), .move); XCTAssertTrue(bar.performDragOperation(returning))
    XCTAssertEqual(workspace.windows.count, 1); XCTAssertEqual(source.layout.tabs.count, 2)
    XCTAssertTrue(source.focusedPane === pane)
    for width in [800.0, 1180, 700, 2020] {
      original.setContentSize(.init(width: width, height: 960)); source.workspaceView?.layoutSubtreeIfNeeded()
      check(source, "back in original at width \(width)")
    }
    // The final PTY dimensions reach the same remote shell after all queued resize requests.
    pane.session.sendInput(Data("printf 'REFLOW_SIZE_%s\\n' \"$(stty size)\"\r".utf8))
    try await wait { terminalLogicalLines(terminal).contains("REFLOW_SIZE_\(terminal.terminalDimensions.rows) \(terminal.terminalDimensions.cols)") }
  }
}
