import XCTest
import Darwin
@testable import SSHCore

private final class ResumeProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var task: Task<Void, Error>?
  private var values: [SFTPProgress] = []
  let threshold: UInt64?
  init(threshold: UInt64? = nil) { self.threshold = threshold }
  func set(_ task: Task<Void, Error>) { lock.withLock { self.task = task } }
  func record(_ progress: SFTPProgress) {
    lock.withLock {
      values.append(progress)
      if let threshold, progress.completed >= threshold { task?.cancel() }
    }
  }
  var recorded: [SFTPProgress] { lock.withLock { values } }
}

final class SFTPResumeTests: XCTestCase {
  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }
  private func open(_ server: TestSSHServer, store: KnownHostsStore) async throws -> SFTPClient {
    let client = try await SFTPClient.connect(config: .init(hostname: server.host, port: server.port,
      username: server.username, auth: .password(server.password)), knownHosts: store, confirmUnknownHostKey: { _, _, _ in true })
    addTeardownBlock { await client.close() }
    return client
  }
  private func pause(_ transfer: SFTPFileTransfer, using client: SFTPClient, threshold: UInt64 = 65_536) async throws {
    let probe = ResumeProbe(threshold: threshold)
    let task = Task { try await client.transfer(transfer, progress: probe.record) }
    probe.set(task)
    do { try await task.value; XCTFail("must pause") } catch is CancellationError {}
  }

  func test_real_upload_and_download_resume_twice_preserve_destinations_and_report_actual_offsets() async throws {
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    let root = try directory(), store = KnownHostsStore(fileURL: root.appendingPathComponent("hosts"))
    let first = try await open(server, store: store)
    let home = try await first.canonicalPath(".")
    let input = root.appendingPathComponent("input"), output = root.appendingPathComponent("output")
    let remote = try RemotePath.child("resume-\(UUID())", in: home)
    let original = Data("original".utf8)
    try original.write(to: input); try original.write(to: output)
    try await first.upload(input, to: remote)
    let bytes = Data((0..<8 * 1024 * 1024).map { UInt8($0 % 251) })
    try bytes.write(to: input)
    let upload = try SFTPFileTransfer(direction: .upload, localURL: input, remotePath: remote, overwrite: true)
    try await pause(upload, using: first)
    let second = try await open(server, store: store)
    let partials = try await second.listDirectory(home)
    let partial = try XCTUnwrap(partials.first { $0.path == upload.remoteTemporaryPath })
    let offset = try XCTUnwrap(partial.size)
    XCTAssertGreaterThan(offset, 0); XCTAssertLessThan(offset, UInt64(bytes.count))
    let previous = root.appendingPathComponent("previous")
    try await second.download(remote, to: previous)
    XCTAssertEqual(try Data(contentsOf: previous), original)
    try await pause(upload, using: second, threshold: offset + 65_536)
    let third = try await open(server, store: store)
    let nextPartials = try await third.listDirectory(home)
    let resumedOffset = try XCTUnwrap(nextPartials.first { $0.path == upload.remoteTemporaryPath }?.size)
    let uploadProgress = ResumeProbe()
    try await third.transfer(upload, progress: uploadProgress.record)
    XCTAssertEqual(uploadProgress.recorded.first?.completed, resumedOffset)
    XCTAssertEqual(uploadProgress.recorded.last?.completed, UInt64(bytes.count))
    XCTAssertTrue(zip(uploadProgress.recorded, uploadProgress.recorded.dropFirst()).allSatisfy { $0.completed <= $1.completed })
    let afterUpload = try await third.listDirectory(home)
    XCTAssertFalse(afterUpload.contains { $0.path == upload.remoteTemporaryPath })
    let download = try SFTPFileTransfer(direction: .download, localURL: output, remotePath: remote, overwrite: true)
    try await pause(download, using: third)
    XCTAssertEqual(try Data(contentsOf: output), original)
    let localOffset = UInt64(try Data(contentsOf: download.localTemporaryURL).count)
    XCTAssertGreaterThan(localOffset, 0)
    let fourth = try await open(server, store: store)
    try await pause(download, using: fourth, threshold: localOffset + 65_536)
    let finalOffset = UInt64(try Data(contentsOf: download.localTemporaryURL).count)
    let fifth = try await open(server, store: store), downloadProgress = ResumeProbe()
    try await fifth.transfer(download, progress: downloadProgress.record)
    XCTAssertEqual(downloadProgress.recorded.first?.completed, finalOffset)
    XCTAssertEqual(try Data(contentsOf: output), bytes)
    XCTAssertFalse(FileManager.default.fileExists(atPath: download.localTemporaryURL.path))
  }

  func test_changed_sources_corrupt_partials_and_explicit_discard() async throws {
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    let root = try directory(), store = KnownHostsStore(fileURL: root.appendingPathComponent("hosts"))
    let first = try await open(server, store: store), input = root.appendingPathComponent("input")
    let home = try await first.canonicalPath("."), remote = home + "/source-\(UUID())"
    let bytes = Data(repeating: 0xA5, count: 4 * 1024 * 1024)
    try bytes.write(to: input)
    let changed = try SFTPFileTransfer(direction: .upload, localURL: input, remotePath: remote)
    try await pause(changed, using: first)
    let second = try await open(server, store: store)
    try Data(repeating: 0xB5, count: bytes.count).write(to: input)
    do { try await second.transfer(changed); XCTFail("changed source") }
    catch let error as SFTPResumeError { XCTAssertEqual(error, .sourceChanged) }
    await second.close()
    try await first.discardUsingFreshConnection(changed)
    let cleanupInspector = try await open(server, store: store)
    let cleared = try await cleanupInspector.listDirectory(home)
    XCTAssertFalse(cleared.contains { $0.path == changed.remoteTemporaryPath || $0.path == remote })
    try bytes.write(to: input)
    let corrupt = try SFTPFileTransfer(direction: .upload, localURL: input, remotePath: remote)
    try await pause(corrupt, using: cleanupInspector)
    let third = try await open(server, store: store), bad = root.appendingPathComponent("bad")
    try Data(repeating: 9, count: 65_536).write(to: bad)
    try await third.upload(bad, to: corrupt.remoteTemporaryPath, overwrite: true)
    do { try await third.transfer(corrupt); XCTFail("corrupt prefix") }
    catch let error as SFTPResumeError { XCTAssertEqual(error, .partialChanged) }
    try await third.discard(corrupt)
    try await third.upload(input, to: remote)
    let output = root.appendingPathComponent("output")
    let download = try SFTPFileTransfer(direction: .download, localURL: output, remotePath: remote)
    try await pause(download, using: third)
    let fourth = try await open(server, store: store)
    let local = try FileHandle(forWritingTo: download.localTemporaryURL)
    try local.write(contentsOf: Data([0])); try local.close()
    do { try await fourth.transfer(download); XCTFail("corrupt download prefix") }
    catch let error as SFTPResumeError { XCTAssertEqual(error, .partialChanged) }
    try download.discardLocalPartial()
    XCTAssertFalse(FileManager.default.fileExists(atPath: download.localTemporaryURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    let sourceChanged = try SFTPFileTransfer(direction: .download, localURL: output, remotePath: remote)
    try await pause(sourceChanged, using: fourth)
    let fifth = try await open(server, store: store)
    try await fifth.upload(bad, to: remote, overwrite: true)
    do { try await fifth.transfer(sourceChanged); XCTFail("changed remote source") }
    catch let error as SFTPResumeError { XCTAssertEqual(error, .sourceChanged) }
    try sourceChanged.discardLocalPartial()
  }

  func test_empty_files_conflicts_symlinks_and_late_local_destination_are_protected() async throws {
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    let root = try directory(), store = KnownHostsStore(fileURL: root.appendingPathComponent("hosts"))
    let client = try await open(server, store: store), input = root.appendingPathComponent("empty")
    try Data().write(to: input)
    let home = try await client.canonicalPath("."), remote = home + "/empty-\(UUID())"
    let upload = try SFTPFileTransfer(direction: .upload, localURL: input, remotePath: remote)
    try await client.transfer(upload)
    let output = root.appendingPathComponent("empty-output")
    try await client.transfer(SFTPFileTransfer(direction: .download, localURL: output, remotePath: remote))
    XCTAssertEqual(try Data(contentsOf: output), Data())
    let duplicate = try SFTPFileTransfer(direction: .upload, localURL: input, remotePath: remote)
    do { try await client.transfer(duplicate); XCTFail("conflict") } catch let error as SFTPError { XCTAssertEqual(error, .alreadyExists(remote)) }
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: input)
    do { try await client.transfer(SFTPFileTransfer(direction: .upload, localURL: link, remotePath: remote + "-link")); XCTFail("link") } catch {}
    let fifo = root.appendingPathComponent("pipe")
    XCTAssertEqual(Darwin.mkfifo(fifo.path, 0o600), 0)
    do { try await client.transfer(SFTPFileTransfer(direction: .upload, localURL: fifo, remotePath: remote + "-pipe")); XCTFail("pipe") }
    catch let error as SFTPError { XCTAssertEqual(error, .unsupportedFile) }
    let late = root.appendingPathComponent("late"), original = Data("keep".utf8)
    let lateDownload = try SFTPFileTransfer(direction: .download, localURL: late, remotePath: remote)
    do {
      try await client.transfer(lateDownload) { p in if p.completed == 0 { try? original.write(to: late) } }
      XCTFail("late destination")
    } catch let error as SFTPError { XCTAssertEqual(error, .alreadyExists(late.path)) }
    XCTAssertEqual(try Data(contentsOf: late), original)
    try lateDownload.discardLocalPartial()
  }
}
