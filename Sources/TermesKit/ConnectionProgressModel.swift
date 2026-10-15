import Foundation
import Combine
import SSHCore

public enum ConnectionProgressStepState: Equatable, Sendable {
  case waiting, running, waitingForTrust, succeeded, failed(String), cancelled
}
public struct ConnectionProgressNode: Equatable, Sendable, Identifiable {
  public var id: Int { endpoint.index }
  public let endpoint: SSHProgressEndpoint
  /// connection, host identity, user authentication, route/terminal, ready.
  public var steps: [ConnectionProgressStepState] = Array(repeating: .waiting, count: 5)
}
public struct ConnectionProgressLog: Equatable, Sendable, Identifiable {
  public let id = UUID()
  public let timestamp: Date
  public let attempt: Int
  public let text: String
}

/// Bounded, credential-free presentation of one pane's actual connection attempts.
@MainActor
public final class ConnectionProgressModel: ObservableObject {
  public enum State: Equatable, Sendable {
    case idle, running, waitingForTrust, ready, cancelled, disconnected
    case failed(String), waitingRetry(seconds: Int)
  }
  public static let maximumLogCount = 200
  @Published public private(set) var state: State = .idle
  @Published public private(set) var nodes: [ConnectionProgressNode] = []
  @Published public private(set) var logs: [ConnectionProgressLog] = []
  @Published public private(set) var currentNodeIndex = 0
  @Published public private(set) var attempt = 1
  private var token = UUID()
  private var lastSequence: UInt64 = 0
  public init() {}
  public var attemptID: UUID { token }
  public var currentNode: ConnectionProgressNode? { nodes.indices.contains(currentNodeIndex) ? nodes[currentNodeIndex] : nil }
  public var canCancel: Bool {
    switch state { case .running, .waitingForTrust, .waitingRetry: return true; default: return false }
  }

  @discardableResult
  public func begin(config: ConnectionConfig, attempt: Int = 1) -> UUID {
    let jumpCount = config.jumpHosts.count
    var endpoints = config.jumpHosts.prefix(ConnectionConfig.maximumJumpHosts).enumerated().map { index, hop in
      SSHProgressEndpoint(hostname: hop.hostname, port: hop.port, username: hop.username, index: index, jumpCount: jumpCount)
    }
    endpoints.append(.init(hostname: config.hostname, port: config.port, username: config.username, index: jumpCount, jumpCount: jumpCount))
    if nodes.map(\.endpoint) != endpoints { logs = [] }
    token = UUID(); lastSequence = 0; self.attempt = max(1, attempt)
    nodes = endpoints.map { .init(endpoint: $0) }; currentNodeIndex = 0; state = .running
    append("开始第 \(self.attempt) 次连接", at: Date())
    return token
  }

  public func receive(_ event: SSHConnectionProgressEvent, token: UUID) {
    guard token == self.token, event.sequence > lastSequence,
          state == .running || state == .waitingForTrust,
          let index = nodes.firstIndex(where: { $0.endpoint == event.endpoint }) else { return }
    lastSequence = event.sequence; currentNodeIndex = index
    let step = Self.step(event.stage)
    var node = nodes[index]
    switch event.status {
    case .started:
      node.steps[step] = .running; state = .running
    case .waitingForTrust:
      node.steps[step] = .waitingForTrust; state = .waitingForTrust
    case .succeeded:
      // Channel-open and PTY success are substeps, not an opened interactive shell.
      node.steps[step] = [.channel, .pty].contains(event.stage) ? .running : .succeeded
      if event.stage == .route { node.steps[4] = .succeeded }
      state = .running
    case .failed(let failure):
      node.steps[step] = failure == .cancelled ? .cancelled : .failed(failure.message)
      state = failure == .cancelled ? .cancelled : .failed(failure.message)
    }
    nodes[index] = node
    let role = event.endpoint.isJumpHost ? "跳板 \(event.endpoint.index + 1)/\(event.endpoint.jumpCount)" : "目标"
    let host = event.endpoint.hostname.contains(":") ? "[\(event.endpoint.hostname)]" : event.endpoint.hostname
    append("[\(role) \(event.endpoint.username)@\(host):\(event.endpoint.port)] [\(Self.stageName(event.stage))] \(Self.statusText(event))", at: event.timestamp)
  }

  @discardableResult
  public func ready(token: UUID) -> Bool {
    guard token == self.token, state == .running, let index = nodes.indices.last,
          nodes[index].steps.prefix(4).allSatisfy({ $0 == .succeeded }) else { return false }
    nodes[index].steps[4] = .succeeded; currentNodeIndex = index; state = .ready
    append("终端已打开，连接就绪", at: Date()); return true
  }
  public func fail(token: UUID) {
    guard token == self.token, state == .running || state == .waitingForTrust else { return }
    let reason = SSHProgressFailure.unknown.message
    if nodes.indices.contains(currentNodeIndex) {
      let step = nodes[currentNodeIndex].steps.firstIndex { $0 == .running || $0 == .waitingForTrust } ?? 0
      nodes[currentNodeIndex].steps[step] = .failed(reason)
    }
    state = .failed(reason); append(reason, at: Date())
  }
  public func waitingRetry(seconds: Int, token: UUID) {
    guard token == self.token, case .failed = state else { return }
    state = .waitingRetry(seconds: max(1, seconds))
    append("\(max(1, seconds)) 秒后自动重试", at: Date())
  }
  public func endConnection() {
    let cancelling = canCancel
    token = UUID()
    if cancelling {
      if nodes.indices.contains(currentNodeIndex), let step = nodes[currentNodeIndex].steps.firstIndex(where: { $0 == .running || $0 == .waitingForTrust }) {
        nodes[currentNodeIndex].steps[step] = .cancelled
      }
      state = .cancelled; append("连接已取消", at: Date())
    } else if state == .ready {
      state = .disconnected; append("连接已断开", at: Date())
    }
  }
  private func append(_ text: String, at timestamp: Date) {
    let bounded = String(String.UnicodeScalarView(text.unicodeScalars.prefix(512).filter { !CharacterSet.controlCharacters.contains($0) }))
    logs.append(.init(timestamp: timestamp, attempt: attempt, text: bounded))
    if logs.count > Self.maximumLogCount { logs.removeFirst(logs.count - Self.maximumLogCount) }
  }
  private static func step(_ stage: SSHProgressStage) -> Int {
    switch stage { case .connection: return 0; case .hostKey: return 1; case .authentication: return 2; case .route, .channel, .pty, .shell: return 3 }
  }
  private static func stageName(_ stage: SSHProgressStage) -> String {
    switch stage {
    case .connection: return "建立连接"
    case .hostKey: return "主机校验"
    case .authentication: return "身份认证"
    case .route: return "准备下一跳"
    case .channel: return "打开通道"
    case .pty: return "申请终端"
    case .shell: return "启动 shell"
    }
  }
  private static func statusText(_ event: SSHConnectionProgressEvent) -> String {
    switch event.status {
    case .started:
      switch event.detail {
      case .tcpConnected: return "TCP 已建立，开始 SSH 握手"
      case .password: return "开始密码认证"
      case .privateKey: return "开始私钥认证"
      case nil: return "开始"
      }
    case .succeeded: return "已完成"
    case .waitingForTrust(let fingerprint): return "等待信任确认 · \(fingerprint)"
    case .failed(let failure): return failure.message
    }
  }
}
