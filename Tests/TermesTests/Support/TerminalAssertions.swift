import XCTest
import SwiftTerm

/// Join soft wraps while retaining real spaces and unexpected blank cells. Dropping all
/// NUL cells would conceal the resize regression; only wide-character continuations vanish.
@MainActor
func terminalLogicalLines(_ terminal: Terminal) -> [String] {
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

func assertTerminalLines(_ actual: [String], _ expected: [String], context: String,
  file: StaticString = #filePath, line: UInt = #line) {
  XCTAssertEqual(actual.count, expected.count, context, file: file, line: line)
  for (index, pair) in zip(actual, expected).enumerated() where pair.0 != pair.1 {
    XCTFail("\(context): changed logical line \(index)\nactual: \(pair.0)\nexpected: \(pair.1)", file: file, line: line)
    break
  }
}
