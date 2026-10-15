import Foundation
import Combine
import SSHCore

@MainActor
public final class RemotePermissionsModel: ObservableObject {
  public let path: String
  @Published public var octal = ""
  @Published public private(set) var entry: SFTPEntry?
  @Published public private(set) var isBusy = false
  @Published public private(set) var error: String?
  public var permissions: UnixPermissions? { try? .init(octal: octal) }
  public var validationError: String? { permissions == nil && !octal.isEmpty ? SFTPEditError.invalidPermissions.localizedDescription : nil }
  public var canApply: Bool { entry != nil && permissions != nil && !isBusy }
  private let original: SFTPEntry
  private let factory: FileBrowserModel.Factory
  private var task: Task<Void, Never>?
  private var generation = 0
  public init(entry: SFTPEntry, factory: @escaping FileBrowserModel.Factory) {
    original = entry; path = entry.path; self.factory = factory
  }
  public func load() {
    guard !isBusy else { return }
    generation += 1; let gen = generation; isBusy = true; error = nil
    task = Task { [weak self] in
      guard let self else { return }
      do {
        let current = try await RemoteEditingOperation.perform(factory: factory) { try await $0.fileAttributes(self.path) }
        try Task.checkCancellation(); guard generation == gen else { return }
        guard (current.kind == .file || current.kind == .directory), current.kind == original.kind else { throw SFTPError.unsupportedFile }
        guard let mode = current.permissions else { throw SFTPEditError.missingMetadata }
        entry = current; octal = try UnixPermissions(mode).octal
      } catch { guard generation == gen else { return }; self.error = error.localizedDescription }
      guard generation == gen else { return }; isBusy = false; task = nil
    }
  }
  public func setBit(_ bit: UInt32, enabled: Bool) {
    guard let permissions, !isBusy else { return }
    if let updated = try? UnixPermissions(enabled ? permissions.value | bit : permissions.value & ~bit) { octal = updated.octal }
  }
  public func apply(completion: (@MainActor (Bool) -> Void)? = nil) {
    guard canApply, let entry, let permissions else { completion?(false); return }
    generation += 1; let gen = generation; isBusy = true; error = nil
    task = Task { [weak self] in
      guard let self else { completion?(false); return }
      var success = false
      do {
        let updated = try await RemoteEditingOperation.perform(factory: factory) {
          try await $0.setPermissions(self.path, permissions: permissions.value, expected: entry)
        }
        try Task.checkCancellation(); guard generation == gen else { completion?(false); return }
        self.entry = updated; success = true
      } catch { guard generation == gen else { completion?(false); return }; self.error = error.localizedDescription }
      guard generation == gen else { completion?(false); return }
      isBusy = false; task = nil; completion?(success)
    }
  }
  public func cancel() { generation += 1; task?.cancel(); task = nil; isBusy = false }
}
