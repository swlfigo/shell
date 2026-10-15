import Foundation

public protocol ServerMonitoringClient: AnyObject, Sendable {
  func sample() async throws -> LinuxServerSample
  func close() async
}

/// Owns a dedicated monitoring transport. Closing it interrupts connect/exec without
/// touching a terminal or file transport, including for a routed SSH destination.
public actor SSHServerMonitoringClient: ServerMonitoringClient {
  private let connection: SSHConnection
  private let collector: LinuxServerCollector
  private var closed = false
  private var sampling = false

  private init(connection: SSHConnection) {
    self.connection = connection; self.collector = .init(connection: connection)
  }

  public static func connect(config: ConnectionConfig, knownHosts: KnownHostsStoring) async throws -> SSHServerMonitoringClient {
    let connection = SSHConnection(config: config, knownHosts: knownHosts, confirmUnknownHostKey: { _, _, _ in false })
    do {
      try Task.checkCancellation()
      try await connection.connect()
      try Task.checkCancellation()
      return .init(connection: connection)
    } catch { await connection.disconnect(); throw error }
  }

  deinit {
    let connection = connection
    Task { await connection.disconnect() }
  }

  public func sample() async throws -> LinuxServerSample {
    try Task.checkCancellation()
    guard !closed else { throw SSHError.disconnected }
    guard !sampling else { throw ServerMonitoringError.collectionInProgress }
    sampling = true
    defer { sampling = false }
    let result = try await collector.sample()
    try Task.checkCancellation()
    guard !closed else { throw SSHError.disconnected }
    return result
  }

  public func close() async { closed = true; await connection.disconnect() }
}
