import CryptoKit
import Foundation

public enum HostKeyDecision: Equatable {
  case trusted
  case unknown(fingerprint: String)
  case mismatch(stored: String, got: String)
}

public struct HostKeyValidator: Sendable {
  private let store: KnownHostsStoring

  public init(store: KnownHostsStoring) {
    self.store = store
  }

  public static func fingerprint(_ blob: Data) -> String {
    let d = SHA256.hash(data: blob)
    return "SHA256:" + Data(d).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
  }

  public func evaluate(hostname: String, port: Int, keyType: String,
                       publicKeyBlob: Data) throws -> HostKeyDecision {
    let fp = Self.fingerprint(publicKeyBlob)
    guard let saved = try store.lookup(hostname: hostname, port: port) else {
      return .unknown(fingerprint: fp)
    }
    return saved.fingerprintSHA256 == fp ? .trusted
      : .mismatch(stored: saved.fingerprintSHA256, got: fp)
  }
}
