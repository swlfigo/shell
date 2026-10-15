import AppKit
import Combine
import TermesKit
import SSHCore

@MainActor
final class RemotePermissionsViewController: NSViewController, NSTextFieldDelegate {
  let model: RemotePermissionsModel
  var onDismiss: (() -> Void)?
  let modeField = NSTextField()
  private let pathLabel = NSTextField(labelWithString: "")
  private let ownerLabel = NSTextField(labelWithString: "")
  private let status = NSTextField(wrappingLabelWithString: "")
  private let symbolic = NSTextField(labelWithString: "")
  private var checks: [NSButton] = []
  private var observer: AnyCancellable?
  private lazy var apply = NSButton(title: "应用权限", target: self, action: #selector(applyMode))
  private lazy var reload = NSButton(title: "重新读取", target: self, action: #selector(reloadMode))
  private lazy var cancel = NSButton(title: "取消", target: self, action: #selector(cancelMode))
  init(model: RemotePermissionsModel) { self.model = model; super.init(nibName: nil, bundle: nil) }
  required init?(coder: NSCoder) { fatalError("unsupported") }
  override func loadView() {
    view = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 344))
    pathLabel.stringValue = model.path; pathLabel.lineBreakMode = .byTruncatingMiddle
    pathLabel.frame = NSRect(x: 20, y: 308, width: 400, height: 20)
    ownerLabel.frame = NSRect(x: 20, y: 282, width: 400, height: 18); ownerLabel.font = .systemFont(ofSize: 11)
    let label = NSTextField(labelWithString: "八进制权限")
    label.frame = NSRect(x: 20, y: 250, width: 90, height: 22)
    modeField.frame = NSRect(x: 116, y: 248, width: 90, height: 24)
    modeField.delegate = self; modeField.placeholderString = "0644"; modeField.setAccessibilityLabel("八进制权限")
    symbolic.frame = NSRect(x: 220, y: 250, width: 180, height: 20); symbolic.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    for (row, group) in ["所有者", "组", "其他用户"].enumerated() {
      let title = NSTextField(labelWithString: group); title.frame = NSRect(x: 20, y: 212 - CGFloat(row) * 32, width: 90, height: 22)
      view.addSubview(title)
      for (column, name) in ["读", "写", "执行"].enumerated() {
        let bit: UInt32 = 1 << UInt32(8 - row * 3 - column)
        let button = NSButton(checkboxWithTitle: name, target: self, action: #selector(bitChanged))
        button.tag = Int(bit); button.setAccessibilityLabel("\(group) \(name)权限")
        button.frame = NSRect(x: 116 + CGFloat(column) * 92, y: 210 - CGFloat(row) * 32, width: 90, height: 24)
        checks.append(button); view.addSubview(button)
      }
    }
    for (index, item) in [("setuid", UInt32(0o4000)), ("setgid", 0o2000), ("sticky", 0o1000)].enumerated() {
      let button = NSButton(checkboxWithTitle: item.0, target: self, action: #selector(bitChanged)); button.tag = Int(item.1)
      button.frame = NSRect(x: 20 + CGFloat(index) * 132, y: 108, width: 130, height: 24)
      checks.append(button); view.addSubview(button)
    }
    status.frame = NSRect(x: 20, y: 52, width: 400, height: 48); status.font = .systemFont(ofSize: 11)
    for (index, button) in [reload, cancel, apply].enumerated() {
      button.bezelStyle = .rounded; button.frame = NSRect(x: 20 + CGFloat(index) * 134, y: 12, width: 128, height: 30)
    }
    for child in [pathLabel, ownerLabel, label, modeField, symbolic, status, reload, cancel, apply] { view.addSubview(child) }
    observer = model.objectWillChange.sink { [weak self] in
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.render() } }
    }
    render(); model.load()
  }
  private func render() {
    if modeField.stringValue != model.octal { modeField.stringValue = model.octal }
    modeField.isEnabled = !model.isBusy && model.entry != nil
    symbolic.stringValue = model.permissions?.symbolic ?? "—"
    ownerLabel.stringValue = "UID：\(model.entry?.ownerID.map(String.init) ?? "—")  ·  GID：\(model.entry?.groupID.map(String.init) ?? "—")"
    for button in checks {
      button.state = (model.permissions?.value ?? 0) & UInt32(button.tag) == 0 ? .off : .on
      button.isEnabled = !model.isBusy && model.permissions != nil
    }
    apply.isEnabled = model.canApply; reload.isEnabled = !model.isBusy
    status.stringValue = model.validationError ?? model.error ?? (model.isBusy ? "正在处理…" : "仅修改当前文件或目录的权限，不递归修改子项。")
    status.textColor = model.error != nil || model.validationError != nil ? .systemRed : .secondaryLabelColor
  }
  func controlTextDidChange(_ obj: Notification) { model.octal = modeField.stringValue }
  @objc private func bitChanged(_ sender: NSButton) { model.setBit(UInt32(sender.tag), enabled: sender.state == .on) }
  @objc private func reloadMode() { model.load() }
  @objc private func applyMode() { model.apply { [weak self] success in if success { self?.finish() } } }
  @objc private func cancelMode() { model.cancel(); finish() }
  private func finish() { onDismiss?(); dismiss(self) }
}
