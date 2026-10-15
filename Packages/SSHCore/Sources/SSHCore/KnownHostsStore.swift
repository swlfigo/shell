import Foundation

public protocol KnownHostsStoring: Sendable {
  func lookup(hostname: String, port: Int) throws -> KnownHost?
  func save(_ host: KnownHost) throws
  func all() throws -> [KnownHost]
}

public final class KnownHostsStore: KnownHostsStoring {
  private let fileURL: URL
  private let queue = DispatchQueue(label: "knownhosts")

  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  private func load() throws -> [KnownHost] {
    guard let data = try? Data(contentsOf: fileURL) else { return [] }
    return try JSONDecoder().decode([KnownHost].self, from: data)
  }

  private func write(_ hosts: [KnownHost]) throws {
    let data = try JSONEncoder().encode(hosts)
    try data.write(to: fileURL, options: .atomic)
  }

  public func all() throws -> [KnownHost] {
    try queue.sync { try load() }
  }

  public func lookup(hostname: String, port: Int) throws -> KnownHost? {
    try queue.sync { try load().first { $0.hostname == hostname && $0.port == port } }
  }

  public func save(_ host: KnownHost) throws {
    try queue.sync {
      var hosts = try load()
      hosts.removeAll { $0.hostname == host.hostname && $0.port == host.port }
      hosts.append(host)
      try write(hosts)
    }
  }
}
