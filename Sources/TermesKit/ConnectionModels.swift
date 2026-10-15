import Foundation

public struct SSHKey: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public var name: String
  public var keyType: String?
  public var fingerprint: String?
  public var isEncrypted: Bool?
  public var createdAt: Date
  public var updatedAt: Date
  public init(id: UUID = UUID(), name: String, keyType: String? = nil,
              fingerprint: String? = nil, isEncrypted: Bool? = nil,
              createdAt: Date = Date(), updatedAt: Date = Date()) {
    self.id = id; self.name = name; self.keyType = keyType
    self.fingerprint = fingerprint; self.isEncrypted = isEncrypted
    self.createdAt = createdAt; self.updatedAt = updatedAt
  }
}

public enum AuthRef: Codable, Equatable, Sendable {
  case password
  case privateKey(keyId: UUID, hasPassphrase: Bool)
}

public struct ConnectionProfile: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public var name: String
  public var hostname: String
  public var port: Int
  public var username: String
  public var auth: AuthRef
  public var jumpProfileId: UUID?
  public var createdAt: Date
  public var updatedAt: Date
  public init(id: UUID = UUID(), name: String, hostname: String, port: Int,
              username: String, auth: AuthRef, jumpProfileId: UUID? = nil,
              createdAt: Date = Date(), updatedAt: Date = Date()) {
    self.id = id; self.name = name; self.hostname = hostname; self.port = port
    self.username = username; self.auth = auth; self.jumpProfileId = jumpProfileId
    self.createdAt = createdAt; self.updatedAt = updatedAt
  }
}
