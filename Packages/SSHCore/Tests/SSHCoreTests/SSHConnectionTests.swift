import XCTest; @testable import SSHCore
final class SSHConnectionTests: XCTestCase {
  func freshStore() -> KnownHostsStore {
    KnownHostsStore(fileURL: FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString + ".json"))
  }
  func test_password_connect_succeeds_and_saves_unknown_host_on_confirm() async throws {
    let s = try await TestSSHServer.start(); addTeardownBlock { await s.stop() }
    let store = freshStore()
    let conn = SSHConnection(
      config: .init(hostname: s.host, port: s.port, username: s.username, auth: .password(s.password)),
      knownHosts: store,
      confirmUnknownHostKey: { _,_,_ in true })   // 用户点"信任"
    try await conn.connect()
    XCTAssertNotNil(try store.lookup(hostname: s.host, port: s.port))  // TOFU 已记录
    await conn.disconnect()
  }
  func test_wrong_password_throws_authenticationFailed() async throws {
    let s = try await TestSSHServer.start(); addTeardownBlock { await s.stop() }
    let conn = SSHConnection(
      config: .init(hostname: s.host, port: s.port, username: s.username, auth: .password("WRONG")),
      knownHosts: freshStore(), confirmUnknownHostKey: { _,_,_ in true })
    do { try await conn.connect(); XCTFail("should throw") }
    catch let e as SSHError { XCTAssertEqual(e, .authenticationFailed) }
  }
  func test_rejected_hostkey_throws() async throws {
    let s = try await TestSSHServer.start(); addTeardownBlock { await s.stop() }
    let conn = SSHConnection(
      config: .init(hostname: s.host, port: s.port, username: s.username, auth: .password(s.password)),
      knownHosts: freshStore(), confirmUnknownHostKey: { _,_,_ in false })  // 用户点"拒绝"
    do { try await conn.connect(); XCTFail("should throw") }
    catch let e as SSHError { XCTAssertEqual(e, .hostKeyRejected) }
  }
  func test_unreachable_throws_connectionFailed() async throws {
    let conn = SSHConnection(
      config: .init(hostname: "127.0.0.1", port: 1, username: "x", auth: .password("y")),
      knownHosts: freshStore(), confirmUnknownHostKey: { _,_,_ in true })
    do { try await conn.connect(); XCTFail("should throw") }
    catch let e as SSHError { if case .connectionFailed = e {} else { XCTFail("got \(e)") } }
  }
  func test_concurrent_connect_is_rejected_without_leaking() async throws {
    let s = try await TestSSHServer.start(); addTeardownBlock { await s.stop() }
    let conn = SSHConnection(
      config: .init(hostname: s.host, port: s.port, username: s.username, auth: .password(s.password)),
      knownHosts: freshStore(), confirmUnknownHostKey: { _,_,_ in true })
    async let a: Void = conn.connect()
    async let b: Void = conn.connect()
    var failures = 0
    do { try await a } catch { failures += 1 }
    do { try await b } catch { failures += 1 }
    XCTAssertEqual(failures, 1)
    await conn.disconnect()
  }
  func test_privatekey_connect_succeeds() async throws {
    let s = try await TestSSHServer.start(); addTeardownBlock { await s.stop() }
    let keyData = TestSSHServer.testEd25519PrivateKeyOpenSSH.data(using: .utf8)!
    let conn = SSHConnection(
      config: .init(hostname: s.host, port: s.port, username: s.username,
                    auth: .privateKey(data: keyData, passphrase: nil)),
      knownHosts: freshStore(), confirmUnknownHostKey: { _,_,_ in true })
    try await conn.connect()
    await conn.disconnect()
  }
  func test_malformed_private_key_throws_auth() async throws {
    let s = try await TestSSHServer.start(); addTeardownBlock { await s.stop() }
    let conn = SSHConnection(
      config: .init(hostname: s.host, port: s.port, username: s.username,
                    auth: .privateKey(data: Data("not-a-key".utf8), passphrase: nil)),
      knownHosts: freshStore(), confirmUnknownHostKey: { _,_,_ in true })
    do { try await conn.connect(); XCTFail("should throw") }
    catch let e as SSHError { XCTAssertEqual(e, .authenticationFailed) }
  }

  func test_rsa_openssh_privatekey_connect_succeeds() async throws {
    let s = try await TestSSHServer.start(); addTeardownBlock { await s.stop() }
    let conn = SSHConnection(config: .init(hostname: s.host, port: s.port, username: s.username,
                auth: .privateKey(data: Data(TestSSHServer.testRSAPrivateKeyOpenSSH.utf8), passphrase: nil)),
                knownHosts: freshStore(), confirmUnknownHostKey: { _,_,_ in true })
    try await conn.connect(); await conn.disconnect()
  }
  func test_encrypted_privatekey_with_passphrase_succeeds() async throws {
    let s = try await TestSSHServer.start(); addTeardownBlock { await s.stop() }
    let conn = SSHConnection(config: .init(hostname: s.host, port: s.port, username: s.username,
                auth: .privateKey(data: Data(TestSSHServer.testEncryptedEd25519PrivateKey.utf8), passphrase: TestSSHServer.encryptedKeyPassphrase)),
                knownHosts: freshStore(), confirmUnknownHostKey: { _,_,_ in true })
    try await conn.connect(); await conn.disconnect()
  }
  func test_encrypted_privatekey_wrong_passphrase_throws_auth() async throws {
    let s = try await TestSSHServer.start(); addTeardownBlock { await s.stop() }
    let conn = SSHConnection(config: .init(hostname: s.host, port: s.port, username: s.username,
                auth: .privateKey(data: Data(TestSSHServer.testEncryptedEd25519PrivateKey.utf8), passphrase: "WRONG")),
                knownHosts: freshStore(), confirmUnknownHostKey: { _,_,_ in true })
    do { try await conn.connect(); XCTFail("should throw") } catch let e as SSHError { XCTAssertEqual(e, .authenticationFailed) }
  }
}
