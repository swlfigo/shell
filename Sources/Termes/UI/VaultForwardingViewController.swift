import AppKit
import Combine
import SSHCore
import TermesKit

/// Saved targets can be edited without connecting or reading credentials. Connected targets
/// use the session's actual manager, so starting/stopping here controls the same live listeners.
@MainActor
final class VaultForwardingViewController: NSViewController {
  let hostPopup = NSPopUpButton()
  let connectButton = NSButton(title: "连接主机", target: nil, action: nil)
  var onConnect: ((UUID) -> Void)?
  var liveManager: ((LocalForwardDestination) -> LocalForwardManager?)?
  private(set) var editor: LocalForwardViewController?
  private(set) var selectedProfileID: UUID?
  private let services: AppServices
  private let model: ServerListModel
  private let root = VaultLayoutView(frame: .init(x: 0, y: 0, width: 760, height: 560))
  private let hint = NSTextField(wrappingLabelWithString: "")
  private var profileIDs: [UUID] = []
  private var observer: AnyCancellable?
  private var offlineManagers: [LocalForwardDestination: LocalForwardManager] = [:]
  private var editors: [ObjectIdentifier: LocalForwardViewController] = [:]

  init(services: AppServices, model: ServerListModel) {
    self.services = services; self.model = model
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError("unsupported") }
  override func loadView() {
    view = root; root.fillColor = TermesColors.vaultBackground
    hostPopup.target = self; hostPopup.action = #selector(hostChanged)
    hostPopup.setAccessibilityLabel("端口转发的 SSH 主机")
    connectButton.target = self; connectButton.action = #selector(connectTapped)
    connectButton.bezelStyle = .rounded
    hint.font = .systemFont(ofSize: 12); hint.textColor = .secondaryLabelColor
    for child in [hostPopup, connectButton, hint] { root.addSubview(child) }
    root.onLayout = { [weak self] in self?.layoutContent() }
    observer = model.objectWillChange.sink { [weak self] in
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.refresh() } }
    }
    refresh()
  }

  func refresh() {
    guard isViewLoaded else { return }
    let profiles = model.profiles
    profileIDs = profiles.map(\.id)
    hostPopup.removeAllItems()
    hostPopup.addItem(withTitle: "选择 SSH 主机…")
    hostPopup.addItems(withTitles: profiles.map(\.name))
    if let id = selectedProfileID, let index = profileIDs.firstIndex(of: id) { hostPopup.selectItem(at: index + 1) }
    else { selectedProfileID = nil; hostPopup.selectItem(at: 0) }
    connectButton.isEnabled = selectedProfileID != nil && model.error == nil
    guard let id = selectedProfileID else {
      editor?.view.isHidden = true; editor = nil
      hint.stringValue = model.error ?? (profiles.isEmpty ? "先在 Hosts 中添加主机，再创建端口转发规则。" : "选择主机即可查看和保存规则；连接 SSH 后可手动启动转发。")
      root.needsLayout = true
      return
    }
    do {
      let destination = try services.profiles.forwardingDestination(for: id)
      let manager: LocalForwardManager
      if let live = liveManager?(destination) { manager = live }
      else if let existing = offlineManagers[destination] { manager = existing }
      else {
        manager = LocalForwardManager(store: services.localForwards) { _ in throw LocalForwardError.notConnected }
        offlineManagers[destination] = manager
        Task { await manager.bindDestination(destination) }
      }
      let identity = ObjectIdentifier(manager)
      let page: LocalForwardViewController
      if let existing = editors[identity] { page = existing }
      else {
        page = LocalForwardViewController(model: manager)
        editors[identity] = page; addChild(page); root.addSubview(page.view)
      }
      if editor !== page { editor?.view.isHidden = true; editor = page }
      page.view.isHidden = false
      connectButton.title = manager.isConnected ? "打开会话" : "连接主机"
      hint.stringValue = manager.isConnected ? "已连接 · 修改与当前会话共用的转发规则。" : "未连接 · 可以先保存规则，连接 SSH 后手动启动。"
    } catch {
      editor?.view.isHidden = true; editor = nil
      hint.stringValue = error.localizedDescription
      connectButton.isEnabled = false
    }
    root.needsLayout = true
  }

  @objc private func hostChanged() {
    let index = hostPopup.indexOfSelectedItem - 1
    selectedProfileID = profileIDs.indices.contains(index) ? profileIDs[index] : nil
    refresh()
  }
  @objc private func connectTapped() {
    guard let id = selectedProfileID, connectButton.isEnabled else { return }
    onConnect?(id)
  }
  private func layoutContent() {
    let width = root.bounds.width, height = root.bounds.height
    hostPopup.frame = .init(x: 20, y: 8, width: max(0, width - 180), height: 30)
    connectButton.frame = .init(x: width - 144, y: 8, width: 124, height: 30)
    hint.frame = .init(x: 22, y: 50, width: max(0, width - 44), height: 32)
    editor?.view.frame = .init(x: 0, y: 88, width: width, height: max(0, height - 88))
    editor?.view.needsLayout = true
  }
}
