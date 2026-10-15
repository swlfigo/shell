import Foundation
import CLibssh2

#if canImport(Darwin)
import Darwin
#endif

/// Wraps a libssh2 session. libssh2 sessions are not thread-safe, so every libssh2 call
/// runs on this object's dedicated serial queue. The session is non-blocking; EAGAIN is
/// handled by poll()ing the socket in the direction libssh2 requests.
final class SSHSession: @unchecked Sendable {
  private static let initOnce: Int32 = libssh2_init(0)

  let queue: DispatchQueue
  private(set) var session: OpaquePointer?   // LIBSSH2_SESSION*
  private(set) var socketFD: Int32 = -1
  private var closing = false
  private let cancellationLock = NSLock()
  private var cancelled = false
  private let timeoutMs: Int32

  init(label: String = "sshcore.session", timeoutMs: Int32 = 15_000) {
    self.queue = DispatchQueue(label: label + "." + UUID().uuidString)
    self.timeoutMs = timeoutMs
  }

  deinit { closeNow() }

  /// May be called off the session queue to interrupt a pending connect/auth/channel open.
  func cancelPendingOperations() { cancellationLock.withLock { cancelled = true } }
  func checkCancellation() throws {
    if cancellationLock.withLock({ cancelled }) { throw CancellationError() }
  }

  /// Run a body on the session queue and bridge to async.
  func run<T: Sendable>(_ body: @escaping @Sendable (SSHSession) throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { cont in
      queue.async {
        do { try self.checkCancellation(); cont.resume(returning: try body(self)) }
        catch { cont.resume(throwing: error) }
      }
    }
  }

  // MARK: - Socket

  /// Queue only. The remote forwarding connector uses the same cancellable TCP
  /// connect implementation, then transfers ownership without creating an SSH session.
  func detachUnnegotiatedSocket() throws -> Int32 {
    try checkCancellation()
    guard session == nil, !closing, socketFD >= 0 else { throw SSHError.disconnected }
    let fd = socketFD
    socketFD = -1
    return fd
  }

  /// Must be called on the queue.
  func openSocket(host: String, port: Int) throws {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM
    var res: UnsafeMutablePointer<addrinfo>?
    let gai = getaddrinfo(host, String(port), &hints, &res)
    guard gai == 0, let first = res else {
      throw SSHError.connectionFailed("resolve \(host): \(String(cString: gai_strerror(gai)))")
    }
    defer { freeaddrinfo(res) }

    var lastErr = "no address"
    var cur: UnsafeMutablePointer<addrinfo>? = first
    while let ai = cur {
      try checkCancellation()
      cur = ai.pointee.ai_next
      let fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
      if fd < 0 { lastErr = String(cString: strerror(errno)); continue }
      var one: Int32 = 1
      setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
      setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
      let flags = fcntl(fd, F_GETFL, 0)
      _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

      var rc = Darwin.connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen)
      if rc != 0 && errno == EINPROGRESS {
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutMs) * 1_000_000
        do {
          while true {
            try checkCancellation()
            let pr = poll(&pfd, 1, min(timeoutMs, 100))
            if pr > 0 {
              var soErr: Int32 = 0
              var len = socklen_t(MemoryLayout<Int32>.size)
              getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len)
              if soErr == 0 { rc = 0 } else { errno = soErr }
              break
            }
            if pr < 0 && errno != EINTR { break }
            if DispatchTime.now().uptimeNanoseconds >= deadline { errno = ETIMEDOUT; break }
          }
        } catch { Darwin.close(fd); throw error }
      }
      if rc == 0 { socketFD = fd; return }
      lastErr = String(cString: strerror(errno))
      Darwin.close(fd)
    }
    throw SSHError.connectionFailed("connect \(host):\(port): \(lastErr)")
  }

  /// Wait on the socket in the direction libssh2 needs. Must be called on the queue.
  func waitSocket(checkCancellation: () throws -> Void = {}) throws {
    guard let session, !closing else { throw SSHError.disconnected }
    let dir = libssh2_session_block_directions(session)
    var events: Int16 = 0
    if dir & LIBSSH2_SESSION_BLOCK_INBOUND != 0 { events |= Int16(POLLIN) }
    if dir & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0 { events |= Int16(POLLOUT) }
    if events == 0 { events = Int16(POLLIN | POLLOUT) }
    var pfd = pollfd(fd: socketFD, events: events, revents: 0)
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutMs) * 1_000_000
    while true {
      try self.checkCancellation()
      try checkCancellation()
      let pr = poll(&pfd, 1, min(timeoutMs, 100))
      if pr > 0 { return }
      if pr < 0 && errno != EINTR { throw SSHError.connectionFailed(String(cString: strerror(errno))) }
      if DispatchTime.now().uptimeNanoseconds >= deadline { throw SSHError.connectionFailed("timeout") }
    }
  }

  /// Retry a libssh2 call while it returns EAGAIN. Must be called on the queue.
  func retrying(_ call: () -> Int32) throws -> Int32 {
    while true {
      try checkCancellation()
      let rc = call()
      if rc != LIBSSH2_ERROR_EAGAIN { return rc }
      try waitSocket()
    }
  }

  // MARK: - Handshake / host key / auth (queue only)

  func handshake() throws {
    _ = SSHSession.initOnce
    guard let s = libssh2_session_init_ex(nil, nil, nil, nil) else {
      throw SSHError.connectionFailed("libssh2 session init failed")
    }
    session = s
    libssh2_session_set_blocking(s, 0)
    let fd = socketFD
    let rc = try retrying { libssh2_session_handshake(s, fd) }
    if rc != 0 { throw SSHError.connectionFailed("handshake failed (\(rc)): \(lastErrorMessage())") }
    // Keepalive: ask the server for a reply; the shell channel pump sends them periodically.
    libssh2_keepalive_config(s, 1, 15)
  }

  func hostKey() throws -> (type: String, blob: Data) {
    guard let s = session else { throw SSHError.disconnected }
    var len = 0
    var type: Int32 = 0
    guard let kp = libssh2_session_hostkey(s, &len, &type), len > 0 else {
      throw SSHError.connectionFailed("no host key")
    }
    let blob = Data(bytes: kp, count: len)
    let name: String
    switch type {
    case LIBSSH2_HOSTKEY_TYPE_ED25519: name = "ssh-ed25519"
    case LIBSSH2_HOSTKEY_TYPE_ECDSA_256: name = "ecdsa-sha2-nistp256"
    case LIBSSH2_HOSTKEY_TYPE_ECDSA_384: name = "ecdsa-sha2-nistp384"
    case LIBSSH2_HOSTKEY_TYPE_ECDSA_521: name = "ecdsa-sha2-nistp521"
    case LIBSSH2_HOSTKEY_TYPE_RSA: name = "ssh-rsa"
    default: throw SSHError.connectionFailed("unsupported host key type (\(type))")
    }
    return (name, blob)
  }

  func authPassword(user: String, password: String) throws {
    guard let s = session else { throw SSHError.disconnected }
    let u = Array(user.utf8CString), p = Array(password.utf8CString)
    let rc = try retrying {
      libssh2_userauth_password_ex(s, u, UInt32(u.count - 1), p, UInt32(p.count - 1), nil)
    }
    // Socket-level / protocol errors (e.g. server closed an idle connection during
    // host-key confirmation) are connection failures, not rejected credentials.
    try classifyAuth(rc)
  }

  /// Public-key auth from in-memory private key (RSA / ed25519 / ecdsa, optionally encrypted).
  /// The public key is derived from the private key by libssh2.
  func authPublicKey(user: String, privateKey: Data, passphrase: String?) throws {
    guard let s = session else { throw SSHError.disconnected }
    let u = Array(user.utf8CString)
    // libssh2 expects a NUL-terminated key blob for PEM parsing; include the terminator.
    var key = [CChar](repeating: 0, count: privateKey.count + 1)
    privateKey.withUnsafeBytes { raw in
      for (i, b) in raw.enumerated() { key[i] = CChar(bitPattern: b) }
    }
    // Always pass a non-nil passphrase ("" when absent): a nil passphrase can make OpenSSL
    // fall back to prompting on /dev/tty for encrypted keys, hanging the session queue.
    let pass: [CChar] = Array((passphrase ?? "").utf8CString)
    let rc = try retrying {
      key.withUnsafeBufferPointer { kp in
        pass.withUnsafeBufferPointer { pp in
          libssh2_userauth_publickey_frommemory(s, u, u.count - 1, nil, 0,
                                                kp.baseAddress, privateKey.count, pp.baseAddress)
        }
      }
    }
    try classifyAuth(rc)
  }

  private func classifyAuth(_ rc: Int32) throws {
    switch rc {
    case 0: return
    case LIBSSH2_ERROR_AUTHENTICATION_FAILED, LIBSSH2_ERROR_PUBLICKEY_UNVERIFIED,
         LIBSSH2_ERROR_PASSWORD_EXPIRED, LIBSSH2_ERROR_FILE, LIBSSH2_ERROR_KEYFILE_AUTH_FAILED,
         LIBSSH2_ERROR_PUBLICKEY_PROTOCOL:
      throw SSHError.authenticationFailed
    default:
      throw SSHError.connectionFailed("authentication aborted (\(rc)): \(lastErrorMessage())")
    }
  }

  func lastErrorMessage() -> String {
    guard let s = session else { return "" }
    var msg: UnsafeMutablePointer<CChar>?
    var len: Int32 = 0
    _ = libssh2_session_last_error(s, &msg, &len, 0)
    return msg.map { String(cString: $0) } ?? ""
  }

  // MARK: - Teardown

  func close() async {
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
      queue.async { self.closeNow(); c.resume() }
    }
  }

  /// Queue only; dedicated forwarding transports have no other channel owners to preserve.
  func abortTransport() {
    cancelPendingOperations()
    if socketFD >= 0 { Darwin.shutdown(socketFD, SHUT_RDWR) }
  }

  /// Queue only. A command whose protocol state cannot be released must not leave a
  /// half-open channel attached to a usable session. A monitoring transport is dedicated.
  func abortCommandTransport() { abortTransport(); closeNow() }

  /// Queue only (or deinit).
  private func closeNow() {
    if closing && session == nil && socketFD < 0 { return }
    closing = true
    if cancellationLock.withLock({ cancelled }), socketFD >= 0 { Darwin.shutdown(socketFD, SHUT_RDWR) }
    if let s = session {
      // Non-blocking disconnect: best effort, bounded attempts.
      var tries = 0
      while libssh2_session_disconnect_ex(s, SSH_DISCONNECT_BY_APPLICATION, "bye", "") == LIBSSH2_ERROR_EAGAIN, tries < 20 {
        tries += 1
        var pfd = pollfd(fd: socketFD, events: Int16(POLLIN | POLLOUT), revents: 0)
        _ = poll(&pfd, 1, 100)
      }
      libssh2_session_free(s)
      session = nil
    }
    if socketFD >= 0 { Darwin.close(socketFD); socketFD = -1 }
  }
}
