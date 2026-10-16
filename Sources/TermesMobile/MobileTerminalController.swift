import UIKit
import SnapKit
import SwiftTerm
import TermesKit

@MainActor
final class MobileTerminalController: UIViewController, TerminalViewDelegate, UITextFieldDelegate {
  let terminal: TerminalView
  private let manager: SessionManager
  private var appliedSettings: AppearanceSettings?
  private var appliedDark: Bool?
  let searchField = UISearchTextField()
  let searchStatus = UILabel()
  private(set) var searchBar = UIStackView()
  private var restoreTerminalFocus = false
  private var searchRefresh: Task<Void, Never>?
  var isSearching: Bool { isViewLoaded && !searchBar.isHidden }
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
    searchField.placeholder = "搜索终端历史"
    searchField.accessibilityIdentifier = "terminal.search"
    searchField.autocorrectionType = .no; searchField.autocapitalizationType = .none
    searchField.spellCheckingType = .no; searchField.returnKeyType = .search
    searchField.delegate = self
    searchField.addAction(UIAction { [weak self] _ in self?.refreshSearch(reset: true) }, for: .editingChanged)
    searchStatus.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    searchStatus.accessibilityIdentifier = "terminal.searchStatus"
    searchStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    func button(_ image: String, _ title: String, _ id: String, action: @escaping () -> Void) -> UIButton {
      let button = UIButton(type: .system)
      button.setImage(UIImage(systemName: image), for: .normal)
      button.accessibilityLabel = title; button.accessibilityIdentifier = id
      button.addAction(UIAction { _ in action() }, for: .touchUpInside)
      button.snp.makeConstraints { $0.width.equalTo(36); $0.height.equalTo(44) }
      return button
    }
    searchBar = MobileUI.stack([searchField, searchStatus,
      button("chevron.up", "上一个匹配", "terminal.searchPrevious") { [weak self] in self?.navigateSearch(forward: false) },
      button("chevron.down", "下一个匹配", "terminal.searchNext") { [weak self] in self?.navigateSearch(forward: true) },
      button("xmark", "关闭搜索", "terminal.searchClose") { [weak self] in self?.closeSearch() }], axis: .horizontal, spacing: 4)
    searchBar.isHidden = true
    searchField.snp.makeConstraints { $0.width.greaterThanOrEqualTo(60).priority(750) }
    let column = MobileUI.stack([searchBar, terminal], spacing: 0)
    view.addSubview(column)
    column.snp.makeConstraints { make in
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
    let background = palette.background
    let brightness = Int(background.red) * 299 + Int(background.green) * 587 + Int(background.blue) * 114
    searchBar.overrideUserInterfaceStyle = brightness < 128_000 ? .dark : .light
    searchField.textColor = palette.foreground.uiColor
    searchStatus.textColor = palette.foreground.uiColor
    terminal.font = settings.terminalFontName.flatMap { UIFont(name: $0, size: settings.terminalFontSize) }
      ?? .monospacedSystemFont(ofSize: settings.terminalFontSize, weight: .regular)
    terminal.ansi256PaletteStrategy = .xterm
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
    if isSearching { view.layoutIfNeeded(); refreshSearch(reset: true) }
  }

  func showKeyboard() { _ = terminal.becomeFirstResponder() }
  func hideKeyboard() { _ = terminal.resignFirstResponder() }
  func shutdown() {
    manager.onData = nil; terminal.terminalDelegate = nil
    (terminal as? MobileTerminalView)?.onViewportChanged = nil
    hasUnseenOutput = false
    searchRefresh?.cancel(); searchRefresh = nil
    if isViewLoaded { updateOutputNotice() }
  }

  func showSearch() {
    loadViewIfNeeded()
    if searchBar.isHidden { restoreTerminalFocus = terminal.isFirstResponder }
    searchBar.isHidden = false
    refreshSearch(reset: true)
    searchField.becomeFirstResponder()
  }
  func closeSearch() {
    terminal.clearSearch()
    searchField.resignFirstResponder()
    searchBar.isHidden = true
    searchRefresh?.cancel(); searchRefresh = nil
    if restoreTerminalFocus { showKeyboard() }
  }
  func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    navigateSearch(forward: true); return false
  }
  func navigateSearch(forward: Bool) {
    guard isSearching else { showSearch(); return }
    let query = searchField.text ?? ""
    if !query.isEmpty {
      if forward { terminal.findNext(query) } else { terminal.findPrevious(query) }
    }
    refreshSearch(reset: false)
  }
  func refreshSearch(reset: Bool) {
    let query = searchField.text ?? ""
    if reset { terminal.clearSearch(); if !query.isEmpty { terminal.findNext(query) } }
    let summary = terminal.searchMatchSummary(query, limit: 1001)
    searchStatus.text = query.isEmpty ? "" : summary.total == 0 ? "无匹配"
      : summary.total > 1000 ? "1000+" : summary.index == 0 ? "\(summary.total) 项" : "\(summary.index)/\(summary.total)"
  }
  func exportSnapshot() -> Data { terminal.getBufferAsData() }
  func exportOutput(from presenter: UIViewController) {
    presenter.view.endEditing(true)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Termes-Export-\(UUID())", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let url = directory.appendingPathComponent("termes-terminal.txt")
      try exportSnapshot().write(to: url, options: [.atomic, .completeFileProtection])
      let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
      activity.popoverPresentationController?.sourceView = presenter.view
      activity.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.safeAreaInsets.top, width: 1, height: 1)
      activity.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: directory) }
      presenter.present(activity, animated: true)
    } catch {
      try? FileManager.default.removeItem(at: directory)
      presenter.presentError(error.localizedDescription)
    }
  }

  private var isReadingHistory: Bool { terminal.canScroll && terminal.scrollPosition < 1 }

  private func receiveOutput(_ data: Data) {
    guard !data.isEmpty else { return }
    let wasReadingHistory = isReadingHistory
    terminal.feed(byteArray: Array(data)[...])
    if wasReadingHistory && isReadingHistory { hasUnseenOutput = true }
    updateOutputNotice()
    if isSearching, searchRefresh == nil {
      searchRefresh = Task { @MainActor [weak self] in
        do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
        self?.searchRefresh = nil
        self?.refreshSearch(reset: false)
      }
    }
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
  private var viewportNotificationPending = false
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
    didSet {
      guard contentOffset != oldValue, onViewportChanged != nil, !viewportNotificationPending else { return }
      // Layout can change the offset while SwiftTerm holds its non-recursive
      // engine lock. Notify after it returns so the observer can read the viewport.
      viewportNotificationPending = true
      Task { @MainActor [weak self] in
        guard let self else { return }
        viewportNotificationPending = false
        onViewportChanged?()
      }
    }
  }
}

private extension TerminalColor {
  var uiColor: UIColor {
    UIColor(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255, alpha: alpha)
  }
}
