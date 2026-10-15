import Foundation
import CLibssh2
import Darwin

/// A loopback-only TCP/SOCKS5 listener with a dedicated SSH control transport. Each accepted client
/// gets its own SSH transport so a slow target or backpressure cannot block other clients
/// or the interactive terminal. All libssh2 calls stay on their session's serial queue.
public final class LocalPortForward: LocalForwarding, @unchecked Sendable {
  public let localPort: Int
  public let events: AsyncStream<LocalForwardEvent>
  private let resources: ForwardResources
  private let config: ConnectionConfig
  private let knownHosts: KnownHostsStoring
  private let target: LocalForwardConfiguration
  private let networkEndpoint: SSHNetworkEndpoint?

  private init(resources: ForwardResources, localPort: Int, config: ConnectionConfig,
               knownHosts: KnownHostsStoring, target: LocalForwardConfiguration,
               events: AsyncStream<LocalForwardEvent>, networkEndpoint: SSHNetworkEndpoint?) {
    self.resources = resources; self.localPort = localPort
    self.config = config; self.knownHosts = knownHosts; self.target = target; self.events = events
    self.networkEndpoint = networkEndpoint
  }

  public static func start(config: ConnectionConfig, knownHosts: KnownHostsStoring,
                           forwarding: LocalForwardConfiguration) async throws -> LocalPortForward {
    try await startRouted(config: config, knownHosts: knownHosts, forwarding: forwarding,
                          networkEndpoint: nil, confirmUnknownHostKey: { _, _, _ in false })
  }

  /// A hop's actual identity stays in config; only its TCP destination uses the prior tunnel.
  static func startRouted(config: ConnectionConfig, knownHosts: KnownHostsStoring,
                          forwarding: LocalForwardConfiguration, networkEndpoint: SSHNetworkEndpoint?,
                          confirmUnknownHostKey: @escaping HostKeyConfirm,
                          progressReporter: SSHProgressReporter? = nil) async throws -> LocalPortForward {
    try forwarding.validate()
    guard forwarding.kind != .remote else { throw LocalForwardError.invalidConfiguration }
    try Task.checkCancellation()
    let owner = SSHConnection(config: config, knownHosts: knownHosts,
                              confirmUnknownHostKey: confirmUnknownHostKey, networkEndpoint: networkEndpoint,
                              progressReporter: progressReporter)
    do {
      try await owner.connect()
      progressReporter?.send(.route, .started)
      let forward = try await owner.makeLocalForward(config: config, knownHosts: knownHosts,
                                                     target: forwarding, networkEndpoint: networkEndpoint)
      if Task.isCancelled { await forward.stop(); throw CancellationError() }
      progressReporter?.send(.route, .succeeded)
      forward.schedulePump()
      return forward
    } catch { progressReporter?.fail(error); await owner.disconnect(); throw error }
  }

  fileprivate static func open(ssh: SSHSession, owner: SSHConnection, config: ConnectionConfig,
                               knownHosts: KnownHostsStoring, target: LocalForwardConfiguration,
                               networkEndpoint: SSHNetworkEndpoint?) async throws -> LocalPortForward {
    try await withTaskCancellationHandler {
      try await ssh.run { session in
        guard let raw = session.session else { throw LocalForwardError.notConnected }
        // A session channel with no PTY/process lets the control pump consume keepalive
        // replies and detect transport loss even while no local clients are connected.
        var control: OpaquePointer?
        while control == nil {
          control = libssh2_channel_open_ex(raw, "session", 7, 65536, 32768, nil, 0)
          if control != nil { break }
          guard libssh2_session_last_errno(raw) == LIBSSH2_ERROR_EAGAIN else {
            throw LocalForwardError.transport(session.lastErrorMessage())
          }
          try session.waitSocket()
        }
        do {
          let (listener, port) = try ForwardSocket.listen(port: target.localPort)
          let (events, continuation) = AsyncStream<LocalForwardEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
          let resources = ForwardResources(ssh: session, owner: owner, control: control!, listener: listener,
                                           continuation: continuation)
          return LocalPortForward(resources: resources, localPort: port, config: config,
                                   knownHosts: knownHosts, target: target, events: events, networkEndpoint: networkEndpoint)
        } catch {
          _ = libssh2_channel_free(control!)
          throw error
        }
      }
    } onCancel: { ssh.cancelPendingOperations() }
  }

  deinit {
    let resources = resources
    resources.ssh.queue.async { resources.finish(error: nil) }
  }

  public func stop() async {
    let resources = resources
    let cleanup: Task<Void, Never>? = await withCheckedContinuation { continuation in
      resources.ssh.queue.async {
        resources.finish(error: nil)
        continuation.resume(returning: resources.cleanup)
      }
    }
    // A transport failure may already have begun cleanup. Wait for that same task,
    // including authenticating clients, before the UI can restart this rule.
    await cleanup?.value
  }

  private func schedulePump() {
    resources.ssh.queue.async { [weak self] in self?.pump() }
  }

  private func pump() {
    let r = resources
    guard !r.finished, let control = r.control, r.ssh.session != nil else { return }
    var byte: CChar = 0
    let read = libssh2_channel_read_ex(control, 0, &byte, 1)
    if (read < 0 && read != Int(LIBSSH2_ERROR_EAGAIN)) || libssh2_channel_eof(control) != 0 {
      r.finish(error: LocalForwardError.transport(r.ssh.lastErrorMessage()).localizedDescription)
      return
    }
    if Date().timeIntervalSince(r.lastKeepalive) >= 5 {
      r.lastKeepalive = Date()
      var next: Int32 = 0
      let result = libssh2_keepalive_send(r.ssh.session, &next)
      if result != 0 && result != LIBSSH2_ERROR_EAGAIN {
        r.finish(error: LocalForwardError.transport(r.ssh.lastErrorMessage()).localizedDescription)
        return
      }
    }
    for _ in 0..<16 {
      var address = sockaddr_in()
      var length = socklen_t(MemoryLayout<sockaddr_in>.size)
      let fd = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(r.listener, $0, &length) }
      }
      guard fd >= 0 else {
        if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
          r.finish(error: LocalForwardError.listen(String(cString: strerror(errno))).localizedDescription)
          return
        }
        break
      }
      guard r.peers.count < 32 else {
        Darwin.close(fd)
        r.continuation.yield(.clientError(LocalForwardError.tooManyClients.localizedDescription))
        continue
      }
      do { try ForwardSocket.configure(fd) }
      catch { Darwin.close(fd); r.continuation.yield(.clientError(error.localizedDescription)); continue }
      let id = UUID()
      let peer = ForwardPeer(socket: ForwardSocket(fd), config: config, knownHosts: knownHosts, target: target,
                             originPort: Int(UInt16(bigEndian: address.sin_port)), networkEndpoint: networkEndpoint) { [weak self] error in
        guard let self else { return }
        self.resources.ssh.queue.async { [weak self] in
          guard let self, !self.resources.finished else { return }
          self.resources.peers.removeValue(forKey: id)
          self.resources.continuation.yield(.clients(self.resources.peers.count))
          if let error { self.resources.continuation.yield(.clientError(error)) }
        }
      }
      r.peers[id] = peer
      r.continuation.yield(.clients(r.peers.count))
      peer.start()
    }
    var polls = [pollfd(fd: r.listener, events: Int16(POLLIN), revents: 0),
                 pollfd(fd: r.ssh.socketFD, events: Int16(POLLIN), revents: 0)]
    _ = poll(&polls, 2, 20)
    schedulePump()
  }
}

extension SSHConnection {
  fileprivate func makeLocalForward(config: ConnectionConfig, knownHosts: KnownHostsStoring,
                                    target: LocalForwardConfiguration, networkEndpoint: SSHNetworkEndpoint?) async throws -> LocalPortForward {
    guard let ssh = sshSession else { throw LocalForwardError.notConnected }
    return try await LocalPortForward.open(ssh: ssh, owner: self, config: config, knownHosts: knownHosts, target: target,
                                          networkEndpoint: networkEndpoint)
  }
}

private final class ForwardResources: @unchecked Sendable {
  let ssh: SSHSession
  let owner: SSHConnection
  let continuation: AsyncStream<LocalForwardEvent>.Continuation
  var control: OpaquePointer?
  var listener: Int32
  var peers: [UUID: ForwardPeer] = [:]
  var finished = false
  var cleanup: Task<Void, Never>?
  var lastKeepalive = Date()

  init(ssh: SSHSession, owner: SSHConnection, control: OpaquePointer, listener: Int32,
       continuation: AsyncStream<LocalForwardEvent>.Continuation) {
    self.ssh = ssh; self.owner = owner; self.control = control
    self.listener = listener; self.continuation = continuation
  }

  /// Session queue only. Closing the listener is immediate; pending clients are cancelled too.
  func finish(error: String?) {
    guard !finished else { return }
    finished = true
    if listener >= 0 { Darwin.close(listener); listener = -1 }
    let peers = Array(peers.values)
    self.peers.removeAll()
    for peer in peers { peer.requestStop() }
    ssh.abortTransport()
    if let control, ssh.session != nil { _ = libssh2_channel_free(control) }
    control = nil
    continuation.yield(.stopped(error: error))
    continuation.finish()
    let owner = owner
    cleanup = Task {
      await withTaskGroup(of: Void.self) { group in
        for peer in peers { group.addTask { await peer.close() } }
      }
      await owner.disconnect()
    }
  }
}

/// Protects local socket ownership against stop during SSH authentication/pump activity.
final class ForwardSocket: @unchecked Sendable {
  private let lock = NSLock()
  private var fd: Int32
  init(_ fd: Int32) { self.fd = fd }
  deinit { close() }
  func withFD<T>(_ body: (Int32) throws -> T) rethrows -> T { try lock.withLock { try body(fd) } }
  func close() {
    lock.withLock {
      if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR); Darwin.close(fd); fd = -1 }
    }
  }
  static func configure(_ fd: Int32) throws {
    guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK) >= 0 else {
      throw LocalForwardError.listen(String(cString: strerror(errno)))
    }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
  }
  static func listen(port: Int) throws -> (Int32, Int) {
    let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw LocalForwardError.listen(String(cString: strerror(errno))) }
    do {
      try configure(fd)
      var one: Int32 = 1
      setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
      var address = sockaddr_in()
      address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      address.sin_family = sa_family_t(AF_INET)
      address.sin_port = UInt16(port).bigEndian
      address.sin_addr.s_addr = inet_addr("127.0.0.1")
      let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
      }
      guard result == 0, Darwin.listen(fd, 32) == 0 else {
        throw LocalForwardError.listen(String(cString: strerror(errno)))
      }
      var length = socklen_t(MemoryLayout<sockaddr_in>.size)
      let named = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
      }
      guard named == 0 else { throw LocalForwardError.listen(String(cString: strerror(errno))) }
      return (fd, Int(UInt16(bigEndian: address.sin_port)))
    } catch { Darwin.close(fd); throw error }
  }
}

private final class ForwardPeer: @unchecked Sendable {
  let socket: ForwardSocket
  private let config: ConnectionConfig
  private let knownHosts: KnownHostsStoring
  private let target: LocalForwardConfiguration
  private let networkEndpoint: SSHNetworkEndpoint?
  private let originPort: Int
  private let onFinish: @Sendable (String?) -> Void
  private let lock = NSLock()
  private var cancelled = false
  private var task: Task<Void, Never>?
  private var bridge: DirectTCPBridge?

  init(socket: ForwardSocket, config: ConnectionConfig, knownHosts: KnownHostsStoring,
       target: LocalForwardConfiguration, originPort: Int, networkEndpoint: SSHNetworkEndpoint?, onFinish: @escaping @Sendable (String?) -> Void) {
    self.socket = socket; self.config = config; self.knownHosts = knownHosts
    self.target = target; self.originPort = originPort; self.onFinish = onFinish
    self.networkEndpoint = networkEndpoint
  }
  func start() {
    lock.withLock {
      guard !cancelled else { return }
      task = Task { await self.connect() }
    }
  }
  private func connect() async {
    let owner = SSHConnection(config: config, knownHosts: knownHosts, confirmUnknownHostKey: { _, _, _ in false },
                              networkEndpoint: networkEndpoint)
    var requestAccepted = false
    var pendingBridge: DirectTCPBridge?
    do {
      let destination: LocalForwardConfiguration
      if target.kind == .socks {
        let endpoint = try await SOCKS5Handshake.negotiate(socket: socket)
        requestAccepted = true
        destination = .init(localPort: target.localPort, targetHost: endpoint.host, targetPort: endpoint.port)
      } else { destination = target }
      try Task.checkCancellation()
      try await owner.connect()
      try Task.checkCancellation()
      let bridge = try await owner.makeDirectBridge(socket: socket, target: destination, originPort: originPort,
                                                     onFinish: onFinish)
      pendingBridge = bridge
      if target.kind == .socks {
        try await SOCKS5Handshake.reply(socket: socket, code: 0)
        requestAccepted = false
      }
      try Task.checkCancellation()
      let accepted = lock.withLock { () -> Bool in
        if cancelled { return false }
        self.bridge = bridge
        return true
      }
      if accepted { bridge.start() } else { await bridge.close() }
    } catch {
      if requestAccepted, !lock.withLock({ cancelled }) {
        // libssh2 exposes channel-open text, not a portable socket errno. Report a
        // general failure rather than inventing a refusal/network-unreachable reason.
        try? await SOCKS5Handshake.reply(socket: socket, code: 1)
      }
      socket.close()
      await pendingBridge?.close()
      await owner.disconnect()
      if !lock.withLock({ cancelled }) { onFinish(Self.message(error)) }
    }
  }
  func requestStop() {
    let task = lock.withLock { cancelled = true; return self.task }
    task?.cancel()
    socket.close()
  }
  func close() async {
    requestStop()
    let task = lock.withLock { self.task }
    await task?.value
    let bridge = lock.withLock { self.bridge }
    await bridge?.close()
  }
  static func message(_ error: Error) -> String {
    if let error = error as? SSHError {
      switch error {
      case .hostKeyRejected: return "转发 SSH 主机密钥未受信任，请重新连接终端。"
      case .hostKeyMismatch: return "转发 SSH 主机密钥已变化，请检查服务器。"
      case .authenticationFailed: return "转发 SSH 认证失败。"
      case .connectionFailed(let message), .channelFailure(let message): return LocalForwardError.target(message).localizedDescription
      case .disconnected: return LocalForwardError.notConnected.localizedDescription
      }
    }
    return error.localizedDescription
  }
}

/// Stable storage is required across libssh2 EAGAIN retries, including pointer and size.
final class ForwardBuffer {
  let bytes = UnsafeMutablePointer<CChar>.allocate(capacity: 65536)
  let capacity = 65536
  var count = 0
  var offset = 0
  var remaining: Int { count - offset }
  func consume(_ amount: Int) {
    offset += amount
    if offset == count { offset = 0; count = 0 }
  }
  deinit { bytes.deallocate() }
}

private final class DirectTCPBridge: @unchecked Sendable {
  private let ssh: SSHSession
  private let owner: SSHConnection
  private let socket: ForwardSocket
  private let onFinish: @Sendable (String?) -> Void
  private var channel: OpaquePointer?
  private let outbound = ForwardBuffer()
  private let inbound = ForwardBuffer()
  private var localEOF = false
  private var sentEOF = false
  private var remoteEOF = false
  private var finished = false
  private var lastKeepalive = Date()

  init(ssh: SSHSession, owner: SSHConnection, socket: ForwardSocket, channel: OpaquePointer,
       onFinish: @escaping @Sendable (String?) -> Void) {
    self.ssh = ssh; self.owner = owner; self.socket = socket
    self.channel = channel; self.onFinish = onFinish
  }

  static func open(ssh: SSHSession, owner: SSHConnection, socket: ForwardSocket,
                   target: LocalForwardConfiguration, originPort: Int,
                   onFinish: @escaping @Sendable (String?) -> Void) async throws -> DirectTCPBridge {
    try await withTaskCancellationHandler {
      try await ssh.run { session in
        guard let raw = session.session else { throw LocalForwardError.notConnected }
        while true {
          if let channel = libssh2_channel_direct_tcpip_ex(raw, target.targetHost, Int32(target.targetPort),
                                                          "127.0.0.1", Int32(originPort)) {
            return DirectTCPBridge(ssh: session, owner: owner, socket: socket, channel: channel, onFinish: onFinish)
          }
          guard libssh2_session_last_errno(raw) == LIBSSH2_ERROR_EAGAIN else {
            throw LocalForwardError.target(session.lastErrorMessage())
          }
          try session.waitSocket()
        }
      }
    } onCancel: { ssh.cancelPendingOperations() }
  }

  func start() { schedulePump() }
  private func schedulePump() { ssh.queue.async { [weak self] in self?.pump() } }

  private func pump() {
    guard !finished else { return }
    guard let channel, ssh.session != nil, socket.withFD({ $0 >= 0 }) else { finish(error: nil); return }
    var progressed = false
    if !localEOF, outbound.remaining == 0 {
      let count = socket.withFD { recv($0, outbound.bytes, outbound.capacity, 0) }
      if count > 0 { outbound.count = count; progressed = true }
      else if count == 0 { localEOF = true; progressed = true }
      else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { finish(error: nil); return }
    }
    if outbound.remaining > 0 {
      let count = libssh2_channel_write_ex(channel, 0, outbound.bytes + outbound.offset, outbound.remaining)
      if count > 0 { outbound.consume(count); progressed = true }
      else if count < 0 && count != Int(LIBSSH2_ERROR_EAGAIN) {
        finish(error: LocalForwardError.transport(ssh.lastErrorMessage()).localizedDescription); return
      }
    }
    if localEOF, outbound.remaining == 0, !sentEOF {
      let result = libssh2_channel_send_eof(channel)
      if result == 0 { sentEOF = true; progressed = true }
      else if result != LIBSSH2_ERROR_EAGAIN {
        finish(error: LocalForwardError.transport(ssh.lastErrorMessage()).localizedDescription); return
      }
    }
    if !remoteEOF, inbound.remaining == 0 {
      let count = libssh2_channel_read_ex(channel, 0, inbound.bytes, inbound.capacity)
      if count > 0 { inbound.count = count; progressed = true }
      else if count == 0 || count == Int(LIBSSH2_ERROR_EAGAIN) {
        if libssh2_channel_eof(channel) != 0 { remoteEOF = true; progressed = true }
      } else { finish(error: LocalForwardError.transport(ssh.lastErrorMessage()).localizedDescription); return }
    }
    if inbound.remaining > 0 {
      let count = socket.withFD { send($0, inbound.bytes + inbound.offset, inbound.remaining, 0) }
      if count > 0 { inbound.consume(count); progressed = true }
      else if count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { finish(error: nil); return }
    }
    if remoteEOF, inbound.remaining == 0 {
      socket.withFD { _ = Darwin.shutdown($0, SHUT_WR) }
      if localEOF, sentEOF { finish(error: nil); return }
    }
    // Never interleave a keepalive send with an unfinished channel write/EOF packet.
    if outbound.remaining == 0, (!localEOF || sentEOF), Date().timeIntervalSince(lastKeepalive) >= 5 {
      lastKeepalive = Date()
      var next: Int32 = 0
      let result = libssh2_keepalive_send(ssh.session, &next)
      if result != 0 && result != LIBSSH2_ERROR_EAGAIN {
        finish(error: LocalForwardError.transport(ssh.lastErrorMessage()).localizedDescription); return
      }
    }
    if !progressed {
      socket.withFD { fd in
        let localEvents = (!localEOF && outbound.remaining == 0 ? Int16(POLLIN) : 0)
          | (inbound.remaining > 0 ? Int16(POLLOUT) : 0)
        let direction = libssh2_session_block_directions(ssh.session)
        let sshEvents = Int16(POLLIN) | (direction & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0 ? Int16(POLLOUT) : 0)
        var polls = [pollfd(fd: fd, events: localEvents, revents: 0),
                     pollfd(fd: ssh.socketFD, events: sshEvents, revents: 0)]
        _ = poll(&polls, 2, 20)
      }
    }
    schedulePump()
  }

  func close() async {
    socket.close()
    await withCheckedContinuation { continuation in
      ssh.queue.async { [self] in finish(error: nil); continuation.resume() }
    }
    await owner.disconnect()
  }

  private func finish(error: String?) {
    guard !finished else { return }
    finished = true
    socket.close()
    // This SSH connection is exclusive to the client. Its owner releases the transport
    // rather than wait indefinitely for a channel close acknowledgement under backpressure.
    ssh.abortTransport()
    if let channel, ssh.session != nil { _ = libssh2_channel_free(channel) }
    channel = nil
    onFinish(error)
    let owner = owner
    Task { await owner.disconnect() }
  }
}

extension SSHConnection {
  fileprivate func makeDirectBridge(socket: ForwardSocket, target: LocalForwardConfiguration, originPort: Int,
                                     onFinish: @escaping @Sendable (String?) -> Void) async throws -> DirectTCPBridge {
    guard let ssh = sshSession else { throw LocalForwardError.notConnected }
    return try await DirectTCPBridge.open(ssh: ssh, owner: self, socket: socket, target: target,
                                          originPort: originPort, onFinish: onFinish)
  }
}
