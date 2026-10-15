import XCTest
import CryptoKit
import Darwin
@testable import SSHCore

private actor ForwardEventRecorder {
  var recorded: [LocalForwardEvent] = []
  func append(_ event: LocalForwardEvent) { recorded.append(event) }
}

final class LocalPortForwardTests: XCTestCase {
  private func trusted(_ server: TestSSHServer) throws -> KnownHostsStore {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    let store = KnownHostsStore(fileURL: url)
    let blob = Data(base64Encoded: TestSSHServer.hostEd25519PublicKey.split(separator: " ")[1].description)!
    try store.save(.init(hostname: server.host, port: server.port, keyType: "ssh-ed25519", publicKeyBlob: blob,
                         fingerprintSHA256: server.fingerprintSHA256(), addedAt: Date()))
    return store
  }
  private func config(_ server: TestSSHServer) -> ConnectionConfig {
    .init(hostname: server.host, port: server.port, username: server.username, auth: .password(server.password))
  }

  func test_configuration_rejects_invalid_ports_and_hosts() throws {
    for value in [LocalForwardConfiguration(localPort: -1, targetHost: "localhost", targetPort: 80),
                  .init(localPort: 65536, targetHost: "localhost", targetPort: 80),
                  .init(localPort: 1, targetHost: "localhost", targetPort: 0),
                  .init(localPort: 1, targetHost: "bad\0host", targetPort: 80),
                  .init(localPort: 1, targetHost: "bad host", targetPort: 80),
                  .init(localPort: 1, targetHost: " ", targetPort: 80)] {
      XCTAssertThrowsError(try value.validate())
    }
    try LocalForwardConfiguration(localPort: 0, targetHost: " ::1 ", targetPort: 65535).validate()
  }

  func test_loopback_listener_concurrent_clients_and_stop_release_port() async throws {
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    try await server.enableTCPForwarding()
    let forward = try await LocalPortForward.start(config: config(server), knownHosts: trusted(server),
      forwarding: .init(localPort: 0, targetHost: "localhost", targetPort: 2222))
    addTeardownBlock { await forward.stop() }
    let fd = try ForwardTestSocket.open(port: forward.localPort)
    defer { Darwin.close(fd) }
    // An IPv4 loopback connection succeeds; occupying the same port must fail.
    XCTAssertThrowsError(try ForwardTestSocket.listener(port: forward.localPort))
    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<4 {
        let port = forward.localPort
        group.addTask {
          let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
          defer { try? FileManager.default.removeItem(at: file) }
          let store = KnownHostsStore(fileURL: file)
          let connection = SSHConnection(config: .init(hostname: "127.0.0.1", port: port, username: "test", auth: .password("test")),
                                          knownHosts: store, confirmUnknownHostKey: { _, _, _ in true })
          do {
            try await connection.connect()
            let channel = try await connection.openShell(cols: 80, rows: 24)
            await channel.send(Data("printf 'FORWARDED_%s\\n' '\(index)'; exit\r".utf8))
            var output = ""
            for await data in channel.output { output += String(decoding: data, as: UTF8.self) }
            XCTAssertTrue(output.contains("FORWARDED_\(index)"))
            await connection.disconnect()
          } catch { await connection.disconnect(); throw error }
        }
      }
      try await group.waitForAll()
    }
    let port = forward.localPort
    await forward.stop()
    // Stop closes both established and pending accepted clients and frees the listening port.
    let newListener = try ForwardTestSocket.listener(port: port)
    Darwin.close(newListener)
    XCTAssertThrowsError(try ForwardTestSocket.open(port: port))
  }

  func test_large_binary_transfer_preserves_local_half_close_and_remote_response() async throws {
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    try await server.enableTCPForwarding()
    _ = try await server.execute(["sh", "-c", "dd if=/dev/zero of=/tmp/forward-response bs=1048576 count=2 2>/dev/null; printf '#!/bin/sh\\ncat > /tmp/forward-request\\ncat /tmp/forward-response\\n' > /tmp/forward-service; chmod +x /tmp/forward-service; nohup busybox nc -l -s 127.0.0.1 -p 34567 -e /tmp/forward-service >/tmp/forward-service.log 2>&1 </dev/null &"])
    let forward = try await LocalPortForward.start(config: config(server), knownHosts: trusted(server),
      forwarding: .init(localPort: 0, targetHost: "127.0.0.1", targetPort: 34567))
    addTeardownBlock { await forward.stop() }
    let input = Data((0..<(1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 * 37) })
    let output = try await ForwardTestSocket.exchange(port: forward.localPort, data: input)
    XCTAssertEqual(output, Data(repeating: 0, count: 2 * 1024 * 1024))
    let hash = SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    let remoteHash = try await server.execute(["sha256sum", "/tmp/forward-request"])
    XCTAssertTrue(remoteHash.hasPrefix(hash), "all local bytes must arrive before forwarding EOF")
  }

  func test_bind_conflict_and_untrusted_host_fail_without_listener() async throws {
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    try await server.enableTCPForwarding()
    let listener = try ForwardTestSocket.listener(); defer { Darwin.close(listener) }
    let port = try ForwardTestSocket.boundPort(listener).port
    do {
      _ = try await LocalPortForward.start(config: config(server), knownHosts: trusted(server),
        forwarding: .init(localPort: port, targetHost: "localhost", targetPort: 2222))
      XCTFail("occupied port must fail")
    } catch let error as LocalForwardError {
      guard case .listen = error else { return XCTFail("\(error)") }
    }
    let store = KnownHostsStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    do {
      _ = try await LocalPortForward.start(config: config(server), knownHosts: store,
        forwarding: .init(localPort: 0, targetHost: "localhost", targetPort: 2222))
      XCTFail("forward must not silently trust a new host")
    } catch let error as SSHError { XCTAssertEqual(error, .hostKeyRejected) }
  }

  func test_target_failure_is_reported_and_transport_loss_closes_listener() async throws {
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    try await server.enableTCPForwarding()
    let forward = try await LocalPortForward.start(config: config(server), knownHosts: trusted(server),
      forwarding: .init(localPort: 0, targetHost: "127.0.0.1", targetPort: 1))
    addTeardownBlock { await forward.stop() }
    let recorder = ForwardEventRecorder()
    let task = Task { for await event in forward.events { await recorder.append(event) } }
    defer { task.cancel() }
    let result = try await ForwardTestSocket.exchange(port: forward.localPort, data: Data())
    XCTAssertEqual(result, Data())
    var deadline = Date().addingTimeInterval(10)
    while !(await recorder.recorded.contains { if case .clientError = $0 { return true }; return false }), Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    let errors = await recorder.recorded
    XCTAssertTrue(errors.contains { if case .clientError = $0 { return true }; return false })
    // A target refusal leaves the listener available.
    let fd = try ForwardTestSocket.open(port: forward.localPort)
    defer { Darwin.close(fd) }
    await server.stop()
    deadline = Date().addingTimeInterval(10)
    while !(await recorder.recorded.contains { if case .stopped = $0 { return true }; return false }), Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    let events = await recorder.recorded
    XCTAssertTrue(events.contains { if case .stopped(let error) = $0 { return error != nil }; return false })
    await forward.stop()
    XCTAssertThrowsError(try ForwardTestSocket.open(port: forward.localPort))
  }

  func test_cancel_during_ssh_handshake_is_prompt_and_never_opens_listener() async throws {
    let slowServer = try ForwardTestSocket.listener()
    defer { Darwin.close(slowServer) }
    let sshPort = try ForwardTestSocket.boundPort(slowServer).port
    let reservation = try ForwardTestSocket.listener()
    let localPort = try ForwardTestSocket.boundPort(reservation).port
    Darwin.close(reservation)
    let store = KnownHostsStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let task = Task {
      try await LocalPortForward.start(config: .init(hostname: "127.0.0.1", port: sshPort,
        username: "test", auth: .password("test")), knownHosts: store,
        forwarding: .init(localPort: localPort, targetHost: "localhost", targetPort: 80))
    }
    try await Task.sleep(for: .milliseconds(200))
    let start = Date()
    task.cancel()
    do { let forward = try await task.value; await forward.stop(); XCTFail("cancelled start must fail") }
    catch is CancellationError {}
    XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    let listener = try ForwardTestSocket.listener(port: localPort)
    Darwin.close(listener)
  }

  func test_private_key_authentication_and_wrong_password() async throws {
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    try await server.enableTCPForwarding()
    let store = try trusted(server)
    let keyConfig = ConnectionConfig(hostname: server.host, port: server.port, username: server.username,
      auth: .privateKey(data: Data(TestSSHServer.testEncryptedEd25519PrivateKey.utf8), passphrase: TestSSHServer.encryptedKeyPassphrase))
    let forward = try await LocalPortForward.start(config: keyConfig, knownHosts: store,
      forwarding: .init(localPort: 0, targetHost: "localhost", targetPort: 2222))
    let result = try await ForwardTestSocket.exchange(port: forward.localPort, data: Data())
    XCTAssertTrue(String(decoding: result, as: UTF8.self).contains("SSH-"))
    await forward.stop()
    do {
      let wrong = ConnectionConfig(hostname: server.host, port: server.port, username: server.username, auth: .password("wrong"))
      let forward = try await LocalPortForward.start(config: wrong, knownHosts: store,
        forwarding: .init(localPort: 0, targetHost: "localhost", targetPort: 2222))
      await forward.stop(); XCTFail("bad credentials must fail")
    } catch let error as SSHError { XCTAssertEqual(error, .authenticationFailed) }
  }

  func test_stop_under_remote_backpressure_is_prompt_and_releases_port() async throws {
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    try await server.enableTCPForwarding()
    _ = try await server.execute(["sh", "-c", "printf '#!/bin/sh\\ndd if=/dev/zero bs=1048576 count=64 2>/dev/null\\n' > /tmp/forward-service; chmod +x /tmp/forward-service; nohup busybox nc -l -s 127.0.0.1 -p 34567 -e /tmp/forward-service >/tmp/forward-service.log 2>&1 </dev/null &"])
    let forward = try await LocalPortForward.start(config: config(server), knownHosts: trusted(server),
      forwarding: .init(localPort: 0, targetHost: "127.0.0.1", targetPort: 34567))
    addTeardownBlock { await forward.stop() }
    let fd = try ForwardTestSocket.open(port: forward.localPort)
    defer { Darwin.close(fd) }
    var size: Int32 = 4096
    setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
    // The target writes 64 MiB while this client never reads, filling both bounded buffers.
    try await Task.sleep(for: .milliseconds(500))
    let start = Date()
    await forward.stop()
    XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    let listener = try ForwardTestSocket.listener(port: forward.localPort)
    Darwin.close(listener)
  }


  func test_client_limit_and_stop_cancel_all_pending_authentication() async throws {
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    try await server.enableTCPForwarding()
    let forward = try await LocalPortForward.start(config: config(server), knownHosts: trusted(server),
      forwarding: .init(localPort: 0, targetHost: "localhost", targetPort: 2222))
    addTeardownBlock { await forward.stop() }
    let recorder = ForwardEventRecorder()
    let events = Task { for await event in forward.events { await recorder.append(event) } }
    defer { events.cancel() }
    try await server.pause()
    var clients: [Int32] = []
    defer { clients.forEach { Darwin.close($0) } }
    for _ in 0..<32 { clients.append(try ForwardTestSocket.open(port: forward.localPort)) }
    var deadline = Date().addingTimeInterval(10)
    while !(await recorder.recorded.contains(.clients(32))), Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    let accepted = await recorder.recorded
    XCTAssertTrue(accepted.contains(.clients(32)))
    let rejected = try await ForwardTestSocket.exchange(port: forward.localPort, data: Data())
    XCTAssertTrue(rejected.isEmpty)
    deadline = Date().addingTimeInterval(3)
    while !(await recorder.recorded.contains(.clientError(LocalForwardError.tooManyClients.localizedDescription))), Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    let recorded = await recorder.recorded
    XCTAssertTrue(recorded.contains(.clientError(LocalForwardError.tooManyClients.localizedDescription)))
    let start = Date()
    await forward.stop()
    XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    let listener = try ForwardTestSocket.listener(port: forward.localPort)
    Darwin.close(listener)
  }

}
