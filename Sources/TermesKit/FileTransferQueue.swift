import Foundation
import Combine
import SSHCore

public struct FileTransferJob: Identifiable, Equatable, Sendable {
  public enum State: String, Sendable {
    case queued, running, pausing, paused, cancelling, cancelled, completed, failed
    public var title: String {
      switch self {
      case .queued: return "等待"
      case .running: return "传输中"
      case .pausing: return "正在暂停"
      case .paused: return "已暂停"
      case .cancelling: return "正在清理"
      case .cancelled: return "已取消"
      case .completed: return "已完成"
      case .failed: return "失败"
      }
    }
    public var isActive: Bool { [.queued, .running, .pausing, .cancelling].contains(self) }
  }
  public let id: UUID
  public let name: String
  public let destination: String
  public let isUpload: Bool
  public var state: State = .queued
  public var currentName: String?
  public var completedItems = 0
  public var totalItems: Int
  public var progress: SFTPProgress?
  public var error: String?
}

/// Each submitted batch is sequential. Two independent batches can run concurrently;
/// listing and terminal connections remain independent of both transfer connections.
@MainActor
public final class FileTransferQueue: ObservableObject {
  public typealias Factory = @MainActor () async throws -> any SFTPFileSystem
  @Published public private(set) var jobs: [FileTransferJob] = []
  public var onChange: (() -> Void)?
  public var onSettled: (() -> Void)?
  public var isBusy: Bool { jobs.contains { $0.state.isActive } }
  public var isConnected = true { didSet { if isConnected { schedule() } else { pauseAll() } } }
  public let maximumConcurrentBatches: Int
  private let factory: Factory
  private enum Request {
    case upload([URL], directory: String, overwriting: Set<String>)
    case download(SFTPEntry, URL, overwrite: Bool)
    var targets: [String] {
      switch self {
      case .upload(let urls, let directory, _): return urls.compactMap { try? RemotePath.child($0.lastPathComponent, in: directory) }
      case .download(_, let url, _): return [url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).path]
      }
    }
    var isUpload: Bool { if case .upload = self { return true }; return false }
  }
  private final class Work {
    let request: Request
    var items: [SFTPUploadItem]?
    var index = 0
    var checkpoint: SFTPFileTransfer?
    var cleanupClient: SFTPClient?
    var task: Task<Void, Never>?
    var attempt = 0
    var progressSerial = 0
    init(_ request: Request) { self.request = request }
  }
  private var work: [UUID: Work] = [:]
  private var closing = false

  public init(maximumConcurrentBatches: Int = 2, factory: @escaping Factory) {
    self.maximumConcurrentBatches = max(1, min(4, maximumConcurrentBatches)); self.factory = factory
  }

  @discardableResult
  public func upload(_ urls: [URL], directory: String, overwriting: Set<String> = []) -> UUID? {
    guard isConnected, !closing, !urls.isEmpty else { return nil }
    var seen: Set<URL> = []
    let unique = urls.map(\.standardizedFileURL).filter { seen.insert($0).inserted }
    let name = unique.count == 1 ? unique[0].lastPathComponent : "\(unique.count) 项"
    return append(.upload(unique, directory: directory, overwriting: overwriting), name: name,
                  destination: directory, isUpload: true, count: unique.count)
  }

  @discardableResult
  public func download(_ entry: SFTPEntry, to url: URL, overwrite: Bool = false) -> UUID? {
    guard isConnected, !closing else { return nil }
    return append(.download(entry, url, overwrite: overwrite), name: entry.name,
                  destination: url.path, isUpload: false, count: 1)
  }

  private func append(_ request: Request, name: String, destination: String, isUpload: Bool, count: Int) -> UUID {
    let id = UUID()
    work[id] = Work(request)
    jobs.append(.init(id: id, name: name, destination: destination, isUpload: isUpload, totalItems: count))
    let conflict = jobs.dropLast().contains { job in
      guard ![.completed, .cancelled].contains(job.state), let previous = work[job.id]?.request,
            previous.isUpload == request.isUpload else { return false }
      return previous.targets.contains { old in request.targets.contains { new in
        old == new || old.hasPrefix(new + "/") || new.hasPrefix(old + "/")
      } }
    }
    if conflict {
      jobs[jobs.count - 1].state = .cancelled
      jobs[jobs.count - 1].error = "此目标已有未结束的传输，请先继续或取消原任务。"
      // Never start a duplicate by pressing retry on the rejected row.
      work.removeValue(forKey: id)
    }
    changed(); schedule(); return id
  }

  public func pause(_ id: UUID) {
    guard let row = row(id), let item = work[id] else { return }
    switch jobs[row].state {
    case .queued: jobs[row].state = .paused
    case .running: jobs[row].state = .pausing; item.task?.cancel()
    default: return
    }
    changed(); schedule()
  }
  public func pauseAll() { for id in jobs.map(\.id) { pause(id) } }

  public func resume(_ id: UUID) {
    guard isConnected, !closing, let row = row(id), work[id]?.task == nil,
          [.paused, .failed].contains(jobs[row].state) else { return }
    jobs[row].state = .queued; jobs[row].error = nil
    changed(); schedule()
  }

  public func cancel(_ id: UUID) {
    guard let row = row(id), let item = work[id], ![.cancelled, .completed, .cancelling].contains(jobs[row].state) else { return }
    jobs[row].state = .cancelling; item.task?.cancel()
    if item.task == nil { startCleanup(id, item: item) }
    changed()
  }
  public func cancelAll() { for id in jobs.map(\.id) { cancel(id) } }

  public func clearFinished() {
    let ids = Set(jobs.filter { [.completed, .cancelled].contains($0.state) }.map(\.id))
    jobs.removeAll { ids.contains($0.id) }
    for id in ids { work.removeValue(forKey: id) }
    changed()
  }

  public func shutdown() { closing = true; cancelAll() }

  private func row(_ id: UUID) -> Int? { jobs.firstIndex { $0.id == id } }
  private func changed() { onChange?() }
  private func schedule() {
    guard !closing, isConnected else { return }
    var available = maximumConcurrentBatches - work.values.filter { $0.task != nil }.count
    for job in jobs where job.state == .queued && available > 0 {
      guard let item = work[job.id], item.task == nil, let row = row(job.id) else { continue }
      jobs[row].state = .running
      item.attempt += 1
      let id = job.id
      item.task = Task { [weak self] in await self?.execute(id, item: item) }
      available -= 1
    }
    changed()
  }

  private func execute(_ id: UUID, item: Work) async {
    var client: (any SFTPFileSystem)?
    var failure: Error?
    do {
      if case .upload(let urls, _, _) = item.request, item.items == nil {
        let worker = Task.detached(priority: .userInitiated) {
          try SFTPDirectoryTransfer.prepareUploads(UploadSelection.validated(urls))
        }
        item.items = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
      }
      try Task.checkCancellation()
      let opened = try await factory(); client = opened
      item.cleanupClient = opened as? SFTPClient
      try Task.checkCancellation()
      switch item.request {
      case .upload(_, let directory, let names):
        let items = item.items ?? []
        while item.index < items.count {
          try Task.checkCancellation()
          let source = items[item.index]
          let destination = try RemotePath.child(source.source.lastPathComponent, in: directory)
          if let row = row(id) { jobs[row].currentName = source.source.lastPathComponent; jobs[row].progress = nil; changed() }
          if !source.isDirectory, let resumable = opened as? any SFTPResumableFileSystem {
            if item.checkpoint == nil {
              try source.validateSource()
              item.checkpoint = try SFTPFileTransfer(direction: .upload, localURL: source.source,
                                                     remotePath: destination, overwrite: names.contains(source.source.lastPathComponent))
            }
            try await resumable.transfer(item.checkpoint!, progress: progressHandler(id))
          } else {
            try await SFTPDirectoryTransfer.upload(source, to: destination, using: opened,
              overwrite: names.contains(source.source.lastPathComponent), progress: progressHandler(id))
          }
          // A committed item remains completed even if pause arrives at its final callback.
          item.index += 1; item.checkpoint = nil
          if let row = row(id) { jobs[row].completedItems = item.index; changed() }
        }
      case .download(let entry, let url, let overwrite):
        if let row = row(id) { jobs[row].currentName = entry.name; changed() }
        if entry.kind == .directory {
          try await SFTPDirectoryTransfer.download(entry, to: url, using: opened, progress: progressHandler(id))
        } else if entry.kind == .file, let resumable = opened as? any SFTPResumableFileSystem {
          if item.checkpoint == nil {
            item.checkpoint = try SFTPFileTransfer(direction: .download, localURL: url, remotePath: entry.path, overwrite: overwrite)
          }
          try await resumable.transfer(item.checkpoint!, progress: progressHandler(id))
        } else {
          guard entry.kind == .file || entry.kind == .symbolicLink else { throw SFTPError.unsupportedFile }
          try await opened.download(entry.path, to: url, overwrite: overwrite, progress: progressHandler(id))
        }
        item.index = 1; item.checkpoint = nil
        if let row = row(id) { jobs[row].completedItems = 1 }
      }
    } catch { failure = error }
    if item.checkpoint == nil { item.cleanupClient = nil }
    await client?.close()
    guard let row = row(id) else { item.task = nil; return }
    if jobs[row].state == .cancelling {
      // A cancelled native call closed its transport. Cleanup always uses a fresh one.
      await cleanup(id, item: item)
    } else if item.index == jobs[row].totalItems {
      jobs[row].state = .completed
    } else if jobs[row].state == .pausing || failure is CancellationError {
      jobs[row].state = .paused
    } else if let failure {
      jobs[row].state = .failed
      let current = jobs[row].currentName ?? jobs[row].name
      jobs[row].error = jobs[row].isUpload
        ? "上传 \(current) 失败（已完成 \(item.index)/\(jobs[row].totalItems)）：\(failure.localizedDescription)"
        : failure.localizedDescription
    }
    item.task = nil
    changed(); schedule()
    if !isBusy { onSettled?() }
  }

  private func startCleanup(_ id: UUID, item: Work) {
    item.task = Task { [weak self] in
      guard let self else { return }
      await cleanup(id, item: item)
      item.task = nil
      changed(); schedule()
      if !isBusy { onSettled?() }
    }
  }
  private func cleanup(_ id: UUID, item: Work) async {
    var cleanupError: String?
    if let checkpoint = item.checkpoint {
      do {
        if checkpoint.direction == .download { try checkpoint.discardLocalPartial() }
        else {
          // This task intentionally ignores the cancelled transfer's token.
          let worker = Task { @MainActor [factory, cleanupClient = item.cleanupClient] in
            if let cleanupClient { try await cleanupClient.discardUsingFreshConnection(checkpoint); return }
            let opened = try await factory()
            do {
              if let resumable = opened as? any SFTPResumableFileSystem { try await resumable.discard(checkpoint) }
              await opened.close()
            } catch { await opened.close(); throw error }
          }
          try await worker.value
        }
      } catch { cleanupError = "临时文件未清理：\(error.localizedDescription)" }
    }
    if let row = row(id) { jobs[row].state = .cancelled; jobs[row].error = cleanupError }
    item.checkpoint = nil
    item.cleanupClient = nil
  }

  private func progressHandler(_ id: UUID) -> SFTPProgressHandler {
    let throttle = FileProgressThrottle()
    let attempt = work[id]?.attempt
    work[id]?.progressSerial += 1
    let serial = work[id]?.progressSerial
    return { [weak self] progress in
      guard throttle.shouldPublish(progress) else { return }
      Task { @MainActor [weak self] in
        guard let self, let row = self.row(id), self.jobs[row].state == .running,
              self.work[id]?.attempt == attempt, self.work[id]?.progressSerial == serial else { return }
        self.jobs[row].progress = progress; self.changed()
      }
    }
  }
}
