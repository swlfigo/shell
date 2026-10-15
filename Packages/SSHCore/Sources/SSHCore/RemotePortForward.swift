import Foundation
import CLibssh2
import Darwin

/// A server-side TCP listener with a dedicated SSH transport. Forwarded channels
/// share that transport; each connects to its local target independently.
public final class RemotePortForward: LocalForwarding, @unchecked Sendable {
  public let localPort: Int
  public let events: AsyncStream<LocalForwardEvent>
  private let resources: RemoteForwardResources

  private init(port: Int, events: AsyncStream<LocalForwardEvent>, resources: RemoteForwardResources) {
    localPort = port; self.events = events; self.resources = resources
  }

  public static func start(config: ConnectionConfig, knownHosts: KnownHostsStoring,
                           forwarding: LocalForwardConfiguration) async throws -> RemotePortForward {
    try forwarding.validate()
    guard forwarding.kind == .remote else { throw LocalForwardError.invalidConfiguration }
    try Task.checkCancellation()
    let owner = SSHConnection(config: config, knownHosts: knownHosts, confirmUnknownHostKey: { _, _, _ in false })
    do {
      try await owner.connect()
      let forward = try await owner.makeRemoteForward(target: forwarding)
      if Task.isCancelled { await forward.stop(); throw CancellationError() }
      forward.resources.schedulePump()
      return forward
    } catch { await owner.disconnect(); throw error }
  }

  fileprivate static func open(ssh: SSHSession, owner: SSHConnection,
                                target: LocalForwardConfiguration) async throws -> RemotePortForward {
    try await withTaskCancellationHandler {
      try await ssh.run { session in
        guard let raw = session.session else { throw LocalForwardError.notConnected }
        // A process-free control channel consumes replies and provides a retryable
        // heartbeat request. It never starts a shell or modifies the terminal's environment.
        var control: OpaquePointer?
        while control == nil {
          control = libssh2_channel_open_ex(raw, "session", 7, 65536, 32768, nil, 0)
          if control != nil { break }
          guard libssh2_session_last_errno(raw) == LIBSSH2_ERROR_EAGAIN else {
            throw LocalForwardError.transport(session.lastErrorMessage())
          }
          try session.waitSocket()
        }
        var port: Int32 = 0
        while true {
          if let listener = libssh2_channel_forward_listen_ex(raw, target.listenHost, Int32(target.localPort), &port, 32) {
            let (events, continuation) = AsyncStream<LocalForwardEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
            let resources = RemoteForwardResources(ssh: session, owner: owner, target: target,
              listener: listener, control: control!, continuation: continuation)
            return RemotePortForward(port: Int(port), events: events, resources: resources)
          }
          guard libssh2_session_last_errno(raw) == LIBSSH2_ERROR_EAGAIN else {
            throw LocalForwardError.remoteListen(session.lastErrorMessage())
          }
          try session.waitSocket()
        }
      }
    } onCancel: { ssh.cancelPendingOperations() }
  }

  public func stop() async {
    let resources = resources
    let cleanup: Task<Void, Never>? = await withCheckedContinuation { continuation in
      resources.ssh.queue.async {
        resources.finish(error: nil)
        continuation.resume(returning: resources.cleanup)
      }
    }
    await cleanup?.value
  }

  deinit {
    let resources = resources
    resources.ssh.queue.async { resources.finish(error: nil) }
  }
}

extension SSHConnection {
  fileprivate func makeRemoteForward(target: LocalForwardConfiguration) async throws -> RemotePortForward {
    guard let ssh = sshSession else { throw LocalForwardError.notConnected }
    return try await RemotePortForward.open(ssh: ssh, owner: self, target: target)
  }
}

private final class RemoteForwardPeer {
  let id = UUID()
  let channel: OpaquePointer
  let outbound = ForwardBuffer()
  let inbound = ForwardBuffer()
  var socket: ForwardSocket?
  var connector: Task<Void, Never>?
  var localEOF = false
  var sentEOF = false
  var remoteEOF = false
  var shutdownWrite = false
  var closingAt: TimeInterval?
  var isActive: Bool { closingAt == nil }
  init(channel: OpaquePointer) { self.channel = channel }
}

/// All state and libssh2 access are confined to ssh.queue.
private final class RemoteForwardResources: @unchecked Sendable {
  enum Operation: Equatable {
    case accept, control, heartbeat, read(UUID), write(UUID, Int), eof(UUID), free(UUID)
  }
  let ssh: SSHSession
  private let owner: SSHConnection
  private let target: LocalForwardConfiguration
  private let listener: OpaquePointer
  private let control: OpaquePointer
  private let controlBuffer = ForwardBuffer()
  private let continuation: AsyncStream<LocalForwardEvent>.Continuation
  private var peers: [UUID: RemoteForwardPeer] = [:]
  private var finished = false
  private var pending: Operation?
  private var pendingSince: TimeInterval?
  private var heartbeatSince: TimeInterval?
  private var lastHeartbeat = ProcessInfo.processInfo.systemUptime
  var cleanup: Task<Void, Never>?
  private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
  private var clientCount: Int { peers.values.filter(\.isActive).count }
  private var blockedOutbound: Bool {
    libssh2_session_block_directions(ssh.session) & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0
  }

  init(ssh: SSHSession, owner: SSHConnection, target: LocalForwardConfiguration,
       listener: OpaquePointer, control: OpaquePointer, continuation: AsyncStream<LocalForwardEvent>.Continuation) {
    self.ssh = ssh; self.owner = owner; self.target = target
    self.listener = listener; self.control = control; self.continuation = continuation
  }

  func schedulePump() { ssh.queue.async { [weak self] in self?.pump() } }

  private func pump() {
    guard !finished, ssh.session != nil else { return }
    if let pendingSince, now - pendingSince > 15 {
      finish(error: LocalForwardError.transport("发送超时").localizedDescription); return
    }
    if let operation = pending {
      pending = nil
      perform(operation)
      if pending != nil, operation != .accept, !finished {
        // Transport reads can generate channel-open replies while a data write is
        // pending. Drain that state without starting a different application write.
        let saved = pending
        perform(.accept)
        pending = saved
      }
      if pending == nil { pendingSince = nil }
      waitAndSchedule(); return
    }
    perform(.accept)
    guard ready else { waitAndSchedule(); return }
    perform(.control)
    guard ready else { waitAndSchedule(); return }
    if heartbeatSince != nil || now - lastHeartbeat >= 15 {
      perform(.heartbeat)
      guard ready else { waitAndSchedule(); return }
    }
    // A slow local connect is off this queue. Bounded buffers and channel windows
    // let all established clients progress without waiting for another local service.
    for peer in Array(peers.values) {
      if let closingAt = peer.closingAt {
        if now - closingAt > 15 { finish(error: LocalForwardError.transport("客户端通道关闭超时").localizedDescription); return }
        perform(.free(peer.id))
      } else if let socket = peer.socket {
        pumpLocal(peer, socket: socket)
        guard ready, peer.isActive else { if !ready { break }; continue }
        if !peer.remoteEOF, peer.inbound.remaining == 0 { perform(.read(peer.id)) }
        guard ready, peer.isActive else { if !ready { break }; continue }
        if peer.outbound.remaining > 0 {
          let window = Int(libssh2_channel_window_write_ex(peer.channel, nil))
          if window > 0 { perform(.write(peer.id, min(window, peer.outbound.remaining, 32700))) }
        }
        guard ready, peer.isActive else { if !ready { break }; continue }
        if peer.localEOF, peer.outbound.remaining == 0, !peer.sentEOF { perform(.eof(peer.id)) }
        guard ready, peer.isActive else { if !ready { break }; continue }
        if peer.remoteEOF, peer.inbound.remaining == 0, !peer.shutdownWrite {
          socket.withFD { _ = Darwin.shutdown($0, SHUT_WR) }; peer.shutdownWrite = true
        }
        if peer.localEOF, peer.sentEOF, peer.remoteEOF, peer.inbound.remaining == 0 {
          closePeer(peer, error: nil)
        }
      }
      if !ready { break }
    }
    waitAndSchedule()
  }

  private var ready: Bool { !finished && pending == nil }
  private func retry(_ operation: Operation) {
    pending = operation
    if pendingSince == nil { pendingSince = now }
  }

  private func perform(_ operation: Operation) {
    guard !finished else { return }
    switch operation {
    case .accept:
      guard peers.count < 64 else { return } // Includes channels awaiting close acknowledgement.
      if let channel = libssh2_channel_forward_accept(listener) {
        let peer = RemoteForwardPeer(channel: channel)
        peers[peer.id] = peer
        if clientCount > 32 { closePeer(peer, error: LocalForwardError.tooManyClients.localizedDescription) }
        else { continuation.yield(.clients(clientCount)); connectTarget(peer) }
      } else if libssh2_session_last_errno(ssh.session) != LIBSSH2_ERROR_EAGAIN {
        finish(error: LocalForwardError.transport(ssh.lastErrorMessage()).localizedDescription); return
      }
      if blockedOutbound { retry(.accept) }
    case .control:
      let count = libssh2_channel_read_ex(control, 0, controlBuffer.bytes, 1)
      if count < 0 && count != Int(LIBSSH2_ERROR_EAGAIN) || libssh2_channel_eof(control) != 0 {
        finish(error: LocalForwardError.transport(ssh.lastErrorMessage()).localizedDescription); return
      }
      if blockedOutbound { retry(.control) }
    case .heartbeat:
      if heartbeatSince == nil { heartbeatSince = now }
      guard now - heartbeatSince! < 15 else {
        finish(error: LocalForwardError.transport("心跳超时").localizedDescription); return
      }
      // Unlike keepalive_send, setenv exposes EAGAIN and retains its packet across
      // retries. Denial is also a successful heartbeat reply on this process-free channel.
      let variable = "TERMES_FORWARD_HEARTBEAT"
      let result = libssh2_channel_setenv_ex(control, variable, UInt32(variable.utf8.count), "1", 1)
      if result == 0 || result == LIBSSH2_ERROR_CHANNEL_REQUEST_DENIED {
        heartbeatSince = nil; lastHeartbeat = now
      } else if result != LIBSSH2_ERROR_EAGAIN {
        finish(error: LocalForwardError.transport(ssh.lastErrorMessage()).localizedDescription); return
      }
      if blockedOutbound { retry(.heartbeat) }
    case .read(let id):
      guard let peer = peers[id] else { return }
      let count = libssh2_channel_read_ex(peer.channel, 0, peer.inbound.bytes, peer.inbound.capacity)
      if count > 0 { peer.inbound.count = count }
      else if count == 0 || count == Int(LIBSSH2_ERROR_EAGAIN) {
        if libssh2_channel_eof(peer.channel) != 0 { peer.remoteEOF = true }
      } else { channelFailure(peer, code: count); return }
      if blockedOutbound { retry(count > 0 ? .accept : operation) }
    case .write(let id, let count):
      guard let peer = peers[id] else { return }
      let result = libssh2_channel_write_ex(peer.channel, 0, peer.outbound.bytes + peer.outbound.offset, count)
      if result > 0 { peer.outbound.consume(result) }
      else if result == Int(LIBSSH2_ERROR_EAGAIN) { retry(operation); return }
      else if result < 0 { channelFailure(peer, code: result); return }
      if blockedOutbound { retry(.accept) }
    case .eof(let id):
      guard let peer = peers[id] else { return }
      let result = libssh2_channel_send_eof(peer.channel)
      if result == 0 { peer.sentEOF = true }
      else if result == LIBSSH2_ERROR_EAGAIN { retry(operation); return }
      else { channelFailure(peer, code: Int(result)); return }
      if blockedOutbound { retry(.accept) }
    case .free(let id):
      guard let peer = peers[id] else { return }
      let result = libssh2_channel_free(peer.channel)
      if result == LIBSSH2_ERROR_EAGAIN {
        if blockedOutbound { retry(operation) }
      } else { peers.removeValue(forKey: id) }
    }
  }

  private func channelFailure(_ peer: RemoteForwardPeer, code: Int) {
    if code == Int(LIBSSH2_ERROR_CHANNEL_CLOSED) || code == Int(LIBSSH2_ERROR_CHANNEL_EOF_SENT) {
      closePeer(peer, error: nil)
    } else { finish(error: LocalForwardError.transport(ssh.lastErrorMessage()).localizedDescription) }
  }

  private func pumpLocal(_ peer: RemoteForwardPeer, socket: ForwardSocket) {
    if peer.inbound.remaining > 0 {
      let count = socket.withFD { send($0, peer.inbound.bytes + peer.inbound.offset, peer.inbound.remaining, 0) }
      if count > 0 { peer.inbound.consume(count) }
      else if count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
        closePeer(peer, error: LocalForwardError.target(String(cString: strerror(errno))).localizedDescription); return
      }
    }
    if !peer.localEOF, peer.outbound.remaining == 0 {
      let count = socket.withFD { recv($0, peer.outbound.bytes, peer.outbound.capacity, 0) }
      if count > 0 { peer.outbound.count = count }
      else if count == 0 { peer.localEOF = true }
      else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
        closePeer(peer, error: LocalForwardError.target(String(cString: strerror(errno))).localizedDescription)
      }
    }
  }

  private func connectTarget(_ peer: RemoteForwardPeer) {
    let id = peer.id, target = target, ssh = ssh
    peer.connector = Task { [weak self] in
      let connector = SSHSession(label: "sshcore.remote-target")
      do {
        let socket = try await withTaskCancellationHandler {
          try await connector.run { session in
            try session.openSocket(host: target.targetHost, port: target.targetPort)
            return ForwardSocket(try session.detachUnnegotiatedSocket())
          }
        } onCancel: { connector.cancelPendingOperations() }
        ssh.queue.async { [weak self] in
          guard let self, !self.finished, let peer = self.peers[id], peer.isActive else { socket.close(); return }
          peer.socket = socket
        }
      } catch {
        await connector.close()
        let message = LocalForwardError.target(error.localizedDescription).localizedDescription
        ssh.queue.async { [weak self] in
          guard let self, !self.finished, let peer = self.peers[id], peer.isActive else { return }
          self.closePeer(peer, error: message)
        }
      }
    }
  }

  private func closePeer(_ peer: RemoteForwardPeer, error: String?) {
    guard peer.isActive else { return }
    peer.closingAt = now
    peer.connector?.cancel(); peer.socket?.close()
    continuation.yield(.clients(clientCount))
    if let error { continuation.yield(.clientError(error)) }
  }

  private func waitAndSchedule() {
    guard !finished else { return }
    let directions = libssh2_session_block_directions(ssh.session)
    let sshEvents = Int16(POLLIN) | (directions & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0 ? Int16(POLLOUT) : 0)
    var polls = [pollfd(fd: ssh.socketFD, events: sshEvents, revents: 0)]
    if pending == nil {
      for peer in peers.values where peer.isActive {
        if let socket = peer.socket {
          socket.withFD { fd in
            let events = (!peer.localEOF && peer.outbound.remaining == 0 ? Int16(POLLIN) : 0)
              | (peer.inbound.remaining > 0 ? Int16(POLLOUT) : 0)
            if events != 0 { polls.append(pollfd(fd: fd, events: events, revents: 0)) }
          }
        }
      }
    }
    _ = poll(&polls, nfds_t(polls.count), 20)
    schedulePump()
  }

  func finish(error: String?) {
    guard !finished else { return }
    finished = true
    let peers = Array(peers.values)
    self.peers.removeAll()
    for peer in peers { peer.connector?.cancel(); peer.socket?.close() }
    // Ending this dedicated SSH transport releases its remote listener, queued and
    // accepted channels together, even under backpressure or a lost close acknowledgement.
    ssh.abortTransport()
    continuation.yield(.stopped(error: error)); continuation.finish()
    let owner = owner
    cleanup = Task {
      await withTaskGroup(of: Void.self) { group in
        for peer in peers { if let task = peer.connector { group.addTask { await task.value } } }
      }
      await owner.disconnect()
    }
  }
}
