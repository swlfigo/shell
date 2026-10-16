import AppKit
import XCTest
import TermesKit
import SSHCore
@testable import SwiftTerm
@testable import Termes

@MainActor
final class TerminalViewControllerTests: XCTestCase {
  func test_terminal_colors_follow_explicit_preference_or_system_appearance_without_replacing_buffer() throws {
    _ = NSApplication.shared
    let session = SessionManager(knownHosts: KnownHostsStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
    let controller = TerminalViewController(session: session)
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 640, height: 320), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = controller.view
    defer { controller.teardown(); window.close() }
    let buffer = terminalIdentity(controller.terminalView)
    session.onData?(Data("preserved output\r\n".utf8))
    func brightness() throws -> CGFloat { try XCTUnwrap(controller.terminalView.nativeBackgroundColor.usingColorSpace(.sRGB)).redComponent }
    window.appearance = NSAppearance(named: .darkAqua)
    controller.applyAppearance(.init(terminalTheme: .light, terminalFontSize: 18))
    XCTAssertGreaterThan(try brightness(), 0.9)
    controller.applyAppearance(.init(terminalTheme: .appearance, terminalFontSize: 18))
    XCTAssertLessThan(try brightness(), 0.1)
    window.appearance = NSAppearance(named: .aqua)
    XCTAssertGreaterThan(try brightness(), 0.9)
    controller.applyAppearance(.init(terminalTheme: .graphite, terminalFontSize: 18))
    XCTAssertLessThan(try brightness(), 0.1)
    XCTAssertTrue(terminalIdentity(controller.terminalView) == buffer)
    XCTAssertTrue(String(decoding: controller.terminalView.getBufferAsData(), as: UTF8.self).contains("preserved output"))
  }

  func test_scrollback_indicator_stays_visible_and_tracks_history_position() throws {
    _ = NSApplication.shared
    let session = SessionManager(knownHosts: KnownHostsStore(
      fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
    let controller = TerminalViewController(session: session)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 320),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = controller.view
    defer { controller.teardown(); window.close() }
    controller.view.layoutSubtreeIfNeeded()
    let terminal = controller.terminalView
    let scroller = try XCTUnwrap(terminal.subviews.compactMap { $0 as? NSScroller }.first)

    let output = (0..<200).map { "line \($0)\r\n" }.joined()
    session.onData?(Data(output.utf8))
    terminal.scroll(toPosition: 0.5)
    controller.view.layoutSubtreeIfNeeded()
    terminal.frameTick()

    XCTAssertEqual(scroller.scrollerStyle, .legacy, "the position indicator must not auto-hide")
    XCTAssertFalse(scroller.isHiddenOrHasHiddenAncestor)
    XCTAssertTrue(scroller.isEnabled)
    XCTAssertGreaterThan(scroller.rect(for: .knob).height, 0)
    XCTAssertGreaterThan(scroller.knobProportion, 0)
    XCTAssertLessThan(scroller.knobProportion, 1)
    XCTAssertEqual(scroller.doubleValue, terminal.scrollPosition, accuracy: 0.001)
    XCTAssertEqual(scroller.doubleValue, 0.5, accuracy: 0.02)
    XCTAssertEqual(scroller.frame.maxX, terminal.bounds.maxX, accuracy: 0.5)

    terminal.scroll(toPosition: 0)
    terminal.frameTick()
    XCTAssertEqual(scroller.doubleValue, 0, accuracy: 0.001)
    terminal.scroll(toPosition: 1)
    terminal.frameTick()
    XCTAssertEqual(scroller.doubleValue, 1, accuracy: 0.001)
    window.setContentSize(NSSize(width: 480, height: 200))
    controller.view.layoutSubtreeIfNeeded()
    XCTAssertFalse(scroller.isHiddenOrHasHiddenAncestor)
    XCTAssertEqual(scroller.frame.maxX, terminal.bounds.maxX, accuracy: 0.5)
  }
}
