import XCTest
@testable import TermesKit

final class SecretStoreTests: XCTestCase {
  func test_legacy_credentials_migrate_prefer_current_values_and_delete_without_reappearing() throws {
    let primary = InMemorySecretStore(), legacy = InMemorySecretStore()
    let store = LegacyCompatibleSecretStore(primary: primary, legacy: legacy)
    let id = UUID(), refs = [SecretRef.password(UUID()), .privateKey(UUID()), .passphrase(UUID())]
    for ref in refs {
      try legacy.set(Data("original".utf8), for: ref)
      XCTAssertEqual(try store.data(for: ref), Data("original".utf8))
      XCTAssertEqual(try primary.data(for: ref), Data("original".utf8))
      try store.set(Data("updated".utf8), for: ref)
      XCTAssertEqual(try store.data(for: ref), Data("updated".utf8))
      XCTAssertEqual(try legacy.data(for: ref), Data("original".utf8))
      try store.delete(ref)
      XCTAssertNil(try primary.data(for: ref)); XCTAssertNil(try legacy.data(for: ref))
      XCTAssertNil(try store.data(for: ref))
    }
    XCTAssertNil(try store.data(for: .password(id)))
  }

  func test_failed_migration_and_legacy_cleanup_keep_existing_credentials_available_for_retry() throws {
    let primary = FailingMigrationSecretStore(), legacy = FailingMigrationSecretStore()
    let store = LegacyCompatibleSecretStore(primary: primary, legacy: legacy)
    let ref = SecretRef.password(UUID()), data = Data("original".utf8)
    try legacy.set(data, for: ref)
    primary.failWrites = true
    XCTAssertThrowsError(try store.data(for: ref))
    XCTAssertEqual(try legacy.data(for: ref), data); XCTAssertNil(try primary.data(for: ref))
    primary.failWrites = false
    XCTAssertEqual(try store.data(for: ref), data)
    legacy.failDeletes = true
    XCTAssertThrowsError(try store.delete(ref))
    XCTAssertEqual(try primary.data(for: ref), data)
    legacy.failDeletes = false
    try store.delete(ref)
    XCTAssertNil(try store.data(for: ref))
  }

  func test_real_keychain_legacy_password_private_key_and_passphrase_migration() throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["RUN_KEYCHAIN_TESTS"] == "1")
    let namespace = "com.termes.tests.migration.\(UUID().uuidString)"
    let primary = KeychainSecretStore(service: namespace + ".current")
    let legacy = KeychainSecretStore(service: namespace + ".legacy")
    let store = LegacyCompatibleSecretStore(primary: primary, legacy: legacy)
    let refs = [SecretRef.password(UUID()), .privateKey(UUID()), .passphrase(UUID())]
    defer { for ref in refs { try? primary.delete(ref); try? legacy.delete(ref) } }
    for (index, ref) in refs.enumerated() {
      let data = Data([0, 1, 255, UInt8(index)])
      try legacy.set(data, for: ref)
      XCTAssertEqual(try store.data(for: ref), data)
      XCTAssertEqual(try primary.data(for: ref), data)
      try store.delete(ref)
      XCTAssertNil(try primary.data(for: ref)); XCTAssertNil(try legacy.data(for: ref))
      XCTAssertNil(try store.data(for: ref))
    }
  }

  func test_inmemory_set_get_delete_and_overwrite() throws {
    let s = InMemorySecretStore()
    let ref = SecretRef.password(UUID())
    XCTAssertNil(try s.data(for: ref))                 // not found -> nil
    try s.set(Data("one".utf8), for: ref)
    XCTAssertEqual(try s.data(for: ref), Data("one".utf8))
    try s.set(Data("two".utf8), for: ref)              // upsert overwrites
    XCTAssertEqual(try s.data(for: ref), Data("two".utf8))
    try s.delete(ref)
    XCTAssertNil(try s.data(for: ref))
    XCTAssertNoThrow(try s.delete(ref))                // delete missing is ok
  }

  func test_secret_ref_accounts_are_distinct() {
    let id = UUID()
    XCTAssertNotEqual(SecretRef.privateKey(id).account, SecretRef.passphrase(id).account)
    XCTAssertTrue(SecretRef.password(id).account.contains(id.uuidString))
  }

  // Real Keychain: opt-in via env to avoid CI prompts/permission issues.
  func test_keychain_roundtrip_integration() throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["RUN_KEYCHAIN_TESTS"] == "1",
                      "set RUN_KEYCHAIN_TESTS=1 to run the real-Keychain test")
    let store = KeychainSecretStore(service: "com.termes.tests." + UUID().uuidString)
    let ref = SecretRef.password(UUID())
    defer { try? store.delete(ref) }
    XCTAssertNil(try store.data(for: ref))
    try store.set(Data("secret".utf8), for: ref)
    XCTAssertEqual(try store.data(for: ref), Data("secret".utf8))
    try store.set(Data("secret2".utf8), for: ref)
    XCTAssertEqual(try store.data(for: ref), Data("secret2".utf8))
    try store.delete(ref)
    XCTAssertNil(try store.data(for: ref))
  }
}

private final class FailingMigrationSecretStore: SecretStoring, @unchecked Sendable {
  private let storage = InMemorySecretStore()
  var failWrites = false
  var failDeletes = false
  func data(for ref: SecretRef) throws -> Data? { try storage.data(for: ref) }
  func set(_ data: Data, for ref: SecretRef) throws {
    if failWrites { throw CocoaError(.fileWriteUnknown) }
    try storage.set(data, for: ref)
  }
  func delete(_ ref: SecretRef) throws {
    if failDeletes { throw CocoaError(.fileWriteUnknown) }
    try storage.delete(ref)
  }
}
