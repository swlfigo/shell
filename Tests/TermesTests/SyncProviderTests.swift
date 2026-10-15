import XCTest
@testable import TermesKit

final class SyncProviderTests: XCTestCase {
  private func tempURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
  }

  func test_file_provider_push_then_pull_roundtrip() async throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
    let provider = FileSyncProvider(fileURL: url)
    XCTAssertFalse(provider.handlesSecrets)
    let none = try await provider.pull()
    XCTAssertNil(none)                                   // no file yet
    let snap = ConnectionSnapshot(
      profiles: [ConnectionProfile(name: "a", hostname: "h", port: 22, username: "u", auth: .password)],
      keys: [SSHKey(name: "k")])
    let v1 = try await provider.push(snap, baseVersion: nil)
    let pulled = try await provider.pull()
    XCTAssertEqual(pulled?.profiles.count, 1)
    XCTAssertEqual(pulled?.keys.count, 1)
    XCTAssertEqual(pulled?.encryptedSecrets, nil)         // non-secret provider never writes secrets
    XCTAssertEqual(v1, pulled?.version)                   // version persisted
  }

  func test_push_strips_encrypted_secrets() async throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
    let provider = FileSyncProvider(fileURL: url)
    let snap = ConnectionSnapshot(profiles: [], keys: [], encryptedSecrets: Data("x".utf8))
    _ = try await provider.push(snap, baseVersion: nil)
    let pulled = try await provider.pull()
    XCTAssertNotNil(pulled)
    XCTAssertNil(pulled?.encryptedSecrets)
  }

  func test_version_changes_with_content() async throws {
    let url = tempURL(); defer { try? FileManager.default.removeItem(at: url) }
    let provider = FileSyncProvider(fileURL: url)
    let v1 = try await provider.push(ConnectionSnapshot(profiles: [], keys: []), baseVersion: nil)
    let v2 = try await provider.push(
      ConnectionSnapshot(profiles: [ConnectionProfile(name: "a", hostname: "h", port: 22, username: "u", auth: .password)], keys: []),
      baseVersion: v1)
    XCTAssertNotEqual(v1, v2)
  }
}
