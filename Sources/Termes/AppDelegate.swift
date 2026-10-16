import AppKit
import Combine
import TermesKit
import SSHCore

/// App-wide: main menu, shared services, the open windows and the quit confirmation.
/// Window-level actions live in MainWindowController; their menu items have a nil target and
/// reach the key window's controller through the responder chain.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
  private let services: AppServices
  private let runAlert: @MainActor (NSAlert) -> NSApplication.ModalResponse
  let workspace: WorkspaceController
  override convenience init() { self.init(services: AppServices()) }
  init(services: AppServices,
       runAlert: @escaping @MainActor (NSAlert) -> NSApplication.ModalResponse = { alert in
         NSApp.unhide(nil); NSApp.activate(ignoringOtherApps: true)
         return alert.runModal()
       }) {
    self.services = services; self.runAlert = runAlert
    workspace = WorkspaceController(services: services); super.init()
  }

  /// Rebuilds 连接 → 打开已存连接 each time it opens, so it always reflects the saved list.
  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    if ["moveSession", "moveTab"].contains(menu.identifier?.rawValue ?? "") {
      guard let source = windows.first(where: { $0.window === NSApp.keyWindow }), let pane = source.focusedPane else { return }
      let moves = menu.identifier?.rawValue == "moveTab"
        ? source.makeMoveMenu(tab: source.layout.selectedTabId) : source.makeMoveMenu(pane: pane.id)
      for item in moves.items { moves.removeItem(item); menu.addItem(item) }
      return
    }
    if menu.identifier?.rawValue == "snippets" {
      do {
        let snippets = try services.snippets.all()
        if snippets.isEmpty {
          let empty = NSMenuItem(title: "(无常用命令)", action: nil, keyEquivalent: "")
          empty.isEnabled = false
          menu.addItem(empty)
        }
        var groups: [String: NSMenu] = [:]
        for snippet in snippets {
          let target: NSMenu
          if snippet.group.isEmpty { target = menu }
          else if let group = groups[snippet.group] { target = group }
          else {
            let group = NSMenu(title: snippet.group)
            let category = NSMenuItem(title: snippet.group, action: nil, keyEquivalent: "")
            category.submenu = group; menu.addItem(category)
            groups[snippet.group] = group; target = group
          }
          let item = NSMenuItem(title: snippet.name, action: #selector(MainWindowController.insertSnippet(_:)), keyEquivalent: "")
          item.representedObject = snippet.id
          item.toolTip = snippet.command
          target.addItem(item)
        }
      } catch {
        let item = NSMenuItem(title: "读取失败，请打开管理常用命令查看", action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
      }
      return
    }
    let list = (try? services.profiles.profiles()) ?? []
    guard !list.isEmpty else {
      let empty = NSMenuItem(title: "(无已存连接)", action: nil, keyEquivalent: "")
      empty.isEnabled = false
      menu.addItem(empty)
      return
    }
    for p in list {
      let item = NSMenuItem(title: p.name, action: #selector(MainWindowController.openSavedConnection(_:)),
                            keyEquivalent: "")
      item.representedObject = p.id
      menu.addItem(item)
    }
  }
  private var windows: [MainWindowController] { workspace.windows }
  private var keyManager: NSWindowController?
  private var snippetManager: NSWindowController?
  private var appearanceWindow: NSWindowController?
  private var appearanceObserver: AnyCancellable?

  func applicationDidFinishLaunching(_ notification: Notification) {
    #if SWIFT_PACKAGE
    if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
       let icon = NSImage(contentsOf: url) {
      NSApp.applicationIconImage = icon
    }
    #endif
    NSWindow.allowsAutomaticWindowTabbing = false  // we draw our own tab bar
    NSApplication.shared.mainMenu = makeMainMenu()
    appearanceObserver = services.appearance.$settings.sink { settings in NSApp.appearance = settings.theme.nativeAppearance }
    workspace.restore()
    workspace.onSaveError = { [weak self] message in self?.showWorkspaceError(message) }
    NSApp.activate(ignoringOtherApps: true)
    if let warning = services.startupDataWarning, let window = windows.first?.window {
      let alert = NSAlert()
      alert.messageText = "本地数据迁移未完成"
      alert.informativeText = warning
      alert.beginSheetModal(for: window)
    }
    if let warning = services.workspace.error { showWorkspaceError(warning) }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    sender.unhide(nil)
    workspace.reopenWindows()
    return false // The workspace restores its existing controllers, including hidden sessions.
  }

  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    let active = windows.reduce(0) { $0 + $1.activeSessionCount }
    let transfers = windows.reduce(0) { $0 + $1.unfinishedTransferCount }
    let forwards = windows.reduce(0) { $0 + $1.activeForwardCount }
    let drafts = RemoteFileEditorWindowController.unsavedCount
    let work = [(active, "个活动会话"), (transfers, "项未完成传输"),
                (forwards, "个端口转发"), (drafts, "个未保存或正在操作的远端文件")]
      .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
    if !work.isEmpty {
      let alert = NSAlert()
      alert.messageText = "仍有 " + work.joined(separator: "、")
      alert.informativeText = "后台运行会保留连接、传输和当前编辑内容，点击 Dock 图标可恢复窗口。\n断开并退出会结束所有会话、停止转发和未完成传输" + (drafts > 0 ? "，并放弃未保存的远端文件草稿。" : "。")
      alert.addButton(withTitle: "后台运行（保持连接）")
      alert.addButton(withTitle: "断开并退出")
      alert.addButton(withTitle: "取消")
      alert.buttons[1].keyEquivalent = ""
      alert.buttons[2].keyEquivalent = "\u{1b}"
      switch runAlert(alert) {
      case .alertFirstButtonReturn:
        workspace.runInBackground()
        sender.hide(nil)
        return .terminateCancel
      case .alertSecondButtonReturn: break
      default: return .terminateCancel
      }
    }
    if !workspace.saveNow(reportError: false) {
      let alert = NSAlert()
      alert.messageText = "工作区未能保存，仍要退出吗？"
      alert.informativeText = "下次启动将使用上次保存的布局。\n" + (services.workspace.error ?? "请检查本机文件权限或磁盘空间。")
      alert.addButton(withTitle: "退出"); alert.addButton(withTitle: "取消")
      guard runAlert(alert) == .alertFirstButtonReturn else { return .terminateCancel }
    }
    RemoteFileEditorWindowController.cancelAll()
    workspace.prepareToTerminate(save: false)
    return .terminateNow
  }

  @objc func newWindow(_ sender: Any?) { workspace.openWindow() }

  private func showWorkspaceError(_ message: String) {
    guard let window = windows.first?.window, window.attachedSheet == nil else { return }
    let alert = NSAlert(); alert.messageText = "工作区未能恢复或保存"; alert.informativeText = message
    alert.beginSheetModal(for: window)
  }

  @objc private func saveWorkspace(_ sender: Any?) {
    do {
      try services.workspace.preserveUnreadableFile()
      _ = workspace.saveNow()
    } catch { NSAlert(error: error).runModal() }
  }

  private func makeMainMenu() -> NSMenu {
    let main = NSMenu()
    func submenu(_ title: String) -> NSMenu {
      let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      main.addItem(item)
      let menu = NSMenu(title: title)
      item.submenu = menu
      return menu
    }

    let app = submenu(ApplicationIdentity.name)
    app.addItem(withTitle: "设置…", action: #selector(showAppearance), keyEquivalent: ",").target = self
    app.addItem(.separator())
    app.addItem(withTitle: "Quit Termes", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

    let file = submenu("文件")
    file.addItem(withTitle: "新建标签", action: #selector(MainWindowController.newTab(_:)), keyEquivalent: "t")
    file.addItem(withTitle: "新建窗口", action: #selector(newWindow(_:)), keyEquivalent: "n").target = self
    file.addItem(withTitle: "复制会话", action: #selector(MainWindowController.duplicateSession(_:)), keyEquivalent: "d")
    file.addItem(withTitle: "保存远端文件", action: #selector(RemoteFileEditorWindowController.saveRemoteFile(_:)), keyEquivalent: "s")
    file.addItem(withTitle: "导出终端输出…", action: #selector(MainWindowController.exportTerminalOutput(_:)), keyEquivalent: "E")
    file.addItem(.separator())
    file.addItem(withTitle: "关闭", action: #selector(MainWindowController.closeFocusedPane(_:)), keyEquivalent: "w")

    // Nil target: ⌘C/⌘V/⌘A travel the responder chain to the terminal view.
    let edit = submenu("Edit")
    edit.addItem(withTitle: "Undo", action: #selector(RemoteFileEditorWindowController.undoText(_:)), keyEquivalent: "z")
    edit.addItem(withTitle: "Redo", action: #selector(RemoteFileEditorWindowController.redoText(_:)), keyEquivalent: "Z")
    edit.addItem(.separator())
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    edit.addItem(.separator())
    edit.addItem(withTitle: "搜索终端历史…", action: #selector(MainWindowController.findTerminalText(_:)), keyEquivalent: "f")
    edit.addItem(withTitle: "下一个匹配", action: #selector(MainWindowController.findNextTerminalMatch(_:)), keyEquivalent: "g")
    edit.addItem(withTitle: "上一个匹配", action: #selector(MainWindowController.findPreviousTerminalMatch(_:)), keyEquivalent: "G")

    let conn = submenu("连接")
    let saved = NSMenuItem(title: "打开已存连接", action: nil, keyEquivalent: "")
    let savedMenu = NSMenu(title: "打开已存连接")
    savedMenu.delegate = self  // rebuilt in menuNeedsUpdate
    saved.submenu = savedMenu
    conn.addItem(saved)
    conn.addItem(.separator())
    conn.addItem(withTitle: "端口转发…", action: #selector(MainWindowController.manageLocalForwards(_:)), keyEquivalent: "")
    conn.addItem(withTitle: "服务器监控", action: #selector(MainWindowController.toggleServerMonitor(_:)), keyEquivalent: "")
    conn.addItem(withTitle: "连接日志…", action: #selector(MainWindowController.showConnectionLogs(_:)), keyEquivalent: "")
    conn.addItem(.separator())
    conn.addItem(withTitle: "管理私钥…", action: #selector(manageKeys), keyEquivalent: "").target = self
    conn.addItem(.separator())
    conn.addItem(withTitle: "导出连接…", action: #selector(exportConnections), keyEquivalent: "").target = self
    conn.addItem(withTitle: "导入连接…", action: #selector(importConnections), keyEquivalent: "").target = self

    let commands = submenu("命令")
    commands.addItem(withTitle: "管理常用命令…", action: #selector(manageSnippets), keyEquivalent: "").target = self
    let insert = NSMenuItem(title: "插入常用命令", action: nil, keyEquivalent: "")
    let snippetsMenu = NSMenu(title: "插入常用命令")
    snippetsMenu.identifier = NSUserInterfaceItemIdentifier("snippets")
    snippetsMenu.delegate = self
    insert.submenu = snippetsMenu
    commands.addItem(insert)

    let win = submenu("窗口")
    win.addItem(withTitle: "Vaults 首页", action: #selector(MainWindowController.showVaults(_:)), keyEquivalent: "H")
    win.addItem(.separator())
    win.addItem(withTitle: "将当前标签移到新窗口", action: #selector(MainWindowController.moveCurrentTabToNewWindow(_:)), keyEquivalent: "")
    let moveTab = NSMenuItem(title: "移动当前标签到窗口", action: nil, keyEquivalent: "")
    let moveTabMenu = NSMenu(title: "移动当前标签到窗口")
    moveTabMenu.identifier = NSUserInterfaceItemIdentifier("moveTab"); moveTabMenu.delegate = self
    moveTab.submenu = moveTabMenu; win.addItem(moveTab)
    let move = NSMenuItem(title: "移动当前会话到窗口", action: nil, keyEquivalent: "")
    let moveMenu = NSMenu(title: "移动当前会话到窗口")
    moveMenu.identifier = NSUserInterfaceItemIdentifier("moveSession"); moveMenu.delegate = self
    move.submenu = moveMenu; win.addItem(move)
    win.addItem(withTitle: "重新保存工作区…", action: #selector(saveWorkspace(_:)), keyEquivalent: "").target = self
    win.addItem(.separator())
    win.addItem(withTitle: "服务器侧栏", action: #selector(MainWindowController.toggleSidebar(_:)), keyEquivalent: "S")
    let search = win.addItem(withTitle: "搜索服务器", action: #selector(MainWindowController.searchServers(_:)), keyEquivalent: "f")
    search.keyEquivalentModifierMask = [.command, .option]
    let tools = win.addItem(withTitle: "服务器工具", action: #selector(MainWindowController.toggleSessionTools(_:)), keyEquivalent: "i")
    tools.keyEquivalentModifierMask = [.command, .option]
    win.addItem(.separator())
    // "{" / "}" are ⌘⇧[ / ⌘⇧] on a US layout.
    win.addItem(withTitle: "上一个标签", action: #selector(MainWindowController.selectPreviousTab(_:)), keyEquivalent: "{")
    win.addItem(withTitle: "下一个标签", action: #selector(MainWindowController.selectNextTab(_:)), keyEquivalent: "}")
    win.addItem(.separator())
    for i in 1...9 {
      let item = win.addItem(withTitle: "标签 \(i)", action: #selector(MainWindowController.selectTabByNumber(_:)),
                             keyEquivalent: "\(i)")
      item.tag = i - 1
    }
    NSApp.windowsMenu = win
    win.addItem(.separator())
    let fullScreen = win.addItem(withTitle: "切换全屏", action: #selector(NSWindow.toggleFullScreen(_:)),
                                 keyEquivalent: "f")
    fullScreen.keyEquivalentModifierMask = [.command, .control]
    return main
  }

  @objc func manageKeys() {
    if keyManager == nil {
      let content = KeyManagerViewController(profiles: services.profiles)
      let window = NSWindow(contentViewController: content)
      window.title = "私钥管理"
      window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
      window.minSize = NSSize(width: 600, height: 340)
      window.isReleasedWhenClosed = false
      window.isRestorable = false
      window.center()
      keyManager = NSWindowController(window: window)
    }
    keyManager?.showWindow(nil)
    keyManager?.window?.makeKeyAndOrderFront(nil)
  }

  @objc func manageSnippets() {
    if snippetManager == nil {
      let content = SnippetManagerViewController(store: services.snippets)
      let window = NSWindow(contentViewController: content)
      window.title = "常用命令"
      window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
      window.contentMinSize = NSSize(width: 560, height: 420)
      window.isReleasedWhenClosed = false
      window.isRestorable = false
      window.center()
      snippetManager = NSWindowController(window: window)
    }
    snippetManager?.showWindow(nil)
    snippetManager?.window?.makeKeyAndOrderFront(nil)
  }

  @objc func showAppearance() {
    if appearanceWindow == nil {
      let window = NSWindow(contentViewController: AppearanceViewController(store: services.appearance))
      window.title = "Termes 设置"; window.styleMask = [.titled, .closable, .resizable]
      window.contentMinSize = NSSize(width: 360, height: 480)
      window.isRestorable = false; window.isReleasedWhenClosed = false; window.center()
      appearanceWindow = NSWindowController(window: window)
    }
    appearanceWindow?.showWindow(nil); appearanceWindow?.window?.makeKeyAndOrderFront(nil)
  }

  @objc private func exportConnections() {
    let panel = NSSavePanel(); panel.nameFieldStringValue = "termes-connections.json"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let profiles = services.profiles
    Task {
      do {
        let snap = ConnectionSnapshot(profiles: try profiles.profiles(), keys: try profiles.keys())
        _ = try await FileSyncProvider(fileURL: url).push(snap, baseVersion: nil)
      } catch { NSAlert(error: error).runModal() }
    }
  }

  @objc private func importConnections() {
    let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let profiles = services.profiles
    Task {
      do {
        guard let snap = try await FileSyncProvider(fileURL: url).pull() else { return }
        try profiles.importSnapshot(snap)   // didChange refreshes every open connect page
        let done = NSAlert()
        done.messageText = "已导入 \(snap.profiles.count) 个连接"
        done.runModal()
      } catch { NSAlert(error: error).runModal() }
    }
  }
}
