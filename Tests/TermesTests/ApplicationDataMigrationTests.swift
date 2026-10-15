import Foundation
import XCTest
import TermesKit
import SSHCore
@testable import Termes

@MainActor
final class ApplicationDataMigrationTests: XCTestCase {
  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("termes-migration-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  func test_fresh_install_creates_private_current_directory() throws {
    let support = try directory()
    let result = try ApplicationDataDirectory.prepare(in: support)
    XCTAssertEqual(result, ApplicationDataDirectory.current(in: support))
    XCTAssertFalse(FileManager.default.fileExists(atPath: ApplicationDataDirectory.legacy(in: support).path))
    let attributes = try FileManager.default.attributesOfItem(atPath: result.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
  }

  func test_entire_legacy_directory_and_permissions_are_copied_without_changing_originals() throws {
    let support = try directory(), legacy = ApplicationDataDirectory.legacy(in: support)
    try FileManager.default.createDirectory(at: legacy.appendingPathComponent("backups"), withIntermediateDirectories: true)
    let files = ["connections.json", "keys.json", "snippets.json", "local-forwards.json", "appearance.json", "known_hosts.json", "backups/original.json"]
    for name in files {
      let file = legacy.appendingPathComponent(name)
      try Data("retained Unicode 服务器: \(name)".utf8).write(to: file)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    let current = try ApplicationDataDirectory.prepare(in: support)
    for name in files {
      let original = legacy.appendingPathComponent(name), copy = current.appendingPathComponent(name)
      XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: original))
      let attributes = try FileManager.default.attributesOfItem(atPath: copy.path)
      XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: support.path).contains { $0.hasPrefix(".termes-migration-") })
  }

  func test_existing_current_data_wins_and_repeated_launches_do_not_reimport_old_values() throws {
    let support = try directory(), legacy = ApplicationDataDirectory.legacy(in: support)
    let current = ApplicationDataDirectory.current(in: support)
    for path in [legacy, current] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
    let old = legacy.appendingPathComponent("connections.json"), new = current.appendingPathComponent("connections.json")
    try Data("old".utf8).write(to: old)
    try Data("current".utf8).write(to: new)
    for _ in 0..<2 {
      XCTAssertEqual(try ApplicationDataDirectory.prepare(in: support), current)
      XCTAssertEqual(try Data(contentsOf: new), Data("current".utf8))
    }
    XCTAssertEqual(try Data(contentsOf: old), Data("old".utf8))
  }

  func test_legacy_path_that_is_a_file_is_not_copied_as_a_new_data_directory() throws {
    let support = try directory(), legacy = ApplicationDataDirectory.legacy(in: support)
    let data = Data("occupied legacy path".utf8)
    try data.write(to: legacy)
    XCTAssertThrowsError(try ApplicationDataDirectory.prepare(in: support))
    XCTAssertFalse(FileManager.default.fileExists(atPath: ApplicationDataDirectory.current(in: support).path))
    let services = AppServices(secrets: InMemorySecretStore(), applicationSupportDirectory: support)
    XCTAssertNotNil(services.startupDataWarning)
    XCTAssertEqual(try services.profiles.profiles(), [])
    XCTAssertEqual(try Data(contentsOf: legacy), data)
    var isDirectory: ObjCBool = false
    XCTAssertTrue(FileManager.default.fileExists(atPath: ApplicationDataDirectory.current(in: support).path, isDirectory: &isDirectory))
    XCTAssertTrue(isDirectory.boolValue)
  }

  func test_failed_copy_never_exposes_partial_current_data_and_removes_staging() throws {
    let support = try directory(), legacy = ApplicationDataDirectory.legacy(in: support)
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    let file = legacy.appendingPathComponent("connections.json")
    try Data("original".utf8).write(to: file)
    XCTAssertThrowsError(try ApplicationDataDirectory.prepare(in: support, fileManager: InterruptedCopyFileManager()))
    XCTAssertEqual(try Data(contentsOf: file), Data("original".utf8))
    XCTAssertFalse(FileManager.default.fileExists(atPath: ApplicationDataDirectory.current(in: support).path))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: support.path), [ApplicationIdentity.legacyName])
  }

  func test_app_services_restore_connection_identity_credentials_snippets_and_appearance() throws {
    let support = try directory(), legacy = ApplicationDataDirectory.legacy(in: support)
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    let profile = ConnectionProfile(name: "杭州服务器", hostname: "test.example", port: 2222, username: "deploy", auth: .password)
    try ConnectionStore(fileURL: legacy.appendingPathComponent("connections.json")).upsert(profile)
    let key = SSHKey(name: "保留的私钥记录")
    try KeyStore(fileURL: legacy.appendingPathComponent("keys.json")).upsert(key)
    let snippet = try SnippetStore(fileURL: legacy.appendingPathComponent("snippets.json")).save(name: "状态", command: "uptime", group: "常用")
    let settings = AppearanceSettings(theme: .dark, terminalTheme: .kanagawaWave, terminalFontSize: 16, terminalTextColor: 0x44DD77)
    try AppearanceStore(fileURL: legacy.appendingPathComponent("appearance.json")).update(settings)
    let primary = InMemorySecretStore(), oldSecrets = InMemorySecretStore()
    try oldSecrets.set(Data("test-password".utf8), for: .password(profile.id))
    let secrets = LegacyCompatibleSecretStore(primary: primary, legacy: oldSecrets)
    let services = AppServices(secrets: secrets, applicationSupportDirectory: support)
    XCTAssertNil(services.startupDataWarning)
    XCTAssertEqual(try services.profiles.profiles(), [profile])
    XCTAssertEqual(try services.profiles.keys(), [key])
    XCTAssertEqual(try services.profiles.makeConfig(for: profile.id), .init(hostname: profile.hostname, port: profile.port, username: profile.username, auth: .password("test-password")))
    XCTAssertEqual(try primary.data(for: .password(profile.id)), Data("test-password".utf8))
    XCTAssertEqual(try services.snippets.all(), [snippet])
    XCTAssertEqual(services.appearance.settings, settings)
    let updated = try services.profiles.updateConnection(profile.id, name: "新名称", hostname: profile.hostname, port: profile.port, username: profile.username)
    XCTAssertEqual(try ConnectionStore(fileURL: ApplicationDataDirectory.current(in: support).appendingPathComponent("connections.json")).get(profile.id), updated)
    XCTAssertEqual(try ConnectionStore(fileURL: legacy.appendingPathComponent("connections.json")).get(profile.id), profile)
  }

  func test_migration_failure_keeps_app_services_on_existing_data_and_reports_warning() throws {
    let support = try directory(), legacy = ApplicationDataDirectory.legacy(in: support)
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    let profile = ConnectionProfile(name: "existing", hostname: "test.example", port: 22, username: "deploy", auth: .password)
    try ConnectionStore(fileURL: legacy.appendingPathComponent("connections.json")).upsert(profile)
    let obstacle = ApplicationDataDirectory.current(in: support)
    try Data("occupied path".utf8).write(to: obstacle)
    let services = AppServices(secrets: InMemorySecretStore(), applicationSupportDirectory: support)
    XCTAssertNotNil(services.startupDataWarning)
    XCTAssertEqual(try services.profiles.profiles(), [profile])
    XCTAssertEqual(try Data(contentsOf: obstacle), Data("occupied path".utf8))
  }
}

private final class InterruptedCopyFileManager: FileManager, @unchecked Sendable {
  override func copyItem(at source: URL, to destination: URL) throws {
    try super.copyItem(at: source, to: destination)
    throw CocoaError(.fileWriteUnknown)
  }
}
