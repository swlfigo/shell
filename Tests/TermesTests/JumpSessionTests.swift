import AppKit
import XCTest
import SSHCore
@testable import TermesKit
@testable import Termes

@MainActor
final class JumpSessionTests: XCTestCase {
  private func directory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return directory
  }
  private func wait(_ predicate: () -> Bool, timeout: TimeInterval = 15,
                    file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(15)) }
    guard predicate() else { XCTFail("timed out", file: file, line: line); throw CancellationError() }
  }
  private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
  private func servers() async throws -> (TestSSHServer, TestSSHServer) {
    let jump = try await TestSSHServer.start(); addTeardownBlock { await jump.stop() }
    let target = try await TestSSHServer.start(); addTeardownBlock { await target.stop() }
    try await jump.enableTCPForwarding()
    try await jump.mapHost("session-target.invalid", to: target)
    return (jump, target)
  }
  private func config(_ jump: TestSSHServer) -> ConnectionConfig {
    .init(hostname: "session-target.invalid", port: 2222, username: "test", auth: .password("test"),
      jumpHosts: [.init(hostname: jump.host, port: jump.port, username: "test", auth: .password("test"))])
  }
  private func trust(_ manager: SessionManager, task: Task<Void, Never>) async throws {
    for _ in 0..<2 {
      try await wait { if case .needsHostKeyConfirm = manager.state { return true }; return false }
      manager.confirmHostKey(true)
    }
    await task.value
    XCTAssertEqual(manager.state, .connected)
  }

  func test_saved_jump_connect_button_and_trust_banner_identify_each_actual_server() async throws {
    _ = NSApplication.shared
    let (jump, _) = try await servers(), dir = try directory()
    let profiles = ConnectionProfileService(connections: ConnectionStore(fileURL: dir.appendingPathComponent("connections.json")),
      keys: KeyStore(fileURL: dir.appendingPathComponent("keys.json")), secrets: InMemorySecretStore())
    let jumpProfile = try profiles.saveConnection(name: "入口服务器", hostname: jump.host, port: jump.port, username: "test", credential: .password("test"))
    let target = try profiles.saveConnection(name: "内网服务器", hostname: "session-target.invalid", port: 2222, username: "test",
      credential: .password("test"), jumpProfileId: jumpProfile.id)
    let manager = SessionManager(knownHosts: KnownHostsStore(fileURL: dir.appendingPathComponent("known.json")))
    defer { manager.disconnect() }
    var label: SessionLabel?
    let page = ConnectViewController(session: manager, profiles: profiles, onLabel: { label = $0 })
    let controls = descendants(page.view)
    let saved = try XCTUnwrap(controls.compactMap { $0 as? NSPopUpButton }.first { $0.action == NSSelectorFromString("savedChanged") })
    saved.selectItem(withTitle: target.name)
    XCTAssertTrue(saved.sendAction(try XCTUnwrap(saved.action), to: saved.target))
    try XCTUnwrap(controls.compactMap { $0 as? NSButton }.first { $0.title == "连接" }).performClick(nil)
    let terminal = TerminalViewController(session: manager)
    let bannerControls = descendants(terminal.view)
    let trustButton = try XCTUnwrap(bannerControls.compactMap { $0 as? NSButton }.first { $0.title == "信任" })
    for expected in ["127.0.0.1:\(jump.port)", "session-target.invalid:2222"] {
      try await wait { if case .needsHostKeyConfirm = manager.state { return true }; return false }
      let endpoint = try XCTUnwrap(manager.pendingHostKeyEndpoint)
      XCTAssertEqual("\(endpoint.hostname):\(endpoint.port)", expected)
      terminal.apply(manager.state)
      let labels = bannerControls.compactMap { $0 as? NSTextField }.filter { !$0.isHiddenOrHasHiddenAncestor }
      XCTAssertTrue(labels.contains { $0.stringValue.contains("首次连接 " + expected) })
      trustButton.performClick(nil)
    }
    try await wait { manager.state == .connected }
    XCTAssertEqual(label, SessionLabel(name: "内网服务器", username: "test", profileID: target.id))
    XCTAssertEqual(manager.currentConfig?.jumpHosts.count, 1)
    XCTAssertNil(manager.pendingHostKeyEndpoint)
    let client = try await manager.openSFTP()
    let home = try await client.canonicalPath(".")
    XCTAssertFalse(home.isEmpty)
    await client.close()
    terminal.teardown()
  }

  func test_disconnect_during_destination_trust_clears_the_prompt_and_can_connect_again() async throws {
    let (jump, _) = try await servers(), dir = try directory()
    let known = KnownHostsStore(fileURL: dir.appendingPathComponent("known.json"))
    let manager = SessionManager(knownHosts: known)
    let config = config(jump)
    let task = Task { await manager.connect(config) }
    try await wait { manager.pendingHostKeyEndpoint?.hostname == jump.host }
    manager.confirmHostKey(true)
    try await wait { manager.pendingHostKeyEndpoint?.hostname == config.hostname }
    let start = Date(); manager.disconnect(); await task.value
    XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    XCTAssertEqual(manager.state, .disconnected)
    XCTAssertNil(manager.pendingHostKeyEndpoint)
    XCTAssertNil(manager.currentConfig)
    XCTAssertEqual(try known.all().count, 1)
    let next = Task { await manager.connect(config) }
    try await wait { manager.pendingHostKeyEndpoint?.hostname == config.hostname }
    manager.confirmHostKey(true); await next.value
    XCTAssertEqual(manager.state, .connected)
    manager.disconnect()
  }

  func test_jump_transport_loss_reconnects_the_route_and_changed_jump_key_is_permanent() async throws {
    let (jump, target) = try await servers(), dir = try directory()
    let manager = SessionManager(knownHosts: KnownHostsStore(fileURL: dir.appendingPathComponent("known.json")))
    defer { manager.disconnect() }
    manager.resize(cols: 112, rows: 31)
    let configuration = config(jump)
    try await trust(manager, task: Task { await manager.connect(configuration) })
    var output = ""
    manager.onData = { output += String(decoding: $0, as: UTF8.self) }
    await jump.drop()
    try await wait { if case .reconnecting = manager.state { return true }; return false }
    try await jump.restart()
    try await jump.enableTCPForwarding()
    try await jump.mapHost(configuration.hostname, to: target)
    manager.wakeReconnect()
    try await wait { manager.state == .connected }
    XCTAssertEqual(manager.currentConfig, configuration)
    manager.sendInput(Data("printf 'JUMP_RECONNECTED'; stty size\r".utf8))
    try await wait { output.contains("JUMP_RECONNECTED") && output.contains("31 112") }
    let client = try await manager.openSFTP()
    _ = try await client.listDirectory(".")
    await client.close()
    await jump.drop()
    try await wait { if case .reconnecting = manager.state { return true }; return false }
    try await jump.restart(differentHostKey: true)
    manager.wakeReconnect()
    try await wait { if case .failed = manager.state { return true }; return false }
    XCTAssertNil(manager.currentConfig)
    XCTAssertNil(manager.pendingHostKeyEndpoint)
  }
}
