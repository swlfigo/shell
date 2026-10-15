import Foundation
import Combine
import SSHCore

/// One pane's file browser. A generation protects against stale results from cancelled
/// requests, including servers/fakes that finish a request after cancellation.
@MainActor
public final class FileBrowserModel: ObservableObject {
  /// Must open a fresh dedicated connection on each call; transfers close their clients.
  public typealias Factory = @MainActor () async throws -> any SFTPFileSystem
  @Published public private(set) var directory: String?
  @Published public private(set) var entries: [SFTPEntry] = []
  @Published public private(set) var isBusy = false
  @Published public private(set) var isBrowsingBusy = false
  public let transfers: FileTransferQueue
  @Published public private(set) var isConnected = true
  @Published public private(set) var progress: SFTPProgress?
  @Published public private(set) var status = "打开文件面板后加载远端目录。"
  @Published public private(set) var error: String?
  private let factory: Factory
  private var client: (any SFTPFileSystem)?
  private var task: Task<Void, Never>?
  private var generation = 0
  private var needsTransferRefresh = false

  public init(factory: @escaping Factory) {
    self.factory = factory
    transfers = FileTransferQueue(factory: factory)
    transfers.onChange = { [weak self] in self?.transferChanged() }
    transfers.onSettled = { [weak self] in
      self?.needsTransferRefresh = true
      self?.refreshAfterTransfers()
    }
  }

  public func setConnected(_ connected: Bool) {
    guard connected != isConnected else { return }
    isConnected = connected
    transfers.isConnected = connected
    if !connected { cancelBrowser(); status = "SSH 未连接，传输已暂停；重连后可继续。" }
    else { navigate(directory ?? ".") }
  }

  public func navigate(_ path: String) {
    run("正在读取目录…", success: "目录已刷新") { model, client, gen in
      let canonical = try await client.canonicalPath(path)
      let entries = try await client.listDirectory(canonical)
      try model.check(gen)
      model.directory = canonical
      model.entries = entries
    }
  }

  public func refresh() { navigate(directory ?? ".") }
  public func goUp() { if let directory { navigate(RemotePath.parent(directory)) } }
  public func makeEditor(for entry: SFTPEntry) -> RemoteFileEditorModel {
    RemoteFileEditorModel(path: entry.path, factory: factory)
  }
  public func makePermissionsEditor(for entry: SFTPEntry) -> RemotePermissionsModel {
    RemotePermissionsModel(entry: entry, factory: factory)
  }

  public func createDirectory(name: String) {
    guard let directory else { return }
    mutate("正在新建目录…", success: "目录已创建", directory: directory) { client in
      try await client.createDirectory(RemotePath.child(name, in: directory))
    }
  }

  public func rename(_ entry: SFTPEntry, to name: String) {
    guard let directory else { return }
    mutate("正在重命名…", success: "重命名完成", directory: directory) { client in
      try await client.rename(entry.path, to: RemotePath.child(name, in: directory))
    }
  }

  public func remove(_ entry: SFTPEntry) {
    guard let directory else { return }
    mutate("正在删除…", success: "删除完成", directory: directory) { client in try await client.remove(entry) }
  }

  private func mutate(_ status: String, success: String, directory: String,
                      action: @escaping @MainActor (any SFTPFileSystem) async throws -> Void) {
    run(status, success: success) { model, client, gen in
      try await action(client)
      let entries = try await client.listDirectory(directory)
      try model.check(gen)
      model.entries = entries
    }
  }

  public func upload(_ url: URL, overwrite: Bool = false) {
    upload([url], overwriting: overwrite ? [url.lastPathComponent] : [])
  }

  public func upload(_ urls: [URL], overwriting names: Set<String> = []) {
    guard isConnected, !isBrowsingBusy, let directory else { return }
    _ = transfers.upload(urls, directory: directory, overwriting: names)
  }

  public func download(_ entry: SFTPEntry, to url: URL, overwrite: Bool = false) {
    guard isConnected, !isBrowsingBusy else { return }
    _ = transfers.download(entry, to: url, overwrite: overwrite)
  }

  private func transferChanged() {
    isBusy = isBrowsingBusy || transfers.isBusy
    guard !isBrowsingBusy else { return }
    let jobs = transfers.jobs
    guard let job = jobs.first(where: { $0.state.isActive }) ?? jobs.last else { return }
    progress = job.progress
    error = job.error
    switch job.state {
    case .completed: status = "\(job.isUpload ? "上传" : "下载")完成：\(job.name)"
    case .cancelled: status = "已取消"
    case .failed: status = "传输失败，可继续重试。"
    case .paused: status = "已暂停，可从传输队列继续。"
    default: status = "\(job.state.title)：\(job.currentName ?? job.name)"
    }
  }

  private func refreshAfterTransfers() {
    guard needsTransferRefresh, isConnected, !isBrowsingBusy, !transfers.isBusy,
          transfers.jobs.contains(where: { $0.state == .completed || $0.state == .failed }) else { return }
    needsTransferRefresh = false
    let message = status, transferError = error, path = directory ?? "."
    run("正在刷新目录…", success: message) { model, client, gen in
      let entries = try await client.listDirectory(path)
      try model.check(gen)
      model.entries = entries
      model.error = transferError
    }
  }

  private func check(_ gen: Int) throws {
    try Task.checkCancellation()
    guard generation == gen, isConnected else { throw CancellationError() }
  }

  private func run(_ title: String, success: String,
                   operation: @escaping @MainActor (FileBrowserModel, any SFTPFileSystem, Int) async throws -> Void) {
    guard isConnected, !isBrowsingBusy else { return }
    generation += 1
    let gen = generation
    error = nil; progress = nil; status = title; isBrowsingBusy = true; isBusy = true
    task = Task { [weak self] in
      guard let self else { return }
      do {
        let fs: any SFTPFileSystem
        if let current = self.client { fs = current }
        else {
          let opened = try await self.factory()
          do { try self.check(gen) } catch { await opened.close(); throw error }
          self.client = opened
          fs = opened
        }
        try self.check(gen)
        try await operation(self, fs, gen)
        try self.check(gen)
        self.status = success
      } catch {
        guard self.generation == gen else { return }
        if error is CancellationError { self.status = "已取消" }
        else { self.error = error.localizedDescription; self.status = "操作失败，可重试。" }
        let failed = self.client
        self.client = nil
        await failed?.close()
      }
      guard self.generation == gen else { return }
      self.isBrowsingBusy = false
      self.isBusy = self.transfers.isBusy
      self.task = nil
      if self.transfers.isBusy { self.transferChanged() }
      if self.needsTransferRefresh { self.refreshAfterTransfers() }
    }
  }

  public func cancel() {
    transfers.cancelAll()
    cancelBrowser()
  }

  private func cancelBrowser() {
    generation += 1
    let cancelled = task
    cancelled?.cancel(); task = nil
    let old = client
    client = nil
    Task { await cancelled?.value; await old?.close() }
    isBrowsingBusy = false; isBusy = transfers.isBusy; progress = nil; error = nil; status = "已取消"
  }

  public func shutdown() { transfers.shutdown(); cancelBrowser(); isConnected = false; status = "文件面板已关闭" }
}

/// Bound main-actor work for large transfers; the core still reports each written chunk.
final class FileProgressThrottle: @unchecked Sendable {
  private let lock = NSLock()
  private var last: TimeInterval = 0
  func shouldPublish(_ progress: SFTPProgress) -> Bool {
    lock.withLock {
      let now = Date.timeIntervalSinceReferenceDate
      guard progress.completed == 0 || progress.completed == progress.total || now - last >= 0.1 else { return false }
      last = now
      return true
    }
  }
}
