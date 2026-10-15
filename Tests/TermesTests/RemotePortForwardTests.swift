import AppKit
import Darwin
import XCTest
import SSHCore
@testable import TermesKit
@testable import Termes

private final class RemoteStubForward: LocalForwarding, @unchecked Sendable {
  let localPort = 37111
  let events: AsyncStream<LocalForwardEvent>
  private let continuation: AsyncStream<LocalForwardEvent>.Continuation
  init() { (events, continuation) = AsyncStream.makeStream() }
  func stop() async { continuation.finish() }
}

@MainActor
final class RemotePortForwardTests: XCTestCase {
  private func wait(_ predicate: () -> Bool, timeout: TimeInterval = 20,
                    file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = Date().addingTimeInterval(timeout)
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
  private func popup(_ popup: NSPopUpButton, index: Int) throws {
    popup.selectItem(at: index)
    XCTAssertTrue(popup.sendAction(try XCTUnwrap(popup.action), to: popup.target))
  }
  private func port() throws -> Int {
    let fd = try ForwardTestSocket.listener(); defer { Darwin.close(fd) }
    return try ForwardTestSocket.boundPort(fd).port
  }

  func test_remote_form_bind_draft_conflict_persistence_and_minimum_layout() async throws {
    _ = NSApplication.shared
    let file = try directory().appendingPathComponent("local-forwards.json")
    let store = LocalForwardStore(fileURL: file)
    let destination = LocalForwardDestination(hostname: "server", port: 22, username: "test")
    let a = LocalForwardManager(store: store) { _ in RemoteStubForward() }
    let b = LocalForwardManager(store: store) { _ in RemoteStubForward() }
    await a.bindDestination(destination); await b.bindDestination(destination)
    let controller = LocalForwardViewController(model: a)
    let window = NSWindow(contentViewController: controller)
    window.isReleasedWhenClosed = false; defer { a.stopAll(); window.close() }
    try popup(controller.kindPopup, index: 2)
    controller.listenHostField.selectItem(at: 1)
    controller.comboBoxSelectionDidChange(Notification(name: NSComboBox.selectionDidChangeNotification))
    controller.localPortField.stringValue = "37111"
    controller.targetHostField.stringValue = "localhost"
    controller.targetPortField.stringValue = "invalid"
    XCTAssertFalse(controller.saveChanges())
    XCTAssertFalse(controller.listenHostField.isHidden)
    controller.targetPortField.stringValue = "8080"
    XCTAssertTrue(controller.saveChanges())
    let id = try XCTUnwrap(controller.editingID)
    let rule = LocalForwardConfiguration(localPort: 37111, targetHost: "localhost", targetPort: 8080, kind: .remote, listenHost: "::1")
    XCTAssertEqual(a.rules[0].configuration, rule)
    XCTAssertEqual(try LocalForwardStore(fileURL: file).rules(for: destination)[0].configuration, rule)
    for size in [NSSize(width: 600, height: 430), NSSize(width: 900, height: 600)] {
      window.setContentSize(size); controller.view.layoutSubtreeIfNeeded()
      for control in descendants(controller.view).compactMap({ $0 as? NSControl }).filter({ !$0.isHiddenOrHasHiddenAncestor }) {
        let rect = control.convert(control.bounds, to: controller.view)
        XCTAssertGreaterThan(rect.width, 0)
        XCTAssertGreaterThanOrEqual(rect.minX, -0.5); XCTAssertLessThanOrEqual(rect.maxX, size.width + 0.5)
        XCTAssertGreaterThanOrEqual(rect.minY, -0.5); XCTAssertLessThanOrEqual(rect.maxY, size.height + 0.5)
      }
    }
    a.setConnected(true); a.start(id)
    try await wait { if case .running = a.rules[0].state { return true }; return false }
    try await wait { !controller.listenHostField.isEnabled }
    XCTAssertFalse(controller.kindPopup.isEnabled)
    a.stop(id)
    try await wait { a.rules[0].state == .stopped && controller.listenHostField.isEnabled }
    controller.localPortField.stringValue = "37112"
    b.reloadSavedRules()
    let changed = LocalForwardConfiguration(localPort: 37113, targetHost: "localhost", targetPort: 80, kind: .remote, listenHost: "192.0.2.77")
    _ = try b.save(id: id, configuration: changed, expected: rule)
    try await wait { a.rules[0].configuration == changed }
    XCTAssertEqual(controller.listenHostField.stringValue, "::1")
    XCTAssertEqual(controller.localPortField.stringValue, "37112")
    XCTAssertFalse(controller.saveChanges())
    XCTAssertTrue(controller.table.sendAction(try XCTUnwrap(controller.table.action), to: controller.table.target))
    XCTAssertEqual(controller.listenHostField.stringValue, "192.0.2.77")
    try popup(controller.kindPopup, index: 0)
    XCTAssertTrue(controller.listenHostField.isHidden)
    XCTAssertTrue(controller.saveChanges())
    XCTAssertEqual(a.rules[0].configuration.kind, .local)
    XCTAssertEqual(a.rules[0].configuration.listenHost, "127.0.0.1")
    try popup(controller.kindPopup, index: 2)
    XCTAssertEqual(controller.listenHostField.stringValue, "192.0.2.77", "type changes retain the bind-address draft")
    controller.listenHostField.stringValue = "invalid address"
    XCTAssertFalse(controller.saveChanges())
    XCTAssertEqual(controller.listenHostField.stringValue, "invalid address")
    controller.listenHostField.stringValue = "192.0.2.55"
    XCTAssertTrue(controller.saveChanges())
    XCTAssertEqual(try LocalForwardStore(fileURL: file).rules(for: destination)[0].configuration.listenHost, "192.0.2.55")
  }

  func test_real_buttons_remote_service_disconnect_and_restart_restoration() async throws {
    _ = NSApplication.shared
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    try await server.enableTCPForwarding()
    let service = try ForwardTestService { fd in
      _ = try ForwardTestSocket.readToEOF(fd)
      try ForwardTestSocket.write(fd, data: Data("本机响应".utf8))
    }
    addTeardownBlock { service.stop() }
    let directory = try directory(), services = AppServices(directory: directory, secrets: InMemorySecretStore())
    let window = MainWindowController(services: services, empty: false)
    defer { window.disconnectAll(); window.close() }
    let pane = try XCTUnwrap(window.focusedPane)
    let config = ConnectionConfig(hostname: server.host, port: server.port, username: server.username, auth: .password(server.password))
    pane.connect(config, label: .init(name: "远端转发服务器", username: server.username))
    try await wait {
      if case .needsHostKeyConfirm = pane.session.state { pane.session.confirmHostKey(true) }
      return pane.session.state == .connected
    }
    window.manageLocalForwards(nil)
    let managerWindow = try XCTUnwrap(pane.forwardWindow?.window)
    let controller = try XCTUnwrap(managerWindow.contentViewController as? LocalForwardViewController)
    try popup(controller.kindPopup, index: 2)
    controller.localPortField.stringValue = "37111"
    controller.targetHostField.stringValue = "localhost"
    controller.targetPortField.stringValue = String(service.port)
    func button(_ title: String) throws -> NSButton {
      try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.title == title })
    }
    try button("保存规则").performClick(nil)
    let id = try XCTUnwrap(controller.editingID)
    try button("启动").performClick(nil)
    try await wait { if case .running = pane.session.portForwards.rules[0].state { return true }; return false }
    let clientPort = try port()
    let bridgeID = try pane.session.portForwards.save(configuration: .init(localPort: clientPort, targetHost: "127.0.0.1", targetPort: 37111))
    pane.session.portForwards.start(bridgeID)
    try await wait { pane.session.portForwards.rules.allSatisfy { if case .running = $0.state { return true }; return false } }
    managerWindow.close()
    let response = try await ForwardTestSocket.exchange(port: clientPort, data: Data("request".utf8))
    XCTAssertEqual(response, Data("本机响应".utf8))
    pane.session.disconnect()
    try await wait { pane.session.portForwards.rules.allSatisfy { $0.state == .stopped } }
    XCTAssertThrowsError(try ForwardTestSocket.open(port: clientPort))
    let restored = AppServices(directory: directory, secrets: InMemorySecretStore()).makeSession()
    defer { restored.disconnect() }
    await restored.connect(config)
    XCTAssertEqual(restored.state, .connected)
    XCTAssertEqual(restored.portForwards.rules.map(\.id), [id, bridgeID])
    XCTAssertEqual(restored.portForwards.rules[0].configuration.kind, .remote)
    XCTAssertEqual(restored.portForwards.rules[0].configuration.listenHost, "127.0.0.1")
    XCTAssertTrue(restored.portForwards.rules.allSatisfy { $0.state == .stopped })
    restored.portForwards.start(id); restored.portForwards.start(bridgeID)
    try await wait { restored.portForwards.rules.allSatisfy { if case .running = $0.state { return true }; return false } }
    let again = try await ForwardTestSocket.exchange(port: clientPort, data: Data())
    XCTAssertEqual(again, Data("本机响应".utf8))
  }

  func test_reconnect_requires_manual_remote_restart_and_pane_close_stops_it() async throws {
    _ = NSApplication.shared
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    try await server.enableTCPForwarding()
    let service = try ForwardTestService { fd in
      _ = try ForwardTestSocket.readToEOF(fd)
      try ForwardTestSocket.write(fd, data: Data("reconnected".utf8))
    }
    addTeardownBlock { service.stop() }
    let dataDirectory = try directory()
    let services = AppServices(directory: dataDirectory, secrets: InMemorySecretStore())
    let window = MainWindowController(services: services, empty: false)
    defer { window.disconnectAll(); window.close() }
    let pane = try XCTUnwrap(window.focusedPane), session = pane.session
    pane.connect(.init(hostname: server.host, port: server.port, username: server.username, auth: .password(server.password)),
      label: .init(name: "Reconnect remote", username: server.username))
    try await wait {
      if case .needsHostKeyConfirm = session.state { session.confirmHostKey(true) }
      return session.state == .connected
    }
    let id = try session.portForwards.save(configuration: .init(localPort: 37111, targetHost: "localhost", targetPort: service.port, kind: .remote))
    session.portForwards.start(id)
    try await wait { if case .running = session.portForwards.rules[0].state { return true }; return false }
    await server.drop()
    try await wait({ if case .reconnecting = session.state { return true }; return false }, timeout: 30)
    try await wait { session.portForwards.rules[0].canEdit }
    try await server.restart(); try await server.enableTCPForwarding()
    session.wakeReconnect()
    try await wait({ session.state == .connected }, timeout: 30)
    XCTAssertTrue(session.portForwards.rules[0].canEdit, "a stopped rule may retain its transport failure before terminal reconnect")
    let probeConfig = ConnectionConfig(hostname: server.host, port: server.port, username: server.username, auth: .password(server.password))
    let probe = try await RemotePortForward.start(config: probeConfig,
      knownHosts: KnownHostsStore(fileURL: dataDirectory.appendingPathComponent("known_hosts.json")),
      forwarding: .init(localPort: 37111, targetHost: "localhost", targetPort: service.port, kind: .remote))
    await probe.stop() // Claiming the same server port proves reconnect did not reopen it.
    session.portForwards.start(id)
    try await wait { if case .running = session.portForwards.rules[0].state { return true }; return false }
    pane.showLocalForwards()
    pane.close()
    try await wait { session.portForwards.rules[0].state == .stopped }
    XCTAssertNil(pane.forwardWindow)
    // A new owner can immediately claim the same server port after the pane is closed.
    let config = ConnectionConfig(hostname: server.host, port: server.port, username: server.username, auth: .password(server.password))
    let replacement = try await RemotePortForward.start(config: config,
      knownHosts: KnownHostsStore(fileURL: dataDirectory.appendingPathComponent("known_hosts.json")),
      forwarding: .init(localPort: 37111, targetHost: "localhost", targetPort: service.port, kind: .remote))
    await replacement.stop()
  }
}
