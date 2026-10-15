import XCTest
@testable import TermesKit

@MainActor
final class SessionStatusTests: XCTestCase {
  func test_isActive() {
    let active: [SessionManager.State] = [.connecting, .needsHostKeyConfirm(fingerprint: "x"), .connected, .reconnecting(attempt: 1)]
    let inactive: [SessionManager.State] = [.idle, .failed("x"), .disconnected]
    for s in active { XCTAssertTrue(s.isActive, "\(s)") }
    for s in inactive { XCTAssertFalse(s.isActive, "\(s)") }
  }

  func test_status_mapping() {
    XCTAssertEqual(SessionManager.State.idle.status, .idle)
    XCTAssertEqual(SessionManager.State.connected.status, .connected)
    XCTAssertEqual(SessionManager.State.connecting.status, .pending)
    XCTAssertEqual(SessionManager.State.needsHostKeyConfirm(fingerprint: "x").status, .pending)
    XCTAssertEqual(SessionManager.State.reconnecting(attempt: 2).status, .pending)
    XCTAssertEqual(SessionManager.State.failed("x").status, .problem)
    XCTAssertEqual(SessionManager.State.disconnected.status, .problem)
  }

  func test_aggregate_takes_the_worst() {
    XCTAssertEqual(TabTitle.aggregate([]), .idle)
    XCTAssertEqual(TabTitle.aggregate([.connected, .idle]), .connected)
    XCTAssertEqual(TabTitle.aggregate([.connected, .pending]), .pending)
    XCTAssertEqual(TabTitle.aggregate([.pending, .problem, .connected]), .problem)
  }

  func test_titles() {
    XCTAssertEqual(TabTitle.single(name: nil), "新建连接")
    XCTAssertEqual(TabTitle.single(name: ""), "新建连接")
    XCTAssertEqual(TabTitle.single(name: "web-1"), "web-1")
    XCTAssertEqual(TabTitle.workspace(paneCount: 3), "工作区 (3)")
  }

  func test_drag_payload_round_trips_and_rejects_garbage() {
    let p = TabDragPayload(windowToken: "w1", tabId: UUID())
    XCTAssertEqual(TabDragPayload(encoded: p.encoded), p)
    XCTAssertNil(TabDragPayload(encoded: "nope"))
    XCTAssertNil(TabDragPayload(encoded: "w1|not-a-uuid"))
    XCTAssertNil(TabDragPayload(encoded: "|\(UUID().uuidString)"))
  }
}
