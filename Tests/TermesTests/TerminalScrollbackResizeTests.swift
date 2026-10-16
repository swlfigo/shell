import AppKit
import XCTest
import SwiftTerm
import TermesKit
@testable import Termes

@MainActor
final class TerminalScrollbackResizeTests: XCTestCase {
  func test_chinese_log_scrollback_reflows_across_windows() throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let services = AppServices(directory: directory, secrets: InMemorySecretStore())
    let session = services.makeSession(), controller = TerminalViewController(session: session)
    let original = NSWindow(contentRect: .init(x: 0, y: 0, width: 1760, height: 960), styleMask: [.borderless], backing: .buffered, defer: false)
    let detached = NSWindow(contentRect: .init(x: 0, y: 0, width: 940, height: 660), styleMask: [.borderless], backing: .buffered, defer: false)
    original.isReleasedWhenClosed = false; detached.isReleasedWhenClosed = false
    original.contentView = controller.view
    controller.applyAppearance(.init(terminalTheme: .termiusDark, terminalFontSize: 15, terminalFontName: "Monaco"))
    defer { controller.teardown(); original.close(); detached.close() }
    original.contentView?.layoutSubtreeIfNeeded()
    let terminal = controller.terminalView, buffer = terminalIdentity(terminal)
    // Keep all fixture rows while narrowing; trimming at the history cap is a separate behavior.
    terminal.changeScrollback(5000)
    let message = "【专家：金融体系将继续保持对实体经济高质量发展的有力支持】金十数据10月14日讯，近期，人民币政策消息"
    let logs = (0..<200).map { "2|flashnews | 2026/10/14 17:14:25.123456 jin10 recv id=\($0) published=2026-10-14 09:14:25 preview=\"" + message + message + "\"" }
    func assertLogs(_ stage: String) {
      assertTerminalLines(terminalLogicalLines(terminal), logs, context: stage)
      XCTAssertEqual(terminalIdentity(terminal), buffer, stage)
      XCTAssertEqual(session.lastSize?.cols, terminal.terminalDimensions.cols, stage)
      XCTAssertEqual(session.lastSize?.rows, terminal.terminalDimensions.rows, stage)
    }
    session.onData?(Data(logs.map { "\u{1b}[32m\($0)\u{1b}[0m\r\n" }.joined().utf8))
    assertLogs("initial")
    terminal.scroll(toPosition: 0.3)
    XCTAssertLessThan(terminal.scrollPosition, 1)
    func render(_ name: String) throws {
      guard let path = ProcessInfo.processInfo.environment["TERMES_SCROLLBACK_RENDER_DIR"] else { return }
      let renderDirectory = URL(fileURLWithPath: path)
      try FileManager.default.createDirectory(at: renderDirectory, withIntermediateDirectories: true)
      let bitmap = try XCTUnwrap(terminal.bitmapImageRepForCachingDisplay(in: terminal.bounds))
      terminal.cacheDisplay(in: terminal.bounds, to: bitmap)
      try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: renderDirectory.appendingPathComponent(name + ".png"))
    }
    try render("before")
    controller.view.removeFromSuperview(); detached.contentView = controller.view
    for (index, width) in [940.0, 480, 2000, 780, 1800, 650, 1180].enumerated() {
      detached.setContentSize(.init(width: width, height: index % 2 == 0 ? 960 : 660))
      detached.contentView?.layoutSubtreeIfNeeded()
      assertLogs("detached width \(width)")
      try render("detached-\(index)")
    }
    controller.view.removeFromSuperview(); original.contentView = controller.view
    for width in stride(from: 660.0, through: 1800.0, by: 9.0) {
      original.setContentSize(.init(width: width, height: 960))
      original.contentView?.layoutSubtreeIfNeeded()
    }
    assertLogs("continuous widening after returning")
    try render("gradual")
    for (index, width) in [1760.0, 800, 2000, 560, 1500].enumerated() {
      original.setContentSize(.init(width: width, height: 960))
      original.contentView?.layoutSubtreeIfNeeded()
      assertLogs("returned width \(width)")
      try render("returned-\(index)")
    }
  }
}
