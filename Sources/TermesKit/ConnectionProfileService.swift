import Foundation
import Combine
import SSHCore

public enum NewCredential {
  case password(String)
  case privateKey(data: Data, name: String, passphrase: String?)
  case existingKey(UUID)
}

public enum ProfileServiceError: Error, Equatable, LocalizedError {
  case profileNotFound
  case keyNotFound
  case credentialMissing
  case keyInUse(profileIds: [UUID])
  case invalidConnection
  case invalidKeyName
  case emptyPrivateKey
  case jumpProfileNotFound
  case jumpHostCycle
  case jumpHostLimit
  case jumpHostInUse(profileIds: [UUID])
  case jumpCredentialMissing(name: String)
  case invalidPrivateKey
  case keyChangedElsewhere
  case duplicateKey(keyId: UUID)
  case keyReplacementRollbackFailed

  public var errorDescription: String? {
    switch self {
    case .profileNotFound: return "连接已不存在"
    case .keyNotFound: return "私钥已不存在"
    case .credentialMissing: return "缺少本机凭据，请重新补录"
    case .keyInUse: return "私钥仍被连接使用，请先删除连接或更换其凭据"
    case .invalidConnection: return "请填写名称、主机、用户名和有效端口（1–65535）"
    case .invalidKeyName: return "请输入私钥名称"
    case .emptyPrivateKey: return "私钥文件不能为空"
    case .jumpProfileNotFound: return "跳板机连接已不存在，请重新选择"
    case .jumpHostCycle: return "跳板机不能引用自身或形成循环"
    case .jumpHostLimit: return "跳板机最多支持 \(ConnectionConfig.maximumJumpHosts) 台"
    case .jumpHostInUse: return "该服务器仍被其他连接用作跳板机，请先更换或移除跳板配置"
    case .jumpCredentialMissing(let name): return "跳板机「\(name)」缺少本机凭据，请选择该连接并更新凭据"
    case .invalidPrivateKey: return "无法识别该私钥，请检查文件格式和 PEM 私钥口令。支持 OpenSSH、RSA/EC/Ed25519 PEM，文件限 1 MiB。"
    case .keyChangedElsewhere: return "私钥或引用连接已变化，请重新选择并确认替换。"
    case .duplicateKey: return "新私钥已属于其他记录，请为连接选择那条已存私钥。"
    case .keyReplacementRollbackFailed: return "替换失败且无法完整恢复原记录，请核对本机凭据并重新补录私钥。"
    }
  }
}

/// Management metadata only; never exposes private key bytes or passphrases.
public struct SSHKeyInfo: Sendable {
  public let key: SSHKey
  public let connections: [ConnectionProfile]
  public let hasLocalCredential: Bool
}

@MainActor
public final class ConnectionProfileService {
  private let connectionStore: ConnectionStoring
  private let keyStore: KeyStoring
  private let secretStore: SecretStoring
  /// Fires after storage changes so open connect pages can reload.
  public let didChange = PassthroughSubject<Void, Never>()

  public init(connections: ConnectionStoring, keys: KeyStoring, secrets: SecretStoring) {
    self.connectionStore = connections
    self.keyStore = keys
    self.secretStore = secrets
  }

  public func profiles() throws -> [ConnectionProfile] {
    try connectionStore.all().sorted { $0.updatedAt > $1.updatedAt }
  }
  public func keys() throws -> [SSHKey] {
    try keyStore.all().map(resolvedKey).sorted { $0.updatedAt > $1.updatedAt }
  }

  private func resolvedKey(_ key: SSHKey) throws -> SSHKey {
    guard let data = try secretStore.data(for: .privateKey(key.id)) else { return key }
    let passphrase = try secretStore.data(for: .passphrase(key.id)).flatMap { String(data: $0, encoding: .utf8) }
    guard let identity = PrivateKeyIdentity.inspect(data, passphrase: passphrase) else { return key }
    var key = key
    key.fingerprint = identity.fingerprint; key.keyType = identity.keyType; key.isEncrypted = identity.isEncrypted
    return key
  }

  public func keyInfo() throws -> [SSHKeyInfo] {
    let profiles = try profiles()
    return try keys().map { key in
      let connections = profiles.filter {
        if case .privateKey(let id, _) = $0.auth { return id == key.id }
        return false
      }
      let needsPassphrase = key.isEncrypted == true || connections.contains {
        if case .privateKey(_, let required) = $0.auth { return required }
        return false
      }
      let hasKey = try secretStore.data(for: .privateKey(key.id))?.isEmpty == false
      let hasPassphrase = try secretStore.data(for: .passphrase(key.id)) != nil
      return SSHKeyInfo(key: key, connections: connections,
                        hasLocalCredential: hasKey && (!needsPassphrase || hasPassphrase))
    }
  }

  /// Editing the target preserves its identity, creation time and local credentials.
  @discardableResult
  public func updateConnection(_ id: UUID, name: String, hostname: String, port: Int,
                               username: String) throws -> ConnectionProfile {
    guard let profile = try connectionStore.get(id) else { throw ProfileServiceError.profileNotFound }
    return try updateConnection(id, name: name, hostname: hostname, port: port, username: username,
                                 jumpProfileId: profile.jumpProfileId)
  }

  @discardableResult
  public func updateConnection(_ id: UUID, name: String, hostname: String, port: Int,
                               username: String, jumpProfileId: UUID?) throws -> ConnectionProfile {
    guard var profile = try connectionStore.get(id) else { throw ProfileServiceError.profileNotFound }
    _ = try jumpProfiles(jumpProfileId, destination: id)
    let values = [name, hostname, username].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard values.allSatisfy({ !$0.isEmpty }), (1...65535).contains(port) else {
      throw ProfileServiceError.invalidConnection
    }
    profile.name = values[0]
    profile.hostname = values[1]
    profile.port = port
    profile.username = values[2]
    profile.jumpProfileId = jumpProfileId
    profile.updatedAt = Date()
    var graph = Dictionary(uniqueKeysWithValues: try connectionStore.all().map { ($0.id, $0) })
    graph[id] = profile
    for candidate in graph.values {
      _ = try jumpProfiles(candidate.jumpProfileId, destination: candidate.id, profiles: graph)
    }
    try connectionStore.upsert(profile)
    didChange.send()
    return profile
  }

  @discardableResult
  public func importKey(data: Data, name: String, passphrase: String?) throws -> SSHKey {
    let stored = try storeKey(data: data, name: name, passphrase: passphrase, now: Date())
    if stored.isNew { didChange.send() }
    return stored.key
  }

  /// Replaces one shared identity; new connections for every referrer use the new material.
  /// Rollback restores each attempted metadata write and both Keychain records on failure.
  @discardableResult
  public func replaceKey(_ id: UUID, data: Data, passphrase: String?, expected: SSHKey? = nil,
                         expectedProfileIds: [UUID]? = nil) throws -> SSHKey {
    guard let original = try keyStore.get(id) else { throw ProfileServiceError.keyNotFound }
    let current = try resolvedKey(original)
    let references = try connectionStore.all().filter {
      if case .privateKey(let keyId, _) = $0.auth { return keyId == id }; return false
    }
    guard expected.map({ $0 == current }) ?? true,
          expectedProfileIds.map({ Set($0) == Set(references.map(\.id)) }) ?? true else {
      throw ProfileServiceError.keyChangedElsewhere
    }
    guard let identity = PrivateKeyIdentity.inspect(data, passphrase: passphrase) else { throw ProfileServiceError.invalidPrivateKey }
    for other in try keys() where other.id != id && other.fingerprint == identity.fingerprint {
      throw ProfileServiceError.duplicateKey(keyId: other.id)
    }
    let password = usablePassphrase(passphrase)
    if identity.isEncrypted && password == nil { throw ProfileServiceError.credentialMissing }
    let oldData = try secretStore.data(for: .privateKey(id)), oldPassphrase = try secretStore.data(for: .passphrase(id))
    var replacement = original
    replacement.fingerprint = identity.fingerprint; replacement.keyType = identity.keyType
    replacement.isEncrypted = identity.isEncrypted; replacement.updatedAt = Date()
    var attempted: [ConnectionProfile] = []
    var touchedSecrets = false, touchedKey = false
    do {
      touchedSecrets = true
      try secretStore.set(data, for: .privateKey(id))
      try restoreSecret(password.map { Data($0.utf8) }, for: .passphrase(id))
      touchedKey = true
      try keyStore.upsert(replacement)
      for profile in references {
        attempted.append(profile)
        var updated = profile
        updated.auth = .privateKey(keyId: id, hasPassphrase: identity.isEncrypted || password != nil)
        updated.updatedAt = replacement.updatedAt
        try connectionStore.upsert(updated)
      }
    } catch {
      var restored = true
      for profile in attempted.reversed() { do { try connectionStore.upsert(profile) } catch { restored = false } }
      if touchedKey { do { try keyStore.upsert(original) } catch { restored = false } }
      if touchedSecrets {
        do { try restoreSecret(oldData, for: .privateKey(id)) } catch { restored = false }
        do { try restoreSecret(oldPassphrase, for: .passphrase(id)) } catch { restored = false }
      }
      if !restored { didChange.send(); throw ProfileServiceError.keyReplacementRollbackFailed }
      throw error
    }
    didChange.send()
    return replacement
  }

  private func usablePassphrase(_ passphrase: String?) -> String? {
    guard let passphrase, !passphrase.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    return passphrase
  }
  private func restoreSecret(_ data: Data?, for ref: SecretRef) throws {
    if let data { try secretStore.set(data, for: ref) } else { try secretStore.delete(ref) }
  }

  @discardableResult
  public func renameKey(_ id: UUID, name: String) throws -> SSHKey {
    guard var key = try keyStore.get(id) else { throw ProfileServiceError.keyNotFound }
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { throw ProfileServiceError.invalidKeyName }
    key.name = name
    key.updatedAt = Date()
    try keyStore.upsert(key)
    didChange.send()
    return key
  }

  public func makeConfig(for profileId: UUID) throws -> ConnectionConfig {
    guard let p = try connectionStore.get(profileId) else { throw ProfileServiceError.profileNotFound }
    let jumpHosts = try jumpHosts(for: p.jumpProfileId, destination: p.id)
    var config = try directConfig(p)
    config.jumpHosts = jumpHosts
    return config
  }

  /// Browsing saved forwarding rules needs only endpoint metadata, including the jump route.
  /// It must also work for imported connections whose credentials are absent on this Mac.
  public func forwardingDestination(for profileId: UUID) throws -> LocalForwardDestination {
    guard let profile = try connectionStore.get(profileId) else { throw ProfileServiceError.profileNotFound }
    let hops = try jumpProfiles(profile.jumpProfileId, destination: profile.id)
    return LocalForwardDestination(hostname: profile.hostname, port: profile.port, username: profile.username,
      jumpHosts: hops.map { ForwardJumpIdentity(hostname: $0.hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
        port: $0.port, username: $0.username.trimmingCharacters(in: .whitespacesAndNewlines)) })
  }

  /// Resolves metadata first so invalid imported routes cannot fall back to a direct connection.
  public func jumpHosts(for profileId: UUID?) throws -> [JumpHost] {
    try jumpHosts(for: profileId, destination: nil)
  }

  private func jumpHosts(for profileId: UUID?, destination: UUID?) throws -> [JumpHost] {
    try jumpProfiles(profileId, destination: destination).map { profile in
      do {
        let config = try directConfig(profile)
        return JumpHost(hostname: config.hostname, port: config.port, username: config.username, auth: config.auth)
      } catch ProfileServiceError.credentialMissing {
        throw ProfileServiceError.jumpCredentialMissing(name: profile.name)
      }
    }
  }

  private func jumpProfiles(_ profileId: UUID?, destination: UUID?,
                            profiles: [UUID: ConnectionProfile]? = nil) throws -> [ConnectionProfile] {
    var visited = Set<UUID>()
    if let destination { visited.insert(destination) }
    var chain: [ConnectionProfile] = []
    var next = profileId
    while let id = next {
      guard visited.insert(id).inserted else { throw ProfileServiceError.jumpHostCycle }
      guard chain.count < ConnectionConfig.maximumJumpHosts else { throw ProfileServiceError.jumpHostLimit }
      let profile: ConnectionProfile?
      if let profiles { profile = profiles[id] } else { profile = try connectionStore.get(id) }
      guard let profile else { throw ProfileServiceError.jumpProfileNotFound }
      chain.append(profile)
      next = profile.jumpProfileId
    }
    return chain.reversed()
  }

  private func directConfig(_ p: ConnectionProfile) throws -> ConnectionConfig {
    switch p.auth {
    case .password:
      guard let data = try secretStore.data(for: .password(p.id)),
            let pw = String(data: data, encoding: .utf8) else {
        throw ProfileServiceError.credentialMissing
      }
      return ConnectionConfig(hostname: p.hostname, port: p.port, username: p.username, auth: .password(pw))
    case .privateKey(let keyId, let hasPassphrase):
      guard let keyData = try secretStore.data(for: .privateKey(keyId)) else {
        throw ProfileServiceError.credentialMissing
      }
      let passphrase = try secretStore.data(for: .passphrase(keyId)).flatMap { String(data: $0, encoding: .utf8) }
      let encrypted = try keyStore.get(keyId)?.isEncrypted == true
      if (hasPassphrase || encrypted), passphrase == nil { throw ProfileServiceError.credentialMissing }
      return ConnectionConfig(hostname: p.hostname, port: p.port, username: p.username,
                              auth: .privateKey(data: keyData, passphrase: passphrase))
    }
  }

  /// Resolve an already-stored key into a config without persisting any profile.
  public func makeConfig(hostname: String, port: Int, username: String, existingKeyId: UUID, jumpProfileId: UUID? = nil) throws -> ConnectionConfig {
    guard let metadata = try keyStore.get(existingKeyId) else { throw ProfileServiceError.keyNotFound }
    guard let keyData = try secretStore.data(for: .privateKey(existingKeyId)) else {
      throw ProfileServiceError.credentialMissing
    }
    var passphrase: String?
    if let ppData = try secretStore.data(for: .passphrase(existingKeyId)) {
      passphrase = String(data: ppData, encoding: .utf8)
    }
    if try resolvedKey(metadata).isEncrypted == true, passphrase == nil { throw ProfileServiceError.credentialMissing }
    return ConnectionConfig(hostname: hostname, port: port, username: username,
                            auth: .privateKey(data: keyData, passphrase: passphrase),
                            jumpHosts: try jumpHosts(for: jumpProfileId))
  }

  @discardableResult
  public func saveConnection(name: String, hostname: String, port: Int,
                             username: String, credential: NewCredential, jumpProfileId: UUID? = nil) throws -> ConnectionProfile {
    let now = Date()
    let profileId = UUID()
    _ = try jumpProfiles(jumpProfileId, destination: profileId)
    let stored = try storeCredential(credential, profileId: profileId, now: now)
    let auth = stored.auth
    let p = ConnectionProfile(id: profileId, name: name, hostname: hostname, port: port,
                              username: username, auth: auth, jumpProfileId: jumpProfileId, createdAt: now, updatedAt: now)
    do {
      try connectionStore.upsert(p)
    } catch {
      try? secretStore.delete(.password(profileId))
      if let keyId = stored.newKeyId { discardKey(keyId) }
      throw error
    }
    didChange.send()
    return p
  }

  /// Repairs imported credentials or replaces an existing login without duplicating the profile.
  /// A different private key gets its own identity; duplicate public keys reuse local material.
  /// Other profiles sharing the previous identity continue to use it.
  @discardableResult
  public func updateCredential(for profileId: UUID, credential: NewCredential) throws -> ConnectionProfile {
    guard var p = try connectionStore.get(profileId) else { throw ProfileServiceError.profileNotFound }
    if case .existingKey(let keyId) = credential {
      _ = try makeConfig(hostname: p.hostname, port: p.port, username: p.username, existingKeyId: keyId)
    }
    let now = Date()
    let oldPassword = try secretStore.data(for: .password(profileId))
    var newKeyId: UUID?
    do {
      let stored = try storeCredential(credential, profileId: profileId, now: now)
      newKeyId = stored.newKeyId
      let auth = stored.auth
      p.auth = auth
      p.updatedAt = now
      if case .privateKey = auth { try secretStore.delete(.password(profileId)) }
      try connectionStore.upsert(p)
    } catch {
      // The metadata write can fail after Keychain succeeds. Preserve the previous login and
      // remove a newly imported key; an explicitly reused key always belongs to other profiles.
      if let oldPassword { try? secretStore.set(oldPassword, for: .password(profileId)) }
      else { try? secretStore.delete(.password(profileId)) }
      if let keyId = newKeyId { discardKey(keyId) }
      throw error
    }
    didChange.send()
    return p
  }

  private func storeCredential(_ credential: NewCredential, profileId: UUID, now: Date) throws -> (auth: AuthRef, newKeyId: UUID?) {
    let auth: AuthRef
    var newKeyId: UUID?
    switch credential {
    case .password(let pw):
      try secretStore.set(Data(pw.utf8), for: .password(profileId))
      auth = .password
    case .privateKey(let data, let keyName, let passphrase):
      let stored = try storeKey(data: data, name: keyName, passphrase: passphrase, now: now)
      if stored.isNew { newKeyId = stored.key.id }
      let hasPass: Bool
      if stored.isNew { hasPass = stored.key.isEncrypted == true || usablePassphrase(passphrase) != nil }
      else { hasPass = try stored.key.isEncrypted == true || secretStore.data(for: .passphrase(stored.key.id)) != nil }
      auth = .privateKey(keyId: stored.key.id, hasPassphrase: hasPass)
    case .existingKey(let keyId):
      guard try keyStore.get(keyId) != nil else { throw ProfileServiceError.keyNotFound }
      guard try secretStore.data(for: .privateKey(keyId))?.isEmpty == false else {
        throw ProfileServiceError.credentialMissing
      }
      let hasPass = try keyStore.get(keyId)?.isEncrypted == true || secretStore.data(for: .passphrase(keyId)) != nil
      auth = .privateKey(keyId: keyId, hasPassphrase: hasPass)
    }
    return (auth, newKeyId)
  }

  private func storeKey(data: Data, name: String, passphrase: String?, now: Date) throws -> (key: SSHKey, isNew: Bool) {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { throw ProfileServiceError.invalidKeyName }
    guard !data.isEmpty else { throw ProfileServiceError.emptyPrivateKey }
    guard data.count <= 1_048_576 else { throw ProfileServiceError.invalidPrivateKey }
    let identity = PrivateKeyIdentity.inspect(data, passphrase: passphrase)
    if let identity {
      for candidate in try keyStore.all() {
        // Imported metadata alone is not proof of local key identity; never reuse its secrets.
        guard let existingData = try secretStore.data(for: .privateKey(candidate.id)) else { continue }
        let existingPassphrase = try secretStore.data(for: .passphrase(candidate.id)).flatMap { String(data: $0, encoding: .utf8) }
        guard let existingIdentity = PrivateKeyIdentity.inspect(existingData, passphrase: existingPassphrase),
              existingIdentity.fingerprint == identity.fingerprint else { continue }
        var resolved = candidate
        resolved.fingerprint = existingIdentity.fingerprint; resolved.keyType = existingIdentity.keyType
        resolved.isEncrypted = existingIdentity.isEncrypted
        return (resolved, false)
      }
    }
    let key = SSHKey(name: name, keyType: identity?.keyType, fingerprint: identity?.fingerprint,
      isEncrypted: identity?.isEncrypted, createdAt: now, updatedAt: now)
    do {
      try secretStore.set(data, for: .privateKey(key.id))
      if let passphrase = usablePassphrase(passphrase) {
        try secretStore.set(Data(passphrase.utf8), for: .passphrase(key.id))
      }
      try keyStore.upsert(key)
    } catch {
      discardKey(key.id)
      throw error
    }
    return (key, true)
  }

  private func discardKey(_ id: UUID) {
    try? secretStore.delete(.privateKey(id))
    try? secretStore.delete(.passphrase(id))
    try? keyStore.delete(id)
  }

  public func deleteConnection(_ id: UUID) throws {
    let references = try connectionStore.all().filter { $0.jumpProfileId == id }.map(\.id)
    guard references.isEmpty else { throw ProfileServiceError.jumpHostInUse(profileIds: references) }
    try secretStore.delete(.password(id))   // tolerates not-found
    try connectionStore.delete(id)
    didChange.send()
  }

  public func deleteKey(_ id: UUID) throws {
    let referrers = try connectionStore.all().filter {
      if case .privateKey(let kid, _) = $0.auth { return kid == id }
      return false
    }.map(\.id)
    guard referrers.isEmpty else { throw ProfileServiceError.keyInUse(profileIds: referrers) }
    try secretStore.delete(.privateKey(id))
    try secretStore.delete(.passphrase(id))
    try keyStore.delete(id)
    didChange.send()
  }

  /// Non-secret import: upsert profiles/keys by id (last-writer-wins by updatedAt).
  /// Secrets are NOT imported; such profiles surface .credentialMissing until re-entered.
  public func importSnapshot(_ snap: ConnectionSnapshot) throws {
    var merged = Dictionary(uniqueKeysWithValues: try connectionStore.all().map { ($0.id, $0) })
    for profile in snap.profiles {
      if let old = merged[profile.id], old.updatedAt >= profile.updatedAt { continue }
      merged[profile.id] = profile
    }
    for profile in merged.values {
      _ = try jumpProfiles(profile.jumpProfileId, destination: profile.id, profiles: merged)
    }
    for k in snap.keys {
      if let existing = try keyStore.get(k.id), existing.updatedAt >= k.updatedAt { continue }
      try keyStore.upsert(k)
    }
    for p in snap.profiles {
      if let existing = try connectionStore.get(p.id), existing.updatedAt >= p.updatedAt { continue }
      try connectionStore.upsert(p)
    }
    didChange.send()
  }
}
