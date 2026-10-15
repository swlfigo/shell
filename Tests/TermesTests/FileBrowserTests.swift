import AppKit
import XCTest
import TermesKit
import SSHCore
@testable import Termes

private actor BrowserFileSystem: SFTPFileSystem {
  let home: String
  let pause: Bool
  var entered = false
  var closed = false
  var release: CheckedContinuation<Void, Never>?
  var items: [SFTPEntry]
  init(home: String, pause: Bool = false) {
    self.home = home; self.pause = pause
    items = [.init(path: home + "/file", name: "file", kind: .file, size: 12)]
  }
  func canonicalPath(_ path: String) async throws -> String {
    entered = true
    if pause { await withCheckedContinuation { release = $0 } }
    if path == "missing" { throw SFTPError.operation("没有该目录", code: 2) }
    return home
  }
  func resume() { release?.resume(); release = nil }
  func listDirectory(_ path: String) async throws -> [SFTPEntry] { items }
  func createDirectory(_ path: String) async throws { items.append(.init(path: path, name: RemotePath.name(path), kind: .directory)) }
  func rename(_ source: String, to destination: String) async throws {}
  func remove(_ entry: SFTPEntry) async throws { items.removeAll { $0.path == entry.path } }
  func upload(_ localURL: URL, to remotePath: String, overwrite: Bool, progress: @escaping SFTPProgressHandler) async throws {}
  func download(_ remotePath: String, to localURL: URL, overwrite: Bool, progress: @escaping SFTPProgressHandler) async throws {}
  func close() async { closed = true }
}

@MainActor
final class FileBrowserTests: XCTestCase {
  private func wait(_ predicate: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(10)
    while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(predicate())
  }

  func test_cancel_discards_late_results_and_closes_old_client() async throws {
    let old = BrowserFileSystem(home: "/old", pause: true)
    let fresh = BrowserFileSystem(home: "/fresh")
    var opens = 0
    let model = FileBrowserModel { opens += 1; return opens == 1 ? old : fresh }
    model.refresh()
    while !(await old.entered) { await Task.yield() }
    model.cancel()
    model.refresh()
    try await wait { !model.isBusy }
    XCTAssertEqual(model.directory, "/fresh")
    await old.resume()
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertEqual(model.directory, "/fresh")
    XCTAssertEqual(model.entries.first?.path, "/fresh/file")
    let closed = await old.closed
    XCTAssertTrue(closed)
    model.shutdown()
  }

  func test_errors_preserve_listing_and_disconnect_blocks_mutations() async throws {
    let fs = BrowserFileSystem(home: "/home")
    let model = FileBrowserModel { fs }
    model.refresh(); try await wait { !model.isBusy }
    model.navigate("missing"); try await wait { !model.isBusy }
    XCTAssertEqual(model.directory, "/home")
    XCTAssertEqual(model.entries.count, 1)
    XCTAssertNotNil(model.error)
    model.createDirectory(name: "../invalid"); try await wait { !model.isBusy }
    XCTAssertNotNil(model.error)
    model.createDirectory(name: "中文"); try await wait { !model.isBusy }
    XCTAssertEqual(model.entries.count, 2)
    model.setConnected(false)
    model.createDirectory(name: "blocked")
    model.refresh()
    XCTAssertFalse(model.isBusy)
    XCTAssertEqual(model.entries.count, 2)
    model.setConnected(true); try await wait { !model.isBusy }
    XCTAssertEqual(model.directory, "/home")
    model.shutdown()
  }

  func test_file_panel_remains_scrollable_in_small_panes() async throws {
    _ = NSApplication.shared
    let fs = BrowserFileSystem(home: "/home")
    let controller = FileBrowserViewController(model: FileBrowserModel { fs },
      localModel: LocalFileBrowserModel(initialDirectory: FileManager.default.temporaryDirectory))
    let terminal = NSView()
    let container = TerminalFilesView(terminal: terminal, files: controller.view)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = container
    defer { controller.shutdown(); window.close() }
    controller.start(); try await wait { !controller.model.isBusy }
    for size in [NSSize(width: 1_400, height: 700), NSSize(width: 900, height: 500), NSSize(width: 480, height: 320), NSSize(width: 240, height: 140)] {
      window.setContentSize(size)
      container.needsLayout = true
      container.layoutSubtreeIfNeeded()
      XCTAssertGreaterThan(terminal.frame.width, 0)
      XCTAssertGreaterThan(terminal.frame.height, 0)
      XCTAssertTrue(container.bounds.contains(terminal.frame))
      XCTAssertTrue(container.bounds.contains(controller.view.frame))
      let workspace = try XCTUnwrap(controller.view as? LocalRemoteFilesView)
      XCTAssertTrue(workspace.bounds.contains(workspace.local.frame))
      XCTAssertTrue(workspace.bounds.contains(workspace.remote.frame))
      let scroll = try XCTUnwrap(workspace.remote.subviews.first as? NSScrollView)
      let document = try XCTUnwrap(scroll.documentView)
      XCTAssertGreaterThanOrEqual(document.frame.height, 334)
      XCTAssertTrue(document.bounds.contains(controller.pathField.frame))
      XCTAssertGreaterThan(controller.table.enclosingScrollView?.frame.height ?? 0, 100)
    }
  }

  func test_pane_toggle_preserves_terminal_and_disconnect_closes_sftp() async throws {
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let services = AppServices(directory: directory, secrets: InMemorySecretStore())
    let session = services.makeSession()
    let pane = SessionPaneController(session: session, profiles: services.profiles)
    _ = pane.view
    defer { pane.close() }
    pane.connect(.init(hostname: server.host, port: server.port, username: server.username, auth: .password(server.password)),
                 label: .init(name: "SFTP test", username: server.username))
    let deadline = Date().addingTimeInterval(30)
    while session.state != .connected, Date() < deadline {
      if case .needsHostKeyConfirm = session.state { session.confirmHostKey(true) }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertEqual(session.state, .connected)
    try await wait { pane.children.contains { $0 is TerminalViewController } }
    let terminal = try XCTUnwrap(pane.children.compactMap { $0 as? TerminalViewController }.first)
    pane.toggleFiles()
    let files = try XCTUnwrap(pane.children.compactMap { $0 as? FileBrowserViewController }.first)
    try await wait { !files.model.isBusy }
    XCTAssertNotNil(files.model.directory)
    XCTAssertNil(files.model.error)
    pane.toggleFiles()
    XCTAssertTrue(pane.children.contains { $0 === terminal })
    XCTAssertNotNil(session.onData)
    pane.toggleFiles()
    let reopened = try XCTUnwrap(pane.children.compactMap { $0 as? FileBrowserViewController }.first)
    try await wait { !reopened.model.isBusy }
    let client = try await session.openSFTP()
    session.disconnect()
    try await wait { pane.children.allSatisfy { !($0 is FileBrowserViewController) } }
    XCTAssertFalse(reopened.model.isConnected)
    try await Task.sleep(for: .milliseconds(100))
    do { _ = try await client.listDirectory("."); XCTFail("client must close with terminal session") }
    catch let error as SFTPError { XCTAssertEqual(error, .notConnected) }
  }
}
