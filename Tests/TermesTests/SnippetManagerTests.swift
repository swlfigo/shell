import AppKit
import XCTest
import TermesKit
@testable import Termes

@MainActor
final class SnippetManagerTests: XCTestCase {
  private func makeStore() throws -> SnippetStore {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return SnippetStore(fileURL: directory.appendingPathComponent("snippets.json"))
  }

  private func makePage(_ store: SnippetStore) -> SnippetManagerViewController {
    _ = NSApplication.shared
    let page = SnippetManagerViewController(store: store)
    _ = page.view
    return page
  }

  func test_create_edit_and_delete_from_the_manager() throws {
    let store = try makeStore()
    let page = makePage(store)
    page.nameField.stringValue = "Disk"
    page.commandField.stringValue = "df -h"
    XCTAssertTrue(page.saveChanges())
    let first = try XCTUnwrap(page.snippets.first)
    XCTAssertEqual(page.editingID, first.id)
    page.commandField.stringValue = "df -h /"
    XCTAssertTrue(page.saveChanges())
    XCTAssertEqual(try store.all(), [Snippet(id: first.id, name: "Disk", command: "df -h /")])
    XCTAssertTrue(page.deleteSnippet(first.id))
    XCTAssertNil(page.editingID)
    XCTAssertEqual(page.snippets, [])
    XCTAssertEqual(page.nameField.stringValue, "")
    XCTAssertEqual(page.commandField.stringValue, "")
  }

  func test_invalid_command_keeps_the_draft_and_shows_the_error() throws {
    let store = try makeStore()
    let page = makePage(store)
    page.nameField.stringValue = "Draft"
    page.commandField.stringValue = "pwd\nls"
    XCTAssertFalse(page.saveChanges())
    XCTAssertEqual(page.nameField.stringValue, "Draft")
    XCTAssertEqual(page.commandField.stringValue, "pwd\nls")
    XCTAssertFalse(page.errorLabel.isHidden)
    XCTAssertEqual(try store.all(), [])
  }

  func test_other_managers_refresh_without_losing_unsaved_edits_or_resurrecting_deleted_items() throws {
    let store = try makeStore()
    let item = try store.save(name: "Disk", command: "df -h")
    let a = makePage(store)
    let b = makePage(store)
    for page in [a, b] { page.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    b.commandField.stringValue = "unsaved draft"
    a.nameField.stringValue = "Renamed"
    XCTAssertTrue(a.saveChanges())
    XCTAssertEqual(b.snippets.first?.name, "Renamed")
    XCTAssertEqual(b.commandField.stringValue, "unsaved draft")
    XCTAssertTrue(a.deleteSnippet(item.id))
    XCTAssertEqual(b.snippets, [])
    XCTAssertEqual(b.commandField.stringValue, "unsaved draft")
    XCTAssertFalse(b.saveChanges(), "a stale edit cannot silently recreate a deleted command")
    XCTAssertEqual(try store.all(), [])
    b.newSnippet()
    XCTAssertNil(b.editingID)
    XCTAssertEqual(b.commandField.stringValue, "")
  }

  func test_clean_editor_reflects_changes_from_another_manager() throws {
    let store = try makeStore()
    let item = try store.save(name: "Disk", command: "df -h")
    let page = makePage(store)
    page.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    try store.save(id: item.id, name: "Renamed", command: "df -h /")
    XCTAssertEqual(page.nameField.stringValue, "Renamed")
    XCTAssertEqual(page.commandField.stringValue, "df -h /")
    try store.delete(item.id)
    XCTAssertNil(page.editingID)
    XCTAssertEqual(page.nameField.stringValue, "")
  }

  func test_minimum_manager_size_keeps_controls_visible_and_preserves_a_long_command() throws {
    let page = makePage(try makeStore())
    page.nameField.stringValue = "Long command"
    let command = "printf '" + String(repeating: "x", count: 500) + "'"
    page.commandField.stringValue = command
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 480),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = page.view
    defer { window.close() }
    for size in [NSSize(width: 560, height: 420), NSSize(width: 900, height: 600)] {
      window.setContentSize(size)
      page.view.layoutSubtreeIfNeeded()
      page.view.layoutSubtreeIfNeeded()
      XCTAssertEqual(page.commandField.stringValue, command)
      for control in [page.nameField, page.commandField, page.table] {
        let rect = control.convert(control.bounds, to: page.view)
        XCTAssertGreaterThan(rect.width, 0)
        XCTAssertGreaterThanOrEqual(rect.minX, 0)
        XCTAssertLessThanOrEqual(rect.maxX, size.width + 0.5)
      }
      let scroll = try XCTUnwrap(page.table.enclosingScrollView)
      XCTAssertGreaterThanOrEqual(scroll.frame.height, 120)
      XCTAssertEqual(page.table.frame.width, scroll.contentView.bounds.width, accuracy: 0.5)
      XCTAssertEqual(window.frame.width, size.width, accuracy: 0.5)
    }
  }

  func test_insert_menu_is_disabled_for_an_idle_pane() throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let services = AppServices(directory: directory, secrets: InMemorySecretStore())
    let controller = MainWindowController(services: services, empty: false)
    defer { controller.close() }
    let snippet = try services.snippets.save(name: "Disk", command: "df -h")
    let item = NSMenuItem(title: snippet.name, action: #selector(MainWindowController.insertSnippet(_:)), keyEquivalent: "")
    item.representedObject = snippet.id
    XCTAssertFalse(controller.validateMenuItem(item))
    controller.insertSnippet(item)
    XCTAssertEqual(controller.focusedPane?.session.state, .idle)
  }

  func test_script_editor_saves_group_and_template_then_keeps_stale_draft() throws {
    let store = try makeStore(), page = makePage(store)
    page.nameField.stringValue = "部署"
    page.groupField.stringValue = "运维"
    page.kindPopup.selectItem(at: 1)
    XCTAssertTrue(page.kindPopup.sendAction(try XCTUnwrap(page.kindPopup.action), to: page.kindPopup.target))
    page.templateButton.state = .on
    page.scriptView.string = "cd '{{path}}'\npwd"
    XCTAssertTrue(page.saveChanges())
    let item = try XCTUnwrap(store.all().first)
    XCTAssertEqual(item.kind, .script); XCTAssertEqual(item.group, "运维"); XCTAssertTrue(item.usesParameters)
    page.scriptView.string = "cd '{{path}}'\nls"
    let latest = try store.save(id: item.id, name: item.name, command: item.command, group: "新分组")
    XCTAssertEqual(page.scriptView.string, "cd '{{path}}'\nls")
    XCTAssertEqual(page.groupField.stringValue, "运维")
    XCTAssertFalse(page.saveChanges())
    XCTAssertFalse(page.errorLabel.isHidden)
    XCTAssertEqual(try store.all(), [latest])
  }

  func test_grouped_menu_rebuilds_from_latest_store_and_keeps_legacy_items() throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let services = AppServices(directory: directory, secrets: InMemorySecretStore()), delegate = AppDelegate(services: services)
    let a = try services.snippets.save(name: "A", command: "pwd", group: "运维")
    let b = try services.snippets.save(name: "B", command: "ls")
    let c = try services.snippets.save(name: "C", command: "echo x", group: "运维")
    let menu = NSMenu(); menu.identifier = .init("snippets")
    delegate.menuNeedsUpdate(menu)
    XCTAssertEqual(menu.items.map(\.title), ["运维", "B"])
    XCTAssertEqual(menu.items[0].submenu?.items.compactMap { $0.representedObject as? UUID }, [a.id, c.id])
    XCTAssertEqual(menu.items[1].representedObject as? UUID, b.id)
    try services.snippets.delete(c.id)
    try services.snippets.save(id: a.id, name: "Renamed", command: "pwd", group: "部署")
    delegate.menuNeedsUpdate(menu)
    XCTAssertEqual(menu.items.map(\.title), ["部署", "B"])
    XCTAssertEqual(menu.items[0].submenu?.items.map(\.title), ["Renamed"])
  }
}
