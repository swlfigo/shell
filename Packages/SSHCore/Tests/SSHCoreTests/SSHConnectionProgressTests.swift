import Foundation
import XCTest
@testable import SSHCore

private final class ProgressEvents: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [SSHConnectionProgressEvent] = []
  func receive(_ event: SSHConnectionProgressEvent) { lock.withLock { events.append(event) } }
  var values: [SSHConnectionProgressEvent] { lock.withLock { events } }
}
private actor ProgressTrustGate {
  private var pending: CheckedContinuation<Bool, Never>?
  var entered = false
  func confirm() async -> Bool { entered = true; return await withCheckedContinuation { pending = $0 } }
  func finish(_ value: Bool) { pending?.resume(returning: value); pending = nil }
}

@MainActor
final class SSHConnectionProgressTests: XCTestCase {
  private func server() async throws -> TestSSHServer {
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }; return server
  }
  private func store() -> KnownHostsStore {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return .init(fileURL: url)
  }
  private func config(_ server: TestSSHServer, password: String? = nil) -> ConnectionConfig {
    .init(hostname: server.host, port: server.port, username: server.username, auth: .password(password ?? server.password))
  }
  private func connection(_ config: ConnectionConfig, store: KnownHostsStore, events: ProgressEvents,
                          confirm: @escaping HostKeyConfirm = { _, _, _ in true }) -> SSHConnection {
    let value = SSHConnection(config: config, knownHosts: store, progress: { events.receive($0) }, confirmUnknownHostKey: confirm)
    addTeardownBlock { await value.disconnect() }; return value
  }
  private func ordered(_ events: [SSHConnectionProgressEvent], file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(events.map(\.sequence), events.indices.map { UInt64($0 + 1) }, file: file, line: line)
  }

  func test_password_connection_waits_for_trust_then_authenticates_before_channel_pty_and_shell() async throws {
    let server = try await server(), events = ProgressEvents(), store = store(), gate = ProgressTrustGate()
    let config = config(server), conn = connection(config, store: store, events: events) { _, _, _ in await gate.confirm() }
    let opening = Task { try await conn.connect() }
    let deadline = Date().addingTimeInterval(5)
    while !(await gate.entered), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    let entered = await gate.entered; XCTAssertTrue(entered)
    guard case .waitingForTrust(let fingerprint) = events.values.last?.status else { await gate.finish(false); return XCTFail("must stop at host trust") }
    XCTAssertTrue(fingerprint.hasPrefix("SHA256:")); XCTAssertTrue(try store.all().isEmpty)
    XCTAssertFalse(events.values.contains { $0.stage == .authentication })
    await gate.finish(true); try await opening.value
    let login = events.values
    XCTAssertEqual(login.map(\.stage), [.connection, .connection, .connection, .hostKey, .hostKey, .hostKey, .authentication, .authentication])
    XCTAssertEqual(login.last?.status, .succeeded); XCTAssertEqual(login[6].detail, .password)
    XCTAssertEqual(login[1].detail, .tcpConnected); XCTAssertFalse(login.contains { $0.stage == .channel })
    let channel = try await conn.openShell(cols: 80, rows: 24)
    let terminal = Array(events.values.suffix(6))
    XCTAssertEqual(terminal.map(\.stage), [.channel, .channel, .pty, .pty, .shell, .shell])
    XCTAssertEqual(terminal.map(\.status), [.started, .succeeded, .started, .succeeded, .started, .succeeded])
    XCTAssertTrue(events.values.allSatisfy { $0.endpoint.hostname == config.hostname && $0.endpoint.index == 0 && !$0.endpoint.isJumpHost })
    ordered(events.values); await channel.close()
  }

  func test_bad_password_fails_authentication_without_logging_credentials_or_starting_terminal() async throws {
    let server = try await server(), events = ProgressEvents(), secret = "DO_NOT_LOG_PASSWORD_" + UUID().uuidString
    let conn = connection(config(server, password: secret), store: store(), events: events)
    do { try await conn.connect(); XCTFail("bad password") } catch { XCTAssertEqual(error as? SSHError, .authenticationFailed) }
    XCTAssertEqual(events.values.last?.stage, .authentication)
    XCTAssertEqual(events.values.last?.status, .failed(.authentication))
    XCTAssertFalse(events.values.contains { $0.stage == .channel || $0.stage == .authentication && $0.status == .succeeded })
    XCTAssertFalse(String(describing: events.values).contains(secret)); ordered(events.values)
  }

  func test_rejected_and_changed_keys_fail_host_verification_before_authentication() async throws {
    let server = try await server(), store = store(), rejected = ProgressEvents()
    let conn = connection(config(server), store: store, events: rejected, confirm: { _, _, _ in false })
    do { try await conn.connect(); XCTFail("rejected") } catch { XCTAssertEqual(error as? SSHError, .hostKeyRejected) }
    XCTAssertEqual(rejected.values.last?.stage, .hostKey); XCTAssertEqual(rejected.values.last?.status, .failed(.hostKeyRejected))
    XCTAssertFalse(rejected.values.contains { $0.stage == .authentication }); XCTAssertTrue(try store.all().isEmpty)
    let accepted = connection(config(server), store: store, events: ProgressEvents())
    try await accepted.connect(); await accepted.disconnect(); try await server.restart(differentHostKey: true)
    let changed = ProgressEvents(), replacement = connection(config(server), store: store, events: changed)
    do { try await replacement.connect(); XCTFail("changed") } catch { guard case .hostKeyMismatch = error as? SSHError else { return XCTFail("mismatch") } }
    XCTAssertEqual(changed.values.last?.status, .failed(.hostKeyChanged)); XCTAssertEqual(changed.values.last?.stage, .hostKey)
    XCTAssertFalse(changed.values.contains { $0.stage == .authentication })
    XCTAssertFalse(changed.values.contains { if case .waitingForTrust = $0.status { return true }; return false })
    ordered(changed.values)
  }

  func test_frozen_handshake_cancellation_stops_at_connection_and_does_not_emit_late_success() async throws {
    let server = try await server(), events = ProgressEvents(), conn = connection(config(server), store: store(), events: events)
    try await server.pause(); addTeardownBlock { try? await server.resume() }
    let opening = Task { try await conn.connect() }
    try await Task.sleep(nanoseconds: 100_000_000)
    let start = Date(); opening.cancel()
    do { try await opening.value; XCTFail("cancelled") } catch {}
    XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    XCTAssertEqual(events.values.last?.stage, .connection); XCTAssertEqual(events.values.last?.status, .failed(.cancelled))
    let stopped = events.values
    try await server.resume(); try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertEqual(events.values, stopped); ordered(stopped)
  }

  func test_two_hop_encrypted_key_progress_reports_actual_hosts_in_route_order() async throws {
    let first = try await server(), second = try await server(), target = try await server(), events = ProgressEvents()
    try await first.enableTCPForwarding(); try await second.enableTCPForwarding()
    try await first.mapHost("progress-second.invalid", to: second); try await second.mapHost("progress-target.invalid", to: target)
    let config = ConnectionConfig(hostname: "progress-target.invalid", port: 2222, username: target.username,
      auth: .privateKey(data: Data(TestSSHServer.testEncryptedEd25519PrivateKey.utf8), passphrase: TestSSHServer.encryptedKeyPassphrase),
      jumpHosts: [.init(hostname: first.host, port: first.port, username: first.username, auth: .password(first.password)),
                  .init(hostname: "progress-second.invalid", port: 2222, username: second.username, auth: .password(second.password))])
    let conn = connection(config, store: store(), events: events)
    try await conn.connect()
    let shell = try await conn.openShell(cols: 80, rows: 24)
    let routeStarts = events.values.filter { $0.stage == .connection && $0.status == .started && $0.detail == nil }
    XCTAssertEqual(routeStarts.map { $0.endpoint.hostname }, [first.host, "progress-second.invalid", "progress-target.invalid"])
    XCTAssertEqual(routeStarts.map { $0.endpoint.index }, [0, 1, 2])
    XCTAssertEqual(events.values.filter { $0.stage == .route && $0.status == .succeeded }.map { $0.endpoint.index }, [0, 1])
    XCTAssertTrue(events.values.filter { [.channel, .pty, .shell].contains($0.stage) }.allSatisfy { $0.endpoint.index == 2 && !$0.endpoint.isJumpHost })
    XCTAssertEqual(events.values.first { $0.endpoint.index == 2 && $0.stage == .authentication && $0.status == .started }?.detail, .privateKey)
    let text = String(describing: events.values)
    XCTAssertFalse(text.contains(TestSSHServer.encryptedKeyPassphrase)); XCTAssertFalse(text.contains("BEGIN OPENSSH PRIVATE KEY"))
    ordered(events.values); await shell.close()
  }

  func test_jump_host_failure_is_reported_once_on_that_hop_without_target_events() async throws {
    let jump = try await server(), events = ProgressEvents()
    let config = ConnectionConfig(hostname: "unreached-target.invalid", port: 2222, username: "target", auth: .password("unlogged-target-secret"),
      jumpHosts: [.init(hostname: jump.host, port: jump.port, username: jump.username, auth: .password(jump.password))])
    let conn = connection(config, store: store(), events: events, confirm: { _, _, _ in false })
    do { try await conn.connect(); XCTFail("hop rejected") } catch { XCTAssertEqual(error as? SSHError, .hostKeyRejected) }
    XCTAssertTrue(events.values.allSatisfy { $0.endpoint.index == 0 && $0.endpoint.isJumpHost })
    XCTAssertEqual(events.values.filter { if case .failed = $0.status { return true }; return false }.count, 1)
    ordered(events.values)
  }

  func test_denied_pty_fails_that_stage_after_channel_open_without_claiming_shell_success() async throws {
    let server = try await server(), events = ProgressEvents()
    _ = try await server.execute(["sh", "-c", "printf '\\nPermitTTY no\\n' >> /config/sshd/sshd_config; kill -HUP \"$(cat /config/sshd.pid)\""])
    let conn = connection(config(server), store: store(), events: events)
    try await conn.connect()
    do { _ = try await conn.openShell(cols: 80, rows: 24); XCTFail("PTY must be refused") } catch {}
    XCTAssertEqual(events.values.last?.stage, .pty); XCTAssertEqual(events.values.last?.status, .failed(.channel))
    XCTAssertTrue(events.values.contains { $0.stage == .channel && $0.status == .succeeded })
    XCTAssertFalse(events.values.contains { $0.stage == .shell }); ordered(events.values)
  }

  func test_excessive_route_configuration_is_reported_without_network_activity() async throws {
    let events = ProgressEvents(), hop = JumpHost(hostname: "127.0.0.1", port: 1, username: "u", auth: .password("secret"))
    let conn = connection(.init(hostname: "unused", username: "u", auth: .password("secret"),
      jumpHosts: Array(repeating: hop, count: ConnectionConfig.maximumJumpHosts + 1)), store: store(), events: events)
    do { try await conn.connect(); XCTFail("invalid route") } catch {}
    XCTAssertEqual(events.values.count, 1); XCTAssertEqual(events.values.last?.status, .failed(.invalidConfiguration))
    ordered(events.values)
  }
}
