import Foundation
import CryptoKit
import XCTest
@testable import SSHCore

final class PrivateKeyIdentityTests: XCTestCase {
  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }
  private func run(_ executable: String, _ arguments: [String]) throws -> String {
    let process = Process(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
    process.standardOutput = output; process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw NSError(domain: "KeyTestCommand", code: Int(process.terminationStatus)) }
    return String(decoding: data, as: UTF8.self)
  }
  private func rsaFile() throws -> URL {
    let file = try directory().appendingPathComponent("rsa")
    try Data(TestSSHServer.testRSAPrivateKeyOpenSSH.utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    _ = try run("/usr/bin/ssh-keygen", ["-p", "-m", "PEM", "-P", "", "-N", "", "-f", file.path])
    return file
  }

  private func pem(_ data: Data, label: String) -> String {
    ["-----BEGIN \(label)-----", data.base64EncodedString(), "-----END \(label)-----", ""]
      .joined(separator: "\n")
  }

  func test_openssh_rsa_and_ed25519_match_authorized_public_key_fingerprints() throws {
    for (privateKey, publicKey, type) in [
      (TestSSHServer.testEd25519PrivateKeyOpenSSH, TestSSHServer.authorizedEd25519PublicKey, "ssh-ed25519"),
      (TestSSHServer.testRSAPrivateKeyOpenSSH, TestSSHServer.authorizedRSAPublicKey, "ssh-rsa")
    ] {
      let identity = try XCTUnwrap(PrivateKeyIdentity.inspect(Data(privateKey.utf8)))
      XCTAssertEqual(identity.fingerprint, TestSSHServer.fingerprint(ofPublicKeyLine: publicKey))
      XCTAssertEqual(identity.keyType, type); XCTAssertFalse(identity.isEncrypted)
    }
  }

  func test_encrypted_openssh_public_identity_does_not_require_or_verify_the_passphrase() throws {
    let data = Data(TestSSHServer.testEncryptedEd25519PrivateKey.utf8)
    let identity = try XCTUnwrap(PrivateKeyIdentity.inspect(data))
    XCTAssertTrue(identity.isEncrypted)
    XCTAssertEqual(identity.fingerprint, TestSSHServer.fingerprint(ofPublicKeyLine: TestSSHServer.authorizedEncryptedEd25519PublicKey))
    XCTAssertEqual(PrivateKeyIdentity.inspect(data, passphrase: "wrong"), identity)
    XCTAssertEqual(PrivateKeyIdentity.inspect(data, passphrase: TestSSHServer.encryptedKeyPassphrase), identity)
  }

  func test_rsa_pem_and_openssh_have_the_same_identity() throws {
    let file = try rsaFile()
    XCTAssertEqual(PrivateKeyIdentity.inspect(try Data(contentsOf: file)),
      PrivateKeyIdentity.inspect(Data(TestSSHServer.testRSAPrivateKeyOpenSSH.utf8)))
  }

  func test_all_supported_ecdsa_curves_match_ssh_keygen_in_openssh_and_pem() throws {
    let dir = try directory()
    for bits in [256, 384, 521] {
      let file = dir.appendingPathComponent("ec\(bits)")
      _ = try run("/usr/bin/ssh-keygen", ["-q", "-t", "ecdsa", "-b", String(bits), "-N", "", "-f", file.path])
      let publicKey = try String(contentsOf: file.appendingPathExtension("pub"), encoding: .utf8)
      let identity = try XCTUnwrap(PrivateKeyIdentity.inspect(try Data(contentsOf: file)))
      XCTAssertEqual(identity.keyType, "ecdsa-sha2-nistp\(bits)")
      XCTAssertEqual(identity.fingerprint, TestSSHServer.fingerprint(ofPublicKeyLine: publicKey))
      _ = try run("/usr/bin/ssh-keygen", ["-p", "-m", "PEM", "-P", "", "-N", "", "-f", file.path])
      XCTAssertEqual(PrivateKeyIdentity.inspect(try Data(contentsOf: file)), identity)
    }
  }

  func test_encrypted_pkcs8_pem_requires_correct_password_without_interactive_prompt() throws {
    let file = try rsaFile(), encrypted = file.appendingPathExtension("pkcs8")
    _ = try run("/usr/bin/openssl", ["pkcs8", "-topk8", "-in", file.path, "-out", encrypted.path,
      "-v2", "aes-256-cbc", "-passout", "pass:key-test-password"])
    let data = try Data(contentsOf: encrypted)
    XCTAssertNil(PrivateKeyIdentity.inspect(data))
    XCTAssertNil(PrivateKeyIdentity.inspect(data, passphrase: "wrong"))
    let identity = try XCTUnwrap(PrivateKeyIdentity.inspect(data, passphrase: "key-test-password"))
    XCTAssertTrue(identity.isEncrypted)
    XCTAssertEqual(identity.fingerprint, TestSSHServer.fingerprint(ofPublicKeyLine: TestSSHServer.authorizedRSAPublicKey))
  }

  func test_ed25519_pkcs8_pem_matches_cryptokit_public_key() throws {
    let key = Curve25519.Signing.PrivateKey()
    let der = Data([0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20]) + key.rawRepresentation
    let pem = pem(der, label: "PRIVATE KEY")
    let blob = Data([0, 0, 0, 11]) + Data("ssh-ed25519".utf8) + Data([0, 0, 0, 32]) + key.publicKey.rawRepresentation
    let identity = try XCTUnwrap(PrivateKeyIdentity.inspect(Data(pem.utf8)))
    XCTAssertEqual(identity.keyType, "ssh-ed25519")
    XCTAssertEqual(identity.fingerprint, "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: ""))
  }

  func test_malformed_truncated_and_oversized_containers_return_no_identity() {
    let valid = Data(TestSSHServer.testEd25519PrivateKeyOpenSSH.utf8)
    for count in stride(from: 0, to: valid.count, by: 7) {
      XCTAssertNil(PrivateKeyIdentity.inspect(Data(valid.prefix(count))))
    }
    for data in [Data("not a key".utf8), Data([255]), Data(repeating: 65, count: 1_048_577),
                 Data(("prefix " + TestSSHServer.testEd25519PrivateKeyOpenSSH).utf8)] {
      XCTAssertNil(PrivateKeyIdentity.inspect(data))
    }
    let overflow = Data("openssh-key-v1\0".utf8) + Data([255, 255, 255, 255])
    let malformed = pem(overflow, label: "OPENSSH PRIVATE KEY")
    XCTAssertNil(PrivateKeyIdentity.inspect(Data(malformed.utf8)))
  }
}
