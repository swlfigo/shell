import AppKit
import SwiftTerm
import TermesKit
import SnapKit

/// Terminal + status banner of one pane. Driven by `SessionPaneController` via `apply(_:)`.
@MainActor
final class TerminalViewController: NSViewController, TerminalViewDelegate {
  private let session: SessionManager
  let terminalView = TerminalView(frame: .zero)
  private let bannerLabel = NSTextField(wrappingLabelWithString: "")
  private lazy var trustButton = NSButton(title: "信任", target: self, action: #selector(trust))
  private lazy var rejectButton = NSButton(title: "拒绝", target: self, action: #selector(reject))
  private lazy var cancelButton = NSButton(title: "取消", target: self, action: #selector(cancelReconnect))
  private var banner: NSStackView!
  private var appearanceSettings = AppearanceSettings()
  private(set) var appliedPalette: TerminalPalette?
  private var appliedTextColor: TerminalColor?
  private(set) var hasUnseenOutput = false
  private(set) lazy var newOutputButton: NSButton = {
    let button = NSButton(title: "有新输出 · 回到底部", target: self, action: #selector(scrollToLatest))
    button.image = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)
    button.imagePosition = .imageLeft
    button.isBordered = false
    button.font = .systemFont(ofSize: 13, weight: .semibold)
    button.contentTintColor = .labelColor
    button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    button.setAccessibilityLabel("有新的终端输出，回到底部")
    button.toolTip = "滚动到最新输出并继续跟随；保留当前输入"
    button.isHidden = true
    return button
  }()
  private lazy var newOutputNotice = TerminalOutputNoticeView(button: newOutputButton)

  init(session: SessionManager) {
    self.session = session
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError("unsupported") }

  override func loadView() {
    let root = TerminalRootView(frame: NSRect(x: 0, y: 0, width: 820, height: 500))
    root.onAppearance = { [weak self] in self?.applyColors() }
    root.onLayout = { [weak self] in self?.updateOutputNotice() }
    // Keep the scrollback position visible even after a wheel/trackpad gesture ends.
    terminalView.scrollerStyle = .legacy
    terminalView.terminalDelegate = self
    bannerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    banner = NSStackView(views: [bannerLabel, spacer, trustButton, rejectButton, cancelButton])
    banner.orientation = .horizontal
    banner.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
    banner.isHidden = true
    let column = NSStackView(views: [banner, terminalView])
    column.orientation = .vertical
    column.spacing = 0
    column.distribution = .fill
    root.addSubview(column)
    column.snp.makeConstraints { make in make.edges.equalToSuperview().labeled("Terminal.column") }
    for child in [banner!, terminalView] {
      child.snp.makeConstraints { make in make.leading.trailing.equalToSuperview() }
    }
    // Overlay the notice so showing it does not resize the PTY or shift the history.
    root.addSubview(newOutputNotice)
    newOutputNotice.snp.makeConstraints { make in
      make.centerX.equalTo(terminalView)
      make.bottom.equalTo(terminalView).inset(12).labeled("Terminal.newOutput")
      make.leading.greaterThanOrEqualTo(terminalView).offset(12)
      make.trailing.lessThanOrEqualTo(terminalView).inset(24)
      make.height.greaterThanOrEqualTo(36)
    }
    view = root
    applyAppearance(appearanceSettings)
  }

  func applyAppearance(_ settings: AppearanceSettings) {
    appearanceSettings = settings
    guard isViewLoaded else { return }
    let font = TerminalFonts.resolve(name: settings.terminalFontName, size: settings.terminalFontSize)
    if terminalView.font.fontName != font.fontName || terminalView.font.pointSize != font.pointSize { terminalView.font = font }
    applyColors()
  }

  private func applyColors() {
    guard isViewLoaded else { return }
    let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let palette = appearanceSettings.terminalTheme.palette(effectiveDark: dark)
    if appliedPalette != palette {
      appliedPalette = palette; appliedTextColor = nil; applyTerminalPalette(palette, to: terminalView)
    }
    let color = appearanceSettings.terminalTextColor.map { TerminalColor($0) } ?? palette.foreground
    if appliedTextColor != color {
      appliedTextColor = color; terminalView.nativeForegroundColor = color.nativeColor; terminalView.needsDisplay = true
    }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    // Bound for this controller's whole life, not its appearance: hidden tabs and re-parented
    // panes must keep feeding SwiftTerm (spec §5).
    session.onData = { [weak self] data in self?.receiveOutput(data) }
  }

  /// Unbinds terminal output; called by the pane when it leaves the terminal or closes.
  func teardown() { session.onData = nil; hasUnseenOutput = false; updateOutputNotice() }

  private var isReadingHistory: Bool { terminalView.canScroll && terminalView.scrollPosition < 1 }

  private func receiveOutput(_ data: Data) {
    guard !data.isEmpty else { return }
    let wasReadingHistory = isReadingHistory
    terminalView.feed(byteArray: Array(data)[...])
    if wasReadingHistory && isReadingHistory { hasUnseenOutput = true }
    updateOutputNotice()
  }

  private func updateOutputNotice() {
    // scrollPosition is also zero when there is no history or an alternate screen is
    // active. canScroll distinguishes those states from reading the oldest output.
    if !isReadingHistory { hasUnseenOutput = false }
    let hidden = !hasUnseenOutput
    if newOutputButton.isHidden != hidden { newOutputButton.isHidden = hidden }
    if newOutputNotice.isHidden != hidden { newOutputNotice.isHidden = hidden }
  }

  @objc private func scrollToLatest() {
    terminalView.scroll(toPosition: 1)
    hasUnseenOutput = false; updateOutputNotice(); focusTerminal()
  }

  func focusTerminal() { view.window?.makeFirstResponder(terminalView) }

  func apply(_ state: SessionManager.State) {
    _ = view
    switch state {
    case .reconnecting(let attempt):
      showBanner("正在重连…(第 \(attempt) 次)", buttons: [cancelButton])
    case .needsHostKeyConfirm(let fingerprint):
      let endpoint = session.pendingHostKeyEndpoint
      let host = endpoint.map { "\($0.hostname.contains(":") ? "[\($0.hostname)]" : $0.hostname):\($0.port)" } ?? "该主机"
      showBanner("首次连接 \(host),指纹:\(fingerprint)", buttons: [trustButton, rejectButton])
    default:
      banner.isHidden = true
    }
  }

  private func showBanner(_ text: String, buttons: [NSButton]) {
    bannerLabel.stringValue = text
    for b in [trustButton, rejectButton, cancelButton] { b.isHidden = !buttons.contains(b) }
    banner.isHidden = false
  }

  @objc private func trust() { session.confirmHostKey(true) }
  @objc private func reject() { session.confirmHostKey(false) }
  @objc private func cancelReconnect() { session.disconnect() }

  // MARK: TerminalViewDelegate
  func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
    session.resize(cols: newCols, rows: newRows)
    updateOutputNotice()
  }
  func send(source: TerminalView, data: ArraySlice<UInt8>) { session.sendInput(Data(data)) }
  func setTerminalTitle(source: TerminalView, title: String) {}
  func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
  func scrolled(source: TerminalView, position: Double) { updateOutputNotice() }
  func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
  func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

private final class TerminalRootView: NSView {
  var onAppearance: (() -> Void)?
  var onLayout: (() -> Void)?
  override func layout() { super.layout(); onLayout?() }
  override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); onAppearance?() }
}

/// An opaque surface keeps streaming log text from showing through the notice.
private final class TerminalOutputNoticeView: ChromeView {
  private let button: NSButton
  init(button: NSButton) {
    self.button = button
    super.init(frame: NSRect(x: 0, y: 0, width: 224, height: 36))
    fillColor = NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0.16, green: 0.18, blue: 0.23, alpha: 1)
        : NSColor(srgbRed: 0.96, green: 0.97, blue: 0.99, alpha: 1)
    }
    layer?.cornerRadius = 10; layer?.borderWidth = 1; layer?.zPosition = 1
    layer?.shadowColor = NSColor.black.cgColor; layer?.shadowOpacity = 0.3
    layer?.shadowRadius = 6; layer?.shadowOffset = CGSize(width: 0, height: -2)
    updateBorder(); isHidden = true
    addSubview(button)
    button.snp.makeConstraints { make in make.edges.equalToSuperview().inset(NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)) }
  }
  required init?(coder: NSCoder) { fatalError("unsupported") }
  override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateBorder() }
  private func updateBorder() {
    effectiveAppearance.performAsCurrentDrawingAppearance { layer?.borderColor = NSColor.separatorColor.cgColor }
  }
  // The padding is also clickable; it must not forward a click to the terminal below.
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard let hit = super.hitTest(point) else { return nil }
    return hit === self ? button : hit
  }
}
