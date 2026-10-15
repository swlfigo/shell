import AppKit
import XCTest
import SSHCore
import TermesKit
@testable import Termes

private final class StubForward: LocalForwarding, @unchecked Sendable {
  let localPort: Int
  let events: AsyncStream<LocalForwardEvent>
  private let continuation: AsyncStream<LocalForwardEvent>.Continuation
  private let lock = NSLock()
  private var stopped = false
  var isStopped: Bool { lock.withLock { stopped } }
  init(port: Int = 8080) {
    localPort = port
    (events, continuation) = AsyncStream.makeStream()
  }
  func emit(_ event: LocalForwardEvent) { continuation.yield(event) }
  func stop() async {
    lock.withLock { stopped = true }
    continuation.yield(.stopped(error: nil))
    continuation.finish()
  }
}

@MainActor
final class LocalForwardTests: XCTestCase {
  private let configuration = LocalForwardConfiguration(localPort: 8080, targetHost: "db.internal", targetPort: 5432)
  private func wait(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = Date().addingTimeInterval(10)
    while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(predicate(), file: file, line: line)
  }
  private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

  func test_rules_validate_ports_preserve_identity_and_only_edit_while_stopped() async throws {
    let forward = StubForward()
    let model = LocalForwardManager { _ in forward }
    XCTAssertThrowsError(try model.save(configuration: .init(localPort: 0, targetHost: "db", targetPort: 80)))
    let id = try model.save(configuration: configuration)
    let changed = LocalForwardConfiguration(localPort: 8081, targetHost: "db2", targetPort: 80)
    XCTAssertEqual(try model.save(id: id, configuration: changed), id)
    XCTAssertEqual(model.rules.count, 1)
    model.start(id)
    XCTAssertEqual(model.rules[0].state, .stopped, "a disconnected session cannot start")
    model.setConnected(true)
    model.start(id)
    XCTAssertThrowsError(try model.save(id: id, configuration: configuration))
    try model.remove(id)
    XCTAssertEqual(model.rules.count, 1)
    try await wait { if case .running = model.rules[0].state { return true }; return false }
    model.stop(id)
    try await wait { model.rules[0].state == .stopped }
    XCTAssertTrue(forward.isStopped)
    try model.remove(id)
    XCTAssertTrue(model.rules.isEmpty)
  }

  func test_stop_during_start_closes_late_result_before_allowing_restart() async throws {
    let forward = StubForward()
    var continuation: CheckedContinuation<any LocalForwarding, Never>?
    var opens = 0
    let model = LocalForwardManager { _ in
      opens += 1
      return await withCheckedContinuation { continuation = $0 }
    }
    model.setConnected(true)
    let id = try model.save(configuration: configuration)
    model.start(id)
    try await wait { continuation != nil }
    model.stop(id)
    XCTAssertEqual(model.rules[0].state, .stopping)
    model.start(id)
    XCTAssertEqual(opens, 1)
    continuation?.resume(returning: forward)
    try await wait { model.rules[0].state == .stopped }
    XCTAssertTrue(forward.isStopped)
  }

  func test_disconnect_stops_all_rules_and_reconnect_does_not_restart_them() async throws {
    let a = StubForward(port: 8080), b = StubForward(port: 8081)
    let model = LocalForwardManager { $0.localPort == 8080 ? a : b }
    model.setConnected(true)
    let ids = try [model.save(configuration: configuration),
                   model.save(configuration: .init(localPort: 8081, targetHost: "other", targetPort: 80))]
    ids.forEach(model.start)
    try await wait { model.rules.allSatisfy { if case .running = $0.state { return true }; return false } }
    a.emit(.clients(3))
    a.emit(.clientError("target refused"))
    try await wait { model.rules[0].clientError == "target refused" }
    XCTAssertEqual(model.rules[0].state, .running(port: 8080, clients: 3))
    XCTAssertNil(model.rules[1].clientError)
    model.setConnected(false)
    try await wait { model.rules.allSatisfy { $0.state == .stopped } }
    XCTAssertTrue(a.isStopped && b.isStopped)
    model.setConnected(true)
    XCTAssertTrue(model.rules.allSatisfy { $0.state == .stopped })
    XCTAssertEqual(model.rules.count, 2)
  }

  func test_transport_error_is_shown_after_cleanup_and_can_be_retried() async throws {
    let forward = StubForward()
    let model = LocalForwardManager { _ in forward }
    let id = try model.save(configuration: configuration)
    model.setConnected(true); model.start(id)
    try await wait { if case .running = model.rules[0].state { return true }; return false }
    forward.emit(.stopped(error: "transport lost"))
    try await wait { model.rules[0].state == .failed("transport lost") }
    XCTAssertTrue(forward.isStopped)
    XCTAssertTrue(model.rules[0].canEdit)
  }

  func test_failed_factory_preserves_rule_and_reports_error() async throws {
    let model = LocalForwardManager { _ in throw LocalForwardError.listen("address in use") }
    let id = try model.save(configuration: configuration)
    model.setConnected(true); model.start(id)
    try await wait { if case .failed = model.rules[0].state { return true }; return false }
    XCTAssertEqual(model.rules[0].configuration, configuration)
    if case .failed(let message) = model.rules[0].state { XCTAssertTrue(message.contains("address in use")) }
  }

  func test_releasing_manager_stops_owned_forward() async throws {
    let forward = StubForward()
    var model: LocalForwardManager? = LocalForwardManager { _ in forward }
    weak var weakModel = model
    let id = try XCTUnwrap(model).save(configuration: configuration)
    model?.setConnected(true); model?.start(id)
    try await wait { if case .running = model?.rules.first?.state { return true }; return false }
    model = nil
    try await wait { forward.isStopped }
    XCTAssertNil(weakModel)
  }

  func test_editor_preserves_invalid_draft_and_updates_existing_rule() throws {
    _ = NSApplication.shared
    let model = LocalForwardManager { _ in StubForward() }
    let controller = LocalForwardViewController(model: model)
    _ = controller.view
    controller.localPortField.stringValue = "70000"
    controller.targetHostField.stringValue = "db"
    controller.targetPortField.stringValue = "80"
    XCTAssertFalse(controller.saveChanges())
    XCTAssertEqual(controller.localPortField.stringValue, "70000")
    XCTAssertTrue(model.rules.isEmpty)
    controller.localPortField.stringValue = "8080"
    XCTAssertTrue(controller.saveChanges())
    let id = controller.editingID
    controller.targetHostField.stringValue = "edited"
    XCTAssertTrue(controller.saveChanges())
    XCTAssertEqual(model.rules.count, 1)
    XCTAssertEqual(controller.editingID, id)
    XCTAssertEqual(model.rules[0].configuration.targetHost, "edited")
  }

  func test_status_refresh_preserves_new_rule_draft_and_minimum_window_layout() async throws {
    _ = NSApplication.shared
    let forward = StubForward()
    let model = LocalForwardManager { _ in forward }
    let id = try model.save(configuration: configuration)
    let controller = LocalForwardViewController(model: model)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = controller.view
    defer { model.stopAll(); window.close() }
    controller.newRule()
    controller.targetHostField.stringValue = "unsaved-draft"
    model.setConnected(true); model.start(id)
    try await wait { if case .running = model.rules[0].state { return true }; return false }
    forward.emit(.clients(2))
    try await wait { model.rules[0].state == .running(port: 8080, clients: 2) }
    await Task.yield()
    XCTAssertNil(controller.editingID)
    XCTAssertEqual(controller.targetHostField.stringValue, "unsaved-draft")
    for size in [NSSize(width: 600, height: 430), NSSize(width: 900, height: 600)] {
      window.setContentSize(size); controller.view.layoutSubtreeIfNeeded()
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
