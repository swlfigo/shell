import XCTest
import UIKit
import SSHCore
import TermesKit
@testable import TermesMobile

@MainActor
private final class MobileMonitorTestClient: ServerMonitoringClient {
  private(set) var requests = 0
  private(set) var closes = 0
  private var pending: CheckedContinuation<LinuxServerSample, Error>?

  var isSampling: Bool { pending != nil }

  func sample() async throws -> LinuxServerSample {
    try Task.checkCancellation()
    guard pending == nil else { throw ServerMonitoringError.collectionInProgress }
    requests += 1
    return try await withCheckedThrowingContinuation { pending = $0 }
  }

  func deliver(_ sample: LinuxServerSample) {
    let continuation = pending
    pending = nil
    continuation?.resume(returning: sample)
  }

  func fail(_ error: Error) {
    let continuation = pending
    pending = nil
    continuation?.resume(throwing: error)
  }

  func close() async {
    closes += 1
    fail(SSHError.disconnected)
  }
}

@MainActor
private final class MobileMonitorTestClients {
  private(set) var clients: [MobileMonitorTestClient] = []

  func open() -> MobileMonitorTestClient {
    let client = MobileMonitorTestClient()
    clients.append(client)
    return client
  }
}

@MainActor
private final class MobileMonitorTestClock {
  var time: TimeInterval = 1_000
}

@MainActor
final class MobileServerMonitorTests: XCTestCase {
  private struct Screen {
    let controller: MobileServerMonitorController
    let model: ServerMonitorModel
    let clients: MobileMonitorTestClients
    let clock: MobileMonitorTestClock
  }

  private func screen(connected: Bool = true) -> Screen {
    let clock = MobileMonitorTestClock(), clients = MobileMonitorTestClients()
    let model = ServerMonitorModel(interval: 0.02, now: { clock.time }) { clients.open() }
    // The visible destination must contain only endpoint identity, even for an encrypted key and jump route.
    let config = ConnectionConfig(hostname: "linux.example", username: "operator",
      auth: .privateKey(data: Data("TEST_PRIVATE_KEY_DO_NOT_RENDER".utf8), passphrase: "TEST_KEY_PHRASE_DO_NOT_RENDER"),
      jumpHosts: [.init(hostname: "jump.example", port: 22, username: "jump",
        auth: .password("TEST_PASSWORD_DO_NOT_RENDER"))])
    model.setConnection(connected: connected, version: 1, destination: .init(config: config))
    let controller = MobileServerMonitorController(model: model, serverName: "生产服务器")
    controller.loadViewIfNeeded()
    return Screen(controller: controller, model: model, clients: clients, clock: clock)
  }

  private func sample(time: TimeInterval = 1_000, second: Bool = false) -> LinuxServerSample {
    .init(capturedAt: Date(timeIntervalSince1970: time), monotonicTime: time,
      identity: .init(kernelRelease: .value("6.8.0"), architecture: .value("aarch64"),
        hostname: .value("production-linux-01"), operatingSystem: .value("Ubuntu 24.04 LTS")),
      bootID: .value("mobile-monitor-boot"),
      cpu: .value(.init(second ? [150, 0, 150, 900, 0, 0, 0, 0] : [100, 0, 100, 800, 0, 0, 0, 0])),
      memory: .value(.init(totalBytes: 16 * 1_024 * 1_024 * 1_024,
        usedBytes: 4 * 1_024 * 1_024 * 1_024, availableBytes: 12 * 1_024 * 1_024 * 1_024)),
      swap: .value(.init(totalBytes: 0, usedBytes: 0, availableBytes: 0)),
      disks: .unavailable(.commandFailed),
      network: .value([.init(name: "eth0", receivedBytes: second ? 5_100 : 100,
        transmittedBytes: second ? 2_700 : 200)]),
      load: .unavailable(.missingData), uptime: .value(36_000 + time))
  }

  private func wait(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
    guard predicate() else {
      XCTFail("Mobile monitor did not reach the expected state", file: file, line: line)
      throw CancellationError()
    }
  }

  private func descendants(_ view: UIView) -> [UIView] {
    [view] + view.subviews.flatMap(descendants)
  }

  func testAppearanceStartsCollectionAndLabelsDistinguishBaselineAndMissingValues() async throws {
    let screen = screen(), controller = screen.controller
    defer { controller.shutdown() }
    XCTAssertFalse(screen.model.isOpen)
    XCTAssertTrue(screen.clients.clients.isEmpty, "loading the view must not open a monitoring connection")

    controller.viewDidAppear(false)
    try await wait { screen.clients.clients.first?.isSampling == true }
    let client = try XCTUnwrap(screen.clients.clients.first)
    client.deliver(sample())
    try await wait { controller.memoryLabel.text == "25.0%" }
    XCTAssertTrue(controller.cpuLabel.text?.contains("等待") == true)
    XCTAssertTrue(controller.networkSummaryLabel.text?.contains("等待") == true)
    XCTAssertTrue(controller.swapLabel.text?.contains("未配置") == true)
    XCTAssertTrue(controller.loadLabel.text?.contains("数据缺失") == true)
    XCTAssertTrue(controller.diskSummaryLabel.text?.contains("读取失败") == true)

    try await wait { client.requests == 2 && client.isSampling }
    screen.clock.time = 1_005
    client.deliver(sample(time: 1_005, second: true))
    try await wait { controller.cpuLabel.text == "50.0%" }
    XCTAssertEqual(screen.model.history.count, 2)
    XCTAssertEqual(try XCTUnwrap(screen.model.current?.network.value?.first?.receivedBytesPerSecond.value), 1_000, accuracy: 0.01)
    XCTAssertFalse(controller.statusLabel.text?.contains("已过期") == true)
    XCTAssertEqual(screen.clients.clients.count, 1, "sampling must keep its dedicated monitoring connection")
  }

  func testTemporaryDisappearancePreservesDataAndResumesOnlyAutomaticPause() async throws {
    let screen = screen(), controller = screen.controller
    defer { controller.shutdown() }
    controller.viewDidAppear(false)
    try await wait { screen.clients.clients.first?.isSampling == true }
    let first = try XCTUnwrap(screen.clients.clients.first)
    first.deliver(sample())
    try await wait { controller.memoryLabel.text == "25.0%" }
    let history = screen.model.history

    controller.viewWillDisappear(false)
    try await wait { first.closes > 0 }
    XCTAssertTrue(screen.model.isPaused)
    XCTAssertFalse(controller.isUserPaused)
    XCTAssertEqual(screen.model.history, history)

    controller.viewDidAppear(false)
    try await wait { screen.clients.clients.count == 2 && screen.clients.clients[1].isSampling }
    controller.togglePause()
    try await wait { screen.clients.clients[1].closes > 0 }
    XCTAssertTrue(controller.isUserPaused)
    controller.viewWillDisappear(false)
    controller.viewDidAppear(false)
    await Task.yield()
    XCTAssertEqual(screen.clients.clients.count, 2)
    XCTAssertTrue(screen.model.isPaused, "returning to the page must respect the user's pause")
    XCTAssertEqual(controller.memoryLabel.text, "25.0%")
    XCTAssertTrue(controller.statusLabel.text?.contains("已过期") == true)

    controller.togglePause()
    try await wait { screen.clients.clients.count == 3 && screen.clients.clients[2].isSampling }
    XCTAssertFalse(controller.isUserPaused)
  }

  func testBackgroundNotificationsPreserveManualPauseAndCannotResumeDismissedMonitor() async throws {
    let screen = screen(), controller = screen.controller
    defer { controller.shutdown() }
    controller.viewDidAppear(false)
    try await wait { screen.clients.clients.first?.isSampling == true }
    let first = try XCTUnwrap(screen.clients.clients.first)
    first.deliver(sample())
    try await wait { screen.model.current != nil }

    NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
    controller.suspendForBackground() // Repeated lifecycle delivery must not change the resume decision.
    try await wait { first.closes > 0 }
    XCTAssertTrue(screen.model.isPaused)
    XCTAssertFalse(controller.isUserPaused)
    XCTAssertNotNil(screen.model.current)

    NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    try await wait { screen.clients.clients.count == 2 && screen.clients.clients[1].isSampling }
    controller.togglePause()
    try await wait { screen.clients.clients[1].closes > 0 }
    controller.suspendForBackground()
    controller.resumeFromBackground()
    XCTAssertTrue(controller.isUserPaused)
    XCTAssertTrue(screen.model.isPaused)
    XCTAssertEqual(screen.clients.clients.count, 2)

    controller.shutdown()
    NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    controller.resumeFromBackground()
    controller.viewDidAppear(false)
    await Task.yield()
    XCTAssertEqual(screen.model.state, .paused)
    XCTAssertTrue(screen.model.isOpen)
    XCTAssertNotNil(screen.model.current)
    XCTAssertEqual(screen.model.history.count, 1)
    XCTAssertEqual(screen.clients.clients.count, 2, "a dismissed monitor must not reopen on foreground notification")
    screen.model.setConnection(connected: false, version: 2, destination: nil)
    screen.model.setConnection(connected: true, version: 3, destination: nil)
    await Task.yield()
    XCTAssertEqual(screen.model.state, .paused)
    XCTAssertEqual(screen.model.history.count, 1)
    XCTAssertEqual(screen.clients.clients.count, 2, "a terminal reconnect must not restart a dismissed monitor")
  }

  func testConnectionAndUnsupportedStatesAreVisibleAndRetryUsesCurrentConnection() async throws {
    let screen = screen(connected: false), controller = screen.controller
    defer { controller.shutdown() }
    controller.viewDidAppear(false)
    XCTAssertEqual(screen.model.state, .disconnected)
    XCTAssertTrue(controller.statusLabel.text?.contains("断开") == true)
    XCTAssertTrue(screen.clients.clients.isEmpty)

    screen.model.setConnection(connected: true, version: 2, destination: nil)
    try await wait { screen.clients.clients.first?.isSampling == true }
    screen.clients.clients[0].fail(ServerMonitoringError.unsupportedPlatform("Darwin"))
    try await wait { controller.statusLabel.text?.contains("Darwin") == true }
    XCTAssertFalse(controller.statusLabel.text?.contains("自动重试") == true)
    XCTAssertNil(screen.model.current)

    controller.retry()
    try await wait { screen.clients.clients.count == 2 && screen.clients.clients[1].isSampling }
    screen.clients.clients[1].deliver(sample())
    try await wait { controller.memoryLabel.text == "25.0%" }
    screen.model.setConnection(connected: false, version: 3, destination: nil)
    try await wait { controller.statusLabel.text?.contains("断开") == true }
    XCTAssertEqual(controller.memoryLabel.text, "25.0%")
    XCTAssertTrue(controller.statusLabel.text?.contains("已过期") == true)
    controller.retry()
    XCTAssertEqual(screen.clients.clients.count, 2, "retry cannot open an auxiliary connection while the terminal is disconnected")

    screen.model.setConnection(connected: true, version: 4, destination: nil)
    try await wait { screen.clients.clients.count == 3 && screen.clients.clients[2].isSampling }
    screen.clock.time = 1_010
    screen.clients.clients[2].deliver(sample(time: 1_010, second: true))
    try await wait { screen.model.current?.sample.monotonicTime == 1_010 }
    controller.render()
    XCTAssertTrue(controller.cpuLabel.text?.contains("等待") == true, "reconnect must not show a rate across the disconnected interval")
  }

  func testDismissalInterruptsCollectionAndPreservesSessionHistoryUntilSessionCloses() async throws {
    let screen = screen(), controller = screen.controller
    defer { controller.shutdown() }
    controller.viewDidAppear(false)
    try await wait { screen.clients.clients.first?.isSampling == true }
    let client = try XCTUnwrap(screen.clients.clients.first)
    client.deliver(sample())
    try await wait { client.requests == 2 && client.isSampling }
    let history = screen.model.history
    XCTAssertEqual(history.count, 1)

    controller.shutdown()
    try await wait { client.closes > 0 && !client.isSampling }
    XCTAssertEqual(screen.model.state, .paused)
    XCTAssertEqual(screen.model.current?.sample, sample())
    XCTAssertEqual(screen.model.history, history)
    controller.shutdown()
    controller.resumeFromBackground()
    await Task.yield()
    XCTAssertTrue(screen.model.isOpen)
    XCTAssertTrue(screen.model.isPaused)
    XCTAssertEqual(screen.clients.clients.count, 1)

    // The session owner, rather than a dismissed page, clears its in-memory cache.
    screen.model.close()
    XCTAssertEqual(screen.model.state, .closed)
    XCTAssertNil(screen.model.current)
    XCTAssertTrue(screen.model.history.isEmpty)
    controller.viewDidAppear(false)
    XCTAssertFalse(screen.model.isOpen)
  }

  func testRemovingContainerChildPreservesHistoryAndReleasingOldPageKeepsReopenedMonitorAlive() async throws {
    let clients = MobileMonitorTestClients(), clock = MobileMonitorTestClock()
    let model = ServerMonitorModel(interval: 0.02, now: { clock.time }) { clients.open() }
    model.setConnection(connected: true, version: 1, destination: nil)
    let container = UIViewController()
    container.loadViewIfNeeded()
    var previous: MobileServerMonitorController? = MobileServerMonitorController(model: model, serverName: "Previous")
    weak var weakPrevious = previous
    defer { previous?.shutdown() }
    container.addChild(previous!)
    container.view.addSubview(previous!.view)
    previous!.didMove(toParent: container)
    previous!.viewDidAppear(false)
    try await wait { clients.clients.first?.isSampling == true }
    clients.clients[0].deliver(sample())
    try await wait { model.current != nil }
    let history = model.history

    previous!.willMove(toParent: nil)
    previous!.view.removeFromSuperview()
    previous!.removeFromParent()
    XCTAssertEqual(model.state, .paused, "removing a contained page must pause synchronously without waiting for deinit")
    XCTAssertTrue(previous!.isShutdown)
    XCTAssertNotNil(model.current)
    XCTAssertEqual(model.history, history)

    let fresh = MobileServerMonitorController(model: model, serverName: "Reopened")
    defer {
      fresh.shutdown()
      fresh.willMove(toParent: nil)
      fresh.view.removeFromSuperview()
      fresh.removeFromParent()
    }
    container.addChild(fresh)
    container.view.addSubview(fresh.view)
    fresh.didMove(toParent: container)
    fresh.viewDidAppear(false)
    XCTAssertEqual(fresh.memoryLabel.text, "25.0%", "reopening must display the cached snapshot before a new sample arrives")
    XCTAssertEqual(model.history, history)
    XCTAssertEqual(fresh.usageChart.series.first { $0.name == "内存" }?.points.map(\.time), history.map(\.monotonicTime))
    previous!.shutdown()
    previous!.viewWillDisappear(false)
    previous!.resumeFromBackground()
    previous = nil
    try await wait { weakPrevious == nil && clients.clients.count == 2 && clients.clients[1].isSampling }
    XCTAssertTrue(model.isOpen)
    XCTAssertFalse(fresh.isShutdown)
    clock.time = 1_005
    clients.clients[1].deliver(sample(time: 1_005, second: true))
    try await wait { model.history.count == 2 }
    XCTAssertTrue(model.isOpen, "the previous page's deallocation must not close the newly opened page's model")
    XCTAssertEqual(model.history.first, history.first)
    XCTAssertNotEqual(model.history.last?.segment, history.last?.segment)
    XCTAssertEqual(model.current?.cpu, .unavailable(.waitingForBaseline))
    XCTAssertEqual(model.current?.network.value?.first?.receivedBytesPerSecond, .unavailable(.waitingForBaseline))
  }

  func testReopeningPrunesExpiredHistoryWithoutWaitingForAnotherSample() async throws {
    let screen = screen(), controller = screen.controller
    defer { screen.model.close() }
    controller.viewDidAppear(false)
    try await wait { screen.clients.clients.first?.isSampling == true }
    screen.clients.clients[0].deliver(sample())
    try await wait { screen.model.history.count == 1 }
    controller.shutdown()
    try await wait { screen.clients.clients[0].closes > 0 }

    screen.clock.time += ServerMonitorModel.historyDuration + 1
    let reopened = MobileServerMonitorController(model: screen.model, serverName: "Reopened")
    defer { reopened.shutdown() }
    reopened.loadViewIfNeeded()
    reopened.viewDidAppear(false)
    XCTAssertTrue(screen.model.history.isEmpty, "a page left closed for 15 minutes must not retain expired chart points")
    XCTAssertEqual(reopened.memoryLabel.text, "25.0%", "the last snapshot remains available while the new sample is pending")
    XCTAssertTrue(reopened.statusLabel.text?.contains("已过期") == true)
    try await wait { screen.clients.clients.count == 2 && screen.clients.clients[1].isSampling }
  }

  func testNarrowWideAndLandscapeLayoutsScrollWithoutExposingCredentials() async throws {
    let screen = screen(), controller = screen.controller
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    window.rootViewController = controller
    window.makeKeyAndVisible()
    controller.viewDidAppear(false)
    defer {
      controller.shutdown()
      window.isHidden = true
      window.rootViewController = nil
    }
    try await wait { screen.clients.clients.first?.isSampling == true }
    screen.clients.clients[0].deliver(sample())
    try await wait { controller.memoryLabel.text == "25.0%" }
    controller.togglePause()
    let history = screen.model.history

    for size in [CGSize(width: 320, height: 568), CGSize(width: 1_024, height: 768),
                 CGSize(width: 844, height: 390), CGSize(width: 240, height: 320)] {
      window.frame = CGRect(origin: .zero, size: size)
      controller.view.frame = window.bounds
      controller.view.setNeedsLayout()
      controller.view.layoutIfNeeded()
      let scroll = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UIScrollView }.first)
      XCTAssertGreaterThan(scroll.bounds.width, 0)
      XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height, "the complete dashboard must remain reachable by scrolling at \(size)")
      XCTAssertGreaterThanOrEqual(scroll.contentSize.width + 1, scroll.bounds.width)
      XCTAssertGreaterThan(controller.usageChart.bounds.width, 0)
      XCTAssertGreaterThan(controller.networkChart.bounds.height, 0)
      for label in descendants(scroll).compactMap({ $0 as? UILabel }) where !label.isHidden && !label.bounds.isEmpty {
        let frame = label.convert(label.bounds, to: scroll)
        XCTAssertGreaterThanOrEqual(frame.minX, -1, "label leaves the scrollable document: \(label.text ?? "")")
        XCTAssertLessThanOrEqual(frame.maxX, scroll.contentSize.width + 1, "label is clipped at \(size): \(label.text ?? "")")
        XCTAssertLessThanOrEqual(frame.maxY, scroll.contentSize.height + 1)
      }
      let text = descendants(controller.view).compactMap { ($0 as? UILabel)?.text }.joined(separator: "\n")
      for credential in ["TEST_PASSWORD_DO_NOT_RENDER", "TEST_PRIVATE_KEY_DO_NOT_RENDER", "TEST_KEY_PHRASE_DO_NOT_RENDER"] {
        XCTAssertFalse(text.contains(credential))
      }
      XCTAssertEqual(controller.memoryLabel.text, "25.0%")
      XCTAssertEqual(screen.model.history, history)
      XCTAssertTrue(controller.isUserPaused)
    }
  }
}
