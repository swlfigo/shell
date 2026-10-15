import XCTest
@testable import SSHCore

private final class EditProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var task: Task<SFTPFileSnapshot, Error>?
  private var acted = false
  private var failure: String?
  func set(_ task: Task<SFTPFileSnapshot, Error>) { lock.withLock { self.task = task } }
  func cancel(_ value: SFTPProgress) { if value.completed >= 65_536 { lock.withLock { task?.cancel() } } }
  func changeOriginal(_ value: SFTPProgress, server: TestSSHServer, command: String) {
    guard value.completed >= 65_536, lock.withLock({ if acted { return false }; acted = true; return true }) else { return }
    let semaphore = DispatchSemaphore(value: 0)
    Task {
      do { _ = try await server.execute(["sh", "-c", command]) }
      catch { lock.withLock { failure = error.localizedDescription } }
      semaphore.signal()
    }
    if semaphore.wait(timeout: .now() + 10) != .success { lock.withLock { failure = "fixture update timed out" } }
  }
  var error: String? { lock.withLock { failure } }
}

final class SFTPFileEditingTests: XCTestCase {
  private func directory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
  }
  private func open(_ server: TestSSHServer, root: URL) async throws -> SFTPClient {
    let client = try await SFTPClient.connect(config: .init(hostname: server.host, port: server.port, username: server.username,
      auth: .password(server.password)), knownHosts: KnownHostsStore(fileURL: root.appendingPathComponent("hosts")), confirmUnknownHostKey: { _, _, _ in true })
    addTeardownBlock { await client.close() }; return client
  }
  private func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

  func test_permission_octal_validation_and_special_symbolic_bits() throws {
    XCTAssertEqual(try UnixPermissions(octal: " 755\n").value, 0o755)
    XCTAssertEqual(try UnixPermissions(0o640).octal, "0640")
    XCTAssertEqual(try UnixPermissions(0o4755).symbolic, "rwsr-xr-x")
    XCTAssertEqual(try UnixPermissions(0o2644).symbolic, "rw-r-Sr--")
    XCTAssertEqual(try UnixPermissions(0o1700).symbolic, "rwx-----T")
    for value in ["", "1", "22", "12345", "0888", "-644", "０６４４", "a644"] { XCTAssertThrowsError(try UnixPermissions(octal: value)) }
    XCTAssertThrowsError(try UnixPermissions(0o10000))
  }

  func test_real_permissions_files_directories_and_atomic_text_save_preserve_metadata() async throws {
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    let root = try directory(), client = try await open(server, root: root)
    let home = try await client.canonicalPath("."), path = home + "/edit-\(UUID())"
    let source = root.appendingPathComponent("source")
    let originalData = Data([0xEF, 0xBB, 0xBF]) + Data("中文\r\nold\r\n".utf8)
    try originalData.write(to: source); try await client.upload(source, to: path)
    let attrs = try await client.fileAttributes(path)
    XCTAssertEqual(attrs.permissions, 0o600); XCTAssertNotNil(attrs.ownerID); XCTAssertNotNil(attrs.groupID)
    let changed = try await client.setPermissions(path, permissions: 0o750, expected: attrs)
    XCTAssertEqual(changed.permissions, 0o750); XCTAssertEqual(changed.ownerID, attrs.ownerID)
    let snapshot = try await client.readFile(path)
    XCTAssertEqual(snapshot.data, originalData)
    let replacement = Data([0xEF, 0xBB, 0xBF]) + Data("中文\r\nnew\r\n".utf8)
    let saved = try await client.writeFile(replacement, to: path, expected: snapshot)
    XCTAssertEqual(saved.entry.permissions, 0o750); XCTAssertEqual(saved.entry.ownerID, attrs.ownerID); XCTAssertEqual(saved.entry.groupID, attrs.groupID)
    let readBack = try await client.readFile(path)
    XCTAssertEqual(readBack, saved)
    let empty = try await client.writeFile(Data(), to: path, expected: saved)
    XCTAssertEqual(empty.data, Data()); XCTAssertEqual(empty.entry.permissions, 0o750)
    let noAccess = try await client.setPermissions(path, permissions: 0, expected: empty.entry)
    let restored = try await client.setPermissions(path, permissions: 0o640, expected: noAccess)
    XCTAssertEqual(restored.permissions, 0o640)
    let folder = path + "-dir"
    try await client.createDirectory(folder)
    let folderAttrs = try await client.fileAttributes(folder)
    let sticky = try await client.setPermissions(folder, permissions: 0o1777, expected: folderAttrs)
    XCTAssertEqual(sticky.permissions, 0o1777)
    let directoryNoAccess = try await client.setPermissions(folder, permissions: 0, expected: sticky)
    let restoredDirectory = try await client.setPermissions(folder, permissions: 0o700, expected: directoryNoAccess)
    XCTAssertEqual(restoredDirectory.permissions, 0o700)
    _ = try await client.setPermissions(path, permissions: 0o666, expected: restored)
    _ = try await server.execute(["chown", "0:0", path])
    let differentOwner = try await client.readFile(path)
    do { _ = try await client.writeFile(Data("draft".utf8), to: path, expected: differentOwner); XCTFail("cannot preserve another owner's file") }
    catch let error as SFTPError { if case .operation = error {} else { XCTFail("unexpected \(error)") } }
    let keptOwner = try await client.readFile(path)
    XCTAssertEqual(keptOwner, differentOwner)
    let files = try await client.listDirectory(home)
    XCTAssertFalse(files.contains { $0.name.hasPrefix(".termes-edit-") })
  }

  func test_same_metadata_content_conflict_and_changes_during_staging_keep_remote_content() async throws {
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    let root = try directory(), client = try await open(server, root: root), source = root.appendingPathComponent("source")
    let path = try await client.canonicalPath(".") + "/conflict-\(UUID())"
    try Data("original".utf8).write(to: source); try await client.upload(source, to: path)
    let snapshot = try await client.readFile(path)
    _ = try await server.execute(["sh", "-c", "cp -p \(quote(path)) \(quote(path + "-stamp")); printf modified > \(quote(path)); touch -r \(quote(path + "-stamp")) \(quote(path)); rm \(quote(path + "-stamp"))"])
    let modified = try await client.readFile(path)
    XCTAssertEqual(modified.entry, snapshot.entry)
    do { _ = try await client.writeFile(Data("local draft".utf8), to: path, expected: snapshot); XCTFail("same-metadata conflict") }
    catch let error as SFTPEditError { XCTAssertEqual(error, .conflict(path)) }
    let probe = EditProbe()
    let command = "printf newest > \(quote(path))"
    do {
      _ = try await client.writeFile(Data(repeating: 65, count: 512 * 1024), to: path, expected: modified) { value in
        probe.changeOriginal(value, server: server, command: command)
      }
      XCTFail("changed while staging")
    } catch let error as SFTPEditError { XCTAssertEqual(error, .conflict(path)) }
    XCTAssertNil(probe.error)
    let newest = try await client.readFile(path)
    XCTAssertEqual(newest.data, Data("newest".utf8))
    do { _ = try await client.setPermissions(path, permissions: 0o777, expected: modified.entry); XCTFail("stale permissions") }
    catch let error as SFTPEditError { XCTAssertEqual(error, .conflict(path)) }
    let files = try await client.listDirectory(RemotePath.parent(path))
    XCTAssertFalse(files.contains { $0.name.hasPrefix(".termes-edit-") })
  }

  func test_bounded_reads_links_and_cancelled_save_preserve_original_and_clean_temporary() async throws {
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    let root = try directory(), client = try await open(server, root: root), source = root.appendingPathComponent("source")
    let path = try await client.canonicalPath(".") + "/bounds-\(UUID())"
    try Data("keep".utf8).write(to: source); try await client.upload(source, to: path)
    do { _ = try await client.readFile(path, maximumBytes: 3); XCTFail("bound") }
    catch let error as SFTPEditError { XCTAssertEqual(error, .tooLarge(3)) }
    _ = try await server.execute(["ln", "-s", path, path + "-link"])
    let link = try await client.fileAttributes(path + "-link")
    do { _ = try await client.setPermissions(link.path, permissions: 0o777, expected: link); XCTFail("link chmod") } catch let error as SFTPError { XCTAssertEqual(error, .unsupportedFile) }
    do { _ = try await client.readFile(link.path); XCTFail("link edit") } catch let error as SFTPError { XCTAssertEqual(error, .unsupportedFile) }
    let snapshot = try await client.readFile(path), probe = EditProbe()
    let task = Task { try await client.writeFile(Data(repeating: 65, count: SFTPFileSnapshot.maximumEditorBytes), to: path, expected: snapshot, progress: probe.cancel) }
    probe.set(task)
    do { _ = try await task.value; XCTFail("cancel") } catch is CancellationError {}
    let fresh = try await open(server, root: root)
    let after = try await fresh.readFile(path)
    XCTAssertEqual(after, snapshot)
    let files = try await fresh.listDirectory(RemotePath.parent(path))
    XCTAssertFalse(files.contains { $0.name.hasPrefix(".termes-edit-") })
    do { _ = try await fresh.writeFile(Data(count: SFTPFileSnapshot.maximumEditorBytes + 1), to: path, expected: snapshot); XCTFail("large write") }
    catch let error as SFTPEditError { XCTAssertEqual(error, .tooLarge(SFTPFileSnapshot.maximumEditorBytes)) }
  }
}
