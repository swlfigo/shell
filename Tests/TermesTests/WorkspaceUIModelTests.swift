import Foundation
import XCTest
import TermesKit
import SSHCore

@MainActor
final class WorkspaceUIModelTests: XCTestCase {
  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }
  private func service(_ directory: URL) -> ConnectionProfileService {
    ConnectionProfileService(connections: ConnectionStore(fileURL: directory.appendingPathComponent("connections.json")),
      keys: KeyStore(fileURL: directory.appendingPathComponent("keys.json")), secrets: InMemorySecretStore())
  }

  func test_appearance_settings_persist_independent_terminal_preferences() throws {
    let url = try directory().appendingPathComponent("appearance.json")
    let store = AppearanceStore(fileURL: url)
    XCTAssertEqual(store.settings, AppearanceSettings())
    let value = AppearanceSettings(theme: .light, terminalTheme: .graphite, terminalFontSize: 20)
    try store.update(value)
    XCTAssertEqual(AppearanceStore(fileURL: url).settings, value)
    var next = value; next.theme = .dark
    try store.update(next)
    XCTAssertEqual(store.settings.terminalTheme, .graphite)
    XCTAssertEqual(store.settings.terminalFontSize, 20)
  }

  func test_old_appearance_files_migrate_without_changing_theme_and_new_fonts_and_palettes_persist() throws {
    let url = try directory().appendingPathComponent("appearance.json")
    try Data(#"{"theme":"dark","terminalTheme":"graphite","terminalFontSize":14}"#.utf8).write(to: url)
    let store = AppearanceStore(fileURL: url)
    XCTAssertNil(store.error); XCTAssertNil(store.settings.terminalFontName)
    XCTAssertNil(store.settings.terminalTextColor)
    XCTAssertEqual(store.settings, .init(theme: .dark, terminalTheme: .graphite, terminalFontSize: 14))
    for theme in TerminalTheme.catalog {
      let value = AppearanceSettings(theme: .light, terminalTheme: theme, terminalFontSize: 16, terminalFontName: "SourceCodePro-Regular")
      try store.update(value)
      XCTAssertEqual(AppearanceStore(fileURL: url).settings, value)
    }
    let data = try Data(contentsOf: url), applied = store.settings
    for name in ["", " \n ", String(repeating: "f", count: 257), "Menlo\u{0}"] {
      var value = applied; value.terminalFontName = name
      XCTAssertThrowsError(try store.update(value))
      XCTAssertEqual(store.settings, applied); XCTAssertEqual(try Data(contentsOf: url), data)
    }
  }

  func test_invalid_or_failed_appearance_writes_keep_current_preferences_and_file() throws {
    let url = try directory().appendingPathComponent("appearance.json")
    let store = AppearanceStore(fileURL: url)
    let value = AppearanceSettings(theme: .dark, terminalTheme: .light, terminalFontSize: 18)
    try store.update(value)
    let data = try Data(contentsOf: url)
    for size in [9.0, 29.0, .nan, .infinity] {
      XCTAssertThrowsError(try store.update(.init(terminalFontSize: size)))
      XCTAssertEqual(store.settings, value); XCTAssertEqual(try Data(contentsOf: url), data)
    }
    try FileManager.default.removeItem(at: url)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    XCTAssertThrowsError(try store.update(.init()))
    XCTAssertEqual(store.settings, value); XCTAssertNotNil(store.error)
  }

  func test_corrupt_appearance_file_uses_defaults_without_overwriting_it() throws {
    let url = try directory().appendingPathComponent("appearance.json"), data = Data("broken".utf8)
    try data.write(to: url)
    let store = AppearanceStore(fileURL: url)
    XCTAssertNotNil(store.error); XCTAssertEqual(store.settings, AppearanceSettings())
    XCTAssertEqual(try Data(contentsOf: url), data)
  }

  func test_custom_text_color_persists_resets_and_invalid_rgb_preserves_the_file() throws {
    let url = try directory().appendingPathComponent("appearance.json"), store = AppearanceStore(fileURL: url)
    let value = AppearanceSettings(terminalTheme: .kanagawaWave, terminalTextColor: 0x40E090)
    try store.update(value)
    XCTAssertEqual(AppearanceStore(fileURL: url).settings, value)
    let data = try Data(contentsOf: url)
    for color in [UInt32(0x1000000), .max] {
      var invalid = value; invalid.terminalTextColor = color
      XCTAssertThrowsError(try store.update(invalid))
      XCTAssertEqual(store.settings, value); XCTAssertEqual(try Data(contentsOf: url), data)
    }
    var following = value; following.terminalTextColor = nil
    try store.update(following)
    XCTAssertNil(AppearanceStore(fileURL: url).settings.terminalTextColor)
    let invalidData = Data(#"{"theme":"dark","terminalTheme":"graphite","terminalFontSize":14,"terminalTextColor":16777216}"#.utf8)
    try invalidData.write(to: url)
    let invalidStore = AppearanceStore(fileURL: url)
    XCTAssertNotNil(invalidStore.error); XCTAssertEqual(invalidStore.settings, AppearanceSettings())
    XCTAssertEqual(try Data(contentsOf: url), invalidData)
  }

  func test_server_search_selection_and_live_states_remain_independent() throws {
    let service = service(try directory())
    let a = try service.saveConnection(name: "生产 API", hostname: "api.example.test", port: 2222, username: "deploy", credential: .password("secret-a"))
    let b = try service.saveConnection(name: "数据库", hostname: "db.example.test", port: 22, username: "ops", credential: .password("secret-b"))
    let model = ServerListModel(service: service)
    model.select(b.id)
    model.updateSessions([.init(profileID: a.id, state: .connected), .init(profileID: a.id, state: .needsHostKeyConfirm(fingerprint: "SHA256:test"))])
    XCTAssertEqual(model.status(for: a.id), .pending)
    XCTAssertEqual(model.sessionText(for: a.id), "等待信任 · 2 个会话")
    XCTAssertEqual(model.sessionText(for: b.id), "未连接")
    for query in ["生产", "API.EXAMPLE", "deploy", "2222"] {
      model.search = query; XCTAssertEqual(model.filteredProfiles.map(\.id), [a.id])
      XCTAssertEqual(model.selectedID, b.id)
    }
    model.search = " secret-a "
    XCTAssertTrue(model.filteredProfiles.isEmpty, "search indexes metadata only")
    model.search = "  "
    XCTAssertEqual(model.filteredProfiles.count, 2)
    XCTAssertEqual(model.selectedID, b.id)
  }

  func test_saved_edits_and_deletion_refresh_all_server_lists_without_selecting_another_server() throws {
    let service = service(try directory())
    let a = try service.saveConnection(name: "a", hostname: "a", port: 22, username: "u", credential: .password("pw"))
    let b = try service.saveConnection(name: "b", hostname: "b", port: 22, username: "u", credential: .password("pw"))
    let first = ServerListModel(service: service), second = ServerListModel(service: service)
    first.select(a.id); second.select(b.id)
    try service.updateConnection(a.id, name: "新名字", hostname: "new.test", port: 23, username: "admin")
    XCTAssertEqual(first.profiles, second.profiles)
    XCTAssertEqual(first.profiles.first { $0.id == a.id }?.name, "新名字")
    XCTAssertEqual(first.selectedID, a.id); XCTAssertEqual(second.selectedID, b.id)
    try service.deleteConnection(a.id)
    XCTAssertNil(first.selectedID); XCTAssertEqual(second.selectedID, b.id)
    XCTAssertEqual(first.profiles.map(\.id), [b.id])
  }

  func test_changed_saved_target_and_jump_route_do_not_claim_the_old_session_is_connected_to_it() throws {
    let service = service(try directory())
    let jump = try service.saveConnection(name: "jump", hostname: "jump.test", port: 22, username: "u", credential: .password("pw"))
    let profile = try service.saveConnection(name: "server", hostname: "old.test", port: 22, username: "u", credential: .password("pw"))
    let model = ServerListModel(service: service)
    model.updateSessions([.init(profileID: profile.id, state: .connected, destination: .init(hostname: "old.test", port: 22, username: "u"))])
    XCTAssertEqual(model.sessionText(for: profile.id), "已连接")
    try service.updateConnection(profile.id, name: "server", hostname: "old.test", port: 22, username: "u", jumpProfileId: jump.id)
    XCTAssertEqual(model.status(for: profile.id), .idle)
    XCTAssertEqual(model.sessionText(for: profile.id), "旧配置会话 · 1 个")
    try service.updateConnection(profile.id, name: "renamed", hostname: "new.test", port: 22, username: "u", jumpProfileId: nil)
    XCTAssertEqual(model.status(for: profile.id), .idle)
    XCTAssertEqual(model.sessionText(for: profile.id), "旧配置会话 · 1 个")
  }
}
