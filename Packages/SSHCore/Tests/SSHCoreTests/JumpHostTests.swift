import XCTest
import Darwin
@testable import SSHCore

private actor JumpConfirmations {
  var hosts: [String] = []
  func record(_ host: String, port: Int) { hosts.append("\(host):\(port)") }
}

final class JumpHostTests: XCTestCase {
  private func store() -> KnownHostsStore {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: file) }
    return KnownHostsStore(fileURL: file)
  }
  private func server() async throws -> TestSSHServer {
    let server = try await TestSSHServer.start()
    addTeardownBlock { await server.stop() }
    return server
  }
  private func route(_ jump: TestSSHServer, target: TestSSHServer) async throws -> ConnectionConfig {
    try await jump.enableTCPForwarding()
    try await jump.mapHost("jump-target.invalid", to: target)
    return .init(hostname: "jump-target.invalid", port: 2222, username: "test", auth: .password("test"),
      jumpHosts: [.init(hostname: jump.host, port: jump.port, username: "test", auth: .password("test"))])
  }
  private func shell(_ connection: SSHConnection, marker: String) async throws {
    let channel = try await connection.openShell(cols: 80, rows: 24)
    await channel.send(Data("printf '%s\\n' '\(marker)'; exit\r".utf8))
    var data = Data()
    for await bytes in channel.output { data.append(bytes) }
    XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(marker))
  }

  func test_two_hops_use_remote_dns_and_separate_host_trust_with_terminal_and_binary_sftp() async throws {
    let first = try await server(), second = try await server(), target = try await server()
    try await first.enableTCPForwarding(); try await second.enableTCPForwarding()
    try await first.mapHost("second-hop.invalid", to: second)
    try await second.mapHost("final-target.invalid", to: target)
    let key = Data(TestSSHServer.testEd25519PrivateKeyOpenSSH.utf8)
    let config = ConnectionConfig(hostname: "final-target.invalid", port: 2222, username: "test",
      auth: .privateKey(data: Data(TestSSHServer.testEncryptedEd25519PrivateKey.utf8), passphrase: TestSSHServer.encryptedKeyPassphrase),
      jumpHosts: [.init(hostname: first.host, port: first.port, username: "test", auth: .password("test")),
                  .init(hostname: "second-hop.invalid", port: 2222, username: "test", auth: .privateKey(data: key, passphrase: nil))])
    let known = store(), confirmations = JumpConfirmations()
    let connection = SSHConnection(config: config, knownHosts: known) { host, port, _ in
      await confirmations.record(host, port: port); return true
    }
    addTeardownBlock { await connection.disconnect() }
    try await connection.connect()
    let hosts = await confirmations.hosts
    XCTAssertEqual(hosts, ["127.0.0.1:\(first.port)", "second-hop.invalid:2222", "final-target.invalid:2222"])
    XCTAssertEqual(try known.all().count, 3, "ephemeral loopback endpoints must never enter known hosts")
    try await shell(connection, marker: "TWO_HOP_OK")
    let client = try await SFTPClient.connect(config: config, knownHosts: known, confirmUnknownHostKey: { _, _, _ in false })
    addTeardownBlock { await client.close() }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let input = directory.appendingPathComponent("input"), output = directory.appendingPathComponent("output")
    let bytes = Data((0..<(1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 * 37) })
    try bytes.write(to: input)
    let home = try await client.canonicalPath(".")
    let remote = try RemotePath.child("jump-binary.bin", in: home)
    try await client.upload(input, to: remote)
    // The terminal route can close without breaking the independent SFTP route.
    await connection.disconnect()
    try await client.download(remote, to: output)
    XCTAssertEqual(try Data(contentsOf: output), bytes)
    await client.close()
  }

  func test_local_socks_and_remote_forwarding_use_the_saved_jump_route() async throws {
    let jump = try await server(), target = try await server()
    let config = try await route(jump, target: target)
    try await target.enableTCPForwarding()
    _ = try await target.execute(["sh", "-c", "printf '#!/bin/sh\\ncat\\n' > /tmp/jump-echo; chmod +x /tmp/jump-echo; nohup busybox nc -l -k -s 127.0.0.1 -p 34567 -e /tmp/jump-echo >/tmp/jump-echo.log 2>&1 </dev/null &"])
    let known = store()
    let connection = SSHConnection(config: config, knownHosts: known, confirmUnknownHostKey: { _, _, _ in true })
    try await connection.connect(); await connection.disconnect()
    let local = try await LocalPortForward.start(config: config, knownHosts: known,
      forwarding: .init(localPort: 0, targetHost: "localhost", targetPort: 34567))
    addTeardownBlock { await local.stop() }
    let socks = try await LocalPortForward.start(config: config, knownHosts: known,
      forwarding: .init(localPort: 0, kind: .socks))
    addTeardownBlock { await socks.stop() }
    let service = try ForwardTestService { fd in
      let bytes = try ForwardTestSocket.readToEOF(fd)
      try ForwardTestSocket.write(fd, data: bytes + Data("MAC_RESPONSE".utf8))
    }
    addTeardownBlock { service.stop() }
    let remote = try await RemotePortForward.start(config: config, knownHosts: known,
      forwarding: .init(localPort: 0, targetHost: "localhost", targetPort: service.port, kind: .remote))
    addTeardownBlock { await remote.stop() }
    let bridge = try await LocalPortForward.start(config: config, knownHosts: known,
      forwarding: .init(localPort: 0, targetHost: "localhost", targetPort: remote.localPort))
    addTeardownBlock { await bridge.stop() }
    let bytes = Data((0..<100_000).map { UInt8(truncatingIfNeeded: $0) })
    let localResponse = try await ForwardTestSocket.exchange(port: local.localPort, data: bytes)
    XCTAssertEqual(localResponse, bytes)
    let socksResponse = try await ForwardTestSocket.socksExchange(port: socks.localPort, host: "localhost", targetPort: 34567, data: bytes)
    XCTAssertEqual(socksResponse, bytes)
    let remoteResponse = try await ForwardTestSocket.exchange(port: bridge.localPort, data: bytes)
    XCTAssertEqual(remoteResponse, bytes + Data("MAC_RESPONSE".utf8))
    await bridge.stop(); await remote.stop(); await socks.stop(); await local.stop()
    for port in [bridge.localPort, socks.localPort, local.localPort] {
      let fd = try ForwardTestSocket.listener(port: port); Darwin.close(fd)
    }
    XCTAssertTrue(service.failures.isEmpty)
  }

  func test_rejecting_a_hop_or_target_never_trusts_the_remaining_route() async throws {
    let jump = try await server(), target = try await server()
    let config = try await route(jump, target: target)
    for rejected in [jump.host, config.hostname] {
      let known = store(), confirmations = JumpConfirmations()
      let connection = SSHConnection(config: config, knownHosts: known) { host, port, _ in
        await confirmations.record(host, port: port); return host != rejected
      }
      do { try await connection.connect(); XCTFail("key must be rejected") }
      catch let error as SSHError { XCTAssertEqual(error, .hostKeyRejected) }
      await connection.disconnect()
      XCTAssertEqual(try known.all().count, rejected == jump.host ? 0 : 1)
      let hosts = await confirmations.hosts
      XCTAssertEqual(hosts.count, rejected == jump.host ? 1 : 2)
    }
  }

  func test_changed_jump_and_target_keys_are_rejected_without_confirmation() async throws {
    let jump = try await server(), target = try await server()
    let config = try await route(jump, target: target), known = store()
    let initial = SSHConnection(config: config, knownHosts: known, confirmUnknownHostKey: { _, _, _ in true })
    try await initial.connect(); await initial.disconnect()
    try await target.restart(differentHostKey: true)
    try await jump.mapHost(config.hostname, to: target)
    let confirmations = JumpConfirmations()
    let changedTarget = SSHConnection(config: config, knownHosts: known) { host, port, _ in
      await confirmations.record(host, port: port); return true
    }
    do { try await changedTarget.connect(); XCTFail("changed target key") }
    catch let error as SSHError { guard case .hostKeyMismatch = error else { return XCTFail("\(error)") } }
    await changedTarget.disconnect()
    try await jump.restart(differentHostKey: true)
    let changedJump = SSHConnection(config: config, knownHosts: known) { host, port, _ in
      await confirmations.record(host, port: port); return true
    }
    do { try await changedJump.connect(); XCTFail("changed jump key") }
    catch let error as SSHError { guard case .hostKeyMismatch = error else { return XCTFail("\(error)") } }
    await changedJump.disconnect()
    let hosts = await confirmations.hosts
    XCTAssertTrue(hosts.isEmpty)
  }

  func test_disconnect_cancels_a_paused_hop_and_releases_the_connect_task() async throws {
    let jump = try await server(), target = try await server()
    let config = try await route(jump, target: target)
    try await jump.pause()
    addTeardownBlock { try? await jump.resume() }
    let connection = SSHConnection(config: config, knownHosts: store(), confirmUnknownHostKey: { _, _, _ in true })
    let task = Task { try await connection.connect() }
    try await Task.sleep(for: .milliseconds(200))
    let start = Date()
    await connection.disconnect()
    do { try await task.value; XCTFail("cancelled connect") } catch {}
    XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    try await jump.resume()
  }

  func test_cancellation_at_the_destination_closes_established_hops_and_allows_reuse() async throws {
    let jump = try await server(), target = try await server()
    let config = try await route(jump, target: target), known = store()
    try await target.pause()
    addTeardownBlock { try? await target.resume() }
    let connection = SSHConnection(config: config, knownHosts: known, confirmUnknownHostKey: { _, _, _ in true })
    let task = Task { try await connection.connect() }
    let deadline = Date().addingTimeInterval(5)
    while try known.lookup(hostname: jump.host, port: jump.port) == nil, Date() < deadline {
      try await Task.sleep(for: .milliseconds(15))
    }
    XCTAssertNotNil(try known.lookup(hostname: jump.host, port: jump.port))
    try await Task.sleep(for: .milliseconds(200))
    let start = Date(); task.cancel()
    do { try await task.value; XCTFail("cancelled destination handshake") } catch {}
    await connection.disconnect()
    XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    let remaining = try await jump.execute(["sh", "-c", "netstat -tn | awk '$4 ~ /:2222$/ && $6 == \"ESTABLISHED\" {c++} END {print c+0}'"])
    XCTAssertEqual(remaining.trimmingCharacters(in: .whitespacesAndNewlines), "0", "all hop transports must close")
    try await target.resume()
    try await connection.connect()
    try await shell(connection, marker: "REUSED_ROUTE_OK")
    await connection.disconnect()
  }

  func test_task_cancellation_while_waiting_for_jump_trust_does_not_hang_or_save_trust() async throws {
    let jump = try await server(), target = try await server()
    let config = try await route(jump, target: target), known = store()
    let entered = expectation(description: "waiting for trust")
    let decision = DeferredJumpDecision()
    let connection = SSHConnection(config: config, knownHosts: known) { _, _, _ in
      entered.fulfill()
      return await decision.wait()
    }
    let task = Task { try await connection.connect() }
    await fulfillment(of: [entered], timeout: 5)
    let start = Date(); task.cancel()
    do { try await task.value; XCTFail("cancelled connect") } catch {}
    XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    await decision.answer(true)
    await connection.disconnect()
    XCTAssertTrue(try known.all().isEmpty)
  }

  func test_core_rejects_excessive_jump_routes_before_opening_sockets() async throws {
    let hop = JumpHost(hostname: "127.0.0.1", port: 1, username: "test", auth: .password("test"))
    let connection = SSHConnection(config: .init(hostname: "target.invalid", username: "test", auth: .password("test"),
      jumpHosts: Array(repeating: hop, count: ConnectionConfig.maximumJumpHosts + 1)),
      knownHosts: store(), confirmUnknownHostKey: { _, _, _ in true })
    do { try await connection.connect(); XCTFail("too many hops") }
    catch let error as SSHError {
      guard case .connectionFailed(let message) = error else { return XCTFail("\(error)") }
      XCTAssertTrue(message.contains("最多"))
    }
    await connection.disconnect()
  }
}

private actor DeferredJumpDecision {
  private var continuation: CheckedContinuation<Bool, Never>?
  private var answer: Bool?
  func wait() async -> Bool {
    if let answer { return answer }
    return await withCheckedContinuation { continuation = $0 }
  }
  func answer(_ answer: Bool) {
    self.answer = answer
    continuation?.resume(returning: answer)
    continuation = nil
  }
}
