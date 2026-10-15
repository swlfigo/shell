import Foundation
import CLibssh2
import Darwin
import CryptoKit

private final class SFTPCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  func cancel() { lock.withLock { cancelled = true } }
  var isCancelled: Bool { lock.withLock { cancelled } }
  func check() throws { if lock.withLock({ cancelled }) { throw CancellationError() } }
}

/// Owns a dedicated, authenticated SSH connection. SFTP calls and local file I/O are confined
/// to its serial session queue, so transfers never hold the interactive terminal's queue.
public final class SFTPClient: SFTPResumableFileSystem, SFTPFileEditingSystem, @unchecked Sendable {
  private let ssh: SSHSession
  private let owner: SSHConnection
  private var sftp: OpaquePointer? // Queue only.
  private let closing = SFTPCancellation()

  private init(ssh: SSHSession, owner: SSHConnection, sftp: OpaquePointer) {
    self.ssh = ssh; self.owner = owner; self.sftp = sftp
  }

  public static func connect(config: ConnectionConfig, knownHosts: KnownHostsStoring,
                             confirmUnknownHostKey: @escaping HostKeyConfirm) async throws -> SFTPClient {
    let connection = SSHConnection(config: config, knownHosts: knownHosts, confirmUnknownHostKey: confirmUnknownHostKey)
    do {
      try Task.checkCancellation()
      try await connection.connect()
      try Task.checkCancellation()
      return try await connection.makeSFTPClient()
    } catch { await connection.disconnect(); throw error }
  }

  fileprivate static func open(on ssh: SSHSession, owner: SSHConnection) async throws -> SFTPClient {
    let cancellation = SFTPCancellation()
    return try await withTaskCancellationHandler {
      try await ssh.run { session in
        guard let raw = session.session else { throw SFTPError.notConnected }
        while true {
          try cancellation.check()
          if let sftp = libssh2_sftp_init(raw) { return SFTPClient(ssh: session, owner: owner, sftp: sftp) }
          guard libssh2_session_last_errno(raw) == LIBSSH2_ERROR_EAGAIN else {
            throw SFTPError.operation("服务器未提供 SFTP：" + session.lastErrorMessage(), code: 0)
          }
          try session.waitSocket(checkCancellation: cancellation.check)
        }
      }
    } onCancel: { cancellation.cancel() }
  }

  deinit {
    // The underlying session owns the channels; release the transport even if the caller
    // forgot close(). Normal UI teardown explicitly closes the SFTP subsystem first.
    let owner = owner
    Task { await owner.disconnect() }
  }

  private func perform<T: Sendable>(_ body: @escaping @Sendable (SFTPClient, SFTPCancellation) throws -> T) async throws -> T {
    let cancellation = SFTPCancellation()
    do {
      return try await withTaskCancellationHandler {
        try await ssh.run { [self] _ in
          try check(cancellation)
          return try body(self, cancellation)
        }
      } onCancel: { cancellation.cancel() }
    } catch is CancellationError {
      // A non-blocking SFTP operation can retain protocol state on EAGAIN. Discard this
      // transport rather than reuse interrupted state for a different request.
      let alreadyClosed = closing.isCancelled
      await close()
      // Disconnect interrupts queued session work before its SFTP body can check
      // closing. Preserve the public error for clients that were explicitly closed.
      if alreadyClosed { throw SFTPError.notConnected }
      throw CancellationError()
    }
  }

  private func check(_ cancellation: SFTPCancellation) throws {
    try cancellation.check()
    do { try closing.check() } catch { throw SFTPError.notConnected }
    guard ssh.session != nil, sftp != nil else { throw SFTPError.notConnected }
  }

  private func retry(_ cancellation: SFTPCancellation, _ call: () -> Int) throws -> Int {
    while true {
      try check(cancellation)
      let result = call()
      if result != Int(LIBSSH2_ERROR_EAGAIN) { return result }
      try ssh.waitSocket { try self.check(cancellation) }
    }
  }

  private func failure(_ operation: String) -> SFTPError {
    .operation(operation + ": " + ssh.lastErrorMessage(), code: sftp.map { UInt(libssh2_sftp_last_error($0)) } ?? 0)
  }

  private func openHandle(_ path: String, flags: UInt = 0, directory: Bool = false,
                          cancellation: SFTPCancellation) throws -> OpaquePointer {
    try RemotePath.validate(path)
    guard let sftp else { throw SFTPError.notConnected }
    while true {
      try check(cancellation)
      if let handle = libssh2_sftp_open_ex(sftp, path, UInt32(path.utf8.count), flags, 0o600,
                                          directory ? LIBSSH2_SFTP_OPENDIR : LIBSSH2_SFTP_OPENFILE) { return handle }
      if libssh2_session_last_errno(ssh.session) != LIBSSH2_ERROR_EAGAIN { throw failure("打开 \(path)") }
      try ssh.waitSocket { try self.check(cancellation) }
    }
  }

  private func closeHandle(_ handle: OpaquePointer, cancellation: SFTPCancellation) throws {
    let result = try retry(cancellation) { Int(libssh2_sftp_close_handle(handle)) }
    guard result == 0 else { throw failure("关闭文件") }
  }

  /// Cleanup is bounded and ignores the cancelled operation's token. It cannot guarantee
  /// remote cleanup when the network disappeared; the old destination is never removed.
  private func cleanup(_ call: () -> Int32) {
    guard ssh.session != nil else { return }
    let deadline = Date().addingTimeInterval(1)
    while call() == LIBSSH2_ERROR_EAGAIN, Date() < deadline {
      var fd = pollfd(fd: ssh.socketFD, events: Int16(POLLIN | POLLOUT), revents: 0)
      _ = poll(&fd, 1, 20)
    }
  }

  private func attributes(_ path: String, followLinks: Bool, cancellation: SFTPCancellation) throws -> LIBSSH2_SFTP_ATTRIBUTES? {
    try RemotePath.validate(path)
    guard let sftp else { throw SFTPError.notConnected }
    var attributes = LIBSSH2_SFTP_ATTRIBUTES()
    let result = try retry(cancellation) {
      Int(libssh2_sftp_stat_ex(sftp, path, UInt32(path.utf8.count),
                              followLinks ? LIBSSH2_SFTP_STAT : LIBSSH2_SFTP_LSTAT, &attributes))
    }
    if result == 0 { return attributes }
    if libssh2_sftp_last_error(sftp) == LIBSSH2_FX_NO_SUCH_FILE { return nil }
    throw failure("读取属性 \(path)")
  }

  private func entry(path: String, name: String, attributes: LIBSSH2_SFTP_ATTRIBUTES) -> SFTPEntry {
    let kind: SFTPEntry.Kind
    if attributes.flags & UInt(LIBSSH2_SFTP_ATTR_PERMISSIONS) == 0 { kind = .other }
    else {
      switch attributes.permissions & UInt(LIBSSH2_SFTP_S_IFMT) {
      case UInt(LIBSSH2_SFTP_S_IFDIR): kind = .directory
      case UInt(LIBSSH2_SFTP_S_IFREG): kind = .file
      case UInt(LIBSSH2_SFTP_S_IFLNK): kind = .symbolicLink
      default: kind = .other
      }
    }
    return SFTPEntry(path: path, name: name, kind: kind,
      size: attributes.flags & UInt(LIBSSH2_SFTP_ATTR_SIZE) != 0 ? attributes.filesize : nil,
      modifiedAt: attributes.flags & UInt(LIBSSH2_SFTP_ATTR_ACMODTIME) != 0 ? Date(timeIntervalSince1970: Double(attributes.mtime)) : nil,
      permissions: attributes.flags & UInt(LIBSSH2_SFTP_ATTR_PERMISSIONS) != 0 ? UInt32(attributes.permissions & 0o7777) : nil,
      ownerID: attributes.flags & UInt(LIBSSH2_SFTP_ATTR_UIDGID) != 0 ? UInt32(truncatingIfNeeded: attributes.uid) : nil,
      groupID: attributes.flags & UInt(LIBSSH2_SFTP_ATTR_UIDGID) != 0 ? UInt32(truncatingIfNeeded: attributes.gid) : nil)
  }

  public func canonicalPath(_ path: String) async throws -> String {
    try RemotePath.validate(path)
    return try await perform { client, cancellation in
      guard let sftp = client.sftp else { throw SFTPError.notConnected }
      var buffer = [CChar](repeating: 0, count: 32_768)
      let count = try client.retry(cancellation) {
        Int(libssh2_sftp_symlink_ex(sftp, path, UInt32(path.utf8.count), &buffer, UInt32(buffer.count), LIBSSH2_SFTP_REALPATH))
      }
      guard count > 0, count < buffer.count else { throw client.failure("打开目录 \(path)") }
      guard let path = String(bytes: buffer.prefix(count).map { UInt8(bitPattern: $0) }, encoding: .utf8) else { throw SFTPError.invalidPath }
      return path
    }
  }

  public func listDirectory(_ path: String) async throws -> [SFTPEntry] {
    try await perform { client, cancellation in
      let handle = try client.openHandle(path, directory: true, cancellation: cancellation)
      defer { client.cleanup { libssh2_sftp_close_handle(handle) } }
      var result: [SFTPEntry] = []
      var buffer = [CChar](repeating: 0, count: 32_768)
      while true {
        var attributes = LIBSSH2_SFTP_ATTRIBUTES()
        let count = try client.retry(cancellation) { Int(libssh2_sftp_readdir_ex(handle, &buffer, buffer.count, nil, 0, &attributes)) }
        if count == 0 { break }
        guard count > 0, count < buffer.count else { throw client.failure("读取目录 \(path)") }
        guard let name = String(bytes: buffer.prefix(count).map { UInt8(bitPattern: $0) }, encoding: .utf8) else { throw SFTPError.invalidPath }
        if name == "." || name == ".." { continue }
        let child = try RemotePath.child(name, in: path)
        result.append(client.entry(path: child, name: name, attributes: attributes))
      }
      return result.sorted {
        if ($0.kind == .directory) != ($1.kind == .directory) { return $0.kind == .directory }
        return $0.name.localizedStandardCompare($1.name) == .orderedAscending
      }
    }
  }

  public func createDirectory(_ path: String) async throws {
    try RemotePath.validate(path)
    try await perform { client, cancellation in
      guard let sftp = client.sftp else { throw SFTPError.notConnected }
      let result = try client.retry(cancellation) { Int(libssh2_sftp_mkdir_ex(sftp, path, UInt32(path.utf8.count), 0o755)) }
      guard result == 0 else { throw client.failure("新建目录 \(path)") }
    }
  }

  private func move(_ source: String, to destination: String, overwrite: Bool, cancellation: SFTPCancellation) throws {
    guard let sftp else { throw SFTPError.notConnected }
    if !overwrite, try attributes(destination, followLinks: false, cancellation: cancellation) != nil {
      throw SFTPError.alreadyExists(destination)
    }
    let result = try retry(cancellation) {
      if overwrite { return Int(libssh2_sftp_posix_rename_ex(sftp, source, source.utf8.count, destination, destination.utf8.count)) }
      return Int(libssh2_sftp_rename_ex(sftp, source, UInt32(source.utf8.count), destination, UInt32(destination.utf8.count), 0))
    }
    guard result == 0 else { throw failure("重命名 \(source) → \(destination)") }
  }

  public func rename(_ source: String, to destination: String) async throws {
    try RemotePath.validate(source); try RemotePath.validate(destination)
    try await perform { client, cancellation in try client.move(source, to: destination, overwrite: false, cancellation: cancellation) }
  }

  public func remove(_ entry: SFTPEntry) async throws {
    try RemotePath.validate(entry.path)
    guard entry.path != "/", entry.name != ".", entry.name != ".." else { throw SFTPError.invalidPath }
    try await perform { client, cancellation in
      guard let sftp = client.sftp else { throw SFTPError.notConnected }
      // LSTAT again: do not trust a stale table entry or follow a replaced symlink.
      guard let attrs = try client.attributes(entry.path, followLinks: false, cancellation: cancellation) else { throw client.failure("文件已不存在") }
      let current = client.entry(path: entry.path, name: entry.name, attributes: attrs)
      let result = try client.retry(cancellation) {
        if current.kind == .directory { return Int(libssh2_sftp_rmdir_ex(sftp, entry.path, UInt32(entry.path.utf8.count))) }
        return Int(libssh2_sftp_unlink_ex(sftp, entry.path, UInt32(entry.path.utf8.count)))
      }
      guard result == 0 else { throw client.failure("删除 \(entry.path)（目录必须为空）") }
    }
  }

  public func upload(_ localURL: URL, to remotePath: String, overwrite: Bool = false,
                     progress: @escaping SFTPProgressHandler = { _ in }) async throws {
    try RemotePath.validate(remotePath)
    guard localURL.isFileURL else { throw SFTPError.invalidPath }
    try await perform { client, cancellation in
      try client.uploadFile(localURL, to: remotePath, overwrite: overwrite, cancellation: cancellation, progress: progress)
    }
  }

  /// A complete directory operation shares one cancellation boundary, so rollback runs on
  /// the original session queue before perform() discards an interrupted transport.
  func uploadDirectory(_ item: SFTPUploadItem, to destination: String, progress: @escaping SFTPProgressHandler) async throws {
    try await perform { client, cancellation in
      if try client.attributes(destination, followLinks: false, cancellation: cancellation) != nil {
        throw SFTPError.alreadyExists(destination)
      }
      guard let sftp = client.sftp else { throw SFTPError.notConnected }
      let temporary = try RemotePath.child(".termes-upload-\(UUID().uuidString).part", in: RemotePath.parent(destination))
      var created: [SFTPEntry] = [], committed = false
      defer {
        if !committed {
          let cleanupDeadline = Date().addingTimeInterval(5)
          for entry in created.reversed() {
            guard Date() < cleanupDeadline else { break }
            client.cleanup {
              if entry.kind == .directory { return libssh2_sftp_rmdir_ex(sftp, entry.path, UInt32(entry.path.utf8.count)) }
              return libssh2_sftp_unlink_ex(sftp, entry.path, UInt32(entry.path.utf8.count))
            }
          }
        }
      }
      let total = try SFTPDirectoryTransfer.sumSizes(item.contents.filter { !$0.isDirectory }.map(\.size))
      var completed: UInt64 = 0
      progress(.init(completed: 0, total: total))
      for node in item.contents {
        try client.check(cancellation)
        try SFTPDirectoryTransfer.validateLocal(node, root: item.source)
        let path = try SFTPDirectoryTransfer.remotePath(temporary, node.components)
        if node.isDirectory {
          let result = try client.retry(cancellation) { Int(libssh2_sftp_mkdir_ex(sftp, path, UInt32(path.utf8.count), 0o755)) }
          guard result == 0 else { throw client.failure("新建目录 \(path)") }
          created.append(.init(path: path, name: RemotePath.name(path), kind: .directory))
        } else {
          let base = completed
          try client.uploadFile(SFTPDirectoryTransfer.localPath(item.source, node.components), to: path, overwrite: false,
                                cancellation: cancellation) { value in
            progress(.init(completed: base + min(value.completed, node.size), total: total))
          }
          created.append(.init(path: path, name: RemotePath.name(path), kind: .file))
          try SFTPDirectoryTransfer.validateLocal(node, root: item.source)
          completed += node.size
        }
      }
      try client.check(cancellation)
      try client.move(temporary, to: destination, overwrite: false, cancellation: cancellation)
      committed = true
      progress(.init(completed: total, total: total))
    }
  }

  private func uploadFile(_ localURL: URL, to remotePath: String, overwrite: Bool,
                          cancellation: SFTPCancellation, progress: @escaping SFTPProgressHandler) throws {
    let client = self
    let fileAttributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
    guard fileAttributes[.type] as? FileAttributeType == .typeRegular else { throw SFTPError.unsupportedFile }
    if !overwrite, try client.attributes(remotePath, followLinks: false, cancellation: cancellation) != nil { throw SFTPError.alreadyExists(remotePath) }
    let input = try FileHandle(forReadingFrom: localURL)
    defer { try? input.close() }
    let total = (fileAttributes[.size] as? NSNumber)?.uint64Value
    let temporary = try RemotePath.child(".termes-upload-\(UUID().uuidString).part", in: RemotePath.parent(remotePath))
    let handle = try client.openHandle(temporary, flags: UInt(LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_EXCL), cancellation: cancellation)
    var handleOpen = true, committed = false
    defer {
      if handleOpen { client.cleanup { libssh2_sftp_close_handle(handle) } }
      if !committed, let sftp = client.sftp { client.cleanup { libssh2_sftp_unlink_ex(sftp, temporary, UInt32(temporary.utf8.count)) } }
    }
    var completed: UInt64 = 0
    progress(SFTPProgress(completed: 0, total: total))
    while true {
      try client.check(cancellation)
      guard let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
      try chunk.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
        var offset = 0
        while offset < bytes.count {
          let count = try client.retry(cancellation) { libssh2_sftp_write(handle, bytes.baseAddress!.advanced(by: offset).assumingMemoryBound(to: CChar.self), bytes.count - offset) }
          guard count >= 0 else { throw client.failure("上传 \(remotePath)") }
          if count == 0 { try client.ssh.waitSocket { try client.check(cancellation) }; continue }
          offset += count
        }
      }
      completed += UInt64(chunk.count)
      progress(SFTPProgress(completed: completed, total: total))
    }
    if let total, completed != total { throw SFTPError.fileChanged }
    try client.closeHandle(handle, cancellation: cancellation)
    handleOpen = false
    try client.move(temporary, to: remotePath, overwrite: overwrite, cancellation: cancellation)
    committed = true
    progress(SFTPProgress(completed: completed, total: completed))
  }

  public func download(_ remotePath: String, to localURL: URL, overwrite: Bool = false,
                       progress: @escaping SFTPProgressHandler = { _ in }) async throws {
    try RemotePath.validate(remotePath)
    guard localURL.isFileURL else { throw SFTPError.invalidPath }
    try await perform { client, cancellation in
      let exists = FileManager.default.fileExists(atPath: localURL.path)
      if !overwrite && exists { throw SFTPError.alreadyExists(localURL.path) }
      guard let attrs = try client.attributes(remotePath, followLinks: true, cancellation: cancellation),
            client.entry(path: remotePath, name: "", attributes: attrs).kind == .file else { throw SFTPError.unsupportedFile }
      let handle = try client.openHandle(remotePath, flags: UInt(LIBSSH2_FXF_READ), cancellation: cancellation)
      defer { client.cleanup { libssh2_sftp_close_handle(handle) } }
      let temporary = localURL.deletingLastPathComponent().appendingPathComponent(".termes-download-\(UUID().uuidString).part")
      let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
      guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
      let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
      defer { try? output.close(); try? FileManager.default.removeItem(at: temporary) }
      let total = attrs.flags & UInt(LIBSSH2_SFTP_ATTR_SIZE) != 0 ? attrs.filesize : nil
      var buffer = [CChar](repeating: 0, count: 64 * 1024)
      var completed: UInt64 = 0
      progress(SFTPProgress(completed: 0, total: total))
      while true {
        let count = try client.retry(cancellation) { libssh2_sftp_read(handle, &buffer, buffer.count) }
        if count == 0 { break }
        guard count > 0 else { throw client.failure("下载 \(remotePath)") }
        try buffer.withUnsafeBytes { try output.write(contentsOf: Data($0.prefix(count))) }
        completed += UInt64(count)
        progress(SFTPProgress(completed: completed, total: total))
      }
      try client.check(cancellation)
      if let total, completed != total { throw SFTPError.fileChanged }
      try output.synchronize()
      try output.close()
      let result: Int32
      if overwrite { result = Darwin.rename(temporary.path, localURL.path) }
      else { result = Darwin.link(temporary.path, localURL.path) }
      guard result == 0 else {
        if errno == EEXIST { throw SFTPError.alreadyExists(localURL.path) }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
      }
      progress(SFTPProgress(completed: completed, total: completed))
    }
  }

  /// Resume uses new handles: seek must never change an outstanding SFTP request's offset.
  public func transfer(_ transfer: SFTPFileTransfer, progress: @escaping SFTPProgressHandler = { _ in }) async throws {
    try transfer.begin()
    defer { transfer.end() }
    try await perform { client, cancellation in
      switch transfer.direction {
      case .upload: try client.resumeUpload(transfer, cancellation: cancellation, progress: progress)
      case .download: try client.resumeDownload(transfer, cancellation: cancellation, progress: progress)
      }
    }
  }

  public func discard(_ transfer: SFTPFileTransfer) async throws {
    if transfer.state.finished { return }
    if transfer.direction == .download { try transfer.discardLocalPartial(); return }
    try transfer.begin()
    defer { transfer.end() }
    if transfer.state.remotePartialCreated {
      try await perform { client, cancellation in
        let path = transfer.remoteTemporaryPath
        if try client.attributes(path, followLinks: false, cancellation: cancellation) != nil {
          guard let sftp = client.sftp else { throw SFTPError.notConnected }
          let result = try client.retry(cancellation) { Int(libssh2_sftp_unlink_ex(sftp, path, UInt32(path.utf8.count))) }
          guard result == 0 else { throw client.failure("清理临时文件") }
        }
      }
    }
    var state = transfer.state; state.finished = true; transfer.state = state
  }

  /// A paused/cancelled client is closed. Explicit cancellation can still clean its own
  /// checkpoint after the terminal disconnects, without reopening an interactive session.
  public func discardUsingFreshConnection(_ transfer: SFTPFileTransfer) async throws {
    if transfer.state.finished { return }
    if transfer.direction == .download { try transfer.discardLocalPartial(); return }
    guard transfer.state.remotePartialCreated else { try await discard(transfer); return }
    let client = try await owner.makeCleanupSFTPClient()
    do { try await client.discard(transfer); await client.close() }
    catch { await client.close(); throw error }
  }

  private func handleAttributes(_ handle: OpaquePointer, cancellation: SFTPCancellation) throws -> LIBSSH2_SFTP_ATTRIBUTES {
    var attrs = LIBSSH2_SFTP_ATTRIBUTES()
    let result = try retry(cancellation) { Int(libssh2_sftp_fstat_ex(handle, &attrs, 0)) }
    guard result == 0 else { throw failure("读取文件属性") }
    return attrs
  }

  private func regularSize(_ attrs: LIBSSH2_SFTP_ATTRIBUTES) throws -> UInt64 {
    guard attrs.flags & UInt(LIBSSH2_SFTP_ATTR_SIZE | LIBSSH2_SFTP_ATTR_PERMISSIONS) == UInt(LIBSSH2_SFTP_ATTR_SIZE | LIBSSH2_SFTP_ATTR_PERMISSIONS),
          attrs.permissions & UInt(LIBSSH2_SFTP_S_IFMT) == UInt(LIBSSH2_SFTP_S_IFREG) else { throw SFTPError.unsupportedFile }
    return attrs.filesize
  }

  private func localStat(_ file: FileHandle) throws -> stat {
    var value = stat()
    guard Darwin.fstat(file.fileDescriptor, &value) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    guard value.st_mode & S_IFMT == S_IFREG, value.st_size >= 0 else { throw SFTPError.unsupportedFile }
    return value
  }

  private func sourceDigest(_ input: FileHandle, cancellation: SFTPCancellation) throws -> Data {
    try input.seek(toOffset: 0)
    var hash = SHA256()
    while let data = try input.read(upToCount: 64 * 1024), !data.isEmpty {
      try check(cancellation); hash.update(data: data)
    }
    try input.seek(toOffset: 0)
    return Data(hash.finalize())
  }

  /// Compare all retained bytes, rather than trusting the last UI progress value.
  private func verifyPrefix(_ remote: OpaquePointer, local: FileHandle, size: UInt64,
                            cancellation: SFTPCancellation) throws {
    var remaining = size
    var buffer = [CChar](repeating: 0, count: 64 * 1024)
    try local.seek(toOffset: 0)
    while remaining > 0 {
      let count = try retry(cancellation) { libssh2_sftp_read(remote, &buffer, Int(min(remaining, UInt64(buffer.count)))) }
      guard count > 0, let data = try local.read(upToCount: count), data.count == count,
            data == buffer.withUnsafeBytes({ Data($0.prefix(count)) }) else { throw SFTPResumeError.partialChanged }
      remaining -= UInt64(count)
    }
  }

  private func checkDestination(_ transfer: SFTPFileTransfer, cancellation: SFTPCancellation) throws {
    if let attrs = try attributes(transfer.remotePath, followLinks: false, cancellation: cancellation) {
      guard transfer.overwrite else { throw SFTPError.alreadyExists(transfer.remotePath) }
      _ = try regularSize(attrs)
    }
  }

  private func resumeUpload(_ transfer: SFTPFileTransfer, cancellation: SFTPCancellation,
                            progress: @escaping SFTPProgressHandler) throws {
    try checkDestination(transfer, cancellation: cancellation)
    guard try FileManager.default.attributesOfItem(atPath: transfer.localURL.path)[.type] as? FileAttributeType == .typeRegular else {
      throw SFTPError.unsupportedFile
    }
    let fd = Darwin.open(transfer.localURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? input.close() }
    let local = try localStat(input)
    let digest = try sourceDigest(input, cancellation: cancellation)
    let modified = Date(timeIntervalSince1970: Double(local.st_mtimespec.tv_sec) + Double(local.st_mtimespec.tv_nsec) / 1e9)
    var state = transfer.state
    if let saved = state.sourceDigest {
      guard saved == digest, state.sourceSize == UInt64(local.st_size), state.sourceInode == local.st_ino,
            state.sourceModified == modified else { throw SFTPResumeError.sourceChanged }
    } else {
      state.sourceDigest = digest; state.sourceSize = UInt64(local.st_size)
      state.sourceInode = local.st_ino; state.sourceModified = modified; transfer.state = state
    }
    let total = UInt64(local.st_size), temporary = transfer.remoteTemporaryPath
    let existing = try attributes(temporary, followLinks: false, cancellation: cancellation)
    var offset: UInt64 = 0
    if let existing {
      guard state.remotePartialCreated else { throw SFTPResumeError.partialChanged }
      offset = try regularSize(existing)
      guard offset <= total else { throw SFTPResumeError.partialChanged }
      let reader = try openHandle(temporary, flags: UInt(LIBSSH2_FXF_READ), cancellation: cancellation)
      do {
        guard try regularSize(handleAttributes(reader, cancellation: cancellation)) == offset else { throw SFTPResumeError.partialChanged }
        try verifyPrefix(reader, local: input, size: offset, cancellation: cancellation)
        try closeHandle(reader, cancellation: cancellation)
      } catch { cleanup { libssh2_sftp_close_handle(reader) }; throw error }
    }
    let flags = existing == nil ? UInt(LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_EXCL) : UInt(LIBSSH2_FXF_WRITE)
    let writer = try openHandle(temporary, flags: flags, cancellation: cancellation)
    var open = true
    defer { if open { cleanup { libssh2_sftp_close_handle(writer) } } }
    state.remotePartialCreated = true; transfer.state = state
    guard try regularSize(handleAttributes(writer, cancellation: cancellation)) == offset else { throw SFTPResumeError.partialChanged }
    libssh2_sftp_seek64(writer, offset)
    try input.seek(toOffset: offset)
    var completed = offset
    progress(.init(completed: offset, total: total))
    while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
      try check(cancellation)
      try chunk.withUnsafeBytes { bytes in
        var sent = 0
        while sent < bytes.count {
          let count = try retry(cancellation) { libssh2_sftp_write(writer, bytes.baseAddress!.advanced(by: sent).assumingMemoryBound(to: CChar.self), bytes.count - sent) }
          guard count >= 0 else { throw failure("续传上传") }
          if count == 0 { try ssh.waitSocket { try self.check(cancellation) }; continue }
          sent += count
        }
      }
      completed += UInt64(chunk.count)
      guard completed <= total else { throw SFTPResumeError.sourceChanged }
      progress(.init(completed: completed, total: total))
    }
    // Detect same-size edits as well as truncation before publishing the destination.
    let final = try localStat(input)
    guard completed == total, final.st_size == local.st_size,
          final.st_mtimespec.tv_sec == local.st_mtimespec.tv_sec, final.st_mtimespec.tv_nsec == local.st_mtimespec.tv_nsec,
          try sourceDigest(input, cancellation: cancellation) == digest else { throw SFTPResumeError.sourceChanged }
    try closeHandle(writer, cancellation: cancellation); open = false
    try checkDestination(transfer, cancellation: cancellation)
    try move(temporary, to: transfer.remotePath, overwrite: transfer.overwrite, cancellation: cancellation)
    state.finished = true; state.remotePartialCreated = false; transfer.state = state
    progress(.init(completed: total, total: total))
  }

  private func resumeDownload(_ transfer: SFTPFileTransfer, cancellation: SFTPCancellation,
                              progress: @escaping SFTPProgressHandler) throws {
    if !transfer.overwrite, (try? FileManager.default.attributesOfItem(atPath: transfer.localURL.path)) != nil {
      throw SFTPError.alreadyExists(transfer.localURL.path)
    }
    guard let attrs = try attributes(transfer.remotePath, followLinks: false, cancellation: cancellation) else { throw SFTPError.unsupportedFile }
    let total = try regularSize(attrs)
    let snapshot = entry(path: transfer.remotePath, name: RemotePath.name(transfer.remotePath), attributes: attrs)
    var state = transfer.state
    if let previous = state.remoteSource {
      guard previous == snapshot else { throw SFTPResumeError.sourceChanged }
    } else { state.remoteSource = snapshot; transfer.state = state }
    let reader = try openHandle(transfer.remotePath, flags: UInt(LIBSSH2_FXF_READ), cancellation: cancellation)
    defer { cleanup { libssh2_sftp_close_handle(reader) } }
    guard entry(path: snapshot.path, name: snapshot.name, attributes: try handleAttributes(reader, cancellation: cancellation)) == snapshot else { throw SFTPResumeError.sourceChanged }
    let temporary = transfer.localTemporaryURL
    let existing = try? FileManager.default.attributesOfItem(atPath: temporary.path)
    if existing != nil, state.localPartialInode == nil { throw SFTPResumeError.partialChanged }
    if let existing, existing[.type] as? FileAttributeType != .typeRegular { throw SFTPResumeError.partialChanged }
    let flags = O_RDWR | O_NOFOLLOW | O_NONBLOCK | (existing == nil ? O_CREAT | O_EXCL : 0)
    let fd = Darwin.open(temporary.path, flags, 0o600)
    guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? output.close() }
    let local = try localStat(output)
    if existing != nil, state.localPartialInode != local.st_ino { throw SFTPResumeError.partialChanged }
    state.localPartialInode = local.st_ino; transfer.state = state
    let offset = UInt64(local.st_size)
    guard offset <= total else { throw SFTPResumeError.partialChanged }
    // Verification advances this fresh read handle to the retained prefix's end.
    try verifyPrefix(reader, local: output, size: offset, cancellation: cancellation)
    try output.seek(toOffset: offset)
    var completed = offset
    progress(.init(completed: offset, total: total))
    var buffer = [CChar](repeating: 0, count: 64 * 1024)
    while true {
      let count = try retry(cancellation) { libssh2_sftp_read(reader, &buffer, buffer.count) }
      if count == 0 { break }
      guard count > 0 else { throw failure("续传下载") }
      completed += UInt64(count)
      guard completed <= total else { throw SFTPResumeError.sourceChanged }
      try buffer.withUnsafeBytes { try output.write(contentsOf: Data($0.prefix(count))) }
      progress(.init(completed: completed, total: total))
    }
    guard completed == total,
          entry(path: snapshot.path, name: snapshot.name, attributes: try handleAttributes(reader, cancellation: cancellation)) == snapshot,
          let current = try attributes(snapshot.path, followLinks: false, cancellation: cancellation),
          entry(path: snapshot.path, name: snapshot.name, attributes: current) == snapshot else { throw SFTPResumeError.sourceChanged }
    try output.synchronize(); try output.close()
    try check(cancellation)
    let result = transfer.overwrite ? Darwin.rename(temporary.path, transfer.localURL.path) : Darwin.link(temporary.path, transfer.localURL.path)
    guard result == 0 else {
      if errno == EEXIST { throw SFTPError.alreadyExists(transfer.localURL.path) }
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    if !transfer.overwrite { try? FileManager.default.removeItem(at: temporary) }
    state.finished = true; state.localPartialInode = nil; transfer.state = state
    progress(.init(completed: total, total: total))
  }

  public func fileAttributes(_ path: String) async throws -> SFTPEntry {
    try await perform { client, cancellation in
      guard let attrs = try client.attributes(path, followLinks: false, cancellation: cancellation) else { throw client.failure("文件已不存在") }
      return client.entry(path: path, name: RemotePath.name(path), attributes: attrs)
    }
  }

  public func setPermissions(_ path: String, permissions: UInt32, expected: SFTPEntry) async throws -> SFTPEntry {
    _ = try UnixPermissions(permissions)
    guard expected.path == path else { throw SFTPError.invalidPath }
    return try await perform { client, cancellation in
      guard let current = try client.attributes(path, followLinks: false, cancellation: cancellation) else { throw SFTPEditError.conflict(path) }
      let before = client.entry(path: path, name: RemotePath.name(path), attributes: current)
      guard before.kind == .file || before.kind == .directory else { throw SFTPError.unsupportedFile }
      guard before == expected else { throw SFTPEditError.conflict(path) }
      guard let sftp = client.sftp else { throw SFTPError.notConnected }
      var attrs = LIBSSH2_SFTP_ATTRIBUTES(); attrs.flags = UInt(LIBSSH2_SFTP_ATTR_PERMISSIONS); attrs.permissions = UInt(permissions)
      let result = try client.retry(cancellation) { Int(libssh2_sftp_stat_ex(sftp, path, UInt32(path.utf8.count), LIBSSH2_SFTP_SETSTAT, &attrs)) }
      guard result == 0 else { throw client.failure("修改权限") }
      guard let updated = try client.attributes(path, followLinks: false, cancellation: cancellation) else { throw SFTPEditError.conflict(path) }
      let after = client.entry(path: path, name: before.name, attributes: updated)
      guard after.kind == before.kind, after.permissions == permissions else { throw client.failure("服务器未应用请求的权限") }
      return after
    }
  }

  public func readFile(_ path: String, maximumBytes: Int = SFTPFileSnapshot.maximumEditorBytes) async throws -> SFTPFileSnapshot {
    guard maximumBytes >= 0, maximumBytes <= SFTPFileSnapshot.maximumEditorBytes else { throw SFTPEditError.tooLarge(SFTPFileSnapshot.maximumEditorBytes) }
    return try await perform { client, cancellation in try client.readSnapshot(path, maximumBytes: maximumBytes, cancellation: cancellation) }
  }

  private func readSnapshot(_ path: String, maximumBytes: Int, cancellation: SFTPCancellation) throws -> SFTPFileSnapshot {
    guard let attrs = try attributes(path, followLinks: false, cancellation: cancellation) else { throw SFTPEditError.conflict(path) }
    let size = try regularSize(attrs)
    guard size <= UInt64(maximumBytes) else { throw SFTPEditError.tooLarge(maximumBytes) }
    let before = entry(path: path, name: RemotePath.name(path), attributes: attrs)
    let handle = try openHandle(path, flags: UInt(LIBSSH2_FXF_READ), cancellation: cancellation)
    defer { cleanup { libssh2_sftp_close_handle(handle) } }
    guard entry(path: path, name: before.name, attributes: try handleAttributes(handle, cancellation: cancellation)) == before else { throw SFTPEditError.conflict(path) }
    var buffer = [CChar](repeating: 0, count: 64 * 1024), data = Data()
    while true {
      let count = try retry(cancellation) { libssh2_sftp_read(handle, &buffer, buffer.count) }
      if count == 0 { break }
      guard count > 0 else { throw failure("读取文本") }
      guard count <= maximumBytes - data.count else { throw SFTPEditError.tooLarge(maximumBytes) }
      buffer.withUnsafeBytes { data.append(contentsOf: $0.prefix(count)) }
    }
    guard UInt64(data.count) == size,
          entry(path: path, name: before.name, attributes: try handleAttributes(handle, cancellation: cancellation)) == before,
          let after = try attributes(path, followLinks: false, cancellation: cancellation),
          entry(path: path, name: before.name, attributes: after) == before else { throw SFTPEditError.conflict(path) }
    return .init(entry: before, data: data)
  }

  public func writeFile(_ data: Data, to path: String, expected: SFTPFileSnapshot,
                        progress: @escaping SFTPProgressHandler = { _ in }) async throws -> SFTPFileSnapshot {
    guard data.count <= SFTPFileSnapshot.maximumEditorBytes else { throw SFTPEditError.tooLarge(SFTPFileSnapshot.maximumEditorBytes) }
    guard expected.entry.path == path else { throw SFTPError.invalidPath }
    return try await perform { client, cancellation in
      let current = try client.readSnapshot(path, maximumBytes: SFTPFileSnapshot.maximumEditorBytes, cancellation: cancellation)
      guard current == expected else { throw SFTPEditError.conflict(path) }
      guard let mode = expected.entry.permissions, let uid = expected.entry.ownerID, let gid = expected.entry.groupID else { throw SFTPEditError.missingMetadata }
      let temporary = try RemotePath.child(".termes-edit-\(UUID().uuidString).part", in: RemotePath.parent(path))
      let handle = try client.openHandle(temporary, flags: UInt(LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_EXCL), cancellation: cancellation)
      var open = true, committed = false
      defer {
        if open { client.cleanup { libssh2_sftp_close_handle(handle) } }
        if !committed, let sftp = client.sftp { client.cleanup { libssh2_sftp_unlink_ex(sftp, temporary, UInt32(temporary.utf8.count)) } }
      }
      var completed = 0
      progress(.init(completed: 0, total: UInt64(data.count)))
      while completed < data.count {
        let chunkEnd = min(data.count, completed + 64 * 1024)
        try data.withUnsafeBytes { bytes in
          while completed < chunkEnd {
            let count = try client.retry(cancellation) { libssh2_sftp_write(handle, bytes.baseAddress!.advanced(by: completed).assumingMemoryBound(to: CChar.self), chunkEnd - completed) }
            guard count >= 0 else { throw client.failure("保存文本") }
            if count == 0 { try client.ssh.waitSocket { try client.check(cancellation) }; continue }
            completed += count
          }
        }
        progress(.init(completed: UInt64(completed), total: UInt64(data.count)))
      }
      // Preserve ownership first, then mode (chown may clear setuid/setgid bits).
      var ownership = LIBSSH2_SFTP_ATTRIBUTES(); ownership.flags = UInt(LIBSSH2_SFTP_ATTR_UIDGID)
      ownership.uid = UInt(uid); ownership.gid = UInt(gid)
      let ownerResult = try client.retry(cancellation) { Int(libssh2_sftp_fstat_ex(handle, &ownership, 1)) }
      guard ownerResult == 0 else { throw client.failure("保留所有者和组") }
      var permissions = LIBSSH2_SFTP_ATTRIBUTES(); permissions.flags = UInt(LIBSSH2_SFTP_ATTR_PERMISSIONS); permissions.permissions = UInt(mode)
      let modeResult = try client.retry(cancellation) { Int(libssh2_sftp_fstat_ex(handle, &permissions, 1)) }
      guard modeResult == 0 else { throw client.failure("保留文件权限") }
      let staged = client.entry(path: path, name: expected.entry.name, attributes: try client.handleAttributes(handle, cancellation: cancellation))
      guard staged.permissions == mode, staged.ownerID == uid, staged.groupID == gid, staged.size == UInt64(data.count) else { throw SFTPEditError.missingMetadata }
      try client.closeHandle(handle, cancellation: cancellation); open = false
      // Compare full bytes again after staging, including same-size/same-time edits.
      guard try client.readSnapshot(path, maximumBytes: SFTPFileSnapshot.maximumEditorBytes, cancellation: cancellation) == expected else { throw SFTPEditError.conflict(path) }
      try client.move(temporary, to: path, overwrite: true, cancellation: cancellation)
      committed = true
      return .init(entry: staged, data: data)
    }
  }

  public func close() async {
    closing.cancel()
    _ = try? await ssh.run { [self] _ in
      if let sftp { cleanup { libssh2_sftp_shutdown(sftp) }; self.sftp = nil }
    }
    await owner.disconnect()
  }
}

extension SSHConnection {
  fileprivate func makeSFTPClient() async throws -> SFTPClient {
    guard let sshSession else { throw SFTPError.notConnected }
    return try await SFTPClient.open(on: sshSession, owner: self)
  }
}
