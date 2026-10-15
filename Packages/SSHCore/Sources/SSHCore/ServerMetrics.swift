import Foundation

public enum ServerMetricUnavailable: Equatable, Sendable {
  case missingData, commandFailed, invalidData, limitExceeded, waitingForBaseline, counterReset, invalidInterval
}

public enum ServerMetric<Value: Equatable & Sendable>: Equatable, Sendable {
  case value(Value)
  case unavailable(ServerMetricUnavailable)
  public var value: Value? { if case .value(let value) = self { value } else { nil } }
}

public struct ServerSystemIdentity: Equatable, Sendable {
  public let kernelRelease, architecture, hostname, operatingSystem: ServerMetric<String>
  public init(kernelRelease: ServerMetric<String>, architecture: ServerMetric<String>,
              hostname: ServerMetric<String>, operatingSystem: ServerMetric<String>) {
    self.kernelRelease = kernelRelease; self.architecture = architecture
    self.hostname = hostname; self.operatingSystem = operatingSystem
  }
}

/// First eight /proc/stat counters. user/nice already include guest time.
public struct LinuxCPUCounters: Equatable, Sendable {
  public let values: [UInt64]
  public init(_ values: [UInt64]) { self.values = values }
}

public struct ServerMemoryUsage: Equatable, Sendable {
  public let totalBytes, usedBytes, availableBytes: UInt64
  public var usagePercent: Double? { totalBytes == 0 ? nil : Double(usedBytes) / Double(totalBytes) * 100 }
  public init(totalBytes: UInt64, usedBytes: UInt64, availableBytes: UInt64) {
    self.totalBytes = totalBytes; self.usedBytes = usedBytes; self.availableBytes = availableBytes
  }
}

public struct ServerDiskUsage: Equatable, Sendable {
  public let filesystem, mountPoint: String
  public let totalBytes, usedBytes: UInt64
  /// df can report negative availability. Reserved space is not counted as used.
  public let availableBytes: Int64
  public let usagePercent: ServerMetric<Double>
  public init(filesystem: String, mountPoint: String, totalBytes: UInt64, usedBytes: UInt64,
              availableBytes: Int64, usagePercent: ServerMetric<Double>) {
    self.filesystem = filesystem; self.mountPoint = mountPoint; self.totalBytes = totalBytes
    self.usedBytes = usedBytes; self.availableBytes = availableBytes; self.usagePercent = usagePercent
  }
}

public struct ServerNetworkCounters: Equatable, Sendable {
  public let name: String
  public let receivedBytes, transmittedBytes: UInt64
  public init(name: String, receivedBytes: UInt64, transmittedBytes: UInt64) {
    self.name = name; self.receivedBytes = receivedBytes; self.transmittedBytes = transmittedBytes
  }
}

public struct ServerLoadAverage: Equatable, Sendable {
  public let oneMinute, fiveMinutes, fifteenMinutes: Double
  public init(oneMinute: Double, fiveMinutes: Double, fifteenMinutes: Double) {
    self.oneMinute = oneMinute; self.fiveMinutes = fiveMinutes; self.fifteenMinutes = fifteenMinutes
  }
}

/// A single collection, before CPU/network deltas. Clock time is for display only;
/// monotonicTime measures the actual interval between completed collections.
public struct LinuxServerSample: Equatable, Sendable {
  public let capturedAt: Date
  public let monotonicTime: TimeInterval
  public let identity: ServerSystemIdentity
  public let bootID: ServerMetric<String>
  public let cpu: ServerMetric<LinuxCPUCounters>
  public let memory, swap: ServerMetric<ServerMemoryUsage>
  public let disks: ServerMetric<[ServerDiskUsage]>
  public let network: ServerMetric<[ServerNetworkCounters]>
  public let load: ServerMetric<ServerLoadAverage>
  public let uptime: ServerMetric<TimeInterval>

  public init(capturedAt: Date, monotonicTime: TimeInterval, identity: ServerSystemIdentity,
              bootID: ServerMetric<String>, cpu: ServerMetric<LinuxCPUCounters>,
              memory: ServerMetric<ServerMemoryUsage>, swap: ServerMetric<ServerMemoryUsage>,
              disks: ServerMetric<[ServerDiskUsage]>, network: ServerMetric<[ServerNetworkCounters]>,
              load: ServerMetric<ServerLoadAverage>, uptime: ServerMetric<TimeInterval>) {
    self.capturedAt = capturedAt; self.monotonicTime = monotonicTime; self.identity = identity
    self.bootID = bootID; self.cpu = cpu; self.memory = memory; self.swap = swap
    self.disks = disks; self.network = network; self.load = load; self.uptime = uptime
  }
}

public struct ServerCPUUsage: Equatable, Sendable {
  public let totalPercent, userPercent, systemPercent: Double
}

public struct ServerNetworkRate: Equatable, Sendable {
  public let name: String
  /// Receive = inbound to server; transmit = outbound from server. No interface aggregation.
  public let receivedBytesPerSecond, transmittedBytesPerSecond: ServerMetric<Double>
}

public struct ServerMetricsSnapshot: Equatable, Sendable {
  public let sample: LinuxServerSample
  public let cpu: ServerMetric<ServerCPUUsage>
  public let network: ServerMetric<[ServerNetworkRate]>
}

/// Reset on reconnect, target change, or any failed collection to prevent rates spanning a gap.
public struct ServerMetricsCalculator: Sendable {
  private var previous: LinuxServerSample?
  public init() {}
  public mutating func reset() { previous = nil }

  public mutating func consume(_ sample: LinuxServerSample) -> ServerMetricsSnapshot {
    defer { previous = sample }
    let old = previous
    let reboot = old.map { prior in
      if let first = prior.bootID.value, let second = sample.bootID.value, first != second { return true }
      if let first = prior.uptime.value, let second = sample.uptime.value, second < first { return true }
      return false
    } ?? false
    let interval = old.map { sample.monotonicTime - $0.monotonicTime }
    let validInterval = interval.map { $0.isFinite && $0 > 0 } ?? false
    let baseline: ServerMetricUnavailable = old == nil ? .waitingForBaseline : (reboot ? .counterReset : .invalidInterval)
    let cpu: ServerMetric<ServerCPUUsage>
    switch sample.cpu {
    case .unavailable(let reason): cpu = .unavailable(reason)
    case .value(let current):
      if current.values.count != 8 { cpu = .unavailable(.invalidData) }
      else if old == nil || reboot || !validInterval { cpu = .unavailable(baseline) }
      else if let prior = old?.cpu.value, prior.values.count == 8 { cpu = Self.cpuUsage(current, prior: prior) }
      else { cpu = .unavailable(.waitingForBaseline) }
    }
    let network: ServerMetric<[ServerNetworkRate]>
    switch sample.network {
    case .unavailable(let reason): network = .unavailable(reason)
    case .value(let interfaces):
      // Public samples can be supplied by test/adaptor code. Never trap on duplicate names.
      if interfaces.count > LinuxServerCollector.maximumInterfaces || Set(interfaces.map(\.name)).count != interfaces.count {
        network = .unavailable(.invalidData)
      } else {
        let previousInterfaces = old?.network.value.flatMap { items in
          items.count <= LinuxServerCollector.maximumInterfaces && Set(items.map(\.name)).count == items.count ? items : nil
        } ?? []
        let prior = Dictionary(previousInterfaces.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })
        network = .value(interfaces.map { current in
          let down: ServerMetric<Double>, up: ServerMetric<Double>
          if old == nil || reboot || !validInterval { down = .unavailable(baseline); up = down }
          else if let first = prior[current.name] {
            if current.receivedBytes < first.receivedBytes || current.transmittedBytes < first.transmittedBytes {
              down = .unavailable(.counterReset); up = down
            } else {
              let receive = Double(current.receivedBytes - first.receivedBytes) / interval!
              let transmit = Double(current.transmittedBytes - first.transmittedBytes) / interval!
              down = receive.isFinite ? .value(receive) : .unavailable(.invalidInterval)
              up = transmit.isFinite ? .value(transmit) : .unavailable(.invalidInterval)
            }
          } else { down = .unavailable(.waitingForBaseline); up = down }
          return .init(name: current.name, receivedBytesPerSecond: down, transmittedBytesPerSecond: up)
        })
      }
    }
    return .init(sample: sample, cpu: cpu, network: network)
  }

  private static func cpuUsage(_ current: LinuxCPUCounters, prior: LinuxCPUCounters) -> ServerMetric<ServerCPUUsage> {
    guard current.values.count == 8, prior.values.count == 8 else { return .unavailable(.invalidData) }
    var deltas: [UInt64] = [], total: UInt64 = 0
    for (first, second) in zip(prior.values, current.values) {
      guard second >= first else { return .unavailable(.counterReset) }
      let delta = second - first, sum = total.addingReportingOverflow(delta)
      guard !sum.overflow else { return .unavailable(.invalidData) }
      total = sum.partialValue; deltas.append(delta)
    }
    guard total > 0 else { return .unavailable(.waitingForBaseline) }
    let percent = 100 / Double(total)
    // iowait is idle here; irq/softirq are included in system. guest is already in user/nice.
    return .value(.init(totalPercent: Double(total - deltas[3] - deltas[4]) * percent,
      userPercent: (Double(deltas[0]) + Double(deltas[1])) * percent,
      systemPercent: (Double(deltas[2]) + Double(deltas[5]) + Double(deltas[6])) * percent))
  }
}
