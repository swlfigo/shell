import Foundation
import Combine
import SSHCore

public struct LocalForwardRule: Identifiable, Equatable, Sendable {
  public enum State: Equatable, Sendable {
    case stopped, starting, stopping
    case running(port: Int, clients: Int)
    case failed(String)
  }
  public let id: UUID
  public var configuration: LocalForwardConfiguration
  public var state: State = .stopped
  /// The most recent client error; a failed target does not stop a working listener.
  public var clientError: String?
  public init(id: UUID = UUID(), configuration: LocalForwardConfiguration) {
    self.id = id; self.configuration = configuration
  }
  public var canEdit: Bool {
    switch state { case .stopped, .failed: return true; default: return false }
  }
}

/// Rules belong to one terminal session. Async generations prevent an old start/stop/event
/// from resurrecting a listener after disconnect or overwriting a newer start's status.
@MainActor
public final class LocalForwardManager: ObservableObject {
  public typealias Factory = @MainActor (LocalForwardConfiguration) async throws -> any LocalForwarding
  @Published public private(set) var rules: [LocalForwardRule] = []
  @Published public private(set) var isConnected = false
  @Published public private(set) var destination: LocalForwardDestination?
  @Published public private(set) var isLoading = false
  @Published public private(set) var storageError: String?
  private let factory: Factory
  private let store: LocalForwardStore?
  private var storeObserver: AnyCancellable?
  private var bindingToken = UUID()
  private var tokens: [UUID: UUID] = [:]
  private var tasks: [UUID: Task<Void, Never>] = [:]
  private var eventTasks: [UUID: Task<Void, Never>] = [:]
  private var forwards: [UUID: any LocalForwarding] = [:]

  public init(store: LocalForwardStore? = nil, factory: @escaping Factory) {
    self.store = store; self.factory = factory
    storeObserver = store?.didChange.sink { [weak self] in
      // Store mutations notify before save() finishes updating this manager's rows.
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.reloadSavedRules() } }
    }
  }

  public var canSave: Bool { !isLoading && (store == nil || destination != nil) }
  public var persistsRules: Bool { store != nil }

  /// A different endpoint first closes all old clients and pending starts. Restoration
  /// never calls the forwarding factory, including after an app restart.
  public func bindDestination(_ destination: LocalForwardDestination) async {
    guard store != nil else { return }
    let token = UUID()
    bindingToken = token
    isLoading = true
    setConnected(false)
    let cleanup = Array(tasks.values)
    for task in cleanup { await task.value }
    guard bindingToken == token else { return }
    tokens.removeAll(); tasks.removeAll()
    for task in eventTasks.values { task.cancel() }
    eventTasks.removeAll()
    self.destination = destination
    rules = []
    isLoading = false
    reloadSavedRules()
  }

  /// Passive rules refresh across windows; running clients retain their configuration
  /// until stopped, even if another window edits or removes the saved preset.
  public func reloadSavedRules() {
    guard !isLoading, let store, let destination else { return }
    do {
      let saved = try store.rules(for: destination)
      let old = Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0) })
      var refreshed = saved.map { item -> LocalForwardRule in
        if let existing = old[item.id], !existing.canEdit || existing.configuration == item.configuration {
          return existing
        }
        return LocalForwardRule(id: item.id, configuration: item.configuration)
      }
      let savedIDs = Set(saved.map(\.id))
      refreshed.append(contentsOf: rules.filter { !savedIDs.contains($0.id) && !$0.canEdit })
      rules = refreshed
      storageError = nil
    } catch { storageError = error.localizedDescription }
  }

  deinit {
    for task in tasks.values { task.cancel() }
    for task in eventTasks.values { task.cancel() }
    let forwards = Array(forwards.values)
    Task { for forward in forwards { await forward.stop() } }
  }

  @discardableResult
  public func save(id: UUID? = nil, configuration: LocalForwardConfiguration,
                   expected: LocalForwardConfiguration? = nil) throws -> UUID {
    guard !isLoading else { throw LocalForwardStoreError.loading }
    guard canSave else { throw LocalForwardStoreError.destinationRequired }
    try configuration.validate()
    guard configuration.localPort > 0 else { throw LocalForwardError.invalidConfiguration }
    if let id {
      guard let index = rules.firstIndex(where: { $0.id == id }), rules[index].canEdit else {
        throw LocalForwardStoreError.changedElsewhere
      }
      guard expected == nil || expected == rules[index].configuration else { throw LocalForwardStoreError.changedElsewhere }
      if let store, let destination {
        _ = try store.save(id: id, destination: destination, configuration: configuration,
                           expected: expected ?? rules[index].configuration)
      }
      rules[index].configuration = configuration
      rules[index].state = .stopped
      rules[index].clientError = nil
      storageError = nil
      return id
    }
    let rule: LocalForwardRule
    if let store, let destination {
      let saved = try store.save(destination: destination, configuration: configuration)
      rule = LocalForwardRule(id: saved.id, configuration: saved.configuration)
    } else { rule = LocalForwardRule(configuration: configuration) }
    rules.append(rule)
    storageError = nil
    return rule.id
  }

  public func remove(_ id: UUID, expected: LocalForwardConfiguration? = nil) throws {
    guard !isLoading else { throw LocalForwardStoreError.loading }
    guard let rule = rules.first(where: { $0.id == id }), rule.canEdit else { return }
    guard expected == nil || expected == rule.configuration else { throw LocalForwardStoreError.changedElsewhere }
    if let store, let destination { try store.delete(id, destination: destination, expected: expected ?? rule.configuration) }
    rules.removeAll { $0.id == id }
    tokens[id] = nil
    storageError = nil
  }

  public func setConnected(_ connected: Bool) {
    isConnected = connected
    if !connected { stopAll() }
  }

  public func start(_ id: UUID) {
    guard !isLoading, isConnected, let index = rules.firstIndex(where: { $0.id == id }), rules[index].canEdit else { return }
    let configuration = rules[index].configuration
    let token = UUID()
    tokens[id] = token
    rules[index].state = .starting
    rules[index].clientError = nil
    tasks[id] = Task { [weak self, factory] in
      do {
        let forward = try await factory(configuration)
        guard let self, self.tokens[id] == token, self.isConnected, !Task.isCancelled else {
          await forward.stop()
          return
        }
        self.forwards[id] = forward
        self.tasks[id] = nil
        self.update(id) { $0.state = .running(port: forward.localPort, clients: 0) }
        self.eventTasks[id] = Task { [weak self] in
          for await event in forward.events {
            guard !Task.isCancelled, let self, self.tokens[id] == token else { return }
            self.receive(event, id: id)
          }
        }
      } catch {
        guard let self, self.tokens[id] == token else { return }
        self.tasks[id] = nil
        self.update(id) { $0.state = .failed(Self.message(error)) }
      }
    }
  }

  public func stop(_ id: UUID) {
    guard let rule = rules.first(where: { $0.id == id }), !rule.canEdit, rule.state != .stopping else { return }
    let token = UUID()
    tokens[id] = token
    let pending = tasks.removeValue(forKey: id)
    pending?.cancel()
    eventTasks.removeValue(forKey: id)?.cancel()
    let forward = forwards.removeValue(forKey: id)
    update(id) { $0.state = .stopping; $0.clientError = nil }
    tasks[id] = Task { [weak self] in
      await forward?.stop()
      // A factory that ignores cancellation still must close its late result before restart.
      await pending?.value
      guard let self, self.tokens[id] == token else { return }
      self.tasks[id] = nil
      self.update(id) { $0.state = .stopped }
      self.reloadSavedRules()
    }
  }

  public func stopAll() { for rule in rules { stop(rule.id) } }

  private func receive(_ event: LocalForwardEvent, id: UUID) {
    switch event {
    case .clients(let count):
      guard let forward = forwards[id] else { return }
      update(id) { $0.state = .running(port: forward.localPort, clients: count) }
    case .clientError(let message): update(id) { $0.clientError = message }
    case .stopped(let error):
      guard let forward = forwards.removeValue(forKey: id) else { return }
      eventTasks.removeValue(forKey: id)?.cancel()
      // Keep restart disabled until the old listener and clients have actually closed.
      update(id) { $0.state = .stopping }
      let token = UUID()
      tokens[id] = token
      tasks[id] = Task { [weak self] in
        await forward.stop()
        guard let self, self.tokens[id] == token else { return }
        self.tasks[id] = nil
        self.update(id) { $0.state = error.map(LocalForwardRule.State.failed) ?? .stopped }
        self.reloadSavedRules()
      }
    }
  }

  private func update(_ id: UUID, _ body: (inout LocalForwardRule) -> Void) {
    guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
    body(&rules[index])
  }

  private static func message(_ error: Error) -> String {
    if let error = error as? SSHError {
      switch error {
      case .authenticationFailed: return "转发 SSH 认证失败。"
      case .hostKeyRejected: return "转发 SSH 主机密钥未受信任，请重新连接终端。"
      case .hostKeyMismatch: return "转发 SSH 主机密钥已变化，请检查服务器。"
      case .connectionFailed(let message), .channelFailure(let message): return message
      case .disconnected: return LocalForwardError.notConnected.localizedDescription
      }
    }
    return error.localizedDescription
  }
}
