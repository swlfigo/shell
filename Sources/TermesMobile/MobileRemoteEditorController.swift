import UIKit
import Combine
import TermesKit

final class MobileRemoteEditorController: MobileFormController, UITextViewDelegate, UIAdaptivePresentationControllerDelegate {
  let model: RemoteFileEditorModel
  private(set) var editor: UITextView!
  private let status = MobileUI.label("", style: .footnote, color: .secondaryLabel)
  private var subscriptions = Set<AnyCancellable>()
  init(model: RemoteFileEditorModel) { self.model = model; super.init(nibName: nil, bundle: nil) }
  required init?(coder: NSCoder) { fatalError("unsupported") }
  override func viewDidLoad() {
    super.viewDidLoad(); title = (model.path as NSString).lastPathComponent
    navigationItem.leftBarButtonItem = UIBarButtonItem(title: "关闭", primaryAction: UIAction { [weak self] _ in self?.close() })
    let save = UIBarButtonItem(title: "保存", primaryAction: UIAction { [weak self] _ in self?.model.save() })
    save.accessibilityIdentifier = "remoteEditor.save"
    let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: UIMenu(children: [
      UIAction(title: "重新读取", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in self?.reload() },
      UIAction(title: "导出草稿", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in self?.exportDraft() },
      UIAction(title: "覆盖远端修改", image: UIImage(systemName: "exclamationmark.arrow.triangle.2.circlepath")) { [weak self] _ in self?.overwrite() }
    ]))
    more.accessibilityIdentifier = "remoteEditor.menu"
    navigationItem.rightBarButtonItems = [save, more]
    content.addArrangedSubview(MobileUI.label(model.path, style: .caption1, color: .secondaryLabel))
    editor = textEditor("UTF-8 文本", id: "remoteEditor.text", height: 380); editor.delegate = self
    content.addArrangedSubview(status); content.addArrangedSubview(errorLabel)
    model.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.render() }.store(in: &subscriptions)
    model.load(); render()
  }
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated); navigationController?.presentationController?.delegate = self
  }
  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if isBeingDismissed || navigationController?.isBeingDismissed == true { model.cancel() }
  }
  func textViewDidChange(_ textView: UITextView) { model.text = textView.text; render() }
  private func render() {
    if editor.text != model.text { editor.text = model.text }
    editor.isEditable = model.isLoaded && !model.isBusy
    status.text = model.status + (model.isDirty ? " · 未保存" : "")
    errorLabel.text = model.error
    navigationItem.rightBarButtonItems?.first?.isEnabled = model.canSave
    navigationItem.rightBarButtonItems?.last?.isEnabled = !model.isBusy
    isModalInPresentation = model.isDirty || model.isBusy
    navigationController?.isModalInPresentation = isModalInPresentation
  }
  private func reload() {
    guard !model.isBusy else { return }
    if model.isDirty { confirm("放弃草稿并重新读取？", message: model.path, actionTitle: "重新读取") { [weak self] in self?.model.load() } }
    else { model.load() }
  }
  private func overwrite() {
    guard model.hasConflict, model.canSave else { return }
    confirm("覆盖服务器上的最新内容？", message: "其他位置的修改将被当前草稿替换。", actionTitle: "覆盖并保存") { [weak self] in self?.model.save(overwriteChanged: true) }
  }
  private func exportDraft() {
    do {
      let dir = MobileFileStorage.documents.appendingPathComponent("Drafts", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let url = dir.appendingPathComponent((model.path as NSString).lastPathComponent)
      try model.exportData().write(to: url, options: .atomic); share(url)
    } catch { presentError(error.localizedDescription) }
  }
  private func close() {
    if model.isDirty { confirm("放弃未保存的修改？", message: "可先通过菜单导出草稿。", actionTitle: "放弃并关闭") { [weak self] in self?.model.cancel(); self?.dismiss(animated: true) } }
    else { model.cancel(); dismiss(animated: true) }
  }
  func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) { close() }
}

final class MobilePermissionsController: MobileFormController {
  let model: RemotePermissionsModel
  private var octal: UITextField!
  private let details = MobileUI.label("", style: .footnote, color: .secondaryLabel)
  private var bits: [(UInt32, UISwitch)] = []
  private var observer: AnyCancellable?
  init(model: RemotePermissionsModel) { self.model = model; super.init(nibName: nil, bundle: nil) }
  required init?(coder: NSCoder) { fatalError("unsupported") }
  override func viewDidLoad() {
    super.viewDidLoad(); title = "文件权限"
    navigationItem.leftBarButtonItem = UIBarButtonItem(title: "取消", primaryAction: UIAction { [weak self] _ in self?.model.cancel(); self?.dismiss(animated: true) })
    navigationItem.rightBarButtonItem = UIBarButtonItem(title: "应用", primaryAction: UIAction { [weak self] _ in
      self?.model.apply { [weak self] success in if success { self?.dismiss(animated: true) } }
    })
    navigationItem.rightBarButtonItem?.accessibilityIdentifier = "permissions.apply"
    content.addArrangedSubview(MobileUI.label(model.path, style: .caption1, color: .secondaryLabel))
    content.addArrangedSubview(details)
    octal = field("八进制权限（含特殊权限位）", id: "permissions.octal"); octal.keyboardType = .numberPad
    octal.addAction(UIAction { [weak self] _ in self?.model.octal = self?.octal.text ?? "" }, for: .editingChanged)
    for (index, name) in ["所有者", "用户组", "其他人"].enumerated() {
      content.addArrangedSubview(MobileUI.label(name, style: .headline))
      for (shift, label) in [(2, "读取"), (1, "写入"), (0, "执行")] {
        let bit: UInt32 = 1 << ((2 - index) * 3 + shift)
        let toggle = UISwitch(); toggle.accessibilityLabel = "\(name)\(label)"
        toggle.addAction(UIAction { [weak self, weak toggle] _ in self?.model.setBit(bit, enabled: toggle?.isOn == true) }, for: .valueChanged)
        bits.append((bit, toggle))
        let row = MobileUI.stack([MobileUI.label(label), toggle], axis: .horizontal); row.distribution = .equalSpacing
        content.addArrangedSubview(row)
      }
    }
    content.addArrangedSubview(errorLabel)
    observer = model.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.render() }
    model.load(); render()
  }
  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if navigationController?.isBeingDismissed == true { model.cancel() }
  }
  private func render() {
    if octal.text != model.octal { octal.text = model.octal }
    octal.isEnabled = !model.isBusy && model.entry != nil
    for (bit, toggle) in bits { toggle.isOn = (model.permissions?.value ?? 0) & bit != 0; toggle.isEnabled = model.permissions != nil && !model.isBusy }
    if let entry = model.entry { details.text = "UID \(entry.ownerID.map(String.init) ?? "—") · GID \(entry.groupID.map(String.init) ?? "—")" }
    errorLabel.text = model.error ?? model.validationError
    navigationItem.rightBarButtonItem?.isEnabled = model.canApply
    navigationController?.isModalInPresentation = model.isBusy
  }
}
