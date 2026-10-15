import AppKit
import XCTest
import SSHCore
import TermesKit
@testable import Termes

@MainActor
final class WorkspaceRestorationTests: XCTestCase {
  private func directory() throws -> URL {
    _ = NSApplication.shared
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("termes-restoration-\(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir
  }
  private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
  private func page(_ pane: SessionPaneController) async throws -> ConnectViewController {
    for _ in 0..<100 {
      if let page = pane.children.compactMap({ $0 as? ConnectViewController }).first { return page }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw CancellationError()
  }
  private func close(_ workspace: WorkspaceController) {
    workspace.prepareToTerminate()
    for window in workspace.windows { window.close() }
  }

  func test_relaunch_restores_all_windows_nested_splits_selection_and_nonsecret_drafts() async throws {
    let dir = try directory(), secrets = InMemorySecretStore(), services = AppServices(directory: dir, secrets: secrets)
    let saved = try services.profiles.saveConnection(name: "生产服务器", hostname: "saved.test", port: 2222,
      username: "ops", credential: .password("PASSWORD_MUST_NEVER_ENTER_WORKSPACE"))
    let workspace = WorkspaceController(services: services), first = workspace.openWindow(empty: false, show: false)
    let a = try XCTUnwrap(first.focusedPane)
    a.restore(.init(profile: saved))
    first.newTab(nil); let b = try XCTUnwrap(first.focusedPane)
    b.restore(.init(name: "临时服务器", hostname: "temporary.test", port: "2200", username: "admin"))
    let draftPage = try await page(b)
    let password = try XCTUnwrap(descendants(draftPage.view).compactMap { $0 as? NSSecureTextField }.first)
    password.stringValue = "DRAFT_PASSWORD_MUST_NEVER_ENTER_WORKSPACE"
    first.selectPreviousTab(nil)
    first.paneContainer(try XCTUnwrap(first.workspaceView?.container), drop: .init(windowToken: first.token, tabId: first.layout.tabs[1].id), onto: a.id, edge: .right)
    first.newTab(nil); let c = try XCTUnwrap(first.focusedPane)
    c.restore(.init(name: "第三台", hostname: "third.test", username: "root"))
    first.selectPreviousTab(nil)
    first.paneContainer(try XCTUnwrap(first.workspaceView?.container), drop: .init(windowToken: first.token, tabId: first.layout.tabs[1].id), onto: b.id, edge: .bottom)
    if case .split(let split, _, _, _) = first.layout.selectedTab?.root {
      first.paneContainer(try XCTUnwrap(first.workspaceView?.container), didResizeSplit: split, fractions: [0.3, 0.7])
    }
    c.actions?.toggleMaximize(c.id)
    XCTAssertEqual(first.layout.selectedTab?.paneIds.count, 3)
    XCTAssertEqual(first.layout.selectedTab?.maximizedPane, c.id)
    first.toggleSidebar(nil)
    first.newTab(nil)
    first.selectTabByNumber({ let item = NSMenuItem(); item.tag = 0; return item }())
    let second = workspace.openWindow(empty: false, show: false)
    try await page(try XCTUnwrap(second.focusedPane)).restore(.init(hostname: "unfinished.test", port: "invalid", username: ""))
    XCTAssertTrue(workspace.saveNow())
    let before = workspace.snapshot
    let data = try String(contentsOf: dir.appendingPathComponent("workspace.json"), encoding: .utf8)
    XCTAssertFalse(data.contains("PASSWORD_MUST_NEVER")); XCTAssertFalse(data.contains("DRAFT_PASSWORD"))
    close(workspace)
    let next = WorkspaceController(services: AppServices(directory: dir, secrets: secrets))
    defer { close(next) }
    next.restore(showWindows: false)
    var expected = before
    for i in expected.windows.indices {
      if let frame = expected.windows[i].frame {
        let visible = MainWindowController.visibleFrame(.init(x: frame.x, y: frame.y, width: frame.width, height: frame.height))
        expected.windows[i].frame = .init(x: visible.minX, y: visible.minY, width: visible.width, height: visible.height)
      }
    }
    XCTAssertEqual(next.snapshot, expected)
    XCTAssertEqual(next.windows.count, 2)
    let restored = try XCTUnwrap(next.windows.first?.pane(id: a.id))
    let restoredPage = try await page(restored)
    XCTAssertEqual(restoredPage.connectionDraft.profileID, saved.id)
    XCTAssertTrue(descendants(restoredPage.view).compactMap { $0 as? NSSecureTextField }.allSatisfy { $0.stringValue.isEmpty })
    try await Task.sleep(for: .milliseconds(100))
    for window in next.windows {
      for id in window.layout.allPaneIds { XCTAssertEqual(window.pane(id: id)?.session.state, .idle) }
      assertInvariants(window.layout)
    }
  }

  func test_latest_saved_target_missing_credentials_and_deleted_references_restore_for_review() async throws {
    let dir = try directory(), services = AppServices(directory: dir, secrets: InMemorySecretStore())
    let profile = ConnectionProfile(name: "旧名字", hostname: "old.test", port: 22, username: "ops", auth: .password)
    try services.profiles.importSnapshot(.init(profiles: [profile], keys: []))
    let main = MainWindowController(services: services, empty: false)
    let pane = try XCTUnwrap(main.focusedPane)
    pane.restore(.init(profile: profile))
    let snapshot = main.restorationSnapshot
    try services.profiles.updateConnection(profile.id, name: "新名字", hostname: "new.test", port: 2222, username: "admin")
    let updated = MainWindowController(services: services, restoring: snapshot)
    defer { main.close(); updated.close() }
    let page = try await page(try XCTUnwrap(updated.focusedPane))
    XCTAssertEqual(page.connectionDraft.hostname, "new.test"); XCTAssertEqual(page.connectionDraft.profileID, profile.id)
    XCTAssertEqual(updated.focusedPane?.label?.name, "新名字")
    let connect = try XCTUnwrap(descendants(page.view).compactMap { $0 as? NSButton }.first { $0.title == "连接" })
    connect.performClick(nil)
    XCTAssertEqual(updated.focusedPane?.session.state, .idle)
    XCTAssertTrue(descendants(page.view).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("缺少本机凭据") })
    try services.profiles.deleteConnection(profile.id)
    let deleted = MainWindowController(services: services, restoring: snapshot)
    defer { deleted.close() }
    let fallback = try await self.page(try XCTUnwrap(deleted.focusedPane))
    XCTAssertNil(fallback.connectionDraft.profileID); XCTAssertEqual(fallback.connectionDraft.hostname, "old.test")
    XCTAssertTrue(descendants(fallback.view).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("已删除") })
  }

  func test_last_window_close_clears_restore_set_but_quit_keeps_all_windows() async throws {
    let dir = try directory(), services = AppServices(directory: dir, secrets: InMemorySecretStore())
    let workspace = WorkspaceController(services: services)
    workspace.openWindow(empty: false, show: false).close()
    XCTAssertEqual(WorkspaceStore(fileURL: dir.appendingPathComponent("workspace.json")).snapshot?.windows, [])
    let first = workspace.openWindow(empty: false, show: false); first.newTab(nil)
    _ = workspace.openWindow(empty: false, show: false)
    let before = workspace.snapshot
    close(workspace)
    XCTAssertEqual(WorkspaceStore(fileURL: dir.appendingPathComponent("workspace.json")).snapshot, before)
  }

  func test_text_edits_are_saved_after_debounce_and_offscreen_frames_are_visible() async throws {
    let dir = try directory(), workspace = WorkspaceController(services: AppServices(directory: dir, secrets: InMemorySecretStore()))
    defer { close(workspace) }
    let main = workspace.openWindow(empty: false, show: false), page = try await page(try XCTUnwrap(main.focusedPane))
    let host = try XCTUnwrap(descendants(page.view).compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "主机" })
    host.stringValue = "autosaved.test"
    NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: host)
    try await Task.sleep(for: .milliseconds(450))
    XCTAssertEqual(WorkspaceStore(fileURL: dir.appendingPathComponent("workspace.json")).snapshot?.windows.first?.panes.first?.connection.hostname, "autosaved.test")
    let rect = MainWindowController.visibleFrame(.init(x: -900_000, y: 900_000, width: 1180, height: 740))
    XCTAssertTrue(NSScreen.screens.contains { $0.visibleFrame.contains(rect) })
  }

  func test_app_launch_restores_workspace_and_window_menus_move_the_current_tab() async throws {
    let services = AppServices(directory: try directory(), secrets: InMemorySecretStore())
    var layout = WindowLayout(); let a = UUID(), b = UUID()
    layout.addTab(pane: a); layout.addTab(pane: b)
    let window = WorkspaceWindow(layout: layout, panes: [a, b].map {
      .init(id: $0, connection: .init(name: "恢复的服务器", hostname: "review.test", username: "ops"))
    })
    try services.workspace.save(.init(windows: [window], selectedWindowID: window.id))
    let oldMenu = NSApp.mainMenu, delegate = AppDelegate(services: services)
    defer { close(delegate.workspace); NSApp.mainMenu = oldMenu }
    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    let restored = try XCTUnwrap(delegate.workspace.windows.first)
    XCTAssertTrue(restored.isShowingVaults)
    let selection = NSMenuItem(); selection.tag = 1
    restored.selectTabByNumber(selection)
    let pane = try XCTUnwrap(restored.focusedPane)
    XCTAssertEqual(pane.id, b)
    await Task.yield()
    let menu = try XCTUnwrap(NSApp.mainMenu?.item(withTitle: "窗口")?.submenu)
    let moves = try XCTUnwrap(menu.item(withTitle: "移动当前标签到窗口")?.submenu)
    XCTAssertEqual(moves.identifier?.rawValue, "moveTab")
    XCTAssertEqual(restored.makeMoveMenu(tab: layout.selectedTabId).items.first?.title, "新窗口")
    let action = try XCTUnwrap(menu.item(withTitle: "将当前标签移到新窗口"))
    // XCTest is not a running NSApplication and cannot become the system key app.
    // Send the real menu's selector to its window responder explicitly in this host.
    XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(action.action), to: restored, from: action))
    XCTAssertEqual(delegate.workspace.windows.count, 2)
    XCTAssertTrue(delegate.workspace.windows.last?.focusedPane === pane)
    if let directory = ProcessInfo.processInfo.environment["TERMES_WORKSPACE_RENDER_DIRECTORY"] {
      let url = URL(fileURLWithPath: directory, isDirectory: true)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      for (index, main) in delegate.workspace.windows.enumerated() {
        main.window?.setContentSize(.init(width: 900, height: 600))
        let content = try XCTUnwrap(main.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url.appendingPathComponent("window-\(index).png"))
      }
    }
    XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateNow)
    XCTAssertEqual(services.workspace.snapshot?.windows.count, 2)
  }
}
