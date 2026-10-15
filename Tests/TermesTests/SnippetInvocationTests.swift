import AppKit
import XCTest
import TermesKit
@testable import Termes

@MainActor
final class SnippetInvocationTests: XCTestCase {
  func test_preview_validation_failed_insert_keeps_values_and_cancel_never_submits() throws {
    _ = NSApplication.shared
    let snippet = Snippet(name: "Deploy", command: "cd '{{path}}'\nprintf '%s' '{{name}}'", kind: .script, usesParameters: true)
    let page = SnippetInvocationViewController(snippet: snippet, destination: "服务器 A")
    _ = page.view
    page.parameterFields["path"]?.stringValue = "/tmp/中文"
    page.parameterFields["name"]?.stringValue = "hello"
    page.refreshPreview()
    XCTAssertEqual(page.preview.string, "cd '/tmp/中文'\nprintf '%s' 'hello'")
    var calls = 0, dismissed = 0
    page.onInsert = { _ in calls += 1; throw SnippetError.changedElsewhere }
    page.onDismiss = { dismissed += 1 }
    XCTAssertFalse(page.insert())
    XCTAssertEqual(calls, 1); XCTAssertEqual(dismissed, 0)
    XCTAssertEqual(page.parameterFields["path"]?.stringValue, "/tmp/中文")
    XCTAssertFalse(page.errorLabel.isHidden)
    page.parameterFields["name"]?.stringValue = "bad\nvalue"
    page.refreshPreview()
    XCTAssertFalse(page.insertButton.isEnabled)
    XCTAssertFalse(page.insert()); XCTAssertEqual(calls, 1)
    page.cancel(); page.cancel()
    XCTAssertEqual(dismissed, 1)
    XCTAssertFalse(page.insert()); XCTAssertEqual(calls, 1)
  }

  func test_preview_supports_32_parameters_and_submit_only_once_at_minimum_size() throws {
    _ = NSApplication.shared
    let snippet = Snippet(name: "Many", command: "printf '%s' " + (0..<32).map { "'{{p\($0)}}'" }.joined(separator: " "), usesParameters: true)
    let page = SnippetInvocationViewController(snippet: snippet, destination: String(repeating: "服务器", count: 100))
    let window = NSWindow(contentViewController: page)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.setContentSize(NSSize(width: 560, height: 500))
    page.view.layoutSubtreeIfNeeded(); page.view.layoutSubtreeIfNeeded()
    XCTAssertEqual(page.parameterFields.count, 32)
    for name in snippet.parameterNames { page.parameterFields[name]?.stringValue = "值" }
    page.refreshPreview()
    for control in [page.preview, page.insertButton] {
      let rect = control.convert(control.bounds, to: page.view)
      XCTAssertGreaterThan(rect.width, 0)
      XCTAssertGreaterThanOrEqual(rect.minX, 0)
      XCTAssertLessThanOrEqual(rect.maxX, 560.5)
    }
    let buttonRect = page.insertButton.convert(page.insertButton.bounds, to: page.view)
    XCTAssertGreaterThanOrEqual(buttonRect.minY, 0)
    XCTAssertLessThanOrEqual(buttonRect.maxY, 500.5)
    var values: [String: String] = [:], dismissed = 0
    page.onInsert = { values = $0 }; page.onDismiss = { dismissed += 1 }
    XCTAssertTrue(page.insert()); XCTAssertFalse(page.insert())
    XCTAssertEqual(values.count, 32); XCTAssertTrue(values.values.allSatisfy { $0 == "值" })
    XCTAssertEqual(dismissed, 1)
  }

  func test_long_script_editor_and_preview_scroll_to_the_final_line() throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SnippetStore(fileURL: directory.appendingPathComponent("snippets.json"))
    let text = String(repeating: "printf '%s\\n' '中文'\n", count: 1000) + "echo final"
    let snippet = try store.save(name: "Long script", command: text, kind: .script)
    let manager = SnippetManagerViewController(store: store)
    _ = manager.view
    manager.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    let page = SnippetInvocationViewController(snippet: snippet, destination: "A")
    for (controller, textView) in [(manager as NSViewController, manager.scriptView), (page as NSViewController, page.preview)] {
      let window = NSWindow(contentViewController: controller)
      window.isReleasedWhenClosed = false
      window.setContentSize(NSSize(width: 560, height: 500))
      controller.view.layoutSubtreeIfNeeded(); controller.view.layoutSubtreeIfNeeded()
      let scroll = try XCTUnwrap(textView.enclosingScrollView)
      XCTAssertEqual(textView.string, text)
      XCTAssertGreaterThan(textView.frame.height, scroll.contentSize.height)
      textView.scrollRangeToVisible(NSRange(location: (text as NSString).length - 1, length: 1))
      XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
      window.close()
    }
  }
}
