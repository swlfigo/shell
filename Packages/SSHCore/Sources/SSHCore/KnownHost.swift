import Foundation

public struct KnownHost: Codable, Equatable {
  public let hostname: String
  public let port: Int
  public let keyType: String
  public let publicKeyBlob: Data
  public let fingerprintSHA256: String
  public let addedAt: Date

  public init(hostname: String, port: Int, keyType: String, publicKeyBlob: Data, fingerprintSHA256: String, addedAt: Date) {
    self.hostname = hostname
    self.port = port
    self.keyType = keyType
    self.publicKeyBlob = publicKeyBlob
    self.fingerprintSHA256 = fingerprintSHA256
    self.addedAt = addedAt
  }
}
