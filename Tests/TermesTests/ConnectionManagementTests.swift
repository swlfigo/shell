import AppKit
import Combine
import XCTest
import TermesKit
import SSHCore
@testable import Termes

@MainActor
final class ConnectionManagementTests: XCTestCase {
  private func makeService() throws -> (ConnectionProfileService, InMemorySecretStore) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    let secrets = InMemorySecretStore()
    return (ConnectionProfileService(connections: ConnectionStore(fileURL: dir.appendingPathComponent("connections.json")),
      keys: KeyStore(fileURL: dir.appendingPathComponent("keys.json")), secrets: secrets), secrets)
  }

  func test_edit_target_keeps_identity_and_password_and_emits_one_change() throws {
    let (service, _) = try makeService()
    let original = try service.saveConnection(name: "old", hostname: "old.test", port: 22,
                                              username: "old-user", credential: .password("secret"))
    var changes = 0
    let observation = service.didChange.sink { changes += 1 }
    defer { observation.cancel() }
    let edited = try service.updateConnection(original.id, name: " new ", hostname: " new.test ",
                                              port: 2222, username: " new-user ")
    XCTAssertEqual(edited.id, original.id)
    XCTAssertEqual(edited.createdAt, original.createdAt)
    XCTAssertEqual(edited.auth, original.auth)
    XCTAssertGreaterThanOrEqual(edited.updatedAt, original.updatedAt)
    XCTAssertEqual(try service.profiles(), [edited])
    let config = try service.makeConfig(for: original.id)
    XCTAssertEqual(config.hostname, "new.test")
    XCTAssertEqual(config.port, 2222)
    XCTAssertEqual(config.username, "new-user")
    XCTAssertEqual(config.auth, .password("secret"))
    XCTAssertEqual(changes, 1)
  }

  func test_invalid_edits_leave_metadata_and_credentials_unchanged() throws {
    let (service, _) = try makeService()
    let profile = try service.saveConnection(name: "a", hostname: "a.test", port: 22,
                                             username: "u", credential: .password("secret"))
    var changes = 0
    let observation = service.didChange.sink { changes += 1 }
    defer { observation.cancel() }
    for (name, host, port, user) in [(" ", "h", 22, "u"), ("n", "\n", 22, "u"),
      ("n", "h", 0, "u"), ("n", "h", 65536, "u"), ("n", "h", 22, " ")] {
      XCTAssertThrowsError(try service.updateConnection(profile.id, name: name, hostname: host, port: port, username: user)) {
        XCTAssertEqual($0 as? ProfileServiceError, .invalidConnection)
      }
    }
    XCTAssertThrowsError(try service.updateConnection(UUID(), name: "n", hostname: "h", port: 22, username: "u")) {
      XCTAssertEqual($0 as? ProfileServiceError, .profileNotFound)
    }
    XCTAssertEqual(try service.profiles(), [profile])
    XCTAssertEqual(try service.makeConfig(for: profile.id).auth, .password("secret"))
    XCTAssertEqual(changes, 0)
  }

  func test_standalone_key_import_rename_and_reuse_preserve_shared_credentials() throws {
    let (service, secrets) = try makeService()
    let data = Data("PRIVATEKEY".utf8)
    let key = try service.importKey(data: data, name: " key ", passphrase: "pp")
    XCTAssertEqual(key.name, "key")
    XCTAssertTrue(try service.profiles().isEmpty)
    let a = try service.saveConnection(name: "a", hostname: "a", port: 22, username: "u", credential: .existingKey(key.id))
    let b = try service.saveConnection(name: "b", hostname: "b", port: 22, username: "u", credential: .existingKey(key.id))
    let renamed = try service.renameKey(key.id, name: " shared ")
    XCTAssertEqual(renamed.id, key.id)
    XCTAssertEqual(renamed.createdAt, key.createdAt)
    XCTAssertEqual(renamed.name, "shared")
    XCTAssertEqual(Set(try service.keyInfo().first!.connections.map(\.id)), Set([a.id, b.id]))
    XCTAssertEqual(try service.makeConfig(for: a.id).auth, .privateKey(data: data, passphrase: "pp"))
    XCTAssertEqual(try service.makeConfig(for: b.id).auth, .privateKey(data: data, passphrase: "pp"))
    XCTAssertEqual(try secrets.data(for: .privateKey(key.id)), data)
    XCTAssertEqual(try secrets.data(for: .passphrase(key.id)), Data("pp".utf8))
    XCTAssertThrowsError(try service.deleteKey(key.id))
    try service.deleteConnection(a.id)
    try service.deleteConnection(b.id)
    try service.deleteKey(key.id)
    XCTAssertTrue(try service.keys().isEmpty)
    XCTAssertNil(try secrets.data(for: .privateKey(key.id)))
    XCTAssertNil(try secrets.data(for: .passphrase(key.id)))
  }

  func test_imported_key_status_reports_missing_bytes_or_required_passphrase() throws {
    let (service, secrets) = try makeService()
    let key = SSHKey(name: "imported")
    let profile = ConnectionProfile(name: "remote", hostname: "h", port: 22, username: "u",
                                    auth: .privateKey(keyId: key.id, hasPassphrase: true))
    try service.importSnapshot(ConnectionSnapshot(profiles: [profile], keys: [key]))
    XCTAssertFalse(try service.keyInfo().first!.hasLocalCredential)
    XCTAssertThrowsError(try service.saveConnection(name: "new", hostname: "h", port: 22, username: "u", credential: .existingKey(key.id))) {
      XCTAssertEqual($0 as? ProfileServiceError, .credentialMissing)
    }
    XCTAssertEqual(try service.profiles(), [profile])
    try secrets.set(Data("K".utf8), for: .privateKey(key.id))
    XCTAssertFalse(try service.keyInfo().first!.hasLocalCredential)
    try secrets.set(Data("pp".utf8), for: .passphrase(key.id))
    XCTAssertTrue(try service.keyInfo().first!.hasLocalCredential)
  }

  func test_invalid_import_or_rename_does_not_publish_changes() throws {
    let (service, _) = try makeService()
    let key = try service.importKey(data: Data("K".utf8), name: "key", passphrase: nil)
    var changes = 0
    let observation = service.didChange.sink { changes += 1 }
    defer { observation.cancel() }
    XCTAssertThrowsError(try service.importKey(data: Data(), name: "empty", passphrase: nil)) {
      XCTAssertEqual($0 as? ProfileServiceError, .emptyPrivateKey)
    }
    XCTAssertThrowsError(try service.importKey(data: Data("K".utf8), name: " ", passphrase: nil))
    XCTAssertThrowsError(try service.renameKey(key.id, name: "\n"))
    XCTAssertThrowsError(try service.renameKey(UUID(), name: "name"))
    XCTAssertEqual(try service.keys(), [key])
    XCTAssertEqual(changes, 0)
  }

  func test_failed_key_metadata_write_cleans_up_keychain_material() throws {
    let store = RejectingKeyStore()
    let secrets = InMemorySecretStore()
    let service = ConnectionProfileService(connections: ConnectionStore(fileURL:
      FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), keys: store, secrets: secrets)
    var changes = 0
    let observation = service.didChange.sink { changes += 1 }
    defer { observation.cancel() }
    XCTAssertThrowsError(try service.importKey(data: Data("K".utf8), name: "key", passphrase: "pp"))
    let attemptedId = try XCTUnwrap(store.attemptedId)
    XCTAssertNil(try secrets.data(for: .privateKey(attemptedId)))
    XCTAssertNil(try secrets.data(for: .passphrase(attemptedId)))
    XCTAssertEqual(changes, 0)
  }

  func test_failed_connection_save_cleans_new_secrets_but_preserves_reused_key() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = RejectingConnectionStore(profile: nil)
    let secrets = InMemorySecretStore()
    let service = ConnectionProfileService(connections: store,
      keys: KeyStore(fileURL: dir.appendingPathComponent("keys.json")), secrets: secrets)
    let key = try service.importKey(data: Data("SHARED".utf8), name: "shared", passphrase: "pp")
    var changes = 0
    let observation = service.didChange.sink { changes += 1 }
    defer { observation.cancel() }
    for credential in [NewCredential.password("pw"), .privateKey(data: Data("NEW".utf8), name: "new", passphrase: "new-pp"), .existingKey(key.id)] {
      XCTAssertThrowsError(try service.saveConnection(name: "fail", hostname: "h", port: 22, username: "u", credential: credential))
      let id = try XCTUnwrap(store.attemptedId)
      XCTAssertNil(try secrets.data(for: .password(id)))
      XCTAssertEqual(try service.keys(), [key])
      XCTAssertEqual(try secrets.data(for: .privateKey(key.id)), Data("SHARED".utf8))
      XCTAssertEqual(try secrets.data(for: .passphrase(key.id)), Data("pp".utf8))
    }
    XCTAssertEqual(changes, 0)
  }

  func test_failed_metadata_edit_keeps_original_target_and_password() throws {
    let original = ConnectionProfile(name: "old", hostname: "old.test", port: 22, username: "old-user", auth: .password)
    let secrets = InMemorySecretStore()
    try secrets.set(Data("pw".utf8), for: .password(original.id))
    let service = ConnectionProfileService(connections: RejectingConnectionStore(profile: original),
      keys: RejectingKeyStore(), secrets: secrets)
    var changes = 0
    let observation = service.didChange.sink { changes += 1 }
    defer { observation.cancel() }
    XCTAssertThrowsError(try service.updateConnection(original.id, name: "new", hostname: "new.test", port: 2200, username: "new-user"))
    XCTAssertEqual(try service.profiles(), [original])
    let config = try service.makeConfig(for: original.id)
    XCTAssertEqual(config.hostname, "old.test")
    XCTAssertEqual(config.auth, .password("pw"))
    XCTAssertEqual(changes, 0)
  }

  func test_editor_keeps_invalid_draft_open_then_saves_existing_profile() throws {
    _ = NSApplication.shared
    let (service, _) = try makeService()
    let profile = try service.saveConnection(name: "old", hostname: "h", port: 22, username: "u", credential: .password("pw"))
    var dismissed = 0
    let editor = ConnectionEditorViewController(profile: profile, profiles: service) { dismissed += 1 }
    _ = editor.view
    editor.nameField.stringValue = "edited"
    editor.portField.stringValue = "oops"
    XCTAssertFalse(editor.saveChanges())
    XCTAssertEqual(dismissed, 0)
    XCTAssertFalse(editor.errorLabel.isHidden)
    XCTAssertEqual(editor.nameField.stringValue, "edited")
    XCTAssertEqual(try service.profiles(), [profile])
    editor.portField.stringValue = "2200"
    XCTAssertTrue(editor.saveChanges())
    XCTAssertEqual(dismissed, 1)
    XCTAssertEqual(try service.profiles().first?.name, "edited")
    XCTAssertEqual(try service.makeConfig(for: profile.id).port, 2200)
  }

  func test_editor_surfaces_deletion_in_another_window_without_recreating_profile() throws {
    _ = NSApplication.shared
    let (service, _) = try makeService()
    let profile = try service.saveConnection(name: "old", hostname: "h", port: 22, username: "u", credential: .password("pw"))
    var dismissed = false
    let editor = ConnectionEditorViewController(profile: profile, profiles: service) { dismissed = true }
    _ = editor.view
    try service.deleteConnection(profile.id)
    XCTAssertFalse(editor.saveChanges())
    XCTAssertFalse(dismissed)
    XCTAssertEqual(editor.errorLabel.stringValue, "连接已不存在")
    XCTAssertTrue(try service.profiles().isEmpty)
  }

  func test_manager_refreshes_renamed_shared_keys_and_blocks_deletion_until_unused() throws {
    _ = NSApplication.shared
    let (service, _) = try makeService()
    let manager = KeyManagerViewController(profiles: service)
    _ = manager.view
    XCTAssertEqual(manager.table.numberOfRows, 0)
    XCTAssertTrue(manager.importKey(data: Data("K".utf8), name: "key", passphrase: "pp"))
    XCTAssertEqual(manager.table.numberOfRows, 1)
    XCTAssertEqual(manager.table.selectedRow, 0)
    let id = try XCTUnwrap(manager.keys.first?.key.id)
    let profile = try service.saveConnection(name: "server", hostname: "h", port: 22, username: "u", credential: .existingKey(id))
    XCTAssertTrue(manager.detailLabel.stringValue.contains("server"))
    XCTAssertTrue(manager.renameKey(id, name: "renamed"))
    XCTAssertEqual(manager.keys.first?.key.name, "renamed")
    XCTAssertEqual(manager.table.selectedRow, 0)
    XCTAssertFalse(manager.deleteKey(id))
    XCTAssertFalse(manager.errorLabel.isHidden)
    XCTAssertEqual(try service.makeConfig(for: profile.id).auth, .privateKey(data: Data("K".utf8), passphrase: "pp"))
    try service.deleteConnection(profile.id)
    XCTAssertTrue(manager.deleteKey(id))
    XCTAssertEqual(manager.table.numberOfRows, 0)
    XCTAssertTrue(manager.errorLabel.isHidden)
  }

  func test_manager_shows_imported_keys_as_missing_and_tracks_external_mutations() throws {
    _ = NSApplication.shared
    let (service, _) = try makeService()
    let manager = KeyManagerViewController(profiles: service)
    _ = manager.view
    let key = SSHKey(name: "missing")
    try service.importSnapshot(ConnectionSnapshot(profiles: [], keys: [key]))
    XCTAssertEqual(manager.table.numberOfRows, 1)
    manager.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    XCTAssertTrue(manager.detailLabel.stringValue.contains("缺少本机凭据"))
    let cell = try XCTUnwrap(manager.tableView(manager.table, viewFor: manager.table.tableColumns[1], row: 0) as? NSTextField)
    XCTAssertEqual(cell.stringValue, "缺少凭据")
    try service.renameKey(key.id, name: "remote-name")
    XCTAssertEqual(manager.keys.first?.key.name, "remote-name")
    try service.deleteKey(key.id)
    XCTAssertEqual(manager.table.selectedRow, -1)
    XCTAssertEqual(manager.table.numberOfRows, 0)
  }

  func test_management_views_fit_their_minimum_window_sizes() throws {
    _ = NSApplication.shared
    let (service, _) = try makeService()
    let profile = try service.saveConnection(name: "name", hostname: "host", port: 22, username: "user", credential: .password("pw"))
    let editor = ConnectionEditorViewController(profile: profile, profiles: service, onDismiss: {})
    let manager = KeyManagerViewController(profiles: service)
    _ = manager.view
    XCTAssertTrue(manager.importKey(data: Data("KEY".utf8), name: "shared-key", passphrase: nil))
    let keyId = try XCTUnwrap(manager.keys.first?.key.id)
    for i in 0..<30 {
      try service.saveConnection(name: "\(i)-" + String(repeating: "很长的连接名称", count: 6),
        hostname: "h", port: 22, username: "u", credential: .existingKey(keyId))
    }
    XCTAssertFalse(manager.deleteKey(keyId))
    XCTAssertTrue(manager.detailLabel.toolTip?.contains("29-") == true)
    for (controller, size) in [(editor as NSViewController, NSSize(width: 440, height: 300)),
                              (manager as NSViewController, NSSize(width: 600, height: 340))] {
      let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = controller.view
      controller.view.layoutSubtreeIfNeeded()
      controller.view.layoutSubtreeIfNeeded()
      for control in descendants(controller.view).compactMap({ $0 as? NSControl }).filter({ !$0.isHiddenOrHasHiddenAncestor }) {
        let rect = control.convert(control.bounds, to: controller.view)
        XCTAssertGreaterThanOrEqual(rect.minX, -0.5)
        XCTAssertLessThanOrEqual(rect.maxX, controller.view.bounds.width + 0.5, "\(type(of: control)): \(rect)")
        XCTAssertGreaterThanOrEqual(rect.minY, -0.5)
        XCTAssertLessThanOrEqual(rect.maxY, controller.view.bounds.height + 0.5)
      }
      window.close()
    }
  }

  private func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap { descendants($0) }
  }
}

private final class RejectingKeyStore: KeyStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var id: UUID?
  var attemptedId: UUID? { lock.withLock { id } }
  func all() throws -> [SSHKey] { [] }
  func get(_ id: UUID) throws -> SSHKey? { nil }
  func upsert(_ key: SSHKey) throws {
    lock.withLock { id = key.id }
    throw CocoaError(.fileWriteNoPermission)
  }
  func delete(_ id: UUID) throws {}
}

private final class RejectingConnectionStore: ConnectionStoring, @unchecked Sendable {
  private let profile: ConnectionProfile?
  private let lock = NSLock()
  private var id: UUID?
  var attemptedId: UUID? { lock.withLock { id } }
  init(profile: ConnectionProfile?) { self.profile = profile }
  func all() throws -> [ConnectionProfile] { profile.map { [$0] } ?? [] }
  func get(_ id: UUID) throws -> ConnectionProfile? { profile?.id == id ? profile : nil }
  func upsert(_ profile: ConnectionProfile) throws {
    lock.withLock { id = profile.id }
    throw CocoaError(.fileWriteNoPermission)
  }
  func delete(_ id: UUID) throws { throw CocoaError(.fileWriteNoPermission) }
}
