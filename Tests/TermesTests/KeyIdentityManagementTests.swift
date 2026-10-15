import AppKit
import Combine
import XCTest
import SSHCore
import TermesKit
@testable import Termes

@MainActor
final class KeyIdentityManagementTests: XCTestCase {
  private let plain = Data(TestSSHServer.testEd25519PrivateKeyOpenSSH.utf8)
  private let encrypted = Data(TestSSHServer.testEncryptedEd25519PrivateKey.utf8)
  private let rsa = Data(TestSSHServer.testRSAPrivateKeyOpenSSH.utf8)
  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }
  private func service() throws -> (ConnectionProfileService, KeyFaultConnections, KeyFaultStore, KeyFaultSecrets) {
    let dir = try directory()
    let connections = KeyFaultConnections(ConnectionStore(fileURL: dir.appendingPathComponent("connections.json")))
    let keys = KeyFaultStore(KeyStore(fileURL: dir.appendingPathComponent("keys.json")))
    let secrets = KeyFaultSecrets()
    return (ConnectionProfileService(connections: connections, keys: keys, secrets: secrets), connections, keys, secrets)
  }
  private func profile(_ service: ConnectionProfileService, key: SSHKey, name: String = "A") throws -> ConnectionProfile {
    try service.saveConnection(name: name, hostname: "example.test", port: 22, username: "u", credential: .existingKey(key.id))
  }
  private func pemRSA() throws -> Data {
    let file = try directory().appendingPathComponent("rsa")
    try rsa.write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
    process.arguments = ["-p", "-m", "PEM", "-P", "", "-N", "", "-f", file.path]
    process.standardOutput = pipe; process.standardError = pipe
    try process.run(); _ = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
    return try Data(contentsOf: file)
  }
  private func encryptedPlainKey() throws -> Data {
    let file = try directory().appendingPathComponent("ed")
    try plain.write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
    process.arguments = ["-p", "-P", "", "-N", "key-test-password", "-f", file.path]
    process.standardOutput = pipe; process.standardError = pipe
    try process.run(); _ = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
    return try Data(contentsOf: file)
  }

  func test_deduplication_across_file_formats_reuses_identity_name_and_original_credentials() throws {
    let (service, _, _, secrets) = try service()
    let original = try service.importKey(data: rsa, name: "Original", passphrase: nil)
    XCTAssertNotNil(original.fingerprint)
    let reused = try service.importKey(data: pemRSA(), name: "Duplicate", passphrase: "ignored-new-password")
    XCTAssertEqual(reused, original)
    XCTAssertEqual(try service.keys(), [original])
    XCTAssertEqual(try secrets.data(for: .privateKey(original.id)), rsa)
    XCTAssertNil(try secrets.data(for: .passphrase(original.id)))
    let saved = try service.saveConnection(name: "A", hostname: "h", port: 22, username: "u",
      credential: .privateKey(data: pemRSA(), name: "New", passphrase: "must-not-replace"))
    XCTAssertEqual(saved.auth, .privateKey(keyId: original.id, hasPassphrase: false))
    XCTAssertEqual(try service.makeConfig(for: saved.id).auth, .privateKey(data: rsa, passphrase: nil))
    let a = try service.importKey(data: encrypted, name: "Encrypted", passphrase: TestSSHServer.encryptedKeyPassphrase)
    let b = try service.importKey(data: encrypted, name: "Other", passphrase: "wrong")
    XCTAssertEqual(a, b)
    XCTAssertEqual(try secrets.data(for: .passphrase(a.id)), Data(TestSSHServer.encryptedKeyPassphrase.utf8))
  }

  func test_imported_or_forged_metadata_cannot_cause_local_secret_reuse() throws {
    let (service, _, _, secrets) = try service()
    let identity = try XCTUnwrap(PrivateKeyIdentity.inspect(plain))
    let missing = SSHKey(name: "Missing", fingerprint: identity.fingerprint)
    let forged = SSHKey(name: "Forged", fingerprint: identity.fingerprint)
    try service.importSnapshot(.init(profiles: [], keys: [missing, forged]))
    try secrets.set(Data("not a private key".utf8), for: .privateKey(forged.id))
    let imported = try service.importKey(data: plain, name: "Actual", passphrase: nil)
    XCTAssertNotEqual(imported.id, missing.id); XCTAssertNotEqual(imported.id, forged.id)
    XCTAssertEqual(try service.keys().count, 3)
    XCTAssertNil(try secrets.data(for: .privateKey(missing.id)))
    XCTAssertEqual(try secrets.data(for: .privateKey(forged.id)), Data("not a private key".utf8))
  }

  func test_same_public_key_with_different_encryption_is_deduped_then_can_be_explicitly_replaced() throws {
    let (service, _, _, secrets) = try service()
    let key = try service.importKey(data: plain, name: "Original", passphrase: nil)
    let encryptedCopy = try encryptedPlainKey()
    XCTAssertNotEqual(encryptedCopy, plain)
    let identity = try XCTUnwrap(PrivateKeyIdentity.inspect(encryptedCopy))
    XCTAssertTrue(identity.isEncrypted); XCTAssertEqual(identity.fingerprint, key.fingerprint)
    let duplicate = try service.importKey(data: encryptedCopy, name: "Encrypted copy", passphrase: "key-test-password")
    XCTAssertEqual(duplicate, key)
    let connection = try profile(service, key: key)
    XCTAssertEqual(try service.makeConfig(for: connection.id).auth, .privateKey(data: plain, passphrase: nil))
    let replaced = try service.replaceKey(key.id, data: encryptedCopy, passphrase: "key-test-password")
    XCTAssertEqual(replaced.fingerprint, key.fingerprint); XCTAssertEqual(replaced.isEncrypted, true)
    XCTAssertEqual(try service.makeConfig(for: connection.id).auth, .privateKey(data: encryptedCopy, passphrase: "key-test-password"))
    XCTAssertEqual(try secrets.data(for: .passphrase(key.id)), Data("key-test-password".utf8))
  }

  func test_shared_replacement_preserves_identity_and_updates_all_referrers_in_both_encryption_directions() throws {
    let (service, _, _, secrets) = try service()
    let key = try service.importKey(data: plain, name: "Shared", passphrase: nil)
    let a = try profile(service, key: key), b = try profile(service, key: key, name: "B")
    let other = try service.importKey(data: rsa, name: "Other", passphrase: nil)
    let untouched = try profile(service, key: other, name: "Other")
    var notifications = 0
    let observer = service.didChange.sink { notifications += 1 }; defer { observer.cancel() }
    let updated = try service.replaceKey(key.id, data: encrypted, passphrase: TestSSHServer.encryptedKeyPassphrase,
      expected: key, expectedProfileIds: [a.id, b.id])
    XCTAssertEqual(updated.id, key.id); XCTAssertEqual(updated.createdAt, key.createdAt); XCTAssertEqual(updated.name, key.name)
    XCTAssertNotEqual(updated.fingerprint, key.fingerprint)
    for id in [a.id, b.id] {
      XCTAssertEqual(try service.profiles().first { $0.id == id }?.auth, .privateKey(keyId: key.id, hasPassphrase: true))
      XCTAssertEqual(try service.makeConfig(for: id).auth, .privateKey(data: encrypted, passphrase: TestSSHServer.encryptedKeyPassphrase))
    }
    let snapshot = ConnectionSnapshot(profiles: try service.profiles(), keys: try service.keys())
    let encoded = try JSONEncoder().encode(snapshot)
    let text = String(decoding: encoded, as: UTF8.self)
    let decoded = try JSONDecoder().decode(ConnectionSnapshot.self, from: encoded)
    XCTAssertEqual(decoded.keys.first { $0.id == updated.id }?.fingerprint, updated.fingerprint)
    XCTAssertFalse(text.contains("PRIVATE KEY")); XCTAssertFalse(text.contains(TestSSHServer.encryptedKeyPassphrase))
    try service.replaceKey(key.id, data: plain, passphrase: nil)
    XCTAssertNil(try secrets.data(for: .passphrase(key.id)))
    for id in [a.id, b.id] {
      XCTAssertEqual(try service.profiles().first { $0.id == id }?.auth, .privateKey(keyId: key.id, hasPassphrase: false))
      XCTAssertEqual(try service.makeConfig(for: id).auth, .privateKey(data: plain, passphrase: nil))
    }
    XCTAssertEqual(try service.profiles().first { $0.id == untouched.id }, untouched)
    XCTAssertEqual(notifications, 2)
  }

  func test_metadata_only_key_can_be_repaired_in_place_and_legacy_fields_decode() throws {
    let (service, _, _, _) = try service()
    let id = UUID()
    let legacy = "{\"id\":\"\(id)\",\"name\":\"Legacy\",\"createdAt\":0,\"updatedAt\":0}"
    let key = try JSONDecoder().decode(SSHKey.self, from: Data(legacy.utf8))
    XCTAssertNil(key.fingerprint); XCTAssertNil(key.isEncrypted)
    let connection = ConnectionProfile(name: "Imported", hostname: "h", port: 22, username: "u",
      auth: .privateKey(keyId: id, hasPassphrase: true))
    try service.importSnapshot(.init(profiles: [connection], keys: [key]))
    let repaired = try service.replaceKey(id, data: plain, passphrase: nil, expected: key, expectedProfileIds: [connection.id])
    XCTAssertEqual(repaired.id, id); XCTAssertEqual(repaired.name, key.name)
    XCTAssertTrue(try service.keyInfo().first!.hasLocalCredential)
    XCTAssertEqual(try service.makeConfig(for: connection.id).auth, .privateKey(data: plain, passphrase: nil))
  }

  func test_replacement_rejects_stale_metadata_references_duplicates_missing_password_and_bad_input() throws {
    let (service, _, _, secrets) = try service()
    let key = try service.importKey(data: plain, name: "A", passphrase: nil)
    let other = try service.importKey(data: rsa, name: "B", passphrase: nil)
    let old = try XCTUnwrap(service.keyInfo().first { $0.key.id == key.id })
    try service.renameKey(key.id, name: "Renamed")
    XCTAssertThrowsError(try service.replaceKey(key.id, data: encrypted, passphrase: "pp", expected: old.key)) {
      XCTAssertEqual($0 as? ProfileServiceError, .keyChangedElsewhere)
    }
    let now = try XCTUnwrap(service.keyInfo().first { $0.key.id == key.id })
    _ = try profile(service, key: key)
    XCTAssertThrowsError(try service.replaceKey(key.id, data: encrypted, passphrase: "pp", expected: now.key, expectedProfileIds: [])) {
      XCTAssertEqual($0 as? ProfileServiceError, .keyChangedElsewhere)
    }
    XCTAssertThrowsError(try service.replaceKey(key.id, data: rsa, passphrase: nil)) {
      XCTAssertEqual($0 as? ProfileServiceError, .duplicateKey(keyId: other.id))
    }
    XCTAssertThrowsError(try service.replaceKey(key.id, data: encrypted, passphrase: nil)) {
      XCTAssertEqual($0 as? ProfileServiceError, .credentialMissing)
    }
    XCTAssertThrowsError(try service.replaceKey(key.id, data: Data("bad".utf8), passphrase: nil)) {
      XCTAssertEqual($0 as? ProfileServiceError, .invalidPrivateKey)
    }
    XCTAssertEqual(try secrets.data(for: .privateKey(key.id)), plain)
  }

  func test_replacement_rolls_back_partial_secret_key_and_profile_writes_without_notification() throws {
    for failure in ["private", "passphrase", "key", "firstProfile", "secondProfile", "deletePassphrase"] {
      let (service, connections, keys, secrets) = try service()
      let oldData = failure == "deletePassphrase" ? encrypted : plain
      let oldPassword = failure == "deletePassphrase" ? TestSSHServer.encryptedKeyPassphrase : nil
      let key = try service.importKey(data: oldData, name: "Shared", passphrase: oldPassword)
      _ = try profile(service, key: key); _ = try profile(service, key: key, name: "B")
      let originalProfiles = try service.profiles(), originalKeys = try service.keys()
      switch failure {
      case "private": secrets.fault.arm("set:" + SecretRef.privateKey(key.id).account, afterMutation: true)
      case "passphrase": secrets.fault.arm("set:" + SecretRef.passphrase(key.id).account, afterMutation: true)
      case "key": keys.fault.arm("upsert", afterMutation: true)
      case "firstProfile": connections.fault.arm("upsert", afterMutation: true)
      case "secondProfile": connections.fault.arm("upsert", skip: 1, afterMutation: true)
      default: secrets.fault.arm("delete:" + SecretRef.passphrase(key.id).account, afterMutation: true)
      }
      var notifications = 0
      let observer = service.didChange.sink { notifications += 1 }; defer { observer.cancel() }
      XCTAssertThrowsError(try service.replaceKey(key.id, data: failure == "deletePassphrase" ? plain : encrypted,
        passphrase: failure == "deletePassphrase" ? nil : TestSSHServer.encryptedKeyPassphrase), failure)
      XCTAssertEqual(try service.profiles(), originalProfiles, failure)
      XCTAssertEqual(try service.keys(), originalKeys, failure)
      XCTAssertEqual(try secrets.data(for: .privateKey(key.id)), oldData, failure)
      XCTAssertEqual(try secrets.data(for: .passphrase(key.id)), oldPassword.map { Data($0.utf8) }, failure)
      XCTAssertEqual(notifications, 0, failure)
    }
  }

  func test_failed_save_and_credential_update_after_dedup_never_delete_existing_key() throws {
    let (service, connections, _, secrets) = try service()
    let key = try service.importKey(data: plain, name: "Shared", passphrase: nil)
    let original = try profile(service, key: key)
    let duplicate = NewCredential.privateKey(data: plain, name: "Duplicate", passphrase: "ignored")
    connections.fault.arm("upsert")
    XCTAssertThrowsError(try service.saveConnection(name: "Failed", hostname: "h", port: 22, username: "u", credential: duplicate))
    connections.fault.arm("upsert")
    XCTAssertThrowsError(try service.updateCredential(for: original.id, credential: duplicate))
    XCTAssertEqual(try service.keys(), [key]); XCTAssertEqual(try service.profiles(), [original])
    XCTAssertEqual(try secrets.data(for: .privateKey(key.id)), plain)
    XCTAssertEqual(try service.makeConfig(for: original.id).auth, .privateKey(data: plain, passphrase: nil))
  }

  func test_failed_rollback_reports_incomplete_recovery_and_refreshes_missing_credential_state() throws {
    let (service, _, _, secrets) = try service()
    let key = try service.importKey(data: plain, name: "Shared", passphrase: nil)
    _ = try profile(service, key: key)
    let operation = "set:" + SecretRef.privateKey(key.id).account
    secrets.fault.arm(operation, afterMutation: true)
    secrets.fault.append(operation)
    var notifications = 0
    let observer = service.didChange.sink { notifications += 1 }; defer { observer.cancel() }
    XCTAssertThrowsError(try service.replaceKey(key.id, data: encrypted, passphrase: TestSSHServer.encryptedKeyPassphrase)) {
      XCTAssertEqual($0 as? ProfileServiceError, .keyReplacementRollbackFailed)
    }
    XCTAssertEqual(notifications, 1)
    XCTAssertFalse(try service.keyInfo().first!.hasLocalCredential)
    try service.replaceKey(key.id, data: plain, passphrase: nil)
    XCTAssertTrue(try service.keyInfo().first!.hasLocalCredential)
  }

  func test_legacy_local_key_identity_is_computed_and_imported_encryption_reports_missing_password() throws {
    let (service, _, _, secrets) = try service()
    let legacy = SSHKey(name: "Old")
    try service.importSnapshot(.init(profiles: [], keys: [legacy]))
    try secrets.set(plain, for: .privateKey(legacy.id))
    XCTAssertEqual(try service.keys().first?.fingerprint, PrivateKeyIdentity.inspect(plain)?.fingerprint)
    let key = try service.importKey(data: encrypted, name: "Locked", passphrase: nil)
    XCTAssertEqual(key.isEncrypted, true)
    XCTAssertFalse(try service.keyInfo().first { $0.key.id == key.id }!.hasLocalCredential)
    XCTAssertThrowsError(try service.makeConfig(hostname: "h", port: 22, username: "u", existingKeyId: key.id)) {
      XCTAssertEqual($0 as? ProfileServiceError, .credentialMissing)
    }
  }

  func test_key_managers_refresh_fingerprints_dedup_and_replacement_with_stale_selection_protection() throws {
    _ = NSApplication.shared
    let (service, _, _, _) = try service()
    let key = try service.importKey(data: plain, name: "Shared", passphrase: nil)
    let a = KeyManagerViewController(profiles: service), b = KeyManagerViewController(profiles: service)
    for page in [a, b] { _ = page.view; page.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    XCTAssertTrue(a.fingerprintLabel.stringValue.contains(key.fingerprint!))
    let pasteboard = NSPasteboard.general
    let clipboard = (pasteboard.pasteboardItems ?? []).map { item in
      let copy = NSPasteboardItem()
      for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
      return copy
    }
    defer { pasteboard.clearContents(); pasteboard.writeObjects(clipboard) }
    let copy = try XCTUnwrap(a.view.subviews.flatMap { descendants($0) }.compactMap { $0 as? NSButton }.first { $0.title == "复制指纹" })
    copy.performClick(nil)
    XCTAssertEqual(NSPasteboard.general.string(forType: .string), key.fingerprint)
    XCTAssertTrue(a.importKey(data: plain, name: "Duplicate", passphrase: nil))
    XCTAssertEqual(a.keys.count, 1)
    XCTAssertTrue(a.detailLabel.stringValue.contains("相同公钥"))
    let info = try XCTUnwrap(a.keys.first)
    XCTAssertTrue(a.replaceKey(info, data: encrypted, passphrase: TestSSHServer.encryptedKeyPassphrase))
    XCTAssertEqual(a.keys.first?.key.id, key.id)
    XCTAssertEqual(b.keys.first?.key.fingerprint, PrivateKeyIdentity.inspect(encrypted)?.fingerprint)
    XCTAssertFalse(b.replaceKey(info, data: rsa, passphrase: nil))
    XCTAssertFalse(b.errorLabel.isHidden)
    XCTAssertEqual(try service.keys().count, 1)
  }

  private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

  func test_real_ssh_shared_replacement_uses_new_keys_for_next_connections_and_keeps_live_config() async throws {
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    let (service, _, _, _) = try service(), dir = try directory()
    let key = try service.importKey(data: plain, name: "Shared", passphrase: nil)
    var ids: [UUID] = []
    for name in ["A", "B"] {
      ids.append(try service.saveConnection(name: name, hostname: server.host, port: server.port, username: "test", credential: .existingKey(key.id)).id)
    }
    let known = KnownHostsStore(fileURL: dir.appendingPathComponent("known.json"))
    let live = SSHConnection(config: try service.makeConfig(for: ids[0]), knownHosts: known, confirmUnknownHostKey: { _, _, _ in true })
    addTeardownBlock { await live.disconnect() }
    try await live.connect()
    let channel = try await live.openShell(cols: 80, rows: 24)
    try service.replaceKey(key.id, data: rsa, passphrase: nil)
    let stillLive = try await live.openShell(cols: 80, rows: 24)
    await stillLive.close(); await channel.close()
    for (data, password) in [(rsa, nil), (encrypted, Optional(TestSSHServer.encryptedKeyPassphrase)), (plain, nil)] {
      if data != rsa { try service.replaceKey(key.id, data: data, passphrase: password) }
      for id in ids {
        let config = try service.makeConfig(for: id)
        XCTAssertEqual(config.auth, .privateKey(data: data, passphrase: password))
        let connection = SSHConnection(config: config, knownHosts: known, confirmUnknownHostKey: { _, _, _ in false })
        addTeardownBlock { await connection.disconnect() }
        try await connection.connect()
        let shell = try await connection.openShell(cols: 80, rows: 24)
        await shell.close(); await connection.disconnect()
      }
    }
    await live.disconnect()
  }
}

private enum KeyInjectedError: Error { case failure }
private final class KeyWriteFault: @unchecked Sendable {
  private let lock = NSLock()
  private var pending: [(operation: String, remaining: Int, afterMutation: Bool)] = []
  func arm(_ operation: String, skip: Int = 0, afterMutation: Bool = false) {
    lock.withLock { pending = [(operation, skip, afterMutation)] }
  }
  func append(_ operation: String, skip: Int = 0, afterMutation: Bool = false) {
    lock.withLock { pending.append((operation, skip, afterMutation)) }
  }
  func run(_ name: String, _ mutation: () throws -> Void) throws {
    let fault: Bool? = lock.withLock {
      guard let index = pending.firstIndex(where: { $0.operation == name }) else { return nil }
      if pending[index].remaining > 0 { pending[index].remaining -= 1; return nil }
      return pending.remove(at: index).afterMutation
    }
    if fault == false { throw KeyInjectedError.failure }
    try mutation()
    if fault == true { throw KeyInjectedError.failure }
  }
}
private final class KeyFaultConnections: ConnectionStoring, @unchecked Sendable {
  let fault = KeyWriteFault()
  private let base: ConnectionStore
  init(_ base: ConnectionStore) { self.base = base }
  func all() throws -> [ConnectionProfile] { try base.all() }
  func get(_ id: UUID) throws -> ConnectionProfile? { try base.get(id) }
  func upsert(_ p: ConnectionProfile) throws { try fault.run("upsert") { try base.upsert(p) } }
  func delete(_ id: UUID) throws { try base.delete(id) }
}
private final class KeyFaultStore: KeyStoring, @unchecked Sendable {
  let fault = KeyWriteFault()
  private let base: KeyStore
  init(_ base: KeyStore) { self.base = base }
  func all() throws -> [SSHKey] { try base.all() }
  func get(_ id: UUID) throws -> SSHKey? { try base.get(id) }
  func upsert(_ p: SSHKey) throws { try fault.run("upsert") { try base.upsert(p) } }
  func delete(_ id: UUID) throws { try base.delete(id) }
}
private final class KeyFaultSecrets: SecretStoring, @unchecked Sendable {
  let fault = KeyWriteFault()
  private let base = InMemorySecretStore()
  func data(for ref: SecretRef) throws -> Data? { try base.data(for: ref) }
  func set(_ data: Data, for ref: SecretRef) throws { try fault.run("set:" + ref.account) { try base.set(data, for: ref) } }
  func delete(_ ref: SecretRef) throws { try fault.run("delete:" + ref.account) { try base.delete(ref) } }
}
