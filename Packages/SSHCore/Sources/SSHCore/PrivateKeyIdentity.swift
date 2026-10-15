import Foundation
import CryptoKit
import OpenSSL

/// Identifies the public part of a private-key container without writing secrets to disk.
/// OpenSSH exposes its public blob even when encrypted; this does not verify its passphrase.
public struct PrivateKeyIdentity: Equatable, Sendable {
  public let fingerprint: String
  public let keyType: String
  public let isEncrypted: Bool

  public static func inspect(_ data: Data, passphrase: String? = nil) -> PrivateKeyIdentity? {
    guard !data.isEmpty, data.count <= 1_048_576, let text = String(data: data, encoding: .utf8) else { return nil }
    if text.contains("-----BEGIN OPENSSH PRIVATE KEY-----") { return openSSH(text) }
    return pem(data, passphrase: passphrase)
  }

  private static func identity(blob: Data, encrypted: Bool) -> PrivateKeyIdentity? {
    var reader = KeyBlobReader(blob)
    guard let type = reader.stringText() else { return nil }
    switch type {
    case "ssh-ed25519":
      guard reader.string()?.count == 32 else { return nil }
    case "ssh-rsa":
      guard let exponent = reader.string(), let modulus = reader.string(),
            validPositiveInteger(exponent), validPositiveInteger(modulus), modulus.count <= 2049 else { return nil }
    case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
      guard let curve = reader.stringText(), type == "ecdsa-sha2-" + curve,
            let point = reader.string(), point.first == 4,
            point.count == ["nistp256": 65, "nistp384": 97, "nistp521": 133][curve] else { return nil }
    default: return nil
    }
    guard reader.atEnd else { return nil }
    let digest = Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    return .init(fingerprint: "SHA256:" + digest, keyType: type, isEncrypted: encrypted)
  }

  private static func validPositiveInteger(_ bytes: Data) -> Bool {
    guard let first = bytes.first, first < 128, bytes.contains(where: { $0 != 0 }) else { return false }
    if first == 0 { return bytes.count > 1 && bytes[bytes.startIndex + 1] >= 128 }
    return true
  }

  private static func openSSH(_ text: String) -> PrivateKeyIdentity? {
    let begin = "-----BEGIN OPENSSH PRIVATE KEY-----", end = "-----END OPENSSH PRIVATE KEY-----"
    guard let start = text.range(of: begin), let stop = text.range(of: end, range: start.upperBound..<text.endIndex),
          text[..<start.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          text[stop.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let decoded = Data(base64Encoded: String(text[start.upperBound..<stop.lowerBound].filter { !$0.isWhitespace })) else { return nil }
    let magic = Data("openssh-key-v1\0".utf8)
    guard decoded.starts(with: magic) else { return nil }
    var reader = KeyBlobReader(Data(decoded.dropFirst(magic.count)))
    guard let cipher = reader.stringText(), let kdf = reader.stringText(), let options = reader.string(),
          reader.uint32() == 1, let publicBlob = reader.string(), let privateBlob = reader.string(),
          !privateBlob.isEmpty, reader.atEnd else { return nil }
    let encrypted = cipher != "none"
    if encrypted {
      var kdfReader = KeyBlobReader(options)
      guard !cipher.isEmpty, kdf == "bcrypt", let salt = kdfReader.string(), !salt.isEmpty,
            let rounds = kdfReader.uint32(), rounds > 0, kdfReader.atEnd else { return nil }
    } else {
      guard kdf == "none", options.isEmpty, privateBlob.count >= 8 else { return nil }
    }
    return identity(blob: publicBlob, encrypted: encrypted)
  }

  private static func pem(_ data: Data, passphrase: String?) -> PrivateKeyIdentity? {
    // A callback is always supplied so OpenSSL never asks on stdin or opens a password UI.
    let password = Data((passphrase ?? "").utf8)
    return data.withUnsafeBytes { bytes in
      guard let bio = BIO_new_mem_buf(bytes.baseAddress, Int32(bytes.count)) else { return nil }
      defer { BIO_free(bio); ERR_clear_error() }
      return password.withUnsafeBytes { passwordBytes in
        var context = KeyPassword(bytes: passwordBytes.baseAddress, count: passwordBytes.count)
        return withUnsafeMutablePointer(to: &context) { pointer in
          guard let key = PEM_read_bio_PrivateKey(bio, nil, { buffer, size, _, user in
            guard let buffer, let user, size > 0 else { return 0 }
            let password = user.assumingMemoryBound(to: KeyPassword.self).pointee
            guard password.count <= Int(size), let bytes = password.bytes else { return 0 }
            buffer.withMemoryRebound(to: UInt8.self, capacity: Int(size)) { destination in
              destination.update(from: bytes.assumingMemoryBound(to: UInt8.self), count: password.count)
            }
            return Int32(password.count)
          }, pointer) else { return nil }
          defer { EVP_PKEY_free(key) }
          var blob = Data()
          if EVP_PKEY_is_a(key, "RSA") == 1 {
            guard let e = integer(key, "e"), let n = integer(key, "n") else { return nil }
            blob.appendKeyString(Data("ssh-rsa".utf8)); blob.appendKeyString(e); blob.appendKeyString(n)
          } else if EVP_PKEY_is_a(key, "ED25519") == 1 {
            var publicBytes = [UInt8](repeating: 0, count: 32), count = publicBytes.count
            guard EVP_PKEY_get_raw_public_key(key, &publicBytes, &count) == 1, count == 32 else { return nil }
            blob.appendKeyString(Data("ssh-ed25519".utf8)); blob.appendKeyString(Data(publicBytes))
          } else if EVP_PKEY_is_a(key, "EC") == 1 {
            var group = [CChar](repeating: 0, count: 80), length = 0
            guard EVP_PKEY_get_utf8_string_param(key, "group", &group, group.count, &length) == 1,
                  let curve = ["prime256v1": "nistp256", "secp384r1": "nistp384", "secp521r1": "nistp521"][String(cString: group)] else { return nil }
            var point = [UInt8](repeating: 0, count: 133), pointLength = 0
            guard EVP_PKEY_get_octet_string_param(key, "pub", &point, point.count, &pointLength) == 1 else { return nil }
            blob.appendKeyString(Data(("ecdsa-sha2-" + curve).utf8)); blob.appendKeyString(Data(curve.utf8))
            blob.appendKeyString(Data(point.prefix(pointLength)))
          } else { return nil }
          let text = String(decoding: data, as: UTF8.self)
          let encrypted = text.contains("BEGIN ENCRYPTED PRIVATE KEY") || text.contains("Proc-Type: 4,ENCRYPTED")
          return identity(blob: blob, encrypted: encrypted)
        }
      }
    }
  }

  private static func integer(_ key: OpaquePointer, _ name: String) -> Data? {
    var number: OpaquePointer?
    guard EVP_PKEY_get_bn_param(key, name, &number) == 1, let number else { return nil }
    defer { BN_free(number) }
    let count = Int((BN_num_bits(number) + 7) / 8)
    guard count > 0, count <= 2048 else { return nil }
    var bytes = [UInt8](repeating: 0, count: count)
    guard BN_bn2bin(number, &bytes) == count else { return nil }
    if bytes[0] >= 128 { bytes.insert(0, at: 0) }
    return Data(bytes)
  }
}

private struct KeyPassword {
  let bytes: UnsafeRawPointer?
  let count: Int
}

private struct KeyBlobReader {
  let bytes: [UInt8]
  var cursor = 0
  init(_ data: Data) { bytes = Array(data) }
  var atEnd: Bool { cursor == bytes.count }
  mutating func uint32() -> UInt32? {
    guard bytes.count - cursor >= 4 else { return nil }
    let result = bytes[cursor..<cursor + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    cursor += 4; return result
  }
  mutating func string() -> Data? {
    guard let length = uint32(), Int(length) <= bytes.count - cursor else { return nil }
    defer { cursor += Int(length) }
    return Data(bytes[cursor..<cursor + Int(length)])
  }
  mutating func stringText() -> String? {
    guard let value = string(), let text = String(data: value, encoding: .utf8),
          text.rangeOfCharacter(from: .controlCharacters.union(.newlines)) == nil else { return nil }
    return text
  }
}

private extension Data {
  mutating func appendKeyString(_ data: Data) {
    let count = UInt32(data.count)
    append(contentsOf: [UInt8((count >> 24) & 255), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255)])
    append(data)
  }
}
