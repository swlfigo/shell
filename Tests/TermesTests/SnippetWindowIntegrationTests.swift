import AppKit
import XCTest
import SSHCore
import TermesKit
@testable import Termes

@MainActor
final class SnippetWindowIntegrationTests: XCTestCase {
  private func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(descendants)
  }

  private func connect(_ pane: SessionPaneController, server: TestSSHServer) async throws {
    pane.connect(.init(hostname: server.host, port: server.port, username: server.username,
                       auth: .password(server.password)),
                 label: SessionLabel(name: pane.id.uuidString, username: server.username))
    let deadline = Date().addingTimeInterval(30)
    while pane.session.state != .connected, Date() < deadline {
      if case .needsHostKeyConfirm = pane.session.state { pane.session.confirmHostKey(true) }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTAssertEqual(pane.session.state, .connected)
    // The terminal controller observes state on the next main runloop turn.
    await Task.yield()
  }

  private func wait(_ predicate: () -> Bool, timeout: TimeInterval = 10,
                    file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
    XCTAssertTrue(predicate(), file: file, line: line)
    if !predicate() { throw CancellationError() }
  }

  private func menuItem(_ snippet: Snippet) -> NSMenuItem {
    let item = NSMenuItem(title: snippet.name, action: #selector(MainWindowController.insertSnippet(_:)), keyEquivalent: "")
    item.representedObject = snippet.id
    return item
  }

  func test_script_template_preview_and_insertion_require_enter_and_never_persist_parameter_values() async throws {
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let services = AppServices(directory: directory, secrets: InMemorySecretStore())
    let window = MainWindowController(services: services, empty: false)
    defer { window.disconnectAll(); window.close() }
    let pane = try XCTUnwrap(window.focusedPane)
    try await connect(pane, server: server)
    var output = ""
    pane.session.onData = { output += String(decoding: $0, as: UTF8.self) }
    let snippet = try services.snippets.save(name: "脚本模板", command: #"""
      printf '%s%s\n' 'SCRIPT_' '{{suffix}}'
      printf '%s\n' '中文 "quotes" backslash\c'
      cat <<'END'
      literal $HOME
      END
      """#, group: "运维", kind: .script, usesParameters: true)
    let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: ""), marker = "SCRIPT_" + suffix
    window.insertSnippet(menuItem(snippet))
    let preview = try XCTUnwrap(window.snippetInvocation)
    preview.parameterFields["suffix"]?.stringValue = suffix
    preview.refreshPreview()
    XCTAssertTrue(preview.preview.string.contains(suffix))
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertFalse(output.contains(suffix), "opening and editing preview must send nothing")
    XCTAssertTrue(preview.insert())
    XCTAssertNil(window.snippetInvocation)
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertFalse(output.contains(marker), "inserting all script lines must not run the first line")
    pane.session.sendInput(Data("\r".utf8))
    try await wait { output.contains(marker) }
    XCTAssertEqual(try services.snippets.all(), [snippet])
    XCTAssertFalse(try String(contentsOf: directory.appendingPathComponent("snippets.json"), encoding: .utf8).contains(suffix))

    let canceledSuffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    window.insertSnippet(menuItem(snippet))
    let canceled = try XCTUnwrap(window.snippetInvocation)
    canceled.parameterFields["suffix"]?.stringValue = canceledSuffix
    canceled.cancel()
    XCTAssertFalse(canceled.insert())
    let probeSuffix = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    pane.session.sendInput(Data("printf '%s%s\\n' 'PROBE_' '\(probeSuffix)'\r".utf8))
    try await wait { output.contains("PROBE_" + probeSuffix) }
    XCTAssertFalse(output.contains(canceledSuffix))
  }

  func test_preview_rejects_focus_changes_edited_deleted_templates_and_reconnected_transport() async throws {
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let services = AppServices(directory: directory, secrets: InMemorySecretStore())
    let window = MainWindowController(services: services, empty: false)
    defer { window.disconnectAll(); window.close() }
    let pane = try XCTUnwrap(window.focusedPane)
    try await connect(pane, server: server)
    var output = ""
    pane.session.onData = { output += String(decoding: $0, as: UTF8.self) }
    let snippet = try services.snippets.save(name: "Template", command: "printf '%s' '{{value}}'", usesParameters: true)
    let secret = "UNSENT_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    window.insertSnippet(menuItem(snippet))
    let preview = try XCTUnwrap(window.snippetInvocation)
    preview.parameterFields["value"]?.stringValue = secret
    window.newTab(nil)
    XCTAssertFalse(preview.insert())
    XCTAssertFalse(preview.errorLabel.isHidden)
    XCTAssertEqual(preview.parameterFields["value"]?.stringValue, secret)
    window.selectPreviousTab(nil)
    XCTAssertTrue(window.focusedPane === pane)
    try services.snippets.save(id: snippet.id, name: snippet.name, command: "echo '{{value}}'")
    XCTAssertFalse(preview.insert())
    try services.snippets.delete(snippet.id)
    XCTAssertFalse(preview.insert())
    preview.cancel()

    let next = try services.snippets.save(name: "Next", command: "printf '%s' '{{value}}'", usesParameters: true)
    window.insertSnippet(menuItem(next))
    let stale = try XCTUnwrap(window.snippetInvocation)
    stale.parameterFields["value"]?.stringValue = secret
    let oldVersion = pane.session.connectionVersion
    pane.session.disconnect()
    try await connect(pane, server: server)
    // Reconnecting rebuilds the terminal controller and its output callback.
    pane.session.onData = { output += String(decoding: $0, as: UTF8.self) }
    XCTAssertNotEqual(pane.session.connectionVersion, oldVersion)
    XCTAssertFalse(stale.insert())
    XCTAssertEqual(stale.parameterFields["value"]?.stringValue, secret)
    let probe = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    pane.session.sendInput(Data("printf '%s%s\\n' 'CHECK_' '\(probe)'\r".utf8))
    try await wait { output.contains("CHECK_" + probe) }
    XCTAssertFalse(output.contains(secret))
    window.close()
    XCTAssertNil(window.snippetInvocation)
    XCTAssertFalse(stale.insert())
  }

  func test_insert_uses_latest_text_and_only_the_focused_workspace_session() async throws {
    let server = try await TestSSHServer.start()
    addTeardownBlock { await server.stop() }
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let services = AppServices(directory: directory, secrets: InMemorySecretStore())
    let window = MainWindowController(services: services, empty: false)
    defer { window.close() }
    let a = try XCTUnwrap(window.focusedPane)
    try await connect(a, server: server)
    window.newTab(nil)
    let b = try XCTUnwrap(window.focusedPane)
    try await connect(b, server: server)
    var outputA = "", outputB = ""
    a.session.onData = { outputA += String(decoding: $0, as: UTF8.self) }
    b.session.onData = { outputB += String(decoding: $0, as: UTF8.self) }

    let root = try XCTUnwrap(window.window?.contentView)
    let tab = try XCTUnwrap(descendants(root).compactMap { $0 as? TabItemView }.first)
    let container = try XCTUnwrap(descendants(root).compactMap { $0 as? PaneContainerView }.first)
    window.paneContainer(container, drop: TabDragPayload(windowToken: window.token, tabId: tab.item.id),
                         onto: b.id, edge: .right)
    XCTAssertTrue(window.focusedPane === a)
    XCTAssertTrue(a.isInWorkspace)
    XCTAssertTrue(b.isInWorkspace)
    XCTAssertEqual(a.session.state, .connected)
    XCTAssertEqual(b.session.state, .connected)

    let snippet = try services.snippets.save(name: "Marker", command: "printf 'old text'")
    let item = NSMenuItem(title: snippet.name, action: #selector(MainWindowController.insertSnippet(_:)), keyEquivalent: "")
    item.representedObject = snippet.id
    XCTAssertTrue(window.validateMenuItem(item))
    let markerA = "FOCUSED_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    try services.snippets.save(id: snippet.id, name: "Edited", command: "printf '%s%s\\n' 'FOCUSED_' '\(markerA.dropFirst(8))'")
    window.insertSnippet(item)
    try await Task.sleep(nanoseconds: 300_000_000)
    XCTAssertFalse(outputA.contains(markerA))
    a.session.sendInput(Data("\r".utf8))
    let deadlineA = Date().addingTimeInterval(10)
    while !outputA.contains(markerA), Date() < deadlineA { try await Task.sleep(nanoseconds: 50_000_000) }
    XCTAssertTrue(outputA.contains(markerA))
    XCTAssertFalse(outputB.contains(markerA))
    XCTAssertFalse(outputA.contains("old text"))

    // Detaching the focused source leaves focus on the remaining session in the original tab.
    a.actions?.detach(a.id)
    XCTAssertTrue(window.focusedPane === b)
    let markerB = "REMAINING_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    try services.snippets.save(id: snippet.id, name: "Edited", command: "printf '%s%s\\n' 'REMAINING_' '\(markerB.dropFirst(10))'")
    window.insertSnippet(item)
    b.session.sendInput(Data("\r".utf8))
    let deadlineB = Date().addingTimeInterval(10)
    while !outputB.contains(markerB), Date() < deadlineB { try await Task.sleep(nanoseconds: 50_000_000) }
    XCTAssertTrue(outputB.contains(markerB))
    XCTAssertFalse(outputA.contains(markerB))

    // A menu already opened before deletion cannot send the removed command.
    let deletedMarker = "DELETED_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    try services.snippets.save(id: snippet.id, name: "Deleted", command: "printf '%s%s\\n' 'DELETED_' '\(deletedMarker.dropFirst(8))'")
    try services.snippets.delete(snippet.id)
    window.insertSnippet(item)
    // The shell may redraw its prompt after a pane resize. Verify input through an ordered
    // round trip instead of requiring the asynchronous output stream to remain unchanged.
    let probe = "CHECK_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    b.session.sendInput(Data("\rprintf '%s%s\\n' 'CHECK_' '\(probe.dropFirst(6))'\r".utf8))
    let probeDeadline = Date().addingTimeInterval(10)
    while !outputB.contains(probe), Date() < probeDeadline { try await Task.sleep(nanoseconds: 50_000_000) }
    XCTAssertTrue(outputB.contains(probe))
    XCTAssertFalse(outputB.contains(deletedMarker))
    window.newTab(nil)
    XCTAssertFalse(window.validateMenuItem(item))
    window.insertSnippet(item)
    XCTAssertEqual(window.focusedPane?.session.state, .idle)
    window.disconnectAll()
  }
}
