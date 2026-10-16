import AppKit
import XCTest
import TermesKit
import SSHCore
@testable import Termes

@MainActor
final class TerminalOutputNoticeTests: XCTestCase {
  private func fixture() -> (SessionManager, TerminalViewController, NSWindow) {
    _ = NSApplication.shared
    let session = SessionManager(knownHosts: KnownHostsStore(
      fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
    let controller = TerminalViewController(session: session)
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 640, height: 320),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = controller.view
    controller.view.layoutSubtreeIfNeeded()
    return (session, controller, window)
  }
  private func history(_ count: Int = 200) -> Data {
    Data((0..<count).map { "history \($0)\r\n" }.joined().utf8)
  }
  private func wait(_ predicate: () -> Bool, timeout: TimeInterval = 20,
                    file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    guard predicate() else { XCTFail("terminal output timed out", file: file, line: line); throw CancellationError() }
  }

  func test_new_output_notice_preserves_history_viewport_and_click_returns_to_latest() async throws {
    let (session, controller, window) = fixture()
    defer { controller.teardown(); window.close() }
    let terminal = controller.terminalView, buffer = terminalIdentity(terminal)
    let denseHistory = (0..<200).map { "history \($0) · received server output · " + String(repeating: "log data ", count: 6) + "\r\n" }.joined()
    session.onData?(Data(denseHistory.utf8))
    XCTAssertFalse(controller.hasUnseenOutput); XCTAssertTrue(controller.newOutputButton.isHidden)
    terminal.scroll(toPosition: 0.5)
    XCTAssertTrue(controller.newOutputButton.isHidden, "scrolling alone is not new output")
    session.onData?(Data())
    XCTAssertFalse(controller.hasUnseenOutput)
    let firstLine = terminalLineText(terminal, row: 0)
    let frame = terminal.frame, rows = terminal.terminalDimensions.rows, cols = terminal.terminalDimensions.cols
    session.onData?(Data("latest output\r\n".utf8))
    controller.view.layoutSubtreeIfNeeded()
    XCTAssertTrue(controller.hasUnseenOutput); XCTAssertFalse(controller.newOutputButton.isHiddenOrHasHiddenAncestor)
    XCTAssertEqual(terminalLineText(terminal, row: 0), firstLine)
    XCTAssertEqual(terminal.frame, frame); XCTAssertEqual(terminal.terminalDimensions.rows, rows); XCTAssertEqual(terminal.terminalDimensions.cols, cols)
    let buttonFrame = controller.newOutputButton.convert(controller.newOutputButton.bounds, to: controller.view)
    XCTAssertTrue(controller.view.bounds.contains(buttonFrame))
    XCTAssertEqual(controller.view.hitTest(NSPoint(x: buttonFrame.midX, y: buttonFrame.midY)), controller.newOutputButton)
    if ProcessInfo.processInfo.environment["TERMES_TERMINAL_OUTPUT_REVIEW"] == "1" {
      window.title = "Termes 新输出提示 · 示例数据"
      window.styleMask = [.titled, .closable, .resizable]
      window.appearance = NSAppearance(named: .darkAqua)
      controller.applyAppearance(.init(terminalTheme: .termiusDark, terminalFontSize: 14))
      window.setContentSize(.init(width: 820, height: 500)); controller.view.layoutSubtreeIfNeeded()
      // Width changes can reflow long history lines to the bottom. Start a new read
      // position after resizing so the screenshot exercises overlapping log text.
      terminal.scroll(toPosition: 0.5); session.onData?(Data("visual output\r\n".utf8))
      XCTAssertTrue(controller.hasUnseenOutput)
      window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
      try await Task.sleep(for: .seconds(15))
    }
    controller.newOutputButton.performClick(nil)
    XCTAssertEqual(terminal.scrollPosition, 1)
    XCTAssertFalse(controller.hasUnseenOutput); XCTAssertTrue(controller.newOutputButton.isHidden)
    XCTAssertTrue(window.firstResponder === terminal)
    XCTAssertTrue(terminalIdentity(terminal) == buffer)
    XCTAssertTrue(String(decoding: terminal.getBufferAsData(), as: UTF8.self).contains("latest output"))
    session.onData?(Data("following output\r\n".utf8))
    XCTAssertEqual(terminal.scrollPosition, 1); XCTAssertFalse(controller.hasUnseenOutput)
  }

  func test_manual_bottom_clear_history_and_alternate_screen_reset_the_notice() throws {
    let (session, controller, window) = fixture()
    defer { controller.teardown(); window.close() }
    let terminal = controller.terminalView
    session.onData?(Data("short output".utf8))
    XCTAssertEqual(terminal.scrollPosition, 0); XCTAssertFalse(terminal.canScroll)
    XCTAssertFalse(controller.hasUnseenOutput)
    terminal.changeScrollback(50)
    session.onData?(history())
    terminal.scroll(toPosition: 0)
    session.onData?(history())
    XCTAssertEqual(terminal.scrollPosition, 0)
    XCTAssertTrue(controller.hasUnseenOutput, "the oldest position in a full history is still scrolled away")
    terminal.scroll(toPosition: 1)
    XCTAssertFalse(controller.hasUnseenOutput)
    terminal.scroll(toPosition: 0.5)
    session.onData?(Data("\rprogress update".utf8))
    XCTAssertTrue(controller.hasUnseenOutput, "output without a newline must also notify")
    session.onData?(Data("\u{1b}[?1049halternate screen\r\n".utf8))
    XCTAssertFalse(terminal.canScroll); XCTAssertFalse(controller.hasUnseenOutput)
    session.onData?(Data("alternate update".utf8))
    XCTAssertTrue(controller.newOutputButton.isHidden)
    session.onData?(Data("\u{1b}[?1049l".utf8))
    terminal.scroll(toPosition: 0.5)
    session.onData?(Data("resumed output\r\n".utf8))
    XCTAssertTrue(controller.hasUnseenOutput)
    terminal.clearScrollback()
    XCTAssertFalse(terminal.canScroll); XCTAssertFalse(controller.hasUnseenOutput)
  }

  func test_hidden_terminal_keeps_notice_across_reparenting_theme_changes_and_small_panes() throws {
    let (session, controller, window) = fixture()
    defer { controller.teardown(); window.close() }
    let terminal = controller.terminalView, buffer = terminalIdentity(terminal)
    session.onData?(history()); terminal.scroll(toPosition: 0.5)
    controller.view.removeFromSuperview()
    session.onData?(Data("background output\r\n".utf8))
    XCTAssertNil(controller.view.window); XCTAssertTrue(controller.hasUnseenOutput)
    window.contentView = controller.view
    controller.applyAppearance(.init(terminalTheme: .termiusDark, terminalFontSize: 18))
    for size in [NSSize(width: 240, height: 140), .init(width: 930, height: 700)] {
      window.setContentSize(size); controller.view.layoutSubtreeIfNeeded()
      XCTAssertTrue(controller.hasUnseenOutput)
      let notice = try XCTUnwrap(controller.newOutputButton.superview)
      let noticeFrame = notice.convert(notice.bounds, to: controller.view)
      XCTAssertTrue(controller.view.bounds.contains(noticeFrame))
      let padding = NSPoint(x: noticeFrame.minX + 2, y: noticeFrame.midY)
      XCTAssertTrue(controller.view.hitTest(padding) === controller.newOutputButton)
      XCTAssertFalse(controller.newOutputButton.isHiddenOrHasHiddenAncestor)
    }
    XCTAssertTrue(terminalIdentity(terminal) == buffer)
    controller.newOutputButton.performClick(nil)
    controller.applyAppearance(.init(terminalTheme: .light, terminalFontSize: 14))
    XCTAssertFalse(controller.hasUnseenOutput, "appearance changes must not create unread output")
    terminal.scroll(toPosition: 0.5); session.onData?(Data("more output\r\n".utf8))
    controller.teardown()
    XCTAssertNil(session.onData); XCTAssertFalse(controller.hasUnseenOutput)
  }

  func test_real_ssh_background_output_notifies_and_click_preserves_unsubmitted_command() async throws {
    _ = NSApplication.shared
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let services = AppServices(directory: directory, secrets: InMemorySecretStore())
    let main = MainWindowController(services: services, empty: false)
    defer { main.disconnectAll(); main.close() }
    let pane = try XCTUnwrap(main.focusedPane), window = try XCTUnwrap(main.window)
    pane.connect(.init(hostname: server.host, port: server.port, username: server.username, auth: .password(server.password)),
      label: .init(name: "新输出提示 · 本机测试服务器", username: server.username))
    try await wait {
      if case .needsHostKeyConfirm = pane.session.state { pane.session.confirmHostKey(true) }
      return pane.session.state == .connected && pane.children.contains { $0 is TerminalViewController }
    }
    let controller = try XCTUnwrap(pane.children.compactMap { $0 as? TerminalViewController }.first)
    let terminal = controller.terminalView, version = pane.session.connectionVersion
    func output() -> String { String(decoding: terminal.getBufferAsData(), as: UTF8.self) }
    pane.session.sendInput(Data("seq 1 240; (sleep 2; printf 'LATE_%s\\n' OUTPUT) & printf 'READY_%s\\n' STREAM\r".utf8))
    try await wait { output().contains("READY_STREAM") }
    terminal.scroll(toPosition: 0.5)
    let firstLine = terminalLineText(terminal, row: 0)
    try await wait { output().contains("LATE_OUTPUT") }
    XCTAssertTrue(controller.hasUnseenOutput)
    XCTAssertEqual(terminalLineText(terminal, row: 0), firstLine)
    pane.session.sendInput(Data("printf 'CLICK_%s\\n' 'KEPT'".utf8))
    try await wait { output().contains("'KEPT'") }
    XCTAssertFalse(output().contains("CLICK_KEPT"))
    controller.newOutputButton.performClick(nil)
    XCTAssertEqual(terminal.scrollPosition, 1); XCTAssertTrue(window.firstResponder === terminal)
    XCTAssertFalse(controller.hasUnseenOutput); XCTAssertFalse(output().contains("CLICK_KEPT"))
    XCTAssertEqual(pane.session.connectionVersion, version); XCTAssertEqual(pane.session.state, .connected)
    pane.session.sendInput(Data("\r".utf8))
    try await wait { output().contains("CLICK_KEPT") }
    XCTAssertFalse(controller.hasUnseenOutput)
  }
}
