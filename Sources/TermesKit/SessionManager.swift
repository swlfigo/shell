import Foundation
import Network
import SSHCore

/// Orchestrates SSHConnection + TerminalService and exposes a connection state machine.
/// UI-framework agnostic: the terminal view is wired through `onData` / `sendInput` / `resize`.
@MainActor
public final class SessionManager: ObservableObject {
  public enum State: Equatable, Sendable {
    case idle, connecting
    case needsHostKeyConfirm(fingerprint: String)
    case connected
    case reconnecting(attempt: Int)
    case failed(String)
    case disconnected
  }

  @Published public private(set) var state: State = .idle {
    didSet {
      portForwards.setConnected(state == .connected)
      serverMonitor.setConnection(connected: state == .connected, version: generation,
        destination: config.map { LocalForwardDestination(config: $0) })
    }
  }

  public private(set) lazy var serverMonitor = ServerMonitorModel { [weak self] in
    guard let self else { throw SSHError.disconnected }
    return try await self.openMonitoringClient()
  }
  public let connectionProgress = ConnectionProgressModel()
  private var progressRelay: ConnectionProgressRelay?

  public private(set) lazy var portForwards = LocalForwardManager(store: forwardStore) { [weak self] target in
    guard let self else { throw LocalForwardError.notConnected }
    return try await self.openLocalForward(target)
  }

  /// Bytes the terminal should feed. Output arriving before this is set is buffered and flushed on assignment.
  public var onData: ((Data) -> Void)? {
    didSet {
      guard let onData, !pending.isEmpty else { return }
      let buffered = pending
      pending.removeAll()
      buffered.forEach(onData)
    }
  }

  private let knownHosts: KnownHostsStoring
  private let forwardStore: LocalForwardStore?
  private var connection: SSHConnection?
  private var terminal: TerminalService?
  private var fileClients: [FileClientReference] = []
  private var monitorClients: [MonitorClientReference] = []
  public private(set) var pendingHostKeyEndpoint: (hostname: String, port: Int)?
  private var hostKeyContinuation: CheckedContinuation<Bool, Never>?
  private var pending: [Data] = []
  /// Bumped on every connect/disconnect so stale async work can detect it was superseded.
  private var generation = 0
  /// Identifies the current transport lifetime, including reconnects to the same server.
  public var connectionVersion: Int { generation }
  /// Last known terminal size; used as the initial PTY size and re-sent after the shell opens.
  public private(set) var lastSize: (cols: Int, rows: Int)?

  var config: ConnectionConfig?
  /// The active connection's in-memory config (nil after failure/disconnect); used to duplicate it.
  public var currentConfig: ConnectionConfig? { config }
  /// Kept only in memory so an explicit retry does not have to reopen the connection form.
  private var failedConfig: ConnectionConfig?
  public var canRetryConnection: Bool {
    if case .failed = state { return failedConfig != nil }
    return false
  }
  private var channel: ShellChannel?
  private var reconnectTask: Task<Void, Never>?
  /// The current backoff sleep; cancelling it ends only this wait, not the reconnect loop.
  private var backoffTask: Task<Void, Never>?
  private var pathMonitor: NWPathMonitor?

  /// Delay before retry number `attempt` (1-based): 1, 2, 4, ... capped at 30 seconds.
  static func backoffDelay(attempt: Int) -> TimeInterval {
    min(pow(2.0, Double(attempt - 1)), 30)
  }

  /// Errors retrying cannot fix (bad credentials, host-key problems).
  static func isPermanent(_ error: SSHError) -> Bool {
    switch error {
    case .authenticationFailed, .hostKeyMismatch, .hostKeyRejected: return true
    // channelFailure is deliberately transient: retried indefinitely (even if a server keeps refusing the shell).
    case .connectionFailed, .channelFailure, .disconnected: return false
    }
  }

  public init(knownHosts: KnownHostsStoring, forwardStore: LocalForwardStore? = nil) {
    self.knownHosts = knownHosts
    self.forwardStore = forwardStore
    startPathMonitor()
  }

  deinit { pathMonitor?.cancel() }

  private func startPathMonitor() {
    let monitor = NWPathMonitor()
    // Touched only on the monitor's serial queue.
    let last = PathStatusBox()
    monitor.pathUpdateHandler = { [weak self] path in
      let satisfied = path.status == .satisfied
      // The first callback only seeds the previous status; it is not a transition.
      let restored = satisfied && last.seen && !last.wasSatisfied
      last.seen = true
      last.wasSatisfied = satisfied
      guard restored else { return }
      Task { @MainActor [weak self] in
        guard let self, case .reconnecting = self.state else { return }
        self.wakeReconnect()
      }
    }
    monitor.start(queue: DispatchQueue(label: "SessionManager.pathMonitor"))
    pathMonitor = monitor
  }

  /// Ends the current reconnect backoff wait early so the next attempt starts now.
  /// No-op when not waiting. Unlike `disconnect()`, this does not stop the reconnect loop.
  func wakeReconnect() {
    backoffTask?.cancel()
  }

  private func backoffSleep(_ delay: TimeInterval) async {
    guard !Task.isCancelled else { return }
    let t = Task<Void, Never> { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
    backoffTask = t
    // Cancelling the outer reconnectTask must also end this wait (disconnect semantics).
    await withTaskCancellationHandler { await t.value } onCancel: { t.cancel() }
    if backoffTask == t { backoffTask = nil }
  }

  public func connect(_ config: ConnectionConfig, cols: Int = 80, rows: Int = 24) async {
    await connect(config, cols: cols, rows: rows, attempt: 1)
  }

  /// Starts a new attempt with the failed connection's original route and credentials.
  public func retryConnection() async {
    guard canRetryConnection, let config = failedConfig else { return }
    await connect(config, cols: 80, rows: 24, attempt: connectionProgress.attempt + 1)
  }

  private func connect(_ config: ConnectionConfig, cols: Int, rows: Int, attempt: Int) async {
    let (cols, rows) = lastSize ?? (cols, rows)
    switch state {
    case .connecting, .needsHostKeyConfirm, .connected, .reconnecting: return
    default: break
    }
    generation += 1
    let gen = generation
    failedConfig = nil
    self.config = config
    let progress = beginProgress(config: config, generation: gen, attempt: attempt)
    if pathMonitor == nil { startPathMonitor() }
    state = .connecting
    pending.removeAll()

    await portForwards.bindDestination(LocalForwardDestination(config: config))
    guard gen == generation else { return }

    let conn = SSHConnection(config: config, knownHosts: knownHosts, progress: { progress.continuation.yield($0) }) { [weak self] hostname, port, fingerprint in
      await self?.requestHostKeyConfirm(hostname: hostname, port: port, fingerprint: fingerprint, gen: gen) ?? false
    }
    connection = conn
    do {
      try await conn.connect()
      guard gen == generation else { await conn.disconnect(); return }
      let channel = try await conn.openShell(cols: cols, rows: rows)
      guard gen == generation else { await channel.close(); await conn.disconnect(); return }
      await finishProgress(progress)
      guard gen == generation else { await channel.close(); await conn.disconnect(); return }
      attach(channel: channel, initialSize: (cols, rows))
      connectionProgress.ready(token: progress.token)
      state = .connected
    } catch {
      guard gen == generation else { return }
      await conn.disconnect()
      await finishProgress(progress)
      guard gen == generation else { return }
      connectionProgress.fail(token: progress.token)
      connection = nil
      self.config = nil
      if error is CancellationError || Task.isCancelled { disconnect(); return }
      failedConfig = config
      state = .failed(Self.message(for: error))
    }
  }

  /// Answers `.needsHostKeyConfirm`. No-op in other states.
  public func confirmHostKey(_ trust: Bool) {
    guard let c = hostKeyContinuation else { return }
    hostKeyContinuation = nil
    pendingHostKeyEndpoint = nil
    if trust { state = .connecting }
    c.resume(returning: trust)
  }

  public func confirmHostKey(_ trust: Bool, attemptID: UUID, fingerprint: String) {
    guard connectionProgress.attemptID == attemptID,
          case .needsHostKeyConfirm(let current) = state, current == fingerprint else { return }
    confirmHostKey(trust)
  }

  public func sendInput(_ data: Data) { terminal?.sendInput(data) }

  /// Reuses credentials and host trust, while keeping file I/O off the terminal transport.
  public func openSFTP() async throws -> any SFTPFileSystem {
    try Task.checkCancellation()
    guard state == .connected, let config else { throw SFTPError.notConnected }
    let gen = generation
    let client = try await SFTPClient.connect(config: config, knownHosts: knownHosts,
                                             confirmUnknownHostKey: { _, _, _ in false })
    guard state == .connected, generation == gen, !Task.isCancelled else {
      await client.close()
      throw SFTPError.notConnected
    }
    fileClients.removeAll { $0.value == nil }
    fileClients.append(FileClientReference(client))
    return client
  }

  private func closeFileClients() {
    let clients = fileClients.compactMap(\.value)
    fileClients.removeAll()
    Task { for client in clients { await client.close() } }
  }

  /// Monitoring reuses this session's in-memory route/credentials and already confirmed trust.
  /// New or changed keys never trigger implicit acceptance or a hidden confirmation dialog.
  public func openMonitoringClient() async throws -> any ServerMonitoringClient {
    try Task.checkCancellation()
    guard state == .connected, let config else { throw SSHError.disconnected }
    let gen = generation
    let client = try await SSHServerMonitoringClient.connect(config: config, knownHosts: knownHosts)
    guard state == .connected, generation == gen, !Task.isCancelled else {
      await client.close(); throw SSHError.disconnected
    }
    monitorClients.removeAll { $0.value == nil }
    monitorClients.append(.init(client))
    return client
  }

  private func closeMonitorClients() {
    let clients = monitorClients.compactMap(\.value)
    monitorClients.removeAll()
    Task { for client in clients { await client.close() } }
  }

  private func openLocalForward(_ target: LocalForwardConfiguration) async throws -> any LocalForwarding {
    try Task.checkCancellation()
    guard state == .connected, let config else { throw LocalForwardError.notConnected }
    let gen = generation
    let forward: any LocalForwarding
    if target.kind == .remote {
      forward = try await RemotePortForward.start(config: config, knownHosts: knownHosts, forwarding: target)
    } else {
      forward = try await LocalPortForward.start(config: config, knownHosts: knownHosts, forwarding: target)
    }
    guard state == .connected, generation == gen, !Task.isCancelled else {
      await forward.stop()
      throw LocalForwardError.notConnected
    }
    return forward
  }

  /// Inserts into a live terminal without submitting the line or queuing it for a reconnect.
  @discardableResult
  public func insertSnippet(_ snippet: Snippet, parameters: [String: String] = [:]) -> Bool {
    guard state == .connected, terminal != nil, let command = try? snippet.insertionCommand(parameters: parameters) else { return false }
    terminal?.sendInput(Data(command.utf8))
    return true
  }
  public func resize(cols: Int, rows: Int) {
    lastSize = (cols, rows)
    terminal?.resize(cols: cols, rows: rows)
  }

  public func disconnect() {
    connectionProgress.endConnection()
    stopProgress()
    closeFileClients()
    closeMonitorClients()
    generation += 1
    reconnectTask?.cancel()
    reconnectTask = nil
    backoffTask?.cancel()
    backoffTask = nil
    pathMonitor?.cancel()
    pathMonitor = nil
    config = nil
    failedConfig = nil
    pendingHostKeyEndpoint = nil
    if let c = hostKeyContinuation { hostKeyContinuation = nil; c.resume(returning: false) }
    // stop() cancels the pump, so onClosed does not fire for a local disconnect.
    terminal?.stop()
    terminal = nil
    let conn = connection
    connection = nil
    // A remote `exit` only closes the child channel; always release the parent connection.
    if let conn { Task { await conn.disconnect() } }
    pending.removeAll()
    state = (state == .idle) ? .idle : .disconnected
  }

  // MARK: - Private

  private func requestHostKeyConfirm(hostname: String, port: Int, fingerprint: String, gen: Int) async -> Bool {
    guard gen == generation else { return false }
    return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
      if let old = hostKeyContinuation { old.resume(returning: false) }
      hostKeyContinuation = c
      pendingHostKeyEndpoint = (hostname, port)
      state = .needsHostKeyConfirm(fingerprint: fingerprint)
    }
  }

  private func deliver(_ data: Data) {
    if let onData { onData(data) } else { pending.append(data) }
  }

  /// Reconcile layout changes made while a first connection or reconnect was opening its PTY.
  func attach(channel: ShellChannel, initialSize: (cols: Int, rows: Int)) {
    let svc = TerminalService(channel: channel)
    svc.onData = { [weak self] data in self?.deliver(data) }
    svc.onClosed = { [weak self] in self?.handleRemoteClosed() }
    terminal = svc
    self.channel = channel
    svc.start()
    if let size = lastSize, size != initialSize { svc.resize(cols: size.cols, rows: size.rows) }
  }

  private func handleRemoteClosed() {
    guard state == .connected else { return }
    connectionProgress.endConnection()
    closeFileClients()
    closeMonitorClients()
    // Only a dropped transport is retried; remote `exit` and local close end the session.
    let reason = (channel as? SSHShellChannel)?.closeReason
    let shouldReconnect = reason == .droppedConnection
    terminal?.stop()
    terminal = nil
    channel = nil
    let conn = connection
    connection = nil
    if let conn { Task { await conn.disconnect() } }
    if !shouldReconnect || config == nil {
      config = nil  // the session is over: release its credentials (and disable duplicating it)
      state = .disconnected
    } else {
      startReconnect()
    }
  }

  func startReconnect() {
    closeFileClients()
    closeMonitorClients()
    guard let config else { state = .disconnected; return }
    generation += 1
    let gen = generation
    state = .reconnecting(attempt: 1)
    reconnectTask?.cancel()
    reconnectTask = Task { [weak self] in
      var attempt = 1
      while !Task.isCancelled {
        guard let self, gen == self.generation else { return }
        self.state = .reconnecting(attempt: attempt)
        let progress = self.beginProgress(config: config, generation: gen, attempt: attempt)
        let size = self.lastSize ?? (80, 24)
        // Host key was trusted on first connect; an unknown key here is treated as a rejection.
        let conn = SSHConnection(config: config, knownHosts: self.knownHosts, progress: { progress.continuation.yield($0) }) { _, _, _ in false }
        self.connection = conn
        do {
          try await conn.connect()
          guard gen == self.generation else { await conn.disconnect(); return }
          let ch = try await conn.openShell(cols: size.0, rows: size.1)
          guard gen == self.generation else { await ch.close(); await conn.disconnect(); return }
          await self.finishProgress(progress)
          guard gen == self.generation else { await ch.close(); await conn.disconnect(); return }
          self.connection = conn
          self.attach(channel: ch, initialSize: size)
          self.connectionProgress.ready(token: progress.token)
          self.state = .connected
          self.reconnectTask = nil
          return
        } catch {
          await conn.disconnect()
          await self.finishProgress(progress)
          guard gen == self.generation else { return }
          self.connection = nil
          self.connectionProgress.fail(token: progress.token)
          if let e = error as? SSHError, Self.isPermanent(e) {
            self.config = nil
            self.failedConfig = config
            self.state = .failed(Self.message(for: error))
            self.reconnectTask = nil
            return
          }
        }
        let delay = Self.backoffDelay(attempt: attempt)
        self.connectionProgress.waitingRetry(seconds: Int(delay), token: progress.token)
        attempt += 1
        await self.backoffSleep(delay)
      }
    }
  }

  public func retryReconnectNow() { wakeReconnect() }

  private func beginProgress(config: ConnectionConfig, generation: Int, attempt: Int) -> ConnectionProgressRelay {
    stopProgress()
    let token = connectionProgress.begin(config: config, attempt: attempt)
    let (stream, continuation) = AsyncStream<SSHConnectionProgressEvent>.makeStream(bufferingPolicy: .bufferingNewest(128))
    let reader = Task { [weak self] in
      for await event in stream {
        guard !Task.isCancelled, self?.generation == generation else { break }
        self?.connectionProgress.receive(event, token: token)
      }
    }
    let relay = ConnectionProgressRelay(token: token, continuation: continuation, reader: reader)
    progressRelay = relay; return relay
  }
  private func finishProgress(_ relay: ConnectionProgressRelay) async {
    relay.continuation.finish(); await relay.reader.value
    if progressRelay?.token == relay.token { progressRelay = nil }
  }
  private func stopProgress() {
    progressRelay?.reader.cancel(); progressRelay?.continuation.finish(); progressRelay = nil
  }

  private static func message(for error: Error) -> String {
    switch error as? SSHError {
    case .hostKeyRejected: return "Host key rejected"
    case .authenticationFailed: return "Authentication failed"
    case .hostKeyMismatch(let stored, let got): return "Host key changed (stored \(stored), got \(got))"
    case .connectionFailed(let m): return "Connection failed: \(m)"
    case .channelFailure(let m): return "Channel failure: \(m)"
    case .disconnected: return "Disconnected"
    case nil: return "\(error)"
    }
  }
}

private struct ConnectionProgressRelay: Sendable {
  let token: UUID
  let continuation: AsyncStream<SSHConnectionProgressEvent>.Continuation
  let reader: Task<Void, Never>
}

private final class FileClientReference {
  weak var value: SFTPClient?
  init(_ value: SFTPClient) { self.value = value }
}

private final class MonitorClientReference {
  weak var value: SSHServerMonitoringClient?
  init(_ value: SSHServerMonitoringClient) { self.value = value }
}

/// Previous path availability; only accessed from the NWPathMonitor's serial queue.
private final class PathStatusBox: @unchecked Sendable {
  var seen = false
  var wasSatisfied = false
}
