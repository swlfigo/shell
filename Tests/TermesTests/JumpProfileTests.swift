import AppKit
import XCTest
import SSHCore
@testable import TermesKit
@testable import Termes

@MainActor
final class JumpProfileTests: XCTestCase {
  private func directory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return directory
  }
  private func service(_ directory: URL, secrets: InMemorySecretStore = InMemorySecretStore()) -> ConnectionProfileService {
    .init(connections: ConnectionStore(fileURL: directory.appendingPathComponent("connections.json")),
          keys: KeyStore(fileURL: directory.appendingPathComponent("keys.json")), secrets: secrets)
  }
  private func save(_ service: ConnectionProfileService, _ name: String, jump: UUID? = nil) throws -> ConnectionProfile {
    try service.saveConnection(name: name, hostname: name + ".test", port: 22, username: "test",
      credential: .password(name + "-password"), jumpProfileId: jump)
  }
  private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

  func test_route_persistence_order_credentials_export_and_legacy_default() async throws {
    let dir = try directory(), secrets = InMemorySecretStore(), profiles = service(dir, secrets: secrets)
    let first = try save(profiles, "first")
    let second = try profiles.saveConnection(name: "second", hostname: "second.test", port: 2222, username: "jump",
      credential: .privateKey(data: Data("PRIVATE_KEY".utf8), name: "jump-key", passphrase: "PASSPHRASE"), jumpProfileId: first.id)
    let target = try save(profiles, "target", jump: second.id)
    let restored = service(dir, secrets: secrets)
    let config = try restored.makeConfig(for: target.id)
    XCTAssertEqual(config.jumpHosts.map(\.hostname), ["first.test", "second.test"])
    XCTAssertEqual(config.jumpHosts.map(\.auth), [.password("first-password"), .privateKey(data: Data("PRIVATE_KEY".utf8), passphrase: "PASSPHRASE")])
    XCTAssertEqual(config.auth, .password("target-password"))
    XCTAssertEqual(try restored.jumpHosts(for: second.id), config.jumpHosts)
    let file = dir.appendingPathComponent("export.json")
    let provider = FileSyncProvider(fileURL: file)
    _ = try await provider.push(ConnectionSnapshot(profiles: restored.profiles(), keys: restored.keys()), baseVersion: nil)
    let pulled = try await provider.pull()
    let exported = try XCTUnwrap(pulled)
    XCTAssertEqual(exported.profiles.first { $0.id == target.id }?.jumpProfileId, second.id)
    let text = try String(contentsOf: file, encoding: .utf8)
    for secret in ["first-password", "target-password", "PRIVATE_KEY", "PASSPHRASE"] { XCTAssertFalse(text.contains(secret)) }
    let imported = service(try directory())
    try imported.importSnapshot(exported)
    XCTAssertEqual(try imported.profiles().count, 3)
    var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(first)) as? [String: Any])
    legacy.removeValue(forKey: "jumpProfileId")
    let decoded = try JSONDecoder().decode(ConnectionProfile.self, from: JSONSerialization.data(withJSONObject: legacy))
    XCTAssertNil(decoded.jumpProfileId)
  }

  func test_cycles_missing_hops_and_referenced_deletion_preserve_profiles_and_credentials() throws {
    let dir = try directory(), profiles = service(dir)
    let first = try save(profiles, "first"), second = try save(profiles, "second", jump: first.id)
    for jump in [first.id, second.id] {
      XCTAssertThrowsError(try profiles.updateConnection(first.id, name: "changed", hostname: first.hostname, port: first.port,
        username: first.username, jumpProfileId: jump)) { XCTAssertEqual($0 as? ProfileServiceError, .jumpHostCycle) }
    }
    XCTAssertThrowsError(try profiles.deleteConnection(first.id)) {
      XCTAssertEqual($0 as? ProfileServiceError, .jumpHostInUse(profileIds: [second.id]))
    }
    XCTAssertEqual(try profiles.makeConfig(for: first.id).auth, .password("first-password"))
    XCTAssertEqual(try profiles.profiles().first { $0.id == first.id }, first)
    XCTAssertThrowsError(try save(profiles, "missing", jump: UUID())) {
      XCTAssertEqual($0 as? ProfileServiceError, .jumpProfileNotFound)
    }
    XCTAssertEqual(try profiles.profiles().count, 2)
    let renamed = try profiles.updateConnection(second.id, name: "renamed", hostname: second.hostname,
      port: second.port, username: second.username)
    XCTAssertEqual(renamed.jumpProfileId, first.id, "the existing non-route editing API preserves a route")
    _ = try profiles.updateConnection(second.id, name: renamed.name, hostname: renamed.hostname,
      port: renamed.port, username: renamed.username, jumpProfileId: nil)
    try profiles.deleteConnection(first.id)
    XCTAssertTrue(try profiles.makeConfig(for: second.id).jumpHosts.isEmpty)
  }

  func test_invalid_imports_are_rejected_before_metadata_mutation_and_depth_is_bounded() throws {
    let dir = try directory(), profiles = service(dir)
    let existing = try save(profiles, "existing")
    let key = SSHKey(name: "unwritten-key")
    var a = ConnectionProfile(name: "a", hostname: "a", port: 22, username: "u", auth: .password)
    var b = ConnectionProfile(name: "b", hostname: "b", port: 22, username: "u", auth: .password, jumpProfileId: a.id)
    a.jumpProfileId = b.id
    XCTAssertThrowsError(try profiles.importSnapshot(.init(profiles: [a, b], keys: [key]))) {
      XCTAssertEqual($0 as? ProfileServiceError, .jumpHostCycle)
    }
    b.jumpProfileId = UUID()
    XCTAssertThrowsError(try profiles.importSnapshot(.init(profiles: [b], keys: [key]))) {
      XCTAssertEqual($0 as? ProfileServiceError, .jumpProfileNotFound)
    }
    XCTAssertEqual(try profiles.profiles(), [existing])
    XCTAssertTrue(try profiles.keys().isEmpty)
    var last = existing
    for index in 0..<ConnectionConfig.maximumJumpHosts { last = try save(profiles, "hop-\(index)", jump: last.id) }
    XCTAssertEqual(try profiles.makeConfig(for: last.id).jumpHosts.count, ConnectionConfig.maximumJumpHosts)
    let other = try save(profiles, "other")
    XCTAssertThrowsError(try profiles.updateConnection(existing.id, name: existing.name, hostname: existing.hostname,
      port: existing.port, username: existing.username, jumpProfileId: other.id)) {
      XCTAssertEqual($0 as? ProfileServiceError, .jumpHostLimit, "editing an ancestor must not invalidate descendants")
    }
    XCTAssertNil(try profiles.profiles().first { $0.id == existing.id }?.jumpProfileId)
    XCTAssertThrowsError(try save(profiles, "too-deep", jump: last.id)) {
      XCTAssertEqual($0 as? ProfileServiceError, .jumpHostLimit)
    }
  }

  func test_missing_jump_credentials_name_the_hop_and_can_be_repaired() throws {
    let dir = try directory(), secrets = InMemorySecretStore(), profiles = service(dir, secrets: secrets)
    let jump = try save(profiles, "jump"), target = try save(profiles, "target", jump: jump.id)
    try secrets.delete(.password(jump.id))
    XCTAssertThrowsError(try profiles.makeConfig(for: target.id)) {
      XCTAssertEqual($0 as? ProfileServiceError, .jumpCredentialMissing(name: "jump"))
    }
    try profiles.updateCredential(for: jump.id, credential: .password("repaired"))
    XCTAssertEqual(try profiles.makeConfig(for: target.id).jumpHosts.first?.auth, .password("repaired"))
  }

  func test_route_changes_separate_forward_presets_without_recording_credentials() throws {
    let dir = try directory(), profiles = service(dir)
    let first = try save(profiles, "first"), second = try save(profiles, "second")
    let target = try save(profiles, "target", jump: first.id)
    let a = LocalForwardDestination(config: try profiles.makeConfig(for: target.id))
    _ = try profiles.updateConnection(target.id, name: target.name, hostname: target.hostname, port: target.port,
      username: target.username, jumpProfileId: second.id)
    let b = LocalForwardDestination(config: try profiles.makeConfig(for: target.id))
    XCTAssertNotEqual(a, b)
    let forwardFile = dir.appendingPathComponent("forwards.json")
    let store = LocalForwardStore(fileURL: forwardFile)
    _ = try store.save(destination: a, configuration: .init(localPort: 8080, targetHost: "localhost", targetPort: 80))
    XCTAssertEqual(try store.rules(for: a).count, 1)
    XCTAssertTrue(try store.rules(for: b).isEmpty)
    XCTAssertFalse(try String(contentsOf: forwardFile, encoding: .utf8).contains("password"))
    let direct = LocalForwardDestination(hostname: "target.test", port: 22, username: "test")
    XCTAssertEqual(LocalForwardDestination(config: .init(hostname: "target.test", username: "test", auth: .password("x"))), direct)
    let decoded = try JSONDecoder().decode(LocalForwardDestination.self, from: Data(#"{"hostname":"target.test","port":22,"username":"test"}"#.utf8))
    XCTAssertEqual(decoded, direct)
  }

  func test_connection_page_saves_and_restores_jump_and_keeps_missing_draft_explicit() throws {
    _ = NSApplication.shared
    let dir = try directory(), profiles = service(dir)
    let jump = try save(profiles, "jump")
    let session = SessionManager(knownHosts: KnownHostsStore(fileURL: dir.appendingPathComponent("known")))
    defer { session.disconnect() }
    let page = ConnectViewController(session: session, profiles: profiles, onLabel: { _ in })
    let controls = descendants(page.view)
    let popup = try XCTUnwrap(controls.compactMap { $0 as? JumpHostPopup }.first)
    popup.selectItem(at: 1)
    let fields = controls.compactMap { $0 as? NSTextField }
    try XCTUnwrap(fields.first { $0.placeholderString == "example.com" }).stringValue = "target.test"
    try XCTUnwrap(fields.first { $0.placeholderString == "root" }).stringValue = "test"
    let password = try XCTUnwrap(fields.compactMap { $0 as? NSSecureTextField }.first)
    password.stringValue = "target-password"
    let save = try XCTUnwrap(controls.compactMap { $0 as? NSButton }.first { $0.title == "保存连接" })
    save.performClick(nil)
    let target = try XCTUnwrap(profiles.profiles().first { $0.id != jump.id })
    XCTAssertEqual(target.jumpProfileId, jump.id)
    XCTAssertFalse(popup.isEnabled)
    XCTAssertEqual(popup.selectedProfileId, jump.id)
    let saved = try XCTUnwrap(controls.compactMap { $0 as? NSPopUpButton }.first { $0.action == NSSelectorFromString("savedChanged") })
    saved.selectItem(at: 0)
    XCTAssertTrue(saved.sendAction(try XCTUnwrap(saved.action), to: saved.target))
    popup.selectItem(at: try XCTUnwrap(popup.itemTitles.firstIndex { $0.contains("jump ·") }))
    XCTAssertTrue(popup.isEnabled)
    password.stringValue = "draft-password"
    try profiles.deleteConnection(target.id)
    try profiles.deleteConnection(jump.id)
    XCTAssertEqual(popup.selectedProfileId, jump.id)
    XCTAssertTrue(popup.titleOfSelectedItem?.contains("不可用") == true)
    XCTAssertEqual(password.stringValue, "draft-password")
    XCTAssertThrowsError(try profiles.jumpHosts(for: popup.selectedProfileId))
    save.performClick(nil)
    XCTAssertTrue(try profiles.profiles().isEmpty)
  }

  func test_editor_preserves_invalid_route_draft_and_updates_other_connection_pages() throws {
    _ = NSApplication.shared
    let dir = try directory(), profiles = service(dir)
    let first = try save(profiles, "first"), second = try save(profiles, "second"), target = try save(profiles, "target", jump: first.id)
    let session = SessionManager(knownHosts: KnownHostsStore(fileURL: dir.appendingPathComponent("known")))
    defer { session.disconnect() }
    let page = ConnectViewController(session: session, profiles: profiles, onLabel: { _ in })
    let controls = descendants(page.view)
    let saved = try XCTUnwrap(controls.compactMap { $0 as? NSPopUpButton }.first { $0.action == NSSelectorFromString("savedChanged") })
    saved.selectItem(withTitle: "target")
    XCTAssertTrue(saved.sendAction(try XCTUnwrap(saved.action), to: saved.target))
    let password = try XCTUnwrap(controls.compactMap { $0 as? NSSecureTextField }.first)
    password.stringValue = "draft"
    var dismissed = false
    let editor = ConnectionEditorViewController(profile: target, profiles: profiles) { dismissed = true }
    _ = editor.view
    XCTAssertFalse(editor.jumpPopup.itemTitles.contains { $0.contains("target ·") })
    editor.jumpPopup.selectItem(at: try XCTUnwrap(editor.jumpPopup.itemTitles.firstIndex { $0.contains("second ·") }))
    XCTAssertTrue(editor.saveChanges())
    XCTAssertTrue(dismissed)
    XCTAssertEqual(try profiles.makeConfig(for: target.id).jumpHosts.first?.hostname, "second.test")
    XCTAssertEqual(try XCTUnwrap(controls.compactMap { $0 as? JumpHostPopup }.first).selectedProfileId, second.id)
    XCTAssertEqual(password.stringValue, "", "a changed route clears credential drafts in other windows")
    let invalid = ConnectionEditorViewController(profile: second, profiles: profiles) {}
    _ = invalid.view
    invalid.jumpPopup.selectItem(at: try XCTUnwrap(invalid.jumpPopup.itemTitles.firstIndex { $0.contains("target ·") }))
    XCTAssertFalse(invalid.saveChanges())
    XCTAssertFalse(invalid.errorLabel.isHidden)
    XCTAssertTrue(invalid.errorLabel.stringValue.contains("循环"))
    XCTAssertEqual(invalid.jumpPopup.selectedProfileId, target.id)
  }
}
