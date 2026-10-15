import Foundation
import XCTest
import SSHCore
@testable import TermesKit

@MainActor
final class ServerMonitorIntegrationTests: XCTestCase {
  private func wait(_ predicate: () -> Bool, timeout: TimeInterval = 15,
                    file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
    guard predicate() else { XCTFail("timed out", file: file, line: line); throw CancellationError() }
  }
  private func fixture() async throws -> (TestSSHServer, SessionManager) {
    let server = try await TestSSHServer.start()
    addTeardownBlock { await server.stop() }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    let manager = SessionManager(knownHosts: KnownHostsStore(fileURL: url))
    addTeardownBlock { @MainActor in manager.serverMonitor.close(); manager.disconnect() }
    let config = ConnectionConfig(hostname: server.host, port: server.port, username: server.username, auth: .password(server.password))
    let opening = Task { await manager.connect(config) }
    try await wait {
      if case .needsHostKeyConfirm = manager.state { manager.confirmHostKey(true) }
      return manager.state == .connected
    }
    await opening.value
    return (server, manager)
  }
  private func connections(_ server: TestSSHServer) async throws -> Int {
    let text = try await server.execute(["sh", "-c", "netstat -tn | awk '$4 ~ /:2222$/ && $6 == \"ESTABLISHED\" {c++} END {print c+0}'"])
    return try XCTUnwrap(Int(text.trimmingCharacters(in: .whitespacesAndNewlines)))
  }
  private func waitConnections(_ count: Int, server: TestSSHServer) async throws {
    let deadline = Date().addingTimeInterval(5)
    var value = try await connections(server)
    while value != count, Date() < deadline {
      try await Task.sleep(nanoseconds: 20_000_000); value = try await connections(server)
    }
    XCTAssertEqual(value, count)
  }

  func test_sampling_reuses_transport_pause_resume_and_disconnect_preserve_independent_terminal_and_files() async throws {
    let (server, manager) = try await fixture(), model = manager.serverMonitor
    var output = ""
    manager.onData = { output += String(decoding: $0, as: UTF8.self) }
    try await waitConnections(1, server: server)
    model.open()
    try await wait { model.history.count == 2 }
    XCTAssertNotNil(model.current?.cpu.value)
    XCTAssertTrue((model.current?.network.value ?? []).allSatisfy { $0.receivedBytesPerSecond.value != nil })
    try await waitConnections(2, server: server)
    let files = try await manager.openSFTP()
    addTeardownBlock { await files.close() }
    let home = try await files.canonicalPath("."); let list = try await files.listDirectory(home)
    XCTAssertFalse(list.isEmpty)
    manager.sendInput(Data("printf '%s%s\\n' 'MONITOR_' 'SESSION_OK'\r".utf8))
    try await wait { output.contains("MONITOR_SESSION_OK") }
    XCTAssertFalse(output.contains("TERMESMON1:")); XCTAssertFalse(output.contains("MemTotal:"))
    model.pause(); XCTAssertTrue(model.isStale)
    try await waitConnections(2, server: server)
    let moreFiles = try await files.listDirectory(home); XCTAssertEqual(moreFiles.count, list.count)
    await files.close(); try await waitConnections(1, server: server)
    let segment = model.history.last?.segment
    model.resume()
    try await wait { model.history.count == 3 }
    XCTAssertEqual(model.current?.cpu, .unavailable(.waitingForBaseline))
    XCTAssertNotEqual(model.history.last?.segment, segment)
    let direct = try await manager.openMonitoringClient()
    let sample = try await direct.sample(); XCTAssertNotNil(sample.memory.value)
    manager.disconnect()
    XCTAssertEqual(model.state, .disconnected); XCTAssertTrue(model.isStale)
    XCTAssertEqual(model.history.count, 3)
    try await waitConnections(0, server: server)
    do { _ = try await direct.sample(); XCTFail("session disconnect must close direct clients too") }
    catch { XCTAssertEqual(error as? SSHError, .disconnected) }
    model.close(); XCTAssertNil(model.current); XCTAssertTrue(model.history.isEmpty)
  }

  func test_terminal_reconnect_keeps_history_but_restarts_monitor_with_a_new_baseline() async throws {
    let (server, manager) = try await fixture(), model = manager.serverMonitor
    model.open(); try await wait { model.history.count == 1 }
    let before = model.history.last?.segment
    await server.drop()
    try await wait({ if case .reconnecting = manager.state { return true }; return false }, timeout: 30)
    XCTAssertEqual(model.state, .disconnected); XCTAssertTrue(model.isStale)
    let oldCount = model.history.count
    try await server.restart(); manager.wakeReconnect()
    try await wait({ manager.state == .connected }, timeout: 30)
    try await wait { model.history.count > oldCount }
    XCTAssertEqual(model.current?.cpu, .unavailable(.waitingForBaseline))
    XCTAssertNotEqual(model.history.last?.segment, before)
    XCTAssertFalse(model.isStale); try await waitConnections(2, server: server)
    model.close(); try await waitConnections(1, server: server)
    XCTAssertEqual(manager.state, .connected)
  }

  func test_closing_monitor_during_handshake_releases_late_connection_and_can_reopen() async throws {
    let (server, manager) = try await fixture(), model = manager.serverMonitor
    try await server.pause()
    addTeardownBlock { try? await server.resume() }
    model.open(); try await wait { model.state == .connecting }
    try await Task.sleep(nanoseconds: 100_000_000)
    model.close()
    XCTAssertEqual(model.state, .closed)
    try await Task.sleep(nanoseconds: 200_000_000)
    try await server.resume(); try await waitConnections(1, server: server)
    XCTAssertTrue(model.history.isEmpty); XCTAssertNil(model.current)
    model.open(); try await wait { model.history.count == 1 }
    XCTAssertEqual(model.current?.cpu, .unavailable(.waitingForBaseline))
    model.close(); try await waitConnections(1, server: server)
  }
}
