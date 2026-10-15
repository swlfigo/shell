import Foundation
import XCTest
@testable import SSHCore

@MainActor
final class ServerMonitoringClientTests: XCTestCase {
  private func server() async throws -> TestSSHServer {
    let server = try await TestSSHServer.start()
    addTeardownBlock { await server.stop() }
    return server
  }
  private func store() -> KnownHostsStore {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return .init(fileURL: url)
  }
  private func config(_ server: TestSSHServer) -> ConnectionConfig {
    .init(hostname: server.host, port: server.port, username: server.username, auth: .password(server.password))
  }
  private func trust(_ config: ConnectionConfig, store: KnownHostsStore) async throws -> SSHConnection {
    let connection = SSHConnection(config: config, knownHosts: store, confirmUnknownHostKey: { _, _, _ in true })
    addTeardownBlock { await connection.disconnect() }
    try await connection.connect()
    return connection
  }

  func test_unknown_and_changed_keys_are_rejected_without_changing_trust_store() async throws {
    let server = try await server(), store = store(), config = config(server)
    do { _ = try await SSHServerMonitoringClient.connect(config: config, knownHosts: store); XCTFail("untrusted key") }
    catch { XCTAssertEqual(error as? SSHError, .hostKeyRejected) }
    XCTAssertTrue(try store.all().isEmpty)
    let terminal = try await trust(config, store: store)
    let trusted = try XCTUnwrap(store.lookup(hostname: config.hostname, port: config.port))
    let client = try await SSHServerMonitoringClient.connect(config: config, knownHosts: store)
    addTeardownBlock { await client.close() }
    let sample = try await client.sample()
    XCTAssertNotNil(sample.memory.value)
    await client.close(); await terminal.disconnect()
    try await server.restart(differentHostKey: true)
    do { _ = try await SSHServerMonitoringClient.connect(config: config, knownHosts: store); XCTFail("changed key") }
    catch { guard case .hostKeyMismatch = error as? SSHError else { return XCTFail("expected mismatch: \(error)") } }
    XCTAssertEqual(try store.lookup(hostname: config.hostname, port: config.port), trusted)
  }

  func test_close_interrupts_frozen_collection_rejects_overlap_and_leaves_terminal_usable() async throws {
    let server = try await server(), store = store()
    let terminal = try await trust(config(server), store: store)
    let client = try await SSHServerMonitoringClient.connect(config: config(server), knownHosts: store)
    addTeardownBlock { await client.close() }
    try await server.pause()
    addTeardownBlock { try? await server.resume() }
    let query = Task { try await client.sample() }
    try await Task.sleep(nanoseconds: 100_000_000)
    do { _ = try await client.sample(); XCTFail("queries must not overlap") }
    catch { XCTAssertEqual(error as? ServerMonitoringError, .collectionInProgress) }
    let start = Date()
    await client.close()
    do { _ = try await query.value; XCTFail("collection must be interrupted") } catch {}
    XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    do { _ = try await client.sample(); XCTFail("closed client") }
    catch { XCTAssertEqual(error as? SSHError, .disconnected) }
    try await server.resume()
    let output = try await terminal.execute("printf terminal_survived")
    XCTAssertEqual(output.stdout, Data("terminal_survived".utf8))
    let remaining = try await server.execute(["sh", "-c", "netstat -tn | awk '$4 ~ /:2222$/ && $6 == \"ESTABLISHED\" {c++} END {print c+0}'"])
    XCTAssertEqual(remaining.trimmingCharacters(in: .whitespacesAndNewlines), "1", "only the terminal transport remains")
  }

  func test_releasing_client_closes_its_transport() async throws {
    let server = try await server(), store = store()
    let terminal = try await trust(config(server), store: store)
    await terminal.disconnect()
    var client: SSHServerMonitoringClient? = try await SSHServerMonitoringClient.connect(config: config(server), knownHosts: store)
    weak let weakClient = client
    let sample = try await XCTUnwrap(client).sample()
    XCTAssertNotNil(sample.network.value)
    client = nil
    XCTAssertNil(weakClient)
    let deadline = Date().addingTimeInterval(3)
    var remaining = "1"
    while remaining != "0", Date() < deadline {
      remaining = try await server.execute(["sh", "-c", "netstat -tn | awk '$4 ~ /:2222$/ && $6 == \"ESTABLISHED\" {c++} END {print c+0}'"])
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if remaining != "0" { try await Task.sleep(nanoseconds: 20_000_000) }
    }
    XCTAssertEqual(remaining, "0")
  }

  func test_cancelling_connection_to_a_frozen_server_releases_the_pending_transport() async throws {
    let server = try await server(), store = store(), config = config(server)
    let terminal = try await trust(config, store: store)
    await terminal.disconnect()
    try await server.pause()
    addTeardownBlock { try? await server.resume() }
    let opening = Task { try await SSHServerMonitoringClient.connect(config: config, knownHosts: store) }
    try await Task.sleep(nanoseconds: 100_000_000)
    let started = Date(); opening.cancel()
    do { _ = try await opening.value; XCTFail("cancelled connection") } catch {}
    XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    try await server.resume()
    let remaining = try await server.execute(["sh", "-c", "netstat -tn | awk '$4 ~ /:2222$/ && $6 == \"ESTABLISHED\" {c++} END {print c+0}'"])
    XCTAssertEqual(remaining.trimmingCharacters(in: .whitespacesAndNewlines), "0")
    let fresh = try await SSHServerMonitoringClient.connect(config: config, knownHosts: store)
    addTeardownBlock { await fresh.close() }
    let sample = try await fresh.sample(); XCTAssertNotNil(sample.memory.value)
  }

  func test_trusted_encrypted_key_route_collects_target_and_close_releases_every_hop() async throws {
    let jump = try await server(), target = try await server(), store = store()
    try await jump.enableTCPForwarding(); try await jump.mapHost("monitor-owner.invalid", to: target)
    let config = ConnectionConfig(hostname: "monitor-owner.invalid", port: 2222, username: target.username,
      auth: .privateKey(data: Data(TestSSHServer.testEncryptedEd25519PrivateKey.utf8), passphrase: TestSSHServer.encryptedKeyPassphrase),
      jumpHosts: [.init(hostname: jump.host, port: jump.port, username: jump.username, auth: .password(jump.password))])
    let terminal = try await trust(config, store: store)
    let client = try await SSHServerMonitoringClient.connect(config: config, knownHosts: store)
    addTeardownBlock { await client.close() }
    let sample = try await client.sample()
    let expected = try await target.execute(["uname", "-n"]).trimmingCharacters(in: .whitespacesAndNewlines)
    XCTAssertEqual(sample.identity.hostname.value, expected)
    await client.close()
    let probe = try await terminal.execute("printf route_survived")
    XCTAssertEqual(probe.stdout, Data("route_survived".utf8))
    await terminal.disconnect()
    for server in [jump, target] {
      let remaining = try await server.execute(["sh", "-c", "netstat -tn | awk '$4 ~ /:2222$/ && $6 == \"ESTABLISHED\" {c++} END {print c+0}'"])
      XCTAssertEqual(remaining.trimmingCharacters(in: .whitespacesAndNewlines), "0")
    }
  }
}
