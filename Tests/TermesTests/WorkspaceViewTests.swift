import AppKit
import XCTest
import TermesKit
import SSHCore
@testable import Termes

@MainActor
final class WorkspaceViewTests: XCTestCase {
  private func services() throws -> AppServices {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return AppServices(directory: directory, secrets: InMemorySecretStore())
  }
  private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
  private func wait(_ predicate: () -> Bool, timeout: TimeInterval = 20,
                    file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
    guard predicate() else { XCTFail("timed out", file: file, line: line); throw CancellationError() }
  }
  private func hostField(_ pane: SessionPaneController) throws -> NSTextField {
    try XCTUnwrap(descendants(pane.view).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "example.com" })
  }
  private func waitForPage(_ pane: SessionPaneController) async throws {
    try await wait { descendants(pane.view).compactMap { $0 as? NSTextField }.contains { $0.placeholderString == "example.com" } }
  }

  func test_sidebar_search_and_selection_preserve_active_pane_and_connection_draft() async throws {
    let services = try services()
    let a = try services.profiles.saveConnection(name: "生产 API", hostname: "api.test", port: 22, username: "deploy", credential: .password("pw"))
    _ = try services.profiles.saveConnection(name: "数据库", hostname: "db.test", port: 22, username: "ops", credential: .password("pw"))
    let main = MainWindowController(services: services, empty: false)
    defer { main.close() }
    let pane = try XCTUnwrap(main.focusedPane)
    try await waitForPage(pane)
    let field = try hostField(pane)
    field.stringValue = "unsaved.test"
    let sidebar = main.sidebar
    sidebar.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    try await wait { sidebar.model.selectedID != nil && sidebar.openButton.isEnabled }
    XCTAssertTrue(main.focusedPane === pane); XCTAssertEqual(pane.session.state, .idle)
    XCTAssertEqual(field.stringValue, "unsaved.test")
    sidebar.model.select(a.id); sidebar.model.search = "no-match"
    try await wait { sidebar.table.numberOfRows == 0 && !sidebar.openButton.isEnabled }
    XCTAssertEqual(sidebar.model.selectedID, a.id)
    sidebar.model.search = "deploy"
    try await wait { sidebar.table.numberOfRows == 1 && sidebar.openButton.isEnabled }
    XCTAssertEqual(sidebar.table.selectedRow, 0)
    XCTAssertEqual(field.stringValue, "unsaved.test")
  }

  func test_responsive_sidebar_toggle_and_search_keep_form_views_and_window_minimum() async throws {
    let main = MainWindowController(services: try services(), empty: false)
    defer { main.close() }
    let window = try XCTUnwrap(main.window), workspace = try XCTUnwrap(main.workspaceView)
    let pane = try XCTUnwrap(main.focusedPane)
    try await waitForPage(pane)
    let field = try hostField(pane)
    field.stringValue = "keep-draft.test"
    for width in [1180.0, 480.0, 1180.0] {
      window.setContentSize(.init(width: width, height: 540)); workspace.layoutSubtreeIfNeeded()
      XCTAssertEqual(workspace.sidebarDocked, width >= 880)
      XCTAssertEqual(workspace.container.frame.width, width - (width >= 880 ? 240 : 0), accuracy: 0.5)
      XCTAssertTrue(workspace.bounds.contains(workspace.container.frame))
      XCTAssertTrue(main.focusedPane === pane); XCTAssertTrue(try hostField(pane) === field)
      XCTAssertEqual(field.stringValue, "keep-draft.test")
    }
    main.toggleSidebar(nil); workspace.layoutSubtreeIfNeeded()
    XCTAssertTrue(main.sidebar.view.isHidden); XCTAssertEqual(workspace.container.frame.width, 1180, accuracy: 0.5)
    window.setContentSize(.init(width: 480, height: 320)); workspace.layoutSubtreeIfNeeded()
    main.searchServers(nil); workspace.layoutSubtreeIfNeeded()
    XCTAssertFalse(main.sidebar.view.isHidden); XCTAssertTrue(workspace.sidebarOverlayOpen)
    XCTAssertEqual(workspace.container.frame.width, 480, accuracy: 0.5)
    XCTAssertEqual(window.contentMinSize, .init(width: 480, height: 320))
    XCTAssertEqual(field.stringValue, "keep-draft.test")
    XCTAssertTrue(main.sidebar.searchField.currentEditor() === window.firstResponder)
  }

  func test_opening_saved_server_with_missing_credential_shows_exact_target_for_repair() throws {
    let services = try services()
    let profile = ConnectionProfile(name: "缺少凭据的服务器", hostname: "repair.test", port: 2222, username: "admin", auth: .password)
    try services.profiles.importSnapshot(.init(profiles: [profile], keys: []))
    let main = MainWindowController(services: services, empty: false)
    defer { main.close() }
    let pane = try XCTUnwrap(main.focusedPane)
    main.openSavedConnection(id: profile.id)
    XCTAssertTrue(main.focusedPane === pane); XCTAssertEqual(pane.session.state, .idle)
    XCTAssertEqual(try hostField(pane).stringValue, "repair.test")
    XCTAssertFalse(try hostField(pane).isEnabled)
    XCTAssertTrue(descendants(pane.view).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("缺少本机凭据") })
    XCTAssertTrue(descendants(pane.view).compactMap { $0 as? NSButton }.contains { $0.title == "更新凭据" })
  }

  func test_appearance_controls_update_existing_and_new_windows_without_replacing_connection_drafts() async throws {
    let services = try services(), first = MainWindowController(services: services, empty: false), second = MainWindowController(services: services, empty: false)
    defer { first.close(); second.close() }
    let pane = try XCTUnwrap(first.focusedPane); try await waitForPage(pane)
    let field = try hostField(pane); field.stringValue = "draft.test"
    let page = AppearanceViewController(store: services.appearance); _ = page.view
    page.themePopup.selectItem(at: 2); page.appThemeChanged()
    try XCTUnwrap(page.themeRows.first { $0.theme == .light }).performClick(nil)
    page.sizeField.stringValue = "20"; page.controlTextDidEndEditing(.init(name: NSControl.textDidEndEditingNotification, object: page.sizeField))
    XCTAssertEqual(services.appearance.settings, .init(theme: .dark, terminalTheme: .light, terminalFontSize: 20))
    XCTAssertEqual(first.window?.appearance?.name, .darkAqua); XCTAssertEqual(second.window?.appearance?.name, .darkAqua)
    XCTAssertEqual(field.stringValue, "draft.test")
    XCTAssertTrue(try hostField(XCTUnwrap(first.focusedPane)) === field)
    let third = MainWindowController(services: services, empty: false); defer { third.close() }
    XCTAssertEqual(third.window?.appearance?.name, .darkAqua)
    page.themePopup.selectItem(at: 0); page.appThemeChanged()
    XCTAssertNil(first.window?.appearance); XCTAssertNil(second.window?.appearance); XCTAssertNil(third.window?.appearance)
  }

  func test_workspace_merge_maximize_detach_and_tab_switch_preserve_drafts_with_sidebar_offsets() async throws {
    let main = MainWindowController(services: try services(), empty: false); defer { main.close() }
    let root = try XCTUnwrap(main.workspaceView), first = try XCTUnwrap(main.focusedPane)
    try await waitForPage(first)
    let firstField = try hostField(first); firstField.stringValue = "first-draft.test"
    let source = try XCTUnwrap(descendants(root.tabBar).compactMap { $0 as? TabItemView }.first?.item.id)
    main.newTab(nil)
    let second = try XCTUnwrap(main.focusedPane); try await waitForPage(second)
    let secondField = try hostField(second); secondField.stringValue = "second-draft.test"
    main.paneContainer(root.container, drop: .init(windowToken: main.token, tabId: source), onto: second.id, edge: .right)
    root.layoutSubtreeIfNeeded()
    XCTAssertTrue(first.isInWorkspace && second.isInWorkspace)
    XCTAssertEqual(root.container.visiblePanes.count, 2)
    XCTAssertEqual(firstField.stringValue, "first-draft.test"); XCTAssertEqual(secondField.stringValue, "second-draft.test")
    first.actions?.toggleMaximize(first.id); root.layoutSubtreeIfNeeded()
    XCTAssertTrue(first.isMaximized); XCTAssertEqual(root.container.visiblePanes.count, 1)
    first.actions?.toggleMaximize(first.id)
    first.actions?.detach(first.id); root.layoutSubtreeIfNeeded()
    XCTAssertFalse(first.isInWorkspace || second.isInWorkspace)
    main.selectNextTab(nil)
    XCTAssertTrue(try hostField(second) === secondField); XCTAssertEqual(secondField.stringValue, "second-draft.test")
    main.selectPreviousTab(nil)
    XCTAssertTrue(try hostField(first) === firstField); XCTAssertEqual(firstField.stringValue, "first-draft.test")
  }

  func test_new_titlebar_layout_hits_tabs_and_sidebar_toggle_in_wide_and_narrow_windows() async throws {
    let main = MainWindowController(services: try services(), empty: false); defer { main.close() }
    let workspace = try XCTUnwrap(main.workspaceView), window = try XCTUnwrap(main.window)
    try await waitForPage(XCTUnwrap(main.focusedPane))
    main.newTab(nil)
    for width in [1180.0, 480.0] {
      window.setContentSize(.init(width: width, height: 540)); workspace.layoutSubtreeIfNeeded()
      let items = descendants(workspace.tabBar).compactMap { $0 as? TabItemView }
      XCTAssertEqual(items.count, 2)
      for item in items {
        let point = item.convert(NSPoint(x: 32, y: 14), to: workspace)
        XCTAssertTrue(workspace.hitTest(point) === item, "tab remains clickable with sidebar offset at \(width)")
      }
      let point = workspace.sidebarButton.convert(.init(x: 13, y: 14), to: workspace)
      XCTAssertTrue(workspace.hitTest(point) === workspace.sidebarButton)
      XCTAssertGreaterThanOrEqual(items[0].convert(items[0].bounds, to: workspace).minX, 120)
    }
  }

  func test_real_session_input_files_monitor_and_focus_survive_theme_sidebar_and_window_changes() async throws {
    let services = try services(), server = try await TestSSHServer.start()
    addTeardownBlock { await server.stop() }
    let a = try services.profiles.saveConnection(name: "生产 API · UI 验收", hostname: server.host, port: server.port, username: server.username, credential: .password(server.password))
    let b = try services.profiles.saveConnection(name: "数据库", hostname: server.host, port: server.port, username: server.username, credential: .password(server.password))
    let main = MainWindowController(services: services, empty: false)
    defer { main.disconnectAll(); main.close() }
    let pane = try XCTUnwrap(main.focusedPane), window = try XCTUnwrap(main.window), workspace = try XCTUnwrap(main.workspaceView)
    main.sidebar.model.select(a.id)
    try await wait { main.sidebar.openButton.isEnabled }
    main.sidebar.openButton.performClick(nil)
    try await wait {
      if case .needsHostKeyConfirm = pane.session.state { pane.session.confirmHostKey(true) }
      return pane.session.state == .connected && pane.children.contains { $0 is TerminalViewController }
    }
    XCTAssertEqual(pane.label?.profileID, a.id)
    let terminal = try XCTUnwrap(pane.children.compactMap { $0 as? TerminalViewController }.first)
    let terminalBuffer = terminalIdentity(terminal.terminalView), version = pane.session.connectionVersion
    main.showVaults(nil)
    XCTAssertTrue(main.isShowingVaults); XCTAssertNil(main.focusedPane)
    XCTAssertEqual(pane.session.state, .connected)
    main.tabBar(workspace.tabBar, select: try XCTUnwrap(main.layout.selectedTabId))
    XCTAssertTrue(main.focusedPane === pane)
    XCTAssertTrue(terminalIdentity(terminal.terminalView) == terminalBuffer)
    XCTAssertEqual(pane.session.connectionVersion, version)
    pane.toggleFiles(); pane.toggleMonitor()
    let files = try XCTUnwrap(pane.children.compactMap { $0 as? FileBrowserViewController }.first), monitor = try XCTUnwrap(pane.monitorVC)
    try await wait { files.model.directory != nil && monitor.model.current != nil }
    main.showWindow(nil); window.makeKeyAndOrderFront(nil); pane.takeFocus()
    pane.session.sendInput(Data("printf 'UI_%s\\n' 'INPUT_PRESERVED'".utf8))
    try await wait { String(decoding: terminal.terminalView.getBufferAsData(), as: UTF8.self).contains("INPUT_PRESERVED") }
    main.sidebar.model.select(b.id)
    try await wait { main.sidebar.model.selectedID == b.id }
    XCTAssertTrue(main.focusedPane === pane); XCTAssertEqual(pane.label?.profileID, a.id)
    let appearances: [(AppTheme, TerminalTheme, String?, Double)] = [
      (.dark, .termiusDark, "SourceCodePro-Regular", 1440), (.light, .kanagawaLotus, "Menlo-Regular", 480), (.system, .hackerBlue, nil, 1180)]
    for (theme, terminalTheme, fontName, width) in appearances {
      try services.appearance.update(.init(theme: theme, terminalTheme: terminalTheme, terminalFontSize: 15, terminalFontName: fontName, terminalTextColor: 0x40E090))
      window.setContentSize(.init(width: width, height: 760)); workspace.layoutSubtreeIfNeeded()
      XCTAssertTrue(terminalIdentity(terminal.terminalView) == terminalBuffer)
      XCTAssertEqual(terminal.terminalView.font.pointSize, 15)
      let actual = try XCTUnwrap(terminal.terminalView.nativeBackgroundColor.usingColorSpace(.sRGB))
      let expected = try XCTUnwrap(terminalTheme.palette(effectiveDark: true).background.nativeColor.usingColorSpace(.sRGB))
      XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.00001)
      XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.00001)
      XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.00001)
      XCTAssertEqual(terminal.terminalView.font.fontName, TerminalFonts.resolve(name: fontName, size: 15).fontName)
      let foreground = try XCTUnwrap(terminal.terminalView.nativeForegroundColor.usingColorSpace(.sRGB))
      XCTAssertEqual(foreground.redComponent, 64.0 / 255, accuracy: 0.00001)
      XCTAssertEqual(foreground.greenComponent, 224.0 / 255, accuracy: 0.00001)
      XCTAssertEqual(foreground.blueComponent, 144.0 / 255, accuracy: 0.00001)
      XCTAssertEqual(window.firstResponder, terminal.terminalView)
      XCTAssertEqual(pane.session.connectionVersion, version); XCTAssertEqual(pane.session.state, .connected)
      XCTAssertTrue(pane.children.contains { $0 === files }); XCTAssertTrue(pane.monitorVC === monitor)
      XCTAssertTrue(monitor.model.isOpen)
      if width >= 1180 {
        let subtitle = try XCTUnwrap(descendants(pane.view).compactMap { $0 as? NSTextField }.first { $0.stringValue.hasPrefix("已连接 · ") })
        XCTAssertGreaterThan(subtitle.frame.width, 400, "server address uses the available toolbar width")
      }
    }
    main.toggleSidebar(nil); workspace.layoutSubtreeIfNeeded(); main.toggleSidebar(nil); workspace.layoutSubtreeIfNeeded()
    pane.session.sendInput(Data("\r".utf8))
    try await wait { String(decoding: terminal.terminalView.getBufferAsData(), as: UTF8.self).contains("UI_INPUT_PRESERVED") }
    XCTAssertEqual(main.sidebar.model.sessionText(for: a.id), "已连接")
    XCTAssertEqual(main.sidebar.model.sessionText(for: b.id), "未连接")
    if ProcessInfo.processInfo.environment["TERMES_WORKSPACE_VISUAL_REVIEW"] == "1" {
      try services.appearance.update(.init(theme: .dark))
      window.setContentSize(.init(width: 1440, height: 860)); workspace.layoutSubtreeIfNeeded()
      pane.toggleFiles(); main.sidebar.model.select(a.id)
      NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
      print("WORKSPACE_REVIEW_WINDOW=\(window.windowNumber)")
      window.title = "Termes UI 验收 · 深色"
      try await Task.sleep(nanoseconds: 20_000_000_000)
      try services.appearance.update(.init(theme: .light, terminalTheme: .light))
      window.title = "Termes UI 验收 · 浅色"
      try await Task.sleep(nanoseconds: 15_000_000_000)
      window.setContentSize(.init(width: 480, height: 540)); workspace.layoutSubtreeIfNeeded()
      window.title = "Termes UI 验收 · 窄窗口"
      try await Task.sleep(nanoseconds: 15_000_000_000)
    }
  }
}
