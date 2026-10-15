import Foundation
import CryptoKit

public struct ConnectionSnapshot: Codable, Sendable {
  public var profiles: [ConnectionProfile]
  public var keys: [SSHKey]
  public var encryptedSecrets: Data?
  public var version: String?
  public init(profiles: [ConnectionProfile], keys: [SSHKey],
              encryptedSecrets: Data? = nil, version: String? = nil) {
    self.profiles = profiles; self.keys = keys
    self.encryptedSecrets = encryptedSecrets; self.version = version
  }
}

public protocol SyncProvider: Sendable {
  var handlesSecrets: Bool { get }
  func pull() async throws -> ConnectionSnapshot?
  func push(_ snapshot: ConnectionSnapshot, baseVersion: String?) async throws -> String
}

public final class FileSyncProvider: SyncProvider {
  public let handlesSecrets = false
  private let fileURL: URL
  public init(fileURL: URL) { self.fileURL = fileURL }

  public func pull() async throws -> ConnectionSnapshot? {
    guard let data = try? Data(contentsOf: fileURL) else { return nil }
    return try JSONDecoder().decode(ConnectionSnapshot.self, from: data)
  }

  /// Overwrite-style export: `baseVersion` is ignored (no CAS/conflict detection); reserved for future remote providers.
  public func push(_ snapshot: ConnectionSnapshot, baseVersion: String?) async throws -> String {
    var snap = snapshot
    snap.encryptedSecrets = nil                 // non-secret provider: strip secrets
    snap.version = nil                          // version is derived, not stored inside the hashed body
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let body = try encoder.encode(snap)
    let version = Self.version(of: body)
    snap.version = version
    try encoder.encode(snap).write(to: fileURL, options: .atomic)
    return version
  }

  static func version(of data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
