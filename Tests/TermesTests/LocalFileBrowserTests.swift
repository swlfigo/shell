import AppKit
import XCTest
import TermesKit
import SSHCore
@testable import Termes

@MainActor
private final class FileDrag: NSObject, NSDraggingInfo {
  let draggingPasteboard: NSPasteboard
  var draggingDestinationWindow: NSWindow? { nil }
  var draggingSourceOperationMask: NSDragOperation = .copy
  var draggingLocation: NSPoint { .zero }
  var draggedImageLocation: NSPoint { .zero }
  nonisolated var draggedImage: NSImage? { nil }
  var draggingSource: Any? { nil }
  var draggingSequenceNumber: Int { 1 }
  var draggingFormation: NSDraggingFormation = .default
  var animatesToDestination = false
  var numberOfValidItemsForDrop = 0
  var springLoadingHighlight: NSSpringLoadingHighlight { .none }
  init(_ pasteboard: NSPasteboard) { draggingPasteboard = pasteboard }
  func slideDraggedImage(to screenPoint: NSPoint) {}
  nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
  func resetSpringLoading() {}
  func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?, classes: [AnyClass],
                              searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                              using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

private actor UploadFileSystem: SFTPFileSystem {
  var uploads: [String] = []
  var overwrites: [Bool] = []
  var items: [SFTPEntry] = []
  var failName: String?
  var pauseName: String?
  var paused = false
  var continuation: CheckedContinuation<Void, Never>?
  func setup(fail: String? = nil, pause: String? = nil) { failName = fail; pauseName = pause }
  func resume() { continuation?.resume(); continuation = nil }
  func canonicalPath(_ path: String) async throws -> String { "/remote" }
  func listDirectory(_ path: String) async throws -> [SFTPEntry] { items }
  func createDirectory(_ path: String) async throws {}
  func rename(_ source: String, to destination: String) async throws {}
  func remove(_ entry: SFTPEntry) async throws {}
  func upload(_ localURL: URL, to path: String, overwrite: Bool, progress: @escaping SFTPProgressHandler) async throws {
    uploads.append(path); overwrites.append(overwrite)
    if localURL.lastPathComponent == pauseName {
      paused = true; await withCheckedContinuation { continuation = $0 }
    }
    try Task.checkCancellation()
    if localURL.lastPathComponent == failName { throw SFTPError.alreadyExists(path) }
    let data = try Data(contentsOf: localURL)
    progress(.init(completed: UInt64(data.count), total: UInt64(data.count)))
    items.append(.init(path: path, name: localURL.lastPathComponent, kind: .file))
  }
  func download(_ path: String, to url: URL, overwrite: Bool, progress: @escaping SFTPProgressHandler) async throws {}
  func close() async {}
}

@MainActor
final class LocalFileBrowserTests: XCTestCase {
  private func fixture() throws -> (URL, [URL]) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("中文目录"), withIntermediateDirectories: true)
    let files = ["a.bin", "b.txt", ".hidden"].map { root.appendingPathComponent($0) }
    for file in files { try Data("\(file.lastPathComponent)\n".utf8).write(to: file) }
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return (root, files)
  }
  private func wait(_ predicate: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(10)
    while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(predicate())
  }

  func test_local_navigation_hidden_files_relative_paths_and_errors_preserve_directory() async throws {
    let (root, files) = try fixture()
    let model = LocalFileBrowserModel(initialDirectory: root)
    defer { model.shutdown() }
    model.refresh(); try await wait { !model.isBusy }
    XCTAssertEqual(model.entries.first?.name, "中文目录")
    XCTAssertEqual(model.entries.first?.kind, .directory)
    XCTAssertTrue(model.entries.contains { $0.name == ".hidden" && $0.kind == .file })
    XCTAssertEqual(model.entries.first { $0.name == files[0].lastPathComponent }?.size, 6)
    model.navigate(path: "中文目录"); try await wait { !model.isBusy }
    XCTAssertEqual(model.directory, root.appendingPathComponent("中文目录", isDirectory: true))
    XCTAssertTrue(model.entries.isEmpty)
    model.goUp(); try await wait { !model.isBusy }
    model.navigate(path: "missing"); try await wait { !model.isBusy }
    XCTAssertNotNil(model.error)
    XCTAssertEqual(model.directory?.path, root.path)
    XCTAssertEqual(model.entries.count, 4)
    model.navigate(files[0]); try await wait { !model.isBusy }
    XCTAssertNotNil(model.error)
    XCTAssertEqual(model.directory?.path, root.path)
  }

  func test_directories_are_allowed_but_symlinks_and_duplicate_basenames_are_rejected_before_upload() async throws {
    let (root, files) = try fixture()
    let directory = root.appendingPathComponent("中文目录")
    XCTAssertEqual(try UploadSelection.validated([files[0], directory]), [files[0], directory])
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: files[0])
    XCTAssertThrowsError(try UploadSelection.validated([link]))
    let duplicate = directory.appendingPathComponent(files[0].lastPathComponent)
    try Data().write(to: duplicate)
    XCTAssertThrowsError(try UploadSelection.validated([files[0], duplicate]))
    XCTAssertEqual(try UploadSelection.validated([files[0], files[0]]), [files[0]])
    let fs = UploadFileSystem(), model = FileBrowserModel { fs }
    model.refresh(); try await wait { !model.isBusy }
    try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("nested-link"), withDestinationURL: files[1])
    model.upload([files[0], directory]); try await wait { !model.isBusy }
    XCTAssertNotNil(model.error)
    let uploads = await fs.uploads
    XCTAssertTrue(uploads.isEmpty)
    model.shutdown()
  }

  func test_batch_uses_current_destination_and_only_overwrites_approved_names() async throws {
    let (_, files) = try fixture()
    let fs = UploadFileSystem(), model = FileBrowserModel { fs }
    defer { model.shutdown() }
    model.refresh(); try await wait { !model.isBusy }
    model.upload(Array(files.prefix(2)), overwriting: ["a.bin"])
    try await wait { !model.isBusy }
    let uploads = await fs.uploads, overwrites = await fs.overwrites
    XCTAssertEqual(uploads, ["/remote/a.bin", "/remote/b.txt"])
    XCTAssertEqual(overwrites, [true, false])
    XCTAssertEqual(model.entries.count, 2)
    XCTAssertNil(model.error)
    XCTAssertEqual(model.status, "上传完成：2 项")
  }

  func test_batch_stops_on_conflict_and_cancel_stops_remaining_files() async throws {
    let (_, files) = try fixture()
    let failing = UploadFileSystem()
    await failing.setup(fail: "b.txt")
    let model = FileBrowserModel { failing }
    model.refresh(); try await wait { !model.isBusy }
    model.upload(files); try await wait { !model.isBusy }
    let uploads = await failing.uploads
    XCTAssertEqual(uploads, ["/remote/a.bin", "/remote/b.txt"])
    XCTAssertTrue(model.error?.contains("已完成 1/3") == true)
    XCTAssertEqual(model.entries.map(\.name), ["a.bin"])
    model.shutdown()

    let paused = UploadFileSystem()
    await paused.setup(pause: "b.txt")
    let cancelling = FileBrowserModel { paused }
    cancelling.refresh(); try await wait { !cancelling.isBusy }
    cancelling.upload(files)
    let deadline = Date().addingTimeInterval(10)
    while !(await paused.paused), Date() < deadline { await Task.yield() }
    cancelling.cancel()
    await paused.resume()
    try await Task.sleep(for: .milliseconds(30))
    let cancelledUploads = await paused.uploads
    XCTAssertEqual(cancelledUploads, ["/remote/a.bin", "/remote/b.txt"])
    XCTAssertEqual(cancelling.status, "已取消")
    XCTAssertFalse(cancelling.isBusy)
    cancelling.shutdown()
  }

  func test_local_table_exports_finder_file_urls_and_remote_accepts_queued_drops_but_rejects_invalid() async throws {
    _ = NSApplication.shared
    let (root, files) = try fixture()
    let fs = UploadFileSystem(), model = FileBrowserModel { fs }
    let controller = FileBrowserViewController(model: model, localModel: LocalFileBrowserModel(initialDirectory: root))
    controller.start()
    defer { controller.shutdown() }
    try await wait { !model.isBusy && !controller.localBrowser.model.isBusy }
    await Task.yield()
    let local = controller.localBrowser
    let row = try XCTUnwrap(local.model.entries.firstIndex { $0.name == files[0].lastPathComponent })
    let draggedURL = local.model.entries[row].url
    let writer = try XCTUnwrap(local.tableView(local.table, pasteboardWriterForRow: row))
    let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
    defer { pasteboard.releaseGlobally() }
    pasteboard.writeObjects([writer])
    let received = try XCTUnwrap(controller.droppedFiles(from: pasteboard))
    XCTAssertEqual(received.map(\.lastPathComponent), [draggedURL.lastPathComponent])
    XCTAssertEqual(try Data(contentsOf: XCTUnwrap(received.first)), try Data(contentsOf: draggedURL))
    XCTAssertEqual(try Data(contentsOf: draggedURL), try Data(contentsOf: files[0]))
    controller.requestUpload(try XCTUnwrap(controller.droppedFiles(from: pasteboard)))
    XCTAssertNotNil(controller.droppedFiles(from: pasteboard), "transfers allow another queued drop")
    try await wait { !model.isBusy }
    let uploads = await fs.uploads
    XCTAssertEqual(uploads, ["/remote/a.bin"])
    pasteboard.clearContents()
    pasteboard.writeObjects([root as NSURL])
    XCTAssertEqual(controller.droppedFiles(from: pasteboard)?.map(\.path), [root.path])
    let directoryRow = try XCTUnwrap(local.model.entries.firstIndex { $0.kind == .directory })
    XCTAssertNotNil(local.tableView(local.table, pasteboardWriterForRow: directoryRow))
    pasteboard.clearContents()
    pasteboard.writeObjects([NSURL(string: "https://example.com/file")!])
    XCTAssertNil(controller.droppedFiles(from: pasteboard))
    model.setConnected(false)
    pasteboard.clearContents(); pasteboard.writeObjects([files[1] as NSURL])
    XCTAssertNil(controller.droppedFiles(from: pasteboard))
  }

  func test_drop_callbacks_upload_multiple_files_to_real_empty_sftp_directory() async throws {
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    let store = KnownHostsStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let client = try await SFTPClient.connect(config: .init(hostname: server.host, port: server.port, username: server.username,
      auth: .password(server.password)), knownHosts: store, confirmUnknownHostKey: { _, _, _ in true })
    addTeardownBlock { await client.close() }
    let home = try await client.canonicalPath(".")
    let destination = try RemotePath.child("drag-\(UUID())", in: home)
    try await client.createDirectory(destination)
    let (root, files) = try fixture()
    let model = FileBrowserModel {
      try await SFTPClient.connect(config: .init(hostname: server.host, port: server.port, username: server.username,
        auth: .password(server.password)), knownHosts: store, confirmUnknownHostKey: { _, _, _ in false })
    }
    let controller = FileBrowserViewController(model: model, localModel: LocalFileBrowserModel(initialDirectory: root))
    _ = controller.view
    defer { controller.shutdown() }
    model.navigate(destination); try await wait { !model.isBusy }
    XCTAssertTrue(model.entries.isEmpty)
    let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
    defer { pasteboard.releaseGlobally() }
    pasteboard.writeObjects(Array(files.prefix(2)).map { $0 as NSURL })
    let drag = FileDrag(pasteboard)
    XCTAssertEqual(controller.tableView(controller.table, validateDrop: drag, proposedRow: 0, proposedDropOperation: .above), .copy)
    let scroll = try XCTUnwrap(controller.table.enclosingScrollView as? FileUploadDropScrollView)
    XCTAssertEqual(scroll.draggingEntered(drag), .copy)
    XCTAssertTrue(scroll.prepareForDragOperation(drag))
    XCTAssertTrue(scroll.performDragOperation(drag))
    XCTAssertTrue(scroll.prepareForDragOperation(drag), "transfer queue still accepts drops")
    try await wait { !model.isBusy }
    XCTAssertNil(model.error)
    XCTAssertEqual(Set(model.entries.map(\.name)), Set(files.prefix(2).map(\.lastPathComponent)))
    for file in files.prefix(2) {
      let output = root.appendingPathComponent("download-" + file.lastPathComponent)
      try await client.download(try RemotePath.child(file.lastPathComponent, in: destination), to: output)
      XCTAssertEqual(try Data(contentsOf: output), try Data(contentsOf: file))
    }
    for entry in model.entries { try await client.remove(entry) }
    let dirs = try await client.listDirectory(home)
    try await client.remove(XCTUnwrap(dirs.first { $0.path == destination }))
  }

  func test_folder_drop_and_model_download_preserve_recursive_contents_and_enable_download() async throws {
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    let store = KnownHostsStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let client = try await SFTPClient.connect(config: .init(hostname: server.host, port: server.port, username: server.username,
      auth: .password(server.password)), knownHosts: store, confirmUnknownHostKey: { _, _, _ in true })
    addTeardownBlock { await client.close() }
    let home = try await client.canonicalPath(".")
    let destination = try RemotePath.child("folder-drag-\(UUID())", in: home)
    try await client.createDirectory(destination)
    let (root, _) = try fixture(), folder = root.appendingPathComponent("中文目录")
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("nested/empty"), withIntermediateDirectories: true)
    try Data([0, 255, 7]).write(to: folder.appendingPathComponent("nested/data.bin"))
    let model = FileBrowserModel {
      try await SFTPClient.connect(config: .init(hostname: server.host, port: server.port, username: server.username,
        auth: .password(server.password)), knownHosts: store, confirmUnknownHostKey: { _, _, _ in false })
    }
    let controller = FileBrowserViewController(model: model, localModel: LocalFileBrowserModel(initialDirectory: root))
    _ = controller.view
    defer { controller.shutdown() }
    controller.localBrowser.start()
    model.navigate(destination); try await wait { !model.isBusy && !controller.localBrowser.model.isBusy }
    let pasteboard = NSPasteboard(name: .init(UUID().uuidString))
    defer { pasteboard.releaseGlobally() }
    pasteboard.writeObjects([folder as NSURL])
    let drag = FileDrag(pasteboard)
    let scroll = try XCTUnwrap(controller.table.enclosingScrollView as? FileUploadDropScrollView)
    XCTAssertEqual(scroll.draggingEntered(drag), .copy)
    XCTAssertTrue(scroll.performDragOperation(drag))
    try await wait { !model.isBusy }
    XCTAssertNil(model.error)
    let entry = try XCTUnwrap(model.entries.first { $0.name == "中文目录" })
    XCTAssertEqual(entry.kind, .directory)
    controller.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    let buttons = controller.view.subviews.flatMap { descendants($0) }.compactMap { $0 as? NSButton }
    let download = try XCTUnwrap(buttons.first { $0.title == "下载…" })
    try await wait { download.isEnabled }
    let output = root.appendingPathComponent("downloaded")
    model.download(entry, to: output)
    try await wait { !model.isBusy }
    XCTAssertNil(model.error)
    XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("nested/data.bin")), Data([0, 255, 7]))
    XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("nested/empty").path))
  }

  private func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(descendants)
  }
}
