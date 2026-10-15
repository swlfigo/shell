import XCTest
@testable import SSHCore

private final class TransferProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var task: Task<Void, Error>?
  private var values: [SFTPProgress] = []
  func set(_ task: Task<Void, Error>) { lock.withLock { self.task = task } }
  func record(_ progress: SFTPProgress) { lock.withLock { values.append(progress) } }
  func cancelAfterChunk(_ progress: SFTPProgress) {
    lock.withLock { if progress.completed >= 65_536 { task?.cancel() } }
  }
  var recorded: [SFTPProgress] { lock.withLock { values } }
}

final class SFTPTests: XCTestCase {
  private func store() -> KnownHostsStore {
    KnownHostsStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
  }
  private func config(_ server: TestSSHServer) -> ConnectionConfig {
    .init(hostname: server.host, port: server.port, username: server.username, auth: .password(server.password))
  }
  private func localDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  func test_paths_reject_ambiguous_names_and_preserve_relative_parent() throws {
    XCTAssertEqual(try RemotePath.child("中文 file", in: "/"), "/中文 file")
    XCTAssertEqual(RemotePath.parent("relative/file"), "relative")
    XCTAssertEqual(RemotePath.parent("file"), ".")
    XCTAssertEqual(RemotePath.parent("/home/"), "/")
    for name in ["", ".", "..", "a/b", "a\0b"] {
      XCTAssertThrowsError(try RemotePath.child(name, in: "/tmp"))
    }
    XCTAssertThrowsError(try RemotePath.validate(""))
    XCTAssertThrowsError(try RemotePath.child(String(repeating: "x", count: 32_768), in: "/tmp"))
  }

  func test_closed_client_reports_not_connected_for_late_operations() async throws {
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    let client = try await SFTPClient.connect(config: config(server), knownHosts: store(), confirmUnknownHostKey: { _, _, _ in true })
    addTeardownBlock { await client.close() }
    _ = try await client.listDirectory(".")
    await client.close()
    await client.close()
    do { _ = try await client.listDirectory("."); XCTFail("closed client must reject late work") }
    catch { XCTAssertEqual(error as? SFTPError, .notConnected) }
  }

  func test_binary_unicode_empty_files_overwrite_and_directory_operations() async throws {
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    let client = try await SFTPClient.connect(config: config(server), knownHosts: store(), confirmUnknownHostKey: { _, _, _ in true })
    addTeardownBlock { await client.close() }
    let home = try await client.canonicalPath(".")
    let directory = try RemotePath.child("sftp-\(UUID())", in: home)
    try await client.createDirectory(directory)
    let local = try localDirectory()
    let input = local.appendingPathComponent("中文 binary.bin")
    let data = Data((0..<300_000).map { UInt8($0 % 251) })
    try data.write(to: input)
    let remote = try RemotePath.child(input.lastPathComponent, in: directory)
    let probe = TransferProbe()
    try await client.upload(input, to: remote, progress: probe.record)
    let entries = try await client.listDirectory(directory)
    XCTAssertEqual(entries.count, 1)
    XCTAssertEqual(entries.first?.kind, .file)
    XCTAssertEqual(entries.first?.size, UInt64(data.count))
    XCTAssertNotNil(entries.first?.modifiedAt)
    XCTAssertEqual(probe.recorded.last, SFTPProgress(completed: UInt64(data.count), total: UInt64(data.count)))
    XCTAssertTrue(zip(probe.recorded, probe.recorded.dropFirst()).allSatisfy { $0.completed <= $1.completed })
    let output = local.appendingPathComponent("download.bin")
    try await client.download(remote, to: output)
    XCTAssertEqual(try Data(contentsOf: output), data)
    do { try await client.upload(input, to: remote); XCTFail("must reject overwrite") }
    catch let error as SFTPError { XCTAssertEqual(error, .alreadyExists(remote)) }
    do { try await client.download(remote, to: output); XCTFail("must reject overwrite") }
    catch let error as SFTPError { XCTAssertEqual(error, .alreadyExists(output.path)) }
    let replacement = Data("replacement".utf8)
    try replacement.write(to: input)
    try await client.upload(input, to: remote, overwrite: true)
    try await client.download(remote, to: output, overwrite: true)
    XCTAssertEqual(try Data(contentsOf: output), replacement)
    // A file truncated during the transfer must not replace a valid destination.
    try data.write(to: input)
    do {
      try await client.upload(input, to: remote, overwrite: true) { progress in
        if progress.completed == 65_536 {
          if let handle = try? FileHandle(forWritingTo: input) {
            try? handle.truncate(atOffset: 65_536); try? handle.close()
          }
        }
      }
      XCTFail("changed file must not commit")
    } catch let error as SFTPError { XCTAssertEqual(error, .fileChanged) }
    try await client.download(remote, to: output, overwrite: true)
    XCTAssertEqual(try Data(contentsOf: output), replacement)
    let empty = local.appendingPathComponent("empty")
    try Data().write(to: empty)
    let remoteEmpty = try RemotePath.child("empty", in: directory)
    try await client.upload(empty, to: remoteEmpty)
    let downloadedEmpty = local.appendingPathComponent("downloaded-empty")
    try await client.download(remoteEmpty, to: downloadedEmpty)
    XCTAssertEqual(try Data(contentsOf: downloadedEmpty), Data())
    let renamed = directory + "-renamed"
    try await client.rename(directory, to: renamed)
    let parentEntries = try await client.listDirectory(home)
    let dirEntry = try XCTUnwrap(parentEntries.first { $0.path == renamed })
    do { try await client.remove(dirEntry); XCTFail("nonempty directory must survive") } catch {}
    for entry in try await client.listDirectory(renamed) { try await client.remove(entry) }
    try await client.remove(dirEntry)
    let remaining = try await client.listDirectory(home)
    XCTAssertFalse(remaining.contains { $0.path == renamed })
  }

  func test_cancelled_upload_and_download_preserve_destinations_and_terminal() async throws {
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    let config = config(server), knownHosts = store()
    let connection = SSHConnection(config: config, knownHosts: knownHosts, confirmUnknownHostKey: { _, _, _ in true })
    try await connection.connect()
    let shell = try await connection.openShell(cols: 80, rows: 24)
    addTeardownBlock { await shell.close(); await connection.disconnect() }
    let first = try await SFTPClient.connect(config: config, knownHosts: knownHosts, confirmUnknownHostKey: { _, _, _ in false })
    addTeardownBlock { await first.close() }
    let local = try localDirectory(), input = local.appendingPathComponent("input")
    let original = Data("original destination".utf8)
    try original.write(to: input)
    let home = try await first.canonicalPath(".")
    let remote = try RemotePath.child("cancel-\(UUID())", in: home)
    try await first.upload(input, to: remote)
    let large = Data(repeating: 0xA5, count: 4 * 1024 * 1024)
    try large.write(to: input)
    let uploadProbe = TransferProbe()
    let uploading = Task { try await first.upload(input, to: remote, overwrite: true, progress: uploadProbe.cancelAfterChunk) }
    uploadProbe.set(uploading)
    do { try await uploading.value; XCTFail("must cancel") } catch is CancellationError {} catch { XCTFail("\(error)") }
    let second = try await SFTPClient.connect(config: config, knownHosts: knownHosts, confirmUnknownHostKey: { _, _, _ in false })
    addTeardownBlock { await second.close() }
    let output = local.appendingPathComponent("output")
    try await second.download(remote, to: output)
    XCTAssertEqual(try Data(contentsOf: output), original)
    let afterCancellation = try await second.listDirectory(home)
    XCTAssertFalse(afterCancellation.contains { $0.name.hasPrefix(".termes-upload-") })
    try await second.upload(input, to: remote, overwrite: true)
    let downloadProbe = TransferProbe()
    let downloading = Task { try await second.download(remote, to: output, overwrite: true, progress: downloadProbe.cancelAfterChunk) }
    downloadProbe.set(downloading)
    do { try await downloading.value; XCTFail("must cancel") } catch is CancellationError {} catch { XCTFail("\(error)") }
    XCTAssertEqual(try Data(contentsOf: output), original)
    XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: local.path).contains { $0.hasPrefix(".termes-download-") })
    await shell.send(Data("printf 'SFTP%s\\n' 'STILLALIVE'\n".utf8))
    let watchdog = Task { try? await Task.sleep(for: .seconds(5)); if !Task.isCancelled { await shell.close() } }
    var text = ""
    for await chunk in shell.output {
      text += String(decoding: chunk, as: UTF8.self)
      if text.contains("SFTPSTILLALIVE") { break }
    }
    watchdog.cancel()
    XCTAssertTrue(text.contains("SFTPSTILLALIVE"))
    let third = try await SFTPClient.connect(config: config, knownHosts: knownHosts, confirmUnknownHostKey: { _, _, _ in false })
    for entry in try await third.listDirectory(home) where entry.path == remote { try await third.remove(entry) }
    await third.close()
  }

  func test_private_key_auth_and_rejected_unknown_host() async throws {
    let server = try await TestSSHServer.start(); addTeardownBlock { await server.stop() }
    do {
      _ = try await SFTPClient.connect(config: config(server), knownHosts: store(), confirmUnknownHostKey: { _, _, _ in false })
      XCTFail("unknown host must be rejected")
    } catch let error as SSHError { XCTAssertEqual(error, .hostKeyRejected) }
    let config = ConnectionConfig(hostname: server.host, port: server.port, username: server.username,
      auth: .privateKey(data: Data(TestSSHServer.testEncryptedEd25519PrivateKey.utf8), passphrase: TestSSHServer.encryptedKeyPassphrase))
    let client = try await SFTPClient.connect(config: config, knownHosts: store(), confirmUnknownHostKey: { _, _, _ in true })
    let home = try await client.canonicalPath(".")
    let entries = try await client.listDirectory(home)
    XCTAssertFalse(entries.isEmpty)
    await client.close()
  }
}
