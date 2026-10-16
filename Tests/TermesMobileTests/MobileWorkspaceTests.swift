import XCTest
import UIKit
import TermesKit
import SSHCore
@testable import SwiftTerm
@testable import TermesMobile

// Read mutable engine internals only while holding SwiftTerm's lock. Return
// copied text/identity so no model references escape into asynchronous tests.
@MainActor
private func terminalIdentity(_ view: TerminalView) -> ObjectIdentifier {
  view.withTerminal { ObjectIdentifier($0) }
}

@MainActor
private func terminalLineText(_ view: TerminalView, row: Int) -> String? {
  view.withTerminal { $0.getLine(row: row)?.translateToString(trimRight: true) }
}

@MainActor
final class MobileWorkspaceTests: XCTestCase {
  private var directory: URL!
  private var workspace: MobileWorkspace!

  override func setUp() async throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    workspace = MobileWorkspace(directory: directory, secrets: InMemorySecretStore())
  }

  override func tearDown() async throws {
    for session in workspace.sessions { workspace.close(session) }
    workspace = nil
    try? FileManager.default.removeItem(at: directory)
  }

  private func draft(name: String = "Development") -> MobileHostDraft {
    var draft = MobileHostDraft()
    draft.name = name; draft.hostname = "127.0.0.1"; draft.port = "1"
    draft.password = "local-test-password"
    return draft
  }

  func testInvalidAddressDoesNotPersistHost() throws {
    for port in ["", "0", "65536", "ssh"] {
      var invalid = draft(); invalid.port = port
      XCTAssertThrowsError(try workspace.save(invalid))
    }
    var invalid = draft(); invalid.hostname = "   "
    XCTAssertThrowsError(try workspace.save(invalid))
    XCTAssertTrue(workspace.hosts.isEmpty)
    XCTAssertTrue(try workspace.profiles.profiles().isEmpty)
  }

  func testKeyboardTabNavigationUsesTabsAndRetainsSplitFocus() throws {
    let profile = try workspace.save(draft())
    let first = try XCTUnwrap(workspace.open(profile)); first.disconnect()
    let second = try XCTUnwrap(workspace.open(profile, newSession: true)); second.disconnect()
    let third = try XCTUnwrap(workspace.open(profile, newSession: true)); third.disconnect()
    workspace.merge(second, beside: first, edge: .right)
    workspace.selectTab(at: 0)
    XCTAssertEqual(workspace.selectedSessionID, second.id)
    workspace.cycleTab(by: -1)
    XCTAssertEqual(workspace.selectedSessionID, third.id)
    workspace.cycleTab(by: 1)
    XCTAssertEqual(workspace.selectedSessionID, second.id)
    workspace.selectTab(at: 8)
    XCTAssertEqual(workspace.selectedSessionID, second.id)
    XCTAssertEqual(workspace.layout.tabs.count, 2)
    XCTAssertEqual(workspace.layout.tabs[0].paneIds.count, 2)
  }

  func testNewTabHostPickerAlwaysCreatesAnIndependentSession() throws {
    let profile = try workspace.save(draft())
    let first = try XCTUnwrap(workspace.open(profile)); first.disconnect()
    first.terminalController.terminal.feed(text: "existing session output")
    let picker = MobileVaultsController(workspace: workspace, choosingNewSession: true)
    picker.loadViewIfNeeded()
    XCTAssertEqual(picker.numberOfSections(in: picker.tableView), 1)
    picker.tableView(picker.tableView, didSelectRowAt: IndexPath(row: 0, section: 0))
    XCTAssertEqual(workspace.sessions.count, 2)
    let created = try XCTUnwrap(workspace.selectedSession); created.disconnect()
    XCTAssertNotEqual(created.id, first.id)
    XCTAssertTrue(String(decoding: first.terminalController.exportSnapshot(), as: UTF8.self).contains("existing session output"))
  }

  func testEmptyWorkspaceRoutesNewTabCommandToItsOwnHostPicker() async throws {
    let root = MobileRootController(workspace: workspace)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previousKeyWindow = scene.keyWindow
    let window = UIWindow(windowScene: scene)
    window.rootViewController = root; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil; previousKeyWindow?.makeKey() }
    root.view.layoutIfNeeded()
    XCTAssertTrue(root.becomeFirstResponder())
    let command = try XCTUnwrap(root.keyCommands?.first { $0.input == "t" && $0.modifierFlags == .command })
    XCTAssertTrue(root.canPerformAction(command.action!, withSender: command))
    XCTAssertTrue(UIApplication.shared.sendAction(command.action!, to: nil, from: command, for: nil))
    try await Task.sleep(for: .milliseconds(400))
    let navigation = try XCTUnwrap(root.presentedViewController as? UINavigationController)
    XCTAssertEqual(navigation.topViewController?.title, "新建连接")
    XCTAssertFalse(root.canPerformAction(command.action!, withSender: command))
    XCTAssertTrue(workspace.sessions.isEmpty, "opening the picker must not create or connect a session")
    await withCheckedContinuation { continuation in root.dismiss(animated: false) { continuation.resume() } }
  }

  func testWorkspaceKeyboardCommandsRouteFromTerminalAndStopAtPresentedEditors() async throws {
    let profile = try workspace.save(draft())
    let first = try XCTUnwrap(workspace.open(profile)); first.disconnect()
    let second = try XCTUnwrap(workspace.open(profile, newSession: true)); second.disconnect()
    let root = MobileRootController(workspace: workspace)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    let previousKeyWindow = scene.keyWindow
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(x: 0, y: 0, width: 1_024, height: 768)
    window.rootViewController = root; window.makeKeyAndVisible()
    defer { window.isHidden = true; window.rootViewController = nil; previousKeyWindow?.makeKey() }
    root.view.layoutIfNeeded()
    await Task.yield()
    second.terminalController.showKeyboard()
    let firstTab = try XCTUnwrap(root.keyCommands?.first { $0.input == "1" && $0.modifierFlags == .command })
    XCTAssertTrue(UIApplication.shared.sendAction(firstTab.action!, to: nil, from: firstTab, for: nil))
    XCTAssertEqual(workspace.selectedSessionID, first.id)
    root.nextTab(nil)
    XCTAssertEqual(workspace.selectedSessionID, second.id)
    XCTAssertFalse(root.canPerformAction(#selector(MobileRootController.searchTerminal(_:)), withSender: nil), "the initial connection overlay must not focus a hidden terminal search field")
    root.openSettings(nil)
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertFalse(root.canPerformAction(#selector(MobileRootController.duplicateCurrentSession(_:)), withSender: nil))
    root.duplicateCurrentSession(nil)
    root.closeCurrentSession(nil)
    XCTAssertEqual(workspace.sessions.count, 2, "commands must not change the workspace behind an editor")
    await withCheckedContinuation { continuation in root.dismiss(animated: false) { continuation.resume() } }
  }

  func testInvalidCredentialDoesNotCreateHost() {
    var invalid = draft(); invalid.password = ""
    XCTAssertThrowsError(try workspace.save(invalid))
    invalid.authentication = .privateKey; invalid.privateKey = "not a key"
    XCTAssertThrowsError(try workspace.save(invalid))
    invalid.authentication = .existingKey
    XCTAssertThrowsError(try workspace.save(invalid))
    XCTAssertTrue(workspace.hosts.isEmpty)
  }

  func testEditPreservesIdentityAndCredential() throws {
    var original = draft(); original.name = "  Development  "; original.username = "  root "
    let saved = try workspace.save(original)
    XCTAssertEqual(saved.name, "Development")
    XCTAssertEqual(saved.username, "root")
    var edit = MobileHostDraft(profile: saved)
    edit.name = "Production"; edit.port = "2222"
    let updated = try workspace.save(edit)
    XCTAssertEqual(updated.id, saved.id)
    XCTAssertEqual(workspace.hosts.count, 1)
    XCTAssertEqual(try workspace.profiles.makeConfig(for: saved.id).auth, .password(original.password))
    XCTAssertEqual(try workspace.profiles.makeConfig(for: saved.id).port, 2222)
    let persisted = MobileWorkspace(directory: directory, secrets: InMemorySecretStore())
    XCTAssertEqual(persisted.hosts.first?.name, "Production")
  }

  func testSwitchingAndClosingSessionsRetainsOtherTerminal() throws {
    let profile = try workspace.save(draft())
    let first = try XCTUnwrap(workspace.open(profile))
    first.disconnect()
    let terminal = first.terminalController
    terminal.terminal.feed(text: "retained output")
    let second = try XCTUnwrap(workspace.open(profile, newSession: true))
    second.disconnect()
    workspace.selectedSessionID = first.id
    XCTAssertTrue(workspace.selectedSession?.terminalController === terminal)
    let line = terminalLineText(terminal.terminal, row: 0)
    XCTAssertTrue(line?.contains("retained output") == true)
    workspace.close(first)
    XCTAssertEqual(workspace.selectedSessionID, second.id)
    XCTAssertEqual(workspace.sessions.count, 1)
    workspace.close(second)
    XCTAssertNil(workspace.selectedSessionID)
    XCTAssertTrue(workspace.sessions.isEmpty)
  }

  func testClosingBeforeConnectionTaskStartsDoesNotReconnect() async throws {
    let profile = try workspace.save(draft())
    let session = try XCTUnwrap(workspace.open(profile))
    workspace.close(session)
    await Task.yield()
    XCTAssertTrue(session.manager.state == .idle || session.manager.state == .disconnected)
    XCTAssertFalse(session.manager.state.isActive)
    XCTAssertNil(session.manager.onData)
  }

  func testEditingDestinationCreatesNewSessionAndDoesNotRetargetOldTerminal() throws {
    let original = try workspace.save(draft())
    let first = try XCTUnwrap(workspace.open(original))
    first.disconnect()
    var edit = MobileHostDraft(profile: original)
    edit.hostname = "127.0.0.2"; edit.name = "Moved"
    let updated = try workspace.save(edit)
    let second = try XCTUnwrap(workspace.open(updated))
    second.disconnect()
    XCTAssertNotEqual(first.id, second.id)
    XCTAssertEqual(workspace.sessions.count, 2)
    XCTAssertTrue(first.address.contains("127.0.0.1"))
    XCTAssertTrue(second.address.contains("127.0.0.2"))
    workspace.reconnect(first)
    XCTAssertEqual(workspace.error, MobileValidationError.profileChanged.errorDescription)
    XCTAssertFalse(first.manager.state.isActive)
  }

  func testAppearanceChangesKeepTerminalInstanceAndOutput() throws {
    let profile = try workspace.save(draft())
    let session = try XCTUnwrap(workspace.open(profile))
    session.disconnect()
    let controller = session.terminalController
    controller.terminal.feed(text: "before theme change")
    var settings = AppearanceSettings(); settings.terminalFontSize = 18; settings.terminalTheme = .flexokiLight
    settings.terminalFontName = "SourceCodePro-Regular"; settings.terminalTextColor = 0x336699
    controller.apply(settings, dark: false)
    XCTAssertTrue(session.terminalController === controller)
    XCTAssertEqual(controller.terminal.font.pointSize, 18)
    XCTAssertEqual(controller.terminal.font.fontName, "SourceCodePro-Regular")
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    XCTAssertTrue(controller.terminal.nativeForegroundColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
    XCTAssertEqual(red, 0.2, accuracy: 0.001)
    XCTAssertEqual(green, 0.4, accuracy: 0.001)
    XCTAssertEqual(blue, 0.6, accuracy: 0.001)
    XCTAssertTrue(terminalLineText(controller.terminal, row: 0)?.contains("before theme change") == true)
  }

  func testClosingSessionClosesItsMonitor() throws {
    let profile = try workspace.save(draft())
    let session = try XCTUnwrap(workspace.open(profile))
    session.disconnect()
    let monitor = session.manager.serverMonitor
    monitor.open()
    XCTAssertTrue(monitor.isOpen)
    workspace.close(session)
    XCTAssertFalse(monitor.isOpen)
    XCTAssertEqual(monitor.state, .closed)
  }

  func testWorkspaceRestoresSplitAndFocusWithoutOpeningConnectionsOrPersistingSecrets() throws {
    let profile = try workspace.save(draft())
    let first = try XCTUnwrap(workspace.open(profile)); first.disconnect()
    let second = try XCTUnwrap(workspace.open(profile, newSession: true)); second.disconnect()
    workspace.merge(second, beside: first, edge: .right)
    guard case .split(let splitID, _, _, _) = workspace.layout.selectedTab?.root else { return XCTFail("expected split") }
    workspace.setFractions([0.3, 0.7], split: splitID)
    workspace.toggleMaximize(second)
    let savedLayout = workspace.layout
    let data = try Data(contentsOf: directory.appendingPathComponent("workspace.json"))
    XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("local-test-password"))

    let restored = MobileWorkspace(directory: directory, secrets: InMemorySecretStore())
    XCTAssertEqual(restored.layout, savedLayout)
    XCTAssertEqual(restored.selectedSessionID, second.id)
    XCTAssertEqual(restored.sessions.map(\.id), [first.id, second.id])
    XCTAssertTrue(restored.sessions.allSatisfy { $0.manager.state == .idle && $0.manager.currentConfig == nil })
    XCTAssertTrue(restored.sessions.allSatisfy { $0.fileBrowser == nil })
    restored.detach(try XCTUnwrap(restored.selectedSession))
    XCTAssertEqual(restored.layout.tabs.count, 2)
    XCTAssertEqual(restored.layout.selectedTab?.paneIds, [second.id])
    for session in restored.sessions { restored.close(session) }
  }

  func testClosingFocusedSplitKeepsItsNeighborSelected() throws {
    let profile = try workspace.save(draft())
    let first = try XCTUnwrap(workspace.open(profile)); first.disconnect()
    let second = try XCTUnwrap(workspace.open(profile, newSession: true)); second.disconnect()
    workspace.merge(second, beside: first, edge: .bottom)
    workspace.close(second)
    XCTAssertEqual(workspace.selectedSessionID, first.id)
    XCTAssertEqual(workspace.layout.selectedTab?.root, .pane(first.id))
    XCTAssertEqual(workspace.layout.allPaneIds, workspace.sessions.map(\.id))
  }

  func testRestoredSessionDoesNotSilentlyFollowEditedDestination() throws {
    let original = try workspace.save(draft())
    let session = try XCTUnwrap(workspace.open(original)); session.disconnect()
    var edit = MobileHostDraft(profile: original); edit.hostname = "127.0.0.2"
    _ = try workspace.save(edit)
    let restored = MobileWorkspace(directory: directory, secrets: InMemorySecretStore())
    let old = try XCTUnwrap(restored.selectedSession)
    XCTAssertTrue(old.address.contains("127.0.0.1"))
    restored.reconnect(old)
    XCTAssertEqual(restored.error, MobileValidationError.profileChanged.errorDescription)
    XCTAssertEqual(old.manager.state, .idle)
    restored.close(old)
  }

  func testUnreadableWorkspaceIsProtectedUntilExplicitSaveAndBackup() throws {
    let url = directory.appendingPathComponent("workspace.json")
    let original = Data("invalid workspace".utf8); try original.write(to: url)
    let restored = MobileWorkspace(directory: directory, secrets: InMemorySecretStore())
    XCTAssertNotNil(restored.error)
    restored.persistWorkspace()
    XCTAssertEqual(try Data(contentsOf: url), original)
    restored.persistWorkspace(replacingUnreadable: true)
    let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.hasPrefix("workspace-backup-") }
    XCTAssertEqual(backups.count, 1)
    XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), original)
    XCTAssertNotEqual(try Data(contentsOf: url), original)
  }

  func testOfflineForwardRulesAndSnippetsPersistWithoutCredentials() async throws {
    let profile = try workspace.save(draft())
    let model = try await workspace.forwardingManager(for: profile)
    let config = LocalForwardConfiguration(localPort: 18080, targetHost: "127.0.0.1", targetPort: 8080)
    _ = try model.save(configuration: config)
    XCTAssertFalse(model.isConnected)
    let snippet = try workspace.snippets.save(name: "Deploy", command: "echo {{env}}", group: "Operations", usesParameters: true)
    let restored = MobileWorkspace(directory: directory, secrets: InMemorySecretStore())
    let offline = try await restored.forwardingManager(for: profile)
    XCTAssertEqual(offline.rules.first?.configuration, config)
    XCTAssertEqual(offline.rules.first?.state, .stopped)
    XCTAssertEqual(try restored.snippets.all(), [snippet])
    XCTAssertTrue(restored.sessions.isEmpty)
  }

  func testFileBrowserBelongsToSessionAndClosesWithIt() throws {
    let profile = try workspace.save(draft())
    let session = try XCTUnwrap(workspace.open(profile)); session.disconnect()
    let browser = session.files()
    XCTAssertTrue(session.files() === browser)
    XCTAssertFalse(browser.isConnected)
    workspace.close(session)
    XCTAssertFalse(browser.isConnected)
    XCTAssertEqual(browser.status, "文件面板已关闭")
  }

  func testMovingBetweenWindowsPreservesTerminalAndBothSavedLayouts() throws {
    let other = MobileWorkspace(sharing: workspace, windowID: UUID())
    XCTAssertTrue(other.profiles === workspace.profiles)
    XCTAssertTrue(other.appearance === workspace.appearance)
    let profile = try workspace.save(draft())
    XCTAssertEqual(other.hosts.first?.id, profile.id)
    let session = try XCTUnwrap(workspace.open(profile)); session.disconnect()
    let terminal = session.terminalController
    terminal.terminal.feed(text: "moving output")
    workspace.transfer(session, to: other)
    XCTAssertTrue(workspace.sessions.isEmpty)
    XCTAssertTrue(other.selectedSession === session)
    XCTAssertTrue(other.selectedSession?.terminalController === terminal)
    XCTAssertTrue(terminalLineText(terminal.terminal, row: 0)?.contains("moving output") == true)
    let saved = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(contentsOf: directory.appendingPathComponent("workspace.json")))
    try saved.validate()
    XCTAssertEqual(saved.windows.count, 2)
    XCTAssertTrue(saved.windows.first(where: { $0.id == workspace.windowID })?.panes.isEmpty == true)
    XCTAssertEqual(saved.windows.first(where: { $0.id == other.windowID })?.panes.map(\.id), [session.id])
    other.discardWindow()
    XCTAssertTrue(other.sessions.isEmpty)
    let remaining = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(contentsOf: directory.appendingPathComponent("workspace.json")))
    XCTAssertEqual(remaining.windows.map(\.id), [workspace.windowID])
  }
}

@MainActor
final class MobileTerminalOutputNoticeTests: XCTestCase {
  private func fixture() -> (SessionManager, MobileTerminalController, UIWindow) {
    let manager = SessionManager(knownHosts: KnownHostsStore(
      fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
    let controller = MobileTerminalController(manager: manager)
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 360, height: 500))
    window.rootViewController = controller
    window.makeKeyAndVisible()
    controller.view.frame = window.bounds
    controller.view.setNeedsLayout()
    controller.view.layoutIfNeeded()
    return (manager, controller, window)
  }

  private func history(_ count: Int = 200) -> Data {
    Data((0..<count).map { "history \($0)\r\n" }.joined().utf8)
  }

  private func close(_ controller: MobileTerminalController, window: UIWindow) {
    controller.hideKeyboard()
    controller.shutdown()
    window.isHidden = true
    window.rootViewController = nil
  }

  func testTerminalSearchNavigatesChineseMatchesWithoutChangingOutputAndExportsPlainUTF8() throws {
    let (manager, controller, window) = fixture()
    defer { close(controller, window: window) }
    manager.onData?(Data("\u{1b}[31m中文needle first\u{1b}[0m\r\n中文NEEDLE second\r\n中文needle third\r\n".utf8))
    controller.showSearch()
    controller.searchField.text = "中文needle"
    controller.searchField.sendActions(for: .editingChanged)
    controller.apply(.init(terminalTheme: .graphite), dark: false)
    XCTAssertEqual(controller.searchBar.overrideUserInterfaceStyle, .dark, "a dark terminal needs readable search controls even when the app uses light mode")
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    XCTAssertTrue(controller.searchStatus.textColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
    XCTAssertGreaterThan(red, 0.5)
    let first = controller.terminal.searchMatchSummary("中文needle")
    XCTAssertEqual(first.total, 3)
    XCTAssertGreaterThan(first.index, 0)
    XCTAssertTrue(controller.searchField.isFirstResponder)
    XCTAssertFalse(controller.terminal.isFirstResponder)
    let snapshot = controller.exportSnapshot()
    controller.navigateSearch(forward: true)
    let next = controller.terminal.searchMatchSummary("中文needle")
    XCTAssertEqual(next.index, first.index % 3 + 1)
    controller.navigateSearch(forward: false)
    XCTAssertEqual(controller.terminal.searchMatchSummary("中文needle").index, first.index)
    XCTAssertEqual(controller.exportSnapshot(), snapshot)
    let text = try XCTUnwrap(String(data: snapshot, encoding: .utf8))
    XCTAssertTrue(text.contains("中文needle first"))
    XCTAssertTrue(text.contains("中文NEEDLE second"))
    XCTAssertFalse(text.contains("\u{1b}"))
    controller.searchField.text = "no-such-output"
    controller.searchField.sendActions(for: .editingChanged)
    XCTAssertEqual(controller.searchStatus.text, "无匹配")
    controller.closeSearch()
    XCTAssertFalse(controller.isSearching)
    XCTAssertFalse(controller.searchField.isFirstResponder)
  }

  func testNewOutputPreservesHistoryAndGridWhileButtonReturnsToLatestWithoutOpeningKeyboard() {
    let (manager, controller, window) = fixture()
    defer { close(controller, window: window) }
    let terminal = controller.terminal, buffer = terminalIdentity(terminal)
    manager.onData?(history())
    XCTAssertFalse(controller.hasUnseenOutput)
    XCTAssertTrue(controller.newOutputButton.isHidden)
    terminal.scroll(toPosition: 0.5)
    XCTAssertTrue(controller.newOutputButton.isHidden, "reading history alone must not create a notification")
    manager.onData?(Data())
    XCTAssertFalse(controller.hasUnseenOutput)

    let topRow = terminal.terminalStateSnapshot().viewportRow
    let firstLine = terminalLineText(terminal, row: 0)
    let terminalFrame = terminal.frame, rows = terminal.terminalDimensions.rows, cols = terminal.terminalDimensions.cols
    manager.onData?(Data("latest server output\r\n".utf8))
    controller.view.layoutIfNeeded()

    XCTAssertTrue(controller.hasUnseenOutput)
    XCTAssertFalse(controller.newOutputButton.isHidden)
    XCTAssertEqual(terminal.terminalStateSnapshot().viewportRow, topRow)
    XCTAssertEqual(terminalLineText(terminal, row: 0), firstLine)
    XCTAssertEqual(terminal.frame, terminalFrame)
    XCTAssertEqual(terminal.terminalDimensions.rows, rows)
    XCTAssertEqual(terminal.terminalDimensions.cols, cols)
    let buttonFrame = controller.newOutputButton.convert(controller.newOutputButton.bounds, to: controller.view)
    XCTAssertTrue(controller.view.bounds.contains(buttonFrame))
    XCTAssertGreaterThanOrEqual(buttonFrame.height, 44)
    XCTAssertTrue(controller.view.hitTest(CGPoint(x: buttonFrame.midX, y: buttonFrame.midY), with: nil)
      === controller.newOutputButton)

    let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
      controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
    }
    let attachment = XCTAttachment(image: image)
    attachment.name = "Mobile terminal new output notice"
    attachment.lifetime = .keepAlways
    add(attachment)

    XCTAssertFalse(terminal.isFirstResponder)
    controller.newOutputButton.sendActions(for: .touchUpInside)
    XCTAssertEqual(terminal.scrollPosition, 1)
    XCTAssertFalse(controller.hasUnseenOutput)
    XCTAssertTrue(controller.newOutputButton.isHidden)
    XCTAssertFalse(terminal.isFirstResponder, "returning to output must not open a dismissed keyboard")
    XCTAssertTrue(terminalIdentity(terminal) == buffer)
    XCTAssertTrue(String(decoding: terminal.getBufferAsData(), as: UTF8.self).contains("latest server output"))
    manager.onData?(Data("following output\r\n".utf8))
    XCTAssertEqual(terminal.scrollPosition, 1)
    XCTAssertFalse(controller.hasUnseenOutput)
  }

  func testReturningToLatestKeepsAnAlreadyFocusedTerminalFocused() {
    let (manager, controller, window) = fixture()
    defer { close(controller, window: window) }
    let terminal = controller.terminal
    controller.showKeyboard()
    XCTAssertTrue(terminal.isFirstResponder)
    manager.onData?(history())
    terminal.scroll(toPosition: 0.5)
    manager.onData?(Data("background output\r\n".utf8))
    XCTAssertTrue(controller.hasUnseenOutput)
    controller.newOutputButton.sendActions(for: .touchUpInside)
    XCTAssertEqual(terminal.scrollPosition, 1)
    XCTAssertTrue(terminal.isFirstResponder)
    XCTAssertFalse(controller.hasUnseenOutput)
  }

  func testScrollViewReachingBottomAndAlternateScreenClearTheNotice() async throws {
    let (manager, controller, window) = fixture()
    defer { close(controller, window: window) }
    let terminal = controller.terminal
    manager.onData?(Data("short output".utf8))
    XCTAssertFalse(terminal.canScroll)
    XCTAssertEqual(terminal.scrollPosition, 0)
    XCTAssertFalse(controller.hasUnseenOutput)

    terminal.changeScrollback(50)
    manager.onData?(history())
    terminal.scroll(toPosition: 0)
    manager.onData?(history())
    XCTAssertEqual(terminal.scrollPosition, 0)
    XCTAssertTrue(controller.hasUnseenOutput, "the oldest line in a full history is still away from latest output")

    // UIScrollView gestures update contentOffset without calling TerminalViewDelegate.scrolled.
    let bottom = max(0, terminal.contentSize.height - terminal.bounds.height + terminal.adjustedContentInset.bottom)
    terminal.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
    let deadline = Date().addingTimeInterval(2)
    while controller.hasUnseenOutput && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertEqual(terminal.scrollPosition, 1)
    XCTAssertFalse(controller.hasUnseenOutput)
    XCTAssertTrue(controller.newOutputButton.isHidden)

    terminal.scroll(toPosition: 0.5)
    manager.onData?(Data("\rprogress update".utf8))
    XCTAssertTrue(controller.hasUnseenOutput, "output without a newline must also notify")
    manager.onData?(Data("\u{1b}[?1049halternate screen\r\n".utf8))
    XCTAssertFalse(terminal.canScroll)
    XCTAssertFalse(controller.hasUnseenOutput)
    manager.onData?(Data("alternate update".utf8))
    XCTAssertTrue(controller.newOutputButton.isHidden)

    manager.onData?(Data("\u{1b}[?1049l".utf8))
    terminal.scroll(toPosition: 0.5)
    manager.onData?(Data("resumed output\r\n".utf8))
    XCTAssertTrue(controller.hasUnseenOutput)
    terminal.clearScrollback()
    controller.view.setNeedsLayout()
    controller.view.layoutIfNeeded()
    XCTAssertFalse(terminal.canScroll)
    XCTAssertFalse(controller.hasUnseenOutput)
    XCTAssertTrue(controller.newOutputButton.isHidden)
  }

  func testHiddenTerminalRetainsNoticeAndSmallLayoutsKeepItReachable() {
    let (manager, controller, window) = fixture()
    defer { close(controller, window: window) }
    let terminal = controller.terminal, buffer = terminalIdentity(terminal)
    manager.onData?(history())
    terminal.scroll(toPosition: 0.5)
    window.rootViewController = UIViewController()
    XCTAssertNil(controller.view.window)
    manager.onData?(Data("hidden session output\r\n".utf8))
    XCTAssertTrue(controller.hasUnseenOutput)

    window.rootViewController = controller
    controller.apply(.init(terminalTheme: .termiusDark, terminalFontSize: 18), dark: true)
    for size in [CGSize(width: 240, height: 140), CGSize(width: 700, height: 360)] {
      window.frame.size = size
      controller.view.frame = CGRect(origin: .zero, size: size)
      controller.view.setNeedsLayout()
      controller.view.layoutIfNeeded()
      XCTAssertTrue(controller.hasUnseenOutput)
      XCTAssertFalse(controller.newOutputButton.isHidden)
      let frame = controller.newOutputButton.convert(controller.newOutputButton.bounds, to: controller.view)
      XCTAssertTrue(controller.view.bounds.contains(frame))
      XCTAssertGreaterThanOrEqual(frame.height, 44)
    }
    XCTAssertTrue(terminalIdentity(terminal) == buffer)
    controller.newOutputButton.sendActions(for: .touchUpInside)
    controller.apply(.init(terminalTheme: .light, terminalFontSize: 14), dark: false)
    controller.view.setNeedsLayout()
    controller.view.layoutIfNeeded()
    XCTAssertFalse(controller.hasUnseenOutput, "appearance and layout changes must not create unread output")
  }

  func testLongMixedWidthLinesKeepEveryNumberedSegmentAcrossLayoutAndFontReflow() {
    let (manager, controller, window) = fixture()
    defer { close(controller, window: window) }
    controller.apply(.init(terminalFontSize: 14), dark: false)
    let terminal = controller.terminal, model = terminalIdentity(terminal)
    let expectedSegments = (0..<8).map { row in
      (0..<16).map { segment in "[行\(row)段\(segment):Ab09中文终端Wide]" }
    }
    let payload = expectedSegments.map { $0.joined(separator: "|") }.joined(separator: "\r\n")
    manager.onData?(Data((payload + "\r\nready> ").utf8))

    // Reconstruct hard lines from soft-wrapped rows, omitting only wide-cell fillers.
    func logicalLines() -> [String] {
      terminal.withTerminal { model in
        var result: [String] = []
        var row = model.buffer.totalLinesTrimmed
        while let line = model.getScrollInvariantLine(row: row) {
          let text = line.translateToString(trimRight: true, skipNullCellsFollowingWide: true,
            characterProvider: { model.getCharacter(for: $0) })
          if line.isWrapped, !result.isEmpty { result[result.count - 1] += text }
          else { result.append(text) }
          row += 1
        }
        return result.filter { !$0.isEmpty }
      }
    }

    func assertContents(_ phase: String) {
      let lines = logicalLines()
      XCTAssertEqual(terminal.withTerminal { $0.buffer.totalLinesTrimmed }, 0, "\(phase): fixture must fit in scrollback")
      XCTAssertEqual(lines.count, expectedSegments.count + 1, "\(phase): hard-line boundaries changed")
      for (row, expected) in expectedSegments.enumerated() {
        guard row < lines.count else { continue }
        XCTAssertEqual(lines[row].components(separatedBy: "|"), expected,
          "\(phase): row \(row) lost, duplicated, or reordered a numbered segment")
      }
      XCTAssertEqual(lines.last, "ready> ", "\(phase): the live prompt changed")
    }

    assertContents("initial portrait")
    var columnCounts = Set([terminal.terminalDimensions.cols])
    for (size, fontSize) in [
      (CGSize(width: 700, height: 320), 14.0),
      (CGSize(width: 260, height: 380), 14.0),
      (CGSize(width: 260, height: 380), 22.0),
      (CGSize(width: 700, height: 320), 22.0),
      (CGSize(width: 360, height: 500), 14.0),
    ] {
      window.frame.size = size
      controller.view.frame = CGRect(origin: .zero, size: size)
      controller.view.setNeedsLayout()
      controller.view.layoutIfNeeded()
      controller.apply(.init(terminalFontSize: fontSize), dark: false)
      controller.view.layoutIfNeeded()
      columnCounts.insert(terminal.terminalDimensions.cols)
      XCTAssertTrue(terminalIdentity(terminal) == model)
      assertContents("\(Int(size.width)) × \(Int(size.height)), font \(Int(fontSize))")
    }
    XCTAssertGreaterThan(columnCounts.count, 2, "the test must exercise different terminal widths")
  }

  func testShutdownClearsAnExistingNoticeAndUnbindsOutput() {
    let (manager, controller, window) = fixture()
    defer { close(controller, window: window) }
    let terminal = controller.terminal
    manager.onData?(history())
    terminal.scroll(toPosition: 0.5)
    XCTAssertTrue(terminal.canScroll)
    XCTAssertLessThan(terminal.scrollPosition, 1)
    manager.onData?(Data("output before shutdown\r\n".utf8))
    XCTAssertTrue(controller.hasUnseenOutput)
    controller.shutdown()
    XCTAssertNil(manager.onData)
    XCTAssertFalse(controller.hasUnseenOutput)
    XCTAssertTrue(controller.newOutputButton.isHidden)
  }
}
