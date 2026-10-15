import AppKit
import TermesKit

enum VaultSection: Int, CaseIterable {
  case hosts, keychain, portForwarding, snippets

  var title: String {
    switch self {
    case .hosts: return "Hosts"
    case .keychain: return "Keychain"
    case .portForwarding: return "Port Forwarding"
    case .snippets: return "Snippets"
    }
  }
  var symbol: String {
    switch self {
    case .hosts: return "server.rack"
    case .keychain: return "key.fill"
    case .portForwarding: return "arrow.triangle.branch"
    case .snippets: return "curlybraces"
    }
  }
  var help: String {
    switch self {
    case .hosts: return "所有主机"
    case .keychain: return "管理 SSH 私钥"
    case .portForwarding: return "管理端口转发与 SOCKS5 代理"
    case .snippets: return "管理常用命令与脚本"
    }
  }
}

/// A library is independent of the live session tabs. Switching pages never replaces a pane.
@MainActor
final class VaultsViewController: NSViewController {
  let hosts: HostBrowserViewController
  let forwarding: VaultForwardingViewController
  private(set) var selectedSection = VaultSection.hosts
  private(set) var navigationButtons: [VaultSection: NSButton] = [:]
  private let services: AppServices
  private let root = VaultLayoutView(frame: .init(x: 0, y: 0, width: 1180, height: 700))
  private let navigation = VaultLayoutView(frame: .zero)
  private let content = NSView()
  private let settings = VaultNavigationButton(title: "设置", target: nil, action: nil)
  private let footer = NSTextField(labelWithString: "本地保险库")
  private var pages: [VaultSection: NSViewController] = [:]
  private var navigationCollapsed = false

  init(services: AppServices, model: ServerListModel) {
    self.services = services
    hosts = HostBrowserViewController(model: model)
    forwarding = VaultForwardingViewController(services: services, model: model)
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError("unsupported") }

  override func loadView() {
    view = root; root.fillColor = TermesColors.vaultBackground
    navigation.fillColor = TermesColors.vaultSidebar
    root.addSubview(navigation); root.addSubview(content)
    for section in VaultSection.allCases {
      let button = VaultNavigationButton(title: section.title, target: self, action: #selector(navigate(_:)))
      button.tag = section.rawValue
      button.image = NSImage(systemSymbolName: section.symbol, accessibilityDescription: nil)
      button.toolTip = section.help; button.setAccessibilityLabel("\(section.title)，\(section.help)")
      navigationButtons[section] = button; navigation.addSubview(button)
    }
    settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
    settings.action = #selector(AppDelegate.showAppearance)
    settings.setAccessibilityLabel("设置")
    footer.font = .systemFont(ofSize: 11); footer.textColor = .tertiaryLabelColor
    navigation.addSubview(settings); navigation.addSubview(footer)
    root.onLayout = { [weak self] in self?.layoutContent() }
    select(.hosts)
  }

  func select(_ section: VaultSection) {
    _ = view
    selectedSection = section
    let page: NSViewController
    if let existing = pages[section] { page = existing }
    else {
      switch section {
      case .hosts: page = hosts
      case .keychain:
        page = VaultManagerPageViewController(title: "Keychain", subtitle: "集中管理 SSH 私钥，供所有主机使用。",
          controller: KeyManagerViewController(profiles: services.profiles), minimum: .init(width: 600, height: 360))
      case .portForwarding:
        page = VaultManagerPageViewController(title: "Port Forwarding", subtitle: "管理本地转发、远端转发与 SOCKS5 代理。",
          controller: forwarding, minimum: .init(width: 640, height: 540))
      case .snippets:
        page = VaultManagerPageViewController(title: "Snippets", subtitle: "保存常用命令与脚本，在终端中随时插入。",
          controller: SnippetManagerViewController(store: services.snippets), minimum: .init(width: 560, height: 440))
      }
      pages[section] = page; addChild(page)
    }
    for child in content.subviews where child !== page.view { child.isHidden = true }
    if page.view.superview == nil { content.addSubview(page.view) }
    page.view.isHidden = false
    for (item, button) in navigationButtons { button.state = item == section ? .on : .off }
    if section == .portForwarding { forwarding.refresh() }
    layoutContent()
  }

  func toggleNavigation() { navigationCollapsed.toggle(); root.needsLayout = true }
  func focusSearch() { select(.hosts); hosts.focusSearch() }
  @objc private func navigate(_ sender: NSButton) {
    guard let section = VaultSection(rawValue: sender.tag) else { return }
    select(section)
  }

  private func layoutContent() {
    let compact = navigationCollapsed || root.bounds.width < 760
    let width: CGFloat = compact ? 64 : WorkspaceView.sidebarWidth
    navigation.frame = .init(x: 0, y: 0, width: width, height: root.bounds.height)
    content.frame = .init(x: width, y: 0, width: max(0, root.bounds.width - width), height: root.bounds.height)
    for (section, button) in navigationButtons {
      button.title = compact ? "" : section.title
      button.imagePosition = compact ? .imageOnly : .imageLeading
      button.alignment = compact ? .center : .left
      button.frame = .init(x: 12, y: 16 + CGFloat(section.rawValue) * 54, width: width - 24, height: 44)
    }
    settings.title = compact ? "" : "设置"
    settings.imagePosition = compact ? .imageOnly : .imageLeading
    settings.alignment = compact ? .center : .left
    settings.frame = .init(x: 12, y: max(242, navigation.bounds.height - 56), width: width - 24, height: 40)
    footer.isHidden = compact || navigation.bounds.height < 380
    footer.frame = .init(x: 24, y: navigation.bounds.height - 84, width: width - 48, height: 16)
    for page in pages.values where page.isViewLoaded {
      page.view.frame = content.bounds; page.view.needsLayout = true
    }
  }
}

final class VaultLayoutView: ChromeView {
  var onLayout: (() -> Void)?
  override var isFlipped: Bool { true }
  override func layout() { super.layout(); onLayout?() }
}

private final class VaultNavigationButton: NSButton {
  override init(frame: NSRect) {
    super.init(frame: frame)
    cell = VaultNavigationButtonCell(textCell: "")
    isBordered = false; bezelStyle = .regularSquare
    imageScaling = .scaleProportionallyDown
    font = .systemFont(ofSize: 14, weight: .medium)
    wantsLayer = true; layer?.cornerRadius = 12
  }
  required init?(coder: NSCoder) { fatalError("unsupported") }
  override var state: NSControl.StateValue { didSet { updateColor() } }
  override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColor() }
  private func updateColor() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = (state == .on ? TermesColors.vaultSelection : .clear).cgColor
    }
  }
}

/// Give symbols a shared column and keep the title clear of both the icon and row edges.
private final class VaultNavigationButtonCell: NSButtonCell {
  override func imageRect(forBounds rect: NSRect) -> NSRect {
    let size: CGFloat = 20
    return NSRect(x: imagePosition == .imageOnly ? rect.midX - size / 2 : rect.minX + 16,
      y: rect.midY - size / 2, width: size, height: size)
  }

  override func titleRect(forBounds rect: NSRect) -> NSRect {
    let leading = imageRect(forBounds: rect).maxX + 12
    let height = min(rect.height, attributedTitle.size().height)
    return NSRect(x: leading, y: rect.midY - height / 2,
      width: max(0, rect.maxX - leading - 16), height: height)
  }

  override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
    if let image { drawImage(image, withFrame: imageRect(forBounds: cellFrame), in: controlView) }
    if imagePosition != .imageOnly {
      drawTitle(attributedTitle, withFrame: titleRect(forBounds: cellFrame), in: controlView)
    }
  }
}

/// Existing managers retain their controllers and drafts, with scrolling at small window sizes.
@MainActor
private final class VaultManagerPageViewController: NSViewController {
  private let controller: NSViewController
  private let minimum: NSSize
  private let heading: NSTextField
  private let subtitle: NSTextField
  private let root = VaultLayoutView(frame: .zero)
  private let document = VaultLayoutView(frame: .zero)
  private let scroll = NSScrollView()
  init(title: String, subtitle: String, controller: NSViewController, minimum: NSSize) {
    self.controller = controller; self.minimum = minimum
    heading = NSTextField(labelWithString: title)
    self.subtitle = NSTextField(wrappingLabelWithString: subtitle)
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError("unsupported") }
  override func loadView() {
    view = root; root.fillColor = TermesColors.vaultBackground
    heading.font = .systemFont(ofSize: 24, weight: .semibold)
    subtitle.font = .systemFont(ofSize: 12); subtitle.textColor = .secondaryLabelColor
    scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
    scroll.autohidesScrollers = true; scroll.automaticallyAdjustsContentInsets = false
    document.fillColor = TermesColors.vaultBackground
    addChild(controller); document.addSubview(controller.view); scroll.documentView = document
    for child in [heading, subtitle, scroll] { root.addSubview(child) }
    root.onLayout = { [weak self] in self?.layoutContent() }
  }
  private func layoutContent() {
    let width = root.bounds.width, height = root.bounds.height
    heading.frame = .init(x: 28, y: 26, width: max(0, width - 56), height: 30)
    subtitle.frame = .init(x: 28, y: 65, width: max(0, width - 56), height: 36)
    scroll.frame = .init(x: 8, y: 110, width: max(0, width - 16), height: max(0, height - 118))
    document.setFrameSize(.init(width: max(minimum.width, scroll.contentSize.width),
      height: max(minimum.height, scroll.contentSize.height)))
    controller.view.frame = document.bounds
    controller.view.needsLayout = true
  }
}
