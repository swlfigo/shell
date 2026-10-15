import AppKit
import XCTest
import TermesKit
import SSHCore
@testable import Termes

@MainActor
final class ConnectViewControllerTests: XCTestCase {
  private func makeService() throws -> ConnectionProfileService {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return ConnectionProfileService(
      connections: ConnectionStore(fileURL: dir.appendingPathComponent("connections.json")),
      keys: KeyStore(fileURL: dir.appendingPathComponent("keys.json")), secrets: InMemorySecretStore())
  }

  private func makePage(_ service: ConnectionProfileService) -> ConnectViewController {
    _ = NSApplication.shared
    let session = SessionManager(knownHosts: KnownHostsStore(
      fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
    let page = ConnectViewController(session: session, profiles: service, onLabel: { _ in })
    _ = page.view
    return page
  }

  private func descendants(of view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap { descendants(of: $0) }
  }

  private func popup(_ action: String, in page: ConnectViewController) throws -> NSPopUpButton {
    try XCTUnwrap(descendants(of: page.view).compactMap { $0 as? NSPopUpButton }
      .first { $0.action == NSSelectorFromString(action) })
  }

  private func select(_ title: String, in popup: NSPopUpButton) throws {
    XCTAssertNotNil(popup.item(withTitle: title))
    popup.selectItem(withTitle: title)
    let action = try XCTUnwrap(popup.action)
    XCTAssertTrue(NSApp.sendAction(action, to: popup.target, from: popup))
  }

  func test_custom_server_name_is_saved_restored_and_used_for_session_labels() throws {
    let service = try makeService()
    let page = makePage(service)
    let fields = descendants(of: page.view).compactMap { $0 as? NSTextField }
    let name = try XCTUnwrap(fields.first { $0.accessibilityLabel() == "服务器名称" })
    let host = try XCTUnwrap(fields.first { $0.placeholderString == "example.com" })
    let user = try XCTUnwrap(fields.first { $0.placeholderString == "root" })
    let password = try XCTUnwrap(fields.compactMap { $0 as? NSSecureTextField }.first)
    name.stringValue = "  生产服务器 · 上海  "
    host.stringValue = "192.0.2.10"
    user.stringValue = "admin"
    password.stringValue = "test-password"
    XCTAssertEqual(page.connectionLabel(host: host.stringValue, user: user.stringValue),
                   SessionLabel(name: "生产服务器 · 上海", username: "admin"))
    let save = try XCTUnwrap(descendants(of: page.view).compactMap { $0 as? NSButton }
      .first { $0.title == "保存连接" })
    save.performClick(nil)
    let profile = try XCTUnwrap(service.profiles().first)
    XCTAssertEqual(profile.name, "生产服务器 · 上海")
    XCTAssertEqual(profile.hostname, "192.0.2.10")
    XCTAssertEqual(try service.makeConfig(for: profile.id).auth, .password("test-password"))
    XCTAssertEqual(try popup("savedChanged", in: page).titleOfSelectedItem, profile.name)
    XCTAssertFalse(name.isEnabled)
    XCTAssertEqual(password.stringValue, "")
    XCTAssertEqual(save.title, "更新凭据")

    let restored = makePage(service)
    try select(profile.name, in: popup("savedChanged", in: restored))
    let restoredName = try XCTUnwrap(descendants(of: restored.view).compactMap { $0 as? NSTextField }
      .first { $0.accessibilityLabel() == "服务器名称" })
    XCTAssertEqual(restoredName.stringValue, profile.name)
    try select("新建连接…", in: popup("savedChanged", in: restored))
    XCTAssertEqual(restoredName.stringValue, "")
    XCTAssertTrue(restoredName.isEnabled)
    XCTAssertEqual(try service.profiles().count, 1)
  }

  func test_blank_server_name_falls_back_to_target_and_failed_save_preserves_name_draft() throws {
    let service = try makeService()
    let page = makePage(service)
    let fields = descendants(of: page.view).compactMap { $0 as? NSTextField }
    let name = try XCTUnwrap(fields.first { $0.accessibilityLabel() == "服务器名称" })
    let host = try XCTUnwrap(fields.first { $0.placeholderString == "example.com" })
    let user = try XCTUnwrap(fields.first { $0.placeholderString == "root" })
    let password = try XCTUnwrap(fields.compactMap { $0 as? NSSecureTextField }.first)
    host.stringValue = "192.0.2.20"
    user.stringValue = "root"
    let save = try XCTUnwrap(descendants(of: page.view).compactMap { $0 as? NSButton }
      .first { $0.title == "保存连接" })
    name.stringValue = "未保存的服务器"
    save.performClick(nil)
    XCTAssertTrue(try service.profiles().isEmpty)
    XCTAssertEqual(name.stringValue, "未保存的服务器")
    XCTAssertTrue(name.isEnabled)
    name.stringValue = " \t "
    password.stringValue = "test-password"
    save.performClick(nil)
    XCTAssertEqual(try service.profiles().first?.name, "root@192.0.2.20")
    XCTAssertEqual(name.stringValue, "root@192.0.2.20")
    XCTAssertEqual(page.connectionLabel(host: host.stringValue, user: user.stringValue).name,
                   "root@192.0.2.20")
  }

  func test_imported_password_can_be_repaired_from_the_connection_page() throws {
    let service = try makeService()
    let profile = ConnectionProfile(name: "imported", hostname: "example.test", port: 2222,
                                     username: "admin", auth: .password)
    try service.importSnapshot(ConnectionSnapshot(profiles: [profile], keys: []))
    let page = makePage(service)
    let saved = try popup("savedChanged", in: page)
    try select("imported", in: saved)

    let fields = descendants(of: page.view).compactMap { $0 as? NSTextField }
    for value in ["example.test", "2222", "admin"] {
      let field = try XCTUnwrap(fields.first { $0.stringValue == value })
      XCTAssertFalse(field.isEnabled, "saved target must match the host used to connect")
    }
    let password = try XCTUnwrap(fields.compactMap { $0 as? NSSecureTextField }
      .first { !$0.isHiddenOrHasHiddenAncestor })
    password.stringValue = "replacement-password"
    let update = try XCTUnwrap(descendants(of: page.view).compactMap { $0 as? NSButton }
      .first { $0.title == "更新凭据" })
    update.performClick(nil)

    XCTAssertEqual(try service.makeConfig(for: profile.id).auth, .password("replacement-password"))
    XCTAssertEqual(try service.profiles().count, 1)
    XCTAssertEqual(saved.titleOfSelectedItem, "imported")
    XCTAssertEqual(password.stringValue, "")
    try select("新建连接…", in: saved)
    XCTAssertEqual(update.title, "保存连接")
    XCTAssertTrue(try XCTUnwrap(fields.first { $0.stringValue == "example.test" }).isEnabled)
  }

  func test_imported_private_key_can_reuse_a_local_key_from_the_connection_page() throws {
    let service = try makeService()
    let local = try service.saveConnection(name: "local", hostname: "local.test", port: 22, username: "u",
      credential: .privateKey(data: Data("LOCALKEY".utf8), name: "local-key", passphrase: "pp"))
    let missingKey = SSHKey(name: "missing-key")
    let imported = ConnectionProfile(name: "imported", hostname: "remote.test", port: 22, username: "u",
      auth: .privateKey(keyId: missingKey.id, hasPassphrase: true))
    try service.importSnapshot(ConnectionSnapshot(profiles: [imported], keys: [missingKey]))
    let page = makePage(service)
    try select("imported", in: popup("savedChanged", in: page))
    try select("local-key", in: popup("keyPopupChanged", in: page))
    let update = try XCTUnwrap(descendants(of: page.view).compactMap { $0 as? NSButton }
      .first { $0.title == "更新凭据" })
    update.performClick(nil)

    XCTAssertEqual(try service.makeConfig(for: imported.id).auth, .privateKey(data: Data("LOCALKEY".utf8), passphrase: "pp"))
    XCTAssertEqual(try service.profiles().first { $0.id == local.id }, local)
    XCTAssertEqual(try service.profiles().count, 2)
  }

  func test_switching_saved_hosts_clears_unsaved_credentials() throws {
    let service = try makeService()
    let a = ConnectionProfile(name: "a", hostname: "a.test", port: 22, username: "u", auth: .password)
    let b = ConnectionProfile(name: "b", hostname: "b.test", port: 22, username: "u", auth: .password)
    try service.importSnapshot(ConnectionSnapshot(profiles: [a, b], keys: []))
    let page = makePage(service)
    let saved = try popup("savedChanged", in: page)
    try select("a", in: saved)
    let secrets = descendants(of: page.view).compactMap { $0 as? NSSecureTextField }
    secrets.forEach { $0.stringValue = "unsaved-secret" }
    try select("b", in: saved)
    XCTAssertTrue(secrets.allSatisfy { $0.stringValue.isEmpty })
    XCTAssertThrowsError(try service.makeConfig(for: b.id))
  }

  func test_edits_in_another_window_refresh_saved_target_and_clear_only_target_changed_drafts() throws {
    let service = try makeService()
    let profile = try service.saveConnection(name: "old", hostname: "old.test", port: 22,
                                             username: "old-user", credential: .password("pw"))
    let page = makePage(service)
    let saved = try popup("savedChanged", in: page)
    try select("old", in: saved)
    let fields = descendants(of: page.view).compactMap { $0 as? NSTextField }
    let name = try XCTUnwrap(fields.first { $0.accessibilityLabel() == "服务器名称" })
    let password = try XCTUnwrap(fields.compactMap { $0 as? NSSecureTextField }
      .first { !$0.isHiddenOrHasHiddenAncestor })
    let edit = try XCTUnwrap(descendants(of: page.view).compactMap { $0 as? NSButton }
      .first { $0.title == "编辑信息…" })
    XCTAssertFalse(edit.isHiddenOrHasHiddenAncestor)
    password.stringValue = "draft"
    try service.updateConnection(profile.id, name: "renamed", hostname: "old.test", port: 22, username: "old-user")
    XCTAssertEqual(saved.titleOfSelectedItem, "renamed")
    XCTAssertEqual(name.stringValue, "renamed")
    XCTAssertEqual(password.stringValue, "draft")
    try service.updateConnection(profile.id, name: "renamed", hostname: "new.test", port: 2222, username: "new-user")
    XCTAssertEqual(password.stringValue, "")
    for value in ["new.test", "2222", "new-user"] {
      XCTAssertFalse(try XCTUnwrap(fields.first { $0.stringValue == value }).isEnabled)
    }
    let key = try service.importKey(data: Data("KEY".utf8), name: "draft-key", passphrase: nil)
    try select(key.name, in: popup("keyPopupChanged", in: page))
    try service.updateConnection(profile.id, name: "renamed", hostname: "third.test", port: 22, username: "u")
    XCTAssertEqual(try popup("keyPopupChanged", in: page).indexOfSelectedItem, 0)
    XCTAssertEqual(try service.makeConfig(for: profile.id).auth, .password("pw"))
    try select("新建连接…", in: saved)
    XCTAssertTrue(edit.isHiddenOrHasHiddenAncestor)
  }

  func test_minimum_pane_width_keeps_password_and_private_key_forms_inside_the_scroll_document() throws {
    let page = makePage(try makeService())
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 140),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = page.view
    defer { window.close() }
    let scroll = try XCTUnwrap(descendants(of: page.view).compactMap { $0 as? NSScrollView }.first)
    let auth = try XCTUnwrap(descendants(of: page.view).compactMap { $0 as? NSSegmentedControl }.first)
    // Repeatedly cross the compact-form boundary with both authentication methods;
    // the inactive layout's required widths must be released before changing direction.
    for (width, mode) in [240.0, 820, 419, 420, 240, 820].flatMap({ width in [0, 1].map { (width, $0) } }) {
      window.setContentSize(NSSize(width: width, height: 140))
      auth.selectedSegment = mode
      XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(auth.action), to: auth.target, from: auth))
      page.view.layoutSubtreeIfNeeded()
      page.view.layoutSubtreeIfNeeded()
      let document = try XCTUnwrap(scroll.documentView)
      scroll.contentView.scroll(to: .zero)
      // Autohiding legacy scrollers can retile the clip view after document layout.
      window.layoutIfNeeded()
      XCTAssertEqual(document.frame.width, scroll.contentView.bounds.width, accuracy: 0.5,
        "width=\(width), auth=\(mode), clip=\(scroll.contentView.frame), bounds=\(scroll.contentView.bounds), document=\(document.frame), scroller=\(scroll.scrollerStyle.rawValue)")
      XCTAssertGreaterThan(document.frame.height, scroll.contentView.bounds.height)
      let controls = descendants(of: document).compactMap { $0 as? NSControl }
        .filter { !$0.isHiddenOrHasHiddenAncestor }
      for control in controls {
        let rect = control.convert(control.bounds, to: document)
        XCTAssertGreaterThanOrEqual(rect.minX, -0.5)
        XCTAssertLessThanOrEqual(rect.maxX, document.bounds.width + 0.5)
        XCTAssertGreaterThan(rect.width, 0)
      }
      let connect = try XCTUnwrap(controls.compactMap { $0 as? NSButton }.first { $0.title == "连接" })
      connect.scrollToVisible(connect.bounds)
      XCTAssertTrue(scroll.contentView.bounds.contains(connect.convert(connect.bounds, to: document)))
      XCTAssertEqual(window.frame.width, width, accuracy: 0.5)
    }
    page.showError("认证失败")
    let document = try XCTUnwrap(scroll.documentView)
    let error = try XCTUnwrap(descendants(of: document).compactMap { $0 as? NSTextField }
      .first { $0.stringValue == "连接/认证失败: 认证失败" })
    XCTAssertTrue(scroll.contentView.bounds.intersects(error.convert(error.bounds, to: document)))
  }

  func test_private_key_controls_fill_available_width_in_saved_connection_form() throws {
    let service = try makeService()
    let profile = try service.saveConnection(name: "server", hostname: "host", port: 22, username: "u",
      credential: .privateKey(data: Data("KEY".utf8), name: "shared-key", passphrase: nil))
    let page = makePage(service)
    try select(profile.name, in: popup("savedChanged", in: page))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 540),
                          styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = page.view
    defer { window.close() }
    let keyPopup = try popup("keyPopupChanged", in: page)
    let host = try XCTUnwrap(descendants(of: page.view).compactMap { $0 as? NSTextField }
      .first { $0.placeholderString == "example.com" })
    let choose = try XCTUnwrap(descendants(of: page.view).compactMap { $0 as? NSButton }
      .first { $0.title == "选择私钥文件" })
    for width in [820.0, 240.0, 820.0] {
      window.setContentSize(NSSize(width: width, height: 540))
      page.view.layoutSubtreeIfNeeded()
      page.view.layoutSubtreeIfNeeded()
      XCTAssertEqual(keyPopup.frame.width, host.frame.width, accuracy: 0.5)
      XCTAssertEqual(choose.frame.width, host.frame.width, accuracy: 0.5)
      XCTAssertGreaterThanOrEqual(choose.frame.width, choose.intrinsicContentSize.width)
      XCTAssertGreaterThanOrEqual(keyPopup.frame.width, 180)
    }
    try select("shared-key", in: keyPopup)
    page.view.layoutSubtreeIfNeeded()
    XCTAssertTrue(choose.isHiddenOrHasHiddenAncestor)
    XCTAssertEqual(keyPopup.frame.width, host.frame.width, accuracy: 0.5)
  }

  func test_resizing_the_connection_page_preserves_entered_fields_and_wraps_long_errors() throws {
    let page = makePage(try makeService())
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 540),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = page.view
    defer { window.close() }
    let host = try XCTUnwrap(descendants(of: page.view).compactMap { $0 as? NSTextField }
      .first { $0.placeholderString == "example.com" })
    host.stringValue = "my-host.test"
    page.view.layoutSubtreeIfNeeded()
    page.view.layoutSubtreeIfNeeded()
    XCTAssertEqual(window.frame.width, 820, accuracy: 0.5)
    let wideScroll = try XCTUnwrap(descendants(of: page.view).compactMap { $0 as? NSScrollView }.first)
    let wideDocument = try XCTUnwrap(wideScroll.documentView)
    XCTAssertGreaterThanOrEqual(wideDocument.frame.height, page.view.bounds.height)
    XCTAssertGreaterThanOrEqual(wideDocument.frame.height, wideScroll.contentView.bounds.height)
    let wideForm = try XCTUnwrap(wideDocument.subviews.first)
    XCTAssertEqual(wideForm.frame.midX, wideDocument.bounds.midX, accuracy: 0.5)
    XCTAssertEqual(wideForm.frame.midY, wideDocument.bounds.midY, accuracy: 0.5)
    page.showError(String(repeating: "连接失败，请检查网络。", count: 30))
    for width in [240.0, 820.0] {
      window.setContentSize(NSSize(width: width, height: 140))
      page.view.layoutSubtreeIfNeeded()
      page.view.layoutSubtreeIfNeeded()
      XCTAssertEqual(window.frame.width, width, accuracy: 0.5)
      XCTAssertEqual(host.stringValue, "my-host.test")
      let scroll = try XCTUnwrap(descendants(of: page.view).compactMap { $0 as? NSScrollView }.first)
      let document = try XCTUnwrap(scroll.documentView)
      let error = try XCTUnwrap(descendants(of: document).compactMap { $0 as? NSTextField }
        .first { $0.stringValue.hasPrefix("连接/认证失败:") })
      XCTAssertLessThanOrEqual(error.alignmentRect(forFrame: error.frame).width,
                              min(420, document.bounds.width - 32) + 0.5)
      let rect = error.convert(error.bounds, to: document)
      XCTAssertGreaterThanOrEqual(rect.minX, 0)
      XCTAssertLessThanOrEqual(rect.maxX, document.bounds.width)
      XCTAssertGreaterThan(error.frame.height, 30)
    }
  }
}
