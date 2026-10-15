import UIKit
import SnapKit
import Combine
import TermesKit
import SSHCore

/// The sheet owns only monitoring. Its pause/close actions never change the terminal session.
@MainActor
final class MobileServerMonitorController: UIViewController, UIAdaptivePresentationControllerDelegate {
  let model: ServerMonitorModel
  var onClose: (() -> Void)?
  let statusLabel = MobileUI.label("", style: .subheadline, color: .secondaryLabel)
  let cpuLabel = UILabel(), memoryLabel = UILabel(), diskSummaryLabel = UILabel()
  let networkSummaryLabel = UILabel(), swapLabel = UILabel(), loadLabel = UILabel()
  let rangeControl = UISegmentedControl(items: ["1 分钟", "5 分钟", "15 分钟"])
  let usageChart = MobileMonitorTrendView(), networkChart = MobileMonitorTrendView()
  let diskDisclosureButton = UIButton(type: .system)
  private(set) var displayedDisks: [ServerDiskUsage] = []
  private(set) var showsAllDisks = false
  private(set) var isUserPaused = false
  private(set) var isShutdown = false

  private let serverName: String
  private let scrollView = UIScrollView()
  private let content = MobileUI.stack(spacing: 16)
  private let endpointLabel = MobileUI.label("", style: .subheadline, color: .secondaryLabel)
  private let updatedLabel = MobileUI.label("", style: .caption1, color: .secondaryLabel)
  private let activity = UIActivityIndicatorView(style: .medium)
  private let metricGrid = MobileMonitorMetricGrid()
  private let systemRows = MobileUI.stack(spacing: 12)
  private let diskRows = MobileUI.stack(spacing: 16)
  private let interfaceRows = MobileUI.stack(spacing: 12)
  private let interfaceButton = UIButton(type: .system)
  private var metricCards: [MobileMonitorMetricCard] = []
  private var selectedInterface: String?
  private var displayedSample: LinuxServerSample?
  private var needsDiskUpdate = true
  private var isVisible = false
  private var hasOpened = false
  private var isInBackground = false
  private var subscriptions = Set<AnyCancellable>()
  private var ticker: Task<Void, Never>?
  private lazy var pauseButton = MobileUI.button("暂停", symbol: "pause", id: "monitor.pause") { [weak self] in self?.togglePause() }
  private lazy var retryButton = MobileUI.button("重试", symbol: "arrow.clockwise", id: "monitor.retry") { [weak self] in self?.retry() }

  init(model: ServerMonitorModel, serverName: String) {
    self.model = model; self.serverName = serverName
    super.init(nibName: nil, bundle: nil)
    preferredContentSize = CGSize(width: 760, height: 900)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  deinit { ticker?.cancel() }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "服务器监控"
    view.accessibilityIdentifier = "monitor.screen"
    view.backgroundColor = .systemGroupedBackground
    navigationItem.largeTitleDisplayMode = .never
    let done = UIBarButtonItem(title: "完成", primaryAction: UIAction { [weak self] _ in self?.closeMonitor() })
    done.accessibilityIdentifier = "monitor.close"
    navigationItem.rightBarButtonItem = done
    buildContent()
    model.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.render() }.store(in: &subscriptions)
    let center = NotificationCenter.default
    for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
      center.publisher(for: name).receive(on: RunLoop.main).sink { [weak self] _ in self?.suspendForBackground() }.store(in: &subscriptions)
    }
    center.publisher(for: UIApplication.didBecomeActiveNotification).receive(on: RunLoop.main).sink { [weak self] _ in
      self?.resumeFromBackground()
    }.store(in: &subscriptions)
    isInBackground = UIApplication.shared.applicationState == .background
    registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (controller: MobileServerMonitorController, _: UITraitCollection) in
      controller.updateRangeFont()
    }
    render()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !isShutdown else { return }
    isVisible = true
    navigationController?.presentationController?.delegate = self
    presentationController?.delegate = self
    if !hasOpened { hasOpened = true; model.open() }
    if isUserPaused || isInBackground { model.pause() }
    else if model.isPaused { model.resume() }
    startClock()
    render()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    isVisible = false
    stopClock()
    // Pause during a sheet gesture; a cancelled dismissal resumes in viewDidAppear.
    if hasOpened && !isShutdown { model.pause() }
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if isBeingDismissed || navigationController?.isBeingDismissed == true || isMovingFromParent {
      shutdown()
    }
  }

  override func didMove(toParent parent: UIViewController?) {
    super.didMove(toParent: parent)
    // Release ownership synchronously when removed from a container. A deferred
    // deinit close could otherwise shut down a newly opened sheet for this session.
    if parent == nil, hasOpened { shutdown() }
  }

  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { shutdown() }

  func shutdown() {
    guard !isShutdown else { return }
    isShutdown = true; isVisible = false
    stopClock()
    model.close()
    render()
    subscriptions.removeAll()
    onClose?()
  }

  @objc func togglePause() {
    guard hasOpened, !isShutdown else { return }
    isUserPaused.toggle()
    if isUserPaused || isInBackground || !isVisible { model.pause() }
    else { model.resume() }
    render()
  }

  @objc func retry() {
    guard !isShutdown, isVisible, !isInBackground, !isUserPaused else { return }
    model.retry()
    render()
  }

  func suspendForBackground() {
    guard !isShutdown else { return }
    isInBackground = true
    stopClock()
    if hasOpened { model.pause() }
    render()
  }

  func resumeFromBackground() {
    guard !isShutdown else { return }
    isInBackground = false
    if hasOpened && isVisible && !isUserPaused { model.resume() }
    startClock()
    render()
  }

  private func startClock() {
    guard ticker == nil, isVisible, !isInBackground, !isShutdown else { return }
    ticker = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { break }
        guard self != nil, !Task.isCancelled else { break }
        self?.model.refreshTime()
        self?.render()
      }
    }
  }
  private func stopClock() { ticker?.cancel(); ticker = nil }
  private func closeMonitor() { shutdown(); dismiss(animated: true) }

  private func buildContent() {
    scrollView.alwaysBounceVertical = true
    scrollView.keyboardDismissMode = .onDrag
    view.addSubview(scrollView)
    scrollView.snp.makeConstraints { $0.edges.equalTo(view.safeAreaLayoutGuide) }
    scrollView.addSubview(content)
    content.snp.makeConstraints { make in
      make.edges.equalTo(scrollView.contentLayoutGuide).inset(16)
      make.width.equalTo(scrollView.frameLayoutGuide).offset(-32)
    }
    let serverLabel = MobileUI.label(serverName, style: .title2)
    serverLabel.accessibilityTraits.insert(.header)
    serverLabel.accessibilityIdentifier = "monitor.server"
    statusLabel.accessibilityIdentifier = "monitor.status"
    endpointLabel.accessibilityIdentifier = "monitor.endpoint"
    updatedLabel.accessibilityIdentifier = "monitor.updated"
    activity.hidesWhenStopped = true
    let stateRow = MobileUI.stack([activity, statusLabel], axis: .horizontal, spacing: 8)
    stateRow.alignment = .top
    let actions = MobileUI.stack([pauseButton, retryButton], axis: .horizontal, spacing: 12)
    actions.distribution = .fillEqually
    content.addArrangedSubview(MobileMonitorCard(views: [serverLabel, endpointLabel, stateRow, updatedLabel, actions]))

    let metrics: [(UILabel, String, String, UIColor, String)] = [
      (cpuLabel, "CPU", "cpu", .systemBlue, "cpu"),
      (memoryLabel, "内存", "memorychip", .systemPurple, "memory"),
      (diskSummaryLabel, "磁盘", "internaldrive", .systemOrange, "disk"),
      (networkSummaryLabel, "网络", "network", .systemGreen, "network"),
      (swapLabel, "Swap", "arrow.left.arrow.right", .systemTeal, "swap"),
      (loadLabel, "负载", "waveform.path.ecg", .systemPink, "load")
    ]
    metricCards = metrics.map { label, title, symbol, color, identifier in
      label.accessibilityIdentifier = "monitor.\(identifier)"
      return MobileMonitorMetricCard(title: title, symbol: symbol, color: color, valueLabel: label)
    }
    metricGrid.setCards(metricCards)
    content.addArrangedSubview(metricGrid)

    rangeControl.selectedSegmentIndex = 1
    rangeControl.accessibilityLabel = "趋势时间范围"
    rangeControl.accessibilityIdentifier = "monitor.range"
    rangeControl.addTarget(self, action: #selector(rangeChanged), for: .valueChanged)
    rangeControl.snp.makeConstraints { $0.height.greaterThanOrEqualTo(36) }
    updateRangeFont()
    usageChart.accessibilityLabel = "CPU 和内存趋势"
    usageChart.accessibilityIdentifier = "monitor.usageChart"
    networkChart.accessibilityLabel = "服务器网络速率趋势"
    networkChart.accessibilityIdentifier = "monitor.networkChart"
    usageChart.snp.makeConstraints { $0.height.equalTo(220) }
    networkChart.snp.makeConstraints { $0.height.equalTo(220) }
    content.addArrangedSubview(MobileMonitorCard(title: "资源使用趋势", views: [rangeControl,
      legend([("CPU", .systemBlue), ("内存", .systemPurple)]), usageChart]))

    interfaceButton.showsMenuAsPrimaryAction = true
    interfaceButton.contentHorizontalAlignment = .leading
    interfaceButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
    interfaceButton.titleLabel?.adjustsFontForContentSizeCategory = true
    interfaceButton.titleLabel?.numberOfLines = 0
    interfaceButton.accessibilityLabel = "网络趋势接口"
    interfaceButton.accessibilityIdentifier = "monitor.interface"
    interfaceButton.snp.makeConstraints { $0.height.greaterThanOrEqualTo(44) }
    content.addArrangedSubview(MobileMonitorCard(title: "网络流量", views: [interfaceButton,
      legend([("接收 ↓", .systemGreen), ("发送 ↑", .systemBlue)]), networkChart,
      MobileUI.label("收发方向相对服务器", style: .caption1, color: .secondaryLabel)]))
    content.addArrangedSubview(MobileMonitorCard(title: "系统信息", views: [systemRows]))

    diskDisclosureButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
    diskDisclosureButton.titleLabel?.adjustsFontForContentSizeCategory = true
    diskDisclosureButton.titleLabel?.numberOfLines = 0
    diskDisclosureButton.contentHorizontalAlignment = .leading
    diskDisclosureButton.accessibilityIdentifier = "monitor.disks.expand"
    diskDisclosureButton.addTarget(self, action: #selector(toggleDiskDetails), for: .touchUpInside)
    diskDisclosureButton.snp.makeConstraints { $0.height.greaterThanOrEqualTo(44) }
    content.addArrangedSubview(MobileMonitorCard(title: "磁盘分区", views: [diskDisclosureButton, diskRows]))
    content.addArrangedSubview(MobileMonitorCard(title: "网络接口", views: [interfaceRows]))
    content.addArrangedSubview(MobileUI.label("约每 5 秒更新，历史保留 15 分钟。CPU 和网络速率需要相邻两次采样。当前支持 Linux 服务器。",
      style: .footnote, color: .secondaryLabel))
  }

  private func updateRangeFont() {
    let font = UIFont.preferredFont(forTextStyle: .caption1)
    rangeControl.setTitleTextAttributes([.font: font], for: .normal)
    rangeControl.setTitleTextAttributes([.font: font], for: .selected)
  }

  private func legend(_ entries: [(String, UIColor)]) -> UIView {
    let labels = entries.map { title, color in MobileUI.label("● \(title)", style: .caption1, color: color) }
    let stack = MobileUI.stack(labels, axis: .horizontal, spacing: 20)
    stack.distribution = .fillEqually
    return stack
  }

  func render() {
    guard isViewLoaded else { return }
    endpointLabel.text = model.destination.map { "\($0.username)@\($0.hostname):\($0.port)" } ?? "等待服务器连接信息"
    let message: String
    switch model.state {
    case .closed: message = "监控已关闭"
    case .disconnected: message = "SSH 已断开，等待重新连接"
    case .paused: message = isInBackground ? "应用不在前台，采样已暂停" : "采样已暂停"
    case .connecting: message = "正在连接监控"
    case .sampling: message = "正在采集服务器状态"
    case .live: message = "实时监控 · 服务器状态已更新"
    case .failed(let error): message = "\(error)\n稍后自动重试，也可以点按重试。"
    case .unavailable(let error): message = error
    }
    let stale = model.current != nil && model.isStale
    statusLabel.text = message + (stale ? "\n上次数据已过期，以下显示最近一次采样。" : "")
    statusLabel.textColor = stale ? .systemOrange : .secondaryLabel
    switch model.state {
    case .connecting, .sampling: activity.startAnimating()
    default: activity.stopAnimating()
    }
    updatedLabel.text = model.current.map {
      "采样时间：" + $0.sample.capturedAt.formatted(date: .abbreviated, time: .standard)
    } ?? "尚无采样数据"
    pauseButton.configuration?.title = isUserPaused ? "恢复" : "暂停"
    pauseButton.configuration?.image = UIImage(systemName: isUserPaused ? "play" : "pause")
    pauseButton.isEnabled = model.isOpen && !isShutdown
    retryButton.isEnabled = model.isOpen && model.isConnected && !isUserPaused && !isInBackground && !isShutdown

    guard let snapshot = model.current else {
      for card in metricCards { card.update(value: "等待采样", detail: "尚无服务器数据") }
      if displayedSample != nil || systemRows.arrangedSubviews.isEmpty {
        replaceRows(systemRows, with: [MobileUI.label("系统信息等待采样", color: .secondaryLabel)])
        replaceRows(diskRows, with: [MobileUI.label("磁盘信息等待采样", color: .secondaryLabel)])
        replaceRows(interfaceRows, with: [MobileUI.label("网络接口等待采样", color: .secondaryLabel)])
      }
      displayedSample = nil; displayedDisks = []; selectedInterface = nil
      diskDisclosureButton.isHidden = true
      configureInterfaceMenu([])
      renderCharts()
      return
    }
    let sample = snapshot.sample
    metricCards[0].update(value: Self.describe(snapshot.cpu) { Self.percent($0.totalPercent) },
      detail: snapshot.cpu.value.map { "用户 \(Self.percent($0.userPercent)) · 系统 \(Self.percent($0.systemPercent))" } ?? "CPU 使用率需要相邻两次有效采样",
      usage: snapshot.cpu.value?.totalPercent, prominent: snapshot.cpu.value != nil)
    metricCards[1].update(value: Self.describe(sample.memory) { Self.percent($0.usagePercent) },
      detail: sample.memory.value.map { "\(Self.bytes($0.usedBytes)) / \(Self.bytes($0.totalBytes))" } ?? "服务器物理内存",
      usage: sample.memory.value?.usagePercent, prominent: sample.memory.value?.usagePercent != nil)
    let disk = sample.disks.value.flatMap { $0.first(where: { $0.mountPoint == "/" }) ?? ServerDiskPresentation.visible($0, showAll: false).first ?? $0.first }
    metricCards[2].update(value: disk.map { Self.describe($0.usagePercent, format: Self.percent) } ?? Self.describe(sample.disks) { _ in "无分区" },
      detail: disk.map { "\($0.mountPoint) · \(Self.bytes($0.usedBytes)) / \(Self.bytes($0.totalBytes))" } ?? "主要磁盘分区",
      usage: disk?.usagePercent.value, prominent: disk?.usagePercent.value != nil)
    metricCards[4].update(value: Self.describe(sample.swap) { $0.totalBytes == 0 ? "未配置" : Self.percent($0.usagePercent) },
      detail: sample.swap.value.map { $0.totalBytes == 0 ? "服务器未配置交换空间" : "\(Self.bytes($0.usedBytes)) / \(Self.bytes($0.totalBytes))" } ?? "交换空间",
      usage: sample.swap.value?.usagePercent, prominent: sample.swap.value != nil)
    metricCards[5].update(value: Self.describe(sample.load) { String(format: "%.2f", $0.oneMinute) },
      detail: sample.load.value.map { String(format: "1 分钟平均负载\n5 分钟 %.2f · 15 分钟 %.2f", $0.fiveMinutes, $0.fifteenMinutes) } ?? "1 / 5 / 15 分钟平均负载",
      prominent: sample.load.value != nil)

    if displayedSample != sample {
      let names = snapshot.network.value?.map(\.name) ?? []
      if selectedInterface == nil || !names.contains(selectedInterface!) {
        selectedInterface = names.first(where: { $0 != "lo" }) ?? names.first
      }
      configureInterfaceMenu(names)
      renderSystem(sample)
      renderInterfaces(snapshot.network)
    }
    if displayedSample != sample || needsDiskUpdate { renderDisks(sample.disks); needsDiskUpdate = false }
    displayedSample = sample
    if let network = snapshot.network.value?.first(where: { $0.name == selectedInterface }) {
      let down = Self.describe(network.receivedBytesPerSecond, format: Self.rate)
      let up = Self.describe(network.transmittedBytesPerSecond, format: Self.rate)
      let available = network.receivedBytesPerSecond.value != nil && network.transmittedBytesPerSecond.value != nil
      metricCards[3].update(value: down == up && !available ? down : "↓ \(down)\n↑ \(up)",
        detail: "\(network.name) · 接收 ↓ / 发送 ↑", prominent: available)
    } else {
      metricCards[3].update(value: Self.describe(snapshot.network) { _ in "无接口" }, detail: "相对服务器的网络速率")
    }
    renderCharts()
  }

  private func renderSystem(_ sample: LinuxServerSample) {
    let values: [(String, String)] = [
      ("系统", Self.describe(sample.identity.operatingSystem) { $0 }),
      ("架构", Self.describe(sample.identity.architecture) { $0 }),
      ("主机名", Self.describe(sample.identity.hostname) { $0 }),
      ("内核", Self.describe(sample.identity.kernelRelease) { $0 }),
      ("已运行", Self.describe(sample.uptime, format: Self.uptime))
    ]
    replaceRows(systemRows, with: values.map { title, value in
      let name = MobileUI.label(title, style: .caption1, color: .secondaryLabel)
      let text = MobileUI.label(value, style: .subheadline)
      return MobileUI.stack([name, text], spacing: 3)
    })
  }

  private func renderDisks(_ metric: ServerMetric<[ServerDiskUsage]>) {
    guard let all = metric.value else {
      displayedDisks = []; diskDisclosureButton.isHidden = true
      replaceRows(diskRows, with: [MobileUI.label(Self.describe(metric) { _ in "" }, color: .secondaryLabel)])
      return
    }
    displayedDisks = ServerDiskPresentation.visible(all, showAll: showsAllDisks)
    diskDisclosureButton.isHidden = all.count == ServerDiskPresentation.visible(all, showAll: false).count
    diskDisclosureButton.setTitle(showsAllDisks ? "收起详情" : "显示全部（\(all.count)）", for: .normal)
    let rows: [UIView] = displayedDisks.map { disk in
      let title = MobileUI.label(disk.mountPoint, style: .headline)
      let source = MobileUI.label(disk.filesystem, style: .caption1, color: .secondaryLabel)
      let capacity = MobileUI.label("\(Self.describe(disk.usagePercent, format: Self.percent)) · \(Self.bytes(disk.usedBytes)) / \(Self.bytes(disk.totalBytes))", style: .subheadline)
      let available = MobileUI.label("可用 " + ByteCountFormatter.string(fromByteCount: disk.availableBytes, countStyle: .binary), style: .caption1, color: .secondaryLabel)
      let bar = UIProgressView(progressViewStyle: .bar)
      bar.progressTintColor = .systemOrange
      bar.progress = Float(min(100, max(0, disk.usagePercent.value ?? 0)) / 100)
      bar.isHidden = disk.usagePercent.value == nil
      bar.isAccessibilityElement = false
      return MobileUI.stack([title, source, capacity, available, bar], spacing: 6)
    }
    replaceRows(diskRows, with: rows.isEmpty ? [MobileUI.label("无实际存储分区，可展开查看全部挂载。", color: .secondaryLabel)] : rows)
  }

  private func renderInterfaces(_ metric: ServerMetric<[ServerNetworkRate]>) {
    guard let interfaces = metric.value else {
      replaceRows(interfaceRows, with: [MobileUI.label(Self.describe(metric) { _ in "" }, color: .secondaryLabel)])
      return
    }
    let rows: [UIView] = interfaces.map { network in
      let title = MobileUI.label(network.name, style: .headline)
      let rates = MobileUI.label("↓ \(Self.describe(network.receivedBytesPerSecond, format: Self.rate))\n↑ \(Self.describe(network.transmittedBytesPerSecond, format: Self.rate))", style: .subheadline, color: .secondaryLabel)
      return MobileUI.stack([title, rates], spacing: 4)
    }
    replaceRows(interfaceRows, with: rows.isEmpty ? [MobileUI.label("服务器没有网络接口", color: .secondaryLabel)] : rows)
  }

  private func configureInterfaceMenu(_ names: [String]) {
    interfaceButton.isEnabled = !names.isEmpty
    interfaceButton.setTitle(selectedInterface.map { "\($0) ▾" } ?? "暂无网络接口", for: .normal)
    interfaceButton.menu = UIMenu(children: names.map { name in
      UIAction(title: name, state: name == selectedInterface ? .on : .off) { [weak self] _ in
        guard let self else { return }
        self.selectedInterface = name
        self.configureInterfaceMenu(names)
        self.render()
      }
    })
  }

  private func replaceRows(_ stack: UIStackView, with views: [UIView]) {
    stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    for (index, child) in views.enumerated() {
      if index > 0 {
        let separator = UIView(); separator.backgroundColor = .separator
        separator.snp.makeConstraints { $0.height.equalTo(1 / max(1, traitCollection.displayScale)) }
        stack.addArrangedSubview(separator)
      }
      stack.addArrangedSubview(child)
    }
  }

  @objc func toggleDiskDetails() { showsAllDisks.toggle(); needsDiskUpdate = true; render() }
  @objc func rangeChanged() { renderCharts() }

  private func renderCharts() {
    let minutes = [1, 5, 15][max(0, min(2, rangeControl.selectedSegmentIndex))]
    let points = model.points(minutes: minutes)
    let end = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    usageChart.configure(minutes: minutes, end: end, fixedMaximum: 100, series: [
      .init(name: "CPU", color: .systemBlue, points: points.map { .init(time: $0.monotonicTime, value: $0.cpuPercent, segment: $0.segment) }),
      .init(name: "内存", color: .systemPurple, points: points.map { .init(time: $0.monotonicTime, value: $0.memoryPercent, segment: $0.segment) })])
    networkChart.configure(minutes: minutes, end: end, fixedMaximum: nil, series: [
      .init(name: "接收 ↓", color: .systemGreen, points: points.map { point in
        .init(time: point.monotonicTime, value: point.network.first { $0.name == selectedInterface }?.receivedBytesPerSecond.value, segment: point.segment)
      }),
      .init(name: "发送 ↑", color: .systemBlue, points: points.map { point in
        .init(time: point.monotonicTime, value: point.network.first { $0.name == selectedInterface }?.transmittedBytesPerSecond.value, segment: point.segment)
      })])
  }

  private static func describe<T: Equatable & Sendable>(_ metric: ServerMetric<T>, format: (T) -> String) -> String {
    switch metric { case .value(let value): return format(value); case .unavailable(let reason): return reasonText(reason) }
  }
  static func reasonText(_ reason: ServerMetricUnavailable) -> String {
    switch reason {
    case .missingData: return "数据缺失"
    case .commandFailed: return "读取失败，请检查权限"
    case .invalidData: return "数据格式无效"
    case .limitExceeded: return "数据超过限制"
    case .waitingForBaseline: return "等待下一次采样"
    case .counterReset: return "计数已重置，等待采样"
    case .invalidInterval: return "采样间隔无效"
    }
  }
  static func percent(_ value: Double?) -> String { value.map { String(format: "%.1f%%", $0) } ?? "不可用" }
  static func bytes(_ value: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .binary) }
  static func rate(_ number: Double) -> String {
    let units = ["B/s", "KB/s", "MB/s", "GB/s", "TB/s", "PB/s"]
    var value = max(0, number), index = 0
    while value >= 1024, index < units.count - 1 { value /= 1024; index += 1 }
    return String(format: index == 0 && (value == 0 || value >= 1) ? "%.0f %@" : "%.1f %@", value, units[index])
  }
  private static func uptime(_ number: Double) -> String {
    guard number.isFinite, number >= 0 else { return "不可用" }
    let minutes = Int(min(Double(Int.max - 1024), number / 60))
    return "\(minutes / 1440) 天 \(minutes % 1440 / 60) 小时 \(minutes % 60) 分钟"
  }
}

@MainActor
private class MobileMonitorCard: UIView {
  init(title: String? = nil, views: [UIView]) {
    super.init(frame: .zero)
    backgroundColor = .secondarySystemGroupedBackground
    layer.cornerRadius = 18
    layer.cornerCurve = .continuous
    let stack = MobileUI.stack(spacing: 12)
    if let title {
      let heading = MobileUI.label(title, style: .headline)
      heading.accessibilityTraits.insert(.header)
      stack.addArrangedSubview(heading)
    }
    views.forEach { stack.addArrangedSubview($0) }
    addSubview(stack)
    stack.snp.makeConstraints { $0.edges.equalToSuperview().inset(16) }
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
private final class MobileMonitorMetricCard: MobileMonitorCard {
  private let title: String
  private let valueLabel: UILabel
  private let detailLabel = MobileUI.label("", style: .caption1, color: .secondaryLabel)
  private let usageBar = UIProgressView(progressViewStyle: .bar)
  init(title: String, symbol: String, color: UIColor, valueLabel: UILabel) {
    self.title = title; self.valueLabel = valueLabel
    let heading = MobileUI.label(title, style: .subheadline, color: .secondaryLabel)
    let icon = UIImageView(image: UIImage(systemName: symbol))
    icon.tintColor = color; icon.contentMode = .scaleAspectFit
    icon.isAccessibilityElement = false
    icon.snp.makeConstraints { $0.size.equalTo(22) }
    let header = MobileUI.stack([icon, heading], axis: .horizontal, spacing: 8)
    header.alignment = .center
    valueLabel.adjustsFontForContentSizeCategory = true
    valueLabel.numberOfLines = 0
    valueLabel.accessibilityLabel = title
    usageBar.progressTintColor = color
    usageBar.isAccessibilityElement = false
    super.init(views: [header, valueLabel, detailLabel, usageBar])
    update(value: "等待采样", detail: "尚无服务器数据")
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  func update(value: String, detail: String, usage: Double? = nil, prominent: Bool = false) {
    valueLabel.text = value; detailLabel.text = detail
    valueLabel.font = prominent
      ? UIFontMetrics(forTextStyle: .title2).scaledFont(for: .monospacedDigitSystemFont(ofSize: 26, weight: .semibold))
      : .preferredFont(forTextStyle: .body)
    valueLabel.textColor = prominent ? .label : .secondaryLabel
    valueLabel.accessibilityValue = value
    usageBar.isHidden = usage == nil || usage?.isFinite == false
    usageBar.progress = Float(min(100, max(0, usage ?? 0)) / 100)
  }
}

/// Keep phones in a readable single column and let the iPad sheet use its extra width.
@MainActor
private final class MobileMonitorMetricGrid: UIView {
  private let rows = MobileUI.stack(spacing: 12)
  private var cards: [UIView] = []
  private var columns = 0
  override init(frame: CGRect) {
    super.init(frame: frame)
    addSubview(rows)
    rows.snp.makeConstraints { $0.edges.equalToSuperview() }
    registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitHorizontalSizeClass.self]) { (grid: MobileMonitorMetricGrid, _: UITraitCollection) in
      grid.setNeedsLayout()
    }
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  func setCards(_ cards: [UIView]) {
    self.cards = cards; columns = 0
    arrange(columns: 1)
    setNeedsLayout()
  }
  override func layoutSubviews() {
    super.layoutSubviews()
    let isWide = traitCollection.userInterfaceIdiom == .pad && !traitCollection.preferredContentSizeCategory.isAccessibilityCategory
    let count = isWide && bounds.width >= 560 ? (bounds.width >= 900 ? 3 : 2) : 1
    arrange(columns: count)
  }
  private func arrange(columns count: Int) {
    guard columns != count else { return }
    columns = count
    cards.forEach { $0.removeFromSuperview() }
    rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
    for start in stride(from: 0, to: cards.count, by: count) {
      let row = MobileUI.stack(Array(cards[start..<min(cards.count, start + count)]), axis: .horizontal, spacing: 12)
      row.distribution = .fillEqually
      rows.addArrangedSubview(row)
    }
    invalidateIntrinsicContentSize()
  }
}

struct MobileMonitorTrendPoint { let time: TimeInterval, value: Double?; let segment: UUID }
struct MobileMonitorTrendSeries { let name: String, color: UIColor, points: [MobileMonitorTrendPoint] }

/// Nil readings, time reversals and new collection segments each end a line.
@MainActor
final class MobileMonitorTrendView: UIView {
  private(set) var series: [MobileMonitorTrendSeries] = []
  private var minutes = 5
  private var end: TimeInterval = 0
  private var fixedMaximum: Double?
  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isAccessibilityElement = true
    contentMode = .redraw
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(minutes: Int, end: TimeInterval, fixedMaximum: Double?, series: [MobileMonitorTrendSeries]) {
    self.minutes = minutes; self.end = end; self.fixedMaximum = fixedMaximum; self.series = series
    accessibilityValue = series.map { line in
      let value = line.points.last?.value.map { fixedMaximum == nil ? MobileServerMonitorController.rate($0) : MobileServerMonitorController.percent($0) } ?? "暂无数据"
      return "\(line.name)：\(value)"
    }.joined(separator: "，")
    setNeedsDisplay()
  }

  func segments(for series: MobileMonitorTrendSeries) -> [[MobileMonitorTrendPoint]] {
    var result: [[MobileMonitorTrendPoint]] = [], current: [MobileMonitorTrendPoint] = []
    for point in series.points {
      guard let value = point.value, value.isFinite, value >= 0,
            point.time >= end - Double(minutes * 60), point.time <= end else {
        if !current.isEmpty { result.append(current); current = [] }
        continue
      }
      if let last = current.last, last.segment != point.segment || point.time <= last.time {
        result.append(current); current = []
      }
      current.append(point)
    }
    if !current.isEmpty { result.append(current) }
    return result
  }

  override func draw(_ rect: CGRect) {
    let font = UIFontMetrics(forTextStyle: .caption2).scaledFont(for: .systemFont(ofSize: 10), maximumPointSize: 15)
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.secondaryLabel]
    let visible = series.map { segments(for: $0) }
    let maximum = fixedMaximum ?? max(1, visible.flatMap { $0 }.flatMap { $0 }.compactMap(\.value).max() ?? 1)
    func axis(_ value: Double) -> String {
      fixedMaximum == nil ? MobileServerMonitorController.rate(value) : String(format: "%.0f%%", value)
    }
    let axisWidth = (axis(maximum) as NSString).size(withAttributes: attributes).width + 8
    let plot = CGRect(x: axisWidth, y: 8, width: max(1, bounds.width - axisWidth - 6), height: max(1, bounds.height - font.lineHeight - 24))
    for index in 0...4 {
      let fraction = CGFloat(index) / 4
      let y = plot.maxY - plot.height * fraction
      let line = UIBezierPath()
      line.move(to: CGPoint(x: plot.minX, y: y)); line.addLine(to: CGPoint(x: plot.maxX, y: y))
      UIColor.separator.withAlphaComponent(0.55).setStroke()
      line.lineWidth = 1 / max(1, traitCollection.displayScale); line.stroke()
      (axis(maximum * Double(fraction)) as NSString).draw(at: CGPoint(x: 0, y: y - font.lineHeight / 2), withAttributes: attributes)
    }
    ("\(minutes) 分钟前" as NSString).draw(at: CGPoint(x: plot.minX, y: plot.maxY + 8), withAttributes: attributes)
    let now = "现在" as NSString
    now.draw(at: CGPoint(x: plot.maxX - now.size(withAttributes: attributes).width, y: plot.maxY + 8), withAttributes: attributes)
    if visible.allSatisfy({ $0.isEmpty }) {
      let message = "等待有效采样" as NSString
      let size = message.size(withAttributes: attributes)
      message.draw(at: CGPoint(x: plot.midX - size.width / 2, y: plot.midY - size.height / 2), withAttributes: attributes)
    }
    guard let context = UIGraphicsGetCurrentContext() else { return }
    context.saveGState(); context.clip(to: plot.insetBy(dx: -2, dy: -2))
    for (index, line) in series.enumerated() {
      line.color.setStroke(); line.color.setFill()
      for segment in visible[index] {
        let path = UIBezierPath(); path.lineWidth = 2; path.lineJoinStyle = .round
        for (index, point) in segment.enumerated() {
          let x = plot.minX + CGFloat((point.time - end + Double(minutes * 60)) / Double(minutes * 60)) * plot.width
          let y = plot.maxY - CGFloat(min(1, point.value! / maximum)) * plot.height
          let position = CGPoint(x: x, y: y)
          if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
          if segment.count == 1 { UIBezierPath(ovalIn: CGRect(x: x - 2, y: y - 2, width: 4, height: 4)).fill() }
        }
        path.stroke()
      }
    }
    context.restoreGState()
  }
}
