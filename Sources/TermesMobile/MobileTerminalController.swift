import UIKit
import SnapKit
import SwiftTerm
import TermesKit

@MainActor
final class MobileTerminalController: UIViewController, @preconcurrency TerminalViewDelegate {
  let terminal: TerminalView
  private let manager: SessionManager
  private var appliedSettings: AppearanceSettings?
  private var appliedDark: Bool?
  private(set) var hasUnseenOutput = false
  private(set) lazy var newOutputButton: UIButton = {
    let button = MobileUI.button("有新输出 · 回到底部", symbol: "arrow.down", filled: true,
      id: "terminal.newOutput") { [weak self] in self?.scrollToLatest() }
    button.configuration?.baseBackgroundColor = .secondarySystemBackground
    button.configuration?.baseForegroundColor = .label
    button.configuration?.cornerStyle = .capsule
    button.configuration?.background.strokeColor = .separator
    button.configuration?.background.strokeWidth = 0.5
    button.accessibilityLabel = "有新的终端输出，回到底部"
    button.accessibilityHint = "滚动到最新输出并继续跟随"
    button.layer.shadowColor = UIColor.black.cgColor
    button.layer.shadowOpacity = 0.18
    button.layer.shadowRadius = 6
    button.layer.shadowOffset = CGSize(width: 0, height: 2)
    button.isHidden = true
    return button
  }()

  init(manager: SessionManager) {
    self.manager = manager
    var options = TerminalOptions.default
    #if DEBUG
    // A repeating caret animation prevents XCTest from reaching UI quiescence.
    if ProcessInfo.processInfo.environment["TERMES_UI_TESTING"] == "1" { options.cursorStyle = .steadyBlock }
    #endif
    terminal = MobileTerminalView(frame: .zero, font: nil, options: options)
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func loadView() {
    view = UIView()
    terminal.terminalDelegate = self
    terminal.accessibilityIdentifier = "terminal.surface"
    terminal.keyboardDismissMode = .interactive
    terminal.contentInsetAdjustmentBehavior = .never
    view.addSubview(terminal)
    terminal.snp.makeConstraints { make in
      make.leading.trailing.equalToSuperview().inset(6)
      make.top.bottom.equalToSuperview()
    }
    // Overlaying the notice keeps the terminal grid and the history viewport unchanged.
    view.addSubview(newOutputButton)
    newOutputButton.snp.makeConstraints { make in
      make.centerX.equalTo(terminal)
      make.bottom.equalTo(terminal).inset(12)
      make.leading.greaterThanOrEqualToSuperview().offset(12)
      make.trailing.lessThanOrEqualToSuperview().inset(12)
      make.height.greaterThanOrEqualTo(44)
    }
    (terminal as? MobileTerminalView)?.onViewportChanged = { [weak self] in self?.updateOutputNotice() }
    manager.onData = { [weak self] data in self?.receiveOutput(data) }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    updateOutputNotice()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    hideKeyboard()
  }

  func apply(_ settings: AppearanceSettings, dark: Bool) {
    loadViewIfNeeded()
    guard settings != appliedSettings || dark != appliedDark else { return }
    appliedSettings = settings; appliedDark = dark
    let palette = settings.terminalTheme.palette(effectiveDark: dark)
    terminal.font = .monospacedSystemFont(ofSize: settings.terminalFontSize, weight: .regular)
    terminal.getTerminal().ansi256PaletteStrategy = .xterm
    terminal.nativeBackgroundColor = palette.background.uiColor
    terminal.nativeForegroundColor = TerminalColor(settings.terminalTextColor ?? palette.foreground.rgb).uiColor
    terminal.installColors(palette.ansi.map { SwiftTerm.Color(red: UInt16($0.red) * 257,
      green: UInt16($0.green) * 257, blue: UInt16($0.blue) * 257) })
    terminal.caretColor = palette.cursor.uiColor
    terminal.caretTextColor = palette.background.uiColor
    terminal.selectedTextBackgroundColor = palette.selection.uiColor
    terminal.selectedTextForegroundColor = palette.selectionForeground.uiColor
    terminal.keyboardAppearance = dark ? .dark : .light
    view.backgroundColor = palette.background.uiColor
    terminal.setNeedsDisplay()
  }

  func showKeyboard() { _ = terminal.becomeFirstResponder() }
  func hideKeyboard() { _ = terminal.resignFirstResponder() }
  func shutdown() {
    manager.onData = nil; terminal.terminalDelegate = nil
    (terminal as? MobileTerminalView)?.onViewportChanged = nil
    hasUnseenOutput = false
    if isViewLoaded { updateOutputNotice() }
  }

  private var isReadingHistory: Bool { terminal.canScroll && terminal.scrollPosition < 1 }

  private func receiveOutput(_ data: Data) {
    guard !data.isEmpty else { return }
    let wasReadingHistory = isReadingHistory
    terminal.feed(byteArray: Array(data)[...])
    if wasReadingHistory && isReadingHistory { hasUnseenOutput = true }
    updateOutputNotice()
  }

  private func updateOutputNotice() {
    // No history and alternate screens also report position zero.
    if !isReadingHistory { hasUnseenOutput = false }
    let hidden = !hasUnseenOutput
    if newOutputButton.isHidden != hidden { newOutputButton.isHidden = hidden }
  }

  private func scrollToLatest() {
    terminal.scroll(toPosition: 1)
    hasUnseenOutput = false
    updateOutputNotice()
  }

  func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
    guard newCols > 0, newRows > 0 else { return }
    manager.resize(cols: newCols, rows: newRows)
    updateOutputNotice()
  }

  func send(source: TerminalView, data: ArraySlice<UInt8>) { manager.sendInput(Data(data)) }
  func setTerminalTitle(source: TerminalView, title: String) {}
  func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
  func scrolled(source: TerminalView, position: Double) { updateOutputNotice() }
  func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
  func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
    guard let url = URL(string: link), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return }
    UIApplication.shared.open(url)
  }
  func bell(source: TerminalView) { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
}

final class MobileTerminalView: TerminalView {
  var onViewportChanged: (() -> Void)?

  override func deleteBackward() {
    guard let marked = markedTextRange else {
      super.deleteBackward()
      return
    }
    // Preedit text has not reached SSH. SwiftTerm's default deletion sends
    // backspaces for the whole marked range, erasing previously committed input.
    guard let composition = text(in: marked), !composition.isEmpty,
      let selection = selectedTextRange else { return }
    let length = composition.utf16.count
    let selectionStart = min(max(offset(from: marked.start, to: selection.start), 0), length)
    let selectionEnd = min(max(offset(from: marked.start, to: selection.end), selectionStart), length)
    // UITextInput positions use UTF-16 offsets; deletion must still respect
    // complete grapheme clusters, including combining accents and joined emoji.
    let boundaries = Array(composition.indices) + [composition.endIndex]
    guard let start = boundaries.last(where: { $0.utf16Offset(in: composition) <= selectionStart }),
      let end = boundaries.first(where: { $0.utf16Offset(in: composition) >= selectionEnd }) else { return }
    let deletionStart: String.Index
    if selectionStart == selectionEnd && start == end {
      guard start > composition.startIndex else { return }
      deletionStart = composition.index(before: start)
    } else {
      deletionStart = start
    }
    let caretOffset = deletionStart.utf16Offset(in: composition)
    var updated = composition
    updated.removeSubrange(deletionStart..<end)
    setMarkedText(updated.isEmpty ? nil : updated,
      selectedRange: NSRange(location: caretOffset, length: 0))
  }

  // SwiftTerm's iOS gestures update contentOffset without calling the scrolled delegate.
  override var contentOffset: CGPoint {
    didSet { onViewportChanged?() }
  }
}

private extension TerminalColor {
  var uiColor: UIColor {
    UIColor(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255, alpha: alpha)
  }
}
