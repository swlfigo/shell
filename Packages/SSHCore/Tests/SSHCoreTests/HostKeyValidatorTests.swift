import XCTest
@testable import SSHCore

final class HostKeyValidatorTests: XCTestCase {
  func store() -> KnownHostsStore {
    KnownHostsStore(fileURL: FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString + ".json"))
  }

  func test_unknown_on_first_sight() throws {
    let v = HostKeyValidator(store: store())
    let d = try v.evaluate(hostname: "h", port: 22, keyType: "ssh-ed25519", publicKeyBlob: Data([1,2,3]))
    if case .unknown = d {} else { XCTFail("expected unknown, got \(d)") }
  }

  func test_trusted_when_matches_saved() throws {
    let s = store(); let blob = Data([1,2,3])
    let fp = HostKeyValidator.fingerprint(blob)
    try s.save(KnownHost(hostname: "h", port: 22, keyType: "ssh-ed25519",
                         publicKeyBlob: blob, fingerprintSHA256: fp, addedAt: Date()))
    XCTAssertEqual(try HostKeyValidator(store: s)
      .evaluate(hostname: "h", port: 22, keyType: "ssh-ed25519", publicKeyBlob: blob), .trusted)
  }

  func test_mismatch_when_key_changed() throws {
    let s = store()
    try s.save(KnownHost(hostname: "h", port: 22, keyType: "ssh-ed25519",
                         publicKeyBlob: Data([1,2,3]),
                         fingerprintSHA256: HostKeyValidator.fingerprint(Data([1,2,3])), addedAt: Date()))
    let d = try HostKeyValidator(store: s)
      .evaluate(hostname: "h", port: 22, keyType: "ssh-ed25519", publicKeyBlob: Data([9,9,9]))
    if case .mismatch = d {} else { XCTFail("expected mismatch, got \(d)") }
  }
}
