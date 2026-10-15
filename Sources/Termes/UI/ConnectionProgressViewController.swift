import AppKit
import Combine
import TermesKit

@MainActor
final class ConnectionProgressViewController: NSViewController {
  let session: SessionManager
  var onClose: (() -> Void)?
  let statusLabel = NSTextField(wrappingLabelWithString: "")
  let fingerprintLabel = NSTextField(wrappingLabelWithString: "")
  let logView = NSTextView()
  let stepLabels = (0..<5).map { _ in NSTextField(wrappingLabelWithString: "") }
  private var serverName: String
  private let root = FileLayoutView(), document = FlippedFileView()
  private let scroll = NSScrollView(), logScroll = NSScrollView()
  private let heading = NSTextField(labelWithString: "")
  private let endpointLabel = NSTextField(wrappingLabelWithString: "")
  private let routeLabel = NSTextField(wrappingLabelWithString: "")
  private let spinner = NSProgressIndicator()
  private var observers: Set<AnyCancellable> = []
  private var displayedAttempt = UUID(), displayedFingerprint: String?
  private var lastLogID: UUID?
  private(set) var showsLogs: Bool
  private lazy var trustButton = button("信任", #selector(trust))
  private lazy var rejectButton = button("拒绝", #selector(reject))
  private lazy var cancelButton = button("取消连接", #selector(cancelConnection))
  private lazy var retryButton = button("立即重试", #selector(retryConnection))
  private lazy var closeButton = button("返回编辑", #selector(closeProgress))
  private lazy var logButton = button("展开日志", #selector(toggleLogs))
  var hasCurrentAttempt: Bool { displayedAttempt == session.connectionProgress.attemptID }

  init(session: SessionManager, serverName: String, showsLogs: Bool = false) {
    self.session = session; self.serverName = serverName; self.showsLogs = showsLogs
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError("unsupported") }
  override func loadView() {
    view = root
    root.wantsLayer = true; root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
    scroll.documentView = document; root.addSubview(scroll)
    root.onLayout = { [weak self] in self?.layoutContent() }
    heading.font = .boldSystemFont(ofSize: 15); heading.lineBreakMode = .byTruncatingTail
    statusLabel.font = .systemFont(ofSize: 12); statusLabel.maximumNumberOfLines = 3
    endpointLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium); endpointLabel.maximumNumberOfLines = 3
    routeLabel.font = .systemFont(ofSize: 11); routeLabel.textColor = .secondaryLabelColor
    for label in stepLabels { label.font = .systemFont(ofSize: 12); label.maximumNumberOfLines = 3 }
    fingerprintLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    fingerprintLabel.lineBreakMode = .byCharWrapping; fingerprintLabel.isSelectable = true
    fingerprintLabel.setAccessibilityLabel("需要信任的服务器及完整 SHA256 指纹")
    spinner.style = .spinning; spinner.controlSize = .small; spinner.isIndeterminate = true
    cancelButton.keyEquivalent = "\u{1b}"
    logView.isEditable = false; logView.isSelectable = true; logView.isRichText = false
    logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    logView.textColor = .labelColor; logView.drawsBackground = false
    logView.isHorizontallyResizable = false; logView.isVerticallyResizable = true
    logView.minSize = .zero; logView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    logView.autoresizingMask = [.width]; logView.textContainer?.widthTracksTextView = true
    logView.textContainerInset = NSSize(width: 6, height: 6)
    logView.setAccessibilityLabel("连接日志")
    logScroll.hasVerticalScroller = true; logScroll.autohidesScrollers = true; logScroll.documentView = logView
    for child in [heading, statusLabel, endpointLabel, routeLabel, fingerprintLabel, spinner, trustButton, rejectButton,
                  cancelButton, retryButton, closeButton, logButton, logScroll] + stepLabels { document.addSubview(child) }
    session.connectionProgress.objectWillChange.sink { [weak self] in
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.render() } }
    }.store(in: &observers)
    session.$state.sink { [weak self] _ in
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.render() } }
    }.store(in: &observers)
    render()
  }
  func shutdown() { observers.removeAll(); spinner.stopAnimation(nil) }
  func setServerName(_ name: String) { serverName = name; render() }
  func focusAction() { view.window?.makeFirstResponder(cancelButton.isHidden ? closeButton : cancelButton) }
  @objc func toggleLogs() { showsLogs.toggle(); render() }
  @objc func trust() { confirm(true) }
  @objc func reject() { confirm(false) }
  private func confirm(_ value: Bool) {
    guard let displayedFingerprint else { return }
    session.confirmHostKey(value, attemptID: displayedAttempt, fingerprint: displayedFingerprint)
  }
  @objc func cancelConnection() { guard hasCurrentAttempt else { return }; session.disconnect() }
  @objc func retryConnection() {
    guard hasCurrentAttempt, case .waitingRetry = session.connectionProgress.state else { return }
    session.retryReconnectNow()
  }
  @objc func closeProgress() {
    guard hasCurrentAttempt else { return }
    if session.connectionProgress.canCancel { session.disconnect() }
    onClose?()
  }
  private func button(_ title: String, _ action: Selector) -> NSButton {
    let result = NSButton(title: title, target: self, action: action); result.bezelStyle = .rounded; result.controlSize = .small
    return result
  }
  func render() {
    guard isViewLoaded else { return }
    let model = session.connectionProgress
    displayedAttempt = model.attemptID
    let message: String
    switch model.state {
    case .idle: message = "尚未发起连接"
    case .running: message = "SSH 连接中…"
    case .waitingForTrust: message = "等待确认服务器身份"
    case .ready: message = "连接就绪"
    case .cancelled: message = "连接已取消"
    case .disconnected: message = "连接已断开"
    case .failed(let error): message = "连接失败 · \(error)"
    case .waitingRetry(let seconds): message = "等待自动重试（本次间隔 \(seconds) 秒）"
    }
    heading.stringValue = "\(serverName) · 连接过程"
    statusLabel.stringValue = "第 \(model.attempt) 次尝试 · \(message)"
    if case .failed = model.state { statusLabel.textColor = .systemRed } else { statusLabel.textColor = .labelColor }
    if model.state == .running { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    spinner.isHidden = model.state != .running
    if let node = model.currentNode {
      let endpoint = node.endpoint, host = endpoint.hostname.contains(":") ? "[\(endpoint.hostname)]" : endpoint.hostname
      endpointLabel.stringValue = (endpoint.isJumpHost ? "跳板机 \(endpoint.index + 1)/\(endpoint.jumpCount)" : "目标服务器") + "\n\(endpoint.username)@\(host):\(endpoint.port)"
      endpointLabel.toolTip = endpointLabel.stringValue
      let names = ["建立连接", "主机校验", "身份认证", endpoint.isJumpHost ? "准备下一跳" : "打开终端", endpoint.isJumpHost ? "跳板机就绪" : "连接就绪"]
      for (index, label) in stepLabels.enumerated() {
        let text: String, color: NSColor
        switch node.steps[index] {
        case .waiting: text = "○ \(names[index]) · 等待"; color = .secondaryLabelColor
        case .running: text = "▶ \(names[index]) · 正在进行"; color = .controlAccentColor
        case .waitingForTrust: text = "? \(names[index]) · 等待用户确认"; color = .systemOrange
        case .succeeded: text = "✓ \(names[index]) · 已完成"; color = .systemGreen
        case .failed(let error): text = "✕ \(names[index]) · \(error)"; color = .systemRed
        case .cancelled: text = "– \(names[index]) · 已取消"; color = .secondaryLabelColor
        }
        label.stringValue = text; label.textColor = color
      }
    } else { endpointLabel.stringValue = ""; stepLabels.forEach { $0.stringValue = "" } }
    routeLabel.stringValue = model.nodes.count > 1 ? model.nodes.map {
      let role = $0.endpoint.isJumpHost ? "跳板 \($0.endpoint.index + 1)" : "目标"
      return "\(role) · \($0.endpoint.hostname)" + ($0.steps[4] == .succeeded ? " ✓" : "")
    }.joined(separator: "\n") : ""
    displayedFingerprint = nil
    if case .needsHostKeyConfirm(let fingerprint) = session.state {
      displayedFingerprint = fingerprint
      let endpoint = session.pendingHostKeyEndpoint.map { "\($0.hostname.contains(":") ? "[\($0.hostname)]" : $0.hostname):\($0.port)" } ?? "该主机"
      fingerprintLabel.stringValue = "首次连接 \(endpoint)\n\(fingerprint)\n请核对服务器指纹后决定是否信任。"
    }
    fingerprintLabel.isHidden = displayedFingerprint == nil
    trustButton.isHidden = displayedFingerprint == nil; rejectButton.isHidden = displayedFingerprint == nil
    cancelButton.isHidden = !model.canCancel; cancelButton.isEnabled = model.canCancel
    if case .waitingRetry = model.state { retryButton.isHidden = false } else { retryButton.isHidden = true }
    closeButton.title = model.canCancel ? "返回编辑" : (model.state == .ready || model.state == .disconnected ? "关闭" : "返回编辑")
    logButton.title = showsLogs ? "收起日志" : "展开日志"; logScroll.isHidden = !showsLogs
    if lastLogID != model.logs.last?.id {
      lastLogID = model.logs.last?.id
      let atEnd = logScroll.contentView.bounds.maxY >= logView.bounds.maxY - 4
      logView.string = model.logs.map { "\($0.timestamp.formatted(date: .omitted, time: .standard)) [尝试 \($0.attempt)] \($0.text)" }.joined(separator: "\n")
      if atEnd { logView.scrollToEndOfDocument(nil) }
    }
    layoutContent()
  }
  private func layoutContent() {
    guard isViewLoaded else { return }
    scroll.frame = root.bounds
    let width = max(300, scroll.contentSize.width), inner = width - 32
    var y: CGFloat = 16
    func row(_ child: NSView, height: CGFloat) { child.frame = NSRect(x: 16, y: y, width: inner, height: height); y += height + 10 }
    func textHeight(_ label: NSTextField, minimum: CGFloat) -> CGFloat {
      max(minimum, ceil(label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: inner, height: CGFloat.greatestFiniteMagnitude)).height ?? minimum))
    }
    row(heading, height: 24)
    heading.frame.size.width = inner - 24
    row(statusLabel, height: textHeight(statusLabel, minimum: 32))
    spinner.frame = NSRect(x: width - 32, y: 18, width: 16, height: 16)
    row(endpointLabel, height: textHeight(endpointLabel, minimum: 40))
    if !routeLabel.stringValue.isEmpty { row(routeLabel, height: textHeight(routeLabel, minimum: 16)) }
    for (index, label) in stepLabels.enumerated() {
      let failed: Bool
      if case .failed = session.connectionProgress.currentNode?.steps[index] { failed = true } else { failed = false }
      row(label, height: textHeight(label, minimum: failed ? 40 : 26))
    }
    if displayedFingerprint != nil {
      row(fingerprintLabel, height: textHeight(fingerprintLabel, minimum: 82))
      trustButton.frame = NSRect(x: 16, y: y, width: 80, height: 26)
      rejectButton.frame = NSRect(x: 106, y: y, width: 80, height: 26); y += 36
    }
    var x: CGFloat = 16
    for control in [cancelButton, retryButton, closeButton, logButton].filter({ !$0.isHidden }) {
      if x + 82 > width - 16 { x = 16; y += 36 }
      control.frame = NSRect(x: x, y: y, width: 82, height: 26); x += 90
    }
    y += 36
    if showsLogs {
      row(logScroll, height: max(160, min(320, root.bounds.height * 0.4)))
      logView.frame.size.width = logScroll.contentSize.width
      if let container = logView.textContainer, let manager = logView.layoutManager {
        manager.ensureLayout(for: container)
        logView.frame.size.height = max(logScroll.contentSize.height, ceil(manager.usedRect(for: container).height) + 12)
      }
    }
    document.frame = NSRect(x: 0, y: 0, width: width, height: y + 6)
  }
}

@MainActor
final class ConnectionProgressWindowController: NSWindowController, NSWindowDelegate {
  private let progress: ConnectionProgressViewController
  init(session: SessionManager, serverName: String) {
    progress = .init(session: session, serverName: serverName, showsLogs: true)
    let window = NSWindow(contentViewController: progress)
    window.styleMask = [.titled, .closable, .resizable]; window.setContentSize(.init(width: 620, height: 700))
    window.contentMinSize = .init(width: 300, height: 240); window.isReleasedWhenClosed = false; window.isRestorable = false
    window.title = "连接日志 · \(serverName)"; window.center()
    super.init(window: window); window.delegate = self
    progress.onClose = { [weak self] in self?.close() }
  }
  required init?(coder: NSCoder) { fatalError("unsupported") }
  func setServerName(_ name: String) {
    progress.setServerName(name); window?.title = "连接日志 · \(name)"
  }
  func windowWillClose(_ notification: Notification) {
    if progress.hasCurrentAttempt && progress.session.connectionProgress.canCancel { progress.session.disconnect() }
  }
}
