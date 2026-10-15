import AppKit
import Darwin
import XCTest
import SSHCore
@testable import TermesKit
@testable import Termes

@MainActor
final class LocalForwardIntegrationTests: XCTestCase {
  private func wait(_ predicate: () -> Bool, timeout: TimeInterval = 20,
                    file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
    guard predicate() else { XCTFail("timed out", file: file, line: line); throw CancellationError() }
  }

  private func connect(_ pane: SessionPaneController, server: TestSSHServer) async throws {
    pane.connect(.init(hostname: server.host, port: server.port, username: server.username,
                       auth: .password(server.password)), label: .init(name: "Forward test", username: "test"))
    try await wait {
      if case .needsHostKeyConfirm = pane.session.state { pane.session.confirmHostKey(true) }
      return pane.session.state == .connected
    }
  }

  private func availablePort() throws -> Int {
    let fd = try ForwardTestSocket.listener()
    defer { Darwin.close(fd) }
    return try ForwardTestSocket.boundPort(fd).port
  }

  func test_management_window_is_per_pane_and_closing_pane_stops_forward() async throws {
    _ = NSApplication.shared
    let server = try await TestSSHServer.start()
    addTeardownBlock { await server.stop() }
    try await server.enableTCPForwarding()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let services = AppServices(directory: directory, secrets: InMemorySecretStore())
    let window = MainWindowController(services: services, empty: false)
    defer { window.disconnectAll(); window.close() }
    let pane = try XCTUnwrap(window.focusedPane)
    try await connect(pane, server: server)
    let port = try availablePort()
    let id = try pane.session.portForwards.save(configuration: .init(localPort: port, targetHost: "localhost", targetPort: 2222))
    pane.session.portForwards.start(id)
    try await wait { if case .running = pane.session.portForwards.rules[0].state { return true }; return false }
    window.manageLocalForwards(nil)
    let managerWindow = try XCTUnwrap(pane.forwardWindow)
    managerWindow.close()
    XCTAssertEqual(pane.session.state, .connected)
    let response = try await ForwardTestSocket.exchange(port: port, data: Data())
    XCTAssertTrue(String(decoding: response, as: UTF8.self).contains("SSH-"))
    window.manageLocalForwards(nil)
    XCTAssertTrue(pane.forwardWindow === managerWindow)
    window.newTab(nil)
    let other = try XCTUnwrap(window.focusedPane)
    window.manageLocalForwards(nil)
    XCTAssertFalse(other.forwardWindow === managerWindow)
    XCTAssertTrue(other.session.portForwards.rules.isEmpty)
    pane.close()
    try await wait { pane.session.portForwards.rules[0].state == .stopped }
    XCTAssertNil(pane.forwardWindow)
    XCTAssertFalse(pane.session.portForwards.isConnected)
    XCTAssertThrowsError(try ForwardTestSocket.open(port: port))
  }

  func test_terminal_reconnect_stops_forward_and_requires_manual_restart() async throws {
    let server = try await TestSSHServer.start()
    addTeardownBlock { await server.stop() }
    try await server.enableTCPForwarding()
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: file) }
    let manager = SessionManager(knownHosts: KnownHostsStore(fileURL: file))
    defer { manager.disconnect() }
    let config = ConnectionConfig(hostname: server.host, port: server.port, username: "test", auth: .password("test"))
    let connection = Task { await manager.connect(config) }
    try await wait {
      if case .needsHostKeyConfirm = manager.state { manager.confirmHostKey(true) }
      return manager.state == .connected
    }
    await connection.value
    let port = try availablePort()
    let id = try manager.portForwards.save(configuration: .init(localPort: port, targetHost: "localhost", targetPort: 2222))
    manager.portForwards.start(id)
    try await wait { if case .running = manager.portForwards.rules[0].state { return true }; return false }
    await server.drop()
    try await wait({ if case .reconnecting = manager.state { return true }; return false }, timeout: 30)
    try await wait { manager.portForwards.rules[0].state == .stopped || manager.portForwards.rules[0].canEdit }
    XCTAssertThrowsError(try ForwardTestSocket.open(port: port))
    try await server.restart()
    try await server.enableTCPForwarding()
    manager.wakeReconnect()
    try await wait({ manager.state == .connected }, timeout: 30)
    XCTAssertTrue(manager.portForwards.rules[0].canEdit)
    XCTAssertThrowsError(try ForwardTestSocket.open(port: port))
    manager.portForwards.start(id)
    try await wait { if case .running = manager.portForwards.rules[0].state { return true }; return false }
    let fd = try ForwardTestSocket.open(port: port)
    Darwin.close(fd)
    manager.disconnect()
    try await wait { manager.portForwards.rules[0].state == .stopped }
    XCTAssertThrowsError(try ForwardTestSocket.open(port: port))
  }

  func test_fresh_app_services_restore_for_same_destination_without_opening_port() async throws {
    let server = try await TestSSHServer.start()
    addTeardownBlock { await server.stop() }
    try await server.enableTCPForwarding()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let services = AppServices(directory: directory, secrets: InMemorySecretStore())
    let presetsFile = directory.appendingPathComponent("local-forwards.json")
    try Data("broken".utf8).write(to: presetsFile)
    let first = services.makeSession()
    defer { first.disconnect() }
    let config = ConnectionConfig(hostname: server.host, port: server.port, username: "test", auth: .password("test"))
    let initial = Task { await first.connect(config) }
    try await wait {
      if case .needsHostKeyConfirm = first.state { first.confirmHostKey(true) }
      return first.state == .connected
    }
    await initial.value
    XCTAssertNotNil(first.portForwards.storageError, "a corrupt preset file must not prevent the SSH terminal connecting")
    XCTAssertEqual(try Data(contentsOf: presetsFile), Data("broken".utf8))
    try FileManager.default.removeItem(at: presetsFile)
    first.portForwards.reloadSavedRules()
    XCTAssertNil(first.portForwards.storageError)
    let port = try availablePort()
    let rule = LocalForwardConfiguration(localPort: port, targetHost: "localhost", targetPort: 2222)
    let id = try first.portForwards.save(configuration: rule)
    first.portForwards.start(id)
    try await wait { !first.portForwards.rules[0].canEdit }
    first.disconnect()
    try await wait { first.portForwards.rules[0].state == .stopped }
    let restarted = AppServices(directory: directory, secrets: InMemorySecretStore()).makeSession()
    defer { restarted.disconnect() }
    await restarted.connect(config)
    XCTAssertEqual(restarted.state, .connected)
    XCTAssertEqual(restarted.portForwards.rules.map(\.id), [id])
    XCTAssertEqual(restarted.portForwards.rules[0].state, .stopped)
    XCTAssertThrowsError(try ForwardTestSocket.open(port: port))
    restarted.portForwards.start(id)
    try await wait { if case .running = restarted.portForwards.rules[0].state { return true }; return false }
    let response = try await ForwardTestSocket.exchange(port: port, data: Data())
    XCTAssertTrue(String(decoding: response, as: UTF8.self).contains("SSH-"))
    restarted.disconnect()
    // Connecting to another SSH port must not carry the old target's rules over.
    await restarted.connect(.init(hostname: server.host, port: 1, username: "test", auth: .password("test")))
    XCTAssertTrue(restarted.portForwards.rules.isEmpty)
    XCTAssertEqual(restarted.portForwards.destination?.port, 1)
    XCTAssertEqual(try LocalForwardStore(fileURL: directory.appendingPathComponent("local-forwards.json"))
      .rules(for: .init(config: config)).map(\.id), [id])
  }
}
