import Foundation
import Darwin

public enum SFTPDirectoryError: Error, Equatable, Sendable, LocalizedError {
  case unsupportedEntry(String), duplicateName(String), treeTooLarge, sourceChanged(String)

  public var errorDescription: String? {
    switch self {
    case .unsupportedEntry(let path): return "文件夹传输不支持符号链接或特殊文件：\(path)"
    case .duplicateName(let name): return "传输选择中有重复名称：\(name)"
    case .treeTooLarge: return "目录树超过传输限制（最多 128 层、100000 项）。请分批传输。"
    case .sourceChanged(let path): return "扫描后来源发生变化，请重新传输：\(path)"
    }
  }
}

/// An immutable, fully validated upload selection. Scanning performs no remote writes.
public struct SFTPUploadItem: Sendable {
  public let source: URL
  public let isDirectory: Bool
  private let nodes: [LocalTransferNode]
  fileprivate init(source: URL, nodes: [LocalTransferNode]) {
    self.source = source; self.nodes = nodes; isDirectory = nodes[0].isDirectory
  }
  var contents: [LocalTransferNode] { nodes }
  public func validateSource() throws {
    for node in nodes { try SFTPDirectoryTransfer.validateLocal(node, root: source) }
  }
}

struct LocalTransferNode: Sendable {
  let components: [String]
  let isDirectory: Bool
  let size: UInt64
  let modifiedAt: Date?
  let inode: UInt64?
}

private struct RemoteTransferNode: Sendable {
  let components: [String]
  let entry: SFTPEntry
}

/// Folders commit as a whole. Existing destinations are never merged or replaced.
public enum SFTPDirectoryTransfer {
  private static let maximumDepth = 128
  private static let maximumEntries = 100_000

  /// Run on a worker task for large selections. Reject the entire selection before upload.
  public static func prepareUploads(_ urls: [URL]) throws -> [SFTPUploadItem] {
    guard !urls.isEmpty else { throw SFTPError.invalidPath }
    var result: [SFTPUploadItem] = [], seen = Set<URL>(), names = Set<String>(), count = 0
    for url in urls {
      try Task.checkCancellation()
      guard url.isFileURL else { throw SFTPError.invalidPath }
      let url = url.standardizedFileURL
      guard seen.insert(url).inserted else { continue }
      _ = try RemotePath.child(url.lastPathComponent, in: "/")
      guard names.insert(url.lastPathComponent).inserted else { throw SFTPDirectoryError.duplicateName(url.lastPathComponent) }
      // Resolve the containing directory, while keeping the selected root itself unfollowed.
      let root = url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent)
      var nodes: [LocalTransferNode] = []
      var pending: [[String]] = [[]]
      while let components = pending.popLast() {
        try Task.checkCancellation()
        count += 1
        guard count <= maximumEntries, components.count <= maximumDepth else { throw SFTPDirectoryError.treeTooLarge }
        let path = localPath(root, components)
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        let kind = attrs[.type] as? FileAttributeType
        guard kind == .typeRegular || kind == .typeDirectory else { throw SFTPDirectoryError.unsupportedEntry(path.path) }
        let node = LocalTransferNode(components: components, isDirectory: kind == .typeDirectory,
          size: (attrs[.size] as? NSNumber)?.uint64Value ?? 0, modifiedAt: attrs[.modificationDate] as? Date,
          inode: (attrs[.systemFileNumber] as? NSNumber)?.uint64Value)
        nodes.append(node)
        if node.isDirectory {
          let children = try FileManager.default.contentsOfDirectory(atPath: path.path).sorted()
          for name in children.reversed() {
            _ = try RemotePath.child(name, in: "/")
            pending.append(components + [name])
          }
          guard count + pending.count <= maximumEntries else { throw SFTPDirectoryError.treeTooLarge }
        }
      }
      result.append(SFTPUploadItem(source: root, nodes: nodes))
    }
    return result
  }

  public static func upload(_ item: SFTPUploadItem, to destination: String, using client: any SFTPFileSystem,
                            overwrite: Bool = false, progress: @escaping SFTPProgressHandler = { _ in }) async throws {
    try RemotePath.validate(destination)
    _ = try RemotePath.child(RemotePath.name(destination), in: RemotePath.parent(destination))
    if !item.isDirectory {
      try validateLocal(item.contents[0], root: item.source)
      try await client.upload(item.source, to: destination, overwrite: overwrite, progress: progress)
      return
    }
    if let native = client as? SFTPClient {
      try await native.uploadDirectory(item, to: destination, progress: progress)
      return
    }
    try Task.checkCancellation()
    let parent = RemotePath.parent(destination)
    guard !(try await client.listDirectory(parent)).contains(where: { $0.name == RemotePath.name(destination) }) else {
      throw SFTPError.alreadyExists(destination)
    }
    let temporary = try RemotePath.child(".termes-upload-\(UUID().uuidString).part", in: parent)
    var created: [SFTPEntry] = []
    let total = try sumSizes(item.contents.filter { !$0.isDirectory }.map(\.size))
    var completed: UInt64 = 0
    progress(.init(completed: 0, total: total))
    do {
      for node in item.contents {
        try Task.checkCancellation()
        try validateLocal(node, root: item.source)
        let path = try remotePath(temporary, node.components)
        if node.isDirectory {
          try await client.createDirectory(path)
          created.append(.init(path: path, name: RemotePath.name(path), kind: .directory))
        } else {
          let base = completed
          try await client.upload(localPath(item.source, node.components), to: path, overwrite: false) { value in
            progress(.init(completed: base + min(value.completed, node.size), total: total))
          }
          created.append(.init(path: path, name: RemotePath.name(path), kind: .file))
          try validateLocal(node, root: item.source)
          completed += node.size
        }
      }
      try Task.checkCancellation()
      try await client.rename(temporary, to: destination)
      progress(.init(completed: total, total: total))
    } catch {
      // Cleanup must run outside the cancelled task. The owner waits before closing the client.
      let cleanup = created.reversed().map { $0 }
      await Task.detached {
        let deadline = Date().addingTimeInterval(5)
        for entry in cleanup {
          guard Date() < deadline else { break }
          try? await client.remove(entry)
        }
      }.value
      throw error
    }
  }

  public static func download(_ directory: SFTPEntry, to destination: URL, using client: any SFTPFileSystem,
                              progress: @escaping SFTPProgressHandler = { _ in }) async throws {
    guard directory.kind == .directory, destination.isFileURL else { throw SFTPError.unsupportedFile }
    _ = try RemotePath.child(destination.lastPathComponent, in: "/")
    _ = try RemotePath.child(directory.name, in: "/")
    guard directory.path == (try RemotePath.child(directory.name, in: RemotePath.parent(directory.path))) else {
      throw SFTPError.invalidPath
    }
    // LSTAT semantics via directory entries: reject a directory replaced by a link.
    try await validateRemoteDirectory(directory.path, using: client)
    let target = destination.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(destination.lastPathComponent)
    guard !localExists(target) else { throw SFTPError.alreadyExists(target.path) }
    var nodes: [RemoteTransferNode] = [], pending: [(String, [String])] = [(directory.path, [])]
    while let (path, components) = pending.popLast() {
      try Task.checkCancellation()
      guard components.count <= maximumDepth else { throw SFTPDirectoryError.treeTooLarge }
      try await validateRemoteDirectory(path, using: client)
      let children = try await client.listDirectory(path)
      var names = Set<String>()
      for entry in children {
        let child = try RemotePath.child(entry.name, in: path)
        guard child == entry.path else { throw SFTPError.invalidPath }
        guard names.insert(entry.name).inserted else { throw SFTPDirectoryError.duplicateName(entry.name) }
        guard entry.kind == .directory || entry.kind == .file else { throw SFTPDirectoryError.unsupportedEntry(entry.path) }
        let relative = components + [entry.name]
        guard relative.count <= maximumDepth, nodes.count < maximumEntries else { throw SFTPDirectoryError.treeTooLarge }
        nodes.append(.init(components: relative, entry: entry))
        if entry.kind == .directory { pending.append((child, relative)) }
      }
    }
    let files = nodes.filter { $0.entry.kind == .file }
    let total = files.allSatisfy { $0.entry.size != nil } ? try sumSizes(files.compactMap { $0.entry.size }) : nil
    let temporary = target.deletingLastPathComponent().appendingPathComponent(".termes-download-\(UUID().uuidString).part", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: temporary) }
    var completed: UInt64 = 0
    progress(.init(completed: 0, total: total))
    for node in nodes.sorted(by: { $0.components.count < $1.components.count }) {
      try Task.checkCancellation()
      let url = localPath(temporary, node.components)
      if node.entry.kind == .directory {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      } else {
        try await validateRemoteDirectory(RemotePath.parent(node.entry.path), using: client)
        let current = try await client.listDirectory(RemotePath.parent(node.entry.path)).first { $0.name == node.entry.name }
        guard current == node.entry else { throw SFTPDirectoryError.sourceChanged(node.entry.path) }
        let base = completed
        try await client.download(node.entry.path, to: url, overwrite: false) { value in
          progress(.init(completed: base + value.completed, total: total))
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        if let size = node.entry.size, bytes != size { throw SFTPError.fileChanged }
        completed = try sumSizes([completed, bytes])
      }
    }
    try Task.checkCancellation()
    // RENAME_EXCL makes a late target collision fail without replacing an empty directory.
    guard Darwin.renamex_np(temporary.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
      if errno == EEXIST { throw SFTPError.alreadyExists(target.path) }
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    progress(.init(completed: completed, total: completed))
  }

  private static func validateRemoteDirectory(_ path: String, using client: any SFTPFileSystem) async throws {
    guard (try await client.listDirectory(RemotePath.parent(path))).first(where: { $0.name == RemotePath.name(path) })?.kind == .directory,
          try await client.canonicalPath(path) == path else { throw SFTPDirectoryError.sourceChanged(path) }
  }

  static func validateLocal(_ node: LocalTransferNode, root: URL) throws {
    for depth in 0..<node.components.count {
      let ancestor = localPath(root, Array(node.components.prefix(depth)))
      let attrs = try FileManager.default.attributesOfItem(atPath: ancestor.path)
      guard attrs[.type] as? FileAttributeType == .typeDirectory else { throw SFTPDirectoryError.sourceChanged(ancestor.path) }
    }
    let url = localPath(root, node.components)
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    guard attrs[.type] as? FileAttributeType == (node.isDirectory ? .typeDirectory : .typeRegular),
          (attrs[.systemFileNumber] as? NSNumber)?.uint64Value == node.inode,
          node.isDirectory || ((attrs[.size] as? NSNumber)?.uint64Value == node.size && attrs[.modificationDate] as? Date == node.modifiedAt) else {
      throw SFTPDirectoryError.sourceChanged(url.path)
    }
  }

  static func localPath(_ root: URL, _ components: [String]) -> URL {
    components.reduce(root) { $0.appendingPathComponent($1) }
  }
  static func remotePath(_ root: String, _ components: [String]) throws -> String {
    try components.reduce(root) { try RemotePath.child($1, in: $0) }
  }
  private static func localExists(_ url: URL) -> Bool {
    // attributesOfItem sees dangling symlinks too; fileExists would silently miss them.
    (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
  }
  static func sumSizes(_ sizes: [UInt64]) throws -> UInt64 {
    try sizes.reduce(0) {
      let (sum, overflow) = $0.addingReportingOverflow($1)
      guard !overflow else { throw SFTPDirectoryError.treeTooLarge }
      return sum
    }
  }
}
