import Foundation
import Security

public struct SecretRef: Hashable, Sendable {
  public let account: String
  public init(account: String) { self.account = account }
  public static func password(_ profileId: UUID) -> SecretRef {
    .init(account: "profile:\(profileId.uuidString):password")
  }
  public static func privateKey(_ keyId: UUID) -> SecretRef {
    .init(account: "key:\(keyId.uuidString):privateKey")
  }
  public static func passphrase(_ keyId: UUID) -> SecretRef {
    .init(account: "key:\(keyId.uuidString):passphrase")
  }
}

public enum SecretError: Error, Equatable, LocalizedError {
  case keychain(OSStatus)
  public var errorDescription: String? {
    switch self { case .keychain(let s): return "Keychain error (OSStatus \(s))" }
  }
}

public protocol SecretStoring: Sendable {
  func data(for ref: SecretRef) throws -> Data?
  func set(_ data: Data, for ref: SecretRef) throws
  func delete(_ ref: SecretRef) throws
}

public final class KeychainSecretStore: SecretStoring {
  private let service: String
  public init(service: String) { self.service = service }

  private func baseQuery(_ ref: SecretRef) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: service,
     kSecAttrAccount as String: ref.account]
  }

  public func data(for ref: SecretRef) throws -> Data? {
    var q = baseQuery(ref)
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var out: CFTypeRef?
    let status = SecItemCopyMatching(q as CFDictionary, &out)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw SecretError.keychain(status) }
    return out as? Data
  }

  public func set(_ data: Data, for ref: SecretRef) throws {
    let status = SecItemUpdate(baseQuery(ref) as CFDictionary,
                               [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      var add = baseQuery(ref)
      add[kSecValueData as String] = data
      add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
      let addStatus = SecItemAdd(add as CFDictionary, nil)
      guard addStatus == errSecSuccess else { throw SecretError.keychain(addStatus) }
    } else {
      guard status == errSecSuccess else { throw SecretError.keychain(status) }
    }
  }

  public func delete(_ ref: SecretRef) throws {
    let status = SecItemDelete(baseQuery(ref) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw SecretError.keychain(status)
    }
  }
}

/// Reads the current namespace first and copies legacy credentials lazily on first use.
/// Deletion clears both namespaces so an older credential cannot reappear through fallback.
public final class LegacyCompatibleSecretStore: SecretStoring {
  private let primary: any SecretStoring
  private let legacy: any SecretStoring
  private let lock = NSLock()

  public init(primary: any SecretStoring, legacy: any SecretStoring) {
    self.primary = primary
    self.legacy = legacy
  }

  public func data(for ref: SecretRef) throws -> Data? {
    lock.lock(); defer { lock.unlock() }
    if let data = try primary.data(for: ref) { return data }
    guard let data = try legacy.data(for: ref) else { return nil }
    try primary.set(data, for: ref)
    return data
  }

  public func set(_ data: Data, for ref: SecretRef) throws {
    lock.lock(); defer { lock.unlock() }
    try primary.set(data, for: ref)
  }

  public func delete(_ ref: SecretRef) throws {
    lock.lock(); defer { lock.unlock() }
    // Keep the primary credential intact if legacy cleanup fails.
    try legacy.delete(ref)
    try primary.delete(ref)
  }
}

public final class InMemorySecretStore: SecretStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var store: [String: Data] = [:]
  public init() {}
  public func data(for ref: SecretRef) throws -> Data? {
    lock.lock(); defer { lock.unlock() }; return store[ref.account]
  }
  public func set(_ data: Data, for ref: SecretRef) throws {
    lock.lock(); defer { lock.unlock() }; store[ref.account] = data
  }
  public func delete(_ ref: SecretRef) throws {
    lock.lock(); defer { lock.unlock() }; store[ref.account] = nil
  }
}
