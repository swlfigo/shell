import AppKit
import SnapKit

enum SessionTool: Int { case overview, files }

/// A single inspector for a session. Switching tabs only hides views; it does not close
/// SFTP, reset a directory or interrupt monitoring and transfers.
@MainActor
final class SessionToolsView: ChromeView {
  let tabControl = NSSegmentedControl(labels: ["概览", "文件"], trackingMode: .selectOne, target: nil, action: nil)
  let collapseButton = NSButton()
  private let title = NSTextField(labelWithString: "工具")
  private let summaryStatus = NSTextField(labelWithString: "等待采样")
  private let body = NSView()
  private var contentConstraints: [ObjectIdentifier: [Constraint]] = [:]
  private var constraintLayout: (tool: SessionTool, compact: Bool)?
  private(set) var selectedTool = SessionTool.overview
  private(set) var overview: NSView?
  private(set) var files: NSView?
  private(set) var summaryCards: [CompactMonitorMetricView] = []
  var usesCompactLayout = false { didSet { if usesCompactLayout != oldValue { updateLayoutConstraints() } } }
  var onSelect: ((SessionTool) -> Void)?
  var onCollapse: (() -> Void)?
  override var isFlipped: Bool { true }

  override init(frame: NSRect) {
    // This scroll document is mounted before the inspector receives its first layout.
    // Keep room for the controls while the outer split is temporarily zero sized.
    super.init(frame: NSRect(origin: frame.origin,
      size: NSSize(width: max(240, frame.width), height: max(320, frame.height))))
    fillColor = MonitorColors.background
    title.font = .systemFont(ofSize: 14, weight: .semibold)
    tabControl.selectedSegment = 0; tabControl.target = self; tabControl.action = #selector(tabChanged)
    tabControl.segmentDistribution = .fillEqually
    tabControl.setAccessibilityLabel("服务器工具：概览或文件")
    collapseButton.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: nil)
    collapseButton.isBordered = false; collapseButton.target = self; collapseButton.action = #selector(collapse)
    collapseButton.toolTip = "收起工具，保留当前目录、传输任务和监控"
    collapseButton.setAccessibilityLabel("收起服务器工具面板")
    summaryStatus.font = .systemFont(ofSize: 10); summaryStatus.textColor = .secondaryLabelColor
    summaryStatus.lineBreakMode = .byTruncatingTail
    for (name, color) in [("CPU", NSColor.systemBlue), ("内存", .systemPurple), ("磁盘", .systemOrange), ("网络", .systemGreen)] {
      let card = CompactMonitorMetricView(title: name, color: color)
      summaryCards.append(card); addSubview(card)
    }
    for child in [title, collapseButton, tabControl, summaryStatus, body] { addSubview(child) }
    collapseButton.snp.makeConstraints { make in
      make.trailing.equalToSuperview().inset(12)
      make.top.equalToSuperview().offset(8)
      make.size.equalTo(NSSize(width: 24, height: 28))
    }
    for (index, card) in summaryCards.enumerated() {
      card.snp.makeConstraints { make in
        make.top.equalToSuperview().offset(80)
        make.height.equalTo(64)
        if index == 0 { make.leading.equalToSuperview().offset(12) }
        else {
          make.leading.equalTo(summaryCards[index - 1].snp.trailing).offset(6)
          make.width.equalTo(summaryCards[0].snp.width)
        }
        if index == summaryCards.count - 1 { make.trailing.equalToSuperview().inset(12) }
      }
    }
    summaryStatus.snp.makeConstraints { make in
      make.leading.trailing.equalToSuperview().inset(12)
      make.top.equalTo(summaryCards[0].snp.bottom).offset(4)
      make.height.equalTo(14)
    }
    body.snp.makeConstraints { make in
      make.leading.trailing.bottom.equalToSuperview()
      make.top.equalToSuperview().offset(80).labeled("Tools.bodyTop")
    }
    select(.overview)
  }
  required init?(coder: NSCoder) { fatalError("unsupported") }

  func setContents(overview: NSView?, files: NSView?) {
    if self.overview !== overview {
      if let previous = self.overview { detach(previous) }
      self.overview = overview
      if let overview { attach(overview) }
    }
    if self.files !== files {
      if let previous = self.files { detach(previous) }
      self.files = files
      if let files { attach(files) }
    }
    select(selectedTool)
  }
  private func attach(_ child: NSView) {
    body.addSubview(child)
    let constraints = child.snp.prepareConstraints { make in make.edges.equalToSuperview().labeled("Tools.content") }
    contentConstraints[ObjectIdentifier(child)] = constraints
    constraints.forEach { $0.activate() }
  }
  private func detach(_ child: NSView) {
    contentConstraints.removeValue(forKey: ObjectIdentifier(child))?.forEach { $0.deactivate() }
    child.removeFromSuperview()
  }
  func select(_ tool: SessionTool) {
    selectedTool = tool; tabControl.selectedSegment = tool.rawValue
    overview?.isHidden = tool != .overview; files?.isHidden = tool != .files
    summaryCards.forEach { $0.isHidden = tool != .files }; summaryStatus.isHidden = tool != .files
    updateLayoutConstraints()
  }
  func updateSummary(from monitor: ServerMonitorViewController?) {
    guard let monitor else {
      summaryStatus.stringValue = "监控已关闭"
      summaryStatus.textColor = .secondaryLabelColor
      summaryCards.forEach { $0.update(value: "—", detail: "监控已关闭") }
      return
    }
    summaryStatus.stringValue = monitor.statusLabel.stringValue.replacingOccurrences(of: "\n", with: " · ")
    summaryStatus.textColor = monitor.model.isStale && monitor.model.current != nil ? .systemOrange : .secondaryLabelColor
    summaryStatus.toolTip = monitor.statusLabel.stringValue
    for (index, card) in summaryCards.enumerated() where monitor.metricCards.indices.contains(index) {
      let source = monitor.metricCards[index], value = source.valueLabel.stringValue
      let isMeasured = index == 3 ? value.hasPrefix("↓") && value.contains("/s") : source.usageBar.usage != nil
      card.update(value: isMeasured ? value : "—", detail: "\(source.toolTip ?? value)\n\(summaryStatus.stringValue)")
    }
  }
  @objc private func tabChanged() {
    guard let tool = SessionTool(rawValue: tabControl.selectedSegment) else { return }
    onSelect?(tool)
  }
  @objc private func collapse() { onCollapse?() }
  private func updateLayoutConstraints() {
    guard constraintLayout?.tool != selectedTool || constraintLayout?.compact != usesCompactLayout else { return }
    constraintLayout = (selectedTool, usesCompactLayout)
    title.snp.remakeConstraints { make in
      make.leading.equalToSuperview().offset(12)
      make.top.equalToSuperview().offset(12)
      make.height.equalTo(20)
      if usesCompactLayout { make.width.equalTo(36) }
      else { make.trailing.equalToSuperview().inset(56) }
    }
    tabControl.snp.remakeConstraints { make in
      make.leading.equalToSuperview().offset(usesCompactLayout ? 58 : 12)
      make.trailing.equalToSuperview().inset(usesCompactLayout ? 46 : 12)
      make.top.equalToSuperview().offset(usesCompactLayout ? 8 : 42)
      make.height.equalTo(28)
    }
    let top: CGFloat = usesCompactLayout ? 44 : 80
    let height: CGFloat = usesCompactLayout ? 56 : 64
    for card in summaryCards {
      card.snp.updateConstraints { make in
        make.top.equalToSuperview().offset(top)
        make.height.equalTo(height)
      }
    }
    body.snp.updateConstraints { make in
      make.top.equalToSuperview().offset(top + (selectedTool == .files ? height + 24 : 0))
    }
    needsLayout = true
  }
}

final class CompactMonitorMetricView: ChromeView {
  let titleLabel: NSTextField
  let valueLabel = NSTextField(wrappingLabelWithString: "—")
  private var valueTop: Constraint?
  override var isFlipped: Bool { true }
  init(title: String, color: NSColor) {
    titleLabel = NSTextField(labelWithString: title)
    super.init(frame: NSRect(x: 0, y: 0, width: 50, height: 64))
    fillColor = MonitorColors.card; layer?.cornerRadius = 9
    titleLabel.font = .systemFont(ofSize: 10, weight: .medium); titleLabel.textColor = .secondaryLabelColor
    valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium); valueLabel.textColor = color
    valueLabel.maximumNumberOfLines = 2; valueLabel.lineBreakMode = .byTruncatingTail
    valueLabel.setAccessibilityLabel(title)
    for label in [titleLabel, valueLabel] {
      label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    addSubview(titleLabel); addSubview(valueLabel)
    titleLabel.snp.makeConstraints { make in
      make.leading.trailing.equalToSuperview().inset(8)
      make.top.equalToSuperview().offset(7)
      make.height.equalTo(14)
    }
    valueLabel.snp.makeConstraints { make in
      make.leading.trailing.equalToSuperview().inset(8)
      valueTop = make.top.equalToSuperview().offset(26).constraint
      make.bottom.equalToSuperview().inset(4)
    }
  }
  required init?(coder: NSCoder) { fatalError("unsupported") }
  func update(value: String, detail: String) { valueLabel.stringValue = value; toolTip = detail; valueLabel.toolTip = detail }
  override func layout() {
    valueTop?.update(offset: bounds.height < 64 ? 23 : 26)
    super.layout()
  }
}

/// The inspector is independently scrollable at the minimum split-pane size.
final class SessionToolsScrollView: NSScrollView {
  let tools: SessionToolsView
  init(tools: SessionToolsView) {
    self.tools = tools
    super.init(frame: .zero)
    drawsBackground = false; hasVerticalScroller = true; hasHorizontalScroller = true; autohidesScrollers = true
    documentView = tools
  }
  required init?(coder: NSCoder) { fatalError("unsupported") }
  override func layout() {
    super.layout()
    tools.usesCompactLayout = contentSize.height < 480
    tools.frame.size = NSSize(width: max(240, contentSize.width), height: max(320, contentSize.height))
    tools.needsLayout = true
  }
}
