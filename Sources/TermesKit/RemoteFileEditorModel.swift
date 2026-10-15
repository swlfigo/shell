import Foundation
import Combine
import SSHCore

public struct RemoteTextDocument: Sendable {
  public enum Newlines: String, Sendable { case lf = "LF", crlf = "CRLF", cr = "CR", mixed = "混合换行" }
  public let text: String
  public let hasBOM: Bool
  public let newlines: Newlines
  public init(data: Data) throws {
    hasBOM = data.starts(with: [0xEF, 0xBB, 0xBF])
    let bytes = hasBOM ? data.dropFirst(3) : data[...]
    guard !bytes.contains(0), let decoded = String(data: bytes, encoding: .utf8) else { throw SFTPEditError.unsupportedEncoding }
    let withoutPairs = decoded.replacingOccurrences(of: "\r\n", with: "")
    if decoded.contains("\r\n"), !withoutPairs.contains("\r"), !withoutPairs.contains("\n") {
      newlines = .crlf; text = decoded.replacingOccurrences(of: "\r\n", with: "\n")
    } else if decoded.contains("\r"), !decoded.contains("\n") {
      newlines = .cr; text = decoded.replacingOccurrences(of: "\r", with: "\n")
    } else if decoded.contains("\r") { newlines = .mixed; text = decoded }
    else { newlines = .lf; text = decoded }
  }
  public func encode(_ text: String) -> Data {
    var content = text
    if newlines == .crlf || newlines == .cr {
      content = content.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        .replacingOccurrences(of: "\n", with: newlines == .crlf ? "\r\n" : "\r")
    }
    var data = hasBOM ? Data([0xEF, 0xBB, 0xBF]) : Data()
    data.append(contentsOf: content.utf8)
    return data
  }
}

@MainActor
enum RemoteEditingOperation {
  static func perform<T: Sendable>(factory: FileBrowserModel.Factory,
    _ body: @MainActor (any SFTPFileEditingSystem) async throws -> T) async throws -> T {
    let client = try await factory()
    do {
      try Task.checkCancellation()
      guard let editing = client as? any SFTPFileEditingSystem else { throw SFTPEditError.unsupportedOperation }
      let result = try await body(editing)
      await client.close()
      return result
    } catch { await client.close(); throw error }
  }
}

@MainActor
public final class RemoteFileEditorModel: ObservableObject {
  public let path: String
  @Published public var text = ""
  @Published public private(set) var isBusy = false
  @Published public private(set) var isLoaded = false
  @Published public private(set) var hasConflict = false
  @Published public private(set) var error: String?
  @Published public private(set) var status = "正在准备读取…"
  public var isDirty: Bool { isLoaded && text != baseline }
  public var format: String { document.map { "UTF-8\($0.hasBOM ? " BOM" : "") · \($0.newlines.rawValue)" } ?? "UTF-8" }
  public var canSave: Bool { isLoaded && !isBusy && isDirty }
  private let factory: FileBrowserModel.Factory
  private var document: RemoteTextDocument?
  private var snapshot: SFTPFileSnapshot?
  private var baseline = ""
  private var generation = 0
  private var task: Task<Void, Never>?

  public init(path: String, factory: @escaping FileBrowserModel.Factory) { self.path = path; self.factory = factory }

  /// The UI confirms discarding dirty text before calling this method.
  public func load() {
    guard !isBusy else { return }
    generation += 1; let gen = generation
    isBusy = true; error = nil; status = "正在读取远端文件…"
    task = Task { [weak self] in
      guard let self else { return }
      do {
        let result = try await RemoteEditingOperation.perform(factory: factory) {
          try await $0.readFile(self.path, maximumBytes: SFTPFileSnapshot.maximumEditorBytes)
        }
        try check(gen)
        let decoded = try RemoteTextDocument(data: result.data)
        document = decoded; snapshot = result; baseline = decoded.text
        text = decoded.text; isLoaded = true; hasConflict = false
        status = "已读取 · \(format)"
      } catch { guard generation == gen else { return }; self.error = error.localizedDescription; status = "读取失败，草稿已保留。" }
      guard generation == gen else { return }
      isBusy = false; task = nil
    }
  }

  public func exportData() throws -> Data {
    guard let document else { throw SFTPEditError.unsupportedEncoding }
    return document.encode(text)
  }

  /// overwriteChanged is used only after the UI explicitly confirms replacing the latest
  /// remote content. Even then, a fresh revision is read and checked before publication.
  public func save(overwriteChanged: Bool = false, completion: (@MainActor (Bool) -> Void)? = nil) {
    guard canSave, let snapshot else { completion?(false); return }
    let submitted = text
    let data: Data
    do {
      data = try exportData()
      _ = try RemoteTextDocument(data: data)
      guard data.count <= SFTPFileSnapshot.maximumEditorBytes else { throw SFTPEditError.tooLarge(SFTPFileSnapshot.maximumEditorBytes) }
    } catch { self.error = error.localizedDescription; completion?(false); return }
    generation += 1; let gen = generation
    error = nil; isBusy = true; status = "正在保存到远端…"
    task = Task { [weak self] in
      guard let self else { completion?(false); return }
      var success = false
      do {
        let updated = try await RemoteEditingOperation.perform(factory: factory) { fs in
          let expected = overwriteChanged ? try await fs.readFile(self.path, maximumBytes: SFTPFileSnapshot.maximumEditorBytes) : snapshot
          return try await fs.writeFile(data, to: self.path, expected: expected, progress: { _ in })
        }
        try check(gen)
        self.snapshot = updated; baseline = submitted; hasConflict = false
        status = "已保存到远端 · \(format)"; success = true
      } catch {
        guard generation == gen else { completion?(false); return }
        self.error = error.localizedDescription
        if case SFTPEditError.conflict = error { hasConflict = true }
        status = "保存失败，草稿已保留。"
      }
      guard generation == gen else { completion?(false); return }
      isBusy = false; task = nil; completion?(success)
    }
  }

  private func check(_ gen: Int) throws { try Task.checkCancellation(); guard generation == gen else { throw CancellationError() } }
  public func cancel() {
    generation += 1; task?.cancel(); task = nil; isBusy = false
    status = "操作已停止，草稿已保留；取消保存后请重新读取确认远端结果。"
  }
}
