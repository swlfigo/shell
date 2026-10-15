import XCTest
import Darwin
@testable import SSHCore

private actor RemoteEvents {
  var values: [LocalForwardEvent] = []
  func append(_ event: LocalForwardEvent) { values.append(event) }
}

final class RemotePortForwardTests: XCTestCase {
  private func config(_ server: TestSSHServer) -> ConnectionConfig {
    .init(hostname: server.host, port: server.port, username: server.username, auth: .password(server.password))
  }
  private func trusted(_ server: TestSSHServer) throws -> KnownHostsStore {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: file) }
    let store = KnownHostsStore(fileURL: file)
    let blob = Data(base64Encoded: TestSSHServer.hostEd25519PublicKey.split(separator: " ")[1].description)!
    try store.save(.init(hostname: server.host, port: server.port, keyType: "ssh-ed25519", publicKeyBlob: blob,
                         fingerprintSHA256: server.fingerprintSHA256(), addedAt: Date()))
    return store
  }
  private func remote(_ server: TestSSHServer, target: Int, port: Int = 0, host: String = "127.0.0.1") async throws -> RemotePortForward {
    try await RemotePortForward.start(config: config(server), knownHosts: trusted(server),
      forwarding: .init(localPort: port, targetHost: "localhost", targetPort: target, kind: .remote, listenHost: host))
  }
  private func bridge(_ server: TestSSHServer, port: Int, host: String = "127.0.0.1") async throws -> LocalPortForward {
    try await LocalPortForward.start(config: config(server), knownHosts: trusted(server),
      forwarding: .init(localPort: 0, targetHost: host, targetPort: port))
  }

  func test_configuration_supports_remote_addresses_and_preserves_older_defaults() throws {
    let old = try JSONDecoder().decode(LocalForwardConfiguration.self,
      from: Data(#"{"localPort":8080,"targetHost":"localhost","targetPort":80,"kind":"local"}"#.utf8))
    XCTAssertEqual(old.listenHost, "127.0.0.1")
    for host in ["127.0.0.1", "::1", "0.0.0.0", "::", "192.0.2.77", "listen.example"] {
      let rule = LocalForwardConfiguration(localPort: 0, targetHost: "::1", targetPort: 65535, kind: .remote, listenHost: host)
      try rule.validate()
      XCTAssertEqual(try JSONDecoder().decode(LocalForwardConfiguration.self, from: JSONEncoder().encode(rule)), rule)
    }
    for rule in [LocalForwardConfiguration(localPort: 1, targetHost: "localhost", targetPort: 80, listenHost: "0.0.0.0"),
                 .init(localPort: 1, kind: .socks, listenHost: "::1"),
                 .init(localPort: 1, targetHost: "localhost", targetPort: 80, kind: .remote, listenHost: "bad\0host"),
                 .init(localPort: 1, targetHost: "localhost", targetPort: 80, kind: .remote, listenHost: ""),
                 .init(localPort: 1, targetHost: "localhost", targetPort: 80, kind: .remote, listenHost: "bad host"),
                 .init(localPort: 1, targetHost: "", targetPort: 80, kind: .remote),
                 .init(localPort: 1, targetHost: "localhost", targetPort: 0, kind: .remote)] {
      XCTAssertThrowsError(try rule.validate())
    }
  }

  func test_binary_concurrent_clients_half_close_and_server_port_release() async throws {
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    try await server.enableTCPForwarding()
    let service = try ForwardTestService { fd in
      let input = try ForwardTestSocket.readToEOF(fd)
      try ForwardTestSocket.write(fd, data: input + Data(repeating: 0, count: 1024 * 1024))
    }
    addTeardownBlock { service.stop() }
    let forward = try await remote(server, target: service.port); addTeardownBlock { await forward.stop() }
    let client = try await bridge(server, port: forward.localPort); addTeardownBlock { await client.stop() }
    let data = Data((0..<(1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 * 37) })
    let response = try await ForwardTestSocket.exchange(port: client.localPort, data: data)
    XCTAssertEqual(response, data + Data(repeating: 0, count: 1024 * 1024))
    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<4 {
        group.addTask {
          let input = Data(repeating: UInt8(index), count: 65536)
          let response = try await ForwardTestSocket.exchange(port: client.localPort, data: input)
          XCTAssertEqual(response, input + Data(repeating: 0, count: 1024 * 1024))
        }
      }
      try await group.waitForAll()
    }
    XCTAssertTrue(service.failures.isEmpty, "\(service.failures)")
    await forward.stop()
    let replacement = try await remote(server, target: service.port, port: forward.localPort)
    await replacement.stop()
  }

  func test_target_refusal_isolated_then_local_service_recovers_without_restart() async throws {
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    try await server.enableTCPForwarding()
    let reservation = try ForwardTestSocket.listener()
    let port = try ForwardTestSocket.boundPort(reservation).port; Darwin.close(reservation)
    let forward = try await remote(server, target: port); addTeardownBlock { await forward.stop() }
    let recorder = RemoteEvents()
    let task = Task { for await event in forward.events { await recorder.append(event) } }; defer { task.cancel() }
    let client = try await bridge(server, port: forward.localPort); addTeardownBlock { await client.stop() }
    let rejected = try await ForwardTestSocket.exchange(port: client.localPort, data: Data())
    XCTAssertTrue(rejected.isEmpty)
    let service = try ForwardTestService(port: port) { fd in
      _ = try ForwardTestSocket.readToEOF(fd)
      try ForwardTestSocket.write(fd, data: Data("recovered".utf8))
    }
    addTeardownBlock { service.stop() }
    let response = try await ForwardTestSocket.exchange(port: client.localPort, data: Data())
    XCTAssertEqual(response, Data("recovered".utf8))
    let events = await recorder.values
    XCTAssertTrue(events.contains { if case .clientError = $0 { return true }; return false })
    XCTAssertFalse(events.contains { if case .stopped = $0 { return true }; return false })
  }

  func test_server_denial_bind_conflict_host_trust_and_encrypted_private_key() async throws {
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    do { let forward = try await remote(server, target: 80); await forward.stop(); XCTFail("server disallows forwarding") }
    catch let error as LocalForwardError { guard case .remoteListen = error else { return XCTFail("\(error)") } }
    try await server.enableTCPForwarding()
    let key = ConnectionConfig(hostname: server.host, port: server.port, username: server.username,
      auth: .privateKey(data: Data(TestSSHServer.testEncryptedEd25519PrivateKey.utf8), passphrase: TestSSHServer.encryptedKeyPassphrase))
    let forward = try await RemotePortForward.start(config: key, knownHosts: trusted(server),
      forwarding: .init(localPort: 0, targetHost: "localhost", targetPort: 80, kind: .remote))
    addTeardownBlock { await forward.stop() }
    do { let duplicate = try await remote(server, target: 80, port: forward.localPort); await duplicate.stop(); XCTFail("occupied server port") }
    catch let error as LocalForwardError { guard case .remoteListen = error else { return XCTFail("\(error)") } }
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    do {
      let unknown = try await RemotePortForward.start(config: config(server), knownHosts: KnownHostsStore(fileURL: file),
        forwarding: .init(localPort: 0, targetHost: "localhost", targetPort: 80, kind: .remote))
      await unknown.stop(); XCTFail("unknown key accepted")
    } catch let error as SSHError { XCTAssertEqual(error, .hostKeyRejected) }
  }

  func test_backpressure_does_not_block_other_clients_and_stop_is_prompt() async throws {
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    try await server.enableTCPForwarding()
    let service = try ForwardTestService { fd in
      let request = try ForwardTestSocket.read(fd, count: 1)
      if request[0] == 0 { try ForwardTestSocket.write(fd, data: Data(repeating: 0, count: 64 * 1024 * 1024)) }
      else { try ForwardTestSocket.write(fd, data: Data("healthy".utf8)) }
      shutdown(fd, SHUT_WR)
      _ = try ForwardTestSocket.readToEOF(fd)
    }
    addTeardownBlock { service.stop() }
    let forward = try await remote(server, target: service.port); addTeardownBlock { await forward.stop() }
    let client = try await bridge(server, port: forward.localPort); addTeardownBlock { await client.stop() }
    let fd = try ForwardTestSocket.open(port: client.localPort); defer { Darwin.close(fd) }
    var size: Int32 = 4096
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
    try ForwardTestSocket.write(fd, data: Data([0]))
    try await Task.sleep(for: .milliseconds(500))
    let started = Date()
    let healthy = try await ForwardTestSocket.exchange(port: client.localPort, data: Data([1]))
    XCTAssertEqual(healthy, Data("healthy".utf8))
    XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    let stop = Date(); await forward.stop()
    XCTAssertLessThan(Date().timeIntervalSince(stop), 2)
    let replacement = try await remote(server, target: service.port, port: forward.localPort); await replacement.stop()
  }

  func test_client_limit_and_idle_transport_loss_release_local_targets() async throws {
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    try await server.enableTCPForwarding()
    let service = try ForwardTestService { fd in _ = try ForwardTestSocket.readToEOF(fd) }
    addTeardownBlock { service.stop() }
    let forward = try await remote(server, target: service.port); addTeardownBlock { await forward.stop() }
    let recorder = RemoteEvents()
    let task = Task { for await event in forward.events { await recorder.append(event) } }; defer { task.cancel() }
    _ = try await server.execute(["sh", "-c", "for i in $(seq 1 32); do nohup sh -c 'sleep 60 | busybox nc 127.0.0.1 \(forward.localPort)' >/tmp/remote-client-$i.log 2>&1 </dev/null & done"])
    var deadline = Date().addingTimeInterval(5)
    while !(await recorder.values.contains(.clients(32))), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    let connected = await recorder.values
    XCTAssertTrue(connected.contains(.clients(32)))
    deadline = Date().addingTimeInterval(3)
    while service.clientCount < 32, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertEqual(service.clientCount, 32)
    _ = try await server.execute(["sh", "-c", "busybox nc 127.0.0.1 \(forward.localPort) </dev/null >/tmp/remote-rejected.log"])
    deadline = Date().addingTimeInterval(3)
    while !(await recorder.values.contains(.clientError(LocalForwardError.tooManyClients.localizedDescription))), Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    let limited = await recorder.values
    XCTAssertTrue(limited.contains(.clientError(LocalForwardError.tooManyClients.localizedDescription)))
    await server.stop()
    deadline = Date().addingTimeInterval(3)
    while !(await recorder.values.contains { if case .stopped = $0 { return true }; return false }), Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    let lost = await recorder.values
    XCTAssertTrue(lost.contains { if case .stopped(let error) = $0 { return error != nil }; return false })
    await forward.stop()
    deadline = Date().addingTimeInterval(3)
    while service.clientCount > 0, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertEqual(service.clientCount, 0)
  }

  func test_cancelled_handshake_does_not_leave_remote_listener() async throws {
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    try await server.enableTCPForwarding(); try await server.pause()
    let config = config(server), store = try trusted(server)
    let task = Task { try await RemotePortForward.start(config: config, knownHosts: store,
      forwarding: .init(localPort: 37111, targetHost: "localhost", targetPort: 80, kind: .remote)) }
    try await Task.sleep(for: .milliseconds(200))
    let start = Date(); task.cancel()
    do { let forward = try await task.value; await forward.stop(); XCTFail("cancelled start succeeded") } catch is CancellationError {}
    XCTAssertLessThan(Date().timeIntervalSince(start), 2)
  }

  func test_requested_ipv4_ipv6_and_wildcard_bind_addresses() async throws {
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    try await server.enableTCPForwarding()
    _ = try await server.execute(["sh", "-c", "sed -i '/^GatewayPorts /d' /config/sshd/sshd_config; sed -i '1iGatewayPorts clientspecified' /config/sshd/sshd_config; kill -HUP $(cat /config/sshd.pid)"])
    let service = try ForwardTestService { fd in
      _ = try ForwardTestSocket.readToEOF(fd)
      try ForwardTestSocket.write(fd, data: Data("addresses".utf8))
    }
    addTeardownBlock { service.stop() }
    let containerIP = try await server.execute(["hostname", "-i"]).trimmingCharacters(in: .whitespacesAndNewlines)
    for (host, destination) in [("127.0.0.1", "127.0.0.1"), ("::1", "::1"), ("0.0.0.0", containerIP), ("::", "::1"), (containerIP, containerIP)] {
      let forward = try await remote(server, target: service.port, host: host)
      let client = try await bridge(server, port: forward.localPort, host: destination)
      do {
        let response = try await ForwardTestSocket.exchange(port: client.localPort, data: Data())
        XCTAssertEqual(response, Data("addresses".utf8), "requested bind \(host)")
        let listeners = try await server.execute(["netstat", "-lnt"])
        let endpoint = host == "::" ? ":::" : (host == "::1" ? "::1:" : host + ":")
        XCTAssertTrue(listeners.contains(endpoint + String(forward.localPort)), listeners)
      } catch { await client.stop(); await forward.stop(); throw error }
      await client.stop(); await forward.stop()
    }
  }

  func test_heartbeat_reply_and_stop_while_waiting_for_frozen_server() async throws {
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    try await server.enableTCPForwarding()
    let service = try ForwardTestService { fd in
      _ = try ForwardTestSocket.readToEOF(fd)
      try ForwardTestSocket.write(fd, data: Data("heartbeat".utf8))
    }
    addTeardownBlock { service.stop() }
    let forward = try await remote(server, target: service.port); addTeardownBlock { await forward.stop() }
    let client = try await bridge(server, port: forward.localPort); addTeardownBlock { await client.stop() }
    try await Task.sleep(for: .seconds(16))
    let response = try await ForwardTestSocket.exchange(port: client.localPort, data: Data())
    XCTAssertEqual(response, Data("heartbeat".utf8), "the control heartbeat must leave data channels usable")
    try await server.pause()
    try await Task.sleep(for: .seconds(15))
    let start = Date(); await forward.stop()
    XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    try await server.resume()
    let replacement = try await remote(server, target: service.port, port: forward.localPort); await replacement.stop()
  }

  func test_idle_frozen_server_heartbeat_timeout_stops_rule_and_releases_port() async throws {
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    try await server.enableTCPForwarding()
    let forward = try await remote(server, target: 80); addTeardownBlock { await forward.stop() }
    let recorder = RemoteEvents()
    let task = Task { for await event in forward.events { await recorder.append(event) } }; defer { task.cancel() }
    try await server.pause()
    let deadline = Date().addingTimeInterval(35)
    while !(await recorder.values.contains { if case .stopped = $0 { return true }; return false }), Date() < deadline {
      try await Task.sleep(for: .milliseconds(100))
    }
    let events = await recorder.values
    XCTAssertTrue(events.contains { if case .stopped(let error) = $0 { return error?.contains("心跳超时") == true }; return false })
    await forward.stop()
    try await server.resume()
    let replacement = try await remote(server, target: 80, port: forward.localPort); await replacement.stop()
  }
}
