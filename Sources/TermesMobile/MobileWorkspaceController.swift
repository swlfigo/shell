import UIKit
import Combine
import TermesKit

/// One layout drives iPad panes and the focused compact-width presentation.
final class MobileWorkspaceController: UIViewController {
  private let workspace: MobileWorkspace
  private var controllers: [UUID: MobileSessionController] = [:]
  private let panes = MobilePaneContainerView()
  private let tabScroll = UIScrollView()
  private let tabs = MobileUI.stack(axis: .horizontal, spacing: 8)
  private var subscriptions = Set<AnyCancellable>()
  init(workspace: MobileWorkspace) { self.workspace = workspace; super.init(nibName: nil, bundle: nil) }
  required init?(coder: NSCoder) { fatalError("unsupported") }
  override func viewDidLoad() {
    super.viewDidLoad(); view.backgroundColor = .systemBackground
    navigationItem.largeTitleDisplayMode = .never
    tabScroll.showsHorizontalScrollIndicator = false; tabScroll.addSubview(tabs)
    tabs.snp.makeConstraints { make in
      make.edges.equalTo(tabScroll.contentLayoutGuide).inset(UIEdgeInsets(top: 4, left: 12, bottom: 4, right: 12))
      make.height.equalTo(tabScroll.frameLayoutGuide).offset(-8)
    }
    tabScroll.snp.makeConstraints { $0.height.equalTo(48).priority(999) }
    let stack = MobileUI.stack([tabScroll, panes], spacing: 0)
    view.addSubview(stack); stack.snp.makeConstraints { make in
      make.top.leading.trailing.equalTo(view.safeAreaLayoutGuide)
      make.bottom.equalTo(view.keyboardLayoutGuide.snp.top)
    }
    panes.onFractions = { [weak self] id, fractions in self?.workspace.setFractions(fractions, split: id) }
    workspace.$layout.receive(on: RunLoop.main).sink { [weak self] _ in self?.render() }.store(in: &subscriptions)
    workspace.$sessions.receive(on: RunLoop.main).sink { [weak self] _ in self?.render() }.store(in: &subscriptions)
    workspace.$selectedSessionID.receive(on: RunLoop.main).sink { [weak self] _ in self?.render() }.store(in: &subscriptions)
    render()
  }
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    panes.compact = traitCollection.horizontalSizeClass == .compact
  }
  func render() {
    guard isViewLoaded else { return }
    for (id, controller) in controllers where !workspace.sessions.contains(where: { $0.id == id }) {
      controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent()
      controllers.removeValue(forKey: id)
    }
    guard let tab = workspace.layout.selectedTab else { return }
    for id in tab.paneIds {
      guard controllers[id] == nil, let session = workspace.sessions.first(where: { $0.id == id }) else { continue }
      let controller = MobileSessionController(workspace: workspace, session: session)
      controller.showsSessionTabs = false
      controllers[id] = controller; addChild(controller)
      controller.loadViewIfNeeded(); controller.didMove(toParent: self)
      controller.onNavigationChange = { [weak self] in self?.syncNavigation() }
      let tap = MobilePaneFocusGesture { [weak self] in
        if self?.workspace.selectedSessionID != id { self?.workspace.selectedSessionID = id }
      }
      controller.view.addGestureRecognizer(tap)
    }
    let views = controllers.mapValues { $0.view! }
    panes.setLayout(tab: tab, views: views)
    tabs.arrangedSubviews.forEach { $0.removeFromSuperview() }
    tabScroll.isHidden = workspace.sessions.count < 2
    for item in workspace.layout.tabs {
      let names = item.paneIds.compactMap { id in workspace.sessions.first(where: { $0.id == id })?.name }
      let button = MobileUI.button(names.joined(separator: " + "), filled: item.id == tab.id,
        id: "workspaceTab.\(item.id)") { [weak self] in self?.workspace.selectedSessionID = item.focusedPane }
      tabs.addArrangedSubview(button)
    }
    // Compact layouts still expose every pane without changing the saved split tree.
    if tab.isWorkspace {
      for id in tab.paneIds {
        guard let session = workspace.sessions.first(where: { $0.id == id }) else { continue }
        tabs.addArrangedSubview(MobileUI.button("窗格：\(session.name)", filled: id == tab.focusedPane,
          id: "paneTab.\(id)") { [weak self] in self?.workspace.selectedSessionID = id })
      }
    }
    controllers[tab.focusedPane]?.refreshNavigation()
    syncNavigation()
  }
  private func syncNavigation() {
    guard let id = workspace.selectedSessionID, let controller = controllers[id] else { return }
    title = controller.title
    navigationItem.rightBarButtonItems = controller.navigationItem.rightBarButtonItems
  }
}

private final class MobilePaneFocusGesture: UITapGestureRecognizer, UIGestureRecognizerDelegate {
  private let focus: () -> Void
  init(focus: @escaping () -> Void) {
    self.focus = focus; super.init(target: nil, action: nil)
    addTarget(self, action: #selector(tapped)); cancelsTouchesInView = false; delegate = self
  }
  @objc private func tapped() { focus() }
  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
}

final class MobilePaneContainerView: UIView {
  var onFractions: ((UUID, [Double]) -> Void)?
  var compact = false { didSet { if oldValue != compact { setNeedsLayout() } } }
  private var tab: Tab?
  private var paneViews: [UUID: UIView] = [:]
  private var dividers: [String: MobilePaneDivider] = [:]
  private let gap: CGFloat = 8
  func setLayout(tab: Tab, views: [UUID: UIView]) {
    self.tab = tab
    for (id, view) in paneViews where views[id] !== view { view.removeFromSuperview() }
    paneViews = views
    for view in views.values where view.superview !== self { addSubview(view) }
    setNeedsLayout()
  }
  override func layoutSubviews() {
    super.layoutSubviews()
    paneViews.values.forEach { $0.isHidden = true; $0.layer.borderWidth = 0 }
    dividers.values.forEach { $0.isHidden = true }
    guard let tab else { return }
    let minimum = tab.root.minimumSize(pane: PaneSize(width: 220, height: 180), divider: gap)
    if compact || tab.maximizedPane != nil || bounds.width < minimum.width || bounds.height < minimum.height {
      let id = tab.maximizedPane ?? tab.focusedPane
      paneViews[id]?.isHidden = false; paneViews[id]?.frame = bounds
    } else { layout(tab.root, in: bounds) }
    if tab.isWorkspace, let focused = paneViews[tab.focusedPane] {
      focused.layer.borderColor = tintColor.cgColor; focused.layer.borderWidth = 1
    }
  }
  private func layout(_ node: PaneNode, in frame: CGRect) {
    switch node {
    case .pane(let id): paneViews[id]?.isHidden = false; paneViews[id]?.frame = frame
    case .split(let id, let axis, let children, let fractions):
      let horizontal = axis == .horizontal
      let total = (horizontal ? frame.width : frame.height) - gap * CGFloat(children.count - 1)
      let minimums = children.map { child in
        let size = child.minimumSize(pane: PaneSize(width: 220, height: 180), divider: gap)
        return horizontal ? size.width : size.height
      }
      let lengths = SplitMath.distribute(total: total, fractions: fractions, minimums: minimums)
      var offset: CGFloat = 0
      for index in children.indices {
        let rect = horizontal ? CGRect(x: frame.minX + offset, y: frame.minY, width: lengths[index], height: frame.height)
          : CGRect(x: frame.minX, y: frame.minY + offset, width: frame.width, height: lengths[index])
        layout(children[index], in: rect); offset += lengths[index]
        guard index < children.count - 1 else { continue }
        let key = "\(id).\(index)"
        let divider = dividers[key] ?? MobilePaneDivider()
        if dividers[key] == nil { dividers[key] = divider; addSubview(divider) }
        divider.isHidden = false; bringSubviewToFront(divider)
        divider.frame = horizontal ? CGRect(x: frame.minX + offset, y: frame.minY, width: gap, height: frame.height)
          : CGRect(x: frame.minX, y: frame.minY + offset, width: frame.width, height: gap)
        divider.accessibilityLabel = "调整分屏比例"; divider.accessibilityIdentifier = "workspace.divider.\(key)"
        divider.onMove = { [weak self] delta in
          guard total > 0 else { return }
          var updated = lengths.map { $0 / total }
          let change = (horizontal ? delta.x : delta.y) / total
          let lower = minimums[index] / total, upper = updated[index] + updated[index + 1] - minimums[index + 1] / total
          let first = max(lower, min(upper, updated[index] + change))
          updated[index + 1] += updated[index] - first; updated[index] = first
          self?.onFractions?(id, updated)
        }
        offset += gap
      }
    }
  }
}

private final class MobilePaneDivider: UIView {
  var onMove: ((CGPoint) -> Void)?
  override init(frame: CGRect) {
    super.init(frame: frame); backgroundColor = .tertiarySystemFill
    addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pan(_:))))
    isAccessibilityElement = true
  }
  required init?(coder: NSCoder) { fatalError("unsupported") }
  @objc private func pan(_ sender: UIPanGestureRecognizer) {
    guard sender.state == .changed else { return }
    onMove?(sender.translation(in: superview)); sender.setTranslation(.zero, in: superview)
  }
}
