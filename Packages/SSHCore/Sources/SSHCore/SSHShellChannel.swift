import Foundation
import CLibssh2

#if canImport(Darwin)
import Darwin
#endif

/// PTY shell channel. All libssh2 calls run on the owning SSHSession's serial queue.
/// A pump task re-schedules itself on that queue: it drains channel reads until EAGAIN,
/// then poll()s the socket for a short interval, so send/resize/close (also queued) interleave.
public final class SSHShellChannel: ShellChannel, @unchecked Sendable {
  public let output: AsyncStream<Data>
  private let continuation: AsyncStream<Data>.Continuation
  private let ssh: SSHSession
  private var channel: OpaquePointer?     // LIBSSH2_CHANNEL*, queue only
  private var finished = false            // queue only
  private var lastKeepalive = Date()      // queue only
  private static let keepaliveCheckInterval: TimeInterval = 5

  private let lock = NSLock()
  private var _closingLocally = false
  /// 是否本地主动关闭(用于区分主动断开 vs 对端掉线)。
  public var isClosingLocally: Bool { lock.withLock { _closingLocally } }

  /// Why the output stream ended (nil while open).
  public enum CloseReason: Sendable, Equatable {
    case localClose        // we closed it
    case remoteExit        // peer sent channel EOF (e.g. user typed `exit`)
    case droppedConnection // transport died / read error / keepalive failure
  }
  private var _closeReason: CloseReason?
  public var closeReason: CloseReason? { lock.withLock { _closeReason } }

  init(ssh: SSHSession, channel: OpaquePointer) {
    let (stream, continuation) = AsyncStream<Data>.makeStream(of: Data.self)
    self.output = stream
    self.continuation = continuation
    self.ssh = ssh
    self.channel = channel
  }

  /// Open channel + PTY + shell. Throws SSHError.channelFailure on failure.
  static func open(on ssh: SSHSession, cols: Int, rows: Int, progress: SSHProgressReporter? = nil) async throws -> SSHShellChannel {
    progress?.send(.channel, .started)
    do {
      let ch: SSHShellChannel = try await ssh.run { sess in
        guard let s = sess.session else { throw SSHError.disconnected }
        var chan: OpaquePointer?
        while true {
          chan = libssh2_channel_open_ex(s, "session", 7, 2 * 1024 * 1024,
                                         32768, nil, 0)
          if chan != nil { break }
          if libssh2_session_last_errno(s) == LIBSSH2_ERROR_EAGAIN { try sess.waitSocket(); continue }
          throw SSHError.channelFailure("channel open: \(sess.lastErrorMessage())")
        }
        let c = chan!
        progress?.send(.channel, .succeeded)
        func fail(_ what: String, _ rc: Int32) -> SSHError {
          let m = sess.lastErrorMessage()
          _ = try? sess.retrying { libssh2_channel_free(c) }
          return SSHError.channelFailure("\(what) (\(rc)): \(m)")
        }
        do {
          progress?.send(.pty, .started)
          let rc1 = try sess.retrying {
            libssh2_channel_request_pty_ex(c, "xterm-256color", 14, nil, 0, Int32(cols), Int32(rows), 0, 0)
          }
          if rc1 != 0 { throw fail("pty request", rc1) }
          progress?.send(.pty, .succeeded)
          progress?.send(.shell, .started)
          let rc2 = try sess.retrying { libssh2_channel_process_startup(c, "shell", 5, nil, 0) }
          if rc2 != 0 { throw fail("shell start", rc2) }
          progress?.send(.shell, .succeeded)
        } catch let e as SSHError { throw e }
        return SSHShellChannel(ssh: sess, channel: c)
      }
      ch.schedulePump()
      return ch
    } catch { progress?.fail(error); throw error }
  }

  // MARK: - Event loop (queue only)

  private func schedulePump() {
    ssh.queue.async { [weak self] in self?.pump() }
  }

  private func pump() {
    guard !finished else { return }
    guard let ch = channel, ssh.session != nil else { teardown(.droppedConnection); return }
    if Date().timeIntervalSince(lastKeepalive) >= Self.keepaliveCheckInterval {
      lastKeepalive = Date()
      var next: Int32 = 0
      let krc = libssh2_keepalive_send(ssh.session, &next)
      // Non-zero and not EAGAIN: transport is dead -> treat as dropped connection.
      if krc != 0 && krc != LIBSSH2_ERROR_EAGAIN { teardown(.droppedConnection); return }
    }
    var buf = [CChar](repeating: 0, count: 32 * 1024)
    var gotData = false
    var total = 0
    while true {
      let n = libssh2_channel_read_ex(ch, 0, &buf, buf.count)
      if n > 0 {
        gotData = true
        total += n
        let d = buf.withUnsafeBytes { Data($0.prefix(n)) }
        continuation.yield(d)
        // Cap per-turn work so send/resize/close queued behind us get to run.
        if total >= 256 * 1024 { schedulePump(); return }
        continue
      }
      if n == Int(LIBSSH2_ERROR_EAGAIN) { break }
      // 0 = EOF from peer (normal exit); negative = transport/read error.
      teardown(n == 0 || libssh2_channel_eof(ch) != 0 ? .remoteExit : .droppedConnection); return
    }
    if libssh2_channel_eof(ch) != 0 { teardown(.remoteExit); return }
    if !gotData {
      var pfd = pollfd(fd: ssh.socketFD, events: Int16(POLLIN), revents: 0)
      let pr = poll(&pfd, 1, 20)
      if pr > 0 && (pfd.revents & Int16(POLLERR | POLLHUP | POLLNVAL)) != 0 && (pfd.revents & Int16(POLLIN)) == 0 {
        teardown(.droppedConnection); return
      }
    }
    schedulePump()
  }

  /// Queue only. Idempotent: finishes output and releases the channel.
  private func teardown(_ reason: CloseReason) {
    guard !finished else { return }
    finished = true
    lock.withLock { _closeReason = _closingLocally ? .localClose : reason }
    if let ch = channel, ssh.session != nil {
      var tries = 0
      while libssh2_channel_close(ch) == LIBSSH2_ERROR_EAGAIN, tries < 10 {
        tries += 1
        var pfd = pollfd(fd: ssh.socketFD, events: Int16(POLLIN | POLLOUT), revents: 0)
        _ = poll(&pfd, 1, 100)
      }
      tries = 0
      while libssh2_channel_free(ch) == LIBSSH2_ERROR_EAGAIN, tries < 10 {
        tries += 1
        var pfd = pollfd(fd: ssh.socketFD, events: Int16(POLLIN | POLLOUT), revents: 0)
        _ = poll(&pfd, 1, 100)
      }
    }
    channel = nil
    continuation.finish()
  }

  // MARK: - ShellChannel

  public func send(_ data: Data) async {
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
      ssh.queue.async { [self] in
        defer { c.resume() }
        guard !finished, let ch = channel, ssh.session != nil else { return }
        var offset = 0
        let bytes = [UInt8](data)
        while offset < bytes.count {
          let n = bytes.withUnsafeBufferPointer { p in
            libssh2_channel_write_ex(ch, 0, p.baseAddress! + offset, bytes.count - offset)
          }
          if n >= 0 { offset += n; continue }
          if n == Int(LIBSSH2_ERROR_EAGAIN) {
            do { try ssh.waitSocket() } catch { teardown(.droppedConnection); return }
            continue
          }
          teardown(.droppedConnection); return
        }
      }
    }
  }

  public func resize(cols: Int, rows: Int) async {
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
      ssh.queue.async { [self] in
        defer { c.resume() }
        guard !finished, let ch = channel, ssh.session != nil else { return }
        do {
          _ = try ssh.retrying { libssh2_channel_request_pty_size_ex(ch, Int32(cols), Int32(rows), 0, 0) }
        } catch { teardown(.droppedConnection) }
      }
    }
  }

  public func close() async {
    lock.withLock { _closingLocally = true }
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
      ssh.queue.async { [self] in teardown(.localClose); c.resume() }
    }
  }
}

extension SSHConnection {
  public func openShell(cols: Int, rows: Int) async throws -> ShellChannel {
    guard let s = sshSession else { throw SSHError.disconnected }
    return try await SSHShellChannel.open(on: s, cols: cols, rows: rows, progress: progressReporter)
  }
}
