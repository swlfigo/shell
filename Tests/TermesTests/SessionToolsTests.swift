import AppKit
import XCTest
import TermesKit
import SSHCore
@testable import Termes

@MainActor
final class SessionToolsTests: XCTestCase {
  private func wait(_ predicate: () -> Bool, timeout: TimeInterval = 20,
                    file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    guard predicate() else { XCTFail("tools timed out", file: file, line: line); throw CancellationError() }
  }
  private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

  /// Render the fixture's own AppKit view when WindowServer capture is unavailable
  /// (for example while the screen is locked). This never reads another app's window.
  private func render(_ window: NSWindow, name: String, directory: String) throws {
    let view = try XCTUnwrap(window.contentView)
    view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    let output = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try data.write(to: output.appendingPathComponent("tools-\(name).png"), options: .atomic)
  }

  func test_tools_and_file_location_controls_remain_reachable_at_minimum_pane_size() throws {
    _ = NSApplication.shared
    let tools = SessionToolsView(frame: .zero), inspector = SessionToolsScrollView(tools: tools)
    let local = NSView(), remote = NSView(), files = LocalRemoteFilesView(local: local, remote: remote, usesTabs: true)
    let overview = NSView(), terminal = NSView(), container = TerminalMonitorView(workspace: terminal, monitor: inspector)
    tools.setContents(overview: overview, files: files)
    tools.onSelect = { tools.select($0) }
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1400, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = container
    defer { window.close(); tools.onSelect = nil }
    for size in [NSSize(width: 1400, height: 700), .init(width: 930, height: 700), .init(width: 480, height: 320), .init(width: 240, height: 140)] {
      window.setContentSize(size)
      for tool in [SessionTool.overview, .files] {
        tools.tabControl.selectedSegment = tool.rawValue
        XCTAssertTrue(tools.tabControl.sendAction(tools.tabControl.action, to: tools.tabControl.target))
        container.needsLayout = true; container.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(terminal.frame.height, 0); XCTAssertTrue(container.bounds.contains(terminal.frame))
        XCTAssertTrue(container.bounds.contains(inspector.frame))
        XCTAssertTrue(inspector.hasVerticalScroller && inspector.hasHorizontalScroller)
        XCTAssertGreaterThanOrEqual(tools.bounds.height, 320)
        XCTAssertEqual(tools.usesCompactLayout, size.width < 880)
        XCTAssertGreaterThan(files.frame.height, 0)
        XCTAssertEqual(overview.isHidden, tool != .overview); XCTAssertEqual(files.isHidden, tool != .files)
        for control in descendants(tools).compactMap({ $0 as? NSControl }).filter({ !$0.isHiddenOrHasHiddenAncestor }) {
          XCTAssertTrue(tools.bounds.contains(control.convert(control.bounds, to: tools)), "tools control is unreachable: \(control)")
        }
        files.locationControl.selectedSegment = 1; files.locationChanged()
        XCTAssertEqual(files.locationControl.width(forSegment: 0), files.locationControl.width(forSegment: 1), accuracy: 0.5)
        XCTAssertLessThanOrEqual(files.locationControl.width(forSegment: 0) + files.locationControl.width(forSegment: 1), files.locationControl.bounds.width)
        XCTAssertTrue(remote.isHidden); XCTAssertFalse(local.isHidden)
        files.locationControl.selectedSegment = 0; files.locationChanged()
        XCTAssertFalse(remote.isHidden); XCTAssertTrue(local.isHidden)
      }
    }
  }

  func test_switching_and_collapsing_tools_preserve_real_ssh_navigation_transfer_and_pending_input() async throws {
    _ = NSApplication.shared
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("工具面板测试.bin")
    try Data(repeating: 0xA5, count: 8 * 1024 * 1024).write(to: source)
    let services = AppServices(directory: directory, secrets: InMemorySecretStore()), main = MainWindowController(services: services, empty: false)
    defer { main.disconnectAll(); main.close() }
    let pane = try XCTUnwrap(main.focusedPane), window = try XCTUnwrap(main.window)
    let menu = NSMenuItem(title: "服务器工具", action: #selector(MainWindowController.toggleSessionTools(_:)), keyEquivalent: "i")
    XCTAssertFalse(main.validateMenuItem(menu))
    pane.connect(.init(hostname: server.host, port: server.port, username: server.username, auth: .password(server.password)),
      label: .init(name: "工具交互 · 本机测试服务器", username: server.username))
    try await wait {
      if case .needsHostKeyConfirm = pane.session.state { pane.session.confirmHostKey(true) }
      return pane.session.state == .connected && pane.children.contains { $0 is TerminalViewController }
    }
    window.setContentSize(.init(width: 1440, height: 860)); main.showWindow(nil); window.makeKeyAndOrderFront(nil)
    let terminal = try XCTUnwrap(pane.children.compactMap { $0 as? TerminalViewController }.first)
    let buffer = terminal.terminalView.getTerminal(), version = pane.session.connectionVersion
    main.toggleSessionTools(nil)
    let tools = try XCTUnwrap(pane.toolsView), monitor = try XCTUnwrap(pane.monitorVC)
    XCTAssertEqual(tools.selectedTool, .overview); XCTAssertTrue(pane.isToolsVisible)
    XCTAssertFalse(pane.children.contains { $0 is FileBrowserViewController })
    XCTAssertTrue(main.validateMenuItem(menu)); XCTAssertEqual(menu.state, .on)
    pane.selectTool(.files)
    let files = try XCTUnwrap(pane.children.compactMap { $0 as? FileBrowserViewController }.first)
    try await wait { files.model.directory != nil && !files.model.isBrowsingBusy && monitor.model.current != nil }
    files.localBrowser.model.navigate(directory)
    try await wait { !files.localBrowser.model.isBusy && files.localBrowser.model.directory == directory.resolvingSymlinksInPath() }
    files.model.createDirectory(name: "工具目录")
    try await wait { !files.model.isBrowsingBusy && files.model.entries.contains { $0.name == "工具目录" } }
    let remoteDirectory = RemotePath.child("工具目录", in: try XCTUnwrap(files.model.directory))
    files.pathField.stringValue = remoteDirectory
    XCTAssertTrue(files.pathField.sendAction(files.pathField.action, to: files.pathField.target))
    try await wait { files.model.directory == remoteDirectory && !files.model.isBrowsingBusy }
    let fileLocations = try XCTUnwrap(files.view as? LocalRemoteFilesView)
    fileLocations.locationControl.selectedSegment = 1; fileLocations.locationChanged()
    pane.selectTool(.overview); pane.selectTool(.files)
    XCTAssertEqual(fileLocations.locationControl.selectedSegment, 1)
    fileLocations.locationControl.selectedSegment = 0; fileLocations.locationChanged()
    pane.takeFocus(); pane.session.sendInput(Data("printf 'TOOLS_%s\\n' 'INPUT_KEPT'".utf8))
    try await wait { String(decoding: buffer.getBufferAsData(), as: UTF8.self).contains("INPUT_KEPT") }
    XCTAssertFalse(String(decoding: buffer.getBufferAsData(), as: UTF8.self).contains("TOOLS_INPUT_KEPT"))
    let queue = files.model.transfers, originalChange = queue.onChange
    defer { queue.onChange = originalChange }
    var switchedDuringTransfer = false
    queue.onChange = {
      originalChange?()
      if !switchedDuringTransfer, queue.jobs.first?.state == .running, queue.jobs.first?.progress != nil {
        switchedDuringTransfer = true
        pane.selectTool(.overview); tools.collapseButton.performClick(nil)
        XCTAssertFalse(pane.isToolsVisible); XCTAssertEqual(queue.jobs.first?.state, .running)
        main.toggleSessionTools(nil); pane.selectTool(.files)
      }
    }
    files.model.upload(source)
    try await wait { switchedDuringTransfer && queue.jobs.first?.state == .completed && !files.model.isBrowsingBusy }
    XCTAssertNil(files.model.error)
    XCTAssertEqual(files.model.directory, remoteDirectory)
    try await wait { files.model.entries.contains { $0.name == source.lastPathComponent } }
    XCTAssertEqual(files.model.entries.first { $0.name == source.lastPathComponent }?.size, 8 * 1024 * 1024)
    let job = try XCTUnwrap(queue.jobs.first), row = try XCTUnwrap(files.model.entries.firstIndex { $0.name == source.lastPathComponent })
    try await wait { files.table.numberOfRows > row }
    files.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    XCTAssertEqual(files.fileActionsMenu().items.map(\.title), ["新建目录…", "重命名…", "编辑…", "权限…", "删除…"])
    XCTAssertTrue(files.fileActionsMenu().items.allSatisfy(\.isEnabled))
    let monitorScroll = try XCTUnwrap(monitor.view.subviews.first as? NSScrollView)
    pane.selectTool(.overview); window.contentView?.layoutSubtreeIfNeeded()
    monitorScroll.contentView.scroll(to: .init(x: 0, y: 600)); monitorScroll.reflectScrolledClipView(monitorScroll.contentView)
    let scrollPosition = monitorScroll.contentView.bounds.origin
    let sizes = [NSSize(width: 1440, height: 860), .init(width: 480, height: 540)]
    for cycle in 0..<8 {
      let size = sizes[cycle % sizes.count]
      pane.selectTool(.files); tools.collapseButton.performClick(nil)
      XCTAssertEqual(window.firstResponder, terminal.terminalView)
      XCTAssertTrue(main.validateMenuItem(menu)); XCTAssertEqual(menu.state, .off)
      window.setContentSize(size); window.contentView?.layoutSubtreeIfNeeded()
      main.toggleSessionTools(nil); window.contentView?.layoutSubtreeIfNeeded()
      XCTAssertTrue(tools === pane.toolsView); XCTAssertTrue(monitor === pane.monitorVC)
      XCTAssertTrue(pane.children.contains { $0 === files }); XCTAssertEqual(files.model.directory, remoteDirectory)
      XCTAssertEqual(queue.jobs.first?.id, job.id); XCTAssertEqual(queue.jobs.first?.state, .completed)
      XCTAssertEqual(files.table.selectedRow, row); XCTAssertEqual(fileLocations.locationControl.selectedSegment, 0)
      XCTAssertTrue(terminal.terminalView.getTerminal() === buffer)
      XCTAssertEqual(pane.session.connectionVersion, version); XCTAssertEqual(pane.session.state, .connected)
      XCTAssertTrue(monitor.model.isOpen)
      let split = try XCTUnwrap(tools.enclosingScrollView?.superview as? TerminalMonitorView)
      XCTAssertTrue(split.bounds.contains(terminal.view.frame)); XCTAssertGreaterThan(terminal.view.frame.height, 0)
      XCTAssertFalse(tools.summaryCards[0].isHidden)
    }
    weak var collapsedContainer: TerminalMonitorView?
    autoreleasepool {
      collapsedContainer = tools.enclosingScrollView?.superview as? TerminalMonitorView
      XCTAssertNotNil(collapsedContainer)
      tools.collapseButton.performClick(nil)
      window.contentView?.layoutSubtreeIfNeeded()
    }
    // AppKit can retain a removed view until its pending display/layout pass finishes.
    try await wait({ collapsedContainer == nil }, timeout: 2)
    XCTAssertNil(collapsedContainer, "collapsed inspector containers must release their attachment constraints")
    main.toggleSessionTools(nil)
    window.setContentSize(.init(width: 1440, height: 860)); pane.selectTool(.overview); window.contentView?.layoutSubtreeIfNeeded()
    XCTAssertEqual(monitorScroll.contentView.bounds.origin.y, scrollPosition.y, accuracy: 1)
    pane.session.sendInput(Data("\r".utf8))
    try await wait { String(decoding: buffer.getBufferAsData(), as: UTF8.self).contains("TOOLS_INPUT_KEPT") }
    let filesReview = ProcessInfo.processInfo.environment["TERMES_TOOLS_FILES_REVIEW"] == "1"
    if ProcessInfo.processInfo.environment["TERMES_TOOLS_VISUAL_REVIEW"] == "1" || filesReview {
      try await wait { monitor.model.history.count >= 2 }
      let networkCard = monitor.metricCards[3]
      let networkTextHeight = networkCard.valueLabel.cell?.cellSize(forBounds: .init(x: 0, y: 0, width: networkCard.valueLabel.bounds.width, height: 1000)).height ?? 0
      XCTAssertGreaterThanOrEqual(networkCard.valueLabel.bounds.height, ceil(networkTextHeight), "both receive and send rates must fit")
      NSApp.activate(ignoringOtherApps: true)
      let modes: [(SessionTool, NSSize, String)] = filesReview ? [(.files, .init(width: 1440, height: 860), "files")] : [
        (.overview, .init(width: 1440, height: 860), "overview"), (.files, .init(width: 1440, height: 860), "files"), (.files, .init(width: 480, height: 740), "compact")]
      for (tool, size, name) in modes {
        try services.appearance.update(.init(theme: .dark, terminalTheme: .termiusDark, terminalFontSize: 14, terminalFontName: "SourceCodePro-Regular"))
        pane.selectTool(tool); window.setContentSize(size); window.contentView?.layoutSubtreeIfNeeded()
        if files.showsTransferQueue { files.transferDisclosure.performClick(nil) }
        monitorScroll.contentView.scroll(to: .zero); monitorScroll.reflectScrolledClipView(monitorScroll.contentView)
        window.title = "Termes 工具交互 · 本机测试服务器 · \(name)"
        await Task.yield(); print("TOOLS_REVIEW_\(name)=\(window.windowNumber)")
        if let directory = ProcessInfo.processInfo.environment["TERMES_TOOLS_RENDER_DIRECTORY"] {
          try render(window, name: name, directory: directory)
        } else { try await Task.sleep(for: .seconds(15)) }
      }
    }
    main.toggleServerMonitor(nil)
    XCTAssertNil(pane.monitorVC); XCTAssertFalse(monitor.model.isOpen)
    pane.toggleTools(); pane.toggleTools(); pane.selectTool(.files)
    XCTAssertTrue(pane.isToolsVisible); XCTAssertNil(pane.monitorVC, "reopening files must honor an explicit sampling stop")
    XCTAssertTrue(tools.summaryCards.allSatisfy { $0.valueLabel.stringValue == "—" })
    pane.close()
    XCTAssertNil(pane.toolsView); XCTAssertFalse(pane.isToolsVisible); XCTAssertFalse(monitor.model.isOpen)
    XCTAssertFalse(files.model.isConnected); XCTAssertNil(pane.session.onData)
  }
}
