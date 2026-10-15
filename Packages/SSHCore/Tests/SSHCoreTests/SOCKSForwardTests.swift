import XCTest
import CryptoKit
import Darwin
@testable import SSHCore

private actor SOCKSEvents {
  var values: [LocalForwardEvent] = []
  func append(_ event: LocalForwardEvent) { values.append(event) }
}

final class SOCKSForwardTests: XCTestCase {
  private func pair() throws -> (ForwardSocket, Int32) {
    var fds: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw ForwardTestSocket.Failure(message: "socketpair") }
    try ForwardSocket.configure(fds[0])
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fds[1], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    return (ForwardSocket(fds[0]), fds[1])
  }

  private func forward(_ server: TestSSHServer) async throws -> LocalPortForward {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: file) }
    let store = KnownHostsStore(fileURL: file)
    let blob = Data(base64Encoded: TestSSHServer.hostEd25519PublicKey.split(separator: " ")[1].description)!
    try store.save(.init(hostname: server.host, port: server.port, keyType: "ssh-ed25519", publicKeyBlob: blob,
                         fingerprintSHA256: server.fingerprintSHA256(), addedAt: Date()))
    return try await LocalPortForward.start(config: .init(hostname: server.host, port: server.port,
      username: server.username, auth: .password(server.password)), knownHosts: store,
      forwarding: .init(localPort: 0, kind: .socks))
  }

  func test_configuration_preserves_legacy_local_rules_and_validates_socks() throws {
    let legacy = try JSONDecoder().decode(LocalForwardConfiguration.self,
      from: Data(#"{"localPort":8080,"targetHost":"localhost","targetPort":80}"#.utf8))
    XCTAssertEqual(legacy.kind, .local)
    try legacy.validate()
    let socks = LocalForwardConfiguration(localPort: 1080, kind: .socks)
    try socks.validate()
    XCTAssertEqual(try JSONDecoder().decode(LocalForwardConfiguration.self, from: JSONEncoder().encode(socks)), socks)
    XCTAssertThrowsError(try LocalForwardConfiguration(localPort: -1, kind: .socks).validate())
    XCTAssertThrowsError(try LocalForwardConfiguration(localPort: 65536, kind: .socks).validate())
    XCTAssertThrowsError(try LocalForwardConfiguration(localPort: 1080, targetHost: "stale", kind: .socks).validate())
    XCTAssertThrowsError(try LocalForwardConfiguration(localPort: 1080, targetPort: 80, kind: .socks).validate())
    XCTAssertThrowsError(try JSONDecoder().decode(LocalForwardConfiguration.self,
      from: Data(#"{"localPort":8080,"targetHost":"","targetPort":0,"kind":"future"}"#.utf8)))
  }

  func test_fragmented_ipv4_ipv6_and_domain_requests_leave_pipelined_bytes() async throws {
    let ipv6 = [UInt8](repeating: 0, count: 15) + [1]
    for (address, host) in [(Data([1, 127, 0, 0, 1]), "127.0.0.1"),
                            (Data([4] + ipv6), "::1"),
                            (Data([3, 17]) + Data("xn--fiqs8s.local.".utf8), "xn--fiqs8s.local.")] {
      let (socket, fd) = try pair()
      defer { socket.close(); Darwin.close(fd) }
      let handshake = Task { try await SOCKS5Handshake.negotiate(socket: socket) }
      try await Task.detached {
        for byte in [UInt8](arrayLiteral: 5, 3, 2, 0, 1) { try ForwardTestSocket.write(fd, data: Data([byte])) }
        XCTAssertEqual(try ForwardTestSocket.read(fd, count: 2), Data([5, 0]))
        for byte in Data([5, 1, 0]) + address + Data([0x12, 0x34]) {
          try ForwardTestSocket.write(fd, data: Data([byte]))
        }
        try ForwardTestSocket.write(fd, data: Data("payload".utf8))
      }.value
      let endpoint = try await handshake.value
      XCTAssertEqual(endpoint, .init(host: host, port: 0x1234))
      let remainder = socket.withFD { fd -> Data in
        var bytes = [UInt8](repeating: 0, count: 7)
        let count = recv(fd, &bytes, 7, 0)
        return count > 0 ? Data(bytes.prefix(count)) : Data()
      }
      XCTAssertEqual(remainder, Data("payload".utf8))
    }
  }

  func test_rejects_unsupported_methods_commands_and_malformed_requests() async throws {
    let fixtures: [(Data, Data)] = [
      (Data([5, 1, 2]), Data([5, 255])),
      (Data([5, 1, 0, 5, 2, 0, 1]), Data([5, 0, 5, 7])),
      (Data([5, 1, 0, 5, 3, 0, 1]), Data([5, 0, 5, 7])),
      (Data([5, 1, 0, 5, 1, 0, 99]), Data([5, 0, 5, 8])),
      (Data([5, 1, 0, 5, 1, 1, 1]), Data([5, 0, 5, 1])),
      (Data([5, 1, 0, 4, 1, 0, 1]), Data([5, 0, 5, 1])),
      (Data([5, 1, 0, 5, 1, 0, 3, 0]), Data([5, 0, 5, 8])),
      (Data([5, 1, 0, 5, 1, 0, 3, 3, 97, 0, 98]), Data([5, 0, 5, 8])),
      (Data([5, 1, 0, 5, 1, 0, 3, 2, 32, 97]), Data([5, 0, 5, 8])),
      (Data([5, 1, 0, 5, 1, 0, 1, 127, 0, 0, 1, 0, 0]), Data([5, 0, 5, 1])),
    ]
    for (input, expected) in fixtures {
      let (socket, fd) = try pair()
      defer { socket.close(); Darwin.close(fd) }
      let handshake = Task { try await SOCKS5Handshake.negotiate(socket: socket) }
      let reply = try await Task.detached {
        try ForwardTestSocket.write(fd, data: input)
        return try ForwardTestSocket.read(fd, count: expected.count == 2 ? 2 : 12)
      }.value
      XCTAssertEqual(reply.prefix(expected.count), expected)
      do { _ = try await handshake.value; XCTFail("invalid request accepted") }
      catch let error as LocalForwardError { guard case .socks = error else { return XCTFail("\(error)") } }
    }
    let (socket, fd) = try pair()
    defer { socket.close(); Darwin.close(fd) }
    let truncated = Task { try await SOCKS5Handshake.negotiate(socket: socket) }
    try ForwardTestSocket.write(fd, data: Data([5, 1]))
    shutdown(fd, SHUT_WR)
    do { _ = try await truncated.value; XCTFail("truncated greeting accepted") } catch {}
  }

  func test_silent_client_deadline_and_cancellation_are_prompt() async throws {
    let (socket, fd) = try pair()
    defer { socket.close(); Darwin.close(fd) }
    let start = Date()
    do { _ = try await SOCKS5Handshake.negotiate(socket: socket, timeout: 0.1); XCTFail("silent client accepted") }
    catch let error as LocalForwardError { XCTAssertTrue(error.localizedDescription.contains("超时")) }
    XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    let task = Task { try await SOCKS5Handshake.negotiate(socket: socket) }
    try await Task.sleep(for: .milliseconds(30))
    let cancelled = Date()
    task.cancel()
    do { _ = try await task.value; XCTFail("cancelled handshake accepted") } catch is CancellationError {}
    XCTAssertLessThan(Date().timeIntervalSince(cancelled), 1)
  }

  func test_real_server_resolves_domains_and_accepts_concurrent_address_types() async throws {
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    try await server.enableTCPForwarding()
    _ = try await server.execute(["sh", "-c", "printf '\\n127.0.0.1 termes-socks-only.invalid\\n' >> /etc/hosts"])
    let proxy = try await forward(server); addTeardownBlock { await proxy.stop() }
    try await withThrowingTaskGroup(of: Void.self) { group in
      for host in ["termes-socks-only.invalid", "127.0.0.1", "::1", "localhost"] {
        group.addTask {
          let response = try await ForwardTestSocket.socksExchange(port: proxy.localPort, host: host, targetPort: 2222)
          XCTAssertTrue(String(decoding: response, as: UTF8.self).contains("SSH-"))
        }
      }
      try await group.waitForAll()
    }
    let port = proxy.localPort
    await proxy.stop()
    let listener = try ForwardTestSocket.listener(port: port); Darwin.close(listener)
  }

  func test_binary_pipelined_payload_half_close_and_complete_response() async throws {
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    try await server.enableTCPForwarding()
    _ = try await server.execute(["sh", "-c", "dd if=/dev/zero of=/tmp/socks-response bs=1048576 count=2 2>/dev/null; printf '#!/bin/sh\\ncat > /tmp/socks-request\\ncat /tmp/socks-response\\n' > /tmp/socks-service; chmod +x /tmp/socks-service; nohup busybox nc -l -s 127.0.0.1 -p 34567 -e /tmp/socks-service >/tmp/socks-service.log 2>&1 </dev/null &"])
    let proxy = try await forward(server); addTeardownBlock { await proxy.stop() }
    let input = Data((0..<(1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 * 37) })
    let response = try await ForwardTestSocket.socksExchange(port: proxy.localPort, host: "localhost", targetPort: 34567, data: input)
    XCTAssertEqual(response, Data(repeating: 0, count: 2 * 1024 * 1024))
    let hash = SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    let remote = try await server.execute(["sha256sum", "/tmp/socks-request"])
    XCTAssertTrue(remote.hasPrefix(hash))
  }

  func test_target_failure_keeps_listener_and_transport_loss_closes_idle_handshake() async throws {
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    try await server.enableTCPForwarding()
    let proxy = try await forward(server); addTeardownBlock { await proxy.stop() }
    let recorder = SOCKSEvents()
    let recording = Task { for await event in proxy.events { await recorder.append(event) } }
    defer { recording.cancel() }
    let reply = try await Task.detached {
      let fd = try ForwardTestSocket.open(port: proxy.localPort); defer { Darwin.close(fd) }
      try ForwardTestSocket.write(fd, data: Data([5, 1, 0]) + ForwardTestSocket.socksRequest(host: "localhost", port: 1))
      let reply = try ForwardTestSocket.read(fd, count: 12)
      XCTAssertTrue(try ForwardTestSocket.readToEOF(fd).isEmpty)
      return reply
    }.value
    XCTAssertEqual(reply[3], 1)
    let banner = try await ForwardTestSocket.socksExchange(port: proxy.localPort, host: "localhost", targetPort: 2222)
    XCTAssertTrue(String(decoding: banner, as: UTF8.self).contains("SSH-"))
    let idle = try ForwardTestSocket.open(port: proxy.localPort); defer { Darwin.close(idle) }
    await server.stop()
    let deadline = Date().addingTimeInterval(5)
    while !(await recorder.values.contains { if case .stopped = $0 { return true }; return false }), Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    let events = await recorder.values
    XCTAssertTrue(events.contains { if case .clientError = $0 { return true }; return false })
    XCTAssertTrue(events.contains { if case .stopped(let error) = $0 { return error != nil }; return false })
    let start = Date(); await proxy.stop()
    XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    XCTAssertThrowsError(try ForwardTestSocket.open(port: proxy.localPort))
  }

  func test_client_limit_includes_incomplete_handshakes_and_stop_releases_them() async throws {
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    try await server.enableTCPForwarding()
    let proxy = try await forward(server); addTeardownBlock { await proxy.stop() }
    let recorder = SOCKSEvents()
    let recording = Task { for await event in proxy.events { await recorder.append(event) } }
    defer { recording.cancel() }
    var fds: [Int32] = []
    defer { fds.forEach { Darwin.close($0) } }
    for _ in 0..<32 { fds.append(try ForwardTestSocket.open(port: proxy.localPort)) }
    let deadline = Date().addingTimeInterval(5)
    while !(await recorder.values.contains(.clients(32))), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    let events = await recorder.values
    XCTAssertTrue(events.contains(.clients(32)))
    let rejected = try await ForwardTestSocket.exchange(port: proxy.localPort, data: Data())
    XCTAssertTrue(rejected.isEmpty)
    let start = Date(); await proxy.stop()
    XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    let listener = try ForwardTestSocket.listener(port: proxy.localPort); Darwin.close(listener)
  }
}
