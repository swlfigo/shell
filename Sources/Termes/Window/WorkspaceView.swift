import AppKit

enum TermesColors {
  static let vaultBackground = adaptive(dark: 0x202233, light: 0xF7F8FA)
  static let vaultSidebar = adaptive(dark: 0x282A3C, light: 0xEFF1F5)
  static let vaultCard = adaptive(dark: 0x2A2D40, light: 0xFFFFFF)
  static let vaultSelection = adaptive(dark: 0x3C4059, light: 0xDEE3ED)

  private static func adaptive(dark: UInt32, light: UInt32) -> NSColor {
    NSColor(name: nil) { appearance in
      let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
      return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
        green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }
  }
  static let sidebar = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      ? NSColor(srgbRed: 0.14, green: 0.16, blue: 0.19, alpha: 1)
      : NSColor(srgbRed: 0.94, green: 0.95, blue: 0.97, alpha: 1)
  }
  static let chrome = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      ? NSColor(srgbRed: 0.10, green: 0.12, blue: 0.15, alpha: 1)
      : NSColor(srgbRed: 0.98, green: 0.98, blue: 0.99, alpha: 1)
  }
}

class ChromeView: NSView {
  var fillColor: NSColor = TermesColors.chrome { didSet { updateColor() } }
  override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; updateColor() }
  required init?(coder: NSCoder) { fatalError("unsupported") }
  override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColor() }
  private func updateColor() {
    effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = fillColor.cgColor }
  }
}

/// Sidebar size changes resize existing views; they never rebuild the pane tree or terminal.
@MainActor
final class WorkspaceView: ChromeView {
  let sidebar: NSView
  let tabBar: TabBarView
  let container: PaneContainerView
  let sidebarButton = NSButton()
  let vaultsButton = NSButton(title: "Vaults", target: nil, action: nil)
  private var vaultsView: NSView?
  var isShowingVaults = false { didSet { needsLayout = true; layoutSubtreeIfNeeded() } }
  var onShowVaults: (() -> Void)?
  var onToggleVaultsNavigation: (() -> Void)?
  private(set) var sidebarDocked = false
  private(set) var sidebarOverlayOpen = false
  private(set) var sidebarPreferredVisible = true
  var onSidebarChange: (() -> Void)?
  var treeMinimumWidth: CGFloat = 480 { didSet { needsLayout = true } }
  static let sidebarWidth: CGFloat = 240

  init(sidebar: NSView, tabBar: TabBarView, container: PaneContainerView) {
    self.sidebar = sidebar; self.tabBar = tabBar; self.container = container
    super.init(frame: NSRect(x: 0, y: 0, width: 1180, height: 740))
    vaultsButton.image = NSImage(systemSymbolName: "lock.square.stack", accessibilityDescription: nil)
    vaultsButton.imagePosition = .imageLeading; vaultsButton.bezelStyle = .recessed
    vaultsButton.font = .systemFont(ofSize: 13, weight: .semibold)
    vaultsButton.target = self; vaultsButton.action = #selector(showVaults)
    vaultsButton.setAccessibilityLabel("Vaults 首页")
    vaultsButton.toolTip = "返回 Vaults，查看所有主机"
    sidebarButton.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "服务器侧栏")
    sidebarButton.isBordered = false; sidebarButton.target = self; sidebarButton.action = #selector(toggleSidebar)
    sidebarButton.toolTip = "显示或隐藏服务器侧栏 (⇧⌘S)"
    sidebarButton.setAccessibilityLabel("显示或隐藏服务器侧栏")
    for view in [container, tabBar, sidebar, vaultsButton, sidebarButton] {
      view.translatesAutoresizingMaskIntoConstraints = true; view.autoresizingMask = []; addSubview(view)
    }
    // The first pane is mounted before AppKit's first layout pass. Give its frame-based
    // container real bounds now, rather than temporarily constraining a pane to 0 × 0.
    layoutContent()
  }
  required init?(coder: NSCoder) { fatalError("unsupported") }

  func installVaults(_ view: NSView) {
    vaultsView?.removeFromSuperview(); vaultsView = view
    addSubview(view, positioned: .below, relativeTo: tabBar)
    needsLayout = true
  }

  @objc private func showVaults() { onShowVaults?() }

  private var canDock: Bool { bounds.width >= max(880, treeMinimumWidth + Self.sidebarWidth) }
  @objc func toggleSidebar() {
    if isShowingVaults { onToggleVaultsNavigation?(); return }
    if canDock { sidebarPreferredVisible.toggle(); sidebarOverlayOpen = false }
    else { sidebarOverlayOpen.toggle() }
    needsLayout = true; layoutSubtreeIfNeeded()
    onSidebarChange?()
  }
  func revealSidebar() {
    if canDock { sidebarPreferredVisible = true } else { sidebarOverlayOpen = true }
    needsLayout = true; layoutSubtreeIfNeeded()
    onSidebarChange?()
  }
  func dismissOverlay() { sidebarOverlayOpen = false; needsLayout = true }

  func restoreSidebar(visible: Bool) {
    sidebarPreferredVisible = visible; sidebarOverlayOpen = false; needsLayout = true
  }

  override func layout() {
    super.layout()
    layoutContent()
  }

  private func layoutContent() {
    sidebarDocked = canDock && sidebarPreferredVisible
    if sidebarDocked { sidebarOverlayOpen = false }
    let inset: CGFloat = sidebarDocked ? Self.sidebarWidth : 0
    let height = max(0, bounds.height - LayoutMetrics.tabBarHeight)
    container.frame = NSRect(x: inset, y: 0, width: max(0, bounds.width - inset), height: height)
    tabBar.frame = NSRect(x: inset, y: height, width: max(0, bounds.width - inset), height: LayoutMetrics.tabBarHeight)
    tabBar.leadingInset = sidebarDocked ? 10 : 208
    sidebar.frame = NSRect(x: 0, y: 0, width: Self.sidebarWidth, height: height)
    sidebar.isHidden = isShowingVaults || (!sidebarDocked && !sidebarOverlayOpen)
    container.isHidden = isShowingVaults
    vaultsView?.isHidden = !isShowingVaults
    vaultsView?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: height)
    vaultsView?.needsLayout = true
    vaultsButton.frame = NSRect(x: 116, y: height + 5, width: 88, height: 28)
    vaultsButton.state = isShowingVaults ? .on : .off
    sidebarButton.frame = NSRect(x: 84, y: height + 5, width: 26, height: 28)
    sidebarButton.state = isShowingVaults || !sidebar.isHidden ? .on : .off
    sidebarButton.toolTip = isShowingVaults ? "收起或展开 Vaults 导航 (⇧⌘S)" : "显示或隐藏服务器侧栏 (⇧⌘S)"
    sidebarButton.setAccessibilityLabel(isShowingVaults ? "收起或展开 Vaults 导航" : "显示或隐藏服务器侧栏")
    tabBar.needsLayout = true; sidebar.needsLayout = true; container.needsLayout = true
  }
}
