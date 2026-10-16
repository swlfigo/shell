import XCTest
@testable import SwiftTerm

// SwiftTerm 2 no longer exposes a mutable Terminal from a view. Keep these
// test-only reads under its lock and return copied values, never a buffer reference.
@MainActor
func terminalIdentity(_ view: TerminalView) -> ObjectIdentifier {
  view.withTerminal { ObjectIdentifier($0) }
}

@MainActor
func terminalLineText(_ view: TerminalView, row: Int) -> String? {
  view.withTerminal { $0.getLine(row: row)?.translateToString(trimRight: true) }
}

@MainActor
func terminalAttributes(_ view: TerminalView, row: Int) -> [Attribute]? {
  view.withTerminal { $0.getLine(row: row)?.getData().map(\.attribute) }
}

/// Join soft wraps while retaining real spaces and unexpected blank cells. Dropping all
/// NUL cells would conceal the resize regression; only wide-character continuations vanish.
@MainActor
func terminalLogicalLines(_ view: TerminalView) -> [String] {
  view.withTerminal { terminal in
    var result: [String] = []
    var row = terminal.buffer.totalLinesTrimmed
    while let line = terminal.getScrollInvariantLine(row: row) {
      let text = line.translateToString(trimRight: true, skipNullCellsFollowingWide: true,
        characterProvider: { terminal.getCharacter(for: $0) })
      if line.isWrapped && !result.isEmpty { result[result.count - 1] += text }
      else { result.append(text) }
      row += 1
    }
    return result.filter { !$0.isEmpty }
  }
}

func assertTerminalLines(_ actual: [String], _ expected: [String], context: String,
  file: StaticString = #filePath, line: UInt = #line) {
  XCTAssertEqual(actual.count, expected.count, context, file: file, line: line)
  for (index, pair) in zip(actual, expected).enumerated() where pair.0 != pair.1 {
    XCTFail("\(context): changed logical line \(index)\nactual: \(pair.0)\nexpected: \(pair.1)", file: file, line: line)
    break
  }
}
