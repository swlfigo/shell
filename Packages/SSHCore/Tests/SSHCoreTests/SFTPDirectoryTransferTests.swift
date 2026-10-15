import XCTest
@testable import SSHCore

private actor TreeFileSystem: SFTPFileSystem {
  struct Node: Sendable { let kind: SFTPEntry.Kind; var data = Data() }
  var nodes: [String: Node] = ["/remote": Node(kind: .directory)]
  var writes: [String] = []
  var malformed: [SFTPEntry]?
  var failFile: String?
  var lateConflict = false
  func configure(malformed: [SFTPEntry]? = nil, failFile: String? = nil, lateConflict: Bool = false) {
    self.malformed = malformed; self.failFile = failFile; self.lateConflict = lateConflict
  }
  func put(_ path: String, kind: SFTPEntry.Kind, data: Data = Data()) { nodes[path] = Node(kind: kind, data: data) }
  func canonicalPath(_ path: String) async throws -> String { path }
  func listDirectory(_ path: String) async throws -> [SFTPEntry] {
    if path == "/remote/tree", let malformed { return malformed }
    return nodes.keys.filter { RemotePath.parent($0) == path }.sorted().map {
      let node = nodes[$0]!
      return .init(path: $0, name: RemotePath.name($0), kind: node.kind,
                   size: node.kind == .file ? UInt64(node.data.count) : nil)
    }
  }
  func createDirectory(_ path: String) async throws {
    try Task.checkCancellation()
    guard nodes[path] == nil else { throw SFTPError.alreadyExists(path) }
    nodes[path] = Node(kind: .directory); writes.append(path)
  }
  func rename(_ source: String, to destination: String) async throws {
    try Task.checkCancellation()
    if lateConflict { nodes[destination] = Node(kind: .directory) }
    guard nodes[destination] == nil else { throw SFTPError.alreadyExists(destination) }
    let snapshot = nodes
    for (path, node) in snapshot where path == source || path.hasPrefix(source + "/") {
      nodes[destination + path.dropFirst(source.count)] = node; nodes[path] = nil
    }
  }
  func remove(_ entry: SFTPEntry) async throws {
    try Task.checkCancellation()
    if entry.kind == .directory, nodes.keys.contains(where: { RemotePath.parent($0) == entry.path }) {
      throw SFTPError.operation("nonempty", code: 4)
    }
    nodes[entry.path] = nil
  }
  func upload(_ url: URL, to path: String, overwrite: Bool, progress: @escaping SFTPProgressHandler) async throws {
    try Task.checkCancellation()
    if url.lastPathComponent == failFile { throw SFTPError.operation("injected failure", code: 4) }
    if !overwrite, nodes[path] != nil { throw SFTPError.alreadyExists(path) }
    let data = try Data(contentsOf: url)
    progress(.init(completed: UInt64(data.count), total: UInt64(data.count)))
    try Task.checkCancellation()
    nodes[path] = Node(kind: .file, data: data); writes.append(path)
  }
  func download(_ path: String, to url: URL, overwrite: Bool, progress: @escaping SFTPProgressHandler) async throws {
    try Task.checkCancellation()
    if RemotePath.name(path) == failFile { throw SFTPError.operation("injected failure", code: 4) }
    guard let node = nodes[path], node.kind == .file else { throw SFTPError.unsupportedFile }
    try node.data.write(to: url, options: .withoutOverwriting)
    progress(.init(completed: UInt64(node.data.count), total: UInt64(node.data.count)))
    try Task.checkCancellation()
  }
  func close() async {}
  func paths() -> Set<String> { Set(nodes.keys) }
}

private final class DirectoryTransferProbe: @unchecked Sendable {
  private let lock = NSLock()
  private let minimum: UInt64
  private var task: Task<Void, Error>?
  private var values: [SFTPProgress] = []
  init(minimum: UInt64 = 1) { self.minimum = minimum }
  func set(_ task: Task<Void, Error>) { lock.withLock { self.task = task } }
  func record(_ value: SFTPProgress) { lock.withLock { values.append(value) } }
  func cancelAfterChunk(_ value: SFTPProgress) {
    lock.withLock { if value.completed >= minimum { task?.cancel() } }
  }
  var recorded: [SFTPProgress] { lock.withLock { values } }
}

final class SFTPDirectoryTransferTests: XCTestCase {
  private func temporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }
  private func fixture() throws -> URL {
    let root = try temporaryDirectory().appendingPathComponent("tree", isDirectory: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("中文/空目录"), withIntermediateDirectories: true)
    try Data([0, 1, 2, 255]).write(to: root.appendingPathComponent("中文/file.bin"))
    try Data("hidden".utf8).write(to: root.appendingPathComponent(".hidden"))
    try Data().write(to: root.appendingPathComponent("empty"))
    return root
  }
  private func rootEntry(_ path: String = "/remote/tree") -> SFTPEntry {
    .init(path: path, name: RemotePath.name(path), kind: .directory)
  }

  func test_recursive_tree_roundtrip_preserves_binary_hidden_empty_files_and_directories() async throws {
    let source = try fixture(), fs = TreeFileSystem()
    let plan = try XCTUnwrap(SFTPDirectoryTransfer.prepareUploads([source]).first)
    let uploadProbe = DirectoryTransferProbe()
    try await SFTPDirectoryTransfer.upload(plan, to: "/remote/tree", using: fs, progress: uploadProbe.record)
    let paths = await fs.paths()
    XCTAssertEqual(paths, ["/remote", "/remote/tree", "/remote/tree/中文", "/remote/tree/中文/空目录",
                           "/remote/tree/中文/file.bin", "/remote/tree/.hidden", "/remote/tree/empty"])
    let destination = try temporaryDirectory().appendingPathComponent("result")
    let downloadProbe = DirectoryTransferProbe()
    try await SFTPDirectoryTransfer.download(rootEntry(), to: destination, using: fs, progress: downloadProbe.record)
    for relative in ["中文/file.bin", ".hidden", "empty"] {
      XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(relative)), try Data(contentsOf: source.appendingPathComponent(relative)))
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("中文/空目录").path))
    for probe in [uploadProbe, downloadProbe] {
      XCTAssertEqual(probe.recorded.last, SFTPProgress(completed: 10, total: 10))
      XCTAssertTrue(zip(probe.recorded, probe.recorded.dropFirst()).allSatisfy { $0.completed <= $1.completed })
    }
  }

  func test_upload_preflight_rejects_nested_links_duplicates_and_changed_source() async throws {
    let source = try fixture(), fs = TreeFileSystem()
    let outside = try temporaryDirectory().appendingPathComponent("secret")
    try Data("must not upload".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("linked"), withDestinationURL: outside)
    XCTAssertThrowsError(try SFTPDirectoryTransfer.prepareUploads([outside, source]))
    try FileManager.default.removeItem(at: source.appendingPathComponent("linked"))
    XCTAssertEqual(try SFTPDirectoryTransfer.prepareUploads([source, source]).count, 1)
    let other = try temporaryDirectory().appendingPathComponent("tree")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
    XCTAssertThrowsError(try SFTPDirectoryTransfer.prepareUploads([source, other]))
    let plan = try XCTUnwrap(SFTPDirectoryTransfer.prepareUploads([source]).first)
    try Data("changed".utf8).write(to: source.appendingPathComponent(".hidden"))
    do { try await SFTPDirectoryTransfer.upload(plan, to: "/remote/tree", using: fs); XCTFail("must fail") }
    catch let error as SFTPDirectoryError { XCTAssertEqual(error, .sourceChanged(source.resolvingSymlinksInPath().appendingPathComponent(".hidden").path)) }
    let paths = await fs.paths()
    XCTAssertEqual(paths, ["/remote"])
  }

  func test_existing_and_late_targets_survive_upload_or_download() async throws {
    let source = try fixture(), fs = TreeFileSystem()
    let plan = try XCTUnwrap(SFTPDirectoryTransfer.prepareUploads([source]).first)
    await fs.put("/remote/tree", kind: .directory)
    await fs.put("/remote/tree/original", kind: .file, data: Data("original".utf8))
    do { try await SFTPDirectoryTransfer.upload(plan, to: "/remote/tree", using: fs, overwrite: true); XCTFail("no folder overwrite") }
    catch let error as SFTPError { XCTAssertEqual(error, .alreadyExists("/remote/tree")) }
    let paths = await fs.paths()
    XCTAssertEqual(paths, ["/remote", "/remote/tree", "/remote/tree/original"])
    let late = TreeFileSystem()
    await late.configure(lateConflict: true)
    do { try await SFTPDirectoryTransfer.upload(plan, to: "/remote/tree", using: late); XCTFail("late conflict") }
    catch let error as SFTPError { XCTAssertEqual(error, .alreadyExists("/remote/tree")) }
    let latePaths = await late.paths()
    XCTAssertEqual(latePaths, ["/remote", "/remote/tree"])
    let destination = try temporaryDirectory().appendingPathComponent("tree")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    try Data("original".utf8).write(to: destination.appendingPathComponent("original"))
    do { try await SFTPDirectoryTransfer.download(rootEntry(), to: destination, using: fs); XCTFail("no folder overwrite") }
    catch let error as SFTPError { XCTAssertEqual(error, .alreadyExists(destination.resolvingSymlinksInPath().path)) }
    XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("original")), Data("original".utf8))
    let lateLocal = try temporaryDirectory().appendingPathComponent("late")
    do {
      try await SFTPDirectoryTransfer.download(rootEntry(), to: lateLocal, using: fs) { value in
        if value.completed > 0 {
          try? FileManager.default.createDirectory(at: lateLocal, withIntermediateDirectories: false)
          try? Data("late original".utf8).write(to: lateLocal.appendingPathComponent("original"))
        }
      }
      XCTFail("late local collision must survive")
    } catch let error as SFTPError { XCTAssertEqual(error, .alreadyExists(lateLocal.resolvingSymlinksInPath().path)) }
    XCTAssertEqual(try Data(contentsOf: lateLocal.appendingPathComponent("original")), Data("late original".utf8))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: lateLocal.deletingLastPathComponent().path), ["late"])
  }

  func test_failed_and_cancelled_transfers_remove_only_their_staging_trees() async throws {
    let source = try fixture(), fs = TreeFileSystem()
    let plan = try XCTUnwrap(SFTPDirectoryTransfer.prepareUploads([source]).first)
    await fs.configure(failFile: "file.bin")
    do { try await SFTPDirectoryTransfer.upload(plan, to: "/remote/tree", using: fs); XCTFail("injected failure") } catch {}
    let paths = await fs.paths()
    XCTAssertEqual(paths, ["/remote"])
    await fs.configure()
    let probe = DirectoryTransferProbe()
    let task = Task { try await SFTPDirectoryTransfer.upload(plan, to: "/remote/tree", using: fs, progress: probe.cancelAfterChunk) }
    probe.set(task)
    do { try await task.value; XCTFail("must cancel") } catch is CancellationError {}
    let cancelledPaths = await fs.paths()
    XCTAssertEqual(cancelledPaths, ["/remote"])
    try await SFTPDirectoryTransfer.upload(plan, to: "/remote/tree", using: fs)
    await fs.configure(failFile: "file.bin")
    let parent = try temporaryDirectory(), destination = parent.appendingPathComponent("tree")
    do { try await SFTPDirectoryTransfer.download(rootEntry(), to: destination, using: fs); XCTFail("must fail") } catch {}
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
  }

  func test_remote_links_paths_and_duplicate_entries_cannot_escape_the_download_root() async throws {
    let fs = TreeFileSystem(), parent = try temporaryDirectory(), destination = parent.appendingPathComponent("tree")
    await fs.put("/remote/tree", kind: .directory)
    let valid = SFTPEntry(path: "/remote/tree/file", name: "file", kind: .file, size: 0)
    for entries in [
      [SFTPEntry(path: "/remote/tree/link", name: "link", kind: .symbolicLink)],
      [SFTPEntry(path: "/remote/tree/../escape", name: "../escape", kind: .file)],
      [SFTPEntry(path: "/outside", name: "file", kind: .file)],
      [valid, valid],
    ] {
      await fs.configure(malformed: entries)
      do { try await SFTPDirectoryTransfer.download(rootEntry(), to: destination, using: fs); XCTFail("must reject") } catch {}
      XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
    }
  }

  func test_real_openssh_recursive_roundtrip_and_empty_directory() async throws {
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    let store = KnownHostsStore(fileURL: try temporaryDirectory().appendingPathComponent("known-hosts"))
    let client = try await SFTPClient.connect(config: .init(hostname: server.host, port: server.port, username: server.username,
      auth: .password(server.password)), knownHosts: store, confirmUnknownHostKey: { _, _, _ in true })
    addTeardownBlock { await client.close() }
    let home = try await client.canonicalPath("."), source = try fixture()
    let remote = try RemotePath.child("recursive-\(UUID())", in: home)
    let plan = try XCTUnwrap(SFTPDirectoryTransfer.prepareUploads([source]).first)
    try await SFTPDirectoryTransfer.upload(plan, to: remote, using: client)
    let destination = try temporaryDirectory().appendingPathComponent("tree")
    try await SFTPDirectoryTransfer.download(rootEntry(remote), to: destination, using: client)
    XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("中文/file.bin")), Data([0, 1, 2, 255]))
    XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(".hidden")), Data("hidden".utf8))
    XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("empty")), Data())
    XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("中文/空目录").path))
    let empty = try temporaryDirectory().appendingPathComponent("empty-root")
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
    let remoteEmpty = remote + "-empty"
    try await SFTPDirectoryTransfer.upload(try XCTUnwrap(SFTPDirectoryTransfer.prepareUploads([empty]).first), to: remoteEmpty, using: client)
    let downloadedEmpty = try temporaryDirectory().appendingPathComponent("empty-root")
    try await SFTPDirectoryTransfer.download(rootEntry(remoteEmpty), to: downloadedEmpty, using: client)
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: downloadedEmpty.path).isEmpty)
  }

  func test_real_openssh_cancelled_folder_transfers_clean_staging_and_keep_other_files() async throws {
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    let store = KnownHostsStore(fileURL: try temporaryDirectory().appendingPathComponent("known-hosts"))
    let config = ConnectionConfig(hostname: server.host, port: server.port, username: server.username, auth: .password(server.password))
    let client = try await SFTPClient.connect(config: config, knownHosts: store, confirmUnknownHostKey: { _, _, _ in true })
    addTeardownBlock { await client.close() }
    let home = try await client.canonicalPath("."), source = try fixture()
    try Data(repeating: 0xA5, count: 8 * 1024 * 1024).write(to: source.appendingPathComponent("large.bin"))
    let remote = try RemotePath.child("cancel-tree-\(UUID())", in: home)
    let plan = try XCTUnwrap(SFTPDirectoryTransfer.prepareUploads([source]).first)
    let uploadProbe = DirectoryTransferProbe(minimum: 65_536)
    let uploading = Task { try await SFTPDirectoryTransfer.upload(plan, to: remote, using: client, progress: uploadProbe.cancelAfterChunk) }
    uploadProbe.set(uploading)
    do { try await uploading.value; XCTFail("must cancel upload") } catch is CancellationError {}
    let fresh = try await SFTPClient.connect(config: config, knownHosts: store, confirmUnknownHostKey: { _, _, _ in false })
    addTeardownBlock { await fresh.close() }
    let afterUpload = try await fresh.listDirectory(home)
    XCTAssertFalse(afterUpload.contains { $0.path == remote || $0.name.hasPrefix(".termes-upload-") })
    try await SFTPDirectoryTransfer.upload(plan, to: remote, using: fresh)
    let parent = try temporaryDirectory(), destination = parent.appendingPathComponent("tree")
    let sentinel = parent.appendingPathComponent("original")
    try Data("original".utf8).write(to: sentinel)
    let downloadProbe = DirectoryTransferProbe(minimum: 65_536)
    let entry = rootEntry(remote)
    let downloading = Task { try await SFTPDirectoryTransfer.download(entry, to: destination, using: fresh, progress: downloadProbe.cancelAfterChunk) }
    downloadProbe.set(downloading)
    do { try await downloading.value; XCTFail("must cancel download") } catch is CancellationError {}
    XCTAssertEqual(try Data(contentsOf: sentinel), Data("original".utf8))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), ["original"])
    let inspector = try await SFTPClient.connect(config: config, knownHosts: store, confirmUnknownHostKey: { _, _, _ in false })
    addTeardownBlock { await inspector.close() }
    let afterDownload = try await inspector.listDirectory(home)
    XCTAssertTrue(afterDownload.contains { $0.path == remote })
  }
}
