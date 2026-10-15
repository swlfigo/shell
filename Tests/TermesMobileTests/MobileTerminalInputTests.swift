import XCTest
import UIKit
import SwiftTerm
@testable import TermesMobile

@MainActor
final class MobileTerminalInputTests: XCTestCase {
  private func fixture() -> (MobileTerminalView, TerminalInputRecorder) {
    var options = TerminalOptions.default
    options.cursorStyle = .steadyBlock
    let terminal = MobileTerminalView(frame: CGRect(x: 0, y: 0, width: 360, height: 500),
      font: nil, options: options)
    let recorder = TerminalInputRecorder()
    terminal.terminalDelegate = recorder
    return (terminal, recorder)
  }

  private func markedText(_ terminal: TerminalView) -> String? {
    terminal.markedTextRange.flatMap { terminal.text(in: $0) }
  }

  private func select(_ range: NSRange, inMarkedTextOf terminal: TerminalView) throws {
    let marked = try XCTUnwrap(terminal.markedTextRange)
    let start = try XCTUnwrap(terminal.position(from: marked.start, offset: range.location))
    let end = try XCTUnwrap(terminal.position(from: start, offset: range.length))
    terminal.selectedTextRange = try XCTUnwrap(terminal.textRange(from: start, to: end))
  }

  func testDeletingPinyinDoesNotSendBackspacesForUncommittedText() {
    let (terminal, recorder) = fixture()
    terminal.insertText("echo KEEP")
    terminal.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0))
    XCTAssertEqual(recorder.bytes, Array("echo KEEP".utf8))

    terminal.deleteBackward()

    XCTAssertEqual(recorder.bytes, Array("echo KEEP".utf8),
      "preedit text has never reached the server, so editing it must not erase committed input")
    XCTAssertEqual(markedText(terminal), "niha")
    terminal.insertText("你好")
    terminal.unmarkText()
    XCTAssertEqual(recorder.bytes, Array("echo KEEP你好".utf8), "the chosen candidate commits once")
  }

  func testDeletingMarkedSelectionUsesUTF16OffsetsAndPreservesTheOtherText() throws {
    let (terminal, recorder) = fixture()
    terminal.insertText("KEEP")
    terminal.setMarkedText("甲👩🏽‍💻乙", selectedRange: NSRange(location: 1, length: 7))

    terminal.deleteBackward()

    XCTAssertEqual(markedText(terminal), "甲乙")
    XCTAssertEqual(recorder.bytes, Array("KEEP".utf8))
    let marked = try XCTUnwrap(terminal.markedTextRange)
    let selection = try XCTUnwrap(terminal.selectedTextRange)
    XCTAssertEqual(terminal.offset(from: marked.start, to: selection.start), 1)
    XCTAssertTrue(selection.isEmpty)
    terminal.unmarkText()
    XCTAssertEqual(recorder.bytes, Array("KEEP甲乙".utf8))
  }

  func testDeletingBeforeMarkedCaretRemovesOneWholeGrapheme() throws {
    let (terminal, recorder) = fixture()
    let composition = "拼e\u{301}👨‍👩‍👧‍👦尾"
    terminal.setMarkedText(composition,
      selectedRange: NSRange(location: composition.utf16.count, length: 0))
    try select(NSRange(location: "拼e\u{301}👨‍👩‍👧‍👦".utf16.count, length: 0),
      inMarkedTextOf: terminal)

    terminal.deleteBackward()
    XCTAssertEqual(markedText(terminal), "拼e\u{301}尾")
    terminal.deleteBackward()
    XCTAssertEqual(markedText(terminal), "拼尾")
    XCTAssertTrue(recorder.bytes.isEmpty)
    terminal.unmarkText()
    XCTAssertEqual(recorder.bytes, Array("拼尾".utf8))
  }

  func testUTF16CaretInsideAGraphemeIsNormalizedBeforeDeletion() throws {
    let (terminal, recorder) = fixture()
    terminal.insertText("KEEP")
    terminal.setMarkedText("甲👩🏽‍💻乙", selectedRange: NSRange(location: 3, length: 0))
    let marked = try XCTUnwrap(terminal.markedTextRange)
    let selection = try XCTUnwrap(terminal.selectedTextRange)
    XCTAssertEqual(terminal.offset(from: marked.start, to: selection.start), 8)

    terminal.deleteBackward()

    XCTAssertEqual(markedText(terminal), "甲乙")
    XCTAssertEqual(recorder.bytes, Array("KEEP".utf8))
    terminal.unmarkText()
    XCTAssertEqual(recorder.bytes, Array("KEEP甲乙".utf8))
  }

  func testDeletingAtTheStartOfCompositionDoesNotTouchCommittedText() {
    let (terminal, recorder) = fixture()
    terminal.insertText("KEEP")
    terminal.setMarkedText("nihao", selectedRange: NSRange(location: 0, length: 0))

    terminal.deleteBackward()

    XCTAssertEqual(markedText(terminal), "nihao")
    XCTAssertEqual(recorder.bytes, Array("KEEP".utf8))
  }

  func testDeletingTheLastMarkedCharacterClearsCompositionThenNormalBackspaceWorks() {
    let (terminal, recorder) = fixture()
    terminal.insertText("KEEP")
    terminal.setMarkedText("你", selectedRange: NSRange(location: 1, length: 0))

    terminal.deleteBackward()

    XCTAssertNil(terminal.markedTextRange)
    XCTAssertEqual(recorder.bytes, Array("KEEP".utf8))
    terminal.deleteBackward()
    XCTAssertEqual(recorder.bytes, Array("KEEP".utf8) + [0x7f])
  }

  func testEmptyMarkedRangeDoesNotDeletePreviouslyCommittedInput() {
    let (terminal, recorder) = fixture()
    terminal.insertText("KEEP")
    terminal.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))

    terminal.deleteBackward()

    XCTAssertEqual(recorder.bytes, Array("KEEP".utf8))
  }

  func testCommittedBackspaceKeepsTheConfiguredTerminalSequence() {
    let (terminal, recorder) = fixture()
    terminal.insertText("你好👩🏽‍💻")
    terminal.deleteBackward()
    XCTAssertEqual(recorder.bytes, Array("你好👩🏽‍💻".utf8) + [0x7f])
    terminal.backspaceSendsControlH = true
    terminal.deleteBackward()
    XCTAssertEqual(recorder.bytes, Array("你好👩🏽‍💻".utf8) + [0x7f, 0x08])
  }

  func testCancellingCompositionSendsNothingAndTheNextCommitStillWorks() {
    let (terminal, recorder) = fixture()
    terminal.insertText("KEEP")
    terminal.setMarkedText("nihao", selectedRange: NSRange(location: 5, length: 0))
    terminal.setMarkedText(nil, selectedRange: NSRange(location: 0, length: 0))
    terminal.unmarkText()
    XCTAssertEqual(recorder.bytes, Array("KEEP".utf8))
    terminal.insertText("后续")
    XCTAssertEqual(recorder.bytes, Array("KEEP后续".utf8))
  }

  #if targetEnvironment(simulator)
  func testPastingMultilineUnicodeSendsTheOriginalBytes() {
    let (terminal, recorder) = fixture()
    let pasteboard = UIPasteboard.general
    defer { pasteboard.items = [] }
    let payload = "echo hello 世界\n第二行 👩🏽‍💻 e\u{301}\r\n第三行\n"
    pasteboard.setItems([["public.utf8-plain-text": payload]], options: [.localOnly: true])
    XCTAssertFalse(terminal.getTerminal().bracketedPasteMode)

    terminal.paste(nil)

    XCTAssertEqual(recorder.bytes, Array(payload.utf8))
  }

  func testBracketedPasteWrapsMultilineUnicodeExactlyOnce() {
    let (terminal, recorder) = fixture()
    let pasteboard = UIPasteboard.general
    defer { pasteboard.items = [] }
    let payload = "first line 中文\n第二行 🌏 👩🏽‍💻\r\nlast e\u{301}\n"
    pasteboard.setItems([["public.utf8-plain-text": payload]], options: [.localOnly: true])
    terminal.feed(text: "\u{1b}[?2004h")
    XCTAssertTrue(terminal.getTerminal().bracketedPasteMode)
    XCTAssertTrue(recorder.bytes.isEmpty)

    terminal.paste(nil)

    XCTAssertEqual(recorder.bytes, Array(("\u{1b}[200~" + payload + "\u{1b}[201~").utf8))
  }
  #endif
}

@MainActor
private final class TerminalInputRecorder: @preconcurrency TerminalViewDelegate {
  var bytes: [UInt8] = []

  func send(source: TerminalView, data: ArraySlice<UInt8>) { bytes.append(contentsOf: data) }
  func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
  func setTerminalTitle(source: TerminalView, title: String) {}
  func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
  func scrolled(source: TerminalView, position: Double) {}
  func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
  func bell(source: TerminalView) {}
  func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
