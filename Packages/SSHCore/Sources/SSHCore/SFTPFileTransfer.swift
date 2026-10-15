import Foundation

public enum SFTPResumeError: Error, Equatable, Sendable, LocalizedError {
  case sourceChanged, partialChanged, alreadyRunning, finished
  public var errorDescription: String? {
    switch self {
    case .sourceChanged: return "源文件已变化，无法续传。请取消此任务后重新添加。"
    case .partialChanged: return "临时文件已变化，无法安全续传。请取消此任务后重新添加。"
    case .alreadyRunning: return "此传输正在运行。"
    case .finished: return "此传输已结束。"
    }
  }
}

/// An in-memory checkpoint, reused with a fresh connection after pause or network failure.
/// Cancellation of transfer() preserves the partial file; discard() explicitly removes it.
public final class SFTPFileTransfer: @unchecked Sendable, Identifiable {
  public enum Direction: Sendable { case upload, download }
  public let id = UUID()
  public let direction: Direction
  public let localURL: URL
  public let remotePath: String
  public let overwrite: Bool
  public var remoteTemporaryPath: String {
    let parent = RemotePath.parent(remotePath)
    return (parent.hasSuffix("/") ? parent : parent + "/") + ".termes-upload-\(id.uuidString).part"
  }
  public var localTemporaryURL: URL {
    localURL.deletingLastPathComponent().appendingPathComponent(".termes-download-\(id.uuidString).part")
  }
  struct State: Sendable {
    var sourceDigest: Data?
    var sourceSize: UInt64?
    var sourceModified: Date?
    var sourceInode: UInt64?
    var remoteSource: SFTPEntry?
    var remotePartialCreated = false
    var localPartialInode: UInt64?
    var finished = false
  }
  private let lock = NSLock()
  private var stored = State()
  private var running = false
  var state: State {
    get { lock.withLock { stored } }
    set { lock.withLock { stored = newValue } }
  }
  func begin() throws {
    try lock.withLock {
      guard !running else { throw SFTPResumeError.alreadyRunning }
      guard !stored.finished else { throw SFTPResumeError.finished }
      running = true
    }
  }
  func end() { lock.withLock { running = false } }

  public init(direction: Direction, localURL: URL, remotePath: String, overwrite: Bool = false) throws {
    try RemotePath.validate(remotePath)
    guard localURL.isFileURL, !localURL.lastPathComponent.isEmpty else { throw SFTPError.invalidPath }
    self.direction = direction
    self.localURL = localURL.deletingLastPathComponent().resolvingSymlinksInPath()
      .appendingPathComponent(localURL.lastPathComponent)
    self.remotePath = remotePath
    self.overwrite = overwrite
  }

  /// Downloads can be discarded even while SSH is disconnected.
  public func discardLocalPartial() throws {
    guard direction == .download, !state.finished else { return }
    try begin(); defer { end() }
    let url = localTemporaryURL
    if let expected = state.localPartialInode,
       let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
      guard attrs[.type] as? FileAttributeType == .typeRegular,
            (attrs[.systemFileNumber] as? NSNumber)?.uint64Value == expected else { throw SFTPResumeError.partialChanged }
      try FileManager.default.removeItem(at: url)
    }
    var current = state; current.finished = true; state = current
  }
}

public protocol SFTPResumableFileSystem: SFTPFileSystem {
  func transfer(_ transfer: SFTPFileTransfer, progress: @escaping SFTPProgressHandler) async throws
  func discard(_ transfer: SFTPFileTransfer) async throws
}
