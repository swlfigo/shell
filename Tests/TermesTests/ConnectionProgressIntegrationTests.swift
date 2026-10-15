import Foundation
import XCTest
import SSHCore
import TermesKit

@MainActor
final class ConnectionProgressIntegrationTests: XCTestCase {
  private func wait(_ predicate: () -> Bool, timeout: TimeInterval = 15,
                    file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    guard predicate() else { XCTFail("timed out", file: file, line: line); throw CancellationError() }
  }
  private func fixture() async throws -> (TestSSHServer, SessionManager, ConnectionConfig) {
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    let manager = SessionManager(knownHosts: KnownHostsStore(fileURL: url))
    addTeardownBlock { @MainActor in manager.disconnect() }
    return (server, manager, .init(hostname: server.host, port: server.port, username: server.username, auth: .password(server.password)))
  }
  private func connect(_ manager: SessionManager, config: ConnectionConfig) async throws {
    let opening = Task { await manager.connect(config) }
    try await wait { if case .needsHostKeyConfirm = manager.state { manager.confirmHostKey(true) }; return manager.state == .connected }
    await opening.value
  }

  func test_session_waits_at_trust_then_marks_ready_after_shell_and_keeps_auxiliary_clients_out_of_logs() async throws {
    let (_, manager, config) = try await fixture(), opening = Task { await manager.connect(config) }
    try await wait { if case .needsHostKeyConfirm = manager.state { return true }; return false }
    try await wait { manager.connectionProgress.state == .waitingForTrust }
    XCTAssertEqual(manager.connectionProgress.currentNode?.steps[1], .waitingForTrust)
    XCTAssertEqual(manager.connectionProgress.currentNode?.steps[2], .waiting)
    manager.confirmHostKey(true); await opening.value
    XCTAssertEqual(manager.state, .connected); XCTAssertEqual(manager.connectionProgress.state, .ready)
    XCTAssertEqual(manager.connectionProgress.currentNode?.steps, Array(repeating: .succeeded, count: 5))
    let logs = manager.connectionProgress.logs
    let monitor = try await manager.openMonitoringClient(), sample = try await monitor.sample()
    XCTAssertNotNil(sample.memory.value); await monitor.close()
    let files = try await manager.openSFTP(); _ = try await files.canonicalPath("."); await files.close()
    XCTAssertEqual(manager.connectionProgress.logs, logs)
    manager.disconnect(); XCTAssertEqual(manager.connectionProgress.state, .disconnected)
  }

  func test_failure_keeps_authentication_reason_and_never_marks_terminal_ready() async throws {
    let (_, manager, original) = try await fixture()
    var config = original; config.auth = .password("NEVER_LOG_THIS_PASSWORD")
    let opening = Task { await manager.connect(config) }
    try await wait { if case .needsHostKeyConfirm = manager.state { return true }; return false }
    manager.confirmHostKey(true); await opening.value
    guard case .failed = manager.state else { return XCTFail("authentication failure") }
    XCTAssertEqual(manager.connectionProgress.state, .failed(SSHProgressFailure.authentication.message))
    XCTAssertEqual(manager.connectionProgress.currentNode?.steps[2], .failed(SSHProgressFailure.authentication.message))
    XCTAssertEqual(manager.connectionProgress.currentNode?.steps[4], .waiting)
    XCTAssertFalse(manager.connectionProgress.logs.contains { $0.text.contains("NEVER_LOG_THIS_PASSWORD") })
  }

  func test_cancel_at_trust_keeps_cancelled_result_and_late_confirmation_cannot_complete_connection() async throws {
    let (_, manager, config) = try await fixture(), opening = Task { await manager.connect(config) }
    try await wait { manager.connectionProgress.state == .waitingForTrust }
    let start = Date(); manager.disconnect(); await opening.value
    XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    let logs = manager.connectionProgress.logs
    manager.confirmHostKey(true); try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertEqual(manager.state, .disconnected); XCTAssertEqual(manager.connectionProgress.state, .cancelled)
    XCTAssertEqual(manager.connectionProgress.logs, logs); XCTAssertNil(manager.currentConfig)
    try await connect(manager, config: config)
    XCTAssertEqual(manager.connectionProgress.state, .ready)
  }

  func test_cancel_frozen_handshake_returns_promptly_and_new_attempt_replaces_old_progress() async throws {
    let (server, manager, config) = try await fixture()
    try await server.pause(); addTeardownBlock { try? await server.resume() }
    let opening = Task { await manager.connect(config) }
    try await wait { manager.connectionProgress.currentNode?.steps[0] == .running }
    let start = Date(); manager.disconnect(); await opening.value
    XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    XCTAssertEqual(manager.connectionProgress.state, .cancelled)
    let logs = manager.connectionProgress.logs
    try await server.resume(); try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertEqual(manager.connectionProgress.logs, logs)
    try await connect(manager, config: config)
    XCTAssertEqual(manager.connectionProgress.state, .ready)
  }

  func test_cancelling_calling_task_releases_trust_prompt_and_scoped_old_approval_cannot_trust_new_attempt() async throws {
    let (_, manager, config) = try await fixture(), opening = Task { await manager.connect(config) }
    try await wait { manager.connectionProgress.state == .waitingForTrust }
    let oldID = manager.connectionProgress.attemptID
    guard case .needsHostKeyConfirm(let oldFingerprint) = manager.state else { return XCTFail("trust prompt") }
    opening.cancel(); await opening.value
    XCTAssertEqual(manager.state, .disconnected); XCTAssertEqual(manager.connectionProgress.state, .cancelled)
    XCTAssertNil(manager.pendingHostKeyEndpoint)
    let next = Task { await manager.connect(config) }
    try await wait { manager.connectionProgress.state == .waitingForTrust }
    manager.confirmHostKey(true, attemptID: oldID, fingerprint: oldFingerprint)
    XCTAssertEqual(manager.connectionProgress.state, .waitingForTrust)
    guard case .needsHostKeyConfirm(let current) = manager.state else { return XCTFail("old approval changed new attempt") }
    manager.confirmHostKey(true, attemptID: manager.connectionProgress.attemptID, fingerprint: current)
    await next.value
    XCTAssertEqual(manager.state, .connected); XCTAssertEqual(manager.connectionProgress.state, .ready)
  }

  func test_reconnect_shows_backoff_then_new_attempt_and_reaches_ready_after_server_returns() async throws {
    let (server, manager, config) = try await fixture()
    try await connect(manager, config: config)
    await server.drop()
    try await wait({ if case .waitingRetry = manager.connectionProgress.state { return true }; return false }, timeout: 30)
    let oldLogs = manager.connectionProgress.logs
    XCTAssertTrue(oldLogs.contains { $0.text.contains("自动重试") })
    try await server.restart(); manager.retryReconnectNow()
    try await wait({ manager.state == .connected }, timeout: 30)
    XCTAssertEqual(manager.connectionProgress.state, .ready)
    XCTAssertGreaterThan(manager.connectionProgress.attempt, 1)
    XCTAssertTrue(manager.connectionProgress.logs.contains { oldLogs.contains($0) })
    XCTAssertEqual(manager.connectionProgress.currentNode?.steps, Array(repeating: .succeeded, count: 5))
  }
}
