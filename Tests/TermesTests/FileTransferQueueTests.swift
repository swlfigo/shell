import AppKit
import XCTest
import TermesKit
import SSHCore
@testable import Termes

private actor QueueLedger {
  var blocked: Set<String> = []
  var failOnce: Set<String> = []
  var starts: [(UUID, String, UInt64)] = []
  var partial: [UUID: UInt64] = [:]
  var discarded: [UUID] = []
  var destinations: [String] = []
  var active = 0
  var maximum = 0
  var closes = 0
  func configure(blocked: Set<String> = [], failures: Set<String> = []) { self.blocked = blocked; failOnce = failures }
  func release(_ name: String) { blocked.remove(name) }
  func start(_ transfer: SFTPFileTransfer) -> UInt64 {
    active += 1; maximum = max(active, maximum)
    let offset = partial[transfer.id] ?? 0
    starts.append((transfer.id, transfer.localURL.lastPathComponent, offset)); return offset
  }
  func retain(_ id: UUID, offset: UInt64) { partial[id] = offset }
  func isBlocked(_ name: String) -> Bool { blocked.contains(name) }
  func shouldFail(_ name: String) -> Bool { failOnce.remove(name) != nil }
  func end(_ transfer: SFTPFileTransfer, success: Bool) {
    active -= 1
    if success { partial.removeValue(forKey: transfer.id); destinations.append(transfer.remotePath) }
  }
  func discard(_ transfer: SFTPFileTransfer) { discarded.append(transfer.id); partial.removeValue(forKey: transfer.id) }
  func close() { closes += 1 }
  func entries(_ path: String) -> [SFTPEntry] {
    destinations.filter { RemotePath.parent($0) == path }.map { .init(path: $0, name: RemotePath.name($0), kind: .file) }
  }
}

private actor QueueFileSystem: SFTPResumableFileSystem {
  let ledger: QueueLedger
  init(_ ledger: QueueLedger) { self.ledger = ledger }
  func canonicalPath(_ path: String) async throws -> String { path == "." ? "/remote" : path }
  func listDirectory(_ path: String) async throws -> [SFTPEntry] { await ledger.entries(path) }
  func createDirectory(_ path: String) async throws {}
  func rename(_ source: String, to destination: String) async throws {}
  func remove(_ entry: SFTPEntry) async throws {}
  func upload(_ localURL: URL, to remotePath: String, overwrite: Bool, progress: @escaping SFTPProgressHandler) async throws {}
  func download(_ remotePath: String, to localURL: URL, overwrite: Bool, progress: @escaping SFTPProgressHandler) async throws {}
  func transfer(_ transfer: SFTPFileTransfer, progress: @escaping SFTPProgressHandler) async throws {
    let name = transfer.localURL.lastPathComponent
    let offset = await ledger.start(transfer)
    do {
      progress(.init(completed: offset, total: 131_072))
      await ledger.retain(transfer.id, offset: 65_536)
      progress(.init(completed: 65_536, total: 131_072))
      while await ledger.isBlocked(name) { try await Task.sleep(for: .milliseconds(5)) }
      try Task.checkCancellation()
      if await ledger.shouldFail(name) { throw SFTPError.operation("injected", code: 4) }
      progress(.init(completed: 131_072, total: 131_072))
      await ledger.end(transfer, success: true)
    } catch { await ledger.end(transfer, success: false); throw error }
  }
  func discard(_ transfer: SFTPFileTransfer) async throws { try Task.checkCancellation(); await ledger.discard(transfer) }
  func close() async { await ledger.close() }
}

@MainActor
final class FileTransferQueueTests: XCTestCase {
  private func files() throws -> [URL] {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return try ["a", "b", "c"].map { name in
      let url = root.appendingPathComponent(name); try Data(repeating: 7, count: 131_072).write(to: url); return url
    }
  }
  private func wait(_ predicate: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(10)
    while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(predicate())
  }
  private func waitStarted(_ ledger: QueueLedger, count: Int) async throws {
    let deadline = Date().addingTimeInterval(10)
    while await ledger.starts.count < count, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    let actual = await ledger.starts.count; XCTAssertGreaterThanOrEqual(actual, count)
  }

  func test_parallel_limit_paused_job_releases_slot_and_resumes_same_checkpoint() async throws {
    let files = try files(), ledger = QueueLedger()
    await ledger.configure(blocked: ["a", "b", "c"])
    let queue = FileTransferQueue { QueueFileSystem(ledger) }
    defer { queue.shutdown() }
    let first = try XCTUnwrap(queue.upload([files[0]], directory: "/remote"))
    let second = try XCTUnwrap(queue.upload([files[1]], directory: "/remote"))
    let third = try XCTUnwrap(queue.upload([files[2]], directory: "/remote"))
    try await waitStarted(ledger, count: 2)
    XCTAssertEqual(queue.jobs.first { $0.id == third }?.state, .queued)
    queue.pause(first)
    try await wait { queue.jobs.first { $0.id == first }?.state == .paused }
    try await waitStarted(ledger, count: 3)
    await ledger.release("b"); await ledger.release("c")
    try await wait { queue.jobs.first { $0.id == second }?.state == .completed && queue.jobs.first { $0.id == third }?.state == .completed }
    await ledger.release("a"); queue.resume(first)
    try await wait { queue.jobs.allSatisfy { $0.state == .completed } }
    let starts = await ledger.starts, maximum = await ledger.maximum
    XCTAssertEqual(starts.filter { $0.1 == "a" }.count, 2)
    let attempts = starts.filter { $0.1 == "a" }
    XCTAssertEqual(attempts.first?.0, attempts.last?.0)
    XCTAssertEqual(attempts.last?.2, 65_536)
    XCTAssertEqual(maximum, 2)
    queue.clearFinished(); XCTAssertTrue(queue.jobs.isEmpty)
  }

  func test_failure_stops_its_batch_other_batches_continue_and_retry_keeps_completed_items() async throws {
    let files = try files(), ledger = QueueLedger()
    await ledger.configure(failures: ["b"])
    let queue = FileTransferQueue { QueueFileSystem(ledger) }
    defer { queue.shutdown() }
    let failing = try XCTUnwrap(queue.upload(Array(files.prefix(2)), directory: "/remote"))
    _ = queue.upload([files[2]], directory: "/elsewhere")
    try await wait { !queue.isBusy }
    XCTAssertEqual(queue.jobs.first?.state, .failed)
    XCTAssertEqual(queue.jobs.first?.completedItems, 1)
    XCTAssertEqual(queue.jobs.last?.state, .completed)
    queue.resume(failing); try await wait { !queue.isBusy }
    XCTAssertTrue(queue.jobs.allSatisfy { $0.state == .completed })
    let starts = await ledger.starts
    XCTAssertEqual(starts.filter { $0.1 == "a" }.count, 1)
    XCTAssertEqual(starts.filter { $0.1 == "b" }.count, 2)
    XCTAssertEqual(starts.filter { $0.1 == "b" }.last?.2, 65_536)
  }

  func test_cancel_running_and_paused_jobs_discards_using_uncancelled_connection_and_duplicate_targets_reject() async throws {
    let files = try files(), ledger = QueueLedger()
    await ledger.configure(blocked: ["a", "b"])
    let queue = FileTransferQueue { QueueFileSystem(ledger) }
    let first = try XCTUnwrap(queue.upload([files[0]], directory: "/remote"))
    try await waitStarted(ledger, count: 1)
    _ = queue.upload([files[0]], directory: "/remote")
    XCTAssertEqual(queue.jobs.last?.state, .cancelled)
    XCTAssertNotNil(queue.jobs.last?.error)
    let second = try XCTUnwrap(queue.upload([files[1]], directory: "/remote"))
    try await waitStarted(ledger, count: 2)
    queue.pause(second); try await wait { queue.jobs.first { $0.id == second }?.state == .paused }
    queue.cancel(first); queue.cancel(second)
    try await wait { !queue.isBusy }
    XCTAssertTrue(queue.jobs.allSatisfy { $0.state == .cancelled && ($0.error == nil || $0.id == queue.jobs[1].id) })
    let discarded = await ledger.discarded, retained = await ledger.partial
    XCTAssertEqual(discarded.count, 2); XCTAssertTrue(retained.isEmpty)
    queue.shutdown()
  }

  func test_disconnect_pauses_without_auto_resuming_and_browser_navigation_does_not_change_captured_destination() async throws {
    let files = try files(), ledger = QueueLedger()
    await ledger.configure(blocked: ["a"])
    let model = FileBrowserModel { QueueFileSystem(ledger) }
    defer { model.shutdown() }
    model.navigate("/original"); try await wait { !model.isBusy }
    model.upload(files[0]); try await waitStarted(ledger, count: 1)
    model.navigate("/other"); try await wait { !model.isBrowsingBusy }
    XCTAssertEqual(model.directory, "/other")
    model.setConnected(false)
    try await wait { model.transfers.jobs.first?.state == .paused }
    XCTAssertFalse(model.isConnected)
    await ledger.release("a")
    model.setConnected(true); try await wait { !model.isBrowsingBusy }
    XCTAssertEqual(model.transfers.jobs.first?.state, .paused)
    model.transfers.resume(try XCTUnwrap(model.transfers.jobs.first?.id))
    try await wait { !model.isBusy }
    let destinations = await ledger.destinations
    XCTAssertEqual(destinations, ["/original/a"])
  }

  func test_appkit_queue_controls_pause_continue_and_cancel_selected_job() async throws {
    _ = NSApplication.shared
    let files = try files(), ledger = QueueLedger()
    await ledger.configure(blocked: ["a"])
    let queue = FileTransferQueue { QueueFileSystem(ledger) }
    defer { queue.shutdown() }
    let controller = FileTransferQueueViewController(queue: queue)
    _ = controller.view
    let id = try XCTUnwrap(queue.upload([files[0]], directory: "/remote"))
    try await waitStarted(ledger, count: 1)
    try await wait { controller.table.numberOfRows == 1 }
    controller.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    let buttons = controller.view.subviews.compactMap { $0 as? NSButton }
    let pause = try XCTUnwrap(buttons.first { $0.title == "暂停" })
    let resume = try XCTUnwrap(buttons.first { $0.title == "继续 / 重试" })
    let cancel = try XCTUnwrap(buttons.first { $0.title == "取消任务" })
    XCTAssertTrue(pause.isEnabled); pause.performClick(nil)
    try await wait { queue.jobs.first?.state == .paused && resume.isEnabled }
    resume.performClick(nil); try await waitStarted(ledger, count: 2)
    try await wait { cancel.isEnabled }
    cancel.performClick(nil); try await wait { queue.jobs.first?.state == .cancelled }
    XCTAssertEqual(queue.jobs.first?.id, id)
  }

  func test_real_paused_upload_is_cleaned_after_terminal_disconnect_and_panel_shutdown() async throws {
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    let files = try files(), source = files[0]
    try Data(repeating: 0xA5, count: 32 * 1024 * 1024).write(to: source)
    let store = KnownHostsStore(fileURL: source.deletingLastPathComponent().appendingPathComponent("hosts"))
    let config = ConnectionConfig(hostname: server.host, port: server.port, username: server.username, auth: .password(server.password))
    let session = SessionManager(knownHosts: store)
    let connecting = Task { await session.connect(config) }
    let deadline = Date().addingTimeInterval(30)
    while session.state != .connected, Date() < deadline {
      if case .needsHostKeyConfirm = session.state { session.confirmHostKey(true) }
      try await Task.sleep(for: .milliseconds(10))
    }
    await connecting.value; XCTAssertEqual(session.state, .connected)
    let inspector = try await SFTPClient.connect(config: config, knownHosts: store, confirmUnknownHostKey: { _, _, _ in false })
    addTeardownBlock { await inspector.close() }
    let model = FileBrowserModel { try await session.openSFTP() }
    defer { session.disconnect(); model.shutdown() }
    model.refresh(); try await wait { !model.isBusy }
    let originalChange = model.transfers.onChange
    var didPause = false
    model.transfers.onChange = {
      originalChange?()
      if !didPause, let job = model.transfers.jobs.first, job.state == .running, job.progress != nil {
        didPause = true; model.transfers.pause(job.id)
      }
    }
    model.upload(source)
    try await wait { model.transfers.jobs.first?.state == .paused }
    let directory = try XCTUnwrap(model.directory)
    let before = try await inspector.listDirectory(directory)
    XCTAssertTrue(before.contains { $0.name.hasPrefix(".termes-upload-") })
    XCTAssertFalse(before.contains { $0.name == source.lastPathComponent })
    session.disconnect(); model.shutdown()
    XCTAssertNil(session.currentConfig)
    try await wait { model.transfers.jobs.first?.state == .cancelled }
    XCTAssertNil(model.transfers.jobs.first?.error)
    let after = try await inspector.listDirectory(directory)
    XCTAssertFalse(after.contains { $0.name.hasPrefix(".termes-upload-") })
    XCTAssertFalse(after.contains { $0.name == source.lastPathComponent })
  }
}
