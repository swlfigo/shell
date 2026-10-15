import AppKit
import Combine
import TermesKit
import SSHCore

@MainActor
final class ServerMonitorViewController: NSViewController {
  let model: ServerMonitorModel
  var onClose: (() -> Void)?
  var onRender: (() -> Void)?
  var showsCompactHeader = false
  let statusLabel = NSTextField(wrappingLabelWithString: "")
  let cpuLabel = NSTextField(wrappingLabelWithString: "")
  let memoryLabel = NSTextField(wrappingLabelWithString: "")
  let swapLabel = NSTextField(wrappingLabelWithString: "")
  let loadLabel = NSTextField(wrappingLabelWithString: "")
  let diskSummaryLabel = NSTextField(wrappingLabelWithString: "")
  let networkSummaryLabel = NSTextField(wrappingLabelWithString: "")
  let interfacePopup = NSPopUpButton()
  let rangeControl = NSSegmentedControl(labels: ["1 分钟", "5 分钟", "15 分钟"], trackingMode: .selectOne, target: nil, action: nil)
  let usageChart = MonitorTrendView()
  let networkChart = MonitorTrendView()
  private let serverName: String
  private let root = FileLayoutView()
  private let scroll = NSScrollView()
  private let document = FlippedFileView()
  private let heading = NSTextField(labelWithString: "")
  private let endpoint = NSTextField(labelWithString: "")
  private let updated = NSTextField(labelWithString: "")
  private let identity = NSTextField(wrappingLabelWithString: "")
  private let footer = NSTextField(wrappingLabelWithString: "约每 5 秒更新，历史保留 15 分钟。CPU 和网络速率需要相邻两次采样。")
  private lazy var usageCard = MonitorTrendCardView(title: "资源使用趋势", chart: usageChart, control: rangeControl, controlWidth: 190)
  private lazy var networkCard = MonitorTrendCardView(title: "网络流量", chart: networkChart, control: interfacePopup, controlWidth: 112)
  private let systemCard = MonitorDetailsCardView(title: "系统信息", rowHeight: 76)
  let diskDisclosureButton = NSButton(title: "显示全部", target: nil, action: nil)
  private lazy var disksCard = MonitorDetailsCardView(title: "磁盘分区", rowHeight: 60, headerControl: diskDisclosureButton)
  private(set) var displayedDisks: [ServerDiskUsage] = []
  private(set) var showsAllDisks = false
  private var disksNeedUpdate = true
  private let interfacesCard = MonitorDetailsCardView(title: "网络接口 · 相对服务器", rowHeight: 48)
  private var observer: AnyCancellable?, ticker: Task<Void, Never>?
  private var displayedSample: LinuxServerSample?
  private var selectedInterface: String?
  private var started = false
  private(set) var metricCards: [MonitorMetricCardView] = []
  private lazy var pauseButton = button("暂停", #selector(togglePause))
  private lazy var retryButton = button("重试", #selector(retry))
  private lazy var closeButton = button("关闭", #selector(closePanel))

  init(model: ServerMonitorModel, serverName: String) {
    self.model = model; self.serverName = serverName
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError("unsupported") }
  deinit { ticker?.cancel() }

  override func loadView() {
    view = root
    root.fillColor = MonitorColors.background
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
    scroll.documentView = document; root.addSubview(scroll)
    root.onLayout = { [weak self] in self?.layoutContent() }
    heading.stringValue = serverName; heading.font = .systemFont(ofSize: 20, weight: .semibold)
    heading.toolTip = "服务器监控 · \(serverName)"; heading.setAccessibilityLabel("服务器监控 · \(serverName)")
    for label in [heading, endpoint, updated] {
      label.lineBreakMode = .byTruncatingTail
    }
    for label in [endpoint, updated, footer] { label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor }
    statusLabel.font = .systemFont(ofSize: 12); statusLabel.maximumNumberOfLines = 4
    identity.font = .systemFont(ofSize: 12); identity.maximumNumberOfLines = 4
    rangeControl.selectedSegment = 1; rangeControl.target = self; rangeControl.action = #selector(rangeChanged)
    rangeControl.setAccessibilityLabel("监控趋势时间范围")
    interfacePopup.target = self; interfacePopup.action = #selector(interfaceChanged)
    interfacePopup.setAccessibilityLabel("网络趋势接口")
    diskDisclosureButton.bezelStyle = .rounded; diskDisclosureButton.controlSize = .small
    diskDisclosureButton.font = .systemFont(ofSize: 11); diskDisclosureButton.target = self; diskDisclosureButton.action = #selector(toggleDiskDetails)
    diskDisclosureButton.setAccessibilityLabel("展开或收起完整磁盘挂载列表")
    usageChart.setAccessibilityLabel("CPU 和内存趋势"); networkChart.setAccessibilityLabel("服务器网络速率趋势")
    for child in [heading, endpoint, statusLabel, updated, pauseButton, retryButton, closeButton,
                  usageCard, networkCard, systemCard, disksCard, interfacesCard, footer] { document.addSubview(child) }
    let metrics: [(NSTextField, String, String, NSColor)] = [
      (cpuLabel, "CPU", "cpu", .systemBlue), (memoryLabel, "内存", "memorychip", .systemPurple),
      (diskSummaryLabel, "磁盘", "internaldrive", .systemOrange), (networkSummaryLabel, "网络", "network", .systemGreen),
      (swapLabel, "Swap", "arrow.left.arrow.right", .systemTeal), (loadLabel, "负载", "waveform.path.ecg", .systemPink)]
    for (label, title, symbol, color) in metrics {
      let card = MonitorMetricCardView(title: title, symbol: symbol, color: color, valueLabel: label)
      metricCards.append(card); document.addSubview(card)
    }
    systemCard.setRows([identity])
    observer = model.objectWillChange.sink { [weak self] in
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.render() } }
    }
    render()
  }

  func start() {
    guard !started else { return }
    started = true; _ = view; model.open()
    ticker = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { break }
        guard self != nil else { break }
        self?.model.refreshTime(); self?.render()
      }
    }
  }
  func shutdown() { started = false; observer = nil; ticker?.cancel(); ticker = nil; model.close() }
  @objc func togglePause() { if model.isPaused { model.resume() } else { model.pause() }; render() }
  @objc func retry() { model.retry(); render() }
  @objc private func closePanel() { onClose?() }
  @objc func rangeChanged() { renderCharts() }
  @objc func interfaceChanged() { selectedInterface = interfacePopup.titleOfSelectedItem; render() }
  @objc func toggleDiskDetails() { showsAllDisks.toggle(); disksNeedUpdate = true; render() }
  private func button(_ title: String, _ action: Selector) -> NSButton {
    let result = NSButton(title: title, target: self, action: action); result.bezelStyle = .rounded; result.controlSize = .small
    return result
  }

  func render() {
    guard isViewLoaded else { return }
    endpoint.stringValue = model.destination.map { "\($0.username)@\($0.hostname):\($0.port)" } ?? ""
    endpoint.toolTip = endpoint.stringValue
    let message: String
    switch model.state {
    case .closed: message = "监控已关闭"
    case .disconnected: message = "SSH 已断开，等待重新连接"
    case .paused: message = "采样已暂停"
    case .connecting: message = "正在连接监控"
    case .sampling: message = "正在采集服务器状态"
    case .live: message = "服务器状态已更新"
    case .failed(let error): message = "\(error)\n稍后自动重试"
    case .unavailable(let error): message = error
    }
    statusLabel.stringValue = message + (model.current != nil && model.isStale ? "\n上次数据已过期" : "")
    statusLabel.textColor = model.isStale && model.current != nil ? .systemOrange : .secondaryLabelColor
    updated.stringValue = model.current.map { "采样时间：" + $0.sample.capturedAt.formatted(date: .omitted, time: .standard) } ?? "尚无采样数据"
    pauseButton.title = model.isPaused ? "恢复" : "暂停"; pauseButton.isEnabled = model.isOpen
    retryButton.isEnabled = model.isOpen && model.isConnected && !model.isPaused
    if let snapshot = model.current {
      let sample = snapshot.sample
      metricCards[0].update(value: Self.describe(snapshot.cpu) { Self.percent($0.totalPercent) },
        detail: snapshot.cpu.value.map { "用户 \(Self.percent($0.userPercent))\n系统 \(Self.percent($0.systemPercent))" } ?? "需要相邻两次采样",
        usage: snapshot.cpu.value?.totalPercent, prominent: snapshot.cpu.value != nil)
      metricCards[1].update(value: Self.describe(sample.memory) { Self.percent($0.usagePercent) },
        detail: sample.memory.value.map { "\(Self.bytes($0.usedBytes)) / \(Self.bytes($0.totalBytes))" } ?? "服务器物理内存",
        usage: sample.memory.value?.usagePercent, prominent: sample.memory.value?.usagePercent != nil)
      let disk = sample.disks.value.flatMap { $0.first(where: { $0.mountPoint == "/" }) ?? ServerDiskPresentation.visible($0, showAll: false).first ?? $0.first }
      metricCards[2].update(value: disk.map { Self.describe($0.usagePercent, format: Self.percent) }
          ?? Self.describe(sample.disks) { _ in "无分区" },
        detail: disk.map { "分区 \($0.mountPoint)\n\(Self.bytes($0.usedBytes)) / \(Self.bytes($0.totalBytes))" } ?? "主要磁盘分区",
        usage: disk?.usagePercent.value, prominent: disk?.usagePercent.value != nil)
      metricCards[4].update(value: Self.describe(sample.swap) { $0.totalBytes == 0 ? "未配置" : Self.percent($0.usagePercent) },
        detail: sample.swap.value.map { $0.totalBytes == 0 ? "服务器未配置交换空间" : "\(Self.bytes($0.usedBytes)) / \(Self.bytes($0.totalBytes))" } ?? "交换空间",
        usage: sample.swap.value?.usagePercent, prominent: sample.swap.value?.usagePercent != nil)
      metricCards[5].update(value: Self.describe(sample.load) { String(format: "%.2f", $0.oneMinute) },
        detail: sample.load.value.map { String(format: "1 分钟平均负载\n5 分钟 %.2f · 15 分钟 %.2f", $0.fiveMinutes, $0.fifteenMinutes) } ?? "1 / 5 / 15 分钟平均负载",
        prominent: sample.load.value != nil)
      identity.stringValue = "\(Self.describe(sample.identity.operatingSystem) { $0 }) · \(Self.describe(sample.identity.architecture) { $0 })\n主机：\(Self.describe(sample.identity.hostname) { $0 })\n内核：\(Self.describe(sample.identity.kernelRelease) { $0 })\n运行：\(Self.describe(sample.uptime, format: Self.uptime))"
      identity.toolTip = identity.stringValue
      if displayedSample != sample || disksNeedUpdate {
        disksNeedUpdate = false
        if let all = sample.disks.value {
          displayedDisks = ServerDiskPresentation.visible(all, showAll: showsAllDisks)
          disksCard.setRows(displayedDisks.isEmpty ? Self.labels(["无实际存储分区，可展开查看全部挂载。"], lines: 3) : displayedDisks.map { MonitorDiskRowView(disk: $0) })
          let hidden = all.count - ServerDiskPresentation.visible(all, showAll: false).count
          diskDisclosureButton.isHidden = hidden == 0
          diskDisclosureButton.title = showsAllDisks ? "收起详情" : "显示全部（\(all.count)）"
        } else {
          displayedDisks = []; diskDisclosureButton.isHidden = true
          disksCard.setRows(Self.labels(Self.describeList(sample.disks) { _ in "" }, lines: 3))
        }
      }
      if displayedSample != sample {
        displayedSample = sample
        let networkTexts = Self.describeList(snapshot.network) { "\($0.name)\n↓ \(Self.describe($0.receivedBytesPerSecond, format: Self.rate))  ↑ \(Self.describe($0.transmittedBytesPerSecond, format: Self.rate))" }
        interfacesCard.setRows(Self.labels(networkTexts, lines: 3))
        let names = snapshot.network.value?.map(\.name) ?? []
        if selectedInterface == nil || !names.contains(selectedInterface!) { selectedInterface = names.first { $0 != "lo" } ?? names.first }
        interfacePopup.removeAllItems(); interfacePopup.addItems(withTitles: names)
        if let selectedInterface { interfacePopup.selectItem(withTitle: selectedInterface) }
        interfacePopup.isEnabled = !names.isEmpty
      }
      let network = snapshot.network.value?.first { $0.name == selectedInterface }
      if let network {
        let down = Self.describe(network.receivedBytesPerSecond, format: Self.rate)
        let up = Self.describe(network.transmittedBytesPerSecond, format: Self.rate)
        let hasRates = network.receivedBytesPerSecond.value != nil && network.transmittedBytesPerSecond.value != nil
        metricCards[3].update(value: hasRates ? "↓ \(down)\n↑ \(up)" : (down == up ? down : "↓ \(down)\n↑ \(up)"),
          detail: "\(network.name) · 接收 ↓ / 发送 ↑", prominent: hasRates, valueSize: 18)
      } else {
        metricCards[3].update(value: Self.describe(snapshot.network) { _ in "无接口" }, detail: "相对服务器的网络速率")
      }
    } else {
      identity.stringValue = "系统信息等待采样"
      metricCards.forEach { $0.update(value: "等待采样", detail: "尚无服务器数据") }
      displayedSample = nil; selectedInterface = nil; interfacePopup.removeAllItems(); interfacePopup.isEnabled = false
      displayedDisks = []; diskDisclosureButton.isHidden = true
      disksCard.setRows(Self.labels(["等待采样"], lines: 3)); interfacesCard.setRows(Self.labels(["等待采样"], lines: 3))
    }
    renderCharts(); layoutContent(); onRender?()
  }

  private static func labels(_ texts: [String], lines: Int) -> [NSTextField] {
    texts.map {
      let label = NSTextField(wrappingLabelWithString: $0); label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
      label.maximumNumberOfLines = lines; label.lineBreakMode = .byTruncatingTail; label.toolTip = $0
      return label
    }
  }
  private func renderCharts() {
    let minutes = [1, 5, 15][max(0, min(2, rangeControl.selectedSegment))]
    let points = model.points(minutes: minutes)
    let end = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    usageChart.configure(minutes: minutes, end: end, fixedMaximum: 100, series: [
      .init(name: "CPU", color: .systemBlue, points: points.map { .init(time: $0.monotonicTime, value: $0.cpuPercent, segment: $0.segment) }),
      .init(name: "内存", color: .systemPurple, points: points.map { .init(time: $0.monotonicTime, value: $0.memoryPercent, segment: $0.segment) })])
    networkChart.configure(minutes: minutes, end: end, fixedMaximum: nil, series: [
      .init(name: "接收 ↓", color: .systemGreen, points: points.map { point in .init(time: point.monotonicTime, value: point.network.first { $0.name == selectedInterface }?.receivedBytesPerSecond.value, segment: point.segment) }),
      .init(name: "发送 ↑", color: .systemBlue, points: points.map { point in .init(time: point.monotonicTime, value: point.network.first { $0.name == selectedInterface }?.transmittedBytesPerSecond.value, segment: point.segment) })])
  }
  private func layoutContent() {
    guard isViewLoaded else { return }
    scroll.frame = root.bounds
    let width = max(320, scroll.contentSize.width), inner = width - 32
    var y: CGFloat = 16
    func row(_ child: NSView, height: CGFloat, gap: CGFloat = 12) {
      child.frame = NSRect(x: 16, y: y, width: inner, height: height); y += height + gap; child.needsLayout = true
    }
    heading.isHidden = showsCompactHeader; endpoint.isHidden = showsCompactHeader; closeButton.isHidden = showsCompactHeader
    if !showsCompactHeader { row(heading, height: 26, gap: 4); row(endpoint, height: 18, gap: 10) }
    for (index, control) in [pauseButton, retryButton, closeButton].enumerated() {
      control.frame = NSRect(x: 16 + CGFloat(index) * 76, y: y, width: 70, height: 24)
    }
    y += 34
    let statusHeight = statusLabel.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: inner, height: 1000)).height ?? 20
    row(statusLabel, height: min(64, max(20, ceil(statusHeight))), gap: 4)
    row(updated, height: 16, gap: 16)
    let columns = inner >= 620 ? 3 : 2
    let cardWidth = (inner - CGFloat(columns - 1) * 12) / CGFloat(columns)
    func cards(_ indices: Range<Int>) {
      let height: CGFloat = showsCompactHeader ? 142 : 164, stride = height + 12
      for (position, index) in indices.enumerated() {
        let card = metricCards[index]; card.isCompact = showsCompactHeader
        card.frame = NSRect(x: 16 + CGFloat(position % columns) * (cardWidth + 12), y: y + CGFloat(position / columns) * stride, width: cardWidth, height: height)
        card.needsLayout = true
      }
      y += CGFloat((indices.count + columns - 1) / columns) * stride
    }
    cards(0..<(showsCompactHeader ? 4 : metricCards.count))
    row(usageCard, height: usageCard.preferredHeight(width: inner))
    row(networkCard, height: networkCard.preferredHeight(width: inner))
    if showsCompactHeader { cards(4..<metricCards.count) }
    row(systemCard, height: systemCard.preferredHeight)
    row(disksCard, height: disksCard.preferredHeight)
    row(interfacesCard, height: interfacesCard.preferredHeight)
    row(footer, height: 42)
    document.frame = NSRect(x: 0, y: 0, width: width, height: y + 4)
  }
  private static func describe<T: Equatable & Sendable>(_ metric: ServerMetric<T>, format: (T) -> String) -> String {
    switch metric { case .value(let value): return format(value); case .unavailable(let reason): return reasonText(reason) }
  }
  private static func describeList<T: Equatable & Sendable>(_ metric: ServerMetric<[T]>, format: (T) -> String) -> [String] {
    switch metric { case .value(let list): return list.isEmpty ? ["无条目"] : list.map(format); case .unavailable(let reason): return [reasonText(reason)] }
  }
  fileprivate static func reasonText(_ reason: ServerMetricUnavailable) -> String {
    switch reason {
    case .missingData: return "数据缺失"
    case .commandFailed: return "读取失败"
    case .invalidData: return "数据格式无效"
    case .limitExceeded: return "数据超过限制"
    case .waitingForBaseline: return "等待下一次采样"
    case .counterReset: return "计数重置，等待采样"
    case .invalidInterval: return "采样间隔无效"
    }
  }
  fileprivate static func percent(_ number: Double?) -> String { number.map { String(format: "%.1f%%", $0) } ?? "不可用" }
  fileprivate static func bytes(_ number: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: number), countStyle: .binary) }
  fileprivate static func rate(_ number: Double) -> String {
    let units = ["B/s", "KB/s", "MB/s", "GB/s", "TB/s", "PB/s"]
    var value = number, index = 0
    while value >= 1024, index < units.count - 1 { value /= 1024; index += 1 }
    return String(format: index == 0 && (value == 0 || value >= 1) ? "%.0f %@" : "%.1f %@", value, units[index])
  }
  private static func uptime(_ number: Double) -> String {
    let minutes = Int(min(Double(Int.max - 1024), number / 60))
    return "\(minutes / 1440) 天 \(minutes % 1440 / 60) 小时 \(minutes % 60) 分钟"
  }
}

struct MonitorTrendPoint { let time: TimeInterval, value: Double?; let segment: UUID }
struct MonitorTrendSeries { let name: String, color: NSColor, points: [MonitorTrendPoint] }

/// Nil values and a changed segment each end a line. A disconnection is never drawn as a zero.
final class MonitorTrendView: NSView {
  private(set) var series: [MonitorTrendSeries] = []
  private var minutes = 5, end: TimeInterval = 0
  private var fixedMaximum: Double?
  func configure(minutes: Int, end: TimeInterval, fixedMaximum: Double?, series: [MonitorTrendSeries]) {
    self.minutes = minutes; self.end = end; self.fixedMaximum = fixedMaximum; self.series = series
    setAccessibilityValue(series.map { "\($0.name)：\($0.points.last?.value.map { String(format: "%.1f", $0) } ?? "暂无数据")" }.joined(separator: "，"))
    needsDisplay = true
  }
  func segments(for series: MonitorTrendSeries) -> [[MonitorTrendPoint]] {
    var result: [[MonitorTrendPoint]] = [], current: [MonitorTrendPoint] = []
    for point in series.points {
      guard let value = point.value, value.isFinite, value >= 0, point.time >= end - Double(minutes * 60), point.time <= end else {
        if !current.isEmpty { result.append(current); current = [] }; continue
      }
      if let last = current.last, last.segment != point.segment || point.time <= last.time { result.append(current); current = [] }
      current.append(point)
    }
    if !current.isEmpty { result.append(current) }
    return result
  }
  override func draw(_ dirtyRect: NSRect) {
    let plot = NSRect(x: 46, y: 25, width: max(1, bounds.width - 58), height: max(1, bounds.height - 50))
    let maximum = fixedMaximum ?? max(1, series.flatMap(\.points).compactMap(\.value).filter { $0.isFinite }.max() ?? 1)
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.secondaryLabelColor]
    for index in 0...4 {
      let y = plot.minY + plot.height * Double(index) / 4
      let path = NSBezierPath(); path.move(to: .init(x: plot.minX, y: y)); path.line(to: .init(x: plot.maxX, y: y))
      NSColor.separatorColor.setStroke(); path.stroke()
      let value = maximum * Double(index) / 4
      let text = fixedMaximum == nil ? ServerMonitorViewController.rate(value) : String(format: "%.0f%%", value)
      (text as NSString).draw(at: .init(x: 2, y: y - 5), withAttributes: attrs)
    }
    ("\(minutes) 分钟前" as NSString).draw(at: .init(x: plot.minX, y: 5), withAttributes: attrs)
    ("现在" as NSString).draw(at: .init(x: plot.maxX - 22, y: 5), withAttributes: attrs)
    for (index, line) in series.enumerated() {
      (line.name as NSString).draw(at: .init(x: plot.minX + CGFloat(index) * 80, y: bounds.height - 17),
        withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: line.color])
      line.color.setStroke(); line.color.setFill()
      for segment in segments(for: line) {
        let path = NSBezierPath(); path.lineWidth = 1.5
        for (index, point) in segment.enumerated() {
          let position = NSPoint(x: plot.minX + (point.time - end + Double(minutes * 60)) / Double(minutes * 60) * plot.width,
            y: plot.minY + min(1, point.value! / maximum) * plot.height)
          if index == 0 { path.move(to: position) } else { path.line(to: position) }
          if segment.count == 1 { NSBezierPath(ovalIn: NSRect(x: position.x - 2, y: position.y - 2, width: 4, height: 4)).fill() }
        }
        path.stroke()
      }
    }
  }
}

enum MonitorColors {
  static let background = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      ? NSColor(srgbRed: 0.085, green: 0.09, blue: 0.10, alpha: 1)
      : NSColor(srgbRed: 0.95, green: 0.96, blue: 0.97, alpha: 1)
  }
  static let card = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      ? NSColor(srgbRed: 0.13, green: 0.14, blue: 0.15, alpha: 1)
      : NSColor.white
  }
}

class MonitorCardView: ChromeView {
  override var isFlipped: Bool { true }
  override init(frame: NSRect) {
    super.init(frame: frame)
    fillColor = MonitorColors.card
    layer?.cornerRadius = 18
  }
  required init?(coder: NSCoder) { fatalError("unsupported") }
}

final class MonitorMetricCardView: MonitorCardView {
  var isCompact = false
  let titleLabel: NSTextField
  let valueLabel: NSTextField
  let detailLabel = NSTextField(wrappingLabelWithString: "")
  let usageBar = MonitorUsageBarView()
  private let badge = ChromeView(frame: .zero)
  private let icon = NSImageView()
  init(title: String, symbol: String, color: NSColor, valueLabel: NSTextField) {
    titleLabel = NSTextField(labelWithString: title); self.valueLabel = valueLabel
    super.init(frame: .zero)
    titleLabel.font = .systemFont(ofSize: 12, weight: .medium); titleLabel.textColor = .secondaryLabelColor
    titleLabel.lineBreakMode = .byTruncatingTail
    valueLabel.maximumNumberOfLines = 2; valueLabel.lineBreakMode = .byTruncatingTail
    valueLabel.setAccessibilityLabel(title)
    detailLabel.font = .systemFont(ofSize: 11); detailLabel.textColor = .secondaryLabelColor
    detailLabel.maximumNumberOfLines = 3; detailLabel.lineBreakMode = .byWordWrapping
    detailLabel.setAccessibilityLabel("\(title)补充信息")
    badge.fillColor = color.withAlphaComponent(0.12); badge.layer?.cornerRadius = 9
    icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    icon.contentTintColor = color; icon.imageScaling = .scaleProportionallyDown; icon.setAccessibilityElement(false)
    badge.addSubview(icon); usageBar.color = color
    for child in [badge, titleLabel, valueLabel, detailLabel, usageBar] { addSubview(child) }
  }
  required init?(coder: NSCoder) { fatalError("unsupported") }
  func update(value: String, detail: String, usage: Double? = nil, prominent: Bool = false, valueSize: CGFloat = 26) {
    valueLabel.stringValue = value; detailLabel.stringValue = detail
    valueLabel.font = prominent ? .monospacedDigitSystemFont(ofSize: valueSize, weight: .semibold) : .systemFont(ofSize: 13, weight: .medium)
    valueLabel.textColor = prominent ? .labelColor : .secondaryLabelColor
    toolTip = "\(titleLabel.stringValue)\n\(value)\n\(detail)"
    valueLabel.toolTip = toolTip; detailLabel.toolTip = detail
    usageBar.setUsage(usage); needsLayout = true
  }
  override func layout() {
    super.layout()
    if isCompact {
      badge.frame = NSRect(x: 12, y: 12, width: 20, height: 20)
      icon.frame = NSRect(x: 2, y: 2, width: 16, height: 16)
      titleLabel.frame = NSRect(x: 40, y: 13, width: max(0, bounds.width - 52), height: 18)
      valueLabel.frame = NSRect(x: 12, y: 38, width: max(0, bounds.width - 24), height: 50)
      detailLabel.frame = NSRect(x: 12, y: 92, width: max(0, bounds.width - 24), height: 30)
      usageBar.frame = NSRect(x: 12, y: 130, width: max(0, bounds.width - 24), height: 4)
      return
    }
    let inner = max(0, bounds.width - 32)
    badge.frame = NSRect(x: 16, y: 14, width: 28, height: 28)
    icon.frame = NSRect(x: 6, y: 6, width: 16, height: 16)
    titleLabel.frame = NSRect(x: 54, y: 20, width: max(0, bounds.width - 70), height: 18)
    valueLabel.frame = NSRect(x: 16, y: 54, width: inner, height: 44)
    detailLabel.frame = NSRect(x: 16, y: 102, width: inner, height: 42)
    usageBar.frame = NSRect(x: 16, y: 148, width: inner, height: 4)
  }
}

final class MonitorUsageBarView: NSView {
  var color: NSColor = .systemBlue
  private(set) var usage: Double?
  func setUsage(_ value: Double?) {
    usage = value.flatMap { $0.isFinite ? min(100, max(0, $0)) : nil }
    isHidden = usage == nil; needsDisplay = true
    setAccessibilityLabel("使用率"); setAccessibilityValue(usage.map { String(format: "%.1f%%", $0) } ?? "不可用")
  }
  override func draw(_ dirtyRect: NSRect) {
    guard let usage else { return }
    NSColor.quaternaryLabelColor.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2).fill()
    color.setFill()
    NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: bounds.width * usage / 100, height: bounds.height), xRadius: 2, yRadius: 2).fill()
  }
}

private final class MonitorTrendCardView: MonitorCardView {
  private let title: NSTextField
  private let chart: MonitorTrendView
  private let control: NSControl
  private let controlWidth: CGFloat
  init(title: String, chart: MonitorTrendView, control: NSControl, controlWidth: CGFloat) {
    self.title = NSTextField(labelWithString: title); self.chart = chart; self.control = control; self.controlWidth = controlWidth
    super.init(frame: .zero)
    self.title.font = .systemFont(ofSize: 14, weight: .semibold); self.title.lineBreakMode = .byTruncatingTail
    for child in [self.title, chart, control] { addSubview(child) }
  }
  required init?(coder: NSCoder) { fatalError("unsupported") }
  private func stacksControl(width: CGFloat) -> Bool { width - 32 < controlWidth + 160 }
  func preferredHeight(width: CGFloat) -> CGFloat { stacksControl(width: width) ? 250 : 218 }
  override func layout() {
    super.layout()
    let inner = max(0, bounds.width - 32), stacked = stacksControl(width: bounds.width)
    title.frame = NSRect(x: 16, y: 17, width: stacked ? inner : inner - controlWidth - 12, height: 22)
    control.frame = NSRect(x: stacked ? 16 : bounds.width - 16 - controlWidth, y: stacked ? 46 : 14, width: controlWidth, height: 26)
    let top: CGFloat = stacked ? 82 : 50
    chart.frame = NSRect(x: 12, y: top, width: max(0, bounds.width - 24), height: max(0, bounds.height - top - 12))
    chart.needsDisplay = true
  }
}

private final class MonitorDetailsCardView: MonitorCardView {
  private let title: NSTextField
  private let rowHeight: CGFloat
  private var rows: [NSView] = []
  private let headerControl: NSControl?
  var preferredHeight: CGFloat { 52 + CGFloat(rows.count) * rowHeight }
  init(title: String, rowHeight: CGFloat, headerControl: NSControl? = nil) {
    self.title = NSTextField(labelWithString: title); self.rowHeight = rowHeight; self.headerControl = headerControl
    super.init(frame: .zero)
    self.title.font = .systemFont(ofSize: 14, weight: .semibold); self.title.lineBreakMode = .byTruncatingTail
    addSubview(self.title)
    if let headerControl { addSubview(headerControl) }
  }
  required init?(coder: NSCoder) { fatalError("unsupported") }
  func setRows(_ rows: [NSView]) {
    self.rows.forEach { $0.removeFromSuperview() }; self.rows = rows
    rows.forEach { addSubview($0) }; needsLayout = true; needsDisplay = true
  }
  override func layout() {
    super.layout()
    let controlWidth: CGFloat = headerControl?.isHidden == false ? 144 : 0
    title.frame = NSRect(x: 16, y: 16, width: max(0, bounds.width - 32 - controlWidth), height: 22)
    headerControl?.frame = NSRect(x: bounds.width - 16 - controlWidth, y: 14, width: controlWidth, height: 26)
    for (index, row) in rows.enumerated() {
      row.frame = NSRect(x: 16, y: 48 + CGFloat(index) * rowHeight, width: max(0, bounds.width - 32), height: rowHeight - 10)
    }
  }
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    NSColor.separatorColor.setStroke()
    for index in rows.indices.dropFirst() {
      let y = 43 + CGFloat(index) * rowHeight
      let path = NSBezierPath(); path.move(to: .init(x: 16, y: y)); path.line(to: .init(x: bounds.width - 16, y: y)); path.stroke()
    }
  }
}

private final class MonitorDiskRowView: NSView {
  private let mount = NSTextField(labelWithString: "")
  private let usage = NSTextField(labelWithString: "")
  private let capacity = NSTextField(labelWithString: "")
  private let bar = MonitorUsageBarView()
  override var isFlipped: Bool { true }
  init(disk: ServerDiskUsage) {
    super.init(frame: .zero)
    mount.stringValue = disk.mountPoint; mount.font = .systemFont(ofSize: 12, weight: .medium); mount.lineBreakMode = .byTruncatingMiddle
    switch disk.usagePercent {
    case .value(let value): usage.stringValue = ServerMonitorViewController.percent(value); bar.setUsage(value)
    case .unavailable(let reason): usage.stringValue = "—"; bar.setUsage(nil); usage.toolTip = ServerMonitorViewController.reasonText(reason)
    }
    usage.alignment = .right; usage.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium); usage.textColor = .systemOrange
    capacity.stringValue = "\(ServerMonitorViewController.bytes(disk.usedBytes)) / \(ServerMonitorViewController.bytes(disk.totalBytes))"
    capacity.font = .systemFont(ofSize: 11); capacity.textColor = .secondaryLabelColor
    toolTip = "\(disk.mountPoint) · \(disk.filesystem)\n\(capacity.stringValue)\n可用 \(ByteCountFormatter.string(fromByteCount: disk.availableBytes, countStyle: .binary))"
    mount.toolTip = toolTip; capacity.toolTip = toolTip; bar.color = .systemOrange
    for child in [mount, usage, capacity, bar] { addSubview(child) }
  }
  required init?(coder: NSCoder) { fatalError("unsupported") }
  override func layout() {
    super.layout()
    mount.frame = NSRect(x: 0, y: 0, width: max(0, bounds.width - 66), height: 18)
    usage.frame = NSRect(x: max(0, bounds.width - 62), y: 0, width: 62, height: 18)
    capacity.frame = NSRect(x: 0, y: 21, width: bounds.width, height: 16)
    bar.frame = NSRect(x: 0, y: 43, width: bounds.width, height: 4)
  }
}

/// Wide panes keep the inspector beside the terminal; narrow panes stack it below.
final class TerminalMonitorView: NSView {
  let workspace: NSView, monitor: NSView
  init(workspace: NSView, monitor: NSView) {
    self.workspace = workspace; self.monitor = monitor
    super.init(frame: .zero)
    for child in [workspace, monitor] { child.translatesAutoresizingMaskIntoConstraints = true; child.autoresizingMask = []; addSubview(child) }
  }
  required init?(coder: NSCoder) { fatalError("unsupported") }
  override func layout() {
    super.layout()
    if bounds.width >= 880 {
      let width = min(440, max(360, bounds.width * 0.3))
      workspace.frame = NSRect(x: 0, y: 0, width: bounds.width - width - 1, height: bounds.height)
      monitor.frame = NSRect(x: bounds.width - width, y: 0, width: width, height: bounds.height)
    } else {
      let height = bounds.height * 0.5
      monitor.frame = NSRect(x: 0, y: 0, width: bounds.width, height: height)
      workspace.frame = NSRect(x: 0, y: height + 1, width: bounds.width, height: max(0, bounds.height - height - 1))
    }
    workspace.needsLayout = true; monitor.needsLayout = true
  }
}
