import XCTest
import SSHCore
@testable import TermesKit

private struct NoopStore: KnownHostsStoring {
  func all() throws -> [KnownHost] { [] }
  func lookup(hostname: String, port: Int) throws -> KnownHost? { nil }
  func save(_ host: KnownHost) throws {}
}

private final class HandoffShellChannel: ShellChannel, @unchecked Sendable {
  enum Event: Equatable { case resize(Int, Int), input(Data) }
  let output: AsyncStream<Data>
  private let continuation: AsyncStream<Data>.Continuation
  private let lock = NSLock()
  private var recordedEvents: [Event] = []
  let inputReceived = XCTestExpectation(description: "input reaches the newly attached transport")
  var events: [Event] { lock.withLock { recordedEvents } }

  init() { (output, continuation) = AsyncStream.makeStream(of: Data.self) }
  func send(_ data: Data) async {
    lock.withLock { recordedEvents.append(.input(data)) }
    inputReceived.fulfill()
  }
  func resize(cols: Int, rows: Int) async {
    lock.withLock { recordedEvents.append(.resize(cols, rows)) }
  }
  func close() async { continuation.finish() }
}

@MainActor
final class SessionManagerTests: XCTestCase {
  func testResizeBeforeConnectIsRemembered() {
    let m = SessionManager(knownHosts: NoopStore())
    XCTAssertNil(m.lastSize)
    m.resize(cols: 120, rows: 40)
    XCTAssertEqual(m.lastSize?.cols, 120)
    XCTAssertEqual(m.lastSize?.rows, 40)
  }

  func testNewTransportReceivesLatestSizeChangedWhileItsPTYWasOpeningBeforeInput() async throws {
    let manager = SessionManager(knownHosts: NoopStore())
    defer { manager.disconnect() }
    manager.resize(cols: 80, rows: 24)
    let openedSize = try XCTUnwrap(manager.lastSize)
    // Rotation and keyboard changes can occur while reconnect awaits openShell.
    manager.resize(cols: 120, rows: 30)
    manager.resize(cols: 160, rows: 48)
    let channel = HandoffShellChannel()
    manager.attach(channel: channel, initialSize: openedSize)
    let input = Data("echo resized\r".utf8)
    manager.sendInput(input)
    await fulfillment(of: [channel.inputReceived], timeout: 2)
    XCTAssertEqual(channel.events, [.resize(160, 48), .input(input)])
  }

  func testNewTransportDoesNotResizeAgainWhenItsPTYAlreadyMatchesTheLayout() async {
    let manager = SessionManager(knownHosts: NoopStore())
    defer { manager.disconnect() }
    manager.resize(cols: 120, rows: 40)
    let channel = HandoffShellChannel()
    manager.attach(channel: channel, initialSize: (120, 40))
    let input = Data("echo unchanged\r".utf8)
    manager.sendInput(input)
    await fulfillment(of: [channel.inputReceived], timeout: 2)
    XCTAssertEqual(channel.events, [.input(input)])
  }

  func testConfirmHostKeyWithoutPendingIsNoop() {
    let m = SessionManager(knownHosts: NoopStore())
    m.confirmHostKey(true)
    XCTAssertEqual(m.state, .idle)
  }

  func testDisconnectWhenIdleStaysIdle() {
    let m = SessionManager(knownHosts: NoopStore())
    m.disconnect()
    XCTAssertEqual(m.state, .idle)
  }

  func testManualRetryRetainsFailedConfigurationUntilDisconnectAndNeverReconnectsAfterCancellation() async {
    let manager = SessionManager(knownHosts: NoopStore())
    defer { manager.disconnect() }
    XCTAssertFalse(manager.canRetryConnection)
    await manager.retryConnection()
    XCTAssertEqual(manager.state, .idle)
    let config = ConnectionConfig(hostname: "127.0.0.1", port: 1, username: "retry-user", auth: .password("RETRY_SECRET"))
    await manager.connect(config)
    guard case .failed = manager.state else { return XCTFail("expected a closed-port failure") }
    XCTAssertTrue(manager.canRetryConnection)
    XCTAssertNil(manager.currentConfig)
    let attemptID = manager.connectionProgress.attemptID
    await manager.retryConnection()
    guard case .failed = manager.state else { return XCTFail("expected another closed-port failure") }
    XCTAssertTrue(manager.canRetryConnection)
    XCTAssertEqual(manager.connectionProgress.attempt, 2)
    XCTAssertNotEqual(manager.connectionProgress.attemptID, attemptID)
    XCTAssertFalse(manager.connectionProgress.logs.contains { $0.text.contains("RETRY_SECRET") })
    manager.disconnect()
    XCTAssertFalse(manager.canRetryConnection)
    let cancelledAttemptID = manager.connectionProgress.attemptID
    await manager.retryConnection()
    XCTAssertEqual(manager.state, .disconnected)
    XCTAssertNil(manager.currentConfig)
    XCTAssertEqual(manager.connectionProgress.attemptID, cancelledAttemptID)
  }

  func testSnippetIsNotInsertedWhileIdleOrReconnecting() {
    let manager = SessionManager(knownHosts: NoopStore())
    let snippet = Snippet(name: "Disk", command: "df -h")
    XCTAssertFalse(manager.insertSnippet(snippet))
    manager.config = .init(hostname: "127.0.0.1", port: 1, username: "u", auth: .password("p"))
    manager.startReconnect()
    XCTAssertFalse(manager.insertSnippet(snippet))
    manager.disconnect()
    XCTAssertFalse(manager.insertSnippet(snippet))
  }
}
