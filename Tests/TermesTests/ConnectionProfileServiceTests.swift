import XCTest
import Combine
import SSHCore
@testable import TermesKit

@MainActor
final class ConnectionProfileServiceTests: XCTestCase {
  private func tempURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
  }
  private func makeService() -> ConnectionProfileService {
    ConnectionProfileService(connections: ConnectionStore(fileURL: tempURL()),
                             keys: KeyStore(fileURL: tempURL()),
                             secrets: InMemorySecretStore())
  }

  func test_didChange_fires_once_per_successful_mutation() throws {
    let svc = makeService()
    var count = 0
    let sub = svc.didChange.sink { count += 1 }
    defer { sub.cancel() }
    let p = try svc.saveConnection(name: "h", hostname: "h", port: 22, username: "u", credential: .password("pw"))
    XCTAssertEqual(count, 1)
    try svc.deleteConnection(p.id)
    XCTAssertEqual(count, 2)
    let k = try svc.saveConnection(name: "k", hostname: "h", port: 22, username: "u",
                                   credential: .privateKey(data: Data("K".utf8), name: "k", passphrase: nil))
    XCTAssertEqual(count, 3)
    guard case .privateKey(let keyId, _) = k.auth else { return XCTFail("expected key auth") }
    try svc.deleteConnection(k.id)
    try svc.deleteKey(keyId)
    try svc.importSnapshot(ConnectionSnapshot(profiles: [], keys: []))
    XCTAssertEqual(count, 6)
  }

  func test_didChange_not_fired_when_mutation_throws() {
    let svc = makeService()
    var count = 0
    let sub = svc.didChange.sink { count += 1 }
    defer { sub.cancel() }
    XCTAssertThrowsError(try svc.saveConnection(name: "x", hostname: "h", port: 22, username: "u",
                                                credential: .existingKey(UUID())))
    XCTAssertEqual(count, 0)
  }

  func test_save_password_and_make_config() throws {
    let svc = makeService()
    let p = try svc.saveConnection(name: "h", hostname: "example.com", port: 2222,
                                   username: "root", credential: .password("pw"))
    XCTAssertEqual(p.auth, .password)
    let cfg = try svc.makeConfig(for: p.id)
    XCTAssertEqual(cfg.hostname, "example.com")
    XCTAssertEqual(cfg.port, 2222)
    XCTAssertEqual(cfg.username, "root")
    XCTAssertEqual(cfg.auth, .password("pw"))
  }

  func test_save_private_key_creates_reusable_key_and_config() throws {
    let svc = makeService()
    let keyData = Data("PRIVATEKEYBYTES".utf8)
    let p = try svc.saveConnection(name: "h", hostname: "h", port: 22, username: "u",
                                   credential: .privateKey(data: keyData, name: "id_ed25519", passphrase: "pp"))
    guard case .privateKey(let keyId, let hasPass) = p.auth else { return XCTFail() }
    XCTAssertTrue(hasPass)
    XCTAssertEqual(try svc.keys().map(\.id), [keyId])
    let cfg = try svc.makeConfig(for: p.id)
    XCTAssertEqual(cfg.auth, .privateKey(data: keyData, passphrase: "pp"))
  }

  func test_blank_passphrase_treated_as_none() throws {
    let svc = makeService()
    let p = try svc.saveConnection(name: "h", hostname: "h", port: 22, username: "u",
                                   credential: .privateKey(data: Data("K".utf8), name: "k", passphrase: "   "))
    guard case .privateKey(_, let hasPass) = p.auth else { return XCTFail() }
    XCTAssertFalse(hasPass)
    let cfg = try svc.makeConfig(for: p.id)
    XCTAssertEqual(cfg.auth, .privateKey(data: Data("K".utf8), passphrase: nil))
  }

  func test_reuse_existing_key() throws {
    let svc = makeService()
    let first = try svc.saveConnection(name: "a", hostname: "a", port: 22, username: "u",
                                       credential: .privateKey(data: Data("K".utf8), name: "k", passphrase: nil))
    guard case .privateKey(let keyId, _) = first.auth else { return XCTFail() }
    let second = try svc.saveConnection(name: "b", hostname: "b", port: 22, username: "u",
                                        credential: .existingKey(keyId))
    guard case .privateKey(let keyId2, _) = second.auth else { return XCTFail() }
    XCTAssertEqual(keyId, keyId2)
    XCTAssertEqual(try svc.keys().count, 1)                 // not duplicated
    XCTAssertEqual(try svc.makeConfig(for: second.id).auth, .privateKey(data: Data("K".utf8), passphrase: nil))
  }

  func test_make_config_missing_secret_throws() throws {
    let svc = makeService()
    // profile referencing a password that was never stored (simulate import)
    let store = ConnectionStore(fileURL: tempURL())
    // build service sharing that store
    let svc2 = ConnectionProfileService(connections: store, keys: KeyStore(fileURL: tempURL()), secrets: InMemorySecretStore())
    let p = ConnectionProfile(name: "x", hostname: "h", port: 22, username: "u", auth: .password)
    try store.upsert(p)
    XCTAssertThrowsError(try svc2.makeConfig(for: p.id)) { error in
      XCTAssertEqual(error as? ProfileServiceError, .credentialMissing)
    }
    _ = svc
  }

  func test_make_config_unknown_profile_throws() throws {
    let svc = makeService()
    XCTAssertThrowsError(try svc.makeConfig(for: UUID())) { error in
      XCTAssertEqual(error as? ProfileServiceError, .profileNotFound)
    }
  }

  func test_update_imported_password_preserves_profile_and_enables_connection() throws {
    let (svc, secrets) = makeServiceWithSecrets()
    let date = Date(timeIntervalSince1970: 100)
    let p = ConnectionProfile(name: "imported", hostname: "example.com", port: 2222,
                              username: "admin", auth: .password, createdAt: date, updatedAt: date)
    try svc.importSnapshot(ConnectionSnapshot(profiles: [p], keys: []))
    XCTAssertThrowsError(try svc.makeConfig(for: p.id))
    var changes = 0
    let sub = svc.didChange.sink { changes += 1 }
    defer { sub.cancel() }

    let updated = try svc.updateCredential(for: p.id, credential: .password("restored"))

    XCTAssertEqual(updated.id, p.id)
    XCTAssertEqual(updated.name, p.name)
    XCTAssertEqual(updated.createdAt, p.createdAt)
    XCTAssertGreaterThan(updated.updatedAt, p.updatedAt)
    XCTAssertEqual(try svc.profiles(), [updated])
    XCTAssertEqual(try svc.makeConfig(for: p.id), ConnectionConfig(
      hostname: p.hostname, port: p.port, username: p.username, auth: .password("restored")))
    XCTAssertEqual(try secrets.data(for: .password(p.id)), Data("restored".utf8))
    XCTAssertEqual(changes, 1)
    let exported = try JSONEncoder().encode(ConnectionSnapshot(profiles: svc.profiles(), keys: svc.keys()))
    XCTAssertFalse(String(decoding: exported, as: UTF8.self).contains("restored"))
  }

  func test_update_imported_private_key_keeps_other_shared_profiles_unchanged() throws {
    let (svc, secrets) = makeServiceWithSecrets()
    let key = SSHKey(name: "shared")
    let auth = AuthRef.privateKey(keyId: key.id, hasPassphrase: true)
    let first = ConnectionProfile(name: "first", hostname: "a", port: 22, username: "u", auth: auth)
    let second = ConnectionProfile(name: "second", hostname: "b", port: 22, username: "u", auth: auth)
    try svc.importSnapshot(ConnectionSnapshot(profiles: [first, second], keys: [key]))

    let updated = try svc.updateCredential(for: first.id,
      credential: .privateKey(data: Data("NEWKEY".utf8), name: "replacement", passphrase: "pp"))

    guard case .privateKey(let newId, let hasPassphrase) = updated.auth else { return XCTFail() }
    XCTAssertNotEqual(newId, key.id)
    XCTAssertTrue(hasPassphrase)
    XCTAssertEqual(try svc.makeConfig(for: first.id).auth, .privateKey(data: Data("NEWKEY".utf8), passphrase: "pp"))
    XCTAssertEqual(try svc.profiles().first { $0.id == second.id }, second)
    XCTAssertNil(try secrets.data(for: .privateKey(key.id)))
    XCTAssertThrowsError(try svc.makeConfig(for: second.id))
    XCTAssertEqual(try svc.profiles().count, 2)
  }

  func test_update_credential_can_reuse_local_key_and_remove_old_password() throws {
    let (svc, secrets) = makeServiceWithSecrets()
    let keyProfile = try svc.saveConnection(name: "key", hostname: "h", port: 22, username: "u",
      credential: .privateKey(data: Data("K".utf8), name: "k", passphrase: "pp"))
    guard case .privateKey(let keyId, _) = keyProfile.auth else { return XCTFail() }
    let passwordProfile = try svc.saveConnection(name: "password", hostname: "h", port: 22,
      username: "u", credential: .password("old"))

    try svc.updateCredential(for: passwordProfile.id, credential: .existingKey(keyId))

    XCTAssertEqual(try svc.makeConfig(for: passwordProfile.id).auth, .privateKey(data: Data("K".utf8), passphrase: "pp"))
    XCTAssertNil(try secrets.data(for: .password(passwordProfile.id)))
    XCTAssertEqual(try svc.keys().count, 1)
    XCTAssertEqual(try svc.makeConfig(for: keyProfile.id).auth, .privateKey(data: Data("K".utf8), passphrase: "pp"))
  }

  func test_update_credential_rejects_missing_profile_or_unavailable_key_without_changes() throws {
    let svc = makeService()
    let key = SSHKey(name: "metadata only")
    let p = ConnectionProfile(name: "p", hostname: "h", port: 22, username: "u", auth: .password)
    try svc.importSnapshot(ConnectionSnapshot(profiles: [p], keys: [key]))
    var changes = 0
    let sub = svc.didChange.sink { changes += 1 }
    defer { sub.cancel() }

    XCTAssertThrowsError(try svc.updateCredential(for: UUID(), credential: .password("pw"))) {
      XCTAssertEqual($0 as? ProfileServiceError, .profileNotFound)
    }
    XCTAssertThrowsError(try svc.updateCredential(for: p.id, credential: .existingKey(key.id))) {
      XCTAssertEqual($0 as? ProfileServiceError, .credentialMissing)
    }
    XCTAssertEqual(try svc.profiles(), [p])
    XCTAssertEqual(changes, 0)
  }

  func test_update_credential_rolls_back_secrets_when_profile_write_fails() throws {
    let original = ConnectionProfile(name: "original", hostname: "h", port: 22, username: "u", auth: .password)
    let secrets = InMemorySecretStore()
    let keys = KeyStore(fileURL: tempURL())
    let svc = ConnectionProfileService(connections: FailingConnectionStore(profile: original),
                                       keys: keys, secrets: secrets)
    try secrets.set(Data("old".utf8), for: .password(original.id))
    var changes = 0
    let sub = svc.didChange.sink { changes += 1 }
    defer { sub.cancel() }

    XCTAssertThrowsError(try svc.updateCredential(for: original.id, credential: .password("new")))
    XCTAssertEqual(try svc.makeConfig(for: original.id).auth, .password("old"))
    XCTAssertThrowsError(try svc.updateCredential(for: original.id,
      credential: .privateKey(data: Data("NEWKEY".utf8), name: "k", passphrase: "pp")))
    XCTAssertEqual(try svc.makeConfig(for: original.id).auth, .password("old"))
    XCTAssertEqual(try keys.all(), [])
    XCTAssertEqual(try svc.profiles(), [original])
    XCTAssertEqual(changes, 0)
  }

  func test_delete_key_in_use_throws_with_referrers() throws {
    let svc = makeService()
    let p = try svc.saveConnection(name: "a", hostname: "a", port: 22, username: "u",
                                   credential: .privateKey(data: Data("K".utf8), name: "k", passphrase: nil))
    guard case .privateKey(let keyId, _) = p.auth else { return XCTFail() }
    XCTAssertThrowsError(try svc.deleteKey(keyId)) { error in
      XCTAssertEqual(error as? ProfileServiceError, .keyInUse(profileIds: [p.id]))
    }
    try svc.deleteConnection(p.id)                          // now unreferenced
    XCTAssertNoThrow(try svc.deleteKey(keyId))
    XCTAssertEqual(try svc.keys().count, 0)
  }

  func test_import_snapshot_adds_profiles_lww() throws {
    let store = ConnectionStore(fileURL: tempURL())
    let keyS = KeyStore(fileURL: tempURL())
    let svc = ConnectionProfileService(connections: store, keys: keyS, secrets: InMemorySecretStore())
    let p = ConnectionProfile(name: "imported", hostname: "h", port: 22, username: "u", auth: .password)
    try svc.importSnapshot(ConnectionSnapshot(profiles: [p], keys: []))
    XCTAssertEqual(try svc.profiles().map(\.id), [p.id])
    var older = p; older.name = "old"; older.updatedAt = p.updatedAt.addingTimeInterval(-100)
    try svc.importSnapshot(ConnectionSnapshot(profiles: [older], keys: []))
    XCTAssertEqual(try svc.profiles().first?.name, "imported")
  }

  private func makeServiceWithSecrets() -> (ConnectionProfileService, InMemorySecretStore) {
    let secrets = InMemorySecretStore()
    return (ConnectionProfileService(connections: ConnectionStore(fileURL: tempURL()),
                                     keys: KeyStore(fileURL: tempURL()), secrets: secrets), secrets)
  }

  func test_blank_passphrase_writes_no_passphrase_secret() throws {
    let (svc, secrets) = makeServiceWithSecrets()
    let p = try svc.saveConnection(name: "h", hostname: "h", port: 22, username: "u",
                                   credential: .privateKey(data: Data("K".utf8), name: "k", passphrase: "   "))
    guard case .privateKey(let keyId, let hasPass) = p.auth else { return XCTFail() }
    XCTAssertFalse(hasPass)
    XCTAssertNil(try secrets.data(for: .passphrase(keyId)))
  }

  func test_delete_connection_removes_password_secret_and_keeps_shared_key() throws {
    let (svc, secrets) = makeServiceWithSecrets()
    let p1 = try svc.saveConnection(name: "a", hostname: "h", port: 22, username: "u",
                                    credential: .privateKey(data: Data("K".utf8), name: "k", passphrase: nil))
    guard case .privateKey(let keyId, _) = p1.auth else { return XCTFail() }
    let p2 = try svc.saveConnection(name: "b", hostname: "h2", port: 22, username: "u",
                                    credential: .existingKey(keyId))
    try secrets.set(Data("pw".utf8), for: .password(p1.id))
    try svc.deleteConnection(p1.id)
    XCTAssertNil(try secrets.data(for: .password(p1.id)))
    XCTAssertEqual(try svc.makeConfig(for: p2.id).auth, .privateKey(data: Data("K".utf8), passphrase: nil))
  }

  func test_make_config_with_existing_key_does_not_persist_profile() throws {
    let svc = makeService()
    let p = try svc.saveConnection(name: "a", hostname: "h", port: 22, username: "u",
                                   credential: .privateKey(data: Data("K".utf8), name: "k", passphrase: "pp"))
    guard case .privateKey(let keyId, _) = p.auth else { return XCTFail() }
    let before = try svc.profiles().count
    let cfg = try svc.makeConfig(hostname: "x", port: 2200, username: "me", existingKeyId: keyId)
    XCTAssertEqual(cfg.hostname, "x")
    XCTAssertEqual(cfg.port, 2200)
    XCTAssertEqual(cfg.username, "me")
    XCTAssertEqual(cfg.auth, .privateKey(data: Data("K".utf8), passphrase: "pp"))
    XCTAssertEqual(try svc.profiles().count, before)
    XCTAssertThrowsError(try svc.makeConfig(hostname: "x", port: 1, username: "u", existingKeyId: UUID())) {
      XCTAssertEqual($0 as? ProfileServiceError, .keyNotFound)
    }
  }
}

private struct FailingConnectionStore: ConnectionStoring {
  let profile: ConnectionProfile
  func all() throws -> [ConnectionProfile] { [profile] }
  func get(_ id: UUID) throws -> ConnectionProfile? { id == profile.id ? profile : nil }
  func upsert(_ p: ConnectionProfile) throws { throw CocoaError(.fileWriteNoPermission) }
  func delete(_ id: UUID) throws { throw CocoaError(.fileWriteNoPermission) }
}
