import CryptoKit
import Foundation
import Network
import XCTest

/// Dockerized OpenSSH server (linuxserver/openssh-server) used as a real SSH target
/// for SSHCore integration tests. Requires a running local Docker daemon.
struct TestSSHServer: Sendable {
  enum FixtureError: Error, CustomStringConvertible {
    case docker(String)
    case timeout(String)
    case initialization(String)
    var description: String {
      switch self {
      case .docker(let m): return "docker error: \(m)"
      case .timeout(let m): return "timeout: \(m)"
      case .initialization(let m): return "SSH test fixture initialization failed: \(m)"
      }
    }
  }

  static let image = "linuxserver/openssh-server:latest"

  let host = "127.0.0.1"
  let port: Int
  let username = "test"
  let password = "test"
  let containerID: String
  private let hostKeyDir: URL

  // MARK: Runtime-only keys

  private struct KeyPair: Sendable {
    let privateKey: String
    let publicKey: String
  }

  private struct RuntimeKeys: Sendable {
    let ed25519: KeyPair
    let rsa: KeyPair
    let encryptedEd25519: KeyPair
    let host: KeyPair
    let alternateHost: KeyPair
    let passphrase: String

    static func generate() throws -> RuntimeKeys {
      let manager = FileManager.default
      let directory = manager.temporaryDirectory
        .appendingPathComponent("termes-runtime-keys-\(UUID().uuidString)", isDirectory: true)
      do {
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
      } catch {
        throw FixtureError.initialization("cannot create the temporary key directory")
      }
      defer { try? manager.removeItem(at: directory) }

      func generatePair(_ name: String, type: String, passphrase: String = "") throws -> KeyPair {
        let file = directory.appendingPathComponent(name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        var arguments = ["-q", "-t", type, "-N", passphrase, "-C", "termes-runtime-fixture", "-f", file.path]
        if type == "rsa" { arguments += ["-b", "2048"] }
        process.arguments = arguments
        // Never include generated material or the passphrase in test output.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { throw FixtureError.initialization("cannot start ssh-keygen for \(name)") }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
          throw FixtureError.initialization("ssh-keygen failed for \(name) (exit \(process.terminationStatus))")
        }
        do {
          try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
          try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.appendingPathExtension("pub").path)
          return KeyPair(privateKey: try String(contentsOf: file, encoding: .utf8),
            publicKey: try String(contentsOf: file.appendingPathExtension("pub"), encoding: .utf8)
              .trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
          throw FixtureError.initialization("cannot read the generated \(name) key")
        }
      }

      let passphrase = UUID().uuidString
      let keys = try RuntimeKeys(
        ed25519: generatePair("user-ed25519", type: "ed25519"),
        rsa: generatePair("user-rsa", type: "rsa"),
        encryptedEd25519: generatePair("user-encrypted-ed25519", type: "ed25519", passphrase: passphrase),
        host: generatePair("host-ed25519", type: "ed25519"),
        alternateHost: generatePair("alternate-host-ed25519", type: "ed25519"),
        passphrase: passphrase)
      do { try manager.removeItem(at: directory) }
      catch { throw FixtureError.initialization("cannot remove the temporary key directory") }
      return keys
    }
  }

  // Swift initializes this once, retaining only memory after the temporary files are removed.
  // Every fixture and restart in this process therefore sees the same host identities.
  private static let runtimeKeys: Result<RuntimeKeys, FixtureError> = {
    do { return .success(try RuntimeKeys.generate()) }
    catch let error as FixtureError { return .failure(error) }
    catch { return .failure(.initialization("unexpected key generation failure")) }
  }()

  private static var keys: RuntimeKeys {
    switch runtimeKeys {
    case .success(let keys): return keys
    case .failure(let error): fatalError(error.description)
    }
  }

  static var authorizedEd25519PublicKey: String { keys.ed25519.publicKey }
  static var testEd25519PrivateKeyOpenSSH: String { keys.ed25519.privateKey }
  static var authorizedRSAPublicKey: String { keys.rsa.publicKey }
  static var testRSAPrivateKeyOpenSSH: String { keys.rsa.privateKey }
  static var authorizedEncryptedEd25519PublicKey: String { keys.encryptedEd25519.publicKey }
  static var encryptedKeyPassphrase: String { keys.passphrase }
  static var testEncryptedEd25519PrivateKey: String { keys.encryptedEd25519.privateKey }
  static var hostEd25519PublicKey: String { keys.host.publicKey }
  private static var hostEd25519PrivateKey: String { keys.host.privateKey }
  static var altHostEd25519PublicKey: String { keys.alternateHost.publicKey }
  private static var altHostEd25519PrivateKey: String { keys.alternateHost.privateKey }

  /// `SHA256:<base64 without padding>` of the server's ed25519 host key (OpenSSH style).
  func fingerprintSHA256() -> String {
    Self.fingerprint(ofPublicKeyLine: Self.hostEd25519PublicKey)
  }

  static func fingerprint(ofPublicKeyLine line: String) -> String {
    let parts = line.split(separator: " ")
    guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return "" }
    var b64 = Data(SHA256.hash(data: blob)).base64EncodedString()
    while b64.hasSuffix("=") { b64.removeLast() }
    return "SHA256:" + b64
  }

  // MARK: Lifecycle

  static func start(timeout: TimeInterval = 30) async throws -> TestSSHServer {
    _ = try runtimeKeys.get()
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("termes-testsshd-\(UUID().uuidString)")
    let name = "termes-testsshd-\(UUID().uuidString.prefix(8).lowercased())"
    do {
      let p = try await launch(name: name, dir: dir, hostPort: nil, timeout: timeout)
      return TestSSHServer(port: p, containerID: name, hostKeyDir: dir)
    } catch { try? FileManager.default.removeItem(at: dir); throw error }
  }

  /// Stops the container and starts a fresh one on the SAME port with the SAME host key,
  /// so the fingerprint is unchanged (TOFU stays trusted). `drop()` may have been called before.
  /// With `differentHostKey: true` the new server presents another host key (fingerprint mismatch).
  func restart(differentHostKey: Bool = false, timeout: TimeInterval = 30) async throws {
    // Docker's port release after `rm -f` can lag; retry the launch once if the banner never shows.
    var p = 0
    for attempt in 0..<2 {
      _ = try? await Self.docker(["rm", "-f", "-v", containerID])
      do {
        p = try await Self.launch(
          name: containerID, dir: hostKeyDir, hostPort: port, timeout: timeout, alternateHostKey: differentHostKey)
        break
      } catch where attempt == 0 {
        try await Task.sleep(nanoseconds: 1_000_000_000)
      }
    }
    guard p == port else { throw FixtureError.docker("restart bound port \(p), expected \(port)") }
  }

  /// Run a test-only service or inspect its files inside this fixture's container.
  func execute(_ arguments: [String]) async throws -> String {
    let result = try await Self.docker(["exec", containerID] + arguments)
    guard result.status == 0 else { throw FixtureError.docker(result.output) }
    return result.output
  }

  /// This name resolves only inside this fixture, proving the next SSH hop performs DNS.
  func mapHost(_ hostname: String, to destination: TestSSHServer) async throws {
    let result = try await Self.docker(["inspect", "--format", "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}", destination.containerID])
    guard result.status == 0 else { throw FixtureError.docker(result.output) }
    let ip = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !ip.isEmpty, hostname.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else {
      throw FixtureError.docker("invalid test host")
    }
    _ = try await execute(["sh", "-c", "printf '%s %s\\n' '\(ip)' '\(hostname)' >> /etc/hosts"])
  }

  /// The image disables forwarding by default. Enable it only for forwarding fixtures.
  func enableTCPForwarding() async throws {
    _ = try await execute(["sh", "-c", "sed -i 's/^AllowTcpForwarding no/AllowTcpForwarding yes/' /config/sshd/sshd_config; kill -HUP $(cat /config/sshd.pid)"])
    try await Self.waitForSSHBanner(port: port, timeout: 10)
  }

  /// Freeze the fixture to hold accepted clients in SSH authentication.
  func pause() async throws {
    let result = try await Self.docker(["pause", containerID])
    guard result.status == 0 else { throw FixtureError.docker(result.output) }
  }

  func resume() async throws {
    let result = try await Self.docker(["unpause", containerID])
    guard result.status == 0 else { throw FixtureError.docker(result.output) }
  }

  /// Writes fixture files into `dir`, runs the container (`containerName`), waits for the banner.
  /// `hostPort == nil` lets Docker pick one. Returns the host port.
  private static func launch(name: String, dir: URL, hostPort: Int?, timeout: TimeInterval, alternateHostKey: Bool = false) async throws -> Int {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let priv = dir.appendingPathComponent("ssh_host_ed25519_key")
    try (alternateHostKey ? altHostEd25519PrivateKey : hostEd25519PrivateKey)
      .write(to: priv, atomically: true, encoding: .utf8)
    try ((alternateHostKey ? altHostEd25519PublicKey : hostEd25519PublicKey) + "\n").write(
      to: dir.appendingPathComponent("ssh_host_ed25519_key.pub"), atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: priv.path)

    try ([authorizedEd25519PublicKey, authorizedRSAPublicKey, authorizedEncryptedEd25519PublicKey]
      .joined(separator: "\n") + "\n").write(
      to: dir.appendingPathComponent("authorized.pub"), atomically: true, encoding: .utf8)

    let run = try await docker([
      "run", "-d", "--name", name,
      "-p", "127.0.0.1:\(hostPort.map(String.init) ?? ""):2222",
      "-e", "PUID=1000", "-e", "PGID=1000",
      "-e", "USER_NAME=test", "-e", "USER_PASSWORD=test",
      "-e", "PASSWORD_ACCESS=true",
      "-e", "PUBLIC_KEY_FILE=/pubkeys/authorized.pub",
      "-v", "\(dir.path)/authorized.pub:/pubkeys/authorized.pub:ro",
      "-v", "\(dir.path):/config/ssh_host_keys",
      image,
    ])
    guard run.status == 0 else {
      throw FixtureError.docker(run.output)
    }
    let id = run.output.trimmingCharacters(in: .whitespacesAndNewlines)

    do {
      let portOut = try await docker(["port", id, "2222/tcp"])
      // e.g. "127.0.0.1:55001" (possibly multiple lines)
      guard portOut.status == 0,
        let line = portOut.output.split(separator: "\n").first,
        let p = line.split(separator: ":").last.flatMap({ Int($0) })
      else { throw FixtureError.docker("cannot parse port: \(portOut.output)") }
      try await waitForSSHBanner(port: p, timeout: timeout)
      return p
    } catch {
      let startup = try? await docker(["logs", "--tail", "60", id])
      _ = try? await docker(["rm", "-f", "-v", id])
      throw FixtureError.docker("\(error)\nFixture startup log:\n\(startup?.output ?? "unavailable")")
    }
  }

  /// Simulates a dropped server but preserves the mounted directory for restart. Deleting
  /// and recreating its path can leave Docker Desktop's bind mount pointing at the old inode.
  func drop() async {
    _ = try? await Self.docker(["rm", "-f", "-v", containerID])
  }

  /// Final fixture cleanup, including test keys. A stopped fixture must not be restarted.
  func stop() async {
    await drop()
    try? FileManager.default.removeItem(at: hostKeyDir)
  }

  // MARK: Helpers

  /// Waits until the port accepts TCP and the server sends an `SSH-` banner
  /// (Docker's port proxy accepts connections before sshd is up).
  private static func waitForSSHBanner(port: Int, timeout: TimeInterval) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if await readBanner(port: port)?.hasPrefix("SSH-") == true { return }
      try await Task.sleep(nanoseconds: 300_000_000)
    }
    throw FixtureError.timeout("SSH server on 127.0.0.1:\(port) not ready within \(timeout)s")
  }

  private static func readBanner(port: Int) async -> String? {
    await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
      let conn = NWConnection(
        host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
      let box = OnceBox(cont)
      conn.stateUpdateHandler = { state in
        switch state {
        case .ready:
          conn.receive(minimumIncompleteLength: 1, maximumLength: 255) { data, _, _, _ in
            conn.cancel()
            box.resume(data.flatMap { String(data: $0, encoding: .utf8) })
          }
        case .failed, .cancelled:
          box.resume(nil)
        default: break
        }
      }
      conn.start(queue: .global())
      DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
        conn.cancel()
        box.resume(nil)
      }
    }
  }

  private final class OnceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<String?, Never>?
    init(_ c: CheckedContinuation<String?, Never>) { cont = c }
    func resume(_ v: String?) {
      lock.lock()
      let c = cont
      cont = nil
      lock.unlock()
      c?.resume(returning: v)
    }
  }

  private static func docker(_ args: [String]) async throws -> (status: Int32, output: String) {
    try await Task.detached {
      let p = Process()
      p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      p.arguments = ["docker"] + args
      var env = ProcessInfo.processInfo.environment
      env["PATH"] = (env["PATH"] ?? "") + ":/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin"
      p.environment = env
      let pipe = Pipe()
      p.standardOutput = pipe
      p.standardError = pipe
      try p.run()
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      p.waitUntilExit()
      return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }.value
  }
}

final class TestSSHServerTests: XCTestCase {
  func test_fixture_starts_and_exposes_port() async throws {
    let s = try await TestSSHServer.start()
    // Note: `defer { Task { await s.stop() } }` is fire-and-forget and can leak the container
    // when the test process exits; prefer an async teardown block.
    addTeardownBlock { await s.stop() }
    XCTAssertGreaterThan(s.port, 0)
    let publicKey = TestSSHServer.hostEd25519PublicKey
    let blob = try XCTUnwrap(Data(base64Encoded: publicKey.split(separator: " ")[1].description))
    let expected = "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString()
      .replacingOccurrences(of: "=", with: "")
    XCTAssertEqual(s.fingerprintSHA256(), expected)
    XCTAssertNotEqual(s.fingerprintSHA256(),
      TestSSHServer.fingerprint(ofPublicKeyLine: TestSSHServer.altHostEd25519PublicKey))
  }
}
