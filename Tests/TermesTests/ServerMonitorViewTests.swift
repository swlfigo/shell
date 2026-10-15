import AppKit
import XCTest
import SSHCore
import TermesKit
@testable import Termes

@MainActor
private final class MonitorViewClient: ServerMonitoringClient {
  var requests = 0, closes = 0
  private var pending: CheckedContinuation<LinuxServerSample, Error>?
  func sample() async throws -> LinuxServerSample {
    requests += 1
    return try await withCheckedThrowingContinuation { pending = $0 }
  }
  func deliver(_ sample: LinuxServerSample? = nil) {
    let sample = sample ?? LinuxServerSample(capturedAt: Date(), monotonicTime: Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000,
      identity: .init(kernelRelease: .value("6.1"), architecture: .value("arm64"), hostname: .value("test-linux"), operatingSystem: .value("Test Linux")),
      bootID: .value("boot"), cpu: .value(.init([100, 0, 100, 800, 0, 0, 0, 0])),
      memory: .value(.init(totalBytes: 1024, usedBytes: 256, availableBytes: 768)),
      swap: .value(.init(totalBytes: 0, usedBytes: 0, availableBytes: 0)), disks: .unavailable(.commandFailed),
      network: .value([.init(name: "eth0", receivedBytes: 100, transmittedBytes: 200)]), load: .unavailable(.missingData), uptime: .value(3600))
    let old = pending; pending = nil; old?.resume(returning: sample)
  }
  func close() async { closes += 1; let old = pending; pending = nil; old?.resume(throwing: SSHError.disconnected) }
}

@MainActor
final class ServerMonitorViewTests: XCTestCase {
  private func wait(_ predicate: () -> Bool, timeout: TimeInterval = 15,
                    file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    guard predicate() else { XCTFail("timed out", file: file, line: line); throw CancellationError() }
  }
  private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

  func test_panel_displays_baseline_missing_metrics_pause_and_scrolls_in_minimum_panes() async throws {
    _ = NSApplication.shared
    let client = MonitorViewClient(), model = ServerMonitorModel { client }
    model.setConnection(connected: true, version: 1, destination: .init(config: .init(hostname: "linux", username: "user", auth: .password("secret"))))
    let controller = ServerMonitorViewController(model: model, serverName: "自定义服务器名称")
    let terminal = NSView(), container = TerminalMonitorView(workspace: terminal, monitor: controller.view)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 700),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = container
    defer { controller.shutdown(); window.close() }
    controller.start(); try await wait { client.requests == 1 }
    client.deliver(); try await wait { controller.memoryLabel.stringValue.contains("25.0%") }
    XCTAssertTrue(controller.cpuLabel.stringValue.contains("等待下一次采样"))
    XCTAssertTrue(controller.swapLabel.stringValue.contains("未配置"))
    XCTAssertTrue(controller.loadLabel.stringValue.contains("数据缺失"))
    XCTAssertTrue(controller.diskSummaryLabel.stringValue.contains("读取失败"))
    XCTAssertTrue(controller.metricCards[3].detailLabel.stringValue.contains("eth0"))
    XCTAssertTrue(controller.networkSummaryLabel.stringValue.contains("等待下一次采样"))
    XCTAssertEqual(controller.metricCards.count, 6)
    XCTAssertTrue(controller.metricCards[0].usageBar.isHidden)
    XCTAssertEqual(controller.metricCards[1].usageBar.usage, 25)
    XCTAssertTrue(controller.metricCards[2].usageBar.isHidden)
    XCTAssertTrue(controller.metricCards[4].usageBar.isHidden, "unconfigured swap is not a measured zero")
    XCTAssertEqual(controller.interfacePopup.itemTitles, ["eth0"])
    XCTAssertTrue(descendants(controller.view).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "读取失败" })
    XCTAssertFalse(descendants(controller.view).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("secret") })
    for size in [NSSize(width: 1400, height: 700), .init(width: 900, height: 500), .init(width: 480, height: 320), .init(width: 240, height: 140)] {
      window.setContentSize(size); container.needsLayout = true; container.layoutSubtreeIfNeeded()
      XCTAssertGreaterThan(terminal.frame.width, 0); XCTAssertGreaterThan(terminal.frame.height, 0)
      XCTAssertTrue(container.bounds.contains(terminal.frame)); XCTAssertTrue(container.bounds.contains(controller.view.frame))
      let scroll = try XCTUnwrap(controller.view.subviews.first as? NSScrollView), document = try XCTUnwrap(scroll.documentView)
      XCTAssertGreaterThanOrEqual(document.frame.width, 300); XCTAssertGreaterThan(document.frame.height, 900)
      XCTAssertTrue(scroll.hasHorizontalScroller && scroll.hasVerticalScroller)
      for control in descendants(document).compactMap({ $0 as? NSControl }) {
        XCTAssertTrue(document.bounds.contains(control.convert(control.bounds, to: document)), "\(control)")
      }
      XCTAssertGreaterThan(controller.usageChart.frame.width, 0); XCTAssertGreaterThan(controller.networkChart.frame.height, 0)
    }
    controller.togglePause(); try await wait { client.closes > 0 }
    XCTAssertTrue(controller.statusLabel.stringValue.contains("已暂停"))
    XCTAssertTrue(controller.statusLabel.stringValue.contains("已过期"))
    XCTAssertTrue(controller.memoryLabel.stringValue.contains("25.0%"))
    controller.togglePause(); try await wait { client.requests == 2 }
    controller.rangeControl.selectedSegment = 2; controller.rangeChanged()
    XCTAssertEqual(model.points(minutes: 15).count, 1)
  }

  func test_cards_preserve_metric_meanings_interface_selection_and_data_across_layout_and_theme_changes() async throws {
    _ = NSApplication.shared
    let client = MonitorViewClient(), model = ServerMonitorModel(interval: 0.01) { client }
    model.setConnection(connected: true, version: 1, destination: .init(config: .init(hostname: "linux", username: "user", auth: .password("secret"))))
    let controller = ServerMonitorViewController(model: model, serverName: "生产服务器 · 卡片面板")
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 940),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentViewController = controller
    defer { controller.shutdown(); window.close() }
    let now = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    func sample(time: TimeInterval, counters: [UInt64], ethBytes: UInt64, loBytes: UInt64) -> LinuxServerSample {
      .init(capturedAt: Date(), monotonicTime: time,
        identity: .init(kernelRelease: .value("6.8.0"), architecture: .value("x86_64"), hostname: .value("production-01"), operatingSystem: .value("Ubuntu 24.04 LTS")),
        bootID: .value("boot"), cpu: .value(.init(counters)),
        memory: .value(.init(totalBytes: 16 * 1024 * 1024 * 1024, usedBytes: 4 * 1024 * 1024 * 1024, availableBytes: 12 * 1024 * 1024 * 1024)),
        swap: .value(.init(totalBytes: 1024 * 1024 * 1024, usedBytes: 0, availableBytes: 1024 * 1024 * 1024)),
        disks: .value([
          .init(filesystem: "/dev/sdb1", mountPoint: "/data", totalBytes: 100 * 1024 * 1024 * 1024, usedBytes: 90 * 1024 * 1024 * 1024, availableBytes: 10 * 1024 * 1024 * 1024, usagePercent: .value(90)),
          .init(filesystem: "/dev/sda1", mountPoint: "/", totalBytes: 50 * 1024 * 1024 * 1024, usedBytes: 24 * 1024 * 1024 * 1024, availableBytes: 26 * 1024 * 1024 * 1024, usagePercent: .value(48)),
          .init(filesystem: "tmpfs", mountPoint: "/run", totalBytes: 1024 * 1024 * 1024, usedBytes: 1024 * 1024, availableBytes: 1023 * 1024 * 1024, usagePercent: .value(0.1)),
          .init(filesystem: "overlay", mountPoint: "/var/lib/docker/overlay2/container/merged", totalBytes: 50 * 1024 * 1024 * 1024, usedBytes: 24 * 1024 * 1024 * 1024, availableBytes: 26 * 1024 * 1024 * 1024, usagePercent: .value(48)),
          .init(filesystem: "/dev/sda1", mountPoint: "/bind", totalBytes: 50 * 1024 * 1024 * 1024, usedBytes: 24 * 1024 * 1024 * 1024, availableBytes: 26 * 1024 * 1024 * 1024, usagePercent: .value(48))]),
        network: .value([.init(name: "lo", receivedBytes: loBytes, transmittedBytes: loBytes),
                         .init(name: "eth0", receivedBytes: ethBytes, transmittedBytes: ethBytes / 2)]),
        load: .value(.init(oneMinute: 0.67, fiveMinutes: 0.52, fifteenMinutes: 0.44)), uptime: .value(638_460))
    }
    controller.start(); try await wait { client.requests == 1 }
    client.deliver(sample(time: now - 5, counters: [100, 0, 100, 800, 0, 0, 0, 0], ethBytes: 100, loBytes: 0))
    try await wait { client.requests == 2 }
    client.deliver(sample(time: now, counters: [150, 0, 150, 900, 0, 0, 0, 0], ethBytes: 5100, loBytes: 5_000_000))
    try await wait { controller.cpuLabel.stringValue == "50.0%" }
    controller.togglePause(); try await wait { client.closes > 0 }
    XCTAssertEqual(controller.memoryLabel.stringValue, "25.0%")
    XCTAssertEqual(controller.diskSummaryLabel.stringValue, "48.0%", "root partition is preferred even if it is not first")
    XCTAssertTrue(controller.metricCards[2].detailLabel.stringValue.contains("分区 /\n"))
    XCTAssertEqual(controller.swapLabel.stringValue, "0.0%", "a configured, unused swap really is zero")
    XCTAssertEqual(controller.metricCards[4].usageBar.usage, 0)
    XCTAssertFalse(controller.metricCards[4].usageBar.isHidden)
    XCTAssertEqual(controller.loadLabel.stringValue, "0.67")
    XCTAssertTrue(controller.metricCards[5].detailLabel.stringValue.contains("0.52"))
    XCTAssertTrue(controller.metricCards[5].detailLabel.stringValue.contains("0.44"))
    XCTAssertTrue(controller.metricCards[3].detailLabel.stringValue.contains("eth0"))
    XCTAssertEqual(controller.networkChart.series[0].points.last?.value, 1000, "virtual interfaces must not be summed")
    controller.interfacePopup.selectItem(withTitle: "lo"); controller.interfaceChanged()
    XCTAssertTrue(controller.metricCards[3].detailLabel.stringValue.contains("lo"))
    XCTAssertEqual(controller.networkChart.series[0].points.last?.value, 1_000_000)
    controller.interfacePopup.selectItem(withTitle: "eth0"); controller.interfaceChanged()
    let values = controller.metricCards.map { $0.valueLabel.stringValue }, history = model.history
    for theme in [NSAppearance.Name.darkAqua, .aqua] {
      window.appearance = NSAppearance(named: theme)
      for size in [NSSize(width: 900, height: 940), .init(width: 360, height: 740), .init(width: 240, height: 140)] {
        window.setContentSize(size); controller.view.needsLayout = true; controller.view.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(controller.view.subviews.first as? NSScrollView), document = try XCTUnwrap(scroll.documentView)
        for card in descendants(document).compactMap({ $0 as? MonitorCardView }) {
          XCTAssertTrue(document.bounds.contains(card.convert(card.bounds, to: document)))
          for control in descendants(card).compactMap({ $0 as? NSControl }) {
            XCTAssertTrue(card.bounds.contains(control.convert(control.bounds, to: card)), "card control is clipped: \(control)")
          }
        }
        XCTAssertEqual(controller.metricCards.map { $0.valueLabel.stringValue }, values)
        XCTAssertEqual(model.history, history); XCTAssertTrue(model.isPaused)
        XCTAssertTrue(controller.statusLabel.stringValue.contains("已过期"))
        XCTAssertFalse(descendants(document).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("secret") })
      }
    }
    if ProcessInfo.processInfo.environment["TERMES_MONITOR_CARDS_VISUAL_REVIEW"] == "1" {
      window.makeKeyAndOrderFront(nil)
      for (theme, size, name) in [(NSAppearance.Name.darkAqua, NSSize(width: 900, height: 940), "dark"),
                                (.aqua, .init(width: 900, height: 940), "light"),
                                (.darkAqua, .init(width: 360, height: 820), "compact")] {
        window.title = "Termes 监控卡片 · 示例数据 · \(name)"
        window.appearance = NSAppearance(named: theme); window.setContentSize(size)
        controller.view.needsLayout = true; controller.view.layoutSubtreeIfNeeded()
        await Task.yield()
        print("MONITOR_CARDS_REVIEW_\(name.uppercased())=\(window.windowNumber)")
        try await Task.sleep(nanoseconds: 15_000_000_000)
      }
    }
    if ProcessInfo.processInfo.environment["TERMES_DISKS_VISUAL_REVIEW"] == "1" {
      window.appearance = NSAppearance(named: .aqua); window.setContentSize(.init(width: 440, height: 820)); window.makeKeyAndOrderFront(nil)
      for (showAll, name) in [(false, "filtered"), (true, "details")] {
        if controller.showsAllDisks != showAll { controller.diskDisclosureButton.performClick(nil) }
        controller.view.needsLayout = true; controller.view.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(controller.view.subviews.first as? NSScrollView)
        let diskTop = try XCTUnwrap(controller.diskDisclosureButton.superview).frame.minY
        scroll.contentView.scroll(to: .init(x: 0, y: diskTop - 16)); scroll.reflectScrolledClipView(scroll.contentView)
        window.title = "Termes 磁盘列表 · 示例数据 · \(name)"
        await Task.yield(); print("DISKS_REVIEW_\(name)=\(window.windowNumber)")
        try await Task.sleep(for: .seconds(15))
      }
    }
  }

  func test_trend_lines_stop_at_missing_data_reconnect_and_invalid_clock_order() {
    let segment = UUID(), reconnect = UUID(), chart = MonitorTrendView()
    let line = MonitorTrendSeries(name: "网络", color: .systemBlue, points: [
      .init(time: -1, value: 10, segment: segment), .init(time: 0, value: 10, segment: segment),
      .init(time: 5, value: nil, segment: segment), .init(time: 10, value: 15, segment: segment),
      .init(time: 15, value: 20, segment: reconnect), .init(time: 20, value: 25, segment: reconnect),
      .init(time: 25, value: .nan, segment: reconnect), .init(time: 30, value: 0, segment: reconnect),
      .init(time: 30, value: 2, segment: reconnect), .init(time: 61, value: 3, segment: reconnect)])
    chart.configure(minutes: 1, end: 60, fixedMaximum: nil, series: [line])
    let paths = chart.segments(for: line)
    XCTAssertEqual(paths.map(\.count), [1, 1, 2, 1, 1])
    XCTAssertEqual(paths[3].first?.value, 0, "a real zero remains visible")
    XCTAssertFalse(paths.contains { $0.contains { $0.value == nil } })
  }

  func test_disk_details_expand_without_changing_the_sample_and_file_summary_preserves_missing_and_stale_data() async throws {
    _ = NSApplication.shared
    let client = MonitorViewClient(), model = ServerMonitorModel(interval: 0.01) { client }
    model.setConnection(connected: true, version: 1, destination: .init(config: .init(hostname: "linux", username: "user", auth: .password("secret"))))
    let monitor = ServerMonitorViewController(model: model, serverName: "磁盘明细测试"), tools = SessionToolsView(frame: .init(x: 0, y: 0, width: 360, height: 700))
    tools.setContents(overview: monitor.view, files: NSView()); tools.select(.files)
    monitor.onRender = { [weak tools, weak monitor] in tools?.updateSummary(from: monitor) }
    defer { monitor.onRender = nil; monitor.shutdown() }
    func disk(_ source: String, _ mount: String, total: UInt64 = 1000) -> ServerDiskUsage {
      .init(filesystem: source, mountPoint: mount, totalBytes: total, usedBytes: 400, availableBytes: 600, usagePercent: .value(40))
    }
    let all = [disk("tmpfs", "/run"), disk("/dev/vda1", "/"), disk("overlay", "/docker/merged"),
               disk("/dev/vda1", "/bind"), disk("/dev/vdb1", "/data", total: 2000)]
    let sample = LinuxServerSample(capturedAt: Date(), monotonicTime: Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000,
      identity: .init(kernelRelease: .value("6.1"), architecture: .value("arm64"), hostname: .value("linux"), operatingSystem: .value("Linux")),
      bootID: .value("boot"), cpu: .value(.init([100, 0, 100, 800, 0, 0, 0, 0])),
      memory: .value(.init(totalBytes: 1000, usedBytes: 0, availableBytes: 1000)), swap: .unavailable(.missingData),
      disks: .value(all), network: .value([.init(name: "eth0", receivedBytes: 100, transmittedBytes: 200)]),
      load: .unavailable(.missingData), uptime: .value(3600))
    monitor.start(); try await wait { client.requests == 1 }
    client.deliver(sample); try await wait { monitor.displayedDisks.count == 2 }
    XCTAssertEqual(monitor.displayedDisks.map(\.mountPoint), ["/", "/data"])
    XCTAssertEqual(tools.summaryCards[0].valueLabel.stringValue, "—", "CPU needs a baseline")
    XCTAssertEqual(tools.summaryCards[1].valueLabel.stringValue, "0.0%", "a measured zero stays visible")
    XCTAssertEqual(tools.summaryCards[2].valueLabel.stringValue, "40.0%")
    XCTAssertEqual(tools.summaryCards[3].valueLabel.stringValue, "—", "network needs a baseline")
    XCTAssertFalse(monitor.diskDisclosureButton.isHidden)
    monitor.diskDisclosureButton.performClick(nil)
    XCTAssertTrue(monitor.showsAllDisks); XCTAssertEqual(monitor.displayedDisks, all)
    XCTAssertEqual(model.current?.sample.disks.value, all)
    monitor.diskDisclosureButton.performClick(nil)
    XCTAssertFalse(monitor.showsAllDisks); XCTAssertEqual(monitor.displayedDisks.map(\.mountPoint), ["/", "/data"])
    monitor.togglePause()
    XCTAssertTrue(tools.summaryCards[1].toolTip?.contains("已过期") == true)
    XCTAssertEqual(tools.summaryCards[1].valueLabel.stringValue, "0.0%")
    let rawMounts = model.current?.sample.disks
    tools.select(.overview); tools.select(.files)
    XCTAssertEqual(model.current?.sample.disks, rawMounts)
    tools.updateSummary(from: nil)
    XCTAssertTrue(tools.summaryCards.allSatisfy { $0.valueLabel.stringValue == "—" })
  }

  func test_menu_and_pane_toggles_keep_files_terminal_and_monitor_alive_until_their_own_close() async throws {
    _ = NSApplication.shared
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let services = AppServices(directory: directory, secrets: InMemorySecretStore()), main = MainWindowController(services: services, empty: false)
    defer { main.disconnectAll(); main.close() }
    let item = NSMenuItem(title: "服务器监控", action: #selector(MainWindowController.toggleServerMonitor(_:)), keyEquivalent: "")
    XCTAssertFalse(main.validateMenuItem(item))
    let pane = try XCTUnwrap(main.focusedPane)
    pane.connect(.init(hostname: server.host, port: server.port, username: server.username, auth: .password(server.password)),
      label: .init(name: "监控验收服务器", username: server.username))
    try await wait {
      if case .needsHostKeyConfirm = pane.session.state { pane.session.confirmHostKey(true) }
      return pane.session.state == .connected && pane.children.contains { $0 is TerminalViewController }
    }
    let terminal = try XCTUnwrap(pane.children.compactMap { $0 as? TerminalViewController }.first)
    pane.toggleFiles()
    let files = try XCTUnwrap(pane.children.compactMap { $0 as? FileBrowserViewController }.first)
    try await wait { !files.model.isBusy && files.model.directory != nil }
    main.toggleServerMonitor(nil)
    let monitor = try XCTUnwrap(pane.monitorVC)
    try await wait { monitor.model.history.count >= 2 }
    XCTAssertTrue(main.validateMenuItem(item)); XCTAssertEqual(item.state, .on)
    XCTAssertTrue(pane.children.contains { $0 === files }); XCTAssertTrue(pane.children.contains { $0 === terminal })
    let window = try XCTUnwrap(main.window)
    window.setContentSize(.init(width: 1440, height: 860)); window.contentView?.layoutSubtreeIfNeeded()
    main.showWindow(nil); window.makeKeyAndOrderFront(nil)
    await Task.yield()
    if ProcessInfo.processInfo.environment["TERMES_MONITOR_VISUAL_REVIEW"] == "1" {
      window.title = "Termes 服务器监控验收"
      print("MONITOR_REVIEW_WINDOW=\(window.windowNumber)")
      try await Task.sleep(nanoseconds: 50_000_000_000)
    }
    pane.toggleFiles()
    XCTAssertTrue(pane.monitorVC === monitor); XCTAssertTrue(monitor.model.isOpen)
    pane.toggleFiles()
    let reopened = try XCTUnwrap(pane.children.compactMap { $0 as? FileBrowserViewController }.first)
    try await wait { !reopened.model.isBusy && reopened.model.directory != nil }
    main.toggleServerMonitor(nil)
    XCTAssertNil(pane.monitorVC); XCTAssertFalse(pane.session.serverMonitor.isOpen)
    XCTAssertTrue(pane.children.contains { $0 === reopened }); XCTAssertTrue(pane.children.contains { $0 === terminal })
    XCTAssertTrue(main.validateMenuItem(item)); XCTAssertEqual(item.state, .off)
    XCTAssertEqual(window.firstResponder, terminal.terminalView)
    main.toggleServerMonitor(nil); try await wait { pane.session.serverMonitor.current != nil }
    let smallWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 140),
      styleMask: [.borderless], backing: .buffered, defer: false)
    smallWindow.isReleasedWhenClosed = false; smallWindow.contentView = pane.view
    defer { smallWindow.close() }
    pane.isInWorkspace = true
    (pane.view as? PaneRootView)?.onHover?(true)
    pane.view.layoutSubtreeIfNeeded()
    let column = try XCTUnwrap(pane.view.subviews.first as? NSStackView)
    let header = try XCTUnwrap(column.arrangedSubviews.first as? NSStackView)
    for button in header.arrangedSubviews.compactMap({ $0 as? NSButton }).filter({ !$0.isHidden }) {
      XCTAssertTrue(pane.view.bounds.contains(button.convert(button.bounds, to: pane.view)), "header control exceeds minimum pane: \(button)")
    }
    pane.close()
    XCTAssertFalse(pane.session.serverMonitor.isOpen); XCTAssertNil(pane.monitorVC)
    XCTAssertTrue(pane.session.serverMonitor.history.isEmpty)
  }
}
