import AppKit
import TermesKit

@MainActor
protocol PaneContainerDelegate: AnyObject {
  func paneContainer(_ c: PaneContainerView, didResizeSplit id: UUID, fractions: [Double])
  func paneContainer(_ c: PaneContainerView, canAccept payload: TabDragPayload) -> Bool
  func paneContainer(_ c: PaneContainerView, drop payload: TabDragPayload, onto pane: UUID, edge: PaneEdge)
  func paneContainer(_ c: PaneContainerView, performDrop payload: TabDragPayload, onto pane: UUID, edge: PaneEdge) -> Bool
}

extension PaneContainerDelegate {
  func paneContainer(_ c: PaneContainerView, performDrop payload: TabDragPayload, onto pane: UUID, edge: PaneEdge) -> Bool {
    paneContainer(c, drop: payload, onto: pane, edge: edge); return true
  }
}

/// Renders one tab's `PaneNode` as nested NSSplitViews around the panes' own views (re-parented,
/// never recreated). Split proportions come from the model and user divider drags are written
/// back through the delegate. Children never shrink below `LayoutMetrics.paneMin`.
@MainActor
final class PaneContainerView: NSView, NSSplitViewDelegate {
  weak var delegate: PaneContainerDelegate?

  private struct SplitInfo {
    let id: UUID
    let axis: SplitAxis
    let children: [PaneNode]
    var fractions: [Double]
  }

  private(set) var visiblePanes: [UUID: NSView] = [:]
  private var splits: [ObjectIdentifier: SplitInfo] = [:]
  private var splitOrder: [NSSplitView] = []  // parents before children
  /// Model fractions still need applying once the container has a real size.
  private var pendingFractions = false
  /// Suppresses write-back while splits are laid out from the model.
  private var applying = false
  private var rootView: NSView?
  private var rootMinimum = PaneSize(width: 0, height: 0)
  private let overlay = DropOverlayView()
  private var dropTarget: (pane: UUID, edge: PaneEdge)?

  override init(frame: NSRect) {
    super.init(frame: frame)
    registerForDraggedTypes([.termesTab])
    overlay.wantsLayer = true
    overlay.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
    overlay.layer?.cornerRadius = 8
    overlay.isHidden = true
  }
  required init?(coder: NSCoder) { fatalError("unsupported") }

  func clear() {
    for view in visiblePanes.values { view.removeFromSuperview() }
    subviews.forEach { $0.removeFromSuperview() }
    visiblePanes.removeAll(); splits.removeAll(); splitOrder.removeAll(); rootView = nil
    clearDrop()
  }

  func render(root: PaneNode, maximized: UUID?, views: [UUID: NSView]) {
    let wasApplying = applying
    applying = true; pendingFractions = true
    defer { applying = wasApplying }
    for v in visiblePanes.values { v.removeFromSuperview() }
    subviews.forEach { $0.removeFromSuperview() }
    visiblePanes.removeAll()
    splits.removeAll()
    splitOrder.removeAll()
    let node = maximized.map { PaneNode.pane($0) } ?? root
    rootMinimum = node.minimumSize(pane: LayoutMetrics.paneMin, divider: LayoutMetrics.divider)
    let top = build(node, views, frame: rootFrame)
    rootView = top
    addSubview(top)
    needsLayout = true
    addSubview(overlay)  // frame-based, always on top
  }

  /// Workspace and NSSplitView own frames; Auto Layout stays inside each pane. A temporary
  /// zero/undersized container keeps the tree at its minimum until real bounds arrive.
  private var rootFrame: NSRect {
    NSRect(x: bounds.minX, y: bounds.minY,
      width: max(bounds.width, CGFloat(rootMinimum.width)), height: max(bounds.height, CGFloat(rootMinimum.height)))
  }

  private func build(_ node: PaneNode, _ views: [UUID: NSView], frame: NSRect) -> NSView {
    switch node {
    case .pane(let id):
      let v = views[id] ?? NSView()
      v.removeFromSuperview()
      v.translatesAutoresizingMaskIntoConstraints = true; v.autoresizingMask = []; v.frame = frame
      visiblePanes[id] = v
      return v
    case .split(let id, let axis, let children, let fractions):
      let sv = PaneSplitView(frame: frame)
      sv.translatesAutoresizingMaskIntoConstraints = true; sv.autoresizingMask = []
      sv.isVertical = axis == .horizontal  // vertical dividers = side-by-side panes
      sv.dividerStyle = .thin
      let info = SplitInfo(id: id, axis: axis, children: children, fractions: fractions)
      splits[ObjectIdentifier(sv)] = info
      splitOrder.append(sv)
      for (child, frame) in zip(children, childFrames(sv, info, fractions: fractions)) {
        sv.addSubview(build(child, views, frame: frame))
      }
      sv.delegate = self
      layoutSplit(sv, info, fractions: fractions)
      return sv
    }
  }

  override func layout() {
    let wasApplying = applying
    applying = true
    defer { applying = wasApplying }
    // Set frames before laying out pane contents, including during re-parenting and
    // zero-size transitions. No required edge constraints tie them to the outer bounds.
    rootView?.frame = rootFrame
    for sv in splitOrder {
      if let info = splits[ObjectIdentifier(sv)] { layoutSplit(sv, info, fractions: info.fractions) }
    }
    super.layout()
    if bounds.width > 0 && bounds.height > 0 { pendingFractions = false }
  }

  /// Frames `sv`'s children by `fractions`, clamped to each child's minimum along the axis.
  private func layoutSplit(_ sv: NSSplitView, _ info: SplitInfo, fractions: [Double]) {
    let subs = sv.subviews
    guard subs.count == fractions.count else { return }
    for (view, frame) in zip(subs, childFrames(sv, info, fractions: fractions)) { view.frame = frame }
  }

  /// Used before mounting children as well as on resize, so nested split views never start
  /// with zero/negative child frames and then force AppKit to break their internal constraints.
  private func childFrames(_ sv: NSSplitView, _ info: SplitInfo, fractions: [Double]) -> [NSRect] {
    let sideBySide = sv.isVertical
    let thickness = sv.dividerThickness
    let length = Double(sideBySide ? sv.bounds.width : sv.bounds.height)
    let available = max(0, length - Double(thickness) * Double(fractions.count - 1))
    let mins = info.children.map { Self.minLength($0, along: info.axis) }
    var lengths = SplitMath.distribute(total: available, fractions: fractions, minimums: mins)
    // Whole points: floor all but the last child, which takes the remainder.
    if lengths.count > 1 {
      for i in 0..<(lengths.count - 1) { lengths[i] = lengths[i].rounded(.down) }
      lengths[lengths.count - 1] = available - lengths.dropLast().reduce(0, +)
    }
    var offset: CGFloat = 0
    return lengths.map { len in
      let frame = sideBySide
        ? NSRect(x: offset, y: 0, width: CGFloat(len), height: sv.bounds.height)
        : NSRect(x: 0, y: offset, width: sv.bounds.width, height: CGFloat(len))
      offset += CGFloat(len) + thickness
      return frame
    }
  }

  static func minLength(_ node: PaneNode, along axis: SplitAxis) -> Double {
    let size = node.minimumSize(pane: LayoutMetrics.paneMin, divider: LayoutMetrics.divider)
    return axis == .horizontal ? size.width : size.height
  }

  // MARK: Merge drop zones

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { updateDrop(sender) }
  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { updateDrop(sender) }
  override func draggingExited(_ sender: NSDraggingInfo?) { clearDrop() }
  override func draggingEnded(_ sender: NSDraggingInfo) { clearDrop() }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    defer { clearDrop() }
    guard let payload = TabDragPayload.from(sender), let target = dropTarget else { return false }
    return delegate?.paneContainer(self, performDrop: payload, onto: target.pane, edge: target.edge) == true
  }

  /// Highlights the half of the pane under the cursor whose edge is nearest; no zone when the
  /// drag is not acceptable or the pane cannot hold two minimum-size panes on that axis.
  private func updateDrop(_ info: NSDraggingInfo) -> NSDragOperation {
    guard let payload = TabDragPayload.from(info), delegate?.paneContainer(self, canAccept: payload) == true else {
      clearDrop()
      return []
    }
    let point = convert(info.draggingLocation, from: nil)
    for (id, v) in visiblePanes {
      let r = v.convert(v.bounds, to: self)
      guard r.contains(point), r.width > 0, r.height > 0 else { continue }
      let x = Double((point.x - r.minX) / r.width)
      let yFromTop = isFlipped ? Double((point.y - r.minY) / r.height) : Double((r.maxY - point.y) / r.height)
      let edge = PaneEdge.nearest(x: x, yFromTop: yFromTop)
      guard PaneEdge.canSplit(width: Double(r.width), height: Double(r.height), edge: edge,
                              paneMin: LayoutMetrics.paneMin, divider: LayoutMetrics.divider) else { break }
      dropTarget = (id, edge)
      overlay.frame = Self.half(of: r, edge: edge, flipped: isFlipped).insetBy(dx: 4, dy: 4)
      overlay.isHidden = false
      return .move
    }
    clearDrop()
    return []
  }

  private func clearDrop() {
    dropTarget = nil
    overlay.isHidden = true
  }

  private static func half(of r: NSRect, edge: PaneEdge, flipped: Bool) -> NSRect {
    let w = r.width / 2, h = r.height / 2
    switch edge {
    case .left: return NSRect(x: r.minX, y: r.minY, width: w, height: r.height)
    case .right: return NSRect(x: r.midX, y: r.minY, width: w, height: r.height)
    case .top: return NSRect(x: r.minX, y: flipped ? r.minY : r.midY, width: r.width, height: h)
    case .bottom: return NSRect(x: r.minX, y: flipped ? r.midY : r.minY, width: r.width, height: h)
    }
  }

  // MARK: NSSplitViewDelegate

  /// Window / parent resize: keep the current proportions, but never below a child's minimum.
  func splitView(_ sv: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
    guard let info = splits[ObjectIdentifier(sv)] else {
      sv.adjustSubviews()
      return
    }
    layoutSplit(sv, info, fractions: info.fractions)
  }

  /// Writes proportions back only during a user divider drag. Window / parent resizes also post
  /// this notification (with a divider index), but must keep laying out from the model fractions.
  func splitViewDidResizeSubviews(_ notification: Notification) {
    guard !applying, !pendingFractions, let sv = notification.object as? PaneSplitView,
          sv.isDraggingDivider,
          let info = splits[ObjectIdentifier(sv)] else { return }
    let lengths = sv.subviews.map { Double(sv.isVertical ? $0.frame.width : $0.frame.height) }
    let total = lengths.reduce(0, +)
    guard total > 0, lengths.allSatisfy({ $0 > 0 }) else { return }
    let fractions = lengths.map { $0 / total }
    splits[ObjectIdentifier(sv)]?.fractions = fractions
    delegate?.paneContainer(self, didResizeSplit: info.id, fractions: fractions)
  }

  func splitView(_ sv: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt i: Int) -> CGFloat {
    guard let info = splits[ObjectIdentifier(sv)] else { return proposed }
    let f = sv.subviews[i].frame
    let start = sv.isVertical ? f.minX : f.minY
    return max(proposed, start + CGFloat(Self.minLength(info.children[i], along: info.axis)))
  }

  func splitView(_ sv: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt i: Int) -> CGFloat {
    guard let info = splits[ObjectIdentifier(sv)] else { return proposed }
    let f = sv.subviews[i + 1].frame
    let end = sv.isVertical ? f.maxX : f.maxY
    return min(proposed, end - CGFloat(Self.minLength(info.children[i + 1], along: info.axis)) - sv.dividerThickness)
  }
}

/// Split view that knows whether the user is dragging one of its dividers: NSSplitView tracks the
/// whole divider drag synchronously inside `super.mouseDown`.
private final class PaneSplitView: NSSplitView {
  private(set) var isDraggingDivider = false

  override func mouseDown(with event: NSEvent) {
    isDraggingDivider = true
    defer { isDraggingDivider = false }
    super.mouseDown(with: event)
  }
}

/// Drop highlight that never takes mouse events.
private final class DropOverlayView: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
