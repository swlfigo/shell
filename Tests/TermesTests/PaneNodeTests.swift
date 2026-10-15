import XCTest
@testable import TermesKit

final class PaneNodeTests: XCTestCase {
  let A = UUID(), B = UUID(), C = UUID(), D = UUID()
  private var names: [UUID: String] { [A: "A", B: "B", C: "C", D: "D"] }
  private func s(_ n: PaneNode?) -> String { n.map { shape($0, names) } ?? "nil" }
  private func rounded(_ a: [Double]) -> [Double] { a.map { ($0 * 1e6).rounded() / 1e6 } }

  func test_insert_right_of_lone_pane_creates_horizontal_split() {
    XCTAssertEqual(s(PaneNode.pane(A).inserting(B, at: A, edge: .right)), "H[A:0.5,B:0.5]")
  }

  func test_insert_top_puts_new_pane_first_in_vertical_split() {
    XCTAssertEqual(s(PaneNode.pane(A).inserting(B, at: A, edge: .top)), "V[B:0.5,A:0.5]")
  }

  func test_same_axis_insert_becomes_sibling_and_halves_target_share() {
    let n = PaneNode.pane(A).inserting(B, at: A, edge: .right).inserting(C, at: A, edge: .right)
    XCTAssertEqual(s(n), "H[A:0.25,C:0.25,B:0.5]")
  }

  func test_cross_axis_insert_nests_a_new_split() {
    let n = PaneNode.pane(A).inserting(B, at: A, edge: .right).inserting(C, at: B, edge: .bottom)
    XCTAssertEqual(s(n), "H[A:0.5,V[B:0.5,C:0.5]:0.5]")
  }

  func test_insert_at_unknown_target_is_noop() {
    XCTAssertEqual(PaneNode.pane(A).inserting(B, at: C, edge: .left), .pane(A))
  }

  func test_remove_collapses_single_child_and_flattens_same_axis() {
    let n = PaneNode.pane(A).inserting(B, at: A, edge: .right)
      .inserting(C, at: B, edge: .bottom)
      .inserting(D, at: C, edge: .right)
    XCTAssertEqual(s(n), "H[A:0.5,V[B:0.5,H[C:0.5,D:0.5]:0.5]:0.5]")
    XCTAssertEqual(s(n.removing(B)), "H[A:0.5,C:0.25,D:0.25]")
  }

  func test_remove_renormalizes_remaining_fractions() {
    let n = PaneNode.pane(A).inserting(B, at: A, edge: .right).inserting(C, at: B, edge: .right)
    XCTAssertEqual(s(n), "H[A:0.5,B:0.25,C:0.25]")
    XCTAssertEqual(s(n.removing(A)), "H[B:0.5,C:0.5]")
  }

  func test_remove_last_pane_returns_nil() {
    XCTAssertNil(PaneNode.pane(A).removing(A))
  }

  func test_setting_fractions_targets_split_by_id_and_validates() {
    let n = PaneNode.pane(A).inserting(B, at: A, edge: .right)
    guard case .split(let id, _, _, _) = n else { return XCTFail("expected split") }
    XCTAssertEqual(s(n.settingFractions([3, 1], split: id)), "H[A:0.75,B:0.25]")
    XCTAssertEqual(n.settingFractions([1], split: id), n)          // wrong count
    XCTAssertEqual(n.settingFractions([1, 0], split: id), n)       // non-positive
    XCTAssertEqual(n.settingFractions([3, 1], split: UUID()), n)   // unknown split
  }

  func test_minimum_size_adds_along_axis_and_maxes_across() {
    let m = PaneSize(width: 240, height: 140)
    XCTAssertEqual(PaneNode.pane(A).minimumSize(pane: m, divider: 1), m)
    let n = PaneNode.pane(A).inserting(B, at: A, edge: .right).inserting(C, at: B, edge: .bottom)
    XCTAssertEqual(n.minimumSize(pane: m, divider: 1), PaneSize(width: 481, height: 281))
  }

  func test_nearest_edge() {
    XCTAssertEqual(PaneEdge.nearest(x: 0.1, yFromTop: 0.5), .left)
    XCTAssertEqual(PaneEdge.nearest(x: 0.9, yFromTop: 0.5), .right)
    XCTAssertEqual(PaneEdge.nearest(x: 0.5, yFromTop: 0.1), .top)
    XCTAssertEqual(PaneEdge.nearest(x: 0.5, yFromTop: 0.95), .bottom)
  }

  func test_can_split_requires_room_for_two_minimum_panes() {
    let m = PaneSize(width: 240, height: 140)
    XCTAssertFalse(PaneEdge.canSplit(width: 480, height: 500, edge: .left, paneMin: m, divider: 1))
    XCTAssertTrue(PaneEdge.canSplit(width: 481, height: 500, edge: .right, paneMin: m, divider: 1))
    XCTAssertFalse(PaneEdge.canSplit(width: 900, height: 280, edge: .top, paneMin: m, divider: 1))
    XCTAssertTrue(PaneEdge.canSplit(width: 900, height: 281, edge: .bottom, paneMin: m, divider: 1))
  }

  func test_distribute_is_proportional_when_there_is_room() {
    XCTAssertEqual(rounded(SplitMath.distribute(total: 1000, fractions: [0.5, 0.5], minimums: [240, 240])), [500, 500])
  }

  func test_distribute_raises_small_child_to_minimum() {
    XCTAssertEqual(rounded(SplitMath.distribute(total: 600, fractions: [0.9, 0.1], minimums: [240, 240])), [360, 240])
  }

  func test_distribute_takes_deficit_in_proportion_to_slack() {
    // raw 600/300/100 → third raised by 140; slack 360 and 60 give 120 and 20.
    let l = SplitMath.distribute(total: 1000, fractions: [0.6, 0.3, 0.1], minimums: [240, 240, 240])
    XCTAssertEqual(rounded(l), [480, 280, 240])
  }

  func test_distribute_falls_back_to_proportional_below_total_minimum() {
    XCTAssertEqual(rounded(SplitMath.distribute(total: 400, fractions: [0.9, 0.1], minimums: [240, 240])), [360, 40])
  }
}
