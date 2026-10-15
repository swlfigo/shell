import XCTest
import SSHCore
@testable import TermesKit

@MainActor
final class SessionManagerReconnectTests: XCTestCase {
  func test_backoff_is_exponential_capped_30() {
    XCTAssertEqual(SessionManager.backoffDelay(attempt: 1), 1)
    XCTAssertEqual(SessionManager.backoffDelay(attempt: 2), 2)
    XCTAssertEqual(SessionManager.backoffDelay(attempt: 3), 4)
    XCTAssertEqual(SessionManager.backoffDelay(attempt: 6), 30)
    XCTAssertEqual(SessionManager.backoffDelay(attempt: 10), 30)
  }

  func test_permanent_vs_transient_classification() {
    XCTAssertTrue(SessionManager.isPermanent(.authenticationFailed))
    XCTAssertTrue(SessionManager.isPermanent(.hostKeyMismatch(stored: "a", got: "b")))
    XCTAssertTrue(SessionManager.isPermanent(.hostKeyRejected))
    XCTAssertFalse(SessionManager.isPermanent(.connectionFailed("x")))
    XCTAssertFalse(SessionManager.isPermanent(.disconnected))
  }

  /// No network/Docker: reconnect against a closed local port so every attempt fails fast,
  /// then wake during the 4s backoff and expect the next attempt well before it elapses.
  func test_wake_interrupts_backoff() async throws {
    let mgr = SessionManager(knownHosts: KnownHostsStore(
      fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")))
    mgr.config = .init(hostname: "127.0.0.1", port: 1, username: "u", auth: .password("p"))
    mgr.startReconnect()
    defer { mgr.disconnect() }

    func waitAttempt(_ n: Int, timeout: TimeInterval) async -> Bool {
      let deadline = Date().addingTimeInterval(timeout)
      while Date() < deadline {
        if case .reconnecting(let a) = mgr.state, a >= n { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
      }
      return false
    }
    // attempt 3 starts after 1s + 2s of backoff; its failure is followed by a 4s wait.
    let reached3 = await waitAttempt(3, timeout: 10)
    XCTAssertTrue(reached3)
    try await Task.sleep(nanoseconds: 500_000_000)  // let attempt 3 fail and enter backoff
    guard case .reconnecting(3) = mgr.state else { return XCTFail("expected attempt 3, got \(mgr.state)") }
    let start = Date()
    mgr.wakeReconnect()
    let reached4 = await waitAttempt(4, timeout: 3)
    XCTAssertTrue(reached4, "wake should start attempt 4 well before the 4s backoff")
    XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)
  }

  /// Spec §4: credentials live in memory only for the session; disconnect releases them.
  func test_disconnect_releases_config() {
    let mgr = SessionManager(knownHosts: KnownHostsStore(
      fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")))
    mgr.config = .init(hostname: "127.0.0.1", port: 1, username: "u", auth: .password("p"))
    mgr.disconnect()
    XCTAssertNil(mgr.config)
  }

  func test_current_config_mirrors_config_and_clears_on_disconnect() {
    let mgr = SessionManager(knownHosts: KnownHostsStore(
      fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")))
    XCTAssertNil(mgr.currentConfig)
    let cfg = ConnectionConfig(hostname: "127.0.0.1", port: 1, username: "u", auth: .password("p"))
    mgr.config = cfg
    XCTAssertEqual(mgr.currentConfig, cfg)
    mgr.disconnect()
    XCTAssertNil(mgr.currentConfig)
  }

  /// Disconnect during a long backoff must end the loop promptly and stop further attempts.
  func test_disconnect_during_backoff_stops_loop() async throws {
    let mgr = SessionManager(knownHosts: KnownHostsStore(
      fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")))
    mgr.config = .init(hostname: "127.0.0.1", port: 1, username: "u", auth: .password("p"))
    mgr.startReconnect()
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
      if case .reconnecting(let a) = mgr.state, a >= 3 { break }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    try await Task.sleep(nanoseconds: 500_000_000)  // in the 4s backoff after attempt 3
    let start = Date()
    mgr.disconnect()
    XCTAssertEqual(mgr.state, .disconnected)
    // Remaining backoff is ~3.5s; stay well inside it and past a wake-up that would start attempt 4.
    try await Task.sleep(nanoseconds: 1_500_000_000)
    XCTAssertEqual(mgr.state, .disconnected)
    XCTAssertLessThan(Date().timeIntervalSince(start), 2.5)
  }
}

// MARK: - Integration (requires Docker)

extension SessionManagerReconnectTests {
  private func makeManager() -> SessionManager {
    SessionManager(knownHosts: KnownHostsStore(
      fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")))
  }

  private func config(_ s: TestSSHServer, password: String? = nil) -> ConnectionConfig {
    .init(hostname: s.host, port: s.port, username: s.username, auth: .password(password ?? s.password))
  }

  /// Polls `mgr.state` (a @Published property read on the main actor) until `predicate` holds.
  private func waitForState(
    _ mgr: SessionManager, timeout: TimeInterval,
    file: StaticString = #filePath, line: UInt = #line,
    _ predicate: (SessionManager.State) -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if predicate(mgr.state) { return }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    XCTFail("timed out waiting for state; last = \(mgr.state)", file: file, line: line)
    throw CancellationError()
  }

  /// First connect needs TOFU confirmation (fresh known-hosts store); auto-accept it.
  private func connectAndTrust(_ mgr: SessionManager, _ cfg: ConnectionConfig) async throws {
    async let c: Void = mgr.connect(cfg, cols: 80, rows: 24)
    try await waitForState(mgr, timeout: 20) {
      if case .needsHostKeyConfirm = $0 { return true }
      return $0 == .connected
    }
    if case .needsHostKeyConfirm = mgr.state { mgr.confirmHostKey(true) }
    await c
    try await waitForState(mgr, timeout: 15) { $0 == .connected }
  }

  func test_current_config_available_while_connected() async throws {
    let s = try await TestSSHServer.start()
    addTeardownBlock { await s.stop() }
    let mgr = makeManager()
    let cfg = config(s)
    try await connectAndTrust(mgr, cfg)
    XCTAssertEqual(mgr.currentConfig, cfg)
    mgr.disconnect()
    XCTAssertNil(mgr.currentConfig)
  }

  func test_snippet_insertion_waits_for_enter_and_rejects_terminal_controls() async throws {
    let server = try await TestSSHServer.start()
    addTeardownBlock { await server.stop() }
    let manager = makeManager()
    defer { manager.disconnect() }
    try await connectAndTrust(manager, config(server))
    var output = ""
    manager.onData = { output += String(decoding: $0, as: UTF8.self) }
    let marker = "SNIPPET_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let command = "printf '%s%s\\n' 'SNIPPET_' '\(marker.dropFirst(8))'"
    XCTAssertFalse(manager.insertSnippet(Snippet(name: "Bad", command: "\u{1b}[31m")))
    XCTAssertTrue(manager.insertSnippet(Snippet(name: "Marker", command: command)))
    try await Task.sleep(nanoseconds: 500_000_000)
    XCTAssertFalse(output.contains(marker), "insertion must not execute the command")
    manager.sendInput(Data("\r".utf8))
    let deadline = Date().addingTimeInterval(10)
    while !output.contains(marker), Date() < deadline {
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTAssertTrue(output.contains(marker), "the command executes after the user submits it")
    manager.disconnect()
    XCTAssertFalse(manager.insertSnippet(Snippet(name: "Marker", command: command)))
  }

  func test_drop_then_restart_auto_reconnects() async throws {
    let s = try await TestSSHServer.start()
    addTeardownBlock { await s.stop() }
    let mgr = makeManager()
    try await connectAndTrust(mgr, config(s))
    await s.drop()
    try await waitForState(mgr, timeout: 40) { if case .reconnecting = $0 { return true }; return false }
    try await s.restart()
    try await waitForState(mgr, timeout: 90) { $0 == .connected }
    mgr.disconnect()
    XCTAssertEqual(mgr.state, .disconnected)
  }

  func test_cancel_during_reconnecting_stops() async throws {
    let s = try await TestSSHServer.start()
    addTeardownBlock { await s.stop() }
    let mgr = makeManager()
    try await connectAndTrust(mgr, config(s))
    await s.drop()
    try await waitForState(mgr, timeout: 40) { if case .reconnecting = $0 { return true }; return false }
    mgr.disconnect()
    XCTAssertEqual(mgr.state, .disconnected)
    try await s.restart()
    try await Task.sleep(nanoseconds: 4_000_000_000)
    XCTAssertEqual(mgr.state, .disconnected, "must not reconnect after user disconnect")
  }

  func test_local_disconnect_does_not_reconnect() async throws {
    let s = try await TestSSHServer.start()
    addTeardownBlock { await s.stop() }
    let mgr = makeManager()
    try await connectAndTrust(mgr, config(s))
    mgr.disconnect()
    try await Task.sleep(nanoseconds: 2_000_000_000)
    XCTAssertEqual(mgr.state, .disconnected)
  }

  func test_permanent_error_stops_reconnect() async throws {
    let s = try await TestSSHServer.start()
    addTeardownBlock { await s.stop() }
    let mgr = makeManager()
    // Wrong password: fails permanently on first connect, never enters reconnecting.
    let bad = config(s, password: "wrong")
    async let c: Void = mgr.connect(bad, cols: 80, rows: 24)
    try await waitForState(mgr, timeout: 20) { if case .needsHostKeyConfirm = $0 { return true }; return false }
    mgr.confirmHostKey(true)
    await c
    try await waitForState(mgr, timeout: 20) { if case .failed = $0 { return true }; return false }
    try await Task.sleep(nanoseconds: 2_000_000_000)
    guard case .failed = mgr.state else { return XCTFail("expected .failed, got \(mgr.state)") }
  }

  func test_remote_exit_does_not_reconnect() async throws {
    let s = try await TestSSHServer.start()
    addTeardownBlock { await s.stop() }
    let mgr = makeManager()
    try await connectAndTrust(mgr, config(s))
    mgr.sendInput(Data("exit\n".utf8))
    try await waitForState(mgr, timeout: 20) { $0 == .disconnected }
    // The ended session releases its in-memory config (credentials); ⌘D has nothing to duplicate.
    XCTAssertNil(mgr.currentConfig)
    // Must stay disconnected and never pass through .reconnecting.
    for _ in 0..<30 {
      if case .reconnecting = mgr.state { return XCTFail("reconnected after remote exit") }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    XCTAssertEqual(mgr.state, .disconnected)
  }

  func test_permanent_error_during_reconnect_fails_and_stops() async throws {
    let s = try await TestSSHServer.start()
    addTeardownBlock { await s.stop() }
    let mgr = makeManager()
    try await connectAndTrust(mgr, config(s))
    await s.drop()
    try await waitForState(mgr, timeout: 40) { if case .reconnecting = $0 { return true }; return false }
    try await s.restart(differentHostKey: true)
    try await waitForState(mgr, timeout: 90) { if case .failed = $0 { return true }; return false }
    // No further reconnect loop after the permanent failure.
    for _ in 0..<40 {
      if case .reconnecting = mgr.state { return XCTFail("kept reconnecting after permanent error") }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    guard case .failed = mgr.state else { return XCTFail("expected .failed, got \(mgr.state)") }
  }
}
