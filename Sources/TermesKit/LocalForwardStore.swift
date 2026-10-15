import Foundation
import Combine
import SSHCore

/// Forwarding presets belong to an SSH endpoint and route, independently of credentials/name.
public struct LocalForwardDestination: Codable, Hashable, Sendable {
  public let hostname: String
  public let port: Int
  public let username: String
  /// Nil is the original direct-connection identity, keeping existing presets compatible.
  public let jumpHosts: [ForwardJumpIdentity]?

  public init(hostname: String, port: Int, username: String, jumpHosts: [ForwardJumpIdentity]? = nil) {
    self.hostname = hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    self.port = port
    self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
    self.jumpHosts = jumpHosts?.isEmpty == false ? jumpHosts : nil
  }

  public init(config: ConnectionConfig) {
    hostname = config.hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    port = config.port
    username = config.username.trimmingCharacters(in: .whitespacesAndNewlines)
    jumpHosts = config.jumpHosts.isEmpty ? nil : config.jumpHosts.map {
      ForwardJumpIdentity(hostname: $0.hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                          port: $0.port, username: $0.username.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  }

  fileprivate var isValid: Bool {
    let routeIsValid = jumpHosts.map { hops in
      !hops.isEmpty && hops.count <= ConnectionConfig.maximumJumpHosts && hops.allSatisfy {
        LocalForwardDestination(hostname: $0.hostname, port: $0.port, username: $0.username).isValid
          && $0.hostname == $0.hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
          && $0.username == $0.username.trimmingCharacters(in: .whitespacesAndNewlines)
      }
    } ?? true
    return routeIsValid
      && !hostname.isEmpty && !username.isEmpty && (1...65535).contains(port)
      && hostname == hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      && hostname.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil
      && username == username.trimmingCharacters(in: .whitespacesAndNewlines)
      && username.rangeOfCharacter(from: .controlCharacters) == nil
  }

  public var displayName: String {
    let host = hostname.contains(":") ? "[\(hostname)]" : hostname
    let name = "\(username)@\(host):\(port)"
    guard let jumpHosts else { return name }
    return name + "（经 " + jumpHosts.map { $0.hostname }.joined(separator: " → ") + "）"
  }
}

public struct ForwardJumpIdentity: Codable, Hashable, Sendable {
  public let hostname: String
  public let port: Int
  public let username: String
}

public struct SavedLocalForward: Codable, Equatable, Sendable {
  public let id: UUID
  public let destination: LocalForwardDestination
  public let configuration: LocalForwardConfiguration

  public init(id: UUID = UUID(), destination: LocalForwardDestination, configuration: LocalForwardConfiguration) {
    self.id = id; self.destination = destination; self.configuration = configuration
  }
}

public enum LocalForwardStoreError: Error, Equatable, LocalizedError {
  case invalidFile, destinationRequired, changedElsewhere, loading
  public var errorDescription: String? {
    switch self {
    case .invalidFile: return "端口转发文件无效或版本不支持，请检查 local-forwards.json；原文件未覆盖。"
    case .destinationRequired: return "请先连接 SSH，再保存此目标的端口转发规则。"
    case .changedElsewhere: return "该规则已在其他窗口修改或移除。请重新选中最新规则；当前草稿已保留。"
    case .loading: return "正在切换 SSH 目标，请稍后重试。"
    }
  }
}

/// One shared store per app. Read latest, validate, and atomically write before notifying.
/// Only endpoint/rule metadata is serialized; runtime state and credentials stay in memory.
@MainActor
public final class LocalForwardStore {
  private struct Document: Codable {
    let version: Int
    var rules: [SavedLocalForward]
  }
  private let fileURL: URL
  public let didChange = PassthroughSubject<Void, Never>()
  public init(fileURL: URL) { self.fileURL = fileURL }

  public func rules(for destination: LocalForwardDestination) throws -> [SavedLocalForward] {
    try load().rules.filter { $0.destination == destination }
  }

  @discardableResult
  public func save(id: UUID? = nil, destination: LocalForwardDestination,
                   configuration: LocalForwardConfiguration,
                   expected: LocalForwardConfiguration? = nil) throws -> SavedLocalForward {
    try configuration.validate()
    guard configuration.localPort > 0, destination.isValid else { throw LocalForwardError.invalidConfiguration }
    var document = try load()
    let rule = SavedLocalForward(id: id ?? UUID(), destination: destination, configuration: configuration)
    if let id {
      guard let index = document.rules.firstIndex(where: { $0.id == id && $0.destination == destination }),
            expected == nil || document.rules[index].configuration == expected else {
        throw LocalForwardStoreError.changedElsewhere
      }
      document.rules[index] = rule
    } else { document.rules.append(rule) }
    try write(document)
    return rule
  }

  public func delete(_ id: UUID, destination: LocalForwardDestination,
                     expected: LocalForwardConfiguration? = nil) throws {
    var document = try load()
    guard let index = document.rules.firstIndex(where: { $0.id == id && $0.destination == destination }),
          expected == nil || document.rules[index].configuration == expected else {
      throw LocalForwardStoreError.changedElsewhere
    }
    document.rules.remove(at: index)
    try write(document)
  }

  private func load() throws -> Document {
    let data: Data
    do { data = try Data(contentsOf: fileURL) }
    catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
      return Document(version: 1, rules: [])
    }
    let document: Document
    do { document = try JSONDecoder().decode(Document.self, from: data) }
    catch { throw LocalForwardStoreError.invalidFile }
    guard document.version == 1, Set(document.rules.map(\.id)).count == document.rules.count else {
      throw LocalForwardStoreError.invalidFile
    }
    for rule in document.rules {
      guard rule.destination.isValid, rule.configuration.localPort > 0 else { throw LocalForwardStoreError.invalidFile }
      do { try rule.configuration.validate() } catch { throw LocalForwardStoreError.invalidFile }
    }
    return document
  }

  private func write(_ document: Document) throws {
    try JSONEncoder().encode(document).write(to: fileURL, options: .atomic)
    didChange.send()
  }
}
