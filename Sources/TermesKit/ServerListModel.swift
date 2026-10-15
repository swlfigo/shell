import Foundation
import Combine

public struct ServerSessionInfo: Equatable, Sendable {
  public let profileID: UUID
  public let state: SessionManager.State
  public let destination: LocalForwardDestination?
  public init(profileID: UUID, state: SessionManager.State, destination: LocalForwardDestination? = nil) {
    self.profileID = profileID; self.state = state; self.destination = destination
  }
}

/// Server selection is independent from window/tab/pane focus. Only an explicit open connects.
@MainActor
public final class ServerListModel: ObservableObject {
  @Published public var search = ""
  @Published public private(set) var selectedID: UUID?
  @Published public private(set) var profiles: [ConnectionProfile] = []
  @Published public private(set) var sessions: [ServerSessionInfo] = []
  @Published public private(set) var error: String?
  private let service: ConnectionProfileService
  private var observer: AnyCancellable?

  public init(service: ConnectionProfileService) {
    self.service = service
    reload()
    observer = service.didChange.sink { [weak self] in self?.reload() }
  }

  public var filteredProfiles: [ConnectionProfile] {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    return profiles.filter {
      query.isEmpty || [$0.name, $0.hostname, $0.username, String($0.port)].contains { $0.localizedStandardContains(query) }
    }
  }

  public func select(_ id: UUID?) {
    selectedID = id.flatMap { id in profiles.contains { $0.id == id } ? id : nil }
  }

  public func updateSessions(_ value: [ServerSessionInfo]) { if sessions != value { sessions = value } }

  public func sessionText(for id: UUID) -> String {
    let all = sessions.filter { $0.profileID == id }
    let values = all.filter { matchesSavedTarget($0) }
    guard !values.isEmpty else { return all.isEmpty ? "未连接" : "旧配置会话 · \(all.count) 个" }
    let status = values.map(\.state.status).max() ?? .idle
    let state = values.first { $0.state.status == status }?.state ?? .idle
    return state.displayText + (values.count > 1 ? " · \(values.count) 个会话" : "") + (values.count < all.count ? " · 有旧配置会话" : "")
  }

  public func status(for id: UUID) -> SessionStatus {
    sessions.filter { $0.profileID == id && matchesSavedTarget($0) }.map(\.state.status).max() ?? .idle
  }

  /// An edited saved address/route must not inherit a connection badge for the old target.
  private func matchesSavedTarget(_ session: ServerSessionInfo) -> Bool {
    guard let destination = session.destination else { return true }
    guard let profile = profiles.first(where: { $0.id == session.profileID }),
      profile.hostname.lowercased() == destination.hostname, profile.port == destination.port,
      profile.username == destination.username else { return false }
    var route: [ForwardJumpIdentity] = [], next = profile.jumpProfileId
    while let id = next {
      guard route.count < 8, let hop = profiles.first(where: { $0.id == id }) else { return false }
      route.insert(.init(hostname: hop.hostname.lowercased(), port: hop.port, username: hop.username), at: 0)
      next = hop.jumpProfileId
    }
    return route == (destination.jumpHosts ?? [])
  }

  private func reload() {
    do {
      let list = try service.profiles().sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
      profiles = list
      if let selectedID, !list.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
      error = nil
    } catch { self.error = "服务器列表读取失败，请检查连接配置文件。" }
  }
}
