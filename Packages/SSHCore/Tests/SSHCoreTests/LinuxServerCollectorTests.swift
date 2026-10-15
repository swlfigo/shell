import Foundation
import XCTest
@testable import SSHCore

@MainActor
final class LinuxServerCollectorTests: XCTestCase {
  private func server() async throws -> TestSSHServer {
    let value = try await TestSSHServer.start()
    addTeardownBlock { await value.stop() }
    return value
  }
  private func knownHosts() -> KnownHostsStore {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return .init(fileURL: url)
  }
  private func connect(_ server: TestSSHServer) async throws -> SSHConnection {
    let connection = SSHConnection(config: .init(hostname: server.host, port: server.port,
      username: server.username, auth: .password(server.password)), knownHosts: knownHosts(), confirmUnknownHostKey: { _, _, _ in true })
    addTeardownBlock { await connection.disconnect() }
    try await connection.connect()
    return connection
  }

  func test_real_linux_collection_deltas_and_independent_terminal_output() async throws {
    let server = try await server()
    let monitor = try await connect(server), terminal = try await connect(server)
    let shell = try await terminal.openShell(cols: 80, rows: 24)
    let output = Task { () -> String in
      var bytes = Data()
      for await data in shell.output { bytes.append(data) }
      return String(decoding: bytes, as: UTF8.self)
    }
    let collector = LinuxServerCollector(connection: monitor)
    let first = try await collector.sample()
    XCTAssertGreaterThan(try XCTUnwrap(first.memory.value).totalBytes, 0)
    XCTAssertNotNil(first.swap.value); XCTAssertNotNil(first.bootID.value)
    XCTAssertNotNil(first.disks.value); XCTAssertNotNil(first.network.value)
    XCTAssertNotNil(first.load.value); XCTAssertNotNil(first.uptime.value)
    XCTAssertNotNil(first.identity.kernelRelease.value); XCTAssertNotNil(first.identity.operatingSystem.value)
    var calculator = ServerMetricsCalculator()
    XCTAssertEqual(calculator.consume(first).cpu, .unavailable(.waitingForBaseline))
    try await Task.sleep(for: .milliseconds(120))
    let second = try await collector.sample(), snapshot = calculator.consume(second)
    let cpu = try XCTUnwrap(snapshot.cpu.value)
    XCTAssertTrue((0...100.0001).contains(cpu.totalPercent))
    XCTAssertTrue((0...100.0001).contains(cpu.userPercent))
    XCTAssertGreaterThan(second.monotonicTime, first.monotonicTime)
    XCTAssertTrue(try XCTUnwrap(snapshot.network.value).allSatisfy { $0.receivedBytesPerSecond.value?.isFinite == true })
    await shell.send(Data("printf '%s\\n' 'MONITOR_TERMINAL_OK'; exit\r".utf8))
    let text = await output.value
    XCTAssertTrue(text.contains("MONITOR_TERMINAL_OK")); XCTAssertFalse(text.contains("TERMESMON1:"))
    XCTAssertFalse(text.contains("MemTotal:"))
  }

  func test_real_section_failures_literal_os_release_and_unsupported_system_are_explicit() async throws {
    let server = try await server()
    let setup = #"""
    mkdir -p /tmp/termes-monitor-bin
    cat > /tmp/termes-monitor-wrapper <<'EOF'
    #!/bin/sh
    PATH=/tmp/termes-monitor-bin:/bin:/usr/bin
    export PATH
    exec /bin/sh -c "$SSH_ORIGINAL_COMMAND"
    EOF
    cat > /tmp/termes-monitor-bin/cat <<'EOF'
    #!/bin/sh
    if [ "$1" = /proc/meminfo ]; then printf 'denied\n' >&2; exit 1; fi
    exec /bin/cat "$@"
    EOF
    cat > /tmp/termes-monitor-bin/df <<'EOF'
    #!/bin/sh
    printf 'broken disk output\n'
    EOF
    chmod +x /tmp/termes-monitor-wrapper /tmp/termes-monitor-bin/*
    printf '\nForceCommand /tmp/termes-monitor-wrapper\n' >> /config/sshd/sshd_config
    kill -HUP "$(cat /config/sshd.pid)"
    rm -f /etc/os-release
    printf 'PRETTY_NAME="$(touch /tmp/termes-monitor-evaluated) Literal Linux"\n' > /etc/os-release
    """#
    _ = try await server.execute(["sh", "-c", setup])
    let connection = try await connect(server), collector = LinuxServerCollector(connection: connection)
    let sample = try await collector.sample()
    XCTAssertEqual(sample.memory, .unavailable(.commandFailed)); XCTAssertEqual(sample.swap, .unavailable(.commandFailed))
    XCTAssertEqual(sample.disks, .unavailable(.invalidData))
    XCTAssertNotNil(sample.cpu.value); XCTAssertNotNil(sample.network.value)
    XCTAssertEqual(sample.identity.operatingSystem.value, "$(touch /tmp/termes-monitor-evaluated) Literal Linux")
    _ = try await server.execute(["sh", "-c", "test ! -e /tmp/termes-monitor-evaluated"])
    _ = try await server.execute(["sh", "-c", "mkdir -p /usr/lib; rm -f /usr/lib/os-release; printf 'PRETTY_NAME=\"Vendor Linux\"\\n' > /usr/lib/os-release; chmod 000 /etc/os-release"])
    let denied = try await collector.sample()
    XCTAssertEqual(denied.identity.operatingSystem, .unavailable(.commandFailed), "an unreadable /etc file must not fall back")
    _ = try await server.execute(["rm", "-f", "/etc/os-release"])
    let vendor = try await collector.sample()
    XCTAssertEqual(vendor.identity.operatingSystem.value, "Vendor Linux")
    _ = try await server.execute(["sh", "-c", "printf '#!/bin/sh\\nprintf Darwin\\n' > /tmp/termes-monitor-bin/uname; chmod +x /tmp/termes-monitor-bin/uname"])
    do { _ = try await collector.sample(); XCTFail("unsupported system") }
    catch { XCTAssertEqual(error as? ServerMonitoringError, .unsupportedPlatform("Darwin")) }
    _ = try await server.execute(["sh", "-c", "printf '#!/bin/sh\\nexit 23\\n' > /tmp/termes-monitor-wrapper"])
    do { _ = try await collector.sample(); XCTFail("nonzero exit must reject a collection") }
    catch { XCTAssertEqual(error as? ServerMonitoringError, .commandFailed) }
  }

  func test_real_output_limit_and_frozen_server_timeout_are_propagated() async throws {
    let server = try await server(), connection = try await connect(server)
    do {
      _ = try await LinuxServerCollector(connection: connection, options: .init(maximumOutputBytes: 64)).sample()
      XCTFail("bounded output")
    } catch { XCTAssertEqual(error as? SSHCommandError, .outputLimitExceeded) }
    await connection.disconnect()
    try await connection.connect()
    try await server.pause()
    addTeardownBlock { try? await server.resume() }
    let started = Date()
    do {
      _ = try await LinuxServerCollector(connection: connection, options: .init(timeout: 0.1)).sample()
      XCTFail("frozen server")
    } catch { XCTAssertEqual(error as? SSHCommandError, .timedOut) }
    XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    try await server.resume()
    try await connection.connect()
    let recovered = try await LinuxServerCollector(connection: connection).sample()
    XCTAssertNotNil(recovered.memory.value)
  }

  func test_encrypted_key_and_jump_route_collect_the_destination_metrics() async throws {
    let jump = try await server(), target = try await server()
    try await jump.enableTCPForwarding(); try await jump.mapHost("monitor-linux.invalid", to: target)
    let config = ConnectionConfig(hostname: "monitor-linux.invalid", port: 2222, username: target.username,
      auth: .privateKey(data: Data(TestSSHServer.testEncryptedEd25519PrivateKey.utf8), passphrase: TestSSHServer.encryptedKeyPassphrase),
      jumpHosts: [.init(hostname: jump.host, port: jump.port, username: jump.username, auth: .password(jump.password))])
    let connection = SSHConnection(config: config, knownHosts: knownHosts(), confirmUnknownHostKey: { _, _, _ in true })
    addTeardownBlock { await connection.disconnect() }
    try await connection.connect()
    let expected = try await target.execute(["uname", "-n"]).trimmingCharacters(in: .whitespacesAndNewlines)
    let sample = try await LinuxServerCollector(connection: connection).sample()
    XCTAssertEqual(sample.identity.hostname.value, expected); XCTAssertNotNil(sample.memory.value)
  }
}
