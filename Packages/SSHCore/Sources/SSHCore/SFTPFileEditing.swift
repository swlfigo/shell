import Foundation

public enum SFTPEditError: Error, Equatable, Sendable, LocalizedError {
  case invalidPermissions, conflict(String), tooLarge(Int), unsupportedEncoding, missingMetadata, unsupportedOperation
  public var errorDescription: String? {
    switch self {
    case .invalidPermissions: return "权限请输入 3 或 4 位八进制数字（0–7），例如 0644。"
    case .conflict(let path): return "远端文件已变化：\(path)。草稿已保留，请重新读取或确认覆盖。"
    case .tooLarge(let size): return "内置编辑器最多支持 \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))，请下载后编辑。"
    case .unsupportedEncoding: return "内置编辑器支持 UTF-8 文本；此文件含有无效编码或二进制数据，请下载后编辑。"
    case .missingMetadata: return "服务器未提供完整权限或所有者属性，无法保留属性后保存。"
    case .unsupportedOperation: return "此文件连接不支持权限或文本编辑。"
    }
  }
}

public struct UnixPermissions: Equatable, Sendable {
  public let value: UInt32
  public init(_ value: UInt32) throws {
    guard value <= 0o7777 else { throw SFTPEditError.invalidPermissions }; self.value = value
  }
  public init(octal: String) throws {
    let text = octal.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (3...4).contains(text.utf8.count), text.utf8.allSatisfy({ (48...55).contains($0) }),
          let value = UInt32(text, radix: 8) else { throw SFTPEditError.invalidPermissions }
    try self.init(value)
  }
  public var octal: String { String(format: "%04o", value) }
  public var symbolic: String {
    let bits: [UInt32] = [0o400, 0o200, 0o100, 0o040, 0o020, 0o010, 0o004, 0o002, 0o001]
    var text = Array("rwxrwxrwx")
    for index in bits.indices where value & bits[index] == 0 { text[index] = "-" }
    if value & 0o4000 != 0 { text[2] = value & 0o100 == 0 ? "S" : "s" }
    if value & 0o2000 != 0 { text[5] = value & 0o010 == 0 ? "S" : "s" }
    if value & 0o1000 != 0 { text[8] = value & 0o001 == 0 ? "T" : "t" }
    return String(text)
  }
}

public struct SFTPFileSnapshot: Equatable, Sendable {
  public static let maximumEditorBytes = 4 * 1024 * 1024
  public let entry: SFTPEntry
  public let data: Data
  public init(entry: SFTPEntry, data: Data) { self.entry = entry; self.data = data }
}

public protocol SFTPFileEditingSystem: SFTPFileSystem {
  func fileAttributes(_ path: String) async throws -> SFTPEntry
  func setPermissions(_ path: String, permissions: UInt32, expected: SFTPEntry) async throws -> SFTPEntry
  func readFile(_ path: String, maximumBytes: Int) async throws -> SFTPFileSnapshot
  func writeFile(_ data: Data, to path: String, expected: SFTPFileSnapshot,
                 progress: @escaping SFTPProgressHandler) async throws -> SFTPFileSnapshot
}
