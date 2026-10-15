import Foundation
import XCTest
import SSHCore
import TermesKit

@MainActor
private final class ControlledMonitorClient: ServerMonitoringClient {
  var requests = 0, closes = 0
  var interruptOnClose = true
  private var pending: CheckedContinuation<LinuxServerSample, Error>?
  func sample() async throws -> LinuxServerSample {
    requests += 1
    guard pending == nil else { throw ServerMonitoringError.collectionInProgress }
    return try await withCheckedThrowingContinuation { pending = $0 }
  }
  func complete(_ sample: LinuxServerSample) { let value = pending; pending = nil; value?.resume(returning: sample) }
  func fail(_ error: Error) { let value = pending; pending = nil; value?.resume(throwing: error) }
  func close() async { closes += 1; if interruptOnClose { fail(SSHError.disconnected) } }
}

@MainActor
private final class MonitorSleepGate {
  var intervals: [TimeInterval] = []
  var isWaiting: Bool { pending != nil }
  private var pending: CheckedContinuation<Void, Error>?
  func sleep(_ interval: TimeInterval) async throws {
    try Task.checkCancellation()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { pending = $0; intervals.append(interval) }
    } onCancel: {
      Task { @MainActor [weak self] in self?.finish(CancellationError()) }
    }
  }
  func advance() { finish(nil) }
  private func finish(_ error: Error?) {
    let value = pending; pending = nil
    if let error { value?.resume(throwing: error) } else { value?.resume() }
  }
}

@MainActor
private final class MonitorClock { var time: TimeInterval = 0 }

@MainActor
final class ServerMonitorTests: XCTestCase {
  private func wait(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(2)) }
    guard predicate() else { XCTFail("monitor timed out", file: file, line: line); throw CancellationError() }
  }
  private func destination(_ host: String = "one") -> LocalForwardDestination {
    .init(config: .init(hostname: host, username: "user", auth: .password("secret")))
  }
  private func sample(_ time: Double, boot: String = "boot", uptime: Double? = nil) -> LinuxServerSample {
    let counter = UInt64(time * 100)
    return .init(capturedAt: Date(timeIntervalSince1970: time), monotonicTime: time,
      identity: .init(kernelRelease: .value("6.1"), architecture: .value("arm64"), hostname: .value("linux"), operatingSystem: .value("Linux")),
      bootID: .value(boot), cpu: .value(.init([counter, 0, counter, counter * 2, 0, 0, 0, 0])),
      memory: .value(.init(totalBytes: 100, usedBytes: 25, availableBytes: 75)),
      swap: .value(.init(totalBytes: 0, usedBytes: 0, availableBytes: 0)), disks: .value([]),
      network: .value([.init(name: "eth0", receivedBytes: counter * 10, transmittedBytes: counter * 20)]),
      load: .value(.init(oneMinute: 0.4, fiveMinutes: 0.3, fifteenMinutes: 0.2)), uptime: .value(uptime ?? time))
  }

  func test_sampling_starts_only_when_open_and_connected_and_waits_after_completion() async throws {
    let client = ControlledMonitorClient(), gate = MonitorSleepGate(), clock = MonitorClock()
    var opens = 0
    let model = ServerMonitorModel(now: { clock.time }, sleep: { try await gate.sleep($0) }) { opens += 1; return client }
    defer { model.close() }
    model.open()
    XCTAssertEqual(model.state, .disconnected); XCTAssertEqual(opens, 0)
    model.setConnection(connected: true, version: 1, destination: destination())
    try await wait { client.requests == 1 }
    XCTAssertEqual(model.state, .sampling); XCTAssertFalse(gate.isWaiting)
    // A slow query remains the only query until it completes, even after several intervals.
    clock.time = 20
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertEqual(client.requests, 1); XCTAssertEqual(opens, 1)
    client.complete(sample(20))
    try await wait { gate.isWaiting }
    XCTAssertEqual(gate.intervals, [5]); XCTAssertEqual(model.state, .live)
    XCTAssertEqual(model.current?.cpu, .unavailable(.waitingForBaseline))
    XCTAssertEqual(model.history.first?.memoryPercent, 25)
    clock.time = 27; gate.advance()
    try await wait { client.requests == 2 }
    client.complete(sample(27))
    try await wait { model.history.count == 2 && gate.isWaiting }
    XCTAssertEqual(try XCTUnwrap(model.current?.cpu.value).totalPercent, 50, accuracy: 0.001)
    XCTAssertEqual(model.current?.network.value?.first?.receivedBytesPerSecond.value, 1000)
    XCTAssertFalse(model.isStale); XCTAssertEqual(opens, 1)
  }

  func test_pause_cleans_up_and_resume_waits_for_late_query_without_accepting_it() async throws {
    let old = ControlledMonitorClient(), fresh = ControlledMonitorClient(), clock = MonitorClock()
    old.interruptOnClose = false
    var opens = 0
    let model = ServerMonitorModel(now: { clock.time }) { opens += 1; return opens == 1 ? old : fresh }
    defer { model.close() }
    model.setConnection(connected: true, version: 1, destination: destination()); model.open()
    try await wait { old.requests == 1 }
    model.pause(); model.resume()
    try await wait { old.closes > 0 }
    XCTAssertEqual(opens, 1, "a replacement must wait for cleanup")
    old.complete(sample(1))
    try await wait { fresh.requests == 1 }
    XCTAssertNil(model.current); XCTAssertTrue(model.history.isEmpty)
    clock.time = 2; fresh.complete(sample(2))
    try await wait { model.current != nil }
    XCTAssertEqual(model.current?.cpu, .unavailable(.waitingForBaseline))
    model.pause()
    try await wait { fresh.closes > 0 }
    XCTAssertEqual(model.state, .paused); XCTAssertTrue(model.isStale)
    model.close()
    XCTAssertNil(model.current); XCTAssertTrue(model.history.isEmpty); XCTAssertEqual(model.state, .closed)
  }

  func test_close_and_reopen_releases_late_factory_before_opening_another_client() async throws {
    let old = ControlledMonitorClient(), fresh = ControlledMonitorClient()
    var pending: CheckedContinuation<any ServerMonitoringClient, Never>?, opens = 0
    let model = ServerMonitorModel {
      opens += 1
      if opens == 1 { return await withCheckedContinuation { pending = $0 } }
      return fresh
    }
    defer { model.close() }
    model.setConnection(connected: true, version: 1, destination: destination()); model.open()
    try await wait { pending != nil }
    model.close(); model.open()
    XCTAssertEqual(opens, 1)
    pending?.resume(returning: old); pending = nil
    try await wait { fresh.requests == 1 }
    XCTAssertGreaterThan(old.closes, 0); XCTAssertEqual(old.requests, 0)
    XCTAssertNil(model.current)
  }

  func test_disconnect_preserves_stale_history_reconnect_resets_baseline_and_target_change_clears_data() async throws {
    let clients = [ControlledMonitorClient(), ControlledMonitorClient(), ControlledMonitorClient()]
    let gate = MonitorSleepGate(), clock = MonitorClock()
    var opens = 0
    let model = ServerMonitorModel(now: { clock.time }, sleep: { try await gate.sleep($0) }) { defer { opens += 1 }; return clients[opens] }
    defer { model.close() }
    model.setConnection(connected: true, version: 1, destination: destination()); model.open()
    try await wait { clients[0].requests == 1 }
    clients[0].complete(sample(0)); try await wait { gate.isWaiting }
    clock.time = 5; gate.advance(); try await wait { clients[0].requests == 2 }
    clients[0].complete(sample(5)); try await wait { model.history.count == 2 && gate.isWaiting }
    let firstSegment = try XCTUnwrap(model.history.last?.segment)
    model.setConnection(connected: false, version: 2, destination: nil)
    XCTAssertEqual(model.state, .disconnected); XCTAssertTrue(model.isStale)
    XCTAssertEqual(model.current?.sample.monotonicTime, 5); XCTAssertEqual(model.history.count, 2)
    model.setConnection(connected: true, version: 3, destination: destination())
    try await wait { clients[1].requests == 1 }
    clock.time = 15; clients[1].complete(sample(15))
    try await wait { model.history.count == 3 && gate.isWaiting }
    XCTAssertEqual(model.current?.cpu, .unavailable(.waitingForBaseline))
    XCTAssertEqual(model.current?.network.value?.first?.receivedBytesPerSecond, .unavailable(.waitingForBaseline))
    XCTAssertNotEqual(model.history.last?.segment, firstSegment)
    model.setConnection(connected: true, version: 4, destination: destination("other"))
    XCTAssertNil(model.current); XCTAssertTrue(model.history.isEmpty)
    try await wait { clients[2].requests == 1 }
    XCTAssertGreaterThan(clients[0].closes, 0); XCTAssertGreaterThan(clients[1].closes, 0)
  }

  func test_transient_failure_keeps_stale_data_then_reopens_and_starts_new_history_segment() async throws {
    let old = ControlledMonitorClient(), fresh = ControlledMonitorClient(), gate = MonitorSleepGate(), clock = MonitorClock()
    var opens = 0
    let model = ServerMonitorModel(now: { clock.time }, sleep: { try await gate.sleep($0) }) { opens += 1; return opens == 1 ? old : fresh }
    defer { model.close() }
    model.setConnection(connected: true, version: 1, destination: destination()); model.open()
    try await wait { old.requests == 1 }
    old.complete(sample(0)); try await wait { gate.isWaiting }
    let segment = model.history.first?.segment
    gate.advance(); try await wait { old.requests == 2 }
    old.fail(SSHCommandError.timedOut)
    try await wait { gate.isWaiting && old.closes > 0 }
    guard case .failed = model.state else { return XCTFail("expected a transient failure") }
    XCTAssertTrue(model.isStale); XCTAssertEqual(model.history.count, 1)
    gate.advance(); try await wait { fresh.requests == 1 }
    clock.time = 10; fresh.complete(sample(10))
    try await wait { model.history.count == 2 }
    XCTAssertEqual(model.current?.cpu, .unavailable(.waitingForBaseline))
    XCTAssertNotEqual(model.history.last?.segment, segment); XCTAssertFalse(model.isStale)
  }

  func test_permanent_errors_stop_automatic_retry_and_allow_explicit_retry() async throws {
    let errors: [Error] = [ServerMonitoringError.unsupportedPlatform("Darwin"), SSHError.authenticationFailed,
      SSHError.hostKeyRejected, SSHError.hostKeyMismatch(stored: "old", got: "new")]
    for error in errors {
      let client = ControlledMonitorClient(), gate = MonitorSleepGate()
      var opens = 0
      let model = ServerMonitorModel(sleep: { try await gate.sleep($0) }) { opens += 1; return client }
      model.setConnection(connected: true, version: 1, destination: destination()); model.open()
      try await wait { client.requests == 1 }
      client.fail(error)
      try await wait { client.closes > 0 }
      guard case .unavailable = model.state else { model.close(); return XCTFail("permanent error must stop") }
      XCTAssertFalse(gate.isWaiting); XCTAssertEqual(opens, 1)
      model.retry(); try await wait { client.requests == 2 }
      XCTAssertEqual(opens, 2)
      model.close(); try await wait { client.closes >= 2 }
    }
  }

  func test_history_is_bounded_by_count_and_time_and_windows_use_monotonic_clock() async throws {
    let client = ControlledMonitorClient(), gate = MonitorSleepGate(), clock = MonitorClock()
    let model = ServerMonitorModel(now: { clock.time }, sleep: { try await gate.sleep($0) }) { client }
    defer { model.close() }
    model.setConnection(connected: true, version: 1, destination: destination()); model.open()
    for index in 0..<190 {
      try await wait { client.requests == index + 1 }
      clock.time = Double(index); client.complete(sample(clock.time))
      try await wait { gate.isWaiting }
      if index < 189 { gate.advance() }
    }
    XCTAssertEqual(model.history.count, ServerMonitorModel.maximumHistoryCount)
    XCTAssertEqual(model.points(minutes: 1).count, 61)
    XCTAssertEqual(model.points(minutes: 5).count, 181)
    XCTAssertEqual(model.points(minutes: 15).count, 181)
    clock.time = 203; XCTAssertTrue(model.isStale)
    model.pause(); clock.time = 1000; model.refreshTime()
    XCTAssertEqual(model.history.count, 90)
    clock.time = 2000; model.refreshTime(); XCTAssertTrue(model.history.isEmpty)
    XCTAssertNotNil(model.current, "aging history must not replace the last snapshot with zeros")
  }

  func test_reboot_breaks_history_and_does_not_calculate_rates_across_boots() async throws {
    let client = ControlledMonitorClient(), gate = MonitorSleepGate(), clock = MonitorClock()
    let model = ServerMonitorModel(now: { clock.time }, sleep: { try await gate.sleep($0) }) { client }
    defer { model.close() }
    model.setConnection(connected: true, version: 1, destination: destination()); model.open()
    for index in 0..<3 {
      try await wait { client.requests == index + 1 }
      clock.time = Double(index * 5)
      client.complete(sample(clock.time, boot: index == 2 ? "reboot" : "boot", uptime: index == 2 ? 1 : nil))
      try await wait { gate.isWaiting }
      if index < 2 { gate.advance() }
    }
    XCTAssertNotNil(model.history[1].cpuPercent); XCTAssertNil(model.history[2].cpuPercent)
    XCTAssertNotEqual(model.history[1].segment, model.history[2].segment)
    XCTAssertEqual(model.current?.cpu, .unavailable(.counterReset))
  }

  func test_releasing_model_interrupts_pending_collection_and_closes_client() async throws {
    let client = ControlledMonitorClient()
    var model: ServerMonitorModel? = ServerMonitorModel { client }
    weak let weakModel = model
    model?.setConnection(connected: true, version: 1, destination: destination()); model?.open()
    try await wait { client.requests == 1 }
    model = nil
    try await wait { client.closes > 0 }
    XCTAssertNil(weakModel)
  }
}
