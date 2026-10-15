import Foundation
import XCTest
@testable import SSHCore

@MainActor
final class SSHCommandTests: XCTestCase {
  private func store() -> KnownHostsStore {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return KnownHostsStore(fileURL: url)
  }

  private func server() async throws -> TestSSHServer {
    let server = try await TestSSHServer.start()
    addTeardownBlock { await server.stop() }
    return server
  }

  private func connect(_ server: TestSSHServer) async throws -> SSHConnection {
    let connection = SSHConnection(config: .init(hostname: server.host, port: server.port,
      username: server.username, auth: .password(server.password)),
      knownHosts: store(), confirmUnknownHostKey: { _, _, _ in true })
    addTeardownBlock { await connection.disconnect() }
    try await connection.connect()
    return connection
  }

  func test_invalid_commands_options_and_pre_cancelled_tasks_do_not_open_channels() async throws {
    let connection = SSHConnection(config: .init(hostname: "127.0.0.1", port: 1, username: "test", auth: .password("test")),
      knownHosts: store(), confirmUnknownHostKey: { _, _, _ in false })
    for command in ["", " \n\t", "echo\0bad", String(repeating: "中", count: 21846)] {
      do { _ = try await connection.execute(command); XCTFail("invalid command") }
      catch { XCTAssertEqual(error as? SSHCommandError, .invalidCommand) }
    }
    for options in [SSHCommandOptions(timeout: 0), .init(timeout: .nan), .init(timeout: .infinity),
      .init(timeout: 301), .init(maximumOutputBytes: 0), .init(maximumOutputBytes: 32 * 1024 * 1024 + 1)] {
      do { _ = try await connection.execute("pwd", options: options); XCTFail("invalid options") }
      catch { XCTAssertEqual(error as? SSHCommandError, .invalidOptions) }
    }
    do { _ = try await connection.execute("pwd"); XCTFail("disconnected") }
    catch { XCTAssertEqual(error as? SSHError, .disconnected) }
    let task = Task { try await connection.execute("pwd") }
    task.cancel()
    do { _ = try await task.value; XCTFail("pre-cancelled") }
    catch { XCTAssertTrue(error is CancellationError) }
  }

  func test_binary_unicode_fragmented_stdout_stderr_and_nonzero_exit_are_preserved_without_pty() async throws {
    let connection = try await connect(server())
    let result = try await connection.execute(
      "if [ -t 1 ]; then exit 99; fi; printf 'first\\000中文'; sleep 0.06; printf 'second\\377'; printf 'err\\000msg' >&2; exit 7")
    XCTAssertEqual(result.stdout, Data("first\0中文second".utf8) + Data([255]))
    XCTAssertEqual(result.stderr, Data("err\0msg".utf8))
    XCTAssertEqual(result.exitStatus, 7)
    XCTAssertNil(result.exitSignal)
  }

  func test_empty_output_and_stdin_eof_allow_repeated_commands_on_one_transport() async throws {
    let connection = try await connect(server())
    let empty = try await connection.execute("true")
    XCTAssertEqual(empty.stdout, Data()); XCTAssertEqual(empty.stderr, Data()); XCTAssertEqual(empty.exitStatus, 0)
    for _ in 0..<12 {
      let result = try await connection.execute("cat; printf 'stdin closed'", options: .init(timeout: 2))
      XCTAssertEqual(result.stdout, Data("stdin closed".utf8))
      XCTAssertEqual(result.exitStatus, 0)
    }
  }

  func test_large_stdout_and_stderr_are_drained_without_deadlock_or_loss() async throws {
    let connection = try await connect(server())
    let result = try await connection.execute("head -c 262144 /dev/zero; head -c 262144 /dev/zero >&2", options: .init(timeout: 3))
    XCTAssertEqual(result.stdout, Data(repeating: 0, count: 262144))
    XCTAssertEqual(result.stderr, Data(repeating: 0, count: 262144))
    XCTAssertEqual(result.exitStatus, 0)
  }

  func test_combined_output_limit_accepts_exact_boundary_then_stops_a_flood() async throws {
    let connection = try await connect(server())
    let result = try await connection.execute("printf 1234; printf 5678 >&2", options: .init(maximumOutputBytes: 8))
    XCTAssertEqual(result.stdout + result.stderr, Data("12345678".utf8))
    let started = Date()
    do {
      _ = try await connection.execute("yes output", options: .init(timeout: 5, maximumOutputBytes: 8192))
      XCTFail("output must be bounded")
    } catch { XCTAssertEqual(error as? SSHCommandError, .outputLimitExceeded) }
    XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    // A normal peer acknowledges channel close, preserving the authenticated transport.
    let probe = try await connection.execute("printf usable")
    XCTAssertEqual(probe.stdout, Data("usable".utf8))
  }

  func test_silent_and_continuously_active_commands_obey_whole_operation_timeout() async throws {
    let server = try await server()
    for command in ["sleep 30", "while :; do printf x; sleep 0.02; done", "exec 1>&- 2>&-; sleep 30"] {
      let connection = try await connect(server)
      let started = Date()
      do { _ = try await connection.execute(command, options: .init(timeout: 0.2)); XCTFail("timeout") }
      catch { XCTAssertEqual(error as? SSHCommandError, .timedOut) }
      XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
      await connection.disconnect()
    }
  }

  func test_cancelling_running_command_returns_promptly_and_releases_its_channel() async throws {
    let connection = try await connect(server())
    let task = Task { try await connection.execute("sleep 30", options: .init(timeout: 20)) }
    try await Task.sleep(for: .milliseconds(150))
    let started = Date()
    task.cancel()
    do { _ = try await task.value; XCTFail("cancelled") }
    catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    let probe = try await connection.execute("printf after_cancel")
    XCTAssertEqual(probe.stdout, Data("after_cancel".utf8))
  }

  func test_ignored_termination_aborts_only_the_command_connection_and_allows_reconnect() async throws {
    let server = try await server()
    let terminal = try await connect(server), monitor = try await connect(server)
    let shell = try await terminal.openShell(cols: 80, rows: 24)
    let output = Task { () -> Data in
      var all = Data()
      for await bytes in shell.output { all.append(bytes) }
      return all
    }
    let task = Task { try await monitor.execute("trap '' TERM; exec sleep 30", options: .init(timeout: 20)) }
    try await Task.sleep(for: .milliseconds(150))
    let started = Date()
    task.cancel()
    do { _ = try await task.value; XCTFail("cancelled") }
    catch { XCTAssertTrue(error is CancellationError) }
    XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    do { _ = try await monitor.execute("printf stale"); XCTFail("unreleased transport must be disconnected") }
    catch { XCTAssertEqual(error as? SSHError, .disconnected) }
    await shell.send(Data("printf '%s\\n' 'TERMINAL_SURVIVED'; exit\r".utf8))
    let shellOutput = await output.value
    XCTAssertTrue(String(decoding: shellOutput, as: UTF8.self).contains("TERMINAL_SURVIVED"))
    try await monitor.connect()
    let fresh = try await monitor.execute("printf fresh")
    XCTAssertEqual(fresh.stdout, Data("fresh".utf8))
  }

  func test_output_eof_does_not_finish_before_process_exit_or_lose_exit_status() async throws {
    let connection = try await connect(server())
    let started = Date()
    let result = try await connection.execute("exec 1>&- 2>&-; sleep 0.2; exit 23", options: .init(timeout: 3))
    XCTAssertEqual(result.stdout, Data()); XCTAssertEqual(result.stderr, Data())
    XCTAssertEqual(result.exitStatus, 23)
    XCTAssertGreaterThan(Date().timeIntervalSince(started), 0.15)
  }

  func test_exit_signal_is_returned_separately_from_an_absent_exit_status() async throws {
    let connection = try await connect(server())
    let result = try await connection.execute("kill -TERM $$")
    XCTAssertEqual(result.exitSignal, "TERM")
  }

  func test_idle_exec_and_other_command_do_not_block_interactive_shell() async throws {
    let connection = try await connect(server())
    let shell = try await connection.openShell(cols: 80, rows: 24)
    let output = Task { () -> Data in
      var all = Data()
      for await bytes in shell.output { all.append(bytes) }
      return all
    }
    let slow = Task { try await connection.execute("sleep 2; printf slow", options: .init(timeout: 5)) }
    try await Task.sleep(for: .milliseconds(100))
    let started = Date()
    let fast = try await connection.execute("printf fast", options: .init(timeout: 3))
    XCTAssertEqual(fast.stdout, Data("fast".utf8))
    XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    await shell.send(Data("printf '%s\\n' 'INTERACTIVE_LIVE'; exit\r".utf8))
    let shellOutput = await output.value
    XCTAssertTrue(String(decoding: shellOutput, as: UTF8.self).contains("INTERACTIVE_LIVE"))
    XCTAssertLessThan(Date().timeIntervalSince(started), 1.5, "shell must finish before the silent command")
    let slowResult = try await slow.value
    XCTAssertEqual(slowResult.stdout, Data("slow".utf8))
  }

  func test_disconnect_interrupts_channel_open_on_a_frozen_server_and_allows_reconnect() async throws {
    let server = try await server(), connection = try await connect(server)
    try await server.pause()
    addTeardownBlock { try? await server.resume() }
    let task = Task { try await connection.execute("printf late", options: .init(timeout: 20)) }
    try await Task.sleep(for: .milliseconds(100))
    let started = Date()
    await connection.disconnect()
    do { _ = try await task.value; XCTFail("disconnect must interrupt exec") } catch {}
    XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    try await server.resume()
    try await connection.connect()
    let probe = try await connection.execute("printf reconnected")
    XCTAssertEqual(probe.stdout, Data("reconnected".utf8))
  }

  func test_timeout_in_channel_open_aborts_unfinished_protocol_state_with_no_late_result() async throws {
    let server = try await server(), connection = try await connect(server)
    try await server.pause()
    addTeardownBlock { try? await server.resume() }
    let started = Date()
    do { _ = try await connection.execute("printf late", options: .init(timeout: 0.1)); XCTFail("frozen") }
    catch { XCTAssertEqual(error as? SSHCommandError, .timedOut) }
    XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    do { _ = try await connection.execute("printf stale"); XCTFail("aborted transport must be disconnected") }
    catch { XCTAssertEqual(error as? SSHError, .disconnected) }
    try await server.resume()
    try await connection.connect()
    let probe = try await connection.execute("printf fresh")
    XCTAssertEqual(probe.stdout, Data("fresh".utf8))
  }

  func test_encrypted_private_key_remote_dns_jump_exec_and_forced_abort_release_route() async throws {
    let jump = try await server(), target = try await server()
    try await jump.enableTCPForwarding()
    try await jump.mapHost("monitor-target.invalid", to: target)
    let config = ConnectionConfig(hostname: "monitor-target.invalid", port: 2222, username: target.username,
      auth: .privateKey(data: Data(TestSSHServer.testEncryptedEd25519PrivateKey.utf8), passphrase: TestSSHServer.encryptedKeyPassphrase),
      jumpHosts: [.init(hostname: jump.host, port: jump.port, username: jump.username, auth: .password(jump.password))])
    let connection = SSHConnection(config: config, knownHosts: store(), confirmUnknownHostKey: { _, _, _ in true })
    addTeardownBlock { await connection.disconnect() }
    try await connection.connect()
    let result = try await connection.execute("printf 'jump exec'; cat /proc/meminfo")
    XCTAssertEqual(result.exitStatus, 0)
    let text = String(decoding: result.stdout, as: UTF8.self)
    XCTAssertTrue(text.hasPrefix("jump exec")); XCTAssertTrue(text.contains("MemTotal:"))
    try await target.pause()
    addTeardownBlock { try? await target.resume() }
    do { _ = try await connection.execute("printf late", options: .init(timeout: 0.1)); XCTFail("frozen destination") }
    catch { XCTAssertEqual(error as? SSHCommandError, .timedOut) }
    let remaining = try await jump.execute(["sh", "-c", "netstat -tn | awk '$4 ~ /:2222$/ && $6 == \"ESTABLISHED\" {c++} END {print c+0}'"])
    XCTAssertEqual(remaining.trimmingCharacters(in: .whitespacesAndNewlines), "0", "aborted command must release every hop transport")
    try await target.resume()
    try await connection.connect()
    let fresh = try await connection.execute("printf route_fresh")
    XCTAssertEqual(fresh.stdout, Data("route_fresh".utf8))
  }
}
