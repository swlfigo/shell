import Foundation
import CLibssh2
import Darwin

public struct SSHCommandOptions: Equatable, Sendable {
  /// Includes channel open, command startup and receiving output. Cleanup has a separate 0.5 s bound.
  public var timeout: TimeInterval
  /// Combined stdout and stderr limit, in bytes.
  public var maximumOutputBytes: Int

  public init(timeout: TimeInterval = 10, maximumOutputBytes: Int = 1024 * 1024) {
    self.timeout = timeout; self.maximumOutputBytes = maximumOutputBytes
  }

  fileprivate var isValid: Bool {
    timeout.isFinite && (0.05...300).contains(timeout) && (1...(32 * 1024 * 1024)).contains(maximumOutputBytes)
  }
}

public struct SSHCommandResult: Equatable, Sendable {
  public let stdout: Data
  public let stderr: Data
  /// libssh2 reports zero if a nonconforming server omits the exit-status request.
  public let exitStatus: Int32
  public let exitSignal: String?
}

public enum SSHCommandError: Error, Equatable, Sendable, LocalizedError {
  case invalidCommand, invalidOptions, timedOut, outputLimitExceeded

  public var errorDescription: String? {
    switch self {
    case .invalidCommand: return "SSH 命令为空、含 NUL 或超过 64 KiB。"
    case .invalidOptions: return "SSH 命令的时长或输出限制无效。"
    case .timedOut: return "SSH 命令执行超时。"
    case .outputLimitExceeded: return "SSH 命令输出超过限制。"
    }
  }
}

extension SSHConnection {
  /// Runs a command on a new non-PTY exec channel. No stdin is supplied; EOF is sent after startup.
  /// Nonzero exit status and stderr are returned to the caller, rather than treated as transport errors.
  /// Output is binary-safe. Cancellation/timeout requests TERM and closes just this channel; if cleanup
  /// cannot finish in 0.5 s, the transport is aborted. Monitoring should use a dedicated connection.
  public func execute(_ command: String, options: SSHCommandOptions = .init()) async throws -> SSHCommandResult {
    guard options.isValid else { throw SSHCommandError.invalidOptions }
    guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !command.utf8.contains(0), command.utf8.count <= 64 * 1024 else { throw SSHCommandError.invalidCommand }
    try Task.checkCancellation()
    guard let ssh = sshSession else { throw SSHError.disconnected }
    let cancellation = CommandCancellation(timeout: options.timeout)
    do {
      return try await withTaskCancellationHandler {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
          let operation = CommandOperation(ssh: ssh, command: command, options: options,
                                          cancellation: cancellation, completion: continuation)
          ssh.queue.async { operation.start() }
        }
      } onCancel: { cancellation.cancel() }
    } catch {
      // Clear the actor's connection and routed transports after a forced abort.
      // A late completion from an old session must never disconnect its replacement.
      if cancellation.transportAborted, sshSession === ssh { await disconnect() }
      throw error
    }
  }
}

private final class CommandCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  private var aborted = false
  private let deadline: UInt64
  init(timeout: TimeInterval) {
    deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
  }
  func cancel() { lock.withLock { cancelled = true } }
  var transportAborted: Bool { lock.withLock { aborted } }
  func markTransportAborted() { lock.withLock { aborted = true } }
  func check() throws {
    if lock.withLock({ cancelled }) { throw CancellationError() }
    if DispatchTime.now().uptimeNanoseconds >= deadline { throw SSHCommandError.timedOut }
  }
}

/// State and pointers are touched only on the session queue. Each read turn yields to other
/// channel pumps, writes and disconnect, including while a remote command is silent or floods output.
private final class CommandOperation: @unchecked Sendable {
  private enum Phase { case reading, waitingExit, signalling, closing, waitingClose, freeing }
  private let ssh: SSHSession
  private let command: String
  private let options: SSHCommandOptions
  private let cancellation: CommandCancellation
  private var completion: CheckedContinuation<SSHCommandResult, any Error>?
  private var channel: OpaquePointer?
  private var stdout = Data(), stderr = Data()
  private var phase: Phase = .reading
  private var failure: (any Error)?
  private var cleanupDeadline: UInt64 = 0
  private var exitStatus: Int32 = 0
  private var exitSignal: String?
  private var channelOpenPending = false
  private var commandStarted = false

  init(ssh: SSHSession, command: String, options: SSHCommandOptions,
       cancellation: CommandCancellation, completion: CheckedContinuation<SSHCommandResult, any Error>) {
    self.ssh = ssh; self.command = command; self.options = options
    self.cancellation = cancellation; self.completion = completion
  }

  private func check() throws { try cancellation.check(); try ssh.checkCancellation() }

  func start() {
    do {
      try check()
      guard let raw = ssh.session else { throw SSHError.disconnected }
      while channel == nil {
        try check()
        channel = libssh2_channel_open_ex(raw, "session", 7, 2 * 1024 * 1024, 32768, nil, 0)
        guard channel == nil else { channelOpenPending = false; break }
        channelOpenPending = libssh2_session_last_errno(raw) == LIBSSH2_ERROR_EAGAIN
        guard channelOpenPending else {
          throw SSHError.channelFailure("exec channel open: \(ssh.lastErrorMessage())")
        }
        try ssh.waitSocket(checkCancellation: cancellation.check)
      }
      let ch = channel!
      let bytes = Array(command.utf8CString)
      let rc = try retrying {
        bytes.withUnsafeBufferPointer {
          libssh2_channel_process_startup(ch, "exec", 4, $0.baseAddress, UInt32(bytes.count - 1))
        }
      }
      guard rc == 0 else { throw SSHError.channelFailure("exec start (\(rc)): \(ssh.lastErrorMessage())") }
      commandStarted = true
      let eof = try retrying { libssh2_channel_send_eof(ch) }
      guard eof == 0 else { throw SSHError.channelFailure("exec stdin EOF (\(eof)): \(ssh.lastErrorMessage())") }
      schedule()
    } catch {
      if channel == nil {
        // libssh2 may still have an unfinished channel-open state with no handle to release.
        // Leave no pending protocol request that a later command could accidentally reuse.
        if channelOpenPending { abortTransport() }
        finish(error)
      } else { beginCleanup(error) }
    }
  }

  private func retrying(_ call: () -> Int32) throws -> Int32 {
    while true {
      try check()
      let rc = call()
      if rc != LIBSSH2_ERROR_EAGAIN { return rc }
      try ssh.waitSocket(checkCancellation: cancellation.check)
    }
  }

  private func schedule() { ssh.queue.async { self.pump() } }

  private func pump() {
    guard completion != nil else { return }
    guard let ch = channel, ssh.session != nil else { finish(failure ?? SSHError.disconnected); return }
    if phase == .waitingExit {
      do {
        try check()
        let rc = libssh2_channel_wait_closed(ch)
        if rc == LIBSSH2_ERROR_EAGAIN { pollBriefly(); schedule(); return }
        guard rc == 0 else { throw SSHError.channelFailure("exec wait (\(rc))") }
        beginCleanup(nil)
      } catch { beginCleanup(error) }
      return
    }
    guard phase == .reading else { cleanup(ch); return }
    do {
      try check()
      var buffer = [CChar](repeating: 0, count: 32 * 1024)
      var consumed = 0
      // Alternate streams so a full stderr window cannot block a child writing both streams.
      for stream in [Int32(0), Int32(1)] {
        let count = libssh2_channel_read_ex(ch, stream, &buffer, buffer.count)
        if count > 0 {
          guard count <= options.maximumOutputBytes - stdout.count - stderr.count else {
            throw SSHCommandError.outputLimitExceeded
          }
          let bytes = buffer.withUnsafeBytes { Data($0.prefix(count)) }
          if stream == 0 { stdout.append(bytes) } else { stderr.append(bytes) }
          consumed += count
        } else if count < 0 && count != Int(LIBSSH2_ERROR_EAGAIN) {
          throw SSHError.channelFailure("exec read (\(count)): \(ssh.lastErrorMessage())")
        }
      }
      // A zero-length read means no currently buffered data; only channel EOF ends the command.
      if consumed == 0 && libssh2_channel_eof(ch) != 0 {
        // EOF closes the output streams, not necessarily the process. Keep the original
        // deadline while waiting for remote channel-close and its exit-status/signal.
        phase = .waitingExit; schedule(); return
      }
      if consumed == 0 { pollBriefly() }
      schedule()
    } catch { beginCleanup(error) }
  }

  private func beginCleanup(_ error: (any Error)?) {
    failure = error
    phase = error != nil && commandStarted ? .signalling : .closing
    cleanupDeadline = DispatchTime.now().uptimeNanoseconds + 500_000_000
    schedule()
  }

  private func cleanup(_ ch: OpaquePointer) {
    if DispatchTime.now().uptimeNanoseconds >= cleanupDeadline {
      abortTransport()
      channel = nil
      finish(failure ?? SSHError.channelFailure("exec channel cleanup timeout"))
      return
    }
    let rc: Int32
    switch phase {
    case .reading, .waitingExit: return
    case .signalling: rc = libssh2_channel_signal_ex(ch, "TERM", 4)
    case .closing: rc = libssh2_channel_close(ch)
    case .waitingClose: rc = libssh2_channel_wait_closed(ch)
    case .freeing: rc = libssh2_channel_free(ch)
    }
    if rc == LIBSSH2_ERROR_EAGAIN { pollBriefly(); schedule(); return }
    if phase == .signalling {
      // RFC 4254 permits servers to ignore signals. Sending TERM is best effort;
      // channel close and the cleanup deadline still apply if it is unsupported.
      phase = .closing; schedule(); return
    }
    if rc != 0 {
      abortTransport(); channel = nil
      finish(failure ?? SSHError.channelFailure("exec channel close (\(rc))"))
      return
    }
    switch phase {
    case .reading, .waitingExit, .signalling: break
    case .closing:
      // channel_close has completed the peer's close handshake. A cancelled peer
      // may close without sending EOF; wait_closed rejects that valid close.
      // No exit status is needed when returning an error, so release it directly.
      phase = failure == nil ? .waitingClose : .freeing
      schedule()
    case .waitingClose:
      exitStatus = libssh2_channel_get_exit_status(ch)
      var signal: UnsafeMutablePointer<CChar>?
      var length = 0
      if libssh2_channel_get_exit_signal(ch, &signal, &length, nil, nil, nil, nil) == 0,
         let signal, let raw = ssh.session {
        exitSignal = String(decoding: UnsafeRawBufferPointer(start: signal, count: min(length, 128)), as: UTF8.self)
        libssh2_free(raw, signal)
      }
      phase = .freeing; schedule()
    case .freeing: channel = nil; finish(failure)
    }
  }

  private func pollBriefly() {
    guard let raw = ssh.session else { return }
    let directions = libssh2_session_block_directions(raw)
    var events = Int16(POLLIN)
    if directions & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0 { events |= Int16(POLLOUT) }
    var pfd = pollfd(fd: ssh.socketFD, events: events, revents: 0)
    _ = poll(&pfd, 1, 20)
  }

  private func finish(_ error: (any Error)?) {
    guard let completion else { return }
    self.completion = nil
    if let error { completion.resume(throwing: error) }
    else { completion.resume(returning: .init(stdout: stdout, stderr: stderr, exitStatus: exitStatus, exitSignal: exitSignal)) }
  }

  private func abortTransport() {
    cancellation.markTransportAborted()
    ssh.abortCommandTransport()
  }
}
