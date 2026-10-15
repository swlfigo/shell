import AppKit
import Combine
import TermesKit
import SwiftTerm

extension AppTheme {
  var nativeAppearance: NSAppearance? {
    switch self {
    case .system: return nil
    case .light: return NSAppearance(named: .aqua)
    case .dark: return NSAppearance(named: .darkAqua)
    }
  }
}

@MainActor
final class AppearanceViewController: NSViewController, NSTextFieldDelegate {
  private let store: AppearanceStore
  let themePopup = NSPopUpButton()
  let fontPopup = NSPopUpButton()
  let sizeField = NSTextField(string: "13")
  let decreaseButton = NSButton(title: "−", target: nil, action: nil)
  let increaseButton = NSButton(title: "+", target: nil, action: nil)
  let fontToggle = NSButton(title: "字体", target: nil, action: nil)
  let textColorMode = NSPopUpButton()
  let textColorWell = NSColorWell()
  let preview = TerminalView(frame: NSRect(x: 0, y: 0, width: 440, height: 480))
  private(set) var themeRows: [TerminalThemeRow] = []
  private(set) var fontChoices: [TerminalFonts.Choice] = []
  private(set) var isFontExpanded = true
  private let root = AppearanceRootView(frame: NSRect(x: 0, y: 0, width: 820, height: 660))
  private let heading = NSTextField(labelWithString: "外观与终端")
  private let appLabel = NSTextField(labelWithString: "界面外观")
  private let previewTitle = NSTextField(labelWithString: "终端预览")
  private let scroll = NSScrollView()
  private let document = AppearanceRootView(frame: .zero)
  private let sizeLabel = NSTextField(labelWithString: "字号")
  private let textColorLabel = NSTextField(labelWithString: "文字颜色")
  private let themesTitle = NSTextField(labelWithString: "主题")
  private let fontNotice = NSTextField(wrappingLabelWithString: "")
  private let errorLabel = NSTextField(wrappingLabelWithString: "")
  private var observer: AnyCancellable?
  private var localError: String?
  private var previewPalette: TerminalPalette?
  private var previewTextColor: TerminalColor?
  private var displayedSettings = AppearanceSettings()
  private var previewGeometry = NSSize.zero

  init(store: AppearanceStore) { self.store = store; super.init(nibName: nil, bundle: nil) }
  required init?(coder: NSCoder) { fatalError("unsupported") }

  override func loadView() {
    view = root
    heading.font = .boldSystemFont(ofSize: 20)
    for label in [appLabel, previewTitle, sizeLabel, textColorLabel] { label.font = .systemFont(ofSize: 12); label.textColor = .secondaryLabelColor }
    previewTitle.lineBreakMode = .byTruncatingTail
    themePopup.addItems(withTitles: ["跟随系统", "浅色", "深色"])
    themePopup.target = self; themePopup.action = #selector(appThemeChanged); themePopup.setAccessibilityLabel("界面外观")
    fontPopup.target = self; fontPopup.action = #selector(fontChanged); fontPopup.setAccessibilityLabel("终端字体")
    textColorMode.addItems(withTitles: ["跟随主题", "自定义"])
    textColorMode.target = self; textColorMode.action = #selector(textColorModeChanged)
    textColorMode.setAccessibilityLabel("终端文字颜色模式")
    textColorWell.target = self; textColorWell.action = #selector(textColorChanged)
    textColorWell.setAccessibilityLabel("选择终端默认文字颜色")
    fontToggle.target = self; fontToggle.action = #selector(toggleFontSection); fontToggle.isBordered = false
    fontToggle.font = .systemFont(ofSize: 14, weight: .semibold); fontToggle.alignment = .left; fontToggle.imagePosition = .imageRight
    fontToggle.setAccessibilityLabel("展开或收起字体设置")
    sizeField.alignment = .center; sizeField.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
    sizeField.delegate = self; sizeField.setAccessibilityLabel("终端字号，10 到 28 点")
    decreaseButton.target = self; decreaseButton.action = #selector(decreaseSize)
    increaseButton.target = self; increaseButton.action = #selector(increaseSize)
    decreaseButton.setAccessibilityLabel("减小终端字号"); increaseButton.setAccessibilityLabel("增大终端字号")
    for button in [decreaseButton, increaseButton] { button.bezelStyle = .rounded; button.font = .systemFont(ofSize: 18, weight: .medium) }
    themesTitle.font = .systemFont(ofSize: 14, weight: .semibold)
    fontNotice.font = .systemFont(ofSize: 11); fontNotice.textColor = .secondaryLabelColor; fontNotice.maximumNumberOfLines = 3
    errorLabel.font = .systemFont(ofSize: 12); errorLabel.textColor = .systemRed; errorLabel.maximumNumberOfLines = 3
    document.fillColor = TermesColors.sidebar
    scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
    scroll.documentView = document; scroll.wantsLayer = true; scroll.layer?.cornerRadius = 16; scroll.layer?.masksToBounds = true
    for child in [heading, appLabel, themePopup, previewTitle, preview, scroll] { root.addSubview(child) }
    for child in [fontToggle, fontPopup, sizeLabel, sizeField, decreaseButton, increaseButton, textColorLabel, textColorMode, textColorWell, themesTitle, fontNotice, errorLabel] { document.addSubview(child) }
    for (index, theme) in TerminalTheme.catalog.enumerated() {
      let row = TerminalThemeRow(theme: theme); row.tag = index; row.target = self; row.action = #selector(themeSelected(_:))
      row.onNavigate = { [weak self] delta in self?.navigate(from: index, delta: delta) }
      themeRows.append(row); document.addSubview(row)
    }
    preview.scrollerStyle = .legacy
    preview.wantsLayer = true; preview.layer?.cornerRadius = 12; preview.layer?.masksToBounds = true
    root.onLayout = { [weak self] in self?.layoutContent() }
    root.onAppearance = { [weak self] in self?.refreshPreview() }
    observer = store.$settings.combineLatest(store.$error).sink { [weak self] value, error in self?.display(value, error: error) }
  }

  override func viewDidAppear() { super.viewDidAppear(); view.window?.appearance = store.settings.theme.nativeAppearance; refreshPreview() }

  private func display(_ settings: AppearanceSettings, error: String?) {
    // @Published emits before the stored property changes. Previews must use this value.
    displayedSettings = settings
    themePopup.selectItem(at: AppTheme.allCases.firstIndex(of: settings.theme) ?? 0)
    fontChoices = TerminalFonts.choices()
    let missing = !TerminalFonts.isAvailable(settings.terminalFontName)
    if missing, let name = settings.terminalFontName { fontChoices.append(.init(name: name, title: "\(name)（不可用）")) }
    fontPopup.removeAllItems(); fontPopup.addItems(withTitles: fontChoices.map(\.title))
    fontPopup.selectItem(at: fontChoices.firstIndex { $0.name == settings.terminalFontName } ?? 0)
    fontNotice.stringValue = missing ? "所选字体未安装，当前使用系统等宽字体。" : ""; fontNotice.isHidden = !missing
    sizeField.stringValue = Self.sizeText(settings.terminalFontSize)
    decreaseButton.isEnabled = settings.terminalFontSize > 10; increaseButton.isEnabled = settings.terminalFontSize < 28
    textColorMode.selectItem(at: settings.terminalTextColor == nil ? 0 : 1)
    textColorWell.isEnabled = settings.terminalTextColor != nil
    errorLabel.stringValue = localError ?? error ?? ""; errorLabel.isHidden = errorLabel.stringValue.isEmpty
    for row in themeRows { row.setSelected(row.theme == settings.terminalTheme) }
    view.window?.appearance = settings.theme.nativeAppearance
    refreshPreview(); layoutContent()
  }

  private func refreshPreview() {
    guard isViewLoaded else { return }
    let settings = displayedSettings, dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let palette = settings.terminalTheme.palette(effectiveDark: dark)
    if previewPalette != palette { previewPalette = palette; previewTextColor = nil; applyTerminalPalette(palette, to: preview) }
    let color = settings.terminalTextColor.map { TerminalColor($0) } ?? palette.foreground
    if previewTextColor != color { previewTextColor = color; preview.nativeForegroundColor = color.nativeColor; preview.needsDisplay = true }
    textColorWell.color = color.nativeColor; textColorWell.toolTip = String(format: "#%06X · 程序指定的颜色保持原样", color.rgb)
    let font = TerminalFonts.resolve(name: settings.terminalFontName, size: settings.terminalFontSize)
    if preview.font.fontName != font.fontName || preview.font.pointSize != font.pointSize { preview.font = font; previewGeometry = .zero }
    previewTitle.stringValue = "终端预览 · \(settings.terminalTheme.displayName)"
    for row in themeRows { row.thumbnail.palette = row.theme.palette(effectiveDark: dark); row.needsDisplay = true }
  }

  private func save(_ settings: AppearanceSettings) {
    localError = nil
    do { try store.update(settings) }
    catch { display(store.settings, error: store.error); _ = errorLabel.scrollToVisible(errorLabel.bounds) }
  }
  @objc func appThemeChanged() {
    guard AppTheme.allCases.indices.contains(themePopup.indexOfSelectedItem) else { return }
    var value = store.settings; value.theme = AppTheme.allCases[themePopup.indexOfSelectedItem]; save(value)
  }
  @objc func fontChanged() {
    guard fontChoices.indices.contains(fontPopup.indexOfSelectedItem) else { return }
    var value = store.settings; value.terminalFontName = fontChoices[fontPopup.indexOfSelectedItem].name; save(value)
  }
  @objc func textColorModeChanged() {
    var value = store.settings
    let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    value.terminalTextColor = textColorMode.indexOfSelectedItem == 1 ? value.terminalTextColor ?? value.terminalTheme.palette(effectiveDark: dark).foreground.rgb : nil
    save(value)
  }
  @objc func textColorChanged() {
    guard let color = textColorWell.color.usingColorSpace(.sRGB) else { return }
    func component(_ value: CGFloat) -> UInt32 { UInt32(min(255, max(0, (value * 255).rounded()))) }
    var value = store.settings
    value.terminalTextColor = component(color.redComponent) << 16 | component(color.greenComponent) << 8 | component(color.blueComponent)
    save(value)
  }
  @objc private func themeSelected(_ sender: NSButton) {
    guard TerminalTheme.catalog.indices.contains(sender.tag) else { return }
    var value = store.settings; value.terminalTheme = TerminalTheme.catalog[sender.tag]; save(value)
  }
  @objc func decreaseSize() { changeSize(-1) }
  @objc func increaseSize() { changeSize(1) }
  private func changeSize(_ delta: Double) {
    var value = store.settings; value.terminalFontSize = min(28, max(10, value.terminalFontSize + delta)); save(value)
  }
  func controlTextDidEndEditing(_ notification: Notification) {
    guard notification.object as? NSTextField === sizeField else { return }
    guard let size = Double(sizeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)), size.isFinite, (10...28).contains(size) else {
      localError = "字号需为 10–28 点。"; display(store.settings, error: store.error); return
    }
    var value = store.settings; value.terminalFontSize = size; save(value)
  }
  @objc func toggleFontSection() { isFontExpanded.toggle(); layoutContent() }
  private func navigate(from index: Int, delta: Int) {
    let row = themeRows[min(themeRows.count - 1, max(0, index + delta))]
    row.performClick(nil); view.window?.makeFirstResponder(row); _ = row.scrollToVisible(row.bounds)
  }
  private static func sizeText(_ value: Double) -> String { value.rounded() == value ? String(Int(value)) : String(value) }

  private func renderPreviewSample() {
    // This unconnected preview regenerates its sample after geometry/font changes.
    // Existing SSH terminals keep their own output and are never cleared here.
    preview.feed(text: "\u{1B}[3J\u{1B}[2J\u{1B}[H\u{1B}[1mShell · 终端预览\u{1B}[0m\r\n\r\n\u{1B}[32mdeploy@production\u{1B}[0m ~ % ls\r\n\u{1B}[34mprojects/\u{1B}[0m   README.md   \u{1B}[36mserver.log\u{1B}[0m\r\n\r\n\u{1B}[32mSUCCESS\u{1B}[0m  服务运行正常\r\n\u{1B}[33mWARNING\u{1B}[0m  磁盘使用率 78%\r\n\u{1B}[31mERROR\u{1B}[0m    连接超时，请重试\r\n\r\n标准色\r\n")
    for code in 30...37 { preview.feed(text: "\u{1B}[\(code)m●● \u{1B}[0m") }
    preview.feed(text: "\r\n明亮色\r\n")
    for code in 90...97 { preview.feed(text: "\u{1B}[\(code)m●● \u{1B}[0m") }
    preview.feed(text: "\r\n\r\ndeploy@production ~ % ")
  }

  private func layoutContent() {
    guard isViewLoaded else { return }
    let width = root.bounds.width, height = root.bounds.height, wide = width >= 740
    heading.frame = NSRect(x: 20, y: 20, width: width - 40, height: 26)
    appLabel.frame = NSRect(x: 20, y: 60, width: 76, height: 22)
    themePopup.frame = NSRect(x: 100, y: 56, width: wide ? 180 : max(0, width - 120), height: 28)
    let previewWidth = wide ? width - 380 : width - 40
    previewTitle.frame = NSRect(x: 20, y: 96, width: previewWidth, height: 20)
    preview.frame = NSRect(x: 20, y: 122, width: previewWidth, height: wide ? max(0, height - 142) : 170)
    if previewGeometry != preview.frame.size { previewGeometry = preview.frame.size; renderPreviewSample() }
    scroll.frame = wide ? NSRect(x: width - 340, y: 56, width: 320, height: max(0, height - 76))
      : NSRect(x: 20, y: 308, width: width - 40, height: max(0, height - 328))
    let contentWidth = max(300, scroll.contentSize.width), inner = contentWidth - 32
    fontToggle.frame = NSRect(x: 16, y: 16, width: inner, height: 28)
    fontToggle.image = NSImage(systemSymbolName: isFontExpanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
    var y: CGFloat = 56
    for child in [fontPopup, sizeLabel, sizeField, decreaseButton, increaseButton, textColorLabel, textColorMode, textColorWell] { child.isHidden = !isFontExpanded }
    if isFontExpanded {
      fontPopup.frame = NSRect(x: 16, y: y, width: inner, height: 32); y += 46
      sizeLabel.frame = NSRect(x: 16, y: y + 7, width: 82, height: 22)
      decreaseButton.frame = NSRect(x: contentWidth - 160, y: y, width: 40, height: 34)
      sizeField.frame = NSRect(x: contentWidth - 114, y: y + 3, width: 50, height: 28)
      increaseButton.frame = NSRect(x: contentWidth - 58, y: y, width: 42, height: 34); y += 52
      textColorLabel.frame = NSRect(x: 16, y: y + 6, width: 64, height: 22)
      textColorMode.frame = NSRect(x: 84, y: y, width: inner - 126, height: 30)
      textColorWell.frame = NSRect(x: contentWidth - 68, y: y, width: 52, height: 30); y += 44
    }
    if !fontNotice.isHidden { fontNotice.frame = NSRect(x: 16, y: y, width: inner, height: 42); y += 50 }
    if !errorLabel.isHidden { errorLabel.frame = NSRect(x: 16, y: y, width: inner, height: 48); y += 56 }
    themesTitle.frame = NSRect(x: 16, y: y, width: inner, height: 22); y += 34
    for row in themeRows { row.frame = NSRect(x: 8, y: y, width: contentWidth - 16, height: 76); row.needsLayout = true; y += 82 }
    document.frame = NSRect(x: 0, y: 0, width: contentWidth, height: y + 10)
  }
}

final class TerminalThemeRow: NSButton {
  let theme: TerminalTheme
  let thumbnail = TerminalThemeThumbnail(frame: .zero)
  private let nameLabel = NSTextField(labelWithString: "")
  private let checkmark = NSImageView()
  var onNavigate: ((Int) -> Void)?
  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  init(theme: TerminalTheme) {
    self.theme = theme; super.init(frame: .zero)
    isBordered = false; setButtonType(.momentaryChange)
    nameLabel.stringValue = theme.displayName; nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
    nameLabel.lineBreakMode = .byTruncatingTail
    checkmark.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
    checkmark.contentTintColor = .systemGreen; checkmark.setAccessibilityElement(false)
    for child in [thumbnail, nameLabel, checkmark] { addSubview(child) }
    setAccessibilityRole(.radioButton); setAccessibilityLabel(theme.displayName)
  }
  required init?(coder: NSCoder) { fatalError("unsupported") }
  func setSelected(_ selected: Bool) {
    state = selected ? .on : .off; checkmark.isHidden = !selected
    nameLabel.textColor = selected ? .systemGreen : .labelColor
    setAccessibilityValue(selected ? 1 : 0); needsDisplay = true
  }
  override func layout() {
    super.layout()
    thumbnail.frame = NSRect(x: 10, y: 9, width: 96, height: 58)
    nameLabel.frame = NSRect(x: 118, y: 19, width: max(0, bounds.width - 130), height: 20)
    checkmark.frame = NSRect(x: 118, y: 43, width: 16, height: 16)
  }
  override func draw(_ dirtyRect: NSRect) {
    if state == .on {
      NSColor.selectedContentBackgroundColor.withAlphaComponent(0.12).setFill()
      NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 12, yRadius: 12).fill()
    }
  }
  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 125: onNavigate?(1)
    case 126: onNavigate?(-1)
    case 36, 76: performClick(nil)
    default: super.keyDown(with: event)
    }
  }
  override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 12, yRadius: 12).fill() }
  override var focusRingMaskBounds: NSRect { bounds }
  override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
}

final class TerminalThemeThumbnail: NSView {
  var palette = TerminalTheme.graphite.palette(effectiveDark: true) { didSet { needsDisplay = true } }
  override var isFlipped: Bool { true }
  override func draw(_ dirtyRect: NSRect) {
    palette.background.nativeColor.setFill(); NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7).fill()
    let lines: [(CGFloat, CGFloat, CGFloat, TerminalColor)] = [(8, 9, 79, palette.foreground), (8, 19, 51, palette.foreground),
      (63, 19, 24, palette.foreground), (8, 30, 24, palette.ansi[2]), (36, 30, 24, palette.foreground), (65, 30, 15, palette.cursor)]
    for (x, y, width, color) in lines {
      color.nativeColor.setFill(); NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: 5), xRadius: 2, yRadius: 2).fill()
    }
    for index in 0..<8 { palette.ansi[index].nativeColor.setFill(); NSRect(x: 5 + CGFloat(index) * 10.75, y: 46, width: 10.75, height: 6).fill() }
    NSColor.separatorColor.setStroke(); NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7).stroke()
  }
}

private final class AppearanceRootView: ChromeView {
  var onLayout: (() -> Void)?, onAppearance: (() -> Void)?
  override var isFlipped: Bool { true }
  override func layout() { super.layout(); onLayout?() }
  override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); onAppearance?() }
}
