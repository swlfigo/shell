import AppKit
import XCTest
import TermesKit
import SSHCore
@testable import SwiftTerm
@testable import Termes

@MainActor
final class TerminalViewControllerTests: XCTestCase {
  func test_terminal_search_navigates_chinese_matches_and_exports_plain_utf8_without_mutating_output() throws {
    _ = NSApplication.shared
    let session = SessionManager(knownHosts: KnownHostsStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
    let controller = TerminalViewController(session: session)
    let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 640, height: 320), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = controller.view
    defer { controller.teardown(); window.close() }
    session.onData?(Data("\u{1b}[31m中文needle first\u{1b}[0m\r\n中文NEEDLE second\r\n中文needle third\r\n".utf8))
    controller.showSearch()
    controller.searchField.stringValue = "中文needle"
    controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: controller.searchField))
    controller.applyAppearance(.init(terminalTheme: .graphite, terminalFontSize: 14))
    let first = controller.terminalView.searchMatchSummary("中文needle")
    XCTAssertEqual(first.total, 3)
    XCTAssertGreaterThan(first.index, 0)
    let snapshot = controller.exportSnapshot()
    controller.nextSearchMatch()
    XCTAssertEqual(controller.terminalView.searchMatchSummary("中文needle").index, first.index % 3 + 1)
    controller.previousSearchMatch()
    XCTAssertEqual(controller.terminalView.searchMatchSummary("中文needle").index, first.index)
    XCTAssertEqual(controller.exportSnapshot(), snapshot)
    let text = try XCTUnwrap(String(data: snapshot, encoding: .utf8))
    XCTAssertTrue(text.contains("中文needle first"))
    XCTAssertTrue(text.contains("中文NEEDLE second"))
    XCTAssertFalse(text.contains("\u{1b}"))
    window.setContentSize(NSSize(width: 220, height: 320))
    controller.view.layoutSubtreeIfNeeded()
    controller.refreshSearch(reset: true)
    XCTAssertGreaterThanOrEqual(controller.searchField.frame.width, 60)
    XCTAssertEqual(controller.terminalView.searchMatchSummary("中文needle").total, 3)
    controller.searchField.stringValue = "no-such-output"
    controller.refreshSearch(reset: true)
    XCTAssertEqual(controller.searchStatus.stringValue, "无匹配")
    controller.closeSearch()
    XCTAssertTrue(controller.searchBar.isHidden)
  }

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
