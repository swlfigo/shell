import AppKit
import XCTest
import SSHCore
import TermesKit
@testable import Termes

@MainActor
final class ConnectionProgressViewTests: XCTestCase {
  private func wait(_ predicate: () -> Bool, timeout: TimeInterval = 15,
                    file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    guard predicate() else { XCTFail("timed out", file: file, line: line); throw CancellationError() }
  }
  private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
  private func fixture() async throws -> (TestSSHServer, MainWindowController, SessionPaneController, ConnectionConfig) {
    _ = NSApplication.shared
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let main = MainWindowController(services: .init(directory: directory, secrets: InMemorySecretStore()), empty: false)
    addTeardownBlock { @MainActor in main.disconnectAll(); main.close() }
    let pane = try XCTUnwrap(main.focusedPane)
    return (server, main, pane, .init(hostname: server.host, port: server.port, username: server.username, auth: .password(server.password)))
  }
  private func open(_ pane: SessionPaneController, _ config: ConnectionConfig) {
    pane.connect(config, label: .init(name: "生产服务器 · 上海", username: config.username))
  }
  private func ready(_ pane: SessionPaneController) async throws {
    try await wait {
      if case .needsHostKeyConfirm = pane.session.state { pane.progressVC?.trust() }
      return pane.session.state == .connected && pane.progressVC == nil && pane.children.contains { $0 is TerminalViewController }
    }
  }

  func test_real_trust_stage_full_fingerprint_scrollable_logs_and_completed_log_window_does_not_disconnect() async throws {
    let (_, main, pane, config) = try await fixture()
    let logsItem = NSMenuItem(title: "连接日志", action: #selector(MainWindowController.showConnectionLogs(_:)), keyEquivalent: "")
    XCTAssertFalse(main.validateMenuItem(logsItem))
    open(pane, config)
    // The protocol model and its AppKit subscribers update in separate main-queue turns.
    // Wait for the displayed phase too, rather than inspecting it between those updates.
    try await wait {
      pane.session.connectionProgress.state == .waitingForTrust &&
        pane.progressVC?.fingerprintLabel.stringValue.contains("SHA256:") == true &&
        pane.progressVC?.stepLabels[1].stringValue.contains("等待用户确认") == true
    }
    let progress = try XCTUnwrap(pane.progressVC)
    XCTAssertFalse(pane.children.contains { $0 is TerminalViewController })
    guard case .needsHostKeyConfirm(let fingerprint) = pane.session.state else { return XCTFail("trust prompt") }
    XCTAssertTrue(progress.fingerprintLabel.stringValue.contains(fingerprint))
    XCTAssertTrue(progress.fingerprintLabel.stringValue.contains("\(config.hostname):\(config.port)"))
    XCTAssertTrue(progress.stepLabels[1].stringValue.contains("等待用户确认"))
    XCTAssertTrue(progress.stepLabels[2].stringValue.contains("等待"))
    progress.toggleLogs()
    let window = try XCTUnwrap(main.window)
    window.setContentSize(.init(width: 840, height: 700)); main.showWindow(nil)
    window.contentView?.layoutSubtreeIfNeeded()
    if ProcessInfo.processInfo.environment["TERMES_CONNECTION_VISUAL_REVIEW"] == "1" {
      window.title = "Termes 连接进度验收"; window.makeKeyAndOrderFront(nil)
      print("CONNECTION_REVIEW_WINDOW=\(window.windowNumber)")
      try await Task.sleep(nanoseconds: 50_000_000_000)
    }
    let small = NSWindow(contentRect: .init(x: 0, y: 0, width: 240, height: 140), styleMask: [.borderless], backing: .buffered, defer: false)
    small.isReleasedWhenClosed = false; small.contentView = progress.view
    defer { small.close() }
    for size in [NSSize(width: 240, height: 140), .init(width: 620, height: 700)] {
      small.setContentSize(size); progress.view.layoutSubtreeIfNeeded(); progress.render()
      let scroll = try XCTUnwrap(progress.view.subviews.first as? NSScrollView), document = try XCTUnwrap(scroll.documentView)
      XCTAssertGreaterThanOrEqual(document.frame.width, 300)
      XCTAssertTrue(scroll.hasVerticalScroller && scroll.hasHorizontalScroller)
      for control in descendants(document).compactMap({ $0 as? NSControl }).filter({ !$0.isHiddenOrHasHiddenAncestor }) {
        XCTAssertTrue(document.bounds.contains(control.convert(control.bounds, to: document)), "\(control)")
      }
      let logScroll = try XCTUnwrap(progress.logView.enclosingScrollView)
      XCTAssertGreaterThan(progress.logView.frame.width, 250)
      XCTAssertGreaterThanOrEqual(progress.logView.frame.height, logScroll.contentSize.height)
      XCTAssertTrue(progress.logView.string.contains(fingerprint))
      XCTAssertTrue(progress.logView.isSelectable)
      progress.fingerprintLabel.scrollToVisible(progress.fingerprintLabel.bounds)
      XCTAssertTrue(scroll.contentView.bounds.intersects(progress.fingerprintLabel.frame))
    }
    // Restore the pane's ownership after checking an unusually small standalone content area.
    small.contentView = nil
    progress.trust(); try await ready(pane)
    XCTAssertEqual(pane.session.connectionProgress.state, .ready)
    XCTAssertTrue(main.validateMenuItem(logsItem))
    main.showConnectionLogs(nil)
    let logWindow = try XCTUnwrap(pane.progressWindow?.window)
    let completed = try XCTUnwrap(logWindow.contentViewController as? ConnectionProgressViewController)
    completed.render()
    XCTAssertTrue(completed.logView.string.contains("终端已打开，连接就绪"))
    logWindow.performClose(nil)
    XCTAssertEqual(pane.session.state, .connected)
  }

  func test_authentication_failure_keeps_form_draft_and_can_connect_after_returning_to_edit() async throws {
    let (server, _, pane, _) = try await fixture()
    try await wait { pane.children.contains { $0 is ConnectViewController } }
    let form = try XCTUnwrap(pane.children.compactMap { $0 as? ConnectViewController }.first)
    let fields = descendants(form.view).compactMap { $0 as? NSTextField }
    let host = try XCTUnwrap(fields.first { $0.placeholderString == "example.com" })
    let user = try XCTUnwrap(fields.first { $0.placeholderString == "root" })
    let name = try XCTUnwrap(fields.first { $0.accessibilityLabel() == "服务器名称" })
    let port = try XCTUnwrap(fields.first { $0.stringValue == "22" })
    let password = try XCTUnwrap(fields.compactMap { $0 as? NSSecureTextField }.first)
    let connect = try XCTUnwrap(descendants(form.view).compactMap { $0 as? NSButton }.first { $0.title == "连接" })
    name.stringValue = "保留的连接草稿"; host.stringValue = server.host; port.stringValue = String(server.port)
    user.stringValue = server.username; password.stringValue = "SECRET_NOT_FOR_LOGS"
    connect.performClick(nil)
    try await wait { pane.session.connectionProgress.state == .waitingForTrust && pane.progressVC != nil }
    pane.progressVC?.render(); pane.progressVC?.trust()
    try await wait { if case .failed = pane.session.state { return pane.progressVC != nil }; return false }
    let failed = try XCTUnwrap(pane.progressVC); failed.render()
    XCTAssertTrue(failed.stepLabels[2].stringValue.contains("身份认证失败"))
    XCTAssertTrue(failed.stepLabels[3].stringValue.contains("等待"))
    XCTAssertFalse(failed.logView.string.contains(password.stringValue))
    pane.showConnectionLogs()
    let logWindow = try XCTUnwrap(pane.progressWindow?.window)
    XCTAssertEqual(logWindow.title, "连接日志 · 保留的连接草稿")
    failed.closeProgress()
    XCTAssertNil(pane.progressVC); XCTAssertTrue(pane.children.contains { $0 === form })
    XCTAssertEqual(name.stringValue, "保留的连接草稿"); XCTAssertEqual(host.stringValue, server.host)
    XCTAssertEqual(password.stringValue, "SECRET_NOT_FOR_LOGS"); XCTAssertFalse(form.view.isHiddenOrHasHiddenAncestor)
    name.stringValue = "修正后的服务器名称"
    password.stringValue = server.password; connect.performClick(nil); try await ready(pane)
    XCTAssertEqual(pane.label?.name, "修正后的服务器名称")
    XCTAssertEqual(logWindow.title, "连接日志 · 修正后的服务器名称")
    XCTAssertTrue(descendants(try XCTUnwrap(logWindow.contentView)).compactMap { $0 as? NSTextField }
      .contains { $0.stringValue == "修正后的服务器名称 · 连接过程" })
    XCTAssertFalse(pane.session.connectionProgress.logs.contains { $0.text.contains("SECRET_NOT_FOR_LOGS") })
  }

  func test_closing_active_log_window_cancels_and_reject_button_preserves_failed_stage() async throws {
    let (_, _, pane, config) = try await fixture()
    open(pane, config)
    try await wait { pane.session.connectionProgress.state == .waitingForTrust && pane.progressVC != nil }
    pane.showConnectionLogs()
    let window = try XCTUnwrap(pane.progressWindow?.window)
    let logs = try XCTUnwrap(window.contentViewController as? ConnectionProgressViewController); logs.render()
    window.performClose(nil)
    try await wait { pane.session.state == .disconnected && pane.progressVC == nil }
    XCTAssertEqual(pane.session.connectionProgress.state, .cancelled); XCTAssertNil(pane.session.pendingHostKeyEndpoint)
    logs.trust()
    XCTAssertEqual(pane.session.state, .disconnected)
    open(pane, config)
    try await wait { pane.session.connectionProgress.state == .waitingForTrust && pane.progressVC != nil }
    pane.progressVC?.render(); pane.progressVC?.reject()
    try await wait { if case .failed = pane.session.state { return true }; return false }
    XCTAssertEqual(pane.session.connectionProgress.currentNode?.steps[1], .failed(SSHProgressFailure.hostKeyRejected.message))
    XCTAssertEqual(pane.session.connectionProgress.currentNode?.steps[2], .waiting)
  }

  func test_reconnect_overlay_preserves_terminal_files_and_monitor_and_blocks_tool_reparenting() async throws {
    let (server, main, pane, config) = try await fixture()
    open(pane, config); try await ready(pane)
    let terminal = try XCTUnwrap(pane.children.compactMap { $0 as? TerminalViewController }.first)
    pane.toggleFiles(); pane.toggleMonitor()
    let files = try XCTUnwrap(pane.children.compactMap { $0 as? FileBrowserViewController }.first), monitor = try XCTUnwrap(pane.monitorVC)
    try await wait { files.model.directory != nil && monitor.model.current != nil }
    await server.drop()
    try await wait({ if case .waitingRetry = pane.session.connectionProgress.state { return pane.progressVC != nil }; return false }, timeout: 30)
    let progress = try XCTUnwrap(pane.progressVC); progress.render()
    XCTAssertTrue(terminal.view.isHiddenOrHasHiddenAncestor)
    let tool = pane.toolsView?.selectedTool
    pane.toggleFiles(); pane.toggleMonitor(); pane.toggleTools(); pane.selectTool(.files)
    XCTAssertTrue(pane.children.contains { $0 === terminal }); XCTAssertTrue(pane.children.contains { $0 === files })
    XCTAssertTrue(pane.monitorVC === monitor); XCTAssertTrue(monitor.model.isOpen)
    XCTAssertEqual(pane.toolsView?.selectedTool, tool)
    XCTAssertFalse(progress.view.isHiddenOrHasHiddenAncestor)
    let item = NSMenuItem(title: "服务器监控", action: #selector(MainWindowController.toggleServerMonitor(_:)), keyEquivalent: "")
    XCTAssertFalse(main.validateMenuItem(item))
    try await server.restart(); pane.session.retryReconnectNow(); try await ready(pane)
    XCTAssertTrue(pane.children.contains { $0 === terminal }); XCTAssertTrue(pane.children.contains { $0 === files })
    XCTAssertTrue(pane.monitorVC === monitor); XCTAssertFalse(terminal.view.isHiddenOrHasHiddenAncestor)
    pane.close(); XCTAssertNil(pane.progressVC); XCTAssertNil(pane.progressWindow); XCTAssertFalse(monitor.model.isOpen)
  }
}
