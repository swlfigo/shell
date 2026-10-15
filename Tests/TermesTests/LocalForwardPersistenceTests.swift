import AppKit
import Combine
import XCTest
import SSHCore
import TermesKit
@testable import Termes

private final class PresetForward: LocalForwarding, @unchecked Sendable {
  let localPort = 8080
  let events: AsyncStream<LocalForwardEvent>
  private let continuation: AsyncStream<LocalForwardEvent>.Continuation
  private let lock = NSLock()
  private var stopped = false
  var isStopped: Bool { lock.withLock { stopped } }
  init() { (events, continuation) = AsyncStream.makeStream() }
  func stop() async { lock.withLock { stopped = true }; continuation.finish() }
}

@MainActor
final class LocalForwardPersistenceTests: XCTestCase {
  private let destination = LocalForwardDestination(hostname: "server.example", port: 22, username: "user")
  private let configuration = LocalForwardConfiguration(localPort: 8080, targetHost: "db.internal", targetPort: 5432)
  private let edited = LocalForwardConfiguration(localPort: 8081, targetHost: "db2.internal", targetPort: 5433)

  private func url() -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return directory.appendingPathComponent("local-forwards.json")
  }
  private func wait(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = Date().addingTimeInterval(10)
    while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    guard predicate() else { XCTFail("timed out", file: file, line: line); throw CancellationError() }
  }

  func test_restart_preserves_rules_order_identity_and_separates_endpoint_and_user() throws {
    let file = url()
    let persisted = LocalForwardStore(fileURL: file)
    let first = try persisted.save(destination: destination, configuration: configuration)
    let second = try persisted.save(destination: destination, configuration: edited)
    let changed = try persisted.save(id: first.id, destination: destination, configuration: edited, expected: configuration)
    let restarted = LocalForwardStore(fileURL: file)
    XCTAssertEqual(try restarted.rules(for: destination), [changed, second])
    for other in [LocalForwardDestination(hostname: "other", port: 22, username: "user"),
                  .init(hostname: "server.example", port: 2222, username: "user"),
                  .init(hostname: "server.example", port: 22, username: "USER")] {
      XCTAssertTrue(try restarted.rules(for: other).isEmpty)
      _ = try restarted.save(destination: other, configuration: configuration)
    }
    XCTAssertEqual(try restarted.rules(for: .init(hostname: " SERVER.EXAMPLE ", port: 22, username: "user")), [changed, second])
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    let rows = try XCTUnwrap(json["rules"] as? [[String: Any]])
    XCTAssertEqual(Set(rows[0].keys), ["id", "destination", "configuration"])
    try restarted.delete(first.id, destination: destination, expected: edited)
    XCTAssertEqual(try LocalForwardStore(fileURL: file).rules(for: destination), [second])
  }

  func test_stale_edit_delete_and_wrong_destination_never_overwrite_other_changes() throws {
    let file = url(), store = LocalForwardStore(fileURL: file)
    let item = try store.save(destination: destination, configuration: configuration)
    _ = try store.save(id: item.id, destination: destination, configuration: edited, expected: configuration)
    let before = try Data(contentsOf: file)
    XCTAssertThrowsError(try store.save(id: item.id, destination: destination, configuration: configuration, expected: configuration))
    XCTAssertThrowsError(try store.delete(item.id, destination: destination, expected: configuration))
    XCTAssertThrowsError(try store.delete(item.id, destination: .init(hostname: "other", port: 22, username: "user")))
    XCTAssertEqual(try Data(contentsOf: file), before)
    try store.delete(item.id, destination: destination, expected: edited)
    XCTAssertThrowsError(try store.save(id: item.id, destination: destination, configuration: configuration))
    XCTAssertTrue(try store.rules(for: destination).isEmpty)
  }

  func test_corrupt_unsupported_duplicate_and_invalid_records_are_not_overwritten() throws {
    let file = url(), store = LocalForwardStore(fileURL: file)
    let item = try store.save(destination: destination, configuration: configuration)
    let valid = try Data(contentsOf: file)
    var document = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
    var fixtures = [Data("broken".utf8)]
    document["version"] = 2
    fixtures.append(try JSONSerialization.data(withJSONObject: document))
    document["version"] = 1
    let rows = try XCTUnwrap(document["rules"] as? [[String: Any]])
    document["rules"] = rows + rows
    fixtures.append(try JSONSerialization.data(withJSONObject: document))
    var bad = rows[0]
    bad["configuration"] = ["localPort": 0, "targetHost": "db", "targetPort": 80]
    document["rules"] = [bad]
    fixtures.append(try JSONSerialization.data(withJSONObject: document))
    var notifications = 0
    let observer = store.didChange.sink { notifications += 1 }
    defer { observer.cancel() }
    for data in fixtures {
      try data.write(to: file)
      XCTAssertThrowsError(try store.rules(for: destination))
      XCTAssertThrowsError(try store.save(destination: destination, configuration: edited))
      XCTAssertThrowsError(try store.delete(item.id, destination: destination))
      XCTAssertEqual(try Data(contentsOf: file), data)
    }
    XCTAssertEqual(notifications, 0)
  }

  func test_io_failure_does_not_notify_or_discard_existing_manager_rules() async throws {
    let file = url(), store = LocalForwardStore(fileURL: file)
    let manager = LocalForwardManager(store: store) { _ in PresetForward() }
    await manager.bindDestination(destination)
    let id = try manager.save(configuration: configuration)
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    var notifications = 0
    let observer = store.didChange.sink { notifications += 1 }
    defer { observer.cancel() }
    manager.reloadSavedRules()
    XCTAssertNotNil(manager.storageError)
    XCTAssertThrowsError(try manager.save(id: id, configuration: edited))
    XCTAssertThrowsError(try manager.remove(id))
    XCTAssertEqual(manager.rules[0].configuration, configuration)
    XCTAssertEqual(notifications, 0)
    let missingParent = LocalForwardStore(fileURL: url().appendingPathComponent("missing/rules.json"))
    XCTAssertThrowsError(try missingParent.save(destination: destination, configuration: configuration))
  }

  func test_restoration_does_not_start_and_saving_requires_known_destination() async throws {
    let file = url(), store = LocalForwardStore(fileURL: file)
    var starts = 0
    let manager = LocalForwardManager(store: store) { _ in starts += 1; return PresetForward() }
    XCTAssertFalse(manager.canSave)
    XCTAssertThrowsError(try manager.save(configuration: configuration))
    await manager.bindDestination(destination)
    let id = try manager.save(configuration: configuration)
    manager.setConnected(true); manager.start(id)
    try await wait { if case .running = manager.rules[0].state { return true }; return false }
    manager.setConnected(false)
    try await wait { manager.rules[0].state == .stopped }
    let fresh = LocalForwardManager(store: LocalForwardStore(fileURL: file)) { _ in starts += 1; return PresetForward() }
    await fresh.bindDestination(destination)
    fresh.setConnected(true)
    XCTAssertEqual(fresh.rules.map(\.id), [id])
    XCTAssertEqual(fresh.rules[0].state, .stopped)
    XCTAssertEqual(starts, 1)
  }

  func test_window_refresh_preserves_running_configuration_then_applies_edits_and_deletion() async throws {
    let store = LocalForwardStore(fileURL: url()), forward = PresetForward()
    var opens = 0
    let a = LocalForwardManager(store: store) { _ in
      defer { opens += 1 }
      return opens == 0 ? forward : PresetForward()
    }
    let b = LocalForwardManager(store: store) { _ in PresetForward() }
    await a.bindDestination(destination); await b.bindDestination(destination)
    let id = try a.save(configuration: configuration)
    try await wait { b.rules.count == 1 }
    a.setConnected(true); a.start(id)
    try await wait { if case .running = a.rules[0].state { return true }; return false }
    _ = try b.save(id: id, configuration: edited)
    a.reloadSavedRules()
    XCTAssertEqual(a.rules[0].configuration, configuration)
    a.stop(id)
    try await wait { a.rules[0].configuration == edited }
    XCTAssertTrue(forward.isStopped)
    XCTAssertEqual(a.rules[0].state, .stopped)
    let second = try a.save(configuration: configuration)
    a.start(second)
    try await wait { a.rules.count == 2 && !a.rules[1].canEdit }
    try await wait { b.rules.count == 2 }
    try b.remove(second)
    a.reloadSavedRules()
    XCTAssertEqual(a.rules.count, 2, "removing a preset must not kill another window's clients")
    a.stop(second)
    try await wait { a.rules.count == 1 }
    XCTAssertEqual(a.rules[0].id, id)
  }

  func test_switching_destination_waits_for_late_start_and_latest_binding_wins() async throws {
    let store = LocalForwardStore(fileURL: url()), forward = PresetForward()
    var continuation: CheckedContinuation<any LocalForwarding, Never>?
    let manager = LocalForwardManager(store: store) { _ in
      await withCheckedContinuation { continuation = $0 }
    }
    await manager.bindDestination(destination)
    let id = try manager.save(configuration: configuration)
    manager.setConnected(true); manager.start(id)
    try await wait { continuation != nil }
    let other = LocalForwardDestination(hostname: "other", port: 22, username: "user")
    let latest = LocalForwardDestination(hostname: "latest", port: 22, username: "user")
    let preset = try store.save(destination: latest, configuration: edited)
    let switchA = Task { await manager.bindDestination(other) }
    try await wait { manager.isLoading }
    XCTAssertThrowsError(try manager.save(configuration: configuration))
    let switchB = Task { await manager.bindDestination(latest) }
    await Task.yield()
    continuation?.resume(returning: forward)
    await switchA.value; await switchB.value
    XCTAssertTrue(forward.isStopped)
    XCTAssertFalse(manager.isLoading)
    XCTAssertEqual(manager.destination, latest)
    XCTAssertEqual(manager.rules.map(\.id), [preset.id])
    XCTAssertEqual(manager.rules[0].state, .stopped)
    XCTAssertEqual(try store.rules(for: destination).map(\.id), [id])
  }

  func test_editor_keeps_stale_draft_and_refuses_overwriting_another_window() async throws {
    _ = NSApplication.shared
    let store = LocalForwardStore(fileURL: url())
    let a = LocalForwardManager(store: store) { _ in PresetForward() }
    let b = LocalForwardManager(store: store) { _ in PresetForward() }
    await a.bindDestination(destination); await b.bindDestination(destination)
    let id = try a.save(configuration: configuration)
    let controller = LocalForwardViewController(model: a)
    _ = controller.view
    controller.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    controller.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
    XCTAssertEqual(controller.editingID, id)
    controller.targetHostField.stringValue = "unsaved-draft"
    b.reloadSavedRules()
    _ = try b.save(id: id, configuration: edited)
    try await wait { a.rules[0].configuration == edited }
    XCTAssertEqual(controller.targetHostField.stringValue, "unsaved-draft")
    XCTAssertFalse(controller.saveChanges())
    XCTAssertEqual(controller.targetHostField.stringValue, "unsaved-draft")
    XCTAssertTrue(controller.statusLabel.stringValue.contains("其他窗口"))
    XCTAssertEqual(try store.rules(for: destination)[0].configuration, edited)
    let action = try XCTUnwrap(controller.table.action)
    XCTAssertTrue(controller.table.sendAction(action, to: controller.table.target))
    XCTAssertEqual(controller.targetHostField.stringValue, edited.targetHost, "clicking the selected row must recover the latest preset")
    XCTAssertTrue(controller.saveChanges())
  }

  func test_load_error_keeps_file_and_draft_and_reload_recovers_without_starting() async throws {
    _ = NSApplication.shared
    let file = url(), store = LocalForwardStore(fileURL: file)
    let preset = try store.save(destination: destination, configuration: configuration)
    let valid = try Data(contentsOf: file)
    try Data("broken".utf8).write(to: file)
    let manager = LocalForwardManager(store: store) { _ in XCTFail("restoration must never open sockets"); return PresetForward() }
    await manager.bindDestination(destination)
    let controller = LocalForwardViewController(model: manager)
    _ = controller.view
    XCTAssertTrue(controller.statusLabel.stringValue.contains("原文件未覆盖"))
    controller.localPortField.stringValue = "8081"
    controller.targetHostField.stringValue = "draft"
    controller.targetPortField.stringValue = "80"
    XCTAssertFalse(controller.saveChanges())
    XCTAssertEqual(controller.targetHostField.stringValue, "draft")
    XCTAssertEqual(try Data(contentsOf: file), Data("broken".utf8))
    try valid.write(to: file)
    manager.reloadSavedRules()
    XCTAssertNil(manager.storageError)
    XCTAssertEqual(manager.rules.map(\.id), [preset.id])
    XCTAssertEqual(manager.rules[0].state, .stopped)
  }

  func test_destination_change_clears_old_editor_and_persistent_window_fits_minimum_size() async throws {
    _ = NSApplication.shared
    let model = LocalForwardManager(store: LocalForwardStore(fileURL: url())) { _ in PresetForward() }
    await model.bindDestination(destination)
    let controller = LocalForwardViewController(model: model)
    let window = NSWindow(contentViewController: controller)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    controller.localPortField.stringValue = "8080"
    controller.targetHostField.stringValue = "old-server-draft"
    controller.targetPortField.stringValue = "80"
    await model.bindDestination(.init(hostname: "other.example", port: 2222, username: "other"))
    try await wait { controller.targetHostField.stringValue.isEmpty }
    XCTAssertNil(controller.editingID)
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    for size in [NSSize(width: 600, height: 430), NSSize(width: 900, height: 600)] {
      window.setContentSize(size)
      controller.view.layoutSubtreeIfNeeded()
      for control in descendants(controller.view).compactMap({ $0 as? NSControl }).filter({ !$0.isHiddenOrHasHiddenAncestor }) {
        let rect = control.convert(control.bounds, to: controller.view)
        XCTAssertGreaterThan(rect.width, 0)
        XCTAssertGreaterThanOrEqual(rect.minX, -0.5)
        XCTAssertLessThanOrEqual(rect.maxX, size.width + 0.5)
        XCTAssertGreaterThanOrEqual(rect.minY, -0.5)
        XCTAssertLessThanOrEqual(rect.maxY, size.height + 0.5)
      }
    }
  }
}
