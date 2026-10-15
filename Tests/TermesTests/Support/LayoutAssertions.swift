import Foundation
import XCTest
@testable import TermesKit

/// Compact, id-free rendering of a pane tree, e.g. "H[A:0.5,V[B:0.5,C:0.5]:0.5]".
func shape(_ node: PaneNode, _ names: [UUID: String]) -> String {
  switch node {
  case .pane(let id):
    return names[id] ?? "?"
  case .split(_, let axis, let children, let fractions):
    let parts = zip(children, fractions).map { "\(shape($0.0, names)):\(String(format: "%.3g", $0.1))" }
    return (axis == .horizontal ? "H" : "V") + "[" + parts.joined(separator: ",") + "]"
  }
}

/// Asserts every WindowLayout invariant from spec §3.2.
func assertInvariants(_ l: WindowLayout, file: StaticString = #filePath, line: UInt = #line) {
  let ids = l.allPaneIds
  XCTAssertEqual(Set(ids).count, ids.count, "duplicate pane ids", file: file, line: line)
  XCTAssertEqual(l.selectedTabId == nil, l.tabs.isEmpty, "selection vs. emptiness", file: file, line: line)
  if let s = l.selectedTabId {
    XCTAssertTrue(l.tabs.contains { $0.id == s }, "selected tab missing", file: file, line: line)
  }
  for t in l.tabs {
    XCTAssertFalse(t.paneIds.isEmpty, "empty tab", file: file, line: line)
    XCTAssertTrue(t.paneIds.contains(t.focusedPane), "focus outside its tab", file: file, line: line)
    if let m = t.maximizedPane {
      XCTAssertTrue(t.isWorkspace && t.paneIds.contains(m), "bad maximized pane", file: file, line: line)
    }
    checkNode(t.root, parentAxis: nil, file: file, line: line)
  }
}

private func checkNode(_ n: PaneNode, parentAxis: SplitAxis?, file: StaticString, line: UInt) {
  guard case .split(_, let axis, let children, let fractions) = n else { return }
  XCTAssertGreaterThanOrEqual(children.count, 2, "split with < 2 children", file: file, line: line)
  XCTAssertNotEqual(Optional(axis), parentAxis, "same-axis nested split", file: file, line: line)
  XCTAssertEqual(fractions.count, children.count, "fraction count", file: file, line: line)
  XCTAssertTrue(fractions.allSatisfy { $0 > 0 }, "non-positive fraction", file: file, line: line)
  XCTAssertEqual(fractions.reduce(0, +), 1, accuracy: 1e-9, "fractions sum", file: file, line: line)
  for c in children { checkNode(c, parentAxis: axis, file: file, line: line) }
}
