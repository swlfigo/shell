import AppKit
import TermesKit
import SnapKit

/// A sheet for non-secret fields. Credentials remain in the connection page.
@MainActor
final class ConnectionEditorViewController: NSViewController {
  private let profiles: ConnectionProfileService
  private let profile: ConnectionProfile
  private let onDismiss: () -> Void
  let nameField = NSTextField()
  let hostField = NSTextField()
  let portField = NSTextField()
  let userField = NSTextField()
  let jumpPopup = JumpHostPopup()
  let errorLabel = NSTextField(wrappingLabelWithString: "")

  init(profile: ConnectionProfile, profiles: ConnectionProfileService, onDismiss: @escaping () -> Void) {
    self.profile = profile
    self.profiles = profiles
    self.onDismiss = onDismiss
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError("unsupported") }

  override func loadView() {
    view = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 360))
    nameField.stringValue = profile.name
    hostField.stringValue = profile.hostname
    portField.stringValue = String(profile.port)
    userField.stringValue = profile.username
    jumpPopup.reload((try? profiles.profiles()) ?? [], selected: profile.jumpProfileId, excluding: profile.id)
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    for (title, field) in [("名称", nameField), ("主机", hostField), ("端口", portField), ("用户名", userField)] {
      let label = NSTextField(labelWithString: title)
      label.snp.makeConstraints { make in make.width.equalTo(60) }
      let row = NSStackView(views: [label, field])
      row.spacing = 8
      field.setContentHuggingPriority(.defaultLow, for: .horizontal)
      field.setAccessibilityLabel(title)
      stack.addArrangedSubview(row)
      row.snp.makeConstraints { make in make.width.equalTo(stack.snp.width) }
    }
    let jumpLabel = NSTextField(labelWithString: "跳板机")
    jumpLabel.snp.makeConstraints { make in make.width.equalTo(60) }
    let jumpRow = NSStackView(views: [jumpLabel, jumpPopup])
    jumpRow.spacing = 8
    stack.addArrangedSubview(jumpRow)
    jumpRow.snp.makeConstraints { make in make.width.equalTo(stack.snp.width) }
    errorLabel.textColor = .systemRed
    errorLabel.preferredMaxLayoutWidth = 400
    errorLabel.isHidden = true
    stack.addArrangedSubview(errorLabel)
    errorLabel.snp.makeConstraints { make in make.width.equalTo(stack.snp.width) }
    let cancel = NSButton(title: "取消", target: self, action: #selector(cancelTapped))
    cancel.keyEquivalent = "\u{1b}"
    let save = NSButton(title: "保存", target: self, action: #selector(saveTapped))
    save.keyEquivalent = "\r"
    cancel.bezelStyle = .rounded
    save.bezelStyle = .rounded
    stack.addArrangedSubview(NSStackView(views: [cancel, save]))
    view.addSubview(stack)
    stack.snp.makeConstraints { make in
      make.leading.trailing.top.equalToSuperview().inset(20).labeled("ConnectionEditor.form")
      make.bottom.lessThanOrEqualToSuperview().inset(20)
    }
  }

  override func viewDidAppear() {
    super.viewDidAppear()
    view.window?.makeFirstResponder(nameField)
  }

  /// Validation errors keep the sheet open and preserve the user's draft.
  @discardableResult
  func saveChanges() -> Bool {
    _ = view
    do {
      guard let port = Int(portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        throw ProfileServiceError.invalidConnection
      }
      try profiles.updateConnection(profile.id, name: nameField.stringValue,
        hostname: hostField.stringValue, port: port, username: userField.stringValue,
        jumpProfileId: jumpPopup.selectedProfileId)
      onDismiss()
      return true
    } catch {
      errorLabel.stringValue = error.localizedDescription
      errorLabel.isHidden = false
      return false
    }
  }

  @objc private func saveTapped() { saveChanges() }
  @objc private func cancelTapped() { onDismiss() }
}

/// Missing selections stay explicit rather than silently changing a draft to direct SSH.
@MainActor
final class JumpHostPopup: NSPopUpButton {
  private var ids: [UUID] = []
  var selectedProfileId: UUID? {
    let index = indexOfSelectedItem - 1
    return ids.indices.contains(index) ? ids[index] : nil
  }
  init() {
    super.init(frame: .zero, pullsDown: false)
    setAccessibilityLabel("跳板机")
    setContentHuggingPriority(.defaultLow, for: .horizontal)
    setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    toolTip = "复用已保存连接的凭据；目标主机地址由最后一台跳板机解析"
  }
  required init?(coder: NSCoder) { fatalError("unsupported") }
  func reload(_ profiles: [ConnectionProfile], selected: UUID?, excluding: UUID? = nil) {
    removeAllItems()
    addItem(withTitle: "直接连接")
    ids = []
    for profile in profiles where profile.id != excluding {
      ids.append(profile.id)
      addItem(withTitle: "\(profile.name) · \(profile.username)@\(profile.hostname):\(profile.port)")
    }
    if let selected {
      if !ids.contains(selected) {
        ids.append(selected)
        addItem(withTitle: "跳板机已不可用（请重新选择）")
      }
      if let index = ids.firstIndex(of: selected) { selectItem(at: index + 1) }
    } else { selectItem(at: 0) }
  }
}
