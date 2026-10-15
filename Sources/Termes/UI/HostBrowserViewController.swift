import AppKit
import Combine
import TermesKit

@MainActor
final class HostBrowserViewController: NSViewController, NSSearchFieldDelegate {
  let model: ServerListModel
  let searchField = NSSearchField()
  let connectButton = NSButton(title: "连接", target: nil, action: nil)
  let newButton = NSButton(title: "新建主机", target: nil, action: nil)
  let editButton = NSButton(title: "编辑…", target: nil, action: nil)
  let displayMode = NSSegmentedControl(images: [
    NSImage(systemSymbolName: "square.grid.2x2.fill", accessibilityDescription: "卡片")!,
    NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "列表")!,
  ], trackingMode: .selectOne, target: nil, action: nil)
  var onOpen: ((UUID) -> Void)?
  var onEdit: ((UUID) -> Void)?
  var onNew: (() -> Void)?
  private(set) var cards: [HostCardView] = []
  private(set) var columnCount = 1
  private let root = VaultLayoutView(frame: .init(x: 0, y: 0, width: 940, height: 700))
  private let heading = NSTextField(labelWithString: "Hosts")
  private let count = NSTextField(labelWithString: "")
  private let emptyTitle = NSTextField(labelWithString: "")
  private let emptyHint = NSTextField(wrappingLabelWithString: "")
  private let emptyIcon = NSImageView()
  private let scroll = NSScrollView()
  private let document = HostGridView(frame: .zero)
  private var observer: AnyCancellable?
  private var isList = false

  init(model: ServerListModel) { self.model = model; super.init(nibName: nil, bundle: nil) }
  required init?(coder: NSCoder) { fatalError("unsupported") }

  override func loadView() {
    view = root; root.fillColor = TermesColors.vaultBackground
    heading.font = .systemFont(ofSize: 17, weight: .semibold)
    count.font = .systemFont(ofSize: 12); count.textColor = .secondaryLabelColor; count.alignment = .right
    searchField.placeholderString = "搜索主机、地址或用户名…"
    searchField.controlSize = .large; searchField.font = .systemFont(ofSize: 14)
    searchField.delegate = self; searchField.sendsSearchStringImmediately = true
    searchField.setAccessibilityLabel("搜索主机")
    for (button, action) in [(connectButton, #selector(connectTapped)), (newButton, #selector(newTapped)), (editButton, #selector(editTapped))] {
      button.bezelStyle = .rounded; button.controlSize = .large
      button.target = self; button.action = action
    }
    newButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
    newButton.imagePosition = .imageLeading
    newButton.toolTip = "新建并保存 SSH 主机 (⌘T)"
    displayMode.selectedSegment = 0; displayMode.target = self; displayMode.action = #selector(displayChanged)
    displayMode.setAccessibilityLabel("主机显示方式：卡片或列表")
    displayMode.setToolTip("卡片视图", forSegment: 0); displayMode.setToolTip("列表视图", forSegment: 1)
    scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
    scroll.automaticallyAdjustsContentInsets = false; scroll.scrollerStyle = .overlay
    scroll.documentView = document
    document.setAccessibilityLabel("已保存的主机")
    document.onKey = { [weak self] key in self?.navigate(key) }
    emptyIcon.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)
    emptyIcon.contentTintColor = .tertiaryLabelColor
    emptyTitle.font = .systemFont(ofSize: 18, weight: .medium); emptyTitle.alignment = .center
    emptyHint.font = .systemFont(ofSize: 13); emptyHint.textColor = .secondaryLabelColor; emptyHint.alignment = .center
    for child in [searchField, connectButton, newButton, editButton, displayMode, heading, count, scroll, emptyIcon, emptyTitle, emptyHint] {
      root.addSubview(child)
    }
    root.onLayout = { [weak self] in self?.layoutContent() }
    observer = model.objectWillChange.sink { [weak self] in
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.reload() } }
    }
    reload()
  }

  func focusSearch() { _ = view; view.window?.makeFirstResponder(searchField) }
  func controlTextDidChange(_ obj: Notification) { model.search = searchField.stringValue; reload() }
  func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
    if commandSelector == #selector(NSResponder.insertNewline(_:)) {
      if !model.filteredProfiles.contains(where: { $0.id == model.selectedID }) {
        model.select(model.filteredProfiles.first?.id)
      }
      reload(); connectTapped(); return true
    }
    if commandSelector == #selector(NSResponder.moveDown(_:)), let first = cards.first {
      select(first.profileID); view.window?.makeFirstResponder(document); return true
    }
    return false
  }

  private func reload() {
    guard isViewLoaded else { return }
    let profiles = model.filteredProfiles
    if cards.map(\.profileID) != profiles.map(\.id) {
      cards.forEach { $0.removeFromSuperview() }
      cards = profiles.map { profile in
        let card = HostCardView(profileID: profile.id)
        card.onSelect = { [weak self] in self?.select(profile.id) }
        card.onOpen = { [weak self] in self?.select(profile.id); self?.connectTapped() }
        card.onMenu = { [weak self] in self?.menu(for: profile.id) }
        document.addSubview(card)
        return card
      }
    }
    for (card, profile) in zip(cards, profiles) {
      card.apply(profile, status: model.status(for: profile.id),
        statusText: model.sessionText(for: profile.id), selected: model.selectedID == profile.id, list: isList)
    }
    if searchField.stringValue != model.search { searchField.stringValue = model.search }
    let selected = profiles.contains { $0.id == model.selectedID }
    connectButton.isEnabled = selected && model.error == nil; editButton.isEnabled = connectButton.isEnabled
    count.stringValue = model.search.isEmpty ? "\(model.profiles.count) 台主机" : "\(profiles.count) / \(model.profiles.count) 台主机"
    let empty = profiles.isEmpty || model.error != nil
    scroll.isHidden = empty
    for child in [emptyIcon, emptyTitle, emptyHint] { child.isHidden = !empty }
    emptyTitle.stringValue = model.error != nil ? "无法读取主机" : model.profiles.isEmpty ? "你的主机，从这里开始" : "没有找到匹配的主机"
    emptyHint.stringValue = model.error ?? (model.profiles.isEmpty ? "点击「新建主机」，保存后即可在 Vaults 中查看和连接。" : "试试其他名称、地址或用户名。")
    root.needsLayout = true
  }

  private func select(_ id: UUID) {
    model.select(id); reload()
    view.window?.makeFirstResponder(document)
  }
  private func navigate(_ key: UInt16) {
    if key == 36 || key == 76 { connectTapped(); return }
    let delta: Int
    switch key { case 123: delta = -1; case 124: delta = 1; case 125: delta = columnCount; case 126: delta = -columnCount; default: return }
    guard !cards.isEmpty else { return }
    let current = cards.firstIndex { $0.profileID == model.selectedID }
    let index = current.map { min(max(0, $0 + delta), cards.count - 1) } ?? 0
    select(cards[index].profileID); cards[index].scrollToVisible(cards[index].bounds)
  }
  @objc private func connectTapped() {
    guard connectButton.isEnabled, let id = model.selectedID else { return }
    onOpen?(id)
  }
  @objc private func editTapped() {
    guard editButton.isEnabled, let id = model.selectedID else { return }
    onEdit?(id)
  }
  @objc private func newTapped() { onNew?() }
  @objc private func displayChanged() { isList = displayMode.selectedSegment == 1; reload() }
  private func menu(for id: UUID) -> NSMenu {
    select(id)
    let menu = NSMenu()
    for (title, action) in [("连接", #selector(connectTapped)), ("编辑主机…", #selector(editTapped))] {
      menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
    }
    return menu
  }

  private func layoutContent() {
    let width = root.bounds.width, height = root.bounds.height
    let inset: CGFloat = width < 520 ? 20 : 28
    searchField.frame = .init(x: inset, y: 22, width: max(0, width - inset * 2 - 100), height: 38)
    connectButton.frame = .init(x: width - inset - 90, y: 25, width: 90, height: 32)
    newButton.frame = .init(x: inset, y: 80, width: 132, height: 32)
    editButton.frame = .init(x: inset + 142, y: 80, width: 80, height: 32)
    displayMode.frame = .init(x: width - inset - 76, y: 84, width: 76, height: 26)
    heading.frame = .init(x: inset, y: 144, width: max(0, width - inset * 2 - 120), height: 24)
    count.frame = .init(x: width - inset - 120, y: 148, width: 120, height: 18)
    scroll.frame = .init(x: inset, y: 186, width: max(0, width - inset * 2), height: max(0, height - 210))
    let available = scroll.contentSize.width, gap: CGFloat = 14
    columnCount = isList ? 1 : max(1, Int((available + gap) / (280 + gap)))
    let cardWidth = max(0, (available - CGFloat(columnCount - 1) * gap) / CGFloat(columnCount))
    let cardHeight: CGFloat = isList ? 76 : 96
    let rows = (cards.count + columnCount - 1) / columnCount
    document.frame = .init(x: 0, y: 0, width: available,
      height: max(scroll.contentSize.height, CGFloat(rows) * (cardHeight + gap) - gap))
    for (index, card) in cards.enumerated() {
      card.frame = .init(x: CGFloat(index % columnCount) * (cardWidth + gap),
        y: CGFloat(index / columnCount) * (cardHeight + gap), width: cardWidth, height: cardHeight)
      card.needsLayout = true
    }
    let hasIcon = height >= 430
    let center = 186 + max(0, (height - 186 - (hasIcon ? 150 : 88)) / 2)
    emptyIcon.isHidden = emptyTitle.isHidden || !hasIcon
    emptyIcon.frame = .init(x: (width - 44) / 2, y: center, width: 44, height: 44)
    emptyTitle.frame = .init(x: inset, y: center + (hasIcon ? 62 : 0), width: max(0, width - inset * 2), height: 26)
    emptyHint.frame = .init(x: inset + 8, y: center + (hasIcon ? 102 : 38), width: max(0, width - inset * 2 - 16), height: 48)
  }
}

private final class HostGridView: NSView {
  var onKey: ((UInt16) -> Void)?
  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  override func keyDown(with event: NSEvent) {
    if [36, 76, 123, 124, 125, 126].contains(event.keyCode) { onKey?(event.keyCode) }
    else { super.keyDown(with: event) }
  }
}

final class HostCardView: NSControl {
  let profileID: UUID
  var onSelect: (() -> Void)?
  var onOpen: (() -> Void)?
  var onMenu: (() -> NSMenu?)?
  private let name = NSTextField(labelWithString: "")
  private let endpoint = NSTextField(labelWithString: "")
  private let statusLabel = NSTextField(labelWithString: "")
  private let iconTile = NSView()
  private let icon = NSImageView()
  private var selected = false
  private var status = SessionStatus.idle
  private var list = false
  init(profileID: UUID) {
    self.profileID = profileID
    super.init(frame: .zero)
    wantsLayer = true; layer?.cornerRadius = 16
    iconTile.wantsLayer = true; iconTile.layer?.cornerRadius = 12
    iconTile.layer?.backgroundColor = NSColor(srgbRed: 0.19, green: 0.39, blue: 0.72, alpha: 1).cgColor
    icon.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)
    icon.contentTintColor = .white; icon.imageScaling = .scaleProportionallyUpOrDown
    iconTile.addSubview(icon)
    name.font = .systemFont(ofSize: 15, weight: .medium)
    endpoint.font = .systemFont(ofSize: 12); endpoint.textColor = .secondaryLabelColor
    statusLabel.font = .systemFont(ofSize: 10, weight: .medium)
    for label in [name, endpoint, statusLabel] { label.lineBreakMode = .byTruncatingTail }
    for child in [iconTile, name, endpoint, statusLabel] { addSubview(child) }
    setAccessibilityElement(true); setAccessibilityRole(.radioButton)
  }
  required init?(coder: NSCoder) { fatalError("unsupported") }
  override var isFlipped: Bool { true }
  func apply(_ profile: ConnectionProfile, status: SessionStatus, statusText: String, selected: Bool, list: Bool) {
    self.selected = selected; self.status = status; self.list = list
    name.stringValue = profile.name
    let host = profile.hostname.contains(":") ? "[\(profile.hostname)]" : profile.hostname
    endpoint.stringValue = "\(profile.username)@\(host)" + (profile.port == 22 ? "" : ":\(profile.port)")
    statusLabel.stringValue = status == .idle ? "SSH" : "● " + statusText
    statusLabel.textColor = status == .idle ? .tertiaryLabelColor : TabItemView.color(for: status)
    toolTip = "\(profile.name)\n\(endpoint.stringValue)\n\(statusText)\n双击连接"
    setAccessibilityLabel("\(profile.name)，\(endpoint.stringValue)，\(statusText)")
    setAccessibilityValue(selected ? 1 : 0)
    updateColor(); needsLayout = true
  }
  override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColor() }
  private func updateColor() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = TermesColors.vaultCard.cgColor
      layer?.borderColor = (selected ? NSColor.controlAccentColor : NSColor.separatorColor.withAlphaComponent(0.18)).cgColor
      layer?.borderWidth = selected ? 2 : 1
    }
  }
  override func layout() {
    super.layout()
    let y = (bounds.height - 48) / 2
    iconTile.frame = .init(x: 16, y: y, width: 48, height: 48)
    icon.frame = .init(x: 12, y: 12, width: 24, height: 24)
    let labelWidth = max(0, bounds.width - 96 - (list && status != .idle ? 128 : 0))
    name.frame = .init(x: 80, y: list ? 16 : 17, width: labelWidth, height: 22)
    endpoint.frame = .init(x: 80, y: list ? 41 : 43, width: labelWidth, height: 18)
    statusLabel.isHidden = list && status == .idle
    statusLabel.frame = list
      ? .init(x: bounds.width - 136, y: 30, width: 120, height: 16)
      : .init(x: 80, y: 68, width: labelWidth, height: 15)
  }
  override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
  override func mouseDown(with event: NSEvent) { if event.clickCount == 2 { onOpen?() } else { onSelect?() } }
  override func menu(for event: NSEvent) -> NSMenu? { onMenu?() }
  override func accessibilityPerformPress() -> Bool { onSelect?(); return true }
}
