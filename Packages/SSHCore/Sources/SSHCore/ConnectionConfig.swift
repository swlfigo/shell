import Foundation

public enum AuthMethod: Equatable, Sendable {
  case password(String)
  case privateKey(data: Data, passphrase: String?)
}

/// Ordered from the first host reachable by this Mac to the host next to the destination.
public struct JumpHost: Equatable, Sendable {
  public var hostname: String
  public var port: Int
  public var username: String
  public var auth: AuthMethod
  public init(hostname: String, port: Int = 22, username: String, auth: AuthMethod) {
    self.hostname = hostname; self.port = port; self.username = username; self.auth = auth
  }
  var config: ConnectionConfig {
    .init(hostname: hostname, port: port, username: username, auth: auth)
  }
}

struct SSHNetworkEndpoint: Sendable {
  let hostname: String
  let port: Int
}

public struct ConnectionConfig: Equatable, Sendable {
  public var hostname: String
  public var port: Int
  public var username: String
  public var auth: AuthMethod
  public var jumpHosts: [JumpHost]
  public static let maximumJumpHosts = 8

  public init(hostname: String, port: Int = 22, username: String, auth: AuthMethod,
              jumpHosts: [JumpHost] = []) {
    self.hostname = hostname
    self.port = port
    self.username = username
    self.auth = auth
    self.jumpHosts = jumpHosts
  }
}
