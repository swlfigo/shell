import XCTest
import SSHCore
@testable import TermesKit

final class FakeShellChannel: ShellChannel, @unchecked Sendable {
  let output: AsyncStream<Data>
  private let cont: AsyncStream<Data>.Continuation
  private let lock = NSLock()
  private var _sent: [Data] = []
  private var _lastSize: (Int, Int)?
  var sent: [Data] { lock.withLock { _sent } }
  var lastSize: (Int, Int)? { lock.withLock { _lastSize } }

  init() { (output, cont) = AsyncStream.makeStream(of: Data.self) }
  func emit(_ d: Data) { cont.yield(d) }
  func send(_ data: Data) async { lock.withLock { _sent.append(data) } }
  func resize(cols: Int, rows: Int) async { lock.withLock { _lastSize = (cols, rows) } }
  func close() async { cont.finish() }
}

@MainActor final class TerminalServiceTests: XCTestCase {
  func test_forwards_output_then_closed() async {
    let ch = FakeShellChannel()
    let svc = TerminalService(channel: ch)
    var got = Data(); var closed = false
    svc.onData = { got.append($0) }; svc.onClosed = { closed = true }
    svc.start()
    ch.emit(Data("abc".utf8)); await ch.close()
    try? await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertEqual(String(decoding: got, as: UTF8.self), "abc")
    XCTAssertTrue(closed)
  }

  func test_sendInput_and_resize_passthrough() async {
    let ch = FakeShellChannel(); let svc = TerminalService(channel: ch)
    svc.start()
    svc.sendInput(Data("x".utf8)); svc.resize(cols: 100, rows: 30)
    try? await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertEqual(ch.sent.first, Data("x".utf8))
    XCTAssertEqual(ch.lastSize?.0, 100)
  }

  func test_sendInput_preserves_order() async {
    let ch = FakeShellChannel(); let svc = TerminalService(channel: ch)
    svc.start()
    let expected = (0..<200).map { Data("\($0)".utf8) }
    expected.forEach { svc.sendInput($0) }
    for _ in 0..<100 where ch.sent.count < expected.count { try? await Task.sleep(nanoseconds: 20_000_000) }
    XCTAssertEqual(ch.sent, expected)
  }
}
