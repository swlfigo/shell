import XCTest
@testable import SSHCore

final class FakeShellChannel: ShellChannel, @unchecked Sendable {
  let output: AsyncStream<Data>
  private let cont: AsyncStream<Data>.Continuation
  private(set) var sent: [Data] = []
  private(set) var lastSize: (Int, Int)?

  init() {
    (output, cont) = AsyncStream.makeStream(of: Data.self)
  }

  func emit(_ d: Data) {
    cont.yield(d)
  }

  func send(_ data: Data) async {
    sent.append(data)
  }

  func resize(cols: Int, rows: Int) async {
    lastSize = (cols, rows)
  }

  func close() async {
    cont.finish()
  }
}

final class FakeShellChannelTests: XCTestCase {
  func test_output_stream_delivers_emitted_bytes() async {
    let ch = FakeShellChannel()
    ch.emit(Data("hi".utf8))
    await ch.close()
    var got = Data()
    for await chunk in ch.output {
      got.append(chunk)
    }
    XCTAssertEqual(String(data: got, encoding: .utf8), "hi")
  }
}
