import Foundation
import XCTest
@testable import SSHCore

final class ServerMetricsTests: XCTestCase {
  private let nonce = "TEST-NONCE"
  private let fields = ["system", "kernel", "architecture", "hostname", "os", "boot", "cpu", "memory", "disks", "network", "load", "uptime"]
  private var valid: [String: String] {
    ["system": "Linux\n", "kernel": "6.8.0\n", "architecture": "x86_64\n", "hostname": "test-host\n",
     "os": "NAME=Linux\nPRETTY_NAME=\"Test Linux 1.0\"\n", "boot": "00000000-0000-0000-0000-000000000001\n",
     "cpu": "cpu 100 20 40 400 10 5 15 10 99 88\ncpu0 100 20 40 400 10 5 15 10 99 88\nbtime 12345\n",
     "memory": "MemTotal: 1000 kB\nMemFree: 100 kB\nMemAvailable: 400 kB\nSwapTotal: 200 kB\nSwapFree: 150 kB\nHugePages_Total: 0\n",
     "disks": "Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/root 1000 600 300 67% /\n",
     "network": network([("eth0", 1000, 2000), ("lo", 50, 50)]), "load": "0.50 1.25 2.00 1/100 400\n", "uptime": "1000.50 2200.00\n"]
  }
  private func network(_ interfaces: [(String, UInt64, UInt64)]) -> String {
    "Inter-| Receive | Transmit\n face |bytes packets errs drop fifo frame compressed multicast|bytes packets errs drop fifo colls carrier compressed\n" +
    interfaces.map { " \($0.0): \($0.1) 1 0 0 0 0 0 0 \($0.2) 1 0 0 0 0 0 0\n" }.joined()
  }
  private func packet(_ overrides: [String: String] = [:], statuses: [String: Int] = [:]) -> Data {
    var result = Data()
    for name in fields {
      result.append(Data("\u{1e}TERMESMON1:\(nonce):\(name)\n".utf8))
      result.append(Data((overrides[name] ?? valid[name]!).utf8))
      result.append(Data("\n\u{1f}\(statuses[name] ?? 0)\n".utf8))
    }
    result.append(Data("\u{1e}TERMESMON1:\(nonce):END\n".utf8))
    return result
  }
  private func sample(_ overrides: [String: String] = [:], statuses: [String: Int] = [:], time: Double = 10, wall: Double = 100) throws -> LinuxServerSample {
    try LinuxServerCollector.parse(packet(overrides, statuses: statuses), nonce: nonce,
      capturedAt: Date(timeIntervalSince1970: wall), monotonicTime: time)
  }

  func test_known_linux_fields_units_reserved_space_and_guest_counters() throws {
    let data = try sample()
    XCTAssertEqual(data.identity.operatingSystem.value, "Test Linux 1.0")
    XCTAssertEqual(data.identity.hostname.value, "test-host")
    XCTAssertEqual(data.cpu.value?.values, [100, 20, 40, 400, 10, 5, 15, 10])
    let memory = try XCTUnwrap(data.memory.value), swap = try XCTUnwrap(data.swap.value)
    XCTAssertEqual(memory.totalBytes, 1_024_000); XCTAssertEqual(memory.usedBytes, 614_400)
    XCTAssertEqual(memory.availableBytes, 409_600); XCTAssertEqual(memory.usagePercent, 60)
    XCTAssertEqual(swap.usedBytes, 51_200); XCTAssertEqual(swap.usagePercent, 25)
    let disk = try XCTUnwrap(data.disks.value?.first)
    XCTAssertEqual(disk.usedBytes, 614_400); XCTAssertEqual(disk.availableBytes, 307_200)
    XCTAssertEqual(disk.usagePercent.value, 67, "df reserved space semantics must survive")
    XCTAssertEqual(data.load.value?.fiveMinutes, 1.25); XCTAssertEqual(data.uptime.value, 1000.5)
  }

  func test_delta_cpu_and_network_use_actual_interval_and_ignore_wall_clock_changes() throws {
    var calculator = ServerMetricsCalculator()
    let cold = calculator.consume(try sample())
    XCTAssertEqual(cold.cpu, .unavailable(.waitingForBaseline))
    XCTAssertEqual(cold.network.value?.first?.receivedBytesPerSecond, .unavailable(.waitingForBaseline))
    let next = calculator.consume(try sample([
      "cpu": "cpu 110 20 60 450 15 10 25 10 999999 999999\n",
      "network": network([("eth0", 1900, 2450), ("lo", 140, 150), ("veth-new", 10000, 10000)]),
      "uptime": "1009.50 2220.00\n"], time: 19, wall: 1))
    let cpu = try XCTUnwrap(next.cpu.value)
    XCTAssertEqual(cpu.totalPercent, 45, accuracy: 0.0001)
    XCTAssertEqual(cpu.userPercent, 10, accuracy: 0.0001)
    XCTAssertEqual(cpu.systemPercent, 35, accuracy: 0.0001)
    let rates = try XCTUnwrap(next.network.value)
    XCTAssertEqual(rates[0].receivedBytesPerSecond.value, 100)
    XCTAssertEqual(rates[0].transmittedBytesPerSecond.value, 50)
    XCTAssertEqual(rates[2].receivedBytesPerSecond, .unavailable(.waitingForBaseline))
    XCTAssertEqual(rates.map(\.name), ["eth0", "lo", "veth-new"], "interfaces must not be aggregated")
  }

  func test_missing_or_failed_sections_do_not_turn_into_zero_or_hide_other_metrics() throws {
    let failed = try sample(["memory": "MemTotal: 1000 kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n"], statuses: ["disks": 1, "boot": 1])
    XCTAssertEqual(failed.memory, .unavailable(.missingData))
    XCTAssertEqual(failed.swap.value?.totalBytes, 0); XCTAssertNil(failed.swap.value?.usagePercent)
    XCTAssertEqual(failed.disks, .unavailable(.commandFailed)); XCTAssertEqual(failed.bootID, .unavailable(.commandFailed))
    XCTAssertNotNil(failed.cpu.value); XCTAssertNotNil(failed.network.value)
    var calculator = ServerMetricsCalculator()
    _ = calculator.consume(try sample())
    _ = calculator.consume(try sample(statuses: ["cpu": 1, "network": 1], time: 15))
    let restored = calculator.consume(try sample(time: 20))
    XCTAssertEqual(restored.cpu, .unavailable(.waitingForBaseline))
    XCTAssertEqual(restored.network.value?.first?.receivedBytesPerSecond, .unavailable(.waitingForBaseline))
  }

  func test_reboot_clock_regression_and_counter_regression_reset_baselines() throws {
    for changes in [["boot": "00000000-0000-0000-0000-000000000002\n"], ["uptime": "1.0 0.0\n"]] {
      var calculator = ServerMetricsCalculator()
      _ = calculator.consume(try sample())
      let reboot = calculator.consume(try sample(changes, time: 15))
      XCTAssertEqual(reboot.cpu, .unavailable(.counterReset))
      XCTAssertEqual(reboot.network.value?.first?.receivedBytesPerSecond, .unavailable(.counterReset))
    }
    var calculator = ServerMetricsCalculator()
    _ = calculator.consume(try sample())
    let regressed = calculator.consume(try sample(["cpu": "cpu 110 20 60 450 9 10 25 10\n", "network": network([("eth0", 999, 3000)])], time: 15))
    XCTAssertEqual(regressed.cpu, .unavailable(.counterReset))
    XCTAssertEqual(regressed.network.value?.first?.transmittedBytesPerSecond, .unavailable(.counterReset))
    let recovered = calculator.consume(try sample(["cpu": "cpu 120 20 70 460 10 10 25 10\n", "network": network([("eth0", 1499, 3500)])], time: 20))
    XCTAssertNotNil(recovered.cpu.value); XCTAssertEqual(recovered.network.value?.first?.receivedBytesPerSecond.value, 100)
    let clock = calculator.consume(try sample(time: 20))
    XCTAssertEqual(clock.cpu, .unavailable(.invalidInterval))
    calculator.reset()
    XCTAssertEqual(calculator.consume(try sample(time: 30)).cpu, .unavailable(.waitingForBaseline))
  }

  func test_disk_unicode_spaces_negative_availability_and_ambiguous_names() throws {
    let disks = try sample(["disks": "Filesystem 1024-blocks Used Available Capacity Mounted on\nserver:/共享 磁盘 10 10 -1 112% /mnt/含 空格\nempty 0 0 0 - /empty\n"])
    let items = try XCTUnwrap(disks.disks.value)
    XCTAssertEqual(items[0].filesystem, "server:/共享 磁盘"); XCTAssertEqual(items[0].mountPoint, "/mnt/含 空格")
    XCTAssertEqual(items[0].availableBytes, -1024); XCTAssertEqual(items[0].usagePercent.value, 112)
    XCTAssertEqual(items[1].usagePercent, .unavailable(.missingData))
    let ambiguous = try sample(["disks": "Filesystem 1024-blocks Used Available Capacity Mounted on\nremote 1 2 3 4% name 10 5 4 56% /mnt\n"])
    XCTAssertEqual(ambiguous.disks, .unavailable(.invalidData))
  }

  func test_malformed_numbers_units_duplicates_and_overflow_are_unavailable() throws {
    for memory in ["MemTotal: 1000 MB\nMemAvailable: 400 kB\n", "MemTotal: 1000 kB\nMemAvailable: 1001 kB\n", "MemTotal: 18446744073709551615 kB\nMemAvailable: 0 kB\n", "MemTotal: 1000 kB\nMemTotal: 1000 kB\nMemAvailable: 400 kB\n"] {
      XCTAssertEqual(try sample(["memory": memory]).memory, .unavailable(.invalidData))
    }
    for cpu in ["cpu 1 2 3\n", "cpu +1 0 0 0 0 0 0 0\n", "cpu 18446744073709551616 0 0 0 0 0 0 0\n"] {
      XCTAssertEqual(try sample(["cpu": cpu]).cpu, .unavailable(.invalidData))
    }
    XCTAssertEqual(try sample(["network": network([("eth0", 1, 1), ("eth0", 2, 2)])]).network, .unavailable(.invalidData))
    XCTAssertEqual(try sample(["load": "nan inf -1\n"]).load, .unavailable(.invalidData))
    XCTAssertEqual(try sample(["uptime": "inf 0\n"]).uptime, .unavailable(.invalidData))
    XCTAssertEqual(try sample(["disks": "Filesystem 1024-blocks Used Available Capacity Mounted on\nx 18446744073709551615 0 0 0% /\n"]).disks, .unavailable(.invalidData))
  }

  func test_framing_nonce_order_truncation_footer_and_clock_validation() throws {
    let validPacket = packet()
    let shortenedFooter = Data(String(decoding: validPacket, as: UTF8.self).replacingOccurrences(of: "system\nLinux\n\n\u{1f}0", with: "system\n\u{1f}0").utf8)
    for data in [Data(validPacket.dropLast()), Data("noise".utf8) + validPacket, shortenedFooter,
      Data(String(decoding: validPacket, as: UTF8.self).replacingOccurrences(of: ":kernel\n", with: ":hostname\n").utf8),
      Data(String(decoding: validPacket, as: UTF8.self).replacingOccurrences(of: "\u{1f}0\n", with: "\u{1f}256\n").utf8)] {
      XCTAssertThrowsError(try LinuxServerCollector.parse(data, nonce: nonce, capturedAt: Date(), monotonicTime: 1)) {
        XCTAssertEqual($0 as? ServerMonitoringError, .malformedResponse)
      }
    }
    XCTAssertThrowsError(try LinuxServerCollector.parse(validPacket, nonce: "OTHER", capturedAt: Date(), monotonicTime: 1))
    XCTAssertThrowsError(try LinuxServerCollector.parse(validPacket, nonce: nonce, capturedAt: Date(), monotonicTime: .nan))
  }

  func test_individual_and_whole_response_limits_and_invalid_encoding() throws {
    XCTAssertEqual(try sample(["cpu": String(repeating: "x", count: 256 * 1024 + 1)]).cpu, .unavailable(.limitExceeded))
    let interfaces = (0...LinuxServerCollector.maximumInterfaces).map { ("eth\($0)", UInt64(1), UInt64(2)) }
    XCTAssertEqual(try sample(["network": network(interfaces)]).network, .unavailable(.limitExceeded))
    let disks = "Filesystem 1024-blocks Used Available Capacity Mounted on\n" +
      (0...LinuxServerCollector.maximumDisks).map { "x 10 1 9 10% /mnt/\($0)\n" }.joined()
    XCTAssertEqual(try sample(["disks": disks]).disks, .unavailable(.limitExceeded))
    let oversizedLine = "Filesystem 1024-blocks Used Available Capacity Mounted on\n" + String(repeating: " ", count: 9000) + "x 1 0 1 0% /\n"
    XCTAssertEqual(try sample(["disks": oversizedLine]).disks, .unavailable(.limitExceeded))
    XCTAssertThrowsError(try LinuxServerCollector.parse(Data(repeating: 0, count: 1024 * 1024 + 1), nonce: nonce, capturedAt: Date(), monotonicTime: 1)) {
      XCTAssertEqual($0 as? ServerMonitoringError, .responseTooLarge)
    }
    var invalidUTF8 = packet()
    let range = try XCTUnwrap(invalidUTF8.range(of: Data("test-host".utf8)))
    invalidUTF8.replaceSubrange(range, with: Data([255]))
    let data = try LinuxServerCollector.parse(invalidUTF8, nonce: nonce, capturedAt: Date(), monotonicTime: 1)
    XCTAssertEqual(data.identity.hostname, .unavailable(.invalidData)); XCTAssertNotNil(data.memory.value)
  }

  func test_os_identity_is_literal_bounded_and_never_evaluates_shell_text() throws {
    let raw = #"PRETTY_NAME="$(touch /tmp/SHOULD_NOT_EXIST) \"quoted\" \\path""# + "\n"
    XCTAssertEqual(try sample(["os": raw]).identity.operatingSystem.value, #"$(touch /tmp/SHOULD_NOT_EXIST) "quoted" \path"#)
    XCTAssertEqual(try sample(["hostname": "host\u{1b}\u{7}\n"]).identity.hostname.value, "host")
    XCTAssertEqual(try sample(["hostname": String(repeating: "中", count: 86)]).identity.hostname, .unavailable(.limitExceeded))
    XCTAssertEqual(try sample(["os": "PRETTY_NAME=\"bad\n"]).identity.operatingSystem, .unavailable(.invalidData))
    XCTAssertEqual(try sample(["os": "PRETTY_NAME=First\nPRETTY_NAME='Last Linux'\n"]).identity.operatingSystem.value, "Last Linux")
    XCTAssertThrowsError(try sample(["system": "Darwin\n"])) { XCTAssertEqual($0 as? ServerMonitoringError, .unsupportedPlatform("Darwin")) }
    XCTAssertThrowsError(try sample(statuses: ["system": 1])) { XCTAssertEqual($0 as? ServerMonitoringError, .commandFailed) }
  }

  func test_zero_delta_and_cpu_delta_overflow_do_not_produce_nan_or_fake_percentages() throws {
    var calculator = ServerMetricsCalculator()
    _ = calculator.consume(try sample())
    XCTAssertEqual(calculator.consume(try sample(time: 15)).cpu, .unavailable(.waitingForBaseline))
    calculator.reset()
    _ = calculator.consume(try sample(["cpu": "cpu 0 0 0 0 0 0 0 0\n"]))
    let overflow = calculator.consume(try sample(["cpu": "cpu 18446744073709551615 18446744073709551615 0 0 0 0 0 0\n"], time: 15))
    XCTAssertEqual(overflow.cpu, .unavailable(.invalidData))
  }
}
