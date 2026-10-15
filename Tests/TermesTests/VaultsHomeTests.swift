import AppKit
import Darwin
import XCTest
import SSHCore
import TermesKit
@testable import Termes

@MainActor
final class VaultsHomeTests: XCTestCase {
  private func services() throws -> AppServices {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("termes-vaults-\(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return AppServices(directory: directory, secrets: InMemorySecretStore())
  }
  private func wait(_ predicate: () -> Bool) async throws {
    for _ in 0..<1000 {
      if predicate() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Vaults did not update"); throw CancellationError()
  }
  private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
  private func render(_ main: MainWindowController, name: String) throws {
    guard let path = ProcessInfo.processInfo.environment["TERMES_VAULTS_RENDER_DIRECTORY"] else { return }
    let directory = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let view = try XCTUnwrap(main.window?.contentView)
    view.layoutSubtreeIfNeeded(); view.layoutSubtreeIfNeeded()
    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
  }

  func test_launch_lists_all_saved_hosts_without_creating_a_connection_and_navigation_is_embedded() async throws {
    let services = try services()
    let demoHosts = [
      ("API", "api.example.com"),
      ("Build Server", "build.example.com"),
      ("Database", "database.example.com"),
      ("Gateway", "gateway.example.com"),
      ("Monitoring", "monitor.example.com"),
      ("Staging", "staging.example.com"),
      ("Storage", "storage.example.com"),
    ]
    try services.profiles.importSnapshot(.init(profiles: demoHosts.map { name, hostname in
      ConnectionProfile(name: name, hostname: hostname, port: 22, username: "demo", auth: .password)
    }, keys: []))
    let workspace = WorkspaceController(services: services)
    workspace.restore(showWindows: false)
    let main = try XCTUnwrap(workspace.windows.first)
    defer { workspace.prepareToTerminate(); main.close() }
    let root = try XCTUnwrap(main.workspaceView), window = try XCTUnwrap(main.window)
    XCTAssertTrue(main.isShowingVaults); XCTAssertTrue(root.isShowingVaults)
    XCTAssertNil(main.focusedPane); XCTAssertTrue(main.layout.tabs.isEmpty)
    XCTAssertEqual(main.vaults.hosts.cards.count, 7)
    XCTAssertEqual(main.vaults.selectedSection, .hosts)
    XCTAssertFalse(main.vaults.hosts.connectButton.isEnabled)
    XCTAssertFalse(descendants(root).compactMap { $0 as? NSTextField }.contains { $0.placeholderString == "example.com" })
    for theme in [AppTheme.dark, .light] {
      try services.appearance.update(.init(theme: theme))
      window.setContentSize(.init(width: 1440, height: 860)); root.layoutSubtreeIfNeeded()
      XCTAssertEqual(main.vaults.hosts.columnCount, 3)
      try render(main, name: "hosts-\(theme.rawValue)")
    }
    try services.appearance.update(.init(theme: .dark))
    root.sidebarButton.performClick(nil); root.layoutSubtreeIfNeeded()
    XCTAssertEqual(main.vaults.hosts.view.convert(.zero, to: main.vaults.view).x, 64)
    root.sidebarButton.performClick(nil); root.layoutSubtreeIfNeeded()
    XCTAssertEqual(main.vaults.hosts.view.convert(.zero, to: main.vaults.view).x, 240)
    if ProcessInfo.processInfo.environment["TERMES_VAULTS_NATIVE_REVIEW"] == "1" {
      main.showWindow(nil); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
      print("VAULTS_REVIEW_WINDOW=\(window.windowNumber)")
      try await Task.sleep(for: .seconds(45))
    }
    for section in [VaultSection.keychain, .portForwarding, .snippets, .hosts] {
      try XCTUnwrap(main.vaults.navigationButtons[section]).performClick(nil)
      root.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(30))
      XCTAssertEqual(main.vaults.selectedSection, section)
      XCTAssertTrue(main.layout.tabs.isEmpty); XCTAssertEqual(workspace.windows.count, 1)
      if section == .keychain { try render(main, name: "keychain-dark") }
    }
    for width in [1180.0, 760, 600, 480] {
      window.setContentSize(.init(width: width, height: 540)); root.layoutSubtreeIfNeeded()
      let page = main.vaults.hosts
      for card in page.cards {
        XCTAssertGreaterThan(card.frame.width, 250)
        XCTAssertTrue(try XCTUnwrap(card.superview).bounds.contains(card.frame))
      }
      for control in [page.searchField, page.connectButton, page.newButton, page.editButton, page.displayMode] {
        XCTAssertTrue(page.view.bounds.contains(control.frame), "\(control) at \(width)")
      }
      if width == 480 { try render(main, name: "hosts-narrow") }
    }
    XCTAssertTrue(workspace.saveNow())
    XCTAssertEqual(services.workspace.snapshot?.windows.first?.panes, [])
    XCTAssertEqual(services.workspace.snapshot?.windows.count, 1)
  }

  func test_search_selection_and_layout_changes_preserve_drafts_and_explicit_new_host_opens_a_form() async throws {
    let services = try services()
    let api = try services.profiles.saveConnection(name: "API", hostname: "api.test", port: 2222, username: "deploy", credential: .password("pw"))
    _ = try services.profiles.saveConnection(name: "DB", hostname: "db.test", port: 22, username: "ops", credential: .password("pw"))
    let main = MainWindowController(services: services)
    defer { main.close() }
    main.vaults.hosts.newButton.performClick(nil)
    let draft = try XCTUnwrap(main.focusedPane)
    draft.restore(.init(name: "未保存的主机", hostname: "draft.test", username: "root"))
    main.workspaceView?.vaultsButton.performClick(nil)
    XCTAssertTrue(main.isShowingVaults); XCTAssertNil(main.focusedPane)
    XCTAssertTrue(main.pane(id: draft.id) === draft)
    let page = main.vaults.hosts
    page.model.search = "deploy"
    try await wait { page.cards.count == 1 }
    XCTAssertEqual(page.cards.first?.profileID, api.id)
    XCTAssertTrue(try XCTUnwrap(page.cards.first).accessibilityPerformPress())
    XCTAssertTrue(page.connectButton.isEnabled); XCTAssertEqual(main.layout.tabs.count, 1)
    page.displayMode.selectedSegment = 1
    XCTAssertTrue(page.displayMode.sendAction(try XCTUnwrap(page.displayMode.action), to: page.displayMode.target))
    main.window?.contentView?.layoutSubtreeIfNeeded()
    XCTAssertEqual(page.cards.first?.frame.height, 76)
    page.model.search = "not-found"
    try await wait { page.cards.isEmpty && !page.connectButton.isEnabled }
    page.model.search = "api.test"
    try await wait { page.cards.count == 1 && page.connectButton.isEnabled }
    XCTAssertEqual(draft.restorationSnapshot.connection.hostname, "draft.test")
    let tab = try XCTUnwrap(main.layout.selectedTabId)
    main.tabBar(try XCTUnwrap(main.workspaceView?.tabBar), select: tab)
    XCTAssertTrue(main.focusedPane === draft)
    XCTAssertEqual(draft.restorationSnapshot.connection.hostname, "draft.test")
    main.requestClose(panes: [draft.id])
    XCTAssertTrue(main.isShowingVaults); XCTAssertTrue(main.layout.tabs.isEmpty)
    XCTAssertNotNil(main.window?.contentView)
  }

  func test_double_clicking_imported_host_opens_credential_repair_for_that_exact_target() throws {
    let services = try services()
    let profile = ConnectionProfile(name: "Imported", hostname: "repair.test", port: 2222, username: "admin", auth: .password)
    try services.profiles.importSnapshot(.init(profiles: [profile], keys: []))
    let main = MainWindowController(services: services)
    defer { main.close() }
    try XCTUnwrap(main.vaults.hosts.cards.first).onOpen?()
    let pane = try XCTUnwrap(main.focusedPane)
    XCTAssertFalse(main.isShowingVaults); XCTAssertEqual(main.layout.tabs.count, 1)
    XCTAssertEqual(pane.session.state, .idle)
    let host = try XCTUnwrap(descendants(pane.view).compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "主机" })
    XCTAssertEqual(host.stringValue, profile.hostname); XCTAssertFalse(host.isEnabled)
    XCTAssertTrue(descendants(pane.view).compactMap { $0 as? NSButton }.contains { $0.title == "更新凭据" })
  }

  func test_port_forwarding_loads_and_saves_routed_rules_without_credentials_or_a_session() async throws {
    let services = try services()
    let hop = ConnectionProfile(name: "Jump", hostname: "jump.test", port: 2200, username: "gateway", auth: .password)
    let target = ConnectionProfile(name: "API", hostname: "private.test", port: 22, username: "ops", auth: .password, jumpProfileId: hop.id)
    try services.profiles.importSnapshot(.init(profiles: [hop, target], keys: []))
    let destination = try services.profiles.forwardingDestination(for: target.id)
    XCTAssertEqual(destination.jumpHosts?.first?.hostname, "jump.test")
    XCTAssertEqual(destination.jumpHosts?.first?.port, 2200)
    let original = try services.localForwards.save(destination: destination,
      configuration: .init(localPort: 18080, targetHost: "localhost", targetPort: 80))
    let main = MainWindowController(services: services)
    defer { main.close() }
    main.manageLocalForwards(nil)
    let page = main.vaults.forwarding
    XCTAssertEqual(main.vaults.selectedSection, .portForwarding)
    page.hostPopup.selectItem(withTitle: "API")
    XCTAssertTrue(page.hostPopup.sendAction(try XCTUnwrap(page.hostPopup.action), to: page.hostPopup.target))
    try await wait { page.editor?.model.destination == destination && page.editor?.table.numberOfRows == 1 }
    let editor = try XCTUnwrap(page.editor)
    XCTAssertFalse(editor.model.isConnected); XCTAssertTrue(editor.model.canSave)
    XCTAssertEqual(editor.model.rules.first?.id, original.id)
    editor.localPortField.stringValue = "15432"
    editor.targetHostField.stringValue = "database.internal"
    editor.targetPortField.stringValue = "5432"
    XCTAssertTrue(editor.saveChanges())
    XCTAssertEqual(try services.localForwards.rules(for: destination).count, 2)
    XCTAssertTrue(editor.model.rules.allSatisfy { $0.state == .stopped })
    XCTAssertThrowsError(try services.profiles.makeConfig(for: target.id))
    XCTAssertTrue(main.layout.tabs.isEmpty); XCTAssertNil(main.focusedPane)
    main.window?.contentView?.layoutSubtreeIfNeeded()
    try render(main, name: "port-forwarding-dark")
  }

  func test_profile_edits_and_imports_update_vaults_in_every_window() async throws {
    let services = try services()
    let a = MainWindowController(services: services), b = MainWindowController(services: services)
    defer { a.close(); b.close() }
    let profile = try services.profiles.saveConnection(name: "First", hostname: "one.test", port: 22, username: "root", credential: .password("pw"))
    try await wait { a.vaults.hosts.cards.count == 1 && b.vaults.hosts.cards.count == 1 }
    try services.profiles.updateConnection(profile.id, name: "Renamed", hostname: "new.test", port: 2200, username: "ops")
    try await wait { a.vaults.hosts.cards.first?.accessibilityLabel()?.contains("new.test:2200") == true }
    XCTAssertTrue(b.vaults.hosts.cards.first?.accessibilityLabel()?.contains("Renamed") == true)
    try services.profiles.deleteConnection(profile.id)
    try await wait { a.vaults.hosts.cards.isEmpty && b.vaults.hosts.cards.isEmpty }
    a.window?.setContentSize(.init(width: 480, height: 320)); a.window?.contentView?.layoutSubtreeIfNeeded()
    try render(a, name: "empty-narrow")
  }

  func test_home_forwarding_controls_share_the_live_session_and_open_it_without_duplicating() async throws {
    let services = try services(), server = try await TestSSHServer.start()
    addTeardownBlock { await server.stop() }
    try await server.enableTCPForwarding()
    _ = try services.profiles.saveConnection(name: "Live", hostname: server.host, port: server.port,
      username: server.username, credential: .password(server.password))
    let main = MainWindowController(services: services)
    defer { main.disconnectAll(); main.close() }
    try XCTUnwrap(main.vaults.hosts.cards.first).onOpen?()
    let pane = try XCTUnwrap(main.focusedPane)
    try await wait {
      if case .needsHostKeyConfirm = pane.session.state { pane.session.confirmHostKey(true) }
      return pane.session.state == .connected && pane.session.portForwards.destination != nil
    }
    main.showVaults(nil); main.manageLocalForwards(nil)
    let page = main.vaults.forwarding
    page.hostPopup.selectItem(withTitle: "Live")
    XCTAssertTrue(page.hostPopup.sendAction(try XCTUnwrap(page.hostPopup.action), to: page.hostPopup.target))
    let editor = try XCTUnwrap(page.editor)
    XCTAssertTrue(editor.model === pane.session.portForwards)
    let socket = try ForwardTestSocket.listener()
    let port = try ForwardTestSocket.boundPort(socket).port
    Darwin.close(socket)
    editor.localPortField.stringValue = String(port)
    editor.targetHostField.stringValue = "127.0.0.1"; editor.targetPortField.stringValue = "2222"
    XCTAssertTrue(editor.saveChanges())
    let start = try XCTUnwrap(descendants(editor.view).compactMap { $0 as? NSButton }.first { $0.title == "启动" })
    XCTAssertTrue(start.isEnabled); start.performClick(nil)
    try await wait { if case .running = editor.model.rules.first?.state { return true }; return false }
    let greeting = try await ForwardTestSocket.exchange(port: port, data: Data())
    XCTAssertTrue(String(decoding: greeting, as: UTF8.self).contains("SSH-"))
    XCTAssertNil(main.focusedPane)
    pane.takeFocus()
    XCTAssertFalse((main.window?.firstResponder as? NSView)?.isDescendant(of: pane.view) ?? false)
    page.connectButton.performClick(nil)
    XCTAssertTrue(main.focusedPane === pane); XCTAssertEqual(main.layout.tabs.count, 1)
    main.showVaults(nil); main.manageLocalForwards(nil)
    XCTAssertTrue(page.editor === editor)
    let stop = try XCTUnwrap(descendants(editor.view).compactMap { $0 as? NSButton }.first { $0.title == "停止" })
    stop.performClick(nil)
    try await wait { editor.model.rules.first?.state == .stopped }
    XCTAssertEqual(pane.session.state, .connected)
  }

  func test_empty_vault_window_restores_frame_and_saved_session_tabs_resume_from_home() throws {
    let services = try services(), workspace = WorkspaceController(services: services)
    let empty = workspace.openWindow(show: false), sessions = workspace.openWindow(show: false)
    sessions.newTab(nil)
    let pane = try XCTUnwrap(sessions.focusedPane)
    pane.restore(.init(hostname: "restore.test", username: "ops"))
    empty.window?.setContentSize(.init(width: 900, height: 600))
    XCTAssertTrue(workspace.saveNow())
    let snapshot = try XCTUnwrap(services.workspace.snapshot)
    XCTAssertEqual(snapshot.windows.count, 2)
    workspace.prepareToTerminate()
    for main in workspace.windows { main.close() }
    let restored = WorkspaceController(services: services)
    restored.restore(showWindows: false)
    defer { restored.prepareToTerminate(); for main in restored.windows { main.close() } }
    XCTAssertEqual(restored.windows.count, 2)
    XCTAssertTrue(restored.windows.allSatisfy(\.isShowingVaults))
    let target = try XCTUnwrap(restored.windows.first { !$0.layout.tabs.isEmpty })
    XCTAssertEqual(target.pane(id: pane.id)?.restorationSnapshot.connection.hostname, "restore.test")
    target.tabBar(try XCTUnwrap(target.workspaceView?.tabBar), select: try XCTUnwrap(target.layout.selectedTabId))
    XCTAssertEqual(target.focusedPane?.id, pane.id)
    XCTAssertEqual(target.focusedPane?.session.state, .idle)
  }
}
