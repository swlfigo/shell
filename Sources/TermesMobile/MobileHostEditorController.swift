import UIKit
import SnapKit
import UniformTypeIdentifiers
import TermesKit

final class MobileHostEditorController: UITableViewController, UITextFieldDelegate, UITextViewDelegate, UIDocumentPickerDelegate {
  var onSave: ((ConnectionProfile, Bool) -> Void)?
  private let workspace: MobileWorkspace
  private var draft: MobileHostDraft
  private var errorMessage: String?
  private let nameField = UITextField(), hostField = UITextField(), portField = UITextField(), userField = UITextField()
  private let passwordField = UITextField(), keyNameField = UITextField(), passphraseField = UITextField()
  private let keyText = UITextView()
  private var saveButton: UIBarButtonItem!
  private lazy var connectButton = MobileUI.button("保存并连接", symbol: "terminal", filled: true,
    id: "hostEditor.saveConnect") { [weak self] in self?.save(connect: true) }

  init(workspace: MobileWorkspace, profile: ConnectionProfile?) {
    self.workspace = workspace; draft = MobileHostDraft(profile: profile)
    super.init(style: .insetGrouped)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = draft.profileID == nil ? "新建主机" : "编辑主机"
    navigationItem.largeTitleDisplayMode = .never
    let cancel = UIBarButtonItem(title: "取消", primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
    cancel.accessibilityIdentifier = "hostEditor.cancel"
    navigationItem.leftBarButtonItem = cancel
    saveButton = UIBarButtonItem(title: "保存", primaryAction: UIAction { [weak self] _ in self?.save(connect: false) })
    saveButton.accessibilityIdentifier = "hostEditor.save"
    navigationItem.rightBarButtonItem = saveButton
    configure(nameField, placeholder: "名称", text: draft.name, id: "hostEditor.name")
    configure(hostField, placeholder: "主机地址", text: draft.hostname, id: "hostEditor.hostname")
    configure(portField, placeholder: "端口", text: draft.port, id: "hostEditor.port")
    configure(userField, placeholder: "用户名", text: draft.username, id: "hostEditor.username")
    configure(passwordField, placeholder: "登录密码", id: "hostEditor.password")
    configure(keyNameField, placeholder: "私钥名称（可选）")
    configure(passphraseField, placeholder: "私钥口令（可选）")
    hostField.keyboardType = .URL; portField.keyboardType = .numberPad
    userField.textContentType = .username
    passwordField.isSecureTextEntry = true; passwordField.textContentType = .password
    passphraseField.isSecureTextEntry = true
    keyText.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    keyText.autocorrectionType = .no; keyText.autocapitalizationType = .none
    keyText.smartQuotesType = .no; keyText.smartDashesType = .no
    keyText.delegate = self; keyText.accessibilityLabel = "私钥内容"
    keyText.backgroundColor = .secondarySystemGroupedBackground
    tableView.keyboardDismissMode = .interactive
    updateDraft()
  }

  private func configure(_ field: UITextField, placeholder: String, text: String = "", id: String? = nil) {
    field.placeholder = placeholder; field.text = text
    field.accessibilityIdentifier = id
    field.font = .preferredFont(forTextStyle: .body); field.adjustsFontForContentSizeCategory = true
    field.autocapitalizationType = .none; field.autocorrectionType = .no
    field.smartQuotesType = .no; field.smartDashesType = .no
    field.clearButtonMode = .whileEditing; field.returnKeyType = .next
    field.delegate = self
    field.addAction(UIAction { [weak self] _ in self?.updateDraft() }, for: .editingChanged)
  }

  private func updateDraft() {
    draft.name = nameField.text ?? ""; draft.hostname = hostField.text ?? ""
    draft.port = portField.text ?? ""; draft.username = userField.text ?? ""
    draft.password = passwordField.text ?? ""; draft.keyName = keyNameField.text ?? ""
    draft.passphrase = passphraseField.text ?? ""; draft.privateKey = keyText.text
    saveButton.isEnabled = draft.hasValidAddress; connectButton.isEnabled = draft.hasValidAddress
  }
  func textViewDidChange(_ textView: UITextView) { updateDraft() }
  func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    let fields = [nameField, hostField, portField, userField, passwordField, keyNameField, passphraseField]
    if let index = fields.firstIndex(of: textField), index + 1 < fields.count, fields[index + 1].window != nil {
      fields[index + 1].becomeFirstResponder()
    } else { textField.resignFirstResponder() }
    return true
  }

  override func numberOfSections(in tableView: UITableView) -> Int { 4 }
  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    switch section {
    case 0: return 4
    case 1:
      let toggle = draft.profileID == nil ? 0 : 1
      guard draft.replaceCredential else { return toggle }
      return toggle + (draft.authentication == .privateKey ? 5 : 2)
    default: return 1
    }
  }
  override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    ["主机", "身份认证", "连接路由", nil][section]
  }
  override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
    switch section {
    case 1: return draft.replaceCredential ? "密码、私钥和口令保存在此设备的系统钥匙串中。" : "保留此设备已保存的凭据。"
    case 2: return "需要通过其他服务器访问内网主机时，选择已保存的跳板机。"
    case 3: return errorMessage
    default: return nil
    }
  }
  override func tableView(_ tableView: UITableView, willDisplayFooterView view: UIView, forSection section: Int) {
    if section == 3 { (view as? UITableViewHeaderFooterView)?.textLabel?.textColor = .systemRed }
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    if indexPath.section == 0 {
      return inputCell(["名称", "地址", "端口", "用户名"][indexPath.row], field: [nameField, hostField, portField, userField][indexPath.row])
    }
    if indexPath.section == 2 {
      return choiceCell("跳板机", value: workspace.hosts.first { $0.id == draft.jumpProfileID }?.name ?? "直接连接")
    }
    if indexPath.section == 3 {
      let cell = UITableViewCell(); cell.selectionStyle = .none
      cell.contentView.addSubview(connectButton)
      connectButton.snp.makeConstraints { $0.edges.equalToSuperview().inset(8) }
      return cell
    }
    var row = indexPath.row
    if draft.profileID != nil {
      if row == 0 {
        let cell = choiceCell("更新登录凭据", value: nil)
        cell.selectionStyle = .none
        let toggle = UISwitch(); toggle.isOn = draft.replaceCredential
        toggle.accessibilityLabel = "更新登录凭据"
        toggle.addAction(UIAction { [weak self, weak toggle] _ in
          guard let self, let toggle else { return }
          self.view.endEditing(true); self.draft.replaceCredential = toggle.isOn
          self.tableView.reloadSections(IndexSet(integer: 1), with: .automatic)
        }, for: .valueChanged)
        cell.accessoryView = toggle
        return cell
      }
      row -= 1
    }
    if row == 0 { return choiceCell("认证方式", value: draft.authentication.rawValue) }
    switch draft.authentication {
    case .password: return inputCell("密码", field: passwordField)
    case .existingKey:
      return choiceCell("私钥", value: workspace.keys.first { $0.id == draft.existingKeyID }?.name ?? "选择私钥")
    case .privateKey:
      switch row {
      case 1: return choiceCell("从“文件”导入", value: nil)
      case 2: return inputCell("名称", field: keyNameField)
      case 3:
        let cell = UITableViewCell(); cell.selectionStyle = .none
        cell.contentView.addSubview(keyText)
        keyText.snp.makeConstraints { $0.edges.equalToSuperview().inset(8); $0.height.equalTo(140) }
        return cell
      default: return inputCell("口令", field: passphraseField)
      }
    }
  }

  private func inputCell(_ title: String, field: UITextField) -> UITableViewCell {
    let cell = UITableViewCell(); cell.selectionStyle = .none
    let label = MobileUI.label(title, style: .subheadline, color: .secondaryLabel)
    label.snp.makeConstraints { $0.width.equalTo(68) }
    let stack = MobileUI.stack([label, field], axis: .horizontal)
    stack.alignment = .center
    cell.contentView.addSubview(stack)
    stack.snp.makeConstraints { $0.edges.equalToSuperview().inset(UIEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)) }
    return cell
  }
  private func choiceCell(_ title: String, value: String?) -> UITableViewCell {
    let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
    cell.textLabel?.text = title; cell.detailTextLabel?.text = value
    cell.accessoryType = .disclosureIndicator
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    if indexPath.section == 2 {
      var choices: [(String, () -> Void)] = [("直接连接", { [weak self] in self?.draft.jumpProfileID = nil })]
      choices += workspace.hosts.filter { $0.id != draft.profileID }.map { profile in
        (profile.name, { [weak self] in self?.draft.jumpProfileID = profile.id })
      }
      choose("跳板机", choices: choices, at: indexPath)
      return
    }
    guard indexPath.section == 1 else { return }
    let row = indexPath.row - (draft.profileID == nil ? 0 : 1)
    if row == 0 {
      choose("认证方式", choices: MobileHostDraft.Authentication.allCases.map { method in
        (method.rawValue, { [weak self] in self?.draft.authentication = method })
      }, at: indexPath)
    } else if row == 1, draft.authentication == .existingKey {
      guard !workspace.keys.isEmpty else { presentError("尚未保存私钥，请选择“导入私钥”。"); return }
      choose("选择私钥", choices: workspace.keys.map { key in
        (key.name, { [weak self] in self?.draft.existingKeyID = key.id })
      }, at: indexPath)
    } else if row == 1, draft.authentication == .privateKey {
      view.endEditing(true)
      let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
      picker.delegate = self
      present(picker, animated: true)
    }
  }

  private func choose(_ title: String, choices: [(String, () -> Void)], at index: IndexPath) {
    view.endEditing(true)
    let alert = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
    for (title, action) in choices {
      alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in action(); self?.tableView.reloadData() })
    }
    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
    alert.popoverPresentationController?.sourceView = tableView.cellForRow(at: index)
    alert.popoverPresentationController?.sourceRect = tableView.cellForRow(at: index)?.bounds ?? .zero
    present(alert, animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let url = urls.first else { return }
    do {
      let scoped = url.startAccessingSecurityScopedResource()
      defer { if scoped { url.stopAccessingSecurityScopedResource() } }
      let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      guard size <= 1_048_576 else { throw MobileValidationError.invalidKey }
      let data = try Data(contentsOf: url)
      guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8) else { throw MobileValidationError.invalidKey }
      keyText.text = text; keyNameField.text = url.lastPathComponent
      updateDraft()
    } catch { errorMessage = error.localizedDescription; tableView.reloadData() }
  }

  private func save(connect: Bool) {
    updateDraft(); view.endEditing(true)
    do { onSave?(try workspace.save(draft), connect) }
    catch {
      errorMessage = error.localizedDescription; tableView.reloadData()
      tableView.scrollToRow(at: IndexPath(row: 0, section: 3), at: .middle, animated: true)
    }
  }
}
