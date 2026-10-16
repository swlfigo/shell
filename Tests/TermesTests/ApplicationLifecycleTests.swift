import AppKit
import CryptoKit
import Darwin
import XCTest
import SSHCore
import TermesKit
@testable import Termes

@MainActor
final class ApplicationLifecycleTests: XCTestCase {
  @MainActor
  private final class AlertChoice {
    var response: NSApplication.ModalResponse
    init(_ response: NSApplication.ModalResponse) { self.response = response }
  }
  private func services(directory: URL? = nil) throws -> AppServices {
    _ = NSApplication.shared
    let directory = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent("termes-lifecycle-\(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return AppServices(directory: directory, secrets: InMemorySecretStore())
  }
  private func dispose(_ delegate: AppDelegate) {
    NSApp.unhide(nil)
    delegate.workspace.prepareToTerminate()
    for main in delegate.workspace.windows { main.close() }
  }
  private func wait(_ predicate: () -> Bool, timeout: TimeInterval = 30,
                    file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    guard predicate() else { XCTFail("timed out", file: file, line: line); throw CancellationError() }
  }
  private func open(_ delegate: AppDelegate, services: AppServices, server: TestSSHServer,
                    name: String = "后台服务器", trust: Bool = true) async throws -> (MainWindowController, SessionPaneController) {
    let saved = try services.profiles.saveConnection(name: name, hostname: server.host, port: server.port,
      username: server.username, credential: .password(server.password))
    let main = delegate.workspace.openWindow(show: false)
    main.openSavedConnection(id: saved.id)
    let pane = try XCTUnwrap(main.focusedPane)
    try await ready(pane, trust: trust)
    return (main, pane)
  }
  private func ready(_ pane: SessionPaneController, trust: Bool = true) async throws {
    try await wait {
      if case .needsHostKeyConfirm = pane.session.state {
        if !trust { return pane.progressVC != nil }
        pane.session.confirmHostKey(true)
      }
      return pane.session.state == .connected && pane.children.contains { $0 is TerminalViewController }
    }
  }
  private func availablePort() throws -> Int {
    let socket = try ForwardTestSocket.listener()
    defer { Darwin.close(socket) }
    return try ForwardTestSocket.boundPort(socket).port
  }
  private func localFile(bytes: Int) throws -> URL {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("background-\(UUID()).bin")
    try Data(repeating: 73, count: bytes).write(to: file)
    addTeardownBlock { try? FileManager.default.removeItem(at: file) }
    return file
  }
  func test_red_close_hides_and_dock_restores_the_same_windows_tabs_and_drafts() throws {
    let services = try services(), delegate = AppDelegate(services: services)
    defer { dispose(delegate) }
    let first = delegate.workspace.openWindow(empty: false, show: false)
    let second = delegate.workspace.openWindow(show: false)
    first.newTab(nil)
    let pane = try XCTUnwrap(first.focusedPane), window = try XCTUnwrap(first.window)
    pane.restore(.init(hostname: "keep-draft.test", username: "ops"))
    first.showWindow(nil); second.showWindow(nil)
    window.setContentSize(.init(width: 980, height: 660))
    let before = first.restorationSnapshot
    window.performClose(nil)
    second.window?.performClose(nil)
    XCTAssertFalse(window.isVisible); XCTAssertFalse(second.window?.isVisible ?? true)
    XCTAssertEqual(delegate.workspace.windows.count, 2)
    XCTAssertTrue(first.focusedPane === pane)
    XCTAssertEqual(first.restorationSnapshot, before)
    XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp))
    XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
    XCTAssertTrue(window.isVisible); XCTAssertTrue(second.window?.isVisible == true)
    XCTAssertTrue(first.focusedPane === pane)
    XCTAssertEqual(first.restorationSnapshot, before)
    XCTAssertTrue(delegate.workspace.saveNow())
    XCTAssertEqual(services.workspace.snapshot?.windows.count, 2)
    second.closeFocusedPane(nil) // ⌘W on Vaults also keeps the library window available in Dock.
    XCTAssertFalse(second.window?.isVisible ?? true)
    XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
    XCTAssertTrue(second.window?.isVisible == true)
  }

  func test_dock_reopen_creates_one_vault_when_all_windows_have_been_disposed() throws {
    let delegate = AppDelegate(services: try services())
    defer { dispose(delegate) }
    XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
    let main = try XCTUnwrap(delegate.workspace.windows.first)
    XCTAssertTrue(main.isShowingVaults); XCTAssertTrue(main.window?.isVisible == true)
    XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
    XCTAssertEqual(delegate.workspace.windows.count, 1)
  }

  func test_hidden_and_minimized_windows_keep_ssh_input_transfer_monitor_and_forward_alive() async throws {
    let services = try services(), delegate = AppDelegate(services: services)
    defer { dispose(delegate) }
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    try await server.enableTCPForwarding()
    let (main, pane) = try await open(delegate, services: services, server: server)
    let window = try XCTUnwrap(main.window)
    let terminal = try XCTUnwrap(pane.children.compactMap { $0 as? TerminalViewController }.first)
    let buffer = terminalIdentity(terminal.terminalView), version = pane.session.connectionVersion
    pane.toggleFiles(); pane.toggleMonitor()
    let files = try XCTUnwrap(pane.children.compactMap { $0 as? FileBrowserViewController }.first)
    let monitor = try XCTUnwrap(pane.monitorVC)
    try await wait { files.model.directory != nil && !files.model.isBrowsingBusy && !monitor.model.history.isEmpty }
    monitor.model.pause(); let history = monitor.model.history
    let port = try availablePort()
    let forward = try pane.session.portForwards.save(configuration: .init(localPort: port, targetHost: "127.0.0.1", targetPort: 2222))
    pane.session.portForwards.start(forward)
    try await wait { if case .running = pane.session.portForwards.rules.first?.state { return true }; return false }
    main.showWindow(nil)
    pane.session.sendInput(Data("printf '%s%s\\n' 'BACKGROUND_' 'INPUT_KEPT'".utf8))
    try await wait { String(decoding: terminal.terminalView.getBufferAsData(), as: UTF8.self).contains("INPUT_KEPT") }
    let local = try localFile(bytes: 16 * 1024 * 1024), queue = files.model.transfers
    files.model.upload(local)
    XCTAssertEqual(main.unfinishedTransferCount, 1)
    window.performClose(nil)
    XCTAssertFalse(window.isVisible); XCTAssertEqual(delegate.workspace.windows.count, 1)
    XCTAssertEqual(pane.session.state, .connected); XCTAssertEqual(pane.session.connectionVersion, version)
    pane.session.sendInput(Data("\r".utf8))
    try await wait { String(decoding: terminal.terminalView.getBufferAsData(), as: UTF8.self).contains("BACKGROUND_INPUT_KEPT") }
    try await wait { queue.jobs.first?.state == .completed }
    XCTAssertEqual(main.unfinishedTransferCount, 0); XCTAssertEqual(main.activeForwardCount, 1)
    let remote = try XCTUnwrap(files.model.directory) + "/" + local.lastPathComponent
    let hash = SHA256.hash(data: try Data(contentsOf: local)).map { String(format: "%02x", $0) }.joined()
    let uploadedHash = try await server.execute(["sha256sum", remote])
    XCTAssertTrue(uploadedHash.hasPrefix(hash))
    let greeting = try await ForwardTestSocket.exchange(port: port, data: Data())
    XCTAssertTrue(String(decoding: greeting, as: UTF8.self).contains("SSH-"))
    _ = delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
    XCTAssertTrue(window.isVisible); XCTAssertTrue(main.focusedPane === pane)
    XCTAssertTrue(terminalIdentity(terminal.terminalView) == buffer)
    XCTAssertTrue(files.model.transfers === queue); XCTAssertTrue(pane.monitorVC === monitor)
    XCTAssertEqual(monitor.model.history, history)
    window.miniaturize(nil)
    try await wait { window.isMiniaturized }
    XCTAssertEqual(pane.session.state, .connected); XCTAssertEqual(main.activeForwardCount, 1)
    _ = delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
    try await wait { !window.isMiniaturized && window.isVisible }
    XCTAssertEqual(pane.session.connectionVersion, version)
  }

  func test_quit_choices_preserve_all_windows_or_disconnect_with_counts_for_transfers_and_forwards() async throws {
    let services = try services()
    let choice = AlertChoice(.alertFirstButtonReturn)
    var prompts: [String] = []
    let delegate = AppDelegate(services: services, runAlert: { alert in
      XCTAssertEqual(alert.buttons.map(\.title), ["后台运行（保持连接）", "断开并退出", "取消"])
      XCTAssertEqual(alert.buttons[0].keyEquivalent, "\r")
      XCTAssertEqual(alert.buttons[1].keyEquivalent, "")
      XCTAssertEqual(alert.buttons[2].keyEquivalent, "\u{1b}")
      prompts.append(alert.messageText)
      alert.layout()
      if let content = alert.window.contentView {
        for button in alert.buttons {
          XCTAssertTrue(content.bounds.contains(button.convert(button.bounds, to: content)))
        }
      }
      return choice.response
    })
    defer { dispose(delegate) }
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    try await server.enableTCPForwarding()
    let (a, first) = try await open(delegate, services: services, server: server, name: "First")
    let (b, second) = try await open(delegate, services: services, server: server, name: "Second")
    let version = first.session.connectionVersion
    let port = try availablePort()
    let forward = try first.session.portForwards.save(configuration: .init(localPort: port, targetHost: "localhost", targetPort: 2222))
    first.session.portForwards.start(forward)
    try await wait { a.activeForwardCount == 1 }
    first.toggleFiles()
    let files = try XCTUnwrap(first.children.compactMap { $0 as? FileBrowserViewController }.first)
    try await wait { files.model.directory != nil && !files.model.isBrowsingBusy }
    a.showWindow(nil); b.showWindow(nil)
    files.model.upload(try localFile(bytes: 16 * 1024 * 1024))
    XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateCancel)
    XCTAssertTrue(try XCTUnwrap(prompts.first).contains("2 个活动会话"))
    XCTAssertTrue(try XCTUnwrap(prompts.first).contains("1 项未完成传输"))
    XCTAssertTrue(try XCTUnwrap(prompts.first).contains("1 个端口转发"))
    XCTAssertFalse(a.window?.isVisible ?? true); XCTAssertFalse(b.window?.isVisible ?? true)
    XCTAssertEqual(first.session.state, .connected); XCTAssertEqual(second.session.state, .connected)
    _ = delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
    XCTAssertEqual(delegate.workspace.windows.count, 2)
    XCTAssertTrue(a.window?.isVisible == true); XCTAssertTrue(b.window?.isVisible == true)
    XCTAssertEqual(first.session.connectionVersion, version)
    try await wait { files.model.transfers.jobs.first?.state == .completed }
    choice.response = .alertThirdButtonReturn
    XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateCancel)
    XCTAssertTrue(a.window?.isVisible == true); XCTAssertTrue(b.window?.isVisible == true)
    XCTAssertEqual(first.session.state, .connected)
    choice.response = .alertSecondButtonReturn
    XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateNow)
    XCTAssertEqual(first.session.state, .disconnected); XCTAssertEqual(second.session.state, .disconnected)
    XCTAssertEqual(services.workspace.snapshot?.windows.count, 2)
    try await wait { a.activeForwardCount == 0 }
    let reusable = try ForwardTestSocket.listener(port: port)
    Darwin.close(reusable)
    XCTAssertEqual(prompts.count, 3)
  }

  func test_unsaved_remote_editor_can_stay_in_background_and_is_discarded_only_on_explicit_quit() async throws {
    let services = try services()
    let choice = AlertChoice(.alertFirstButtonReturn)
    var promptCount = 0
    let delegate = AppDelegate(services: services, runAlert: { alert in
      promptCount += 1
      XCTAssertTrue(alert.messageText.contains("1 个未保存或正在操作的远端文件"))
      XCTAssertTrue(alert.informativeText.contains("放弃未保存"))
      return choice.response
    })
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    let (_, pane) = try await open(delegate, services: services, server: server)
    _ = try await server.execute(["sh", "-c", "printf 'original\\n' > /config/background-editor.txt"])
    let model = RemoteFileEditorModel(path: "/config/background-editor.txt") { try await pane.session.openSFTP() }
    let editor = RemoteFileEditorWindowController(model: model, serverName: "后台草稿")
    defer { editor.close(); dispose(delegate) }
    editor.showWindow(nil)
    try await wait { model.isLoaded && !model.isBusy }
    model.text = "unsaved draft\n"
    pane.session.disconnect()
    XCTAssertTrue(model.isDirty)
    XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateCancel)
    XCTAssertEqual(model.text, "unsaved draft\n"); XCTAssertTrue(model.isDirty)
    XCTAssertEqual(RemoteFileEditorWindowController.unsavedCount, 1)
    _ = delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
    choice.response = .alertThirdButtonReturn
    XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateCancel)
    XCTAssertTrue(model.isDirty)
    choice.response = .alertSecondButtonReturn
    XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateNow)
    XCTAssertEqual(RemoteFileEditorWindowController.unsavedCount, 0)
    XCTAssertEqual(promptCount, 3)
    let actual = try await server.execute(["cat", "/config/background-editor.txt"])
    XCTAssertEqual(actual, "original\n")
  }

  func test_cmd_w_still_confirms_then_disconnects_the_focused_tab() async throws {
    let services = try services()
    let choice = AlertChoice(.alertSecondButtonReturn)
    var prompts = 0
    let main = MainWindowController(services: services, empty: false, runCloseAlert: { alert in
      prompts += 1; XCTAssertTrue(alert.messageText.contains("关闭后将断开")); return choice.response
    })
    defer { main.close() }
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    let pane = try XCTUnwrap(main.focusedPane)
    pane.connect(.init(hostname: server.host, port: server.port, username: server.username, auth: .password(server.password)),
      label: .init(name: "当前标签", username: server.username))
    try await ready(pane)
    main.closeFocusedPane(nil)
    XCTAssertTrue(main.focusedPane === pane); XCTAssertEqual(pane.session.state, .connected)
    choice.response = .alertFirstButtonReturn
    main.closeFocusedPane(nil)
    XCTAssertEqual(pane.session.state, .disconnected)
    XCTAssertTrue(main.isShowingVaults); XCTAssertTrue(main.layout.tabs.isEmpty)
    XCTAssertEqual(prompts, 2)
  }

  func test_host_key_confirmation_survives_hiding_and_dock_reopen() async throws {
    let services = try services(), delegate = AppDelegate(services: services)
    defer { dispose(delegate) }
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    let (main, pane) = try await open(delegate, services: services, server: server, trust: false)
    let progress = try XCTUnwrap(pane.progressVC), version = pane.session.connectionVersion
    main.showWindow(nil); main.window?.performClose(nil)
    XCTAssertFalse(main.window?.isVisible ?? true)
    _ = delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
    XCTAssertTrue(pane.progressVC === progress); XCTAssertEqual(pane.session.connectionVersion, version)
    guard case .needsHostKeyConfirm = pane.session.state else { return XCTFail("trust must remain pending") }
    progress.trust()
    try await ready(pane)
  }

  func test_idle_quit_skips_the_prompt_but_save_failure_still_allows_cancel() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("termes-lifecycle-save-\(UUID())")
    let services = try services(directory: directory)
    let normal = AppDelegate(services: services, runAlert: { _ in XCTFail("idle quit should be immediate"); return .alertThirdButtonReturn })
    _ = normal.workspace.openWindow(show: false)
    XCTAssertEqual(normal.applicationShouldTerminate(NSApp), .terminateNow)
    dispose(normal)
    let choice = AlertChoice(.alertSecondButtonReturn)
    let failed = AppDelegate(services: services, runAlert: { alert in
      XCTAssertEqual(alert.messageText, "工作区未能保存，仍要退出吗？")
      return choice.response
    })
    let file = directory.appendingPathComponent("workspace.json")
    defer { try? FileManager.default.removeItem(at: file); dispose(failed) }
    let main = failed.workspace.openWindow(show: false)
    main.showWindow(nil)
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    XCTAssertEqual(failed.applicationShouldTerminate(NSApp), .terminateCancel)
    XCTAssertTrue(main.window?.isVisible == true)
    XCTAssertNotNil(services.workspace.error)
    choice.response = .alertFirstButtonReturn
    XCTAssertEqual(failed.applicationShouldTerminate(NSApp), .terminateNow)
  }
}
