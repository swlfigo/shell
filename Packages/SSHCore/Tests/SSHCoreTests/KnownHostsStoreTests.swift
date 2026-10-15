import XCTest
@testable import SSHCore

final class KnownHostsStoreTests: XCTestCase {
  func tempStore() -> KnownHostsStore {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString + ".json")
    return KnownHostsStore(fileURL: url)
  }

  func test_lookup_missing_returns_nil() throws {
    XCTAssertNil(try tempStore().lookup(hostname: "h", port: 22))
  }

  func test_save_then_lookup_roundtrip_and_persists() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    let s1 = KnownHostsStore(fileURL: url)
    let h = KnownHost(hostname: "h", port: 22, keyType: "ssh-ed25519",
                      publicKeyBlob: Data([1, 2, 3]), fingerprintSHA256: "AA:BB", addedAt: Date())
    try s1.save(h)
    // 新实例从同一文件读 → 持久化成立
    let s2 = KnownHostsStore(fileURL: url)
    XCTAssertEqual(try s2.lookup(hostname: "h", port: 22)?.fingerprintSHA256, "AA:BB")
  }
}
