import Foundation

public enum ServerMonitoringError: Error, Equatable, Sendable, LocalizedError {
  case unsupportedPlatform(String), commandFailed, malformedResponse, responseTooLarge, collectionInProgress
  public var errorDescription: String? {
    switch self {
    case .unsupportedPlatform(let name): return "暂不支持服务器系统 \(name)，当前监控支持 Linux。"
    case .commandFailed: return "服务器未能完成监控采集命令，请检查命令执行权限和系统支持。"
    case .malformedResponse: return "服务器返回的监控数据格式无效。"
    case .responseTooLarge: return "服务器返回的监控数据超过限制。"
    case .collectionInProgress: return "上一轮监控采集尚未结束。"
    }
  }
}

/// Read-only Linux collection on an already authenticated, dedicated SSH connection.
/// No remote text is sourced/evaluated; each section keeps its own command status.
public struct LinuxServerCollector: Sendable {
  public static let maximumInterfaces = 256
  public static let maximumDisks = 128
  static let maximumResponseBytes = 1024 * 1024
  static let sectionNames = ["system", "kernel", "architecture", "hostname", "os", "boot", "cpu", "memory", "disks", "network", "load", "uptime"]
  private let connection: SSHConnection
  private let options: SSHCommandOptions

  public init(connection: SSHConnection, options: SSHCommandOptions = .init(timeout: 8)) {
    self.connection = connection; self.options = options
  }

  public func sample() async throws -> LinuxServerSample {
    let nonce = UUID().uuidString
    let result = try await connection.execute(Self.command(nonce: nonce), options: options)
    try Task.checkCancellation()
    guard result.exitStatus == 0, result.exitSignal == nil else { throw ServerMonitoringError.commandFailed }
    return try Self.parse(result.stdout, nonce: nonce, capturedAt: Date(),
      monotonicTime: Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000)
  }

  static func command(nonce: String) -> String {
    // Only generated ASCII UUIDs are interpolated. /bin/sh makes this independent of
    // the user's interactive shell. Functions and variables live in this child shell.
    precondition(nonce.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 })
    let script = #"""
    LC_ALL=C
    export LC_ALL
    termes_monitor_emit() {
      termes_monitor_section=$1
      shift
      printf '\036TERMESMON1:\#(nonce):%s\n' "$termes_monitor_section"
      command "$@"
      termes_monitor_status=$?
      printf '\n\037%d\n' "$termes_monitor_status"
    }
    termes_monitor_emit system uname -s
    termes_monitor_emit kernel uname -r
    termes_monitor_emit architecture uname -m
    termes_monitor_emit hostname uname -n
    if [ -e /etc/os-release ]; then
      termes_monitor_emit os cat /etc/os-release
    else
      termes_monitor_emit os cat /usr/lib/os-release
    fi
    termes_monitor_emit boot cat /proc/sys/kernel/random/boot_id
    termes_monitor_emit cpu head -n 1 /proc/stat
    termes_monitor_emit memory cat /proc/meminfo
    termes_monitor_emit disks df -Pk
    termes_monitor_emit network cat /proc/net/dev
    termes_monitor_emit load cat /proc/loadavg
    termes_monitor_emit uptime cat /proc/uptime
    printf '\036TERMESMON1:\#(nonce):END\n'
    """#
    return "/bin/sh -c '" + script.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  private struct Section {
    let data: Data
    let status: Int32
    func text() throws -> String {
      guard status == 0 else { throw ParseIssue(.commandFailed) }
      guard data.count <= 256 * 1024 else { throw ParseIssue(.limitExceeded) }
      guard let text = String(data: data, encoding: .utf8), !text.utf8.contains(0) else { throw ParseIssue(.invalidData) }
      guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ParseIssue(.missingData) }
      return text
    }
  }
  private struct ParseIssue: Error { let reason: ServerMetricUnavailable; init(_ reason: ServerMetricUnavailable) { self.reason = reason } }

  static func parse(_ data: Data, nonce: String, capturedAt: Date, monotonicTime: TimeInterval) throws -> LinuxServerSample {
    guard data.count <= maximumResponseBytes else { throw ServerMonitoringError.responseTooLarge }
    guard monotonicTime.isFinite, monotonicTime >= 0, capturedAt.timeIntervalSince1970.isFinite else { throw ServerMonitoringError.malformedResponse }
    let frames = data.split(separator: 0x1e, omittingEmptySubsequences: false)
    guard frames.count == sectionNames.count + 2, frames.first?.isEmpty == true,
          Data(frames.last!) == Data("TERMESMON1:\(nonce):END\n".utf8) else { throw ServerMonitoringError.malformedResponse }
    var sections: [String: Section] = [:]
    for (index, name) in sectionNames.enumerated() {
      let frame = frames[index + 1], header = Data("TERMESMON1:\(nonce):\(name)\n".utf8)
      guard frame.starts(with: header), let footer = frame.lastIndex(of: 0x1f),
            footer >= frame.index(frame.startIndex, offsetBy: header.count + 1),
            frame[frame.index(before: footer)] == 10 else { throw ServerMonitoringError.malformedResponse }
      let statusBytes = frame[frame.index(after: footer)...]
      guard statusBytes.last == 10,
            let text = String(data: Data(statusBytes.dropLast()), encoding: .utf8), let status = Int32(text),
            (0...255).contains(status), text.utf8.allSatisfy({ (48...57).contains($0) }) else { throw ServerMonitoringError.malformedResponse }
      sections[name] = .init(data: Data(frame.dropFirst(header.count).prefix(upTo: frame.index(before: footer))), status: status)
    }
    // Section names/count/order are fixed; missing framing is a failed collection, not a partial zero.
    guard let system = try? identityText(sections["system"]!.text()) else { throw ServerMonitoringError.commandFailed }
    guard system == "Linux" else { throw ServerMonitoringError.unsupportedPlatform(system) }
    let identity = ServerSystemIdentity(
      kernelRelease: read(sections["kernel"]!, using: identityText),
      architecture: read(sections["architecture"]!, using: identityText),
      hostname: read(sections["hostname"]!, using: identityText),
      operatingSystem: read(sections["os"]!, using: osName))
    let mem = sections["memory"]!
    return .init(capturedAt: capturedAt, monotonicTime: monotonicTime, identity: identity,
      bootID: read(sections["boot"]!) { text in
        guard let id = UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw ParseIssue(.invalidData) }
        return id.uuidString
      },
      cpu: read(sections["cpu"]!, using: cpuCounters),
      memory: read(mem) { try memoryUsage($0, total: "MemTotal", free: "MemAvailable", allowZero: false) },
      swap: read(mem) { try memoryUsage($0, total: "SwapTotal", free: "SwapFree", allowZero: true) },
      disks: read(sections["disks"]!, using: diskUsage), network: read(sections["network"]!, using: networkCounters),
      load: read(sections["load"]!) { text in
        let fields = tokens(text)
        guard fields.count >= 3 else { throw ParseIssue(.missingData) }
        return try .init(oneMinute: decimal(fields[0]), fiveMinutes: decimal(fields[1]), fifteenMinutes: decimal(fields[2]))
      },
      uptime: read(sections["uptime"]!) { text in
        let fields = tokens(text)
        guard fields.count == 2 else { throw ParseIssue(.invalidData) }
        _ = try decimal(fields[1])
        return try decimal(fields[0])
      })
  }

  private static func read<T: Equatable & Sendable>(_ section: Section, using parse: (String) throws -> T) -> ServerMetric<T> {
    do { return .value(try parse(section.text())) }
    catch let issue as ParseIssue { return .unavailable(issue.reason) }
    catch { return .unavailable(.invalidData) }
  }

  private static func tokens(_ text: String) -> [Substring] { text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }) }
  private static func digits(_ text: some StringProtocol) -> Bool {
    !text.isEmpty && text.utf8.allSatisfy { (48...57).contains($0) }
  }
  private static func uint(_ text: some StringProtocol) throws -> UInt64 {
    guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }), let value = UInt64(text) else { throw ParseIssue(.invalidData) }
    return value
  }
  private static func decimal(_ text: some StringProtocol) throws -> Double {
    guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }),
          let value = Double(text), value.isFinite, value >= 0 else { throw ParseIssue(.invalidData) }
    return value
  }
  private static func bytes(_ kib: UInt64) throws -> UInt64 {
    let result = kib.multipliedReportingOverflow(by: 1024)
    guard !result.overflow else { throw ParseIssue(.invalidData) }
    return result.partialValue
  }

  private static func identityText(_ text: String) throws -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.contains("\n"), !trimmed.contains("\r") else { throw ParseIssue(.invalidData) }
    let cleaned = String(String.UnicodeScalarView(trimmed.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
    guard !cleaned.isEmpty else { throw ParseIssue(.missingData) }
    guard cleaned.utf8.count <= 256 else { throw ParseIssue(.limitExceeded) }
    return cleaned
  }

  private static func osName(_ text: String) throws -> String {
    var values: [String: String] = [:]
    for line in text.split(separator: "\n") {
      guard let equal = line.firstIndex(of: "=") else { continue }
      let key = String(line[..<equal])
      guard key == "PRETTY_NAME" || key == "NAME" else { continue }
      // os-release specifies that readers should use the last occurrence.
      let value = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
      var decoded = ""
      if let quote = value.first, quote == "\"" || quote == "'" {
        guard value.count >= 2, value.last == quote else { throw ParseIssue(.invalidData) }
        var escaped = false
        for character in value.dropFirst().dropLast() {
          if escaped {
            if !"$`\"\\".contains(character) { decoded.append("\\") }
            decoded.append(character); escaped = false
          } else if quote == "\"", character == "\\" { escaped = true }
          else if character == quote { throw ParseIssue(.invalidData) }
          else { decoded.append(character) }
        }
        guard !escaped else { throw ParseIssue(.invalidData) }
      } else {
        guard !value.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "'" }) else { throw ParseIssue(.invalidData) }
        decoded = value
      }
      values[key] = decoded
    }
    guard let name = values["PRETTY_NAME"] ?? values["NAME"] else { throw ParseIssue(.missingData) }
    return try identityText(name)
  }

  private static func cpuCounters(_ text: String) throws -> LinuxCPUCounters {
    let lines = text.split(separator: "\n").filter { $0.hasPrefix("cpu ") || $0.hasPrefix("cpu\t") }
    guard lines.count == 1 else { throw ParseIssue(lines.isEmpty ? .missingData : .invalidData) }
    let fields = tokens(String(lines[0]))
    guard fields.count >= 9, fields.count <= 33 else { throw ParseIssue(.invalidData) }
    let values = try fields.dropFirst().map { try uint($0) }
    return .init(Array(values.prefix(8)))
  }

  private static func memoryUsage(_ text: String, total: String, free: String, allowZero: Bool) throws -> ServerMemoryUsage {
    var values: [String: UInt64] = [:]
    for line in text.split(separator: "\n") {
      guard let colon = line.firstIndex(of: ":") else { throw ParseIssue(.invalidData) }
      let key = String(line[..<colon])
      guard key == total || key == free else { continue }
      let fields = tokens(String(line[line.index(after: colon)...]))
      guard values[key] == nil, fields.count == 2, fields[1] == "kB" else { throw ParseIssue(.invalidData) }
      values[key] = try bytes(uint(fields[0]))
    }
    guard let capacity = values[total], let available = values[free] else { throw ParseIssue(.missingData) }
    guard available <= capacity, allowZero || capacity > 0 else { throw ParseIssue(.invalidData) }
    return .init(totalBytes: capacity, usedBytes: capacity - available, availableBytes: available)
  }

  private static func networkCounters(_ text: String) throws -> [ServerNetworkCounters] {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
    guard lines.count >= 2, lines[0].contains("Receive"), lines[0].contains("Transmit"), lines[1].contains("bytes") else { throw ParseIssue(.invalidData) }
    guard lines.count - 2 <= maximumInterfaces else { throw ParseIssue(.limitExceeded) }
    var result: [ServerNetworkCounters] = [], names = Set<String>()
    for line in lines.dropFirst(2) {
      guard let colon = line.lastIndex(of: ":") else { throw ParseIssue(.invalidData) }
      let name = line[..<colon].trimmingCharacters(in: .whitespaces)
      guard !name.isEmpty, name.utf8.count <= 64, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
            names.insert(name).inserted else { throw ParseIssue(.invalidData) }
      let fields = tokens(String(line[line.index(after: colon)...]))
      guard fields.count == 16 else { throw ParseIssue(.invalidData) }
      let values = try fields.map { try uint($0) }
      result.append(.init(name: name, receivedBytes: values[0], transmittedBytes: values[8]))
    }
    return result
  }

  private static func diskUsage(_ text: String) throws -> [ServerDiskUsage] {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
    guard let header = lines.first, header.hasPrefix("Filesystem"), header.contains("Mounted") else { throw ParseIssue(.invalidData) }
    guard lines.count - 1 <= maximumDisks else { throw ParseIssue(.limitExceeded) }
    var result: [ServerDiskUsage] = [], mounts = Set<String>()
    for raw in lines.dropFirst() {
      // Bound each line before scanning. Splitting tokens avoids backtracking on
      // a long malformed whitespace/name sequence, while retaining original name ranges.
      guard raw.utf8.count <= 2 * 4096 + 128 else { throw ParseIssue(.limitExceeded) }
      let line = String(raw), words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
      guard words.count >= 6 else { throw ParseIssue(.invalidData) }
      let matches = (1..<(words.count - 4)).filter { index in
        let available = words[index + 2], percent = words[index + 3]
        return digits(words[index]) && digits(words[index + 1]) &&
          digits(available.first == "-" ? available.dropFirst() : available[...]) &&
          (percent == "-" || (percent.last == "%" && digits(percent.dropLast())))
      }
      // df -P leaves names unquoted. Numeric-looking sequences in either name
      // can be ambiguous; report unavailable rather than assign the wrong mount.
      guard matches.count == 1, let match = matches.first else { throw ParseIssue(.invalidData) }
      let filesystem = line[..<words[match].startIndex].trimmingCharacters(in: .whitespaces)
      let mount = line[words[match + 3].endIndex...].trimmingCharacters(in: .whitespaces)
      guard !filesystem.isEmpty, !mount.isEmpty, filesystem.utf8.count <= 4096, mount.utf8.count <= 4096,
            !line.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\t" }),
            mounts.insert(mount).inserted else { throw ParseIssue(.invalidData) }
      let fields = (match...(match + 3)).map { words[$0] }
      let capacity = try bytes(uint(fields[0])), used = try bytes(uint(fields[1]))
      guard used <= capacity, let available = Int64(fields[2]) else { throw ParseIssue(.invalidData) }
      let availableBytes = available.multipliedReportingOverflow(by: 1024)
      guard !availableBytes.overflow else { throw ParseIssue(.invalidData) }
      let percentage: ServerMetric<Double> = fields[3] == "-" ? .unavailable(.missingData) : .value(Double(try uint(fields[3].dropLast())))
      result.append(.init(filesystem: filesystem, mountPoint: mount, totalBytes: capacity, usedBytes: used,
        availableBytes: availableBytes.partialValue, usagePercent: percentage))
    }
    return result
  }
}
