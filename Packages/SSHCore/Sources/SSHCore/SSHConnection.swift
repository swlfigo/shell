import Foundation
import CLibssh2

public typealias HostKeyConfirm = @Sendable (_ hostname: String, _ port: Int, _ fingerprint: String) async -> Bool

public actor SSHConnection {
  private let config: ConnectionConfig
  private let knownHosts: KnownHostsStoring
  private let confirmUnknownHostKey: HostKeyConfirm
  var sshSession: SSHSession?
  private var connecting = false
  private var pendingSession: SSHSession?
  private var pendingConnectTask: Task<Void, Error>?
  private var routeForwards: [LocalPortForward] = []
  private let networkEndpoint: SSHNetworkEndpoint?
  let progressReporter: SSHProgressReporter?

  public init(config: ConnectionConfig,
              knownHosts: KnownHostsStoring,
              progress: SSHConnectionProgressHandler? = nil,
              confirmUnknownHostKey: @escaping HostKeyConfirm) {
    self.config = config
    self.knownHosts = knownHosts
    self.confirmUnknownHostKey = confirmUnknownHostKey
    self.networkEndpoint = nil
    self.progressReporter = progress.map { SSHProgressReporter(config: config, handler: $0) }
  }

  init(config: ConnectionConfig, knownHosts: KnownHostsStoring,
       confirmUnknownHostKey: @escaping HostKeyConfirm, networkEndpoint: SSHNetworkEndpoint?,
       progressReporter: SSHProgressReporter? = nil) {
    self.config = config; self.knownHosts = knownHosts
    self.confirmUnknownHostKey = confirmUnknownHostKey; self.networkEndpoint = networkEndpoint
    self.progressReporter = progressReporter
  }

  public func connect() async throws {
    guard sshSession == nil, !connecting else {
      throw SSHError.connectionFailed("already connecting or connected")
    }
    connecting = true
    progressReporter?.reset()
    defer { connecting = false }
    let s = SSHSession()
    pendingSession = s
    let task = Task { try await self.establish(s) }
    pendingConnectTask = task
    defer { pendingSession = nil; pendingConnectTask = nil }
    try await withTaskCancellationHandler {
      try await task.value
    } onCancel: { task.cancel(); s.cancelPendingOperations() }
  }

  private func establish(_ s: SSHSession) async throws {
    let host = config.hostname, port = config.port
    var route: [LocalPortForward] = []
    var activeProgress = progressReporter
    do {
      try Task.checkCancellation()
      guard config.jumpHosts.count <= ConnectionConfig.maximumJumpHosts else {
        progressReporter?.send(.connection, .failed(.invalidConfiguration))
        throw SSHError.connectionFailed("跳板机最多支持 \(ConnectionConfig.maximumJumpHosts) 台")
      }
      var endpoint = networkEndpoint
      for (index, hop) in config.jumpHosts.enumerated() {
        activeProgress = progressReporter?.hop(hop, index: index)
        guard !hop.hostname.isEmpty, hop.hostname.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              !hop.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              hop.username.rangeOfCharacter(from: .controlCharacters) == nil, (1...65535).contains(hop.port) else {
          activeProgress?.send(.connection, .failed(.invalidConfiguration))
          throw SSHError.connectionFailed("跳板机连接配置无效")
        }
        try s.checkCancellation()
        let next = index + 1 < config.jumpHosts.count
          ? SSHNetworkEndpoint(hostname: config.jumpHosts[index + 1].hostname, port: config.jumpHosts[index + 1].port)
          : SSHNetworkEndpoint(hostname: host, port: port)
        let forward = try await LocalPortForward.startRouted(config: hop.config, knownHosts: knownHosts,
          forwarding: .init(localPort: 0, targetHost: next.hostname, targetPort: next.port),
          networkEndpoint: endpoint, confirmUnknownHostKey: confirmUnknownHostKey, progressReporter: activeProgress)
        route.append(forward)
        try Task.checkCancellation()
        try s.checkCancellation()
        endpoint = .init(hostname: "127.0.0.1", port: forward.localPort)
      }
      let destination = endpoint ?? SSHNetworkEndpoint(hostname: host, port: port)
      let progress = progressReporter
      activeProgress = progress
      progress?.send(.connection, .started)
      let hk: (type: String, blob: Data) = try await s.run { sess in
        try sess.openSocket(host: destination.hostname, port: destination.port)
        progress?.send(.connection, .started, detail: .tcpConnected)
        try sess.handshake()
        progress?.send(.connection, .succeeded)
        progress?.send(.hostKey, .started)
        return try sess.hostKey()
      }
      let validator = HostKeyValidator(store: knownHosts)
      switch try validator.evaluate(hostname: host, port: port, keyType: hk.type, publicKeyBlob: hk.blob) {
      case .trusted: break
      case .unknown(let fp):
        progress?.send(.hostKey, .waitingForTrust(fingerprint: fp))
        let decision = PendingHostConfirmation()
        let confirm = confirmUnknownHostKey
        let trusted: Bool = await withTaskCancellationHandler {
          await withCheckedContinuation { continuation in
            decision.install(continuation)
            let confirmation = Task { decision.resolve(await confirm(host, port, fp)) }
            decision.install(confirmation)
          }
        } onCancel: { decision.cancel() }
        try Task.checkCancellation()
        try s.checkCancellation()
        guard trusted else { throw SSHError.hostKeyRejected }
        try knownHosts.save(KnownHost(hostname: host, port: port, keyType: hk.type,
          publicKeyBlob: hk.blob, fingerprintSHA256: fp, addedAt: Date()))
      case .mismatch(let stored, let got):
        throw SSHError.hostKeyMismatch(stored: stored, got: got)
      }
      progress?.send(.hostKey, .succeeded)
      try Task.checkCancellation()
      try s.checkCancellation()
      switch config.auth {
      case .password(let pw):
        progress?.send(.authentication, .started, detail: .password)
        let user = config.username
        try await s.run { sess in try sess.authPassword(user: user, password: pw) }
      case .privateKey(let data, let passphrase):
        progress?.send(.authentication, .started, detail: .privateKey)
        let user = config.username
        try await s.run { sess in try sess.authPublicKey(user: user, privateKey: data, passphrase: passphrase) }
      }
      progress?.send(.authentication, .succeeded)
      try Task.checkCancellation()
      try s.checkCancellation()
      routeForwards = route
      sshSession = s
    } catch {
      activeProgress?.fail(error)
      await s.close()
      for forward in route.reversed() { await forward.stop() }
      throw error
    }
  }

  public func disconnect() async {
    pendingConnectTask?.cancel()
    pendingSession?.cancelPendingOperations()
    if let task = pendingConnectTask { _ = await task.result }
    let s = sshSession
    sshSession = nil
    s?.cancelPendingOperations()
    let route = routeForwards
    routeForwards.removeAll()
    await s?.close()
    for forward in route.reversed() { await forward.stop() }
  }

  /// Cleanup may outlive the terminal session. Reuse only this connection's in-memory
  /// credentials and existing host trust; a new/changed host key must still be rejected.
  func makeCleanupSFTPClient() async throws -> SFTPClient {
    try await SFTPClient.connect(config: config, knownHosts: knownHosts, confirmUnknownHostKey: { _, _, _ in false })
  }
}

/// Cancellation must not wait for a host-trust UI (or a caller's suspended callback).
private final class PendingHostConfirmation: @unchecked Sendable {
  private let lock = NSLock()
  private var result: Bool?
  private var continuation: CheckedContinuation<Bool, Never>?
  private var task: Task<Void, Never>?
  func install(_ continuation: CheckedContinuation<Bool, Never>) {
    let result = lock.withLock { () -> Bool? in
      if let result = self.result { return result }
      self.continuation = continuation
      return nil
    }
    if let result { continuation.resume(returning: result) }
  }
  func install(_ task: Task<Void, Never>) {
    let finished = lock.withLock {
      guard result == nil else { return true }
      self.task = task
      return false
    }
    if finished { task.cancel() }
  }
  func resolve(_ value: Bool) {
    let pending = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
      guard result == nil else { return nil }
      result = value
      let pending = continuation
      continuation = nil
      task = nil
      return pending
    }
    pending?.resume(returning: value)
  }
  func cancel() {
    let task = lock.withLock { self.task }
    resolve(false)
    task?.cancel()
  }
}
