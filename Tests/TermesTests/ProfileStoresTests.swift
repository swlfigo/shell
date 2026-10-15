import XCTest
@testable import TermesKit

final class ProfileStoresTests: XCTestCase {
  private func tempURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
  }

  func test_connection_store_roundtrip() throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
    let store = ConnectionStore(fileURL: url)
    XCTAssertEqual(try store.all(), [])                       // missing file -> empty
    let p = ConnectionProfile(name: "a", hostname: "h", port: 22, username: "u", auth: .password)
    try store.upsert(p)
    XCTAssertEqual(try store.get(p.id), p)
    var p2 = p; p2.name = "b"; try store.upsert(p2)           // upsert replaces by id
    XCTAssertEqual(try store.all().count, 1)
    XCTAssertEqual(try store.get(p.id)?.name, "b")
    try store.delete(p.id)
    XCTAssertNil(try store.get(p.id))
  }

  func test_key_store_roundtrip() throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
    let store = KeyStore(fileURL: url)
    let k = SSHKey(name: "id_ed25519")
    try store.upsert(k)
    XCTAssertEqual(try store.get(k.id), k)
    try store.delete(k.id)
    XCTAssertEqual(try store.all(), [])
  }

  func test_corrupt_file_throws_not_wipes() throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
    try Data("not json".utf8).write(to: url)
    let store = ConnectionStore(fileURL: url)
    XCTAssertThrowsError(try store.all())
  }
}
