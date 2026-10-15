import Foundation
import Combine
import SSHCore

public struct ServerMonitorHistoryPoint: Identifiable, Equatable, Sendable {
  public let id = UUID()
  public let segment: UUID
  public let capturedAt: Date
  public let monotonicTime: TimeInterval
  public let cpuPercent, memoryPercent: Double?
  public let load: ServerLoadAverage?
  public let network: [ServerNetworkRate]
}

/// UI-independent monitoring for one pane. One query at a time, one dedicated client,
/// bounded history, and a generation guard for every result across close/reconnect.
@MainActor
public final class ServerMonitorModel: ObservableObject {
  public enum State: Equatable, Sendable {
    case closed, disconnected, paused, connecting, sampling, live
    case failed(String), unavailable(String)
  }
  public typealias Factory = @MainActor () async throws -> any ServerMonitoringClient
  public typealias Sleep = @Sendable (TimeInterval) async throws -> Void
  public static let maximumHistoryCount = 181
  public static let historyDuration: TimeInterval = 15 * 60

  @Published public private(set) var state: State = .closed
  @Published public private(set) var current: ServerMetricsSnapshot?
  @Published public private(set) var history: [ServerMonitorHistoryPoint] = []
  @Published public private(set) var isOpen = false
  @Published public private(set) var isPaused = false
  @Published public private(set) var isConnected = false
  @Published public private(set) var destination: LocalForwardDestination?
  private let factory: Factory
  private let interval: TimeInterval
  private let sleep: Sleep
  private let now: @MainActor () -> TimeInterval
  private var version = -1
  private var token = UUID(), segment = UUID()
  private var task: Task<Void, Never>?
  private var cleanup: Task<Void, Never>?
  private var client: (any ServerMonitoringClient)?
  private var calculator = ServerMetricsCalculator()

  public init(interval: TimeInterval = 5,
              now: @escaping @MainActor () -> TimeInterval = { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 },
              sleep: @escaping Sleep = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
              factory: @escaping Factory) {
    precondition(interval.isFinite && interval > 0 && interval <= 60)
    self.interval = interval; self.now = now; self.sleep = sleep; self.factory = factory
  }

  deinit {
    task?.cancel()
    let client = client
    Task { await client?.close() }
  }

  public var isStale: Bool {
    guard let current else { return true }
    switch state {
    case .live, .sampling: return now() - current.sample.monotonicTime > interval + 8
    default: return true
    }
  }

  public func setConnection(connected: Bool, version: Int, destination: LocalForwardDestination?) {
    let changed = self.destination != destination && destination != nil
    guard self.isConnected != connected || self.version != version || changed else { return }
    stop()
    self.version = version; isConnected = connected
    if changed { current = nil; history = []; self.destination = destination }
    else if let destination { self.destination = destination }
    if !isOpen { state = .closed }
    else if !connected { state = .disconnected }
    else if isPaused { state = .paused }
    else { start() }
  }

  public func open() {
    guard !isOpen else { return }
    isOpen = true; isPaused = false
    if isConnected { start() } else { state = .disconnected }
  }
  public func close() {
    isOpen = false; isPaused = false; stop(); state = .closed
    // A closed panel owns no history or cached server data. Credentials never enter either.
    current = nil; history = []
  }
  public func pause() { guard isOpen else { return }; isPaused = true; stop(); state = .paused }
  public func resume() {
    guard isOpen else { return }
    isPaused = false
    if isConnected { start() } else { state = .disconnected }
  }
  public func retry() { guard isOpen, isConnected, !isPaused else { return }; stop(); start() }

  /// Called by a visible view's clock as well as collection updates, including while paused.
  public func refreshTime() { prune(at: now()) }
  public func points(minutes: Int) -> [ServerMonitorHistoryPoint] {
    let cutoff = now() - Double(min(15, max(1, minutes))) * 60
    return history.filter { $0.monotonicTime >= cutoff }
  }

  private func canRun(_ token: UUID) -> Bool { self.token == token && isOpen && isConnected && !isPaused }

  private func stop() {
    token = UUID(); segment = UUID(); calculator.reset()
    let pending = task, oldClient = client, previousCleanup = cleanup
    pending?.cancel(); task = nil; client = nil
    cleanup = Task {
      await oldClient?.close()
      await pending?.value
      await previousCleanup?.value
    }
  }

  private func start() {
    guard task == nil, isOpen, isConnected, !isPaused else { return }
    let token = UUID(); self.token = token
    let previousCleanup = cleanup, factory = factory, sleep = sleep, interval = interval
    state = .connecting
    task = Task { [weak self] in
      await previousCleanup?.value
      var owned: (any ServerMonitoringClient)?
      while !Task.isCancelled, self?.canRun(token) == true {
        do {
          if owned == nil {
            self?.state = .connecting
            let opened = try await factory()
            owned = opened
            try Task.checkCancellation()
            guard self?.canRun(token) == true else { throw CancellationError() }
            self?.client = opened
          }
          self?.state = .sampling
          guard let samplingClient = owned else { throw SSHError.disconnected }
          let sample = try await samplingClient.sample()
          try Task.checkCancellation()
          guard self?.canRun(token) == true else { throw CancellationError() }
          self?.receive(sample)
          // Schedule after completion, never every N seconds regardless of a slow query.
          try await sleep(interval)
        } catch {
          guard !Task.isCancelled, self?.canRun(token) == true else { break }
          self?.failed(error)
          if let owned { await owned.close() }
          owned = nil; self?.client = nil
          if Self.isPermanent(error) { break }
          do { try await sleep(interval) } catch { break }
        }
      }
      if let owned { await owned.close() }
      if self?.token == token { self?.client = nil; self?.task = nil }
    }
  }

  private func receive(_ sample: LinuxServerSample) {
    if let old = current?.sample,
       (old.bootID.value != nil && sample.bootID.value != nil && old.bootID.value != sample.bootID.value) ||
       (old.uptime.value != nil && sample.uptime.value != nil && sample.uptime.value! < old.uptime.value!) { segment = UUID() }
    let snapshot = calculator.consume(sample)
    current = snapshot
    history.append(.init(segment: segment, capturedAt: sample.capturedAt, monotonicTime: sample.monotonicTime,
      cpuPercent: snapshot.cpu.value?.totalPercent, memoryPercent: sample.memory.value?.usagePercent,
      load: sample.load.value, network: snapshot.network.value ?? []))
    prune(at: max(now(), sample.monotonicTime))
    state = .live
  }

  private func prune(at time: TimeInterval) {
    history.removeAll { $0.monotonicTime < time - Self.historyDuration }
    if history.count > Self.maximumHistoryCount { history.removeFirst(history.count - Self.maximumHistoryCount) }
  }

  private func failed(_ error: Error) {
    calculator.reset(); segment = UUID(); refreshTime()
    let message = Self.message(error)
    state = Self.isPermanent(error) ? .unavailable(message) : .failed(message)
  }

  private static func isPermanent(_ error: Error) -> Bool {
    if case .unsupportedPlatform = error as? ServerMonitoringError { return true }
    if let error = error as? SSHError {
      switch error { case .hostKeyRejected, .hostKeyMismatch, .authenticationFailed: return true; default: break }
    }
    return false
  }
  private static func message(_ error: Error) -> String {
    if let error = error as? SSHError {
      switch error {
      case .hostKeyRejected: return "监控主机密钥尚未受信任，请先连接终端确认。"
      case .hostKeyMismatch: return "监控主机密钥已变化，请检查服务器并重新连接终端。"
      case .authenticationFailed: return "监控 SSH 认证失败。"
      case .disconnected: return "监控连接已断开。"
      default: return "监控 SSH 连接或命令失败，稍后重试。"
      }
    }
    return String(error.localizedDescription.prefix(512))
  }
}
