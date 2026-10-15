import Foundation

public protocol ConnectionStoring: Sendable {
  func all() throws -> [ConnectionProfile]
  func get(_ id: UUID) throws -> ConnectionProfile?
  func upsert(_ p: ConnectionProfile) throws
  func delete(_ id: UUID) throws
}

public protocol KeyStoring: Sendable {
  func all() throws -> [SSHKey]
  func get(_ id: UUID) throws -> SSHKey?
  func upsert(_ k: SSHKey) throws
  func delete(_ id: UUID) throws
}

public final class ConnectionStore: ConnectionStoring {
  private let fileURL: URL
  private let queue = DispatchQueue(label: "connections")
  public init(fileURL: URL) { self.fileURL = fileURL }

  private func load() throws -> [ConnectionProfile] {
    guard let data = try? Data(contentsOf: fileURL) else { return [] }
    return try JSONDecoder().decode([ConnectionProfile].self, from: data)
  }
  private func write(_ items: [ConnectionProfile]) throws {
    try JSONEncoder().encode(items).write(to: fileURL, options: .atomic)
  }
  public func all() throws -> [ConnectionProfile] { try queue.sync { try load() } }
  public func get(_ id: UUID) throws -> ConnectionProfile? {
    try queue.sync { try load().first { $0.id == id } }
  }
  public func upsert(_ p: ConnectionProfile) throws {
    try queue.sync {
      var items = try load()
      items.removeAll { $0.id == p.id }
      items.append(p)
      try write(items)
    }
  }
  public func delete(_ id: UUID) throws {
    try queue.sync {
      var items = try load()
      items.removeAll { $0.id == id }
      try write(items)
    }
  }
}

public final class KeyStore: KeyStoring {
  private let fileURL: URL
  private let queue = DispatchQueue(label: "sshkeys")
  public init(fileURL: URL) { self.fileURL = fileURL }

  private func load() throws -> [SSHKey] {
    guard let data = try? Data(contentsOf: fileURL) else { return [] }
    return try JSONDecoder().decode([SSHKey].self, from: data)
  }
  private func write(_ items: [SSHKey]) throws {
    try JSONEncoder().encode(items).write(to: fileURL, options: .atomic)
  }
  public func all() throws -> [SSHKey] { try queue.sync { try load() } }
  public func get(_ id: UUID) throws -> SSHKey? {
    try queue.sync { try load().first { $0.id == id } }
  }
  public func upsert(_ k: SSHKey) throws {
    try queue.sync {
      var items = try load()
      items.removeAll { $0.id == k.id }
      items.append(k)
      try write(items)
    }
  }
  public func delete(_ id: UUID) throws {
    try queue.sync {
      var items = try load()
      items.removeAll { $0.id == id }
      try write(items)
    }
  }
}
