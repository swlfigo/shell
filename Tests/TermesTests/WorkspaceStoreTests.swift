import XCTest
@testable import TermesKit

@MainActor
final class WorkspaceStoreTests: XCTestCase {
  private func file() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("termes-workspace-store-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir.appendingPathComponent("workspace.json")
  }

  private func snapshot() -> WorkspaceSnapshot {
    var layout = WindowLayout()
    let a = UUID(), b = UUID(), c = UUID()
    layout.addTab(pane: a); let second = layout.addTab(pane: b)
    layout.merge(tab: second, into: a, edge: .right)
    layout.addTab(pane: c); layout.selectTab(at: 0); layout.toggleMaximize(pane: b)
    let window = WorkspaceWindow(layout: layout, panes: layout.allPaneIds.map {
      WorkspacePane(id: $0, connection: .init(name: "中文服务器", hostname: "server.test", port: "2222", username: "ops"))
    }, frame: .init(x: -1200, y: 30, width: 1180, height: 740), sidebarVisible: false)
    return WorkspaceSnapshot(windows: [window], selectedWindowID: window.id)
  }

  func test_round_trip_preserves_nested_layout_selection_focus_maximize_and_frame() throws {
    let url = try file(), store = WorkspaceStore(fileURL: url)
    let value = snapshot()
    try store.save(value)
    XCTAssertEqual(WorkspaceStore(fileURL: url).snapshot, value)
    XCTAssertNil(store.error)
    assertInvariants(try XCTUnwrap(store.snapshot?.windows.first?.layout))
  }

  func test_corrupt_future_and_oversized_files_are_never_overwritten_by_automatic_saves() throws {
    let url = try file(), valid = snapshot()
    var future = valid; future.version = 100
    for data in [Data("broken".utf8), try JSONEncoder().encode(future), Data(repeating: 65, count: 4 * 1024 * 1024 + 1)] {
      try data.write(to: url)
      let store = WorkspaceStore(fileURL: url)
      XCTAssertNil(store.snapshot); XCTAssertTrue(store.isWriteProtected); XCTAssertNotNil(store.error)
      XCTAssertThrowsError(try store.save(valid))
      XCTAssertEqual(try Data(contentsOf: url), data)
    }
  }

  func test_explicit_recovery_keeps_original_backup_and_resumes_saving() throws {
    let url = try file(), broken = Data("original unreadable data".utf8)
    try broken.write(to: url)
    let store = WorkspaceStore(fileURL: url)
    try store.preserveUnreadableFile(); try store.save(snapshot())
    let files = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
    let backup = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("workspace-backup-") })
    XCTAssertEqual(try Data(contentsOf: backup), broken)
    XCTAssertFalse(store.isWriteProtected); XCTAssertNotNil(WorkspaceStore(fileURL: url).snapshot)
  }

  func test_invalid_tree_references_and_duplicates_preserve_previous_snapshot_and_file() throws {
    let url = try file(), store = WorkspaceStore(fileURL: url), valid = snapshot()
    try store.save(valid); let bytes = try Data(contentsOf: url)
    var invalids: [WorkspaceSnapshot] = []
    var duplicateWindow = valid; duplicateWindow.windows.append(valid.windows[0]); invalids.append(duplicateWindow)
    var missingPane = valid; missingPane.windows[0].panes.removeLast(); invalids.append(missingPane)
    var extraPane = valid; extraPane.windows[0].panes.append(.init(id: UUID(), connection: .init())); invalids.append(extraPane)
    var missingWindow = valid; missingWindow.selectedWindowID = UUID(); invalids.append(missingWindow)
    for root in [PaneNode.split(id: UUID(), axis: .horizontal, children: [.pane(UUID())], fractions: [1]),
                 .split(id: UUID(), axis: .horizontal, children: [.pane(UUID()), .pane(UUID())], fractions: [0, 1]),
                 .split(id: UUID(), axis: .horizontal, children: [.pane(UUID()), .pane(UUID())], fractions: [0.3, 0.3]),
                 .split(id: UUID(), axis: .horizontal, children: [.pane(UUID()), .pane(UUID())], fractions: [1]),
                 .split(id: UUID(), axis: .horizontal, children: [.pane(UUID()), .pane(UUID())], fractions: [.infinity, 1])] {
      var tab = Tab(pane: UUID()); tab.root = root
      var layout = WindowLayout(); layout.insertTab(tab, at: 0)
      invalids.append(.init(windows: [.init(layout: layout, panes: root.paneIds.map { .init(id: $0, connection: .init()) })]))
    }
    for invalid in invalids {
      XCTAssertThrowsError(try store.save(invalid))
      XCTAssertEqual(store.snapshot, valid); XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
  }

  func test_deep_input_is_rejected_and_write_failure_retains_last_successful_snapshot() throws {
    let url = try file(), valid = snapshot(), store = WorkspaceStore(fileURL: url)
    var node: [String: Any] = ["kind": "pane", "id": UUID().uuidString]
    for i in 0..<40 {
      node = ["kind": "split", "id": UUID().uuidString, "axis": i % 2 == 0 ? "horizontal" : "vertical",
              "children": [node, ["kind": "pane", "id": UUID().uuidString]], "fractions": [0.5, 0.5]]
    }
    XCTAssertThrowsError(try JSONDecoder().decode(PaneNode.self, from: JSONSerialization.data(withJSONObject: node)))
    try store.save(valid)
    try FileManager.default.removeItem(at: url)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    XCTAssertThrowsError(try store.save(.init(windows: [])))
    XCTAssertEqual(store.snapshot, valid); XCTAssertNotNil(store.error)
  }

  func test_extracting_panes_and_tabs_preserves_tree_and_destination_ownership() throws {
    var from = snapshot().windows[0].layout, to = WindowLayout()
    let focus = try XCTUnwrap(from.selectedTab?.focusedPane)
    let single = try XCTUnwrap(from.takePane(focus))
    XCTAssertEqual(single.paneIds, [focus]); XCTAssertTrue(to.insertTab(single, at: 0))
    XCTAssertFalse(to.insertTab(single, at: 0)); assertInvariants(from); assertInvariants(to)
    let remaining = try XCTUnwrap(from.takeTab(from.tabs[0].id))
    XCTAssertTrue(to.insertTab(remaining, at: 999)); assertInvariants(from); assertInvariants(to)
    XCTAssertNil(from.takePane(UUID())); XCTAssertNil(from.takeTab(UUID()))
  }
}
