import Foundation

/// Identity metadata only. Credentials and remote error/output text never enter progress events.
public struct SSHProgressEndpoint: Equatable, Sendable {
  public let hostname, username: String
  public let port, index, jumpCount: Int
  public var isJumpHost: Bool { index < jumpCount }
  public init(hostname: String, port: Int, username: String, index: Int, jumpCount: Int) {
    self.hostname = Self.displayText(hostname, limit: 256); self.port = port
    self.username = Self.displayText(username, limit: 128)
    self.index = index; self.jumpCount = jumpCount
  }
  private static func displayText(_ value: String, limit: Int) -> String {
    String(String.UnicodeScalarView(value.unicodeScalars.prefix(limit).filter { !CharacterSet.controlCharacters.contains($0) }))
  }
}

public enum SSHProgressStage: Equatable, Sendable {
  case connection, hostKey, authentication, route, channel, pty, shell
}
public enum SSHProgressDetail: Equatable, Sendable { case tcpConnected, password, privateKey }
public enum SSHProgressFailure: Equatable, Sendable {
  case invalidConfiguration, connection, authentication, hostKeyRejected, hostKeyChanged, channel, cancelled, disconnected, unknown
  public var message: String {
    switch self {
    case .invalidConfiguration: return "连接配置无效。"
    case .connection: return "连接失败，请检查主机地址、网络和服务器 SSH 服务。"
    case .authentication: return "身份认证失败，请检查用户名与凭据。"
    case .hostKeyRejected: return "主机密钥未受信任，连接已结束。"
    case .hostKeyChanged: return "主机密钥已变化，请核对服务器身份。"
    case .channel: return "服务器未能打开所需的 SSH 通道或终端。"
    case .cancelled: return "连接已取消。"
    case .disconnected: return "SSH 连接已断开。"
    case .unknown: return "连接未能完成。"
    }
  }
  static func classify(_ error: Error) -> Self {
    if error is CancellationError || Task.isCancelled { return .cancelled }
    switch error as? SSHError {
    case .authenticationFailed: return .authentication
    case .hostKeyRejected: return .hostKeyRejected
    case .hostKeyMismatch: return .hostKeyChanged
    case .connectionFailed: return .connection
    case .channelFailure: return .channel
    case .disconnected: return .disconnected
    case nil: return error is LocalForwardError ? .channel : .unknown
    }
  }
}
public enum SSHProgressStatus: Equatable, Sendable {
  case started, waitingForTrust(fingerprint: String), succeeded, failed(SSHProgressFailure)
}
public struct SSHConnectionProgressEvent: Equatable, Sendable {
  public let sequence: UInt64
  public let timestamp: Date
  public let endpoint: SSHProgressEndpoint
  public let stage: SSHProgressStage
  public let status: SSHProgressStatus
  public let detail: SSHProgressDetail?
  public init(sequence: UInt64, timestamp: Date = Date(), endpoint: SSHProgressEndpoint,
              stage: SSHProgressStage, status: SSHProgressStatus, detail: SSHProgressDetail? = nil) {
    self.sequence = sequence; self.timestamp = timestamp; self.endpoint = endpoint
    self.stage = stage; self.status = status; self.detail = detail
  }
}

/// Called synchronously in event order, including from an SSH queue. Handlers should enqueue
/// their work (for example with AsyncStream.yield) and return promptly.
public typealias SSHConnectionProgressHandler = @Sendable (SSHConnectionProgressEvent) -> Void

/// Shares one ordered delivery across the destination and all jump control transports.
/// Endpoint-local state makes outer cleanup unable to report a hop failure as a target failure.
final class SSHProgressReporter: @unchecked Sendable {
  private final class Delivery: @unchecked Sendable {
    let lock = NSLock()
    let handler: SSHConnectionProgressHandler
    var sequence: UInt64 = 0
    init(_ handler: @escaping SSHConnectionProgressHandler) { self.handler = handler }
  }
  private let delivery: Delivery
  let endpoint: SSHProgressEndpoint
  private var stage: SSHProgressStage = .connection
  private var ended = false
  init(config: ConnectionConfig, handler: @escaping SSHConnectionProgressHandler) {
    endpoint = .init(hostname: config.hostname, port: config.port, username: config.username,
      index: config.jumpHosts.count, jumpCount: config.jumpHosts.count)
    delivery = Delivery(handler)
  }
  private init(endpoint: SSHProgressEndpoint, delivery: Delivery) { self.endpoint = endpoint; self.delivery = delivery }
  func hop(_ hop: JumpHost, index: Int) -> SSHProgressReporter {
    .init(endpoint: .init(hostname: hop.hostname, port: hop.port, username: hop.username,
      index: index, jumpCount: endpoint.jumpCount), delivery: delivery)
  }
  func reset() { delivery.lock.withLock { stage = .connection; ended = false } }
  func send(_ stage: SSHProgressStage, _ status: SSHProgressStatus, detail: SSHProgressDetail? = nil) {
    delivery.lock.withLock {
      guard !ended else { return }
      self.stage = stage
      if case .failed = status { ended = true }
      emit(stage, status, detail: detail)
    }
  }
  func fail(_ error: Error) {
    delivery.lock.withLock {
      guard !ended else { return }
      ended = true
      emit(stage, .failed(.classify(error)), detail: nil)
    }
  }
  private func emit(_ stage: SSHProgressStage, _ status: SSHProgressStatus, detail: SSHProgressDetail?) {
    delivery.sequence &+= 1
    delivery.handler(.init(sequence: delivery.sequence, endpoint: endpoint, stage: stage, status: status, detail: detail))
  }
}
