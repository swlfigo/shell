import XCTest
@testable import TermesKit

final class WindowLayoutTests: XCTestCase {
  let A = UUID(), B = UUID(), C = UUID(), D = UUID()
  private var names: [UUID: String] { [A: "A", B: "B", C: "C", D: "D"] }
  /// Tabs as shapes in order, e.g. ["A", "H[B:0.5,C:0.5]"].
  private func shapes(_ l: WindowLayout) -> [String] { l.tabs.map { shape($0.root, names) } }
  private func selected(_ l: WindowLayout) -> String? { l.selectedTab.map { shape($0.root, names) } }

  /// Tabs A, B, C (in that order); C selected.
  private func threeTabs() -> WindowLayout {
    var l = WindowLayout()
    l.addTab(pane: A)
    l.addTab(pane: B)
    l.addTab(pane: C)
    return l
  }

  func test_addTab_appends_and_selects() {
    var l = WindowLayout()
    let t1 = l.addTab(pane: A)
    XCTAssertEqual(l.selectedTabId, t1)
    l.addTab(pane: B)
    XCTAssertEqual(shapes(l), ["A", "B"])
    XCTAssertEqual(selected(l), "B")
    assertInvariants(l)
  }

  func test_addTab_after_inserts_next_to_given_tab() {
    var l = WindowLayout()
    let ta = l.addTab(pane: A)
    l.addTab(pane: B)
    l.addTab(pane: C, after: ta)
    XCTAssertEqual(shapes(l), ["A", "C", "B"])
    XCTAssertEqual(selected(l), "C")
    assertInvariants(l)
  }

  func test_addTab_with_pane_already_present_is_noop() {
    var l = WindowLayout()
    let ta = l.addTab(pane: A)
    l.addTab(pane: B)
    let before = l
    XCTAssertEqual(l.addTab(pane: A), ta)
    XCTAssertEqual(l, before)
  }

  func test_select_by_index_ignores_out_of_range_and_next_previous_cycle() {
    var l = threeTabs()
    l.selectTab(at: 0); XCTAssertEqual(selected(l), "A")
    l.selectTab(at: 7); XCTAssertEqual(selected(l), "A")
    l.selectPrevious(); XCTAssertEqual(selected(l), "C")
    l.selectNext(); XCTAssertEqual(selected(l), "A")
    l.select(tab: UUID()); XCTAssertEqual(selected(l), "A")
  }

  func test_moveTab_uses_final_index_and_clamps() {
    var l = threeTabs()
    let ta = l.tabs[0].id
    l.moveTab(ta, to: 2); XCTAssertEqual(shapes(l), ["B", "C", "A"])
    l.moveTab(ta, to: -5); XCTAssertEqual(shapes(l), ["A", "B", "C"])
    l.moveTab(ta, to: 99); XCTAssertEqual(shapes(l), ["B", "C", "A"])
    assertInvariants(l)
  }

  func test_merge_moves_tab_next_to_target_pane_and_focuses_it() {
    var l = threeTabs()
    l.select(tab: l.tabs[1].id)                       // viewing B
    let tc = l.tabs[2].id
    XCTAssertTrue(l.merge(tab: tc, into: B, edge: .bottom))
    XCTAssertEqual(shapes(l), ["A", "V[B:0.5,C:0.5]"])
    XCTAssertEqual(selected(l), "V[B:0.5,C:0.5]")
    XCTAssertEqual(l.selectedTab?.focusedPane, C)
    XCTAssertEqual(l.selectedTab?.isWorkspace, true)
    assertInvariants(l)
  }

  func test_merge_rejections_leave_layout_unchanged() {
    var l = threeTabs()
    let ta = l.tabs[0].id
    XCTAssertTrue(l.merge(tab: l.tabs[1].id, into: A, edge: .right))   // [H[A,B], C]
    let tc = l.tabs[1].id
    let before = l
    XCTAssertFalse(l.merge(tab: ta, into: C, edge: .left))              // source is a workspace
    XCTAssertFalse(l.merge(tab: tc, into: C, edge: .left))              // into its own tab
    XCTAssertFalse(l.merge(tab: UUID(), into: A, edge: .left))          // unknown tab
    XCTAssertFalse(l.merge(tab: tc, into: UUID(), edge: .left))         // unknown pane
    XCTAssertEqual(l, before)
  }

  func test_merge_clears_maximize() {
    var l = threeTabs()
    XCTAssertTrue(l.merge(tab: l.tabs[1].id, into: A, edge: .right))
    l.toggleMaximize(pane: A)
    XCTAssertEqual(l.selectedTab?.maximizedPane, A)
    XCTAssertTrue(l.merge(tab: l.tabs[1].id, into: B, edge: .bottom))
    XCTAssertNil(l.selectedTab?.maximizedPane)
    assertInvariants(l)
  }

  func test_detach_inserts_new_tab_after_workspace_and_keeps_selection() {
    var l = threeTabs()
    XCTAssertTrue(l.merge(tab: l.tabs[1].id, into: A, edge: .right))   // [H[A,B], C], focus B
    let workspace = l.selectedTabId
    XCTAssertNotNil(l.detach(pane: B))
    XCTAssertEqual(shapes(l), ["A", "B", "C"])
    XCTAssertEqual(l.selectedTabId, workspace)
    XCTAssertEqual(l.selectedTab?.focusedPane, A)                       // focus was on B → neighbor
    assertInvariants(l)
  }

  func test_detach_unfocused_pane_keeps_focus() {
    var l = threeTabs()
    XCTAssertTrue(l.merge(tab: l.tabs[1].id, into: A, edge: .right))
    XCTAssertTrue(l.merge(tab: l.tabs[1].id, into: B, edge: .right))   // H[A,B,C], focus C
    l.detach(pane: A)
    XCTAssertEqual(shapes(l), ["H[B:0.5,C:0.5]", "A"])
    XCTAssertEqual(l.selectedTab?.focusedPane, C)
    assertInvariants(l)
  }

  func test_detach_from_single_pane_tab_is_noop() {
    var l = threeTabs()
    let before = l
    XCTAssertNil(l.detach(pane: A))
    XCTAssertEqual(l, before)
  }

  func test_close_pane_in_workspace_collapses_to_single_tab() {
    var l = threeTabs()
    XCTAssertTrue(l.merge(tab: l.tabs[1].id, into: A, edge: .right))
    l.close(pane: B)
    XCTAssertEqual(shapes(l), ["A", "C"])
    XCTAssertEqual(l.selectedTab?.isWorkspace, false)
    XCTAssertEqual(l.selectedTab?.focusedPane, A)
    assertInvariants(l)
  }

  func test_close_clears_maximize() {
    var l = threeTabs()
    XCTAssertTrue(l.merge(tab: l.tabs[1].id, into: A, edge: .right))
    XCTAssertTrue(l.merge(tab: l.tabs[1].id, into: B, edge: .right))
    l.toggleMaximize(pane: A)
    l.close(pane: B)
    XCTAssertNil(l.selectedTab?.maximizedPane)
    assertInvariants(l)
  }

  func test_closing_last_pane_selects_next_then_previous_then_nil() {
    var l = threeTabs()
    l.selectTab(at: 1)
    l.close(pane: B); XCTAssertEqual(selected(l), "C")
    l.close(pane: C); XCTAssertEqual(selected(l), "A")
    l.close(pane: A)
    XCTAssertNil(l.selectedTabId)
    XCTAssertTrue(l.tabs.isEmpty)
    assertInvariants(l)
  }

  func test_closing_unselected_tab_keeps_selection() {
    var l = threeTabs()
    l.close(pane: A)
    XCTAssertEqual(selected(l), "C")
    assertInvariants(l)
  }

  func test_toggle_maximize_only_in_workspace_and_toggles_off() {
    var l = threeTabs()
    l.toggleMaximize(pane: A)
    XCTAssertNil(l.tabs[0].maximizedPane)
    XCTAssertTrue(l.merge(tab: l.tabs[1].id, into: A, edge: .right))   // focus B
    l.toggleMaximize(pane: A)
    XCTAssertEqual(l.selectedTab?.maximizedPane, A)
    XCTAssertEqual(l.selectedTab?.focusedPane, A)
    l.toggleMaximize(pane: A)
    XCTAssertNil(l.selectedTab?.maximizedPane)
    assertInvariants(l)
  }

  func test_setFractions_updates_split_by_id() {
    var l = threeTabs()
    XCTAssertTrue(l.merge(tab: l.tabs[1].id, into: A, edge: .right))
    guard case .split(let sid, _, _, _) = l.tabs[0].root else { return XCTFail("expected split") }
    l.setFractions([1, 3], split: sid)
    XCTAssertEqual(shapes(l), ["H[A:0.25,B:0.75]", "C"])
    assertInvariants(l)
  }

  func test_focus_ignores_unknown_pane() {
    var l = threeTabs()
    let before = l
    l.focus(pane: UUID())
    XCTAssertEqual(l, before)
  }
}
