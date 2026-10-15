import AppKit
import XCTest
import SwiftTerm

/// Spec §5 / risk 2: a hidden tab's terminal view is not in any window but must keep consuming output.
@MainActor
final class SwiftTermOffscreenTests: XCTestCase {
  private func line(_ tv: TerminalView, _ row: Int) -> String? {
    tv.getTerminal().getLine(row: row)?.translateToString(trimRight: true)
  }

  func test_feed_without_window_updates_buffer() {
    let tv = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    XCTAssertNil(tv.window)
    tv.feed(byteArray: Array("hello offscreen\r\n".utf8)[...])
    XCTAssertEqual(line(tv, 0), "hello offscreen")
  }

  func test_output_survives_reparenting() {
    let tv = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    let first = NSView(frame: tv.frame)
    let second = NSView(frame: tv.frame)
    first.addSubview(tv)
    tv.feed(byteArray: Array("first\r\n".utf8)[...])
    tv.removeFromSuperview()
    tv.feed(byteArray: Array("second\r\n".utf8)[...])
    second.addSubview(tv)
    XCTAssertEqual(line(tv, 0), "first")
    XCTAssertEqual(line(tv, 1), "second")
  }
}
