import Foundation
import Combine

public struct Snippet: Codable, Identifiable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable { case command, script }
  public let id: UUID
  public var name: String
  public var command: String
  public var group: String
  public var kind: Kind
  public var usesParameters: Bool

  public init(id: UUID = UUID(), name: String, command: String, group: String = "",
              kind: Kind = .command, usesParameters: Bool = false) {
    self.id = id; self.name = name; self.command = command
    self.group = group; self.kind = kind; self.usesParameters = usesParameters
  }
  private enum CodingKeys: String, CodingKey { case id, name, command, group, kind, usesParameters }
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    name = try values.decode(String.self, forKey: .name)
    command = try values.decode(String.self, forKey: .command)
    group = try values.decodeIfPresent(String.self, forKey: .group) ?? ""
    kind = try values.decodeIfPresent(Kind.self, forKey: .kind) ?? .command
    usesParameters = try values.decodeIfPresent(Bool.self, forKey: .usesParameters) ?? false
  }

  public var isValid: Bool {
    let forbidden = CharacterSet.controlCharacters.union(.newlines)
    var allowed = forbidden
    if kind == .script { allowed.remove(charactersIn: "\n\t") }
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          name.utf8.count <= 4096, group.utf8.count <= 4096, command.utf8.count <= 65536,
          name.rangeOfCharacter(from: forbidden) == nil, group.rangeOfCharacter(from: forbidden) == nil,
          command.rangeOfCharacter(from: allowed) == nil else { return false }
    if usesParameters {
      guard let tokens = try? SnippetTemplate.parse(command), !tokens.names.isEmpty else { return false }
    }
    return true
  }
  public var parameterNames: [String] {
    usesParameters ? ((try? SnippetTemplate.parse(command).names) ?? []) : []
  }
  public var needsPreview: Bool { kind == .script || usesParameters }

  /// Values are substituted verbatim; the invocation UI always previews the resolved text.
  public func resolvedCommand(parameters: [String: String] = [:]) throws -> String {
    guard isValid else { throw SnippetError.invalidSnippet }
    guard usesParameters else { return command }
    let template = try SnippetTemplate.parse(command)
    for name in template.names {
      guard let value = parameters[name] else { throw SnippetError.missingParameter(name) }
      guard value.utf8.count <= 4096, value.rangeOfCharacter(from: .controlCharacters.union(.newlines)) == nil else {
        throw SnippetError.invalidParameter(name)
      }
    }
    let resolved = template.tokens.map { token in
      switch token {
      case .literal(let text): return text
      case .parameter(let name): return parameters[name]!
      }
    }.joined()
    guard resolved.utf8.count <= 262144,
          !resolved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SnippetError.invalidSnippet }
    return resolved
  }

  /// A script is encoded as one POSIX shell command with no input newline, so inserting it
  /// cannot submit any part of the script before the user presses Enter.
  public func insertionCommand(parameters: [String: String] = [:]) throws -> String {
    let command = try resolvedCommand(parameters: parameters)
    guard kind == .script else { return command }
    let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t")
      .replacingOccurrences(of: "'", with: "'\"'\"'")
    return "eval \"$(printf '%b' '\(escaped)')\""
  }
}

private struct SnippetTemplate {
  enum Token { case literal(String), parameter(String) }
  let tokens: [Token]
  let names: [String]
  static func parse(_ command: String) throws -> SnippetTemplate {
    var tokens: [Token] = [], names: [String] = [], seen = Set<String>(), literal = ""
    var index = command.startIndex
    while index < command.endIndex {
      let tail = command[index...]
      if tail.hasPrefix("\\{{") {
        literal += "{{"
        index = command.index(index, offsetBy: 3)
      } else if tail.hasPrefix("{{") {
        let start = command.index(index, offsetBy: 2)
        guard let end = command[start...].range(of: "}}") else { throw SnippetError.invalidTemplate }
        let name = String(command[start..<end.lowerBound])
        let bytes = Array(name.utf8)
        guard !bytes.isEmpty, bytes.count <= 64,
              bytes[0] == 95 || (65...90).contains(bytes[0]) || (97...122).contains(bytes[0]),
              bytes.allSatisfy({ $0 == 95 || (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) }) else {
          throw SnippetError.invalidTemplate
        }
        if !literal.isEmpty { tokens.append(.literal(literal)); literal = "" }
        tokens.append(.parameter(name))
        if seen.insert(name).inserted { names.append(name) }
        guard names.count <= 32 else { throw SnippetError.invalidTemplate }
        index = end.upperBound
      } else {
        literal.append(command[index]); index = command.index(after: index)
      }
    }
    if !literal.isEmpty { tokens.append(.literal(literal)) }
    return .init(tokens: tokens, names: names)
  }
}

public enum SnippetError: Error, Equatable, LocalizedError {
  case invalidSnippet, notFound, invalidFile, invalidTemplate, changedElsewhere
  case missingParameter(String), invalidParameter(String)

  public var errorDescription: String? {
    switch self {
    case .invalidSnippet: return "名称和内容不能为空，不能包含终端控制字符；单行命令不能换行，脚本限 64 KiB，参数模板需包含有效参数。"
    case .notFound: return "该常用命令已被删除，请重新选择或新建。"
    case .invalidFile: return "常用命令文件包含无效或重复记录，请检查 snippets.json。"
    case .invalidTemplate: return "参数格式为 {{name}}，名称使用英文字母、数字和下划线且不能以数字开头，最多 32 个参数。"
    case .changedElsewhere: return "该常用命令已在其他窗口修改，请重新选择后再保存；草稿已保留。"
    case .missingParameter(let name): return "请填写参数「\(name)」。"
    case .invalidParameter(let name): return "参数「\(name)」不能包含换行或控制字符，长度不能超过 4 KiB。"
    }
  }
}

/// Shared on the main actor by all windows. Each mutation reads the latest file and writes
/// atomically before notifying observers; malformed or unreadable files are never replaced.
@MainActor
public final class SnippetStore {
  private let fileURL: URL
  public let didChange = PassthroughSubject<Void, Never>()

  public init(fileURL: URL) { self.fileURL = fileURL }

  public func all() throws -> [Snippet] {
    let data: Data
    do { data = try Data(contentsOf: fileURL) }
    catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
      return []
    }
    let items = try JSONDecoder().decode([Snippet].self, from: data)
    guard items.allSatisfy(\.isValid), Set(items.map(\.id)).count == items.count else {
      throw SnippetError.invalidFile
    }
    return items
  }

  @discardableResult
  public func save(id: UUID? = nil, name: String, command: String, group: String? = nil,
                   kind: Snippet.Kind? = nil, usesParameters: Bool? = nil, expected: Snippet? = nil) throws -> Snippet {
    var items = try all()
    let previous = id.flatMap { id in items.first { $0.id == id } }
    if id != nil, previous == nil { throw SnippetError.notFound }
    if let expected, previous != expected { throw SnippetError.changedElsewhere }
    let resolvedKind = kind ?? previous?.kind ?? .command
    let text = resolvedKind == .script
      ? command.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") : command
    let snippet = Snippet(id: id ?? UUID(), name: name.trimmingCharacters(in: .whitespaces), command: text,
      group: (group ?? previous?.group ?? "").trimmingCharacters(in: .whitespaces), kind: resolvedKind,
      usesParameters: usesParameters ?? previous?.usesParameters ?? false)
    guard snippet.isValid else { throw SnippetError.invalidSnippet }
    if let id, let index = items.firstIndex(where: { $0.id == id }) { items[index] = snippet }
    else { items.append(snippet) }
    try write(items)
    return snippet
  }

  public func delete(_ id: UUID) throws {
    var items = try all()
    guard let index = items.firstIndex(where: { $0.id == id }) else { throw SnippetError.notFound }
    items.remove(at: index)
    try write(items)
  }

  private func write(_ items: [Snippet]) throws {
    try JSONEncoder().encode(items).write(to: fileURL, options: .atomic)
    didChange.send()
  }
}
