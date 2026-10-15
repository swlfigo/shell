import Foundation

/// One tab: a pane tree. One pane = ordinary tab; two or more = workspace.
public struct Tab: Equatable, Identifiable, Sendable, Codable {
  public let id: UUID
  public internal(set) var root: PaneNode
  public internal(set) var focusedPane: UUID
  public internal(set) var maximizedPane: UUID?

  init(pane: UUID) {
    id = UUID()
    root = .pane(pane)
    focusedPane = pane
  }

  public var paneIds: [UUID] { root.paneIds }
  public var isWorkspace: Bool { paneIds.count > 1 }
}

/// All tabs and panes of one window: the single source of truth for structure. A pure value
/// type; invalid requests (unknown ids, rejected merges) leave it unchanged. Invariants: spec §3.2.
public struct WindowLayout: Equatable, Sendable, Codable {
  public private(set) var tabs: [Tab] = []
  public private(set) var selectedTabId: UUID?

  public init() {}

  public var selectedTab: Tab? { tabs.first { $0.id == selectedTabId } }
  public var allPaneIds: [UUID] { tabs.flatMap(\.paneIds) }
  public func tab(containing pane: UUID) -> Tab? { tabs.first { $0.root.contains(pane) } }

  private func index(of tab: UUID) -> Int? { tabs.firstIndex { $0.id == tab } }
  private func index(containing pane: UUID) -> Int? { tabs.firstIndex { $0.root.contains(pane) } }

  /// New single-pane tab after `tab` (or at the end), selected. A pane already in the layout is
  /// not added again; its tab's id is returned.
  @discardableResult
  public mutating func addTab(pane: UUID, after tab: UUID? = nil) -> UUID {
    if let existing = self.tab(containing: pane) { return existing.id }
    let t = Tab(pane: pane)
    let at = tab.flatMap { index(of: $0) }.map { $0 + 1 } ?? tabs.count
    tabs.insert(t, at: at)
    selectedTabId = t.id
    return t.id
  }

  public mutating func select(tab: UUID) {
    if index(of: tab) != nil { selectedTabId = tab }
  }

  /// 0-based (⌘1 → 0); out of range is ignored.
  public mutating func selectTab(at i: Int) {
    if tabs.indices.contains(i) { selectedTabId = tabs[i].id }
  }

  public mutating func selectNext() { step(1) }
  public mutating func selectPrevious() { step(-1) }

  private mutating func step(_ delta: Int) {
    guard let id = selectedTabId, let i = index(of: id) else { return }
    selectedTabId = tabs[(i + delta + tabs.count) % tabs.count].id
  }

  /// Moves a tab so that it ends up at `index` (clamped) in the resulting array.
  public mutating func moveTab(_ id: UUID, to index: Int) {
    guard let from = self.index(of: id) else { return }
    let t = tabs.remove(at: from)
    tabs.insert(t, at: min(max(index, 0), tabs.count))
  }

  /// Takes ownership of a complete tab without ending any of its sessions.
  public mutating func takeTab(_ id: UUID) -> Tab? {
    guard let i = index(of: id) else { return nil }
    let tab = tabs.remove(at: i)
    if selectedTabId == id { selectedTabId = tabs.isEmpty ? nil : tabs[min(i, tabs.count - 1)].id }
    return tab
  }

  @discardableResult
  public mutating func insertTab(_ tab: Tab, at index: Int) -> Bool {
    guard !tabs.contains(where: { $0.id == tab.id }),
          Set(allPaneIds).isDisjoint(with: tab.paneIds) else { return false }
    tabs.insert(tab, at: min(max(index, 0), tabs.count))
    selectedTabId = tab.id
    return true
  }

  /// Extracts a workspace's individual pane, normalizing the remaining split tree.
  public mutating func takePane(_ pane: UUID) -> Tab? {
    guard let i = index(containing: pane) else { return nil }
    if !tabs[i].isWorkspace { return takeTab(tabs[i].id) }
    close(pane: pane)
    return Tab(pane: pane)
  }

  /// Moves single-pane tab `source` next to `pane` (in another tab) on `edge`, selects the target
  /// tab and focuses the moved pane. Rejected (false, unchanged): unknown ids, `source` is a
  /// workspace, or `pane` belongs to `source`.
  @discardableResult
  public mutating func merge(tab source: UUID, into pane: UUID, edge: PaneEdge) -> Bool {
    guard let si = index(of: source), !tabs[si].isWorkspace,
          let ti = index(containing: pane), ti != si else { return false }
    let moving = tabs[si].focusedPane
    tabs[ti].root = tabs[ti].root.inserting(moving, at: pane, edge: edge)
    tabs[ti].focusedPane = moving
    tabs[ti].maximizedPane = nil
    selectedTabId = tabs[ti].id
    tabs.remove(at: si)
    return true
  }

  /// Splits `pane` out of its workspace into a new tab right after it; the workspace stays
  /// selected. nil (unchanged) when the pane is unknown or its tab is not a workspace.
  @discardableResult
  public mutating func detach(pane: UUID) -> UUID? {
    guard let ti = index(containing: pane), tabs[ti].isWorkspace,
          let root = tabs[ti].root.removing(pane) else { return nil }
    let fallback = Self.neighbor(of: pane, in: tabs[ti].root)
    tabs[ti].root = root
    if tabs[ti].focusedPane == pane { tabs[ti].focusedPane = fallback }
    tabs[ti].maximizedPane = nil
    let t = Tab(pane: pane)
    tabs.insert(t, at: ti + 1)
    return t.id
  }

  /// Removes a pane. An emptied tab is removed and, if it was selected, the next tab (else the
  /// previous one, else none) becomes selected.
  public mutating func close(pane: UUID) {
    guard let ti = index(containing: pane) else { return }
    if let root = tabs[ti].root.removing(pane) {
      let fallback = Self.neighbor(of: pane, in: tabs[ti].root)
      tabs[ti].root = root
      if tabs[ti].focusedPane == pane { tabs[ti].focusedPane = fallback }
      tabs[ti].maximizedPane = nil
      return
    }
    let removed = tabs.remove(at: ti)
    if selectedTabId == removed.id {
      selectedTabId = tabs.isEmpty ? nil : tabs[min(ti, tabs.count - 1)].id
    }
  }

  public mutating func focus(pane: UUID) {
    guard let ti = index(containing: pane) else { return }
    tabs[ti].focusedPane = pane
  }

  /// Workspace only: maximizes `pane` (and focuses it), or restores when it is already maximized.
  public mutating func toggleMaximize(pane: UUID) {
    guard let ti = index(containing: pane), tabs[ti].isWorkspace else { return }
    if tabs[ti].maximizedPane == pane {
      tabs[ti].maximizedPane = nil
    } else {
      tabs[ti].maximizedPane = pane
      tabs[ti].focusedPane = pane
    }
  }

  public mutating func setFractions(_ fractions: [Double], split id: UUID) {
    for i in tabs.indices { tabs[i].root = tabs[i].root.settingFractions(fractions, split: id) }
  }

  /// Pre-order predecessor of `pane`, else its successor. Only called when `root` has ≥ 2 panes.
  private static func neighbor(of pane: UUID, in root: PaneNode) -> UUID {
    let ids = root.paneIds
    guard let i = ids.firstIndex(of: pane) else { return pane }
    return i > 0 ? ids[i - 1] : ids[i + 1]
  }
}
