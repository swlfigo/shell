import AppKit
import Combine
import TermesKit

@MainActor
final class RemoteFileEditorViewController: NSViewController, NSTextViewDelegate {
  let model: RemoteFileEditorModel
  let textView = NSTextView()
  var onChange: (() -> Void)?
  private let pathLabel = NSTextField(labelWithString: "")
  private let status = NSTextField(wrappingLabelWithString: "")
  private let scroll = NSScrollView()
  private var observer: AnyCancellable?
  private lazy var save = NSButton(title: "保存到远端", target: self, action: #selector(saveFile))
  private lazy var reload = NSButton(title: "重新读取", target: self, action: #selector(reloadFile))
  private lazy var export = NSButton(title: "另存到本机…", target: self, action: #selector(exportFile))
  private lazy var overwrite = NSButton(title: "确认覆盖…", target: self, action: #selector(overwriteFile))
  private lazy var stop = NSButton(title: "停止", target: self, action: #selector(stopOperation))
  init(model: RemoteFileEditorModel) { self.model = model; super.init(nibName: nil, bundle: nil) }
  required init?(coder: NSCoder) { fatalError("unsupported") }
  override func loadView() {
    let root = FileLayoutView(frame: NSRect(x: 0, y: 0, width: 780, height: 560)); view = root
    pathLabel.stringValue = model.path; pathLabel.lineBreakMode = .byTruncatingMiddle
    textView.isRichText = false; textView.allowsUndo = true; textView.delegate = self
    textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    textView.isAutomaticQuoteSubstitutionEnabled = false; textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false; textView.isAutomaticSpellingCorrectionEnabled = false
    textView.isContinuousSpellCheckingEnabled = false
    textView.textContainerInset = NSSize(width: 8, height: 8)
    textView.isVerticallyResizable = true; textView.isHorizontallyResizable = true
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.textContainer?.containerSize = textView.maxSize; textView.textContainer?.widthTracksTextView = false
    textView.setAccessibilityLabel("远端文件文本")
    scroll.documentView = textView; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
    status.font = .systemFont(ofSize: 11); status.maximumNumberOfLines = 3
    for child in [pathLabel, scroll, save, reload, export, overwrite, stop, status] { root.addSubview(child) }
    for button in [save, reload, export, overwrite, stop] { button.bezelStyle = .rounded; button.controlSize = .small }
    root.onLayout = { [weak self] in self?.layoutContent() }
    observer = model.objectWillChange.sink { [weak self] in
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.render() } }
    }
    render(); model.load()
  }
  private func layoutContent() {
    let width = view.bounds.width, height = view.bounds.height
    pathLabel.frame = NSRect(x: 12, y: height - 30, width: width - 24, height: 20)
    for (index, button) in [save, reload, export, overwrite, stop].enumerated() {
      button.frame = NSRect(x: 10 + CGFloat(index) * (width - 20) / 5, y: height - 64, width: (width - 20) / 5, height: 28)
    }
    scroll.frame = NSRect(x: 12, y: 58, width: width - 24, height: height - 132)
    textView.minSize = scroll.contentSize
    status.frame = NSRect(x: 12, y: 8, width: width - 24, height: 44)
  }
  private func render() {
    if textView.string != model.text {
      textView.string = model.text
      textView.undoManager?.removeAllActions()
    }
    textView.isEditable = model.isLoaded && !model.isBusy
    save.isEnabled = model.canSave; reload.isEnabled = !model.isBusy
    export.isEnabled = model.isLoaded; overwrite.isEnabled = model.hasConflict && model.canSave
    stop.isEnabled = model.isBusy
    status.stringValue = model.error ?? "\(model.isDirty ? "有未保存更改 · " : "")\(model.status)"
    status.toolTip = status.stringValue; status.textColor = model.error == nil ? .secondaryLabelColor : .systemRed
    onChange?()
  }
  func textDidChange(_ notification: Notification) { model.text = textView.string }
  @objc func saveFile() { model.save() }
  @objc private func stopOperation() { model.cancel() }
  @objc private func reloadFile() {
    guard !model.isBusy else { return }
    if model.isDirty {
      confirm("重新读取远端文件？", detail: "当前未保存的草稿将被替换。", button: "重新读取") { [weak self] in self?.model.load() }
    } else { model.load() }
  }
  @objc private func overwriteFile() {
    confirm("覆盖最新的远端内容？", detail: "远端已被修改。此操作将用当前草稿替换最新内容，并保留最新的权限、所有者和组。", button: "覆盖并保存") { [weak self] in
      self?.model.save(overwriteChanged: true)
    }
  }
  private func confirm(_ title: String, detail: String, button: String, action: @escaping @MainActor () -> Void) {
    guard let window = view.window else { return }
    let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
    alert.addButton(withTitle: button); alert.addButton(withTitle: "取消")
    alert.beginSheetModal(for: window) { response in if response == .alertFirstButtonReturn { action() } }
  }
  @objc private func exportFile() {
    guard let window = view.window else { return }
    let panel = NSSavePanel(); panel.nameFieldStringValue = (model.path as NSString).lastPathComponent
    panel.prompt = "保存草稿"
    panel.beginSheetModal(for: window) { [weak self] response in
      guard response == .OK, let self, let url = panel.url else { return }
      do { try self.model.exportData().write(to: url, options: .atomic) }
      catch { let alert = NSAlert(error: error); alert.beginSheetModal(for: window) }
    }
  }
}

/// Retained independently of the file panel so closing a pane never drops a dirty draft.
@MainActor
final class RemoteFileEditorWindowController: NSWindowController, NSWindowDelegate, NSUserInterfaceValidations {
  private static var openEditors: [UUID: RemoteFileEditorWindowController] = [:]
  static var unsavedCount: Int { openEditors.values.filter { $0.editor.model.isDirty || ($0.editor.model.isLoaded && $0.editor.model.isBusy) }.count }
  static func cancelAll() { for editor in Array(openEditors.values) { editor.editor.model.cancel(); editor.window?.close() } }
  private let id = UUID()
  let editor: RemoteFileEditorViewController
  var onClosed: (() -> Void)?
  private var askingToClose = false
  init(model: RemoteFileEditorModel, serverName: String) {
    editor = RemoteFileEditorViewController(model: model)
    let window = NSWindow(contentViewController: editor)
    window.title = "编辑 · \(serverName) · \(model.path)"
    window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
    window.contentMinSize = NSSize(width: 560, height: 340)
    window.isReleasedWhenClosed = false; window.isRestorable = false; window.center()
    super.init(window: window)
    window.delegate = self
    editor.onChange = { [weak self] in self?.window?.isDocumentEdited = self?.editor.model.isDirty ?? false }
    Self.openEditors[id] = self
  }
  required init?(coder: NSCoder) { fatalError("unsupported") }
  @objc func saveRemoteFile(_ sender: Any?) { editor.model.save() }
  @objc func undoText(_ sender: Any?) {
    guard editor.model.isLoaded, !editor.model.isBusy else { return }
    editor.textView.undoManager?.undo()
    editor.model.text = editor.textView.string
  }
  @objc func redoText(_ sender: Any?) {
    guard editor.model.isLoaded, !editor.model.isBusy else { return }
    editor.textView.undoManager?.redo()
    editor.model.text = editor.textView.string
  }
  @objc func closeFocusedPane(_ sender: Any?) { window?.performClose(sender) }
  func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
    switch item.action {
    case #selector(saveRemoteFile): return editor.model.canSave
    case #selector(undoText): return editor.textView.undoManager?.canUndo == true && !editor.model.isBusy
    case #selector(redoText): return editor.textView.undoManager?.canRedo == true && !editor.model.isBusy
    default: return true
    }
  }
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard !editor.model.isBusy else { return false }
    guard editor.model.isDirty else { return true }
    guard !askingToClose else { return false }
    askingToClose = true
    let alert = NSAlert(); alert.messageText = "保存远端文件的更改？"
    alert.informativeText = "\(editor.model.path)\n关闭后将丢弃未保存的草稿。"
    alert.addButton(withTitle: "保存并关闭"); alert.addButton(withTitle: "放弃更改"); alert.addButton(withTitle: "取消")
    alert.beginSheetModal(for: sender) { [weak self] response in
      guard let self else { return }; askingToClose = false
      if response == .alertFirstButtonReturn {
        editor.model.save { [weak self] success in
          guard let self, success, !editor.model.isDirty else { return }
          window?.close()
        }
      }
      else if response == .alertSecondButtonReturn { window?.close() }
    }
    return false
  }
  func windowWillClose(_ notification: Notification) {
    editor.model.cancel(); Self.openEditors.removeValue(forKey: id); onClosed?()
  }
}
