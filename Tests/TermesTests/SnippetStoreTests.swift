import XCTest
import Combine
@testable import TermesKit

@MainActor
final class SnippetStoreTests: XCTestCase {
  private func makeURL() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  func test_create_edit_restart_and_delete_preserve_identity_and_order() throws {
    let url = makeURL()
    let store = SnippetStore(fileURL: url)
    XCTAssertEqual(try store.all(), [])
    let first = try store.save(name: "  Disk  ", command: "df -h")
    let second = try store.save(name: "Unicode", command: "printf '你好'")
    XCTAssertEqual(first.name, "Disk")
    let updated = try store.save(id: first.id, name: "Disk usage", command: "  df -h /  ")
    XCTAssertEqual(updated.id, first.id)
    XCTAssertEqual(updated.command, "  df -h /  ")
    XCTAssertEqual(try SnippetStore(fileURL: url).all(), [updated, second])
    try store.delete(first.id)
    XCTAssertEqual(try store.all(), [second])
  }

  func test_rejects_empty_and_control_characters_without_writing_or_notifying() throws {
    let url = makeURL()
    let store = SnippetStore(fileURL: url)
    var notifications = 0
    let observer = store.didChange.sink { notifications += 1 }
    defer { observer.cancel() }
    for command in ["", "   ", "pwd\n", "pwd\r", "pwd\r\nls", "\u{1b}[31m", "a\u{0}b", "a\tb", "a\u{2028}b"] {
      XCTAssertThrowsError(try store.save(name: "Test", command: command), command)
    }
    XCTAssertThrowsError(try store.save(name: "  ", command: "pwd"))
    XCTAssertThrowsError(try store.save(name: "a\nb", command: "pwd"))
    XCTAssertEqual(notifications, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
  }

  func test_successful_mutations_notify_after_the_file_is_updated() throws {
    let store = SnippetStore(fileURL: makeURL())
    var snapshots: [[Snippet]] = []
    let observer = store.didChange.sink { snapshots.append((try? store.all()) ?? []) }
    defer { observer.cancel() }
    let snippet = try store.save(name: "Disk", command: "df -h")
    let edited = try store.save(id: snippet.id, name: "Disk", command: "df -h /")
    try store.delete(snippet.id)
    XCTAssertEqual(snapshots, [[snippet], [edited], []])
    XCTAssertThrowsError(try store.save(id: snippet.id, name: "Stale", command: "pwd"))
    XCTAssertThrowsError(try store.delete(snippet.id))
    XCTAssertEqual(snapshots.count, 3)
  }

  func test_corrupt_invalid_or_duplicate_records_are_never_overwritten() throws {
    let url = makeURL()
    let store = SnippetStore(fileURL: url)
    let item = Snippet(name: "Test", command: "pwd")
    for data in [Data("broken".utf8), try JSONEncoder().encode([item, item]),
                 try JSONEncoder().encode([Snippet(name: "Bad", command: "pwd\nls")])] {
      try data.write(to: url)
      XCTAssertThrowsError(try store.all())
      XCTAssertThrowsError(try store.save(name: "New", command: "ls"))
      XCTAssertThrowsError(try store.delete(item.id))
      XCTAssertEqual(try Data(contentsOf: url), data)
    }
  }

  func test_io_failures_propagate_without_notifications() throws {
    let url = makeURL().appendingPathComponent("missing/snippets.json")
    let store = SnippetStore(fileURL: url)
    var notifications = 0
    let observer = store.didChange.sink { notifications += 1 }
    defer { observer.cancel() }
    XCTAssertThrowsError(try store.save(name: "Test", command: "pwd"))
    XCTAssertEqual(notifications, 0)
    // A directory at the file path is a read error, not an empty store.
    let directory = makeURL()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    XCTAssertThrowsError(try SnippetStore(fileURL: directory).all())
  }

  func test_legacy_records_remain_literal_and_new_metadata_survives_restart_and_old_save_api() throws {
    let url = makeURL(), id = UUID()
    let legacy = "[{\"id\":\"\(id)\",\"name\":\"Legacy\",\"command\":\"echo {{literal}}\"}]"
    try Data(legacy.utf8).write(to: url)
    let store = SnippetStore(fileURL: url)
    let old = try XCTUnwrap(store.all().first)
    XCTAssertEqual(old.kind, .command)
    XCTAssertEqual(old.group, "")
    XCTAssertEqual(try old.insertionCommand(), "echo {{literal}}")
    XCTAssertFalse(old.needsPreview)
    let script = try store.save(id: id, name: "Script", command: "echo {{host}}\r\npwd\r",
      group: "  部署  ", kind: .script, usesParameters: true)
    XCTAssertEqual(script.command, "echo {{host}}\npwd\n")
    XCTAssertEqual(script.group, "部署")
    XCTAssertEqual(try SnippetStore(fileURL: url).all(), [script])
    let edited = try store.save(id: id, name: "Renamed", command: "echo {{host}}\nls")
    XCTAssertEqual(edited.group, "部署")
    XCTAssertEqual(edited.kind, .script)
    XCTAssertTrue(edited.usesParameters)
  }

  func test_template_parameters_preserve_order_reuse_values_and_support_literal_braces() throws {
    let item = Snippet(name: "Template", command: #"printf '%s' '{{b}} {{_a1}} {{b}} \{{literal}}'"#, usesParameters: true)
    XCTAssertTrue(item.isValid)
    XCTAssertEqual(item.parameterNames, ["b", "_a1"])
    XCTAssertEqual(try item.resolvedCommand(parameters: ["b": "你好", "_a1": "'$(echo raw)'", "extra": "ignored"]),
      "printf '%s' '你好 '$(echo raw)' 你好 {{literal}}'")
    XCTAssertThrowsError(try item.resolvedCommand(parameters: ["b": "x"])) {
      XCTAssertEqual($0 as? SnippetError, .missingParameter("_a1"))
    }
  }

  func test_invalid_templates_and_parameter_limits_reject_without_saving_values() throws {
    for command in ["echo {{", "echo {{}}", "echo {{1bad}}", "echo {{a-b}}", "echo {{ name }}",
                    "echo {{名字}}", "echo {{" + String(repeating: "a", count: 65) + "}}",
                    #"echo \{{literal}}"#, "echo " + (0..<33).map { "{{v\($0)}}" }.joined(separator: " ")] {
      XCTAssertFalse(Snippet(name: "Bad", command: command, usesParameters: true).isValid, command)
    }
    let store = SnippetStore(fileURL: makeURL())
    let item = try store.save(name: "Template", command: "echo {{value}}", usesParameters: true)
    for value in ["a\nb", "a\rb", "\u{1b}[31m", "a\tb", "a\u{2028}b", String(repeating: "x", count: 4097)] {
      XCTAssertThrowsError(try item.insertionCommand(parameters: ["value": value])) {
        XCTAssertEqual($0 as? SnippetError, .invalidParameter("value"))
      }
    }
    XCTAssertEqual(try item.insertionCommand(parameters: ["value": "本次参数"]), "echo 本次参数")
    XCTAssertEqual(try store.all(), [item], "invocation values cannot mutate the stored template")
    XCTAssertEqual(try item.insertionCommand(parameters: ["value": ""]), "echo ")
    XCTAssertThrowsError(try Snippet(name: "Empty", command: "{{value}}", usesParameters: true)
      .insertionCommand(parameters: ["value": ""]))
  }

  func test_script_rejects_terminal_controls_and_enforces_size_boundaries() throws {
    let store = SnippetStore(fileURL: makeURL())
    for command in ["echo \u{0}", "echo \u{1b}", "echo \u{7}", "echo \u{2028}", "echo \u{7f}", String(repeating: "x", count: 65537)] {
      XCTAssertThrowsError(try store.save(name: "Script", command: command, kind: .script))
    }
    XCTAssertTrue(try store.save(name: "Max", command: String(repeating: "x", count: 65536), kind: .script).isValid)
    XCTAssertThrowsError(try store.save(name: "Bad group", command: "pwd", group: "a\nb"))
    let template = Snippet(name: "Expanded", command: String(repeating: "{{x}}", count: 100), usesParameters: true)
    XCTAssertThrowsError(try template.insertionCommand(parameters: ["x": String(repeating: "x", count: 4096)]))
  }

  func test_stale_edit_rejects_metadata_changes_without_overwriting_other_window() throws {
    let url = makeURL(), a = SnippetStore(fileURL: url), b = SnippetStore(fileURL: url)
    let original = try a.save(name: "Script", command: "echo {{host}}\npwd", group: "A", kind: .script, usesParameters: true)
    let changed = try b.save(id: original.id, name: original.name, command: original.command, group: "B")
    XCTAssertThrowsError(try a.save(id: original.id, name: "Draft", command: "echo {{host}}\nls", expected: original)) {
      XCTAssertEqual($0 as? SnippetError, .changedElsewhere)
    }
    XCTAssertEqual(try a.all(), [changed])
  }

  func test_script_wrapper_round_trips_quotes_unicode_backslashes_and_heredocs_in_posix_shells() throws {
    let script = #"""
    printf '%s\n' "中文 'quoted'" 'backslash\c\n' '$(literal)' '`literal`'
    cat <<'END'
    {{literal}} $HOME "double" 'single'
    END
    """#
    let command = try Snippet(name: "Script", command: script, kind: .script).insertionCommand()
    XCTAssertNil(command.rangeOfCharacter(from: .controlCharacters.union(.newlines)))
    for shell in ["/bin/sh", "/bin/bash", "/bin/zsh"] {
      let process = Process(), pipe = Pipe()
      process.executableURL = URL(fileURLWithPath: shell); process.arguments = ["-c", command]
      process.standardOutput = pipe; process.standardError = pipe
      try process.run()
      let output = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      XCTAssertEqual(process.terminationStatus, 0, shell)
      XCTAssertEqual(String(decoding: output, as: UTF8.self),
        "中文 'quoted'\nbackslash\\c\\n\n$(literal)\n`literal`\n{{literal}} $HOME \"double\" 'single'\n", shell)
    }
  }
}
