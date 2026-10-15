import AppKit
import SnapKit
import TermesKit

extension NSPasteboard.PasteboardType {
  /// Private type for a dragged tab; the string value is `TabDragPayload.encoded`.
  static let termesTab = NSPasteboard.PasteboardType("cc.termes.tab")
}

extension TabDragPayload {
  @MainActor static func from(_ info: NSDraggingInfo) -> TabDragPayload? {
    info.draggingPasteboard.string(forType: .termesTab).flatMap(TabDragPayload.init(encoded:))
  }
}

struct TabBarItem: Equatable {
  let id: UUID
  var title: String
  var status: SessionStatus
}

@MainActor
protocol TabBarViewDelegate: AnyObject {
  func tabBar(_ bar: TabBarView, select id: UUID)
  func tabBar(_ bar: TabBarView, close id: UUID)
  func tabBarAddTab(_ bar: TabBarView)
  func tabBar(_ bar: TabBarView, move id: UUID, to index: Int)
  func tabBar(_ bar: TabBarView, canAccept payload: TabDragPayload) -> Bool
  func tabBar(_ bar: TabBarView, drop payload: TabDragPayload, at index: Int) -> Bool
  func tabBar(_ bar: TabBarView, dragEnded payload: TabDragPayload, at point: NSPoint)
  func tabBar(_ bar: TabBarView, menuFor id: UUID) -> NSMenu?
}

extension TabBarViewDelegate {
  func tabBar(_ bar: TabBarView, canAccept payload: TabDragPayload) -> Bool { payload.windowToken == bar.windowToken }
  func tabBar(_ bar: TabBarView, drop payload: TabDragPayload, at index: Int) -> Bool {
    guard payload.windowToken == bar.windowToken else { return false }
    tabBar(bar, move: payload.tabId, to: index); return true
  }
  func tabBar(_ bar: TabBarView, dragEnded payload: TabDragPayload, at point: NSPoint) {}
  func tabBar(_ bar: TabBarView, menuFor id: UUID) -> NSMenu? { nil }
}

/// Termius-style tab bar inside the window's transparent title bar. Dragging a tab within the
/// bar reorders it; dragging it into the pane container merges it (handled by the container).
@MainActor
final class TabBarView: ChromeView {
  weak var delegate: TabBarViewDelegate?
  let windowToken: String
  private let scroller = TabScrollView()
  private let document = TabDocumentView()
  private lazy var previousButton = NSButton(title: "‹", target: self, action: #selector(scrollPrevious))
  private lazy var nextButton = NSButton(title: "›", target: self, action: #selector(scrollNext))
  private lazy var addButton = NSButton(title: "+", target: self, action: #selector(addTapped))
  private var inset: CGFloat = 78
  private var selectedTab: UUID?
  private var revealSelection = false
  private var lastLayoutWidth: CGFloat?
  private var itemViews: [TabItemView] = []

  init(windowToken: String) {
    self.windowToken = windowToken
    super.init(frame: .zero)
    scroller.drawsBackground = false
    // This scroll view is itself inside the title bar. AppKit's automatic title-bar inset
    // otherwise marks the visible tabs as inset space and hit-tests the scroll view instead.
    scroller.automaticallyAdjustsContentInsets = false
    scroller.contentInsets = .init(top: 0, left: 0, bottom: 0, right: 0)
    scroller.documentView = document
    scroller.contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(self, selector: #selector(scrollPositionChanged),
      name: NSView.boundsDidChangeNotification, object: scroller.contentView)
    document.onBackgroundMouseDown = { [weak self] event in self?.mouseDown(with: event) }
    for button in [previousButton, nextButton, addButton] {
      button.isBordered = false
      button.font = .systemFont(ofSize: 16)
      addSubview(button)
    }
    previousButton.toolTip = "向左滚动标签"
    nextButton.toolTip = "向右滚动标签"
    addButton.toolTip = "新建标签 (⌘T)"
    addSubview(scroller)
    registerForDraggedTypes([.termesTab])
  }
  required init?(coder: NSCoder) { fatalError("unsupported") }

  /// Space reserved on the left for the traffic-light buttons.
  var leadingInset: CGFloat {
    get { inset }
    set { inset = newValue; needsLayout = true }
  }

  /// Empty bar areas drag the window, like a normal title bar.
  override var mouseDownCanMoveWindow: Bool { true }

  /// The bar is taller than the system title-bar band, so drag the window explicitly; a double
  /// click does what the system setting says (zoom by default), like a normal title bar.
  override func mouseDown(with event: NSEvent) {
    guard event.clickCount == 2 else {
      window?.performDrag(with: event)
      return
    }
    switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize" {
    case "Minimize": window?.performMiniaturize(nil)
    case "None": break
    default: window?.performZoom(nil)
    }
  }

  /// Updates in place while the tab ids/order are unchanged, so the source view of an in-flight
  /// drag survives status refreshes (Review Focus 2); otherwise rebuilds the item views.
  func update(items: [TabBarItem], selected: UUID?) {
    revealSelection = revealSelection || selectedTab != selected
    selectedTab = selected
    if items.map(\.id) == itemViews.map(\.item.id) {
      for (view, item) in zip(itemViews, items) { view.apply(item, selected: item.id == selected) }
      needsLayout = true
      return
    }
    revealSelection = true
    itemViews.forEach { $0.removeFromSuperview() }
    itemViews = items.map { item in
      let v = TabItemView(item: item, payload: TabDragPayload(windowToken: windowToken, tabId: item.id))
      v.apply(item, selected: item.id == selected)
      v.onSelect = { [weak self] in
        guard let self else { return }
        self.delegate?.tabBar(self, select: item.id)
      }
      v.onClose = { [weak self] in
        guard let self else { return }
        self.delegate?.tabBar(self, close: item.id)
      }
      v.onDragOutside = { [weak self] point in
        guard let self else { return }
        self.delegate?.tabBar(self, dragEnded: TabDragPayload(windowToken: self.windowToken, tabId: item.id), at: point)
      }
      v.onMenu = { [weak self] in
        guard let self else { return nil }
        return self.delegate?.tabBar(self, menuFor: item.id)
      }
      return v
    }
    itemViews.forEach { document.addSubview($0) }
    needsLayout = true
  }

  override func layout() {
    super.layout()
    if lastLayoutWidth != bounds.width { revealSelection = true }
    lastLayoutWidth = bounds.width
    let height: CGFloat = 28
    let spacing: CGFloat = 4
    let addWidth: CGFloat = 28
    let arrowWidth: CGFloat = 20
    let available = max(0, bounds.width - inset - addWidth - 16)
    let gaps = CGFloat(max(0, itemViews.count - 1)) * spacing
    let overflow = CGFloat(itemViews.count) * 112 + gaps > available
    let viewport = max(0, available - (overflow ? 2 * arrowWidth : 0))
    let y = (bounds.height - height) / 2
    previousButton.isHidden = !overflow
    nextButton.isHidden = !overflow
    previousButton.frame = NSRect(x: inset, y: y, width: arrowWidth, height: height)
    let x = inset + (overflow ? arrowWidth : 0)
    scroller.frame = NSRect(x: x, y: y, width: viewport, height: height)
    nextButton.frame = NSRect(x: x + viewport, y: y, width: arrowWidth, height: height)
    addButton.frame = NSRect(x: bounds.width - addWidth - 8, y: y, width: addWidth, height: height)
    let width = min(200, max(112, (viewport - gaps) / CGFloat(max(1, itemViews.count))))
    for (i, item) in itemViews.enumerated() {
      item.frame = NSRect(x: CGFloat(i) * (width + spacing), y: 0, width: width, height: height)
    }
    document.frame = NSRect(x: 0, y: 0,
      width: max(viewport, CGFloat(itemViews.count) * width + gaps), height: height)
    var origin = scroller.contentView.bounds.origin
    if revealSelection, let selected = itemViews.first(where: { $0.item.id == selectedTab }) {
      if selected.frame.minX < origin.x { origin.x = selected.frame.minX }
      if selected.frame.maxX > origin.x + viewport { origin.x = selected.frame.maxX - viewport }
    }
    scroller.scroll(toX: origin.x)
    revealSelection = false
    scrollPositionChanged()
  }

  @objc private func scrollPositionChanged() {
    let clip = scroller.contentView.bounds
    previousButton.isEnabled = clip.minX > 0
    nextButton.isEnabled = clip.maxX < document.bounds.maxX - 0.5
  }

  @objc private func scrollPrevious() { scroller.scroll(toX: scroller.contentView.bounds.minX - scrollStep) }
  @objc private func scrollNext() { scroller.scroll(toX: scroller.contentView.bounds.minX + scrollStep) }
  private var scrollStep: CGFloat { max(112, scroller.contentView.bounds.width * 0.8) }

  @objc private func addTapped() { delegate?.tabBarAddTab(self) }

  // MARK: Reorder (drop inside the bar)

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { accepts(sender) ? .move : [] }
  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    guard accepts(sender) else { return [] }
    let point = scroller.convert(sender.draggingLocation, from: nil)
    if point.x < 24 { scroller.scroll(toX: scroller.contentView.bounds.minX - 12) }
    else if point.x > scroller.bounds.width - 24 { scroller.scroll(toX: scroller.contentView.bounds.minX + 12) }
    return .move
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    guard let p = TabDragPayload.from(sender), delegate?.tabBar(self, canAccept: p) == true else { return false }
    let x = document.convert(sender.draggingLocation, from: nil).x
    let index = itemViews
      .filter { $0.item.id != p.tabId }
      .filter { $0.frame.midX < x }
      .count
    return delegate?.tabBar(self, drop: p, at: index) == true
  }

  private func accepts(_ info: NSDraggingInfo) -> Bool {
    guard let payload = TabDragPayload.from(info) else { return false }
    return delegate?.tabBar(self, canAccept: payload) == true
  }
}

/// One tab: status dot + truncating title + a close button anchored at the trailing edge.
/// A click selects on mouse-up; moving more than 4 pt first starts a tab drag instead.
/// An NSControl because, inside the title bar, AppKit only exempts controls from the window-drag
/// region (a plain NSView reports an empty rect even with mouseDownCanMoveWindow == false), so a
/// press on an NSView tab would move the window instead of reaching mouseDown.
@MainActor
final class TabItemView: NSControl, NSDraggingSource {
  private(set) var item: TabBarItem
  private let payload: TabDragPayload
  var onSelect: (() -> Void)?
  var onClose: (() -> Void)?
  var onDragOutside: ((NSPoint) -> Void)?
  var onMenu: (() -> NSMenu?)?
  private let dot = NSView()
  private let titleLabel = NSTextField(labelWithString: "")
  private lazy var closeButton = NSButton(title: "×", target: self, action: #selector(closeTapped))
  private var isSelected = false
  private var downPoint: NSPoint?
  private var dragStarted = false
  private var dragRetain: TabItemView?
  private var escapeMonitor: Any?
  private var dragCancelled = false

  init(item: TabBarItem, payload: TabDragPayload) {
    self.item = item
    self.payload = payload
    // The bar owns the frame. AppKit may lay out our controls immediately on attachment,
    // before the bar's first layout, so it must already have room for the title/close button.
    super.init(frame: NSRect(x: 0, y: 0, width: 112, height: 28))
    setAccessibilityElement(true)
    setAccessibilityRole(.radioButton)
    wantsLayer = true
    layer?.cornerRadius = 6
    dot.wantsLayer = true
    dot.layer?.cornerRadius = 4
    titleLabel.lineBreakMode = .byTruncatingTail
    // Titles truncate rather than push the window wider (default 750 beats the window size priority).
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    closeButton.isBordered = false
    for child in [dot, titleLabel, closeButton] { addSubview(child) }
    dot.snp.makeConstraints { make in
      make.leading.equalToSuperview().offset(10)
      make.centerY.equalToSuperview(); make.size.equalTo(8)
    }
    closeButton.snp.makeConstraints { make in
      make.trailing.equalToSuperview().inset(6)
      make.centerY.equalToSuperview(); make.size.equalTo(18)
    }
    titleLabel.snp.makeConstraints { make in
      make.leading.equalTo(dot.snp.trailing).offset(6)
      make.trailing.equalTo(closeButton.snp.leading).offset(-6)
      make.centerY.equalToSuperview()
    }
  }
  required init?(coder: NSCoder) { fatalError("unsupported") }

  func apply(_ item: TabBarItem, selected: Bool) {
    self.item = item
    isSelected = selected
    titleLabel.stringValue = item.title
    setAccessibilityLabel(item.title)
    setAccessibilityValue(selected ? 1 : 0)
    setAccessibilityHelp(item.status == .idle ? "未连接" : item.status == .connected ? "已连接" : item.status == .pending ? "连接中、等待信任或重连中" : "失败或已断开")
    toolTip = item.title
    dot.isHidden = item.status == .idle
    effectiveAppearance.performAsCurrentDrawingAppearance {
      dot.layer?.backgroundColor = Self.color(for: item.status).cgColor
      layer?.backgroundColor = selected
        ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25).cgColor
        : NSColor.controlBackgroundColor.withAlphaComponent(0.35).cgColor
      layer?.borderWidth = selected ? 1 : 0
      layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.55).cgColor
    }
    closeButton.setAccessibilityLabel("关闭 \(item.title)")
  }

  static func color(for status: SessionStatus) -> NSColor {
    switch status {
    case .idle: return .clear
    case .connected: return .systemGreen
    case .pending: return .systemYellow
    case .problem: return .systemRed
    }
  }

  override var mouseDownCanMoveWindow: Bool { false }
  override var acceptsFirstResponder: Bool { true }
  override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); apply(item, selected: isSelected) }
  override func keyDown(with event: NSEvent) {
    if event.keyCode == 36 || event.keyCode == 49 { onSelect?() } else { super.keyDown(with: event) }
  }

  override func accessibilityPerformPress() -> Bool {
    guard isEnabled else { return false }
    onSelect?()
    return true
  }

  /// Clicks on the title/dot land on the tab itself (not its subviews) so the title-bar band
  /// never treats them as window drags; the close button keeps its own clicks.
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard let hit = super.hitTest(point) else { return nil }
    return hit.isDescendant(of: closeButton) ? hit : self
  }

  override func menu(for event: NSEvent) -> NSMenu? { onMenu?() }

  func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
    alphaValue = 1
    dragRetain = nil
    dragStarted = false
    if let monitor = escapeMonitor { NSEvent.removeMonitor(monitor); escapeMonitor = nil }
    // Esc cancels without tearing off a tab, including while the mouse is held outside a window.
    if operation.isEmpty && !dragCancelled && NSEvent.pressedMouseButtons & 1 == 0 { onDragOutside?(screenPoint) }
  }

  override func mouseDown(with event: NSEvent) {
    downPoint = convert(event.locationInWindow, from: nil)
    dragStarted = false
  }

  override func mouseDragged(with event: NSEvent) {
    guard !dragStarted, let start = downPoint else { return }
    let p = convert(event.locationInWindow, from: nil)
    guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
    dragStarted = true
    dragCancelled = false
    escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      if event.keyCode == 53 { MainActor.assumeIsolated { self?.dragCancelled = true } }
      return event
    }
    let pasteboardItem = NSPasteboardItem()
    pasteboardItem.setString(payload.encoded, forType: .termesTab)
    let dragItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
    dragItem.setDraggingFrame(bounds, contents: snapshot())
    dragRetain = self  // keep the source alive: the bar may rebuild its items during the drop
    beginDraggingSession(with: [dragItem], event: event, source: self)
    alphaValue = 0.4  // the tab stays in place, dimmed, while its floating copy follows the cursor
  }

  override func mouseUp(with event: NSEvent) {
    if !dragStarted { onSelect?() }
    downPoint = nil
  }

  func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
    context == .withinApplication ? .move : []
  }

  @objc private func closeTapped() { onClose?() }

  private func snapshot() -> NSImage {
    let image = NSImage(size: bounds.size)
    if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
      cacheDisplay(in: bounds, to: rep)
      image.addRepresentation(rep)
    }
    return image
  }
}

/// Maps either wheel axis to the horizontal strip, including ordinary vertical mouse wheels.
private final class TabScrollView: NSScrollView {
  func scroll(toX x: CGFloat) {
    let limit = max(0, (documentView?.bounds.width ?? 0) - contentView.bounds.width)
    contentView.scroll(to: NSPoint(x: min(max(0, x), limit), y: 0))
    reflectScrolledClipView(contentView)
  }

  override func scrollWheel(with event: NSEvent) {
    let delta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
      ? event.scrollingDeltaX : event.scrollingDeltaY
    scroll(toX: contentView.bounds.minX - delta * (event.hasPreciseScrollingDeltas ? 1 : 24))
  }
}

private final class TabDocumentView: NSView {
  var onBackgroundMouseDown: ((NSEvent) -> Void)?
  override var mouseDownCanMoveWindow: Bool { true }
  override func mouseDown(with event: NSEvent) { onBackgroundMouseDown?(event) }
}
