import Foundation

public enum LocalForwardKind: String, Codable, Equatable, Sendable {
  case local, socks, remote
}

public struct LocalForwardConfiguration: Codable, Equatable, Sendable {
  /// Zero asks the OS for an available port. The app's form requires an explicit port.
  public let localPort: Int
  public let targetHost: String
  public let targetPort: Int
  public let kind: LocalForwardKind
  public let listenHost: String

  public init(localPort: Int, targetHost: String = "", targetPort: Int = 0, kind: LocalForwardKind = .local,
              listenHost: String = "127.0.0.1") {
    self.localPort = localPort
    self.targetHost = targetHost.trimmingCharacters(in: .whitespacesAndNewlines)
    self.targetPort = targetPort
    self.kind = kind
    self.listenHost = listenHost.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private enum CodingKeys: String, CodingKey { case localPort, targetHost, targetPort, kind, listenHost }
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    localPort = try values.decode(Int.self, forKey: .localPort)
    targetHost = try values.decode(String.self, forKey: .targetHost)
    targetPort = try values.decode(Int.self, forKey: .targetPort)
    // Existing version-1 presets predate the kind field and remain local forwards.
    kind = try values.decodeIfPresent(LocalForwardKind.self, forKey: .kind) ?? .local
    listenHost = try values.decodeIfPresent(String.self, forKey: .listenHost) ?? "127.0.0.1"
  }

  public func validate() throws {
    guard (0...65535).contains(localPort) else { throw LocalForwardError.invalidConfiguration }
    if kind == .remote {
      guard !listenHost.isEmpty, listenHost.utf8.count <= 1024,
            listenHost.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
            !listenHost.contains("/") else { throw LocalForwardError.invalidConfiguration }
    } else if listenHost != "127.0.0.1" { throw LocalForwardError.invalidConfiguration }
    if kind == .socks {
      guard targetHost.isEmpty, targetPort == 0 else { throw LocalForwardError.invalidConfiguration }
      return
    }
    guard (1...65535).contains(targetPort),
          !targetHost.isEmpty, targetHost.utf8.count <= 1024,
          targetHost.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
          !targetHost.contains("/") else { throw LocalForwardError.invalidConfiguration }
  }
}

public enum LocalForwardError: Error, Equatable, Sendable, LocalizedError {
  case invalidConfiguration, notConnected, tooManyClients
  case listen(String), remoteListen(String), target(String), transport(String), socks(String)

  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration: return "请填写有效的监听端口（1–65535）及地址；本地/远端转发还需目标主机和目标端口。"
    case .notConnected: return "请先连接 SSH，再启动端口转发。"
    case .tooManyClients: return "本条转发已有 32 个客户端，请稍后重试。"
    case .listen(let message): return "本机端口监听失败：\(message)"
    case .remoteListen(let message): return "服务器端口监听失败（请检查端口占用、转发权限与 GatewayPorts）：\(message)"
    case .target(let message): return "目标连接失败：\(message)"
    case .transport(let message): return "转发 SSH 连接断开：\(message)"
    case .socks(let message): return "SOCKS5 客户端请求失败：\(message)"
    }
  }
}

public enum LocalForwardEvent: Equatable, Sendable {
  case clients(Int)
  /// One local client failed; the listener remains available for another attempt.
  case clientError(String)
  case stopped(error: String?)
}

public protocol LocalForwarding: AnyObject, Sendable {
  /// The bound listening port; for a remote forward this belongs to the SSH server.
  var localPort: Int { get }
  var events: AsyncStream<LocalForwardEvent> { get }
  func stop() async
}
