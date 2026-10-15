import AppKit
import XCTest
import TermesKit
import SSHCore
@testable import Termes

private actor EditingFileSystem: SFTPFileEditingSystem {
  var data = Data("original\n".utf8)
  var mode: UInt32 = 0o640
  var closed = 0
  var pauseRead = false, pauseWrite = false
  var readEntered = false, writeEntered = false
  var readGate: CheckedContinuation<Void, Never>?, writeGate: CheckedContinuation<Void, Never>?
  func configure(data: Data? = nil, mode: UInt32? = nil, pauseRead: Bool = false, pauseWrite: Bool = false) {
    if let data { self.data = data }; if let mode { self.mode = mode }
    self.pauseRead = pauseRead; self.pauseWrite = pauseWrite
  }
  func releaseRead() { readGate?.resume(); readGate = nil }
  func releaseWrite() { writeGate?.resume(); writeGate = nil }
  func entry(_ path: String = "/remote/file") -> SFTPEntry {
    .init(path: path, name: RemotePath.name(path), kind: .file, size: UInt64(data.count),
      modifiedAt: Date(timeIntervalSince1970: 10), permissions: mode, ownerID: 1000, groupID: 1000)
  }
  func canonicalPath(_ path: String) async throws -> String { "/remote" }
  func listDirectory(_ path: String) async throws -> [SFTPEntry] { [entry()] }
  func createDirectory(_ path: String) async throws {}
  func rename(_ source: String, to destination: String) async throws {}
  func remove(_ entry: SFTPEntry) async throws {}
  func upload(_ localURL: URL, to remotePath: String, overwrite: Bool, progress: @escaping SFTPProgressHandler) async throws {}
  func download(_ remotePath: String, to localURL: URL, overwrite: Bool, progress: @escaping SFTPProgressHandler) async throws {}
  func close() async { closed += 1 }
  func fileAttributes(_ path: String) async throws -> SFTPEntry { entry(path) }
  func setPermissions(_ path: String, permissions: UInt32, expected: SFTPEntry) async throws -> SFTPEntry {
    guard entry(path) == expected else { throw SFTPEditError.conflict(path) }; mode = permissions; return entry(path)
  }
  func readFile(_ path: String, maximumBytes: Int) async throws -> SFTPFileSnapshot {
    guard data.count <= maximumBytes else { throw SFTPEditError.tooLarge(maximumBytes) }
    let snapshot = SFTPFileSnapshot(entry: entry(path), data: data)
    if pauseRead { pauseRead = false; readEntered = true; await withCheckedContinuation { readGate = $0 } }
    // Intentionally return a late result even after cancellation.
    return snapshot
  }
  func writeFile(_ data: Data, to path: String, expected: SFTPFileSnapshot,
                 progress: @escaping SFTPProgressHandler) async throws -> SFTPFileSnapshot {
    if pauseWrite { pauseWrite = false; writeEntered = true; await withCheckedContinuation { writeGate = $0 } }
    try Task.checkCancellation()
    guard SFTPFileSnapshot(entry: entry(path), data: self.data) == expected else { throw SFTPEditError.conflict(path) }
    self.data = data; return .init(entry: entry(path), data: data)
  }
}

@MainActor
final class RemoteFileEditingTests: XCTestCase {
  private func wait(_ predicate: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(10)
    while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(predicate())
  }
  private func waitRead(_ fs: EditingFileSystem, write: Bool = false) async throws {
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
      if write ? await fs.writeEntered : await fs.readEntered { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("operation did not enter")
  }
  private func children(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(children) }

  func test_utf8_bom_newline_roundtrips_and_binary_rejection() throws {
    for value in ["中文😀\nnext\n", "中文\r\nnext\r\n", "中文\rnext\r", "one\r\ntwo\nthree\r", ""] {
      for bom in [Data(), Data([0xEF, 0xBB, 0xBF])] {
        let bytes = bom + Data(value.utf8)
        let document = try RemoteTextDocument(data: bytes)
        XCTAssertEqual(document.encode(document.text), bytes)
      }
    }
    let crlf = try RemoteTextDocument(data: Data("old\r\n".utf8))
    XCTAssertEqual(crlf.text, "old\n"); XCTAssertEqual(crlf.encode("new\nline\n"), Data("new\r\nline\r\n".utf8))
    for data in [Data([0]), Data([0xFF]), Data([0xC3, 0x28])] { XCTAssertThrowsError(try RemoteTextDocument(data: data)) }
  }

  func test_saved_baseline_tracks_submitted_text_and_keeps_edits_made_during_save() async throws {
    let fs = EditingFileSystem(), original = Data([0xEF, 0xBB, 0xBF]) + Data("original\r\n".utf8)
    await fs.configure(data: original)
    let model = RemoteFileEditorModel(path: "/remote/file") { fs }
    model.load(); try await wait { model.isLoaded && !model.isBusy }
    XCTAssertEqual(model.text, "original\n"); XCTAssertEqual(model.format, "UTF-8 BOM · CRLF"); XCTAssertFalse(model.isDirty)
    model.text = "submitted\n"; await fs.configure(pauseWrite: true)
    model.save(); try await waitRead(fs, write: true)
    model.text = "new draft\n"; await fs.releaseWrite()
    try await wait { !model.isBusy }
    XCTAssertTrue(model.isDirty); XCTAssertEqual(model.text, "new draft\n")
    let firstSaved = await fs.data
    XCTAssertEqual(firstSaved, Data([0xEF, 0xBB, 0xBF]) + Data("submitted\r\n".utf8))
    model.save(); try await wait { !model.isBusy }
    XCTAssertFalse(model.isDirty); XCTAssertNil(model.error)
    XCTAssertEqual(try model.exportData(), Data([0xEF, 0xBB, 0xBF]) + Data("new draft\r\n".utf8))
  }

  func test_conflict_preserves_draft_and_confirmed_overwrite_reads_latest_revision_and_metadata() async throws {
    let fs = EditingFileSystem(), model = RemoteFileEditorModel(path: "/remote/file") { fs }
    model.load(); try await wait { !model.isBusy }
    model.text = "local draft\n"
    await fs.configure(data: Data("modified\n".utf8), mode: 0o700)
    model.save(); try await wait { !model.isBusy }
    XCTAssertTrue(model.hasConflict); XCTAssertTrue(model.isDirty); XCTAssertEqual(model.text, "local draft\n")
    let remote = await fs.data; XCTAssertEqual(remote, Data("modified\n".utf8))
    model.save(overwriteChanged: true); try await wait { !model.isBusy }
    XCTAssertFalse(model.hasConflict); XCTAssertFalse(model.isDirty)
    let saved = await fs.data, mode = await fs.mode
    XCTAssertEqual(saved, Data("local draft\n".utf8)); XCTAssertEqual(mode, 0o700)
  }

  func test_cancelled_late_load_cannot_replace_newer_text_and_bad_reload_preserves_draft() async throws {
    let fs = EditingFileSystem(), model = RemoteFileEditorModel(path: "/remote/file") { fs }
    model.load(); try await wait { !model.isBusy }
    model.text = "draft"
    await fs.configure(pauseRead: true)
    model.load(); try await waitRead(fs)
    model.cancel()
    await fs.configure(data: Data("fresh".utf8))
    model.load(); try await wait { !model.isBusy }
    XCTAssertEqual(model.text, "fresh")
    await fs.releaseRead(); try await Task.sleep(for: .milliseconds(30))
    XCTAssertEqual(model.text, "fresh")
    model.text = "keep draft"; await fs.configure(data: Data([0xFF]))
    model.load(); try await wait { !model.isBusy }
    XCTAssertEqual(model.text, "keep draft"); XCTAssertTrue(model.isDirty); XCTAssertNotNil(model.error)
    XCTAssertEqual(try model.exportData(), Data("keep draft".utf8))
    model.text = "binary\0paste"; model.save()
    XCTAssertNotNil(model.error); XCTAssertFalse(model.isBusy); XCTAssertTrue(model.isDirty)
    let raw = await fs.data; XCTAssertEqual(raw, Data([0xFF]))
    let closed = await fs.closed; XCTAssertGreaterThanOrEqual(closed, 4)
  }

  func test_permission_form_validation_bits_conflict_and_reload() async throws {
    let fs = EditingFileSystem(), entry = await fs.entry()
    let model = RemotePermissionsModel(entry: entry) { fs }
    model.load(); try await wait { !model.isBusy }
    XCTAssertEqual(model.octal, "0640")
    model.octal = "0888"; XCTAssertFalse(model.canApply); XCTAssertNotNil(model.validationError)
    model.octal = "0640"; model.setBit(0o100, enabled: true); model.setBit(0o4000, enabled: true)
    XCTAssertEqual(model.octal, "4740")
    await fs.configure(mode: 0o600)
    model.apply(); try await wait { !model.isBusy }
    XCTAssertNotNil(model.error)
    let unchanged = await fs.mode; XCTAssertEqual(unchanged, 0o600)
    model.load(); try await wait { !model.isBusy }
    model.setBit(0o004, enabled: true)
    var success = false
    model.apply { success = $0 }; try await wait { !model.isBusy }
    XCTAssertTrue(success); XCTAssertEqual(model.entry?.permissions, 0o604)
  }

  func test_appkit_editor_save_undo_and_dirty_close_confirmation_keeps_draft_on_cancel() async throws {
    _ = NSApplication.shared
    let previousDrafts = RemoteFileEditorWindowController.unsavedCount
    let fs = EditingFileSystem(), model = RemoteFileEditorModel(path: "/remote/file") { fs }
    let window = RemoteFileEditorWindowController(model: model, serverName: "生产服务器")
    defer { window.window?.close() }
    window.showWindow(nil)
    try await wait { model.isLoaded && !model.isBusy && window.editor.textView.string == model.text }
    XCTAssertTrue(window.window?.title.contains("生产服务器") == true)
    let text = window.editor.textView
    text.insertText("modified\n", replacementRange: NSRange(location: 0, length: (text.string as NSString).length))
    try await wait { model.text == "modified\n" && model.isDirty }
    XCTAssertEqual(RemoteFileEditorWindowController.unsavedCount, previousDrafts + 1)
    let save = try XCTUnwrap(children(window.editor.view).compactMap { $0 as? NSButton }.first { $0.title == "保存到远端" })
    try await wait { save.isEnabled }; save.performClick(nil)
    try await wait { !model.isBusy && !model.isDirty }
    let saved = await fs.data; XCTAssertEqual(saved, Data("modified\n".utf8))
    XCTAssertEqual(RemoteFileEditorWindowController.unsavedCount, previousDrafts)
    XCTAssertNotNil(text.undoManager)
    XCTAssertTrue(text.undoManager?.canUndo == true)
    window.undoText(nil)
    try await wait { model.isDirty }
    XCTAssertEqual(model.text, "original\n")
    window.redoText(nil)
    try await wait { !model.isDirty && model.text == "modified\n" }
    window.undoText(nil)
    try await wait { model.isDirty && model.text == "original\n" }
    let native = try XCTUnwrap(window.window)
    XCTAssertFalse(window.windowShouldClose(native))
    let sheet = try XCTUnwrap(native.attachedSheet)
    native.endSheet(sheet, returnCode: .alertThirdButtonReturn)
    try await wait { native.attachedSheet == nil }
    XCTAssertTrue(native.isVisible); XCTAssertTrue(model.isDirty)
    await fs.configure(pauseWrite: true)
    XCTAssertFalse(window.windowShouldClose(native))
    native.endSheet(try XCTUnwrap(native.attachedSheet), returnCode: .alertFirstButtonReturn)
    try await waitRead(fs, write: true)
    model.text = "newer draft\n"; await fs.releaseWrite()
    try await wait { !model.isBusy }
    XCTAssertTrue(native.isVisible); XCTAssertTrue(model.isDirty)
    XCTAssertEqual(model.text, "newer draft\n")
    XCTAssertFalse(window.windowShouldClose(native))
    native.endSheet(try XCTUnwrap(native.attachedSheet), returnCode: .alertSecondButtonReturn)
    try await wait { !native.isVisible }
    XCTAssertEqual(RemoteFileEditorWindowController.unsavedCount, previousDrafts)
  }

  func test_real_file_panel_permission_and_editor_entries_save_and_keep_draft_after_panel_closes() async throws {
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let config = ConnectionConfig(hostname: server.host, port: server.port, username: server.username, auth: .password(server.password))
    let store = KnownHostsStore(fileURL: root.appendingPathComponent("hosts"))
    let inspector = try await SFTPClient.connect(config: config, knownHosts: store, confirmUnknownHostKey: { _, _, _ in true })
    addTeardownBlock { await inspector.close() }
    let home = try await inspector.canonicalPath("."), folder = home + "/ui-edit-\(UUID())"
    try await inspector.createDirectory(folder)
    let source = root.appendingPathComponent("config.txt")
    let initial = Data([0xEF, 0xBB, 0xBF]) + Data("中文\r\n".utf8)
    try initial.write(to: source); try await inspector.upload(source, to: folder + "/config.txt")
    let browser = FileBrowserModel { try await SFTPClient.connect(config: config, knownHosts: store, confirmUnknownHostKey: { _, _, _ in false }) }
    let panel = FileBrowserViewController(model: browser, localModel: LocalFileBrowserModel(initialDirectory: root), serverName: "测试服务器")
    let native = NSWindow(contentViewController: panel); native.isReleasedWhenClosed = false
    native.setContentSize(NSSize(width: 800, height: 650)); native.makeKeyAndOrderFront(nil)
    defer {
      for window in NSApp.windows where (window.contentViewController as? RemoteFileEditorViewController)?.model.path == folder + "/config.txt" { window.close() }
      panel.shutdown(); native.close()
    }
    browser.navigate(folder); try await wait { !browser.isBusy && panel.table.numberOfRows == 1 }
    panel.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    let buttons = children(panel.view).compactMap { $0 as? NSButton }
    let permissions = try XCTUnwrap(buttons.first { $0.title == "权限…" })
    try await wait { permissions.isEnabled }; permissions.performClick(nil)
    try await wait { panel.presentedViewControllers?.first is RemotePermissionsViewController }
    let sheet = try XCTUnwrap(panel.presentedViewControllers?.first as? RemotePermissionsViewController)
    try await wait { sheet.model.entry != nil && !sheet.model.isBusy }
    sheet.modeField.stringValue = "0750"; sheet.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    let apply = try XCTUnwrap(children(sheet.view).compactMap { $0 as? NSButton }.first { $0.title == "应用权限" })
    try await wait { apply.isEnabled }; apply.performClick(nil)
    try await wait { native.attachedSheet == nil && !browser.isBusy && browser.entries.first?.permissions == 0o750 }
    let edit = try XCTUnwrap(buttons.first { $0.title == "编辑…" })
    try await wait { edit.isEnabled }; edit.performClick(nil)
    try await wait { NSApp.windows.contains { ($0.contentViewController as? RemoteFileEditorViewController)?.model.path == folder + "/config.txt" } }
    let editorWindow = try XCTUnwrap(NSApp.windows.first { ($0.contentViewController as? RemoteFileEditorViewController)?.model.path == folder + "/config.txt" })
    let editor = try XCTUnwrap(editorWindow.contentViewController as? RemoteFileEditorViewController)
    try await wait { editor.model.isLoaded && !editor.model.isBusy }
    editor.model.text = "新配置\n"
    editor.saveFile(); try await wait { !editor.model.isBusy && !editor.model.isDirty }
    let saved = try await inspector.readFile(folder + "/config.txt")
    XCTAssertEqual(saved.data, Data([0xEF, 0xBB, 0xBF]) + Data("新配置\r\n".utf8)); XCTAssertEqual(saved.entry.permissions, 0o750)
    editor.model.text = "保留草稿\n"; panel.shutdown()
    XCTAssertTrue(editorWindow.isVisible); XCTAssertTrue(editor.model.isDirty)
    XCTAssertEqual(try editor.model.exportData(), Data([0xEF, 0xBB, 0xBF]) + Data("保留草稿\r\n".utf8))
  }
}
