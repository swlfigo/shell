import AppKit
import Darwin
import XCTest
import SSHCore
import TermesKit
@testable import Termes

private final class SOCKSStubForward: LocalForwarding, @unchecked Sendable {
  let localPort = 1080
  let events: AsyncStream<LocalForwardEvent>
  private let continuation: AsyncStream<LocalForwardEvent>.Continuation
  init() { (events, continuation) = AsyncStream.makeStream() }
  func stop() async { continuation.finish() }
}

@MainActor
final class SOCKSForwardTests: XCTestCase {
  private func wait(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = Date().addingTimeInterval(20)
    while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(15)) }
    guard predicate() else { XCTFail("timed out", file: file, line: line); throw CancellationError() }
  }
  private func directory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return directory
  }
  private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
  private func setKind(_ controller: LocalForwardViewController, index: Int) throws {
    controller.kindPopup.selectItem(at: index)
    XCTAssertTrue(controller.kindPopup.sendAction(try XCTUnwrap(controller.kindPopup.action), to: controller.kindPopup.target))
  }

  func test_editor_saves_socks_with_port_only_preserves_drafts_and_locks_running_kind() async throws {
    _ = NSApplication.shared
    let model = LocalForwardManager { _ in SOCKSStubForward() }
    let controller = LocalForwardViewController(model: model)
    _ = controller.view
    controller.localPortField.stringValue = "1080"
    controller.targetHostField.stringValue = "draft.internal"
    controller.targetPortField.stringValue = "invalid-draft"
    try setKind(controller, index: 1)
    XCTAssertFalse(controller.targetHostField.isEnabled)
    XCTAssertFalse(controller.targetPortField.isEnabled)
    XCTAssertTrue(controller.saveChanges())
    XCTAssertEqual(model.rules[0].configuration, .init(localPort: 1080, kind: .socks))
    XCTAssertEqual(controller.targetHostField.stringValue, "draft.internal")
    let id = try XCTUnwrap(controller.editingID)
    model.setConnected(true); model.start(id)
    try await wait { if case .running = model.rules[0].state { return true }; return false }
    try await wait { !controller.kindPopup.isEnabled }
    XCTAssertThrowsError(try model.save(id: id, configuration: .init(localPort: 1081, kind: .socks)))
    model.stop(id)
    try await wait { model.rules[0].state == .stopped && controller.kindPopup.isEnabled }
    try setKind(controller, index: 0)
    XCTAssertTrue(controller.targetHostField.isEnabled)
    XCTAssertEqual(controller.targetHostField.stringValue, "draft.internal")
    XCTAssertFalse(controller.saveChanges())
    controller.targetPortField.stringValue = "80"
    XCTAssertTrue(controller.saveChanges())
    XCTAssertEqual(model.rules[0].id, id)
    XCTAssertEqual(model.rules[0].configuration.kind, .local)
  }

  func test_legacy_store_kind_round_trip_and_cross_window_conflict_preserve_file_and_draft() async throws {
    _ = NSApplication.shared
    let file = try directory().appendingPathComponent("local-forwards.json")
    let destination = LocalForwardDestination(hostname: "server", port: 22, username: "test")
    let local = LocalForwardConfiguration(localPort: 8080, targetHost: "localhost", targetPort: 80)
    let store = LocalForwardStore(fileURL: file)
    let item = try store.save(destination: destination, configuration: local)
    var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    var rows = try XCTUnwrap(document["rules"] as? [[String: Any]])
    var config = try XCTUnwrap(rows[0]["configuration"] as? [String: Any])
    config.removeValue(forKey: "kind"); rows[0]["configuration"] = config; document["rules"] = rows
    let legacy = try JSONSerialization.data(withJSONObject: document)
    try legacy.write(to: file)
    XCTAssertEqual(try store.rules(for: destination)[0].configuration, local)
    XCTAssertEqual(try Data(contentsOf: file), legacy, "reading old presets must not rewrite the file")
    let a = LocalForwardManager(store: store) { _ in XCTFail("restoration must not start"); return SOCKSStubForward() }
    let b = LocalForwardManager(store: store) { _ in SOCKSStubForward() }
    await a.bindDestination(destination); await b.bindDestination(destination)
    let controller = LocalForwardViewController(model: a)
    _ = controller.view
    controller.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    controller.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
    try setKind(controller, index: 1)
    controller.localPortField.stringValue = "1080"
    XCTAssertTrue(controller.saveChanges())
    let socks = LocalForwardConfiguration(localPort: 1080, kind: .socks)
    let fresh = LocalForwardManager(store: LocalForwardStore(fileURL: file)) { _ in XCTFail("restoration must not start"); return SOCKSStubForward() }
    await fresh.bindDestination(destination)
    fresh.setConnected(true)
    XCTAssertEqual(fresh.rules[0].id, item.id)
    XCTAssertEqual(fresh.rules[0].configuration, socks)
    XCTAssertEqual(fresh.rules[0].state, .stopped)
    controller.localPortField.stringValue = "1081"
    b.reloadSavedRules()
    _ = try b.save(id: item.id, configuration: local, expected: socks)
    try await wait { a.rules[0].configuration == local }
    XCTAssertEqual(controller.kindPopup.indexOfSelectedItem, 1)
    XCTAssertEqual(controller.localPortField.stringValue, "1081")
    XCTAssertFalse(controller.saveChanges())
    XCTAssertEqual(try store.rules(for: destination)[0].configuration, local)
    XCTAssertTrue(controller.table.sendAction(try XCTUnwrap(controller.table.action), to: controller.table.target))
    XCTAssertEqual(controller.kindPopup.indexOfSelectedItem, 0)
    config["kind"] = "future"; rows[0]["configuration"] = config; document["rules"] = rows
    let invalid = try JSONSerialization.data(withJSONObject: document)
    try invalid.write(to: file)
    XCTAssertThrowsError(try store.save(destination: destination, configuration: socks))
    XCTAssertEqual(try Data(contentsOf: file), invalid)
  }

  func test_real_session_buttons_proxy_response_disconnect_and_restart_restoration() async throws {
    _ = NSApplication.shared
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    try await server.enableTCPForwarding()
    let directory = try directory()
    let services = AppServices(directory: directory, secrets: InMemorySecretStore())
    let window = MainWindowController(services: services, empty: false)
    defer { window.disconnectAll(); window.close() }
    let pane = try XCTUnwrap(window.focusedPane)
    let config = ConnectionConfig(hostname: server.host, port: server.port, username: server.username, auth: .password(server.password))
    pane.connect(config, label: .init(name: "SOCKS 测试服务器", username: server.username))
    try await wait {
      if case .needsHostKeyConfirm = pane.session.state { pane.session.confirmHostKey(true) }
      return pane.session.state == .connected
    }
    window.manageLocalForwards(nil)
    let managerWindow = try XCTUnwrap(pane.forwardWindow?.window)
    let controller = try XCTUnwrap(managerWindow.contentViewController as? LocalForwardViewController)
    let reservation = try ForwardTestSocket.listener()
    let port = try ForwardTestSocket.boundPort(reservation).port; Darwin.close(reservation)
    controller.localPortField.stringValue = String(port)
    try setKind(controller, index: 1)
    func button(_ title: String) throws -> NSButton {
      try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.title == title })
    }
    try button("保存规则").performClick(nil)
    let id = try XCTUnwrap(controller.editingID)
    try button("启动").performClick(nil)
    try await wait { if case .running = pane.session.portForwards.rules[0].state { return true }; return false }
    managerWindow.close()
    let response = try await ForwardTestSocket.socksExchange(port: port, host: "localhost", targetPort: 2222)
    XCTAssertTrue(String(decoding: response, as: UTF8.self).contains("SSH-"))
    pane.session.disconnect()
    try await wait { pane.session.portForwards.rules[0].state == .stopped }
    XCTAssertThrowsError(try ForwardTestSocket.open(port: port))
    let restored = AppServices(directory: directory, secrets: InMemorySecretStore()).makeSession()
    defer { restored.disconnect() }
    await restored.connect(config)
    XCTAssertEqual(restored.state, .connected)
    XCTAssertEqual(restored.portForwards.rules.map(\.id), [id])
    XCTAssertEqual(restored.portForwards.rules[0].configuration, .init(localPort: port, kind: .socks))
    XCTAssertEqual(restored.portForwards.rules[0].state, .stopped)
    XCTAssertThrowsError(try ForwardTestSocket.open(port: port))
  }
}
