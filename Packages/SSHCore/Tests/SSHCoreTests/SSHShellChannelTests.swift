import XCTest
@testable import SSHCore

final class SSHShellChannelTests: XCTestCase {
  func test_shell_echoes_input() async throws {
    let s = try await TestSSHServer.start(); addTeardownBlock { await s.stop() }
    let conn = SSHConnection(
      config: .init(hostname: s.host, port: s.port, username: s.username, auth: .password(s.password)),
      knownHosts: KnownHostsStore(fileURL: FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString + ".json")),
      confirmUnknownHostKey: { _,_,_ in true })
    try await conn.connect()
    let ch = try await conn.openShell(cols: 80, rows: 24)
    await ch.send(Data("echo SHELLTEST\n".utf8))
    // 带 5s 超时:超时后关闭 channel 使 output 结束,避免永久挂起
    let watchdog = Task { guard (try? await Task.sleep(nanoseconds: 5_000_000_000)) != nil else { return }; await ch.close() }
    var acc = ""
    outer: for await chunk in ch.output {
      acc += String(decoding: chunk, as: UTF8.self)
      if acc.contains("SHELLTEST") { break outer }
    }
    watchdog.cancel()
    XCTAssertTrue(acc.contains("SHELLTEST"), "got: \(acc)")
    await ch.close(); await conn.disconnect()
  }

  private func shell() async throws -> (SSHConnection, ShellChannel) {
    let s = try await TestSSHServer.start(); addTeardownBlock { await s.stop() }
    let conn = SSHConnection(
      config: .init(hostname: s.host, port: s.port, username: s.username, auth: .password(s.password)),
      knownHosts: KnownHostsStore(fileURL: FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString + ".json")),
      confirmUnknownHostKey: { _,_,_ in true })
    try await conn.connect()
    return (conn, try await conn.openShell(cols: 80, rows: 24))
  }

  func test_resize_updates_pty_size() async throws {
    let (conn, ch) = try await shell()
    await ch.resize(cols: 100, rows: 30)
    await ch.send(Data("stty size\n".utf8))
    let watchdog = Task { guard (try? await Task.sleep(nanoseconds: 8_000_000_000)) != nil else { return }; await ch.close() }
    var acc = ""
    for await chunk in ch.output {
      acc += String(decoding: chunk, as: UTF8.self)
      if acc.contains("30 100") { break }
    }
    watchdog.cancel()
    XCTAssertTrue(acc.contains("30 100"), "got: \(acc)")
    await ch.close(); await conn.disconnect()
  }

  func test_remote_exit_finishes_output_and_ops_are_safe() async throws {
    let (conn, ch) = try await shell()
    await ch.send(Data("exit\n".utf8))
    let watchdog = Task { guard (try? await Task.sleep(nanoseconds: 8_000_000_000)) != nil else { return }; await ch.close() }
    for await _ in ch.output {}   // must terminate
    watchdog.cancel()
    try? await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertFalse((ch as! SSHShellChannel).isClosingLocally, "remote exit, not a local close")
    await ch.send(Data("x".utf8)); await ch.resize(cols: 10, rows: 10); await ch.close()
    await conn.disconnect()
  }

  func test_disconnect_finishes_output() async throws {
    let (conn, ch) = try await shell()
    await conn.disconnect()
    let watchdog = Task { guard (try? await Task.sleep(nanoseconds: 8_000_000_000)) != nil else { return }; await ch.close() }
    for await _ in ch.output {}
    watchdog.cancel()
    XCTAssertFalse((ch as! SSHShellChannel).isClosingLocally, "stream must end from disconnect, not watchdog close")
    await ch.send(Data("x".utf8))
  }

  func test_keepalive_does_not_disrupt_shell_and_detects_drop() async throws {
    let s = try await TestSSHServer.start(); addTeardownBlock { await s.stop() }
    let conn = SSHConnection(
      config: .init(hostname: s.host, port: s.port, username: s.username, auth: .password(s.password)),
      knownHosts: KnownHostsStore(fileURL: FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString + ".json")),
      confirmUnknownHostKey: { _,_,_ in true })
    try await conn.connect()
    let ch = try await conn.openShell(cols: 80, rows: 24)
    await ch.send(Data("echo ALIVE\n".utf8))
    let w1 = Task { guard (try? await Task.sleep(nanoseconds: 8_000_000_000)) != nil else { return }; await ch.close() }
    var acc = ""
    for await c in ch.output { acc += String(decoding: c, as: UTF8.self); if acc.contains("ALIVE") { break } }
    w1.cancel()
    XCTAssertTrue(acc.contains("ALIVE"))   // keepalive must not disturb normal I/O
    await s.stop()                         // drop the connection
    let w2 = Task { guard (try? await Task.sleep(nanoseconds: 25_000_000_000)) != nil else { return }; await ch.close() }
    for await _ in ch.output {}            // stream must end on its own
    w2.cancel()
    XCTAssertFalse((ch as! SSHShellChannel).isClosingLocally, "stream should end from the drop, not the watchdog")
    await conn.disconnect()
  }
}
