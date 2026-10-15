import Foundation

public enum SFTPError: Error, Equatable, Sendable, LocalizedError {
  case invalidPath, unsupportedFile, alreadyExists(String), notConnected, fileChanged
  case operation(String, code: UInt)

  public var errorDescription: String? {
    switch self {
    case .invalidPath: return "文件名或路径无效。文件名不能为 .、.. 或包含 /。"
    case .unsupportedFile: return "此操作需要普通文件。目录请选择文件夹传输。"
    case .alreadyExists(let path): return "目标已存在：\(path)"
    case .notConnected: return "文件连接已关闭，请重新连接或刷新。"
    case .fileChanged: return "传输时文件大小发生变化，请刷新后重试。"
    case .operation(let message, let code): return "SFTP：\(message)（状态 \(code)）"
    }
  }
}

public enum RemotePath {
  public static func validate(_ path: String) throws {
    guard !path.isEmpty, !path.contains("\0"), path.utf8.count < 32_768 else { throw SFTPError.invalidPath }
  }
  public static func child(_ name: String, in directory: String) throws -> String {
    try validate(directory)
    guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
      throw SFTPError.invalidPath
    }
    let result = directory.hasSuffix("/") ? directory + name : directory + "/" + name
    try validate(result)
    return result
  }
  public static func parent(_ path: String) -> String {
    let parts = path.split(separator: "/").dropLast().joined(separator: "/")
    if path.hasPrefix("/") { return parts.isEmpty ? "/" : "/" + parts }
    return parts.isEmpty ? "." : parts
  }
  public static func name(_ path: String) -> String { path.split(separator: "/").last.map(String.init) ?? "" }
}

public struct SFTPEntry: Equatable, Sendable, Identifiable {
  public enum Kind: String, Sendable { case file, directory, symbolicLink, other }
  public let path: String
  public let name: String
  public let kind: Kind
  public let size: UInt64?
  public let modifiedAt: Date?
  public let permissions: UInt32?
  public let ownerID: UInt32?
  public let groupID: UInt32?
  public var id: String { path }
  public init(path: String, name: String, kind: Kind, size: UInt64? = nil, modifiedAt: Date? = nil,
              permissions: UInt32? = nil, ownerID: UInt32? = nil, groupID: UInt32? = nil) {
    self.path = path; self.name = name; self.kind = kind; self.size = size; self.modifiedAt = modifiedAt
    self.permissions = permissions; self.ownerID = ownerID; self.groupID = groupID
  }
}

public struct SFTPProgress: Equatable, Sendable {
  public let completed: UInt64
  public let total: UInt64?
  public init(completed: UInt64, total: UInt64?) { self.completed = completed; self.total = total }
}

public typealias SFTPProgressHandler = @Sendable (SFTPProgress) -> Void

public protocol SFTPFileSystem: AnyObject, Sendable {
  func canonicalPath(_ path: String) async throws -> String
  func listDirectory(_ path: String) async throws -> [SFTPEntry]
  func createDirectory(_ path: String) async throws
  func rename(_ source: String, to destination: String) async throws
  func remove(_ entry: SFTPEntry) async throws
  func upload(_ localURL: URL, to remotePath: String, overwrite: Bool, progress: @escaping SFTPProgressHandler) async throws
  func download(_ remotePath: String, to localURL: URL, overwrite: Bool, progress: @escaping SFTPProgressHandler) async throws
  func close() async
}
