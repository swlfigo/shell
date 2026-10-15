import Foundation
import Combine

public struct LocalFileEntry: Equatable, Sendable, Identifiable {
  public enum Kind: Sendable { case file, directory, symbolicLink, other }
  public let url: URL
  public let kind: Kind
  public let size: UInt64?
  public var name: String { url.lastPathComponent }
  public var id: URL { url }
}

public enum UploadSelectionError: Error, LocalizedError {
  case empty, unsupported(String), duplicateName(String)
  public var errorDescription: String? {
    switch self {
    case .empty: return "请选择要上传的文件。"
    case .unsupported(let name): return "无法上传 \(name)：支持普通文件和文件夹，符号链接及特殊文件不能上传。"
    case .duplicateName(let name): return "所选文件中有重复名称 \(name)，请分开上传到不同目录。"
    }
  }
}

public enum UploadSelection {
  /// Validate the top-level selection before starting: never silently omit an item or replace
  /// one selected file with a different file bearing the same basename.
  public static func validated(_ urls: [URL]) throws -> [URL] {
    guard !urls.isEmpty else { throw UploadSelectionError.empty }
    var names = Set<String>(), seen = Set<URL>(), result: [URL] = []
    for url in urls {
      guard url.isFileURL else { throw UploadSelectionError.unsupported(url.lastPathComponent) }
      let url = url.standardizedFileURL
      if !seen.insert(url).inserted { continue }
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      let kind = attributes[.type] as? FileAttributeType
      guard kind == .typeRegular || kind == .typeDirectory else {
        throw UploadSelectionError.unsupported(url.lastPathComponent)
      }
      guard names.insert(url.lastPathComponent).inserted else { throw UploadSelectionError.duplicateName(url.lastPathComponent) }
      result.append(url)
    }
    return result
  }
}

@MainActor
public final class LocalFileBrowserModel: ObservableObject {
  @Published public private(set) var directory: URL?
  @Published public private(set) var entries: [LocalFileEntry] = []
  @Published public private(set) var isBusy = false
  @Published public private(set) var error: String?
  private let initialDirectory: URL
  private var task: Task<Void, Never>?
  private var generation = 0

  public init(initialDirectory: URL? = nil) {
    #if os(macOS)
    self.initialDirectory = initialDirectory ?? FileManager.default.homeDirectoryForCurrentUser
    #else
    self.initialDirectory = initialDirectory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    #endif
  }

  public func navigate(path: String) {
    guard !path.isEmpty, !path.contains("\0") else { error = "本机目录路径无效。"; return }
    let expanded = (path as NSString).expandingTildeInPath
    let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) :
      (directory ?? initialDirectory).appendingPathComponent(expanded)
    navigate(url)
  }

  public func navigate(_ url: URL) {
    guard url.isFileURL else { error = "请选择本机目录。"; return }
    generation += 1
    let gen = generation
    task?.cancel()
    isBusy = true; error = nil
    task = Task { [weak self] in
      let worker = Task.detached(priority: .userInitiated) { try Self.read(url) }
      do {
        let (directory, entries) = try await withTaskCancellationHandler {
          try await worker.value
        } onCancel: { worker.cancel() }
        guard let self, gen == self.generation, !Task.isCancelled else { return }
        self.directory = directory; self.entries = entries
      } catch {
        guard let self, gen == self.generation, !Task.isCancelled else { return }
        self.error = error.localizedDescription
      }
      guard let self, gen == self.generation else { return }
      self.isBusy = false; self.task = nil
    }
  }

  public func refresh() { navigate(directory ?? initialDirectory) }
  public func goUp() { if let directory { navigate(directory.deletingLastPathComponent()) } }
  public func shutdown() { generation += 1; task?.cancel(); task = nil; isBusy = false }

  nonisolated private static func read(_ url: URL) throws -> (URL, [LocalFileEntry]) {
    try Task.checkCancellation()
    let directory = url.standardizedFileURL.resolvingSymlinksInPath()
    let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    var entries: [LocalFileEntry] = []
    for url in urls {
      try Task.checkCancellation()
      // A file can disappear during enumeration; leave other rows usable.
      guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { continue }
      let kind: LocalFileEntry.Kind
      switch attributes[.type] as? FileAttributeType {
      case .typeDirectory: kind = .directory
      case .typeRegular: kind = .file
      case .typeSymbolicLink: kind = .symbolicLink
      default: kind = .other
      }
      entries.append(.init(url: url, kind: kind, size: (attributes[.size] as? NSNumber)?.uint64Value))
    }
    entries.sort {
      if ($0.kind == .directory) != ($1.kind == .directory) { return $0.kind == .directory }
      return $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
    return (directory, entries)
  }
}
