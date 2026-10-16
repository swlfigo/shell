import UIKit
import SnapKit
import Combine
import TermesKit

final class MobileSettingsController: UITableViewController, UIColorPickerViewControllerDelegate {
  private let appearance: AppearanceStore
  private var subscriptions = Set<AnyCancellable>()
  private let theme = UISegmentedControl(items: ["系统", "浅色", "深色"])
  private let fontSize = UIStepper()
  private let fontSizeLabel = MobileUI.label("")

  init(appearance: AppearanceStore) { self.appearance = appearance; super.init(style: .insetGrouped) }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "设置"
    navigationItem.rightBarButtonItem = UIBarButtonItem(title: "完成", primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
    theme.accessibilityLabel = "界面外观"
    theme.addAction(UIAction { [weak self] _ in
      guard let self else { return }
      self.update { $0.theme = [.system, .light, .dark][self.theme.selectedSegmentIndex] }
    }, for: .valueChanged)
    fontSize.minimumValue = 10; fontSize.maximumValue = 28; fontSize.stepValue = 1
    fontSize.accessibilityIdentifier = "settings.fontSize"; fontSize.accessibilityLabel = "终端字号"
    fontSize.addAction(UIAction { [weak self] _ in
      guard let self else { return }; self.update { $0.terminalFontSize = self.fontSize.value }
    }, for: .valueChanged)
    appearance.$settings.receive(on: RunLoop.main).sink { [weak self] _ in self?.tableView.reloadData() }.store(in: &subscriptions)
    appearance.$error.receive(on: RunLoop.main).sink { [weak self] _ in self?.tableView.reloadData() }.store(in: &subscriptions)
    registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (controller: MobileSettingsController, _: UITraitCollection) in controller.tableView.reloadData() }
  }

  private func update(_ change: (inout AppearanceSettings) -> Void) {
    var settings = appearance.settings; change(&settings)
    // The store keeps the previous value and publishes a visible error if saving fails.
    try? appearance.update(settings)
  }

  override func numberOfSections(in tableView: UITableView) -> Int { appearance.error == nil ? 3 : 4 }
  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 1 ? 5 : section == 2 ? 3 : 1 }
  override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { ["界面", "终端", "使用提示", "保存状态"][section] }
  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
    cell.selectionStyle = .none
    if indexPath.section == 0 {
      theme.selectedSegmentIndex = appearance.settings.theme == .system ? 0 : appearance.settings.theme == .light ? 1 : 2
      cell.contentView.addSubview(theme)
      theme.snp.makeConstraints { $0.edges.equalToSuperview().inset(14) }
    } else if indexPath.section == 1 {
      switch indexPath.row {
      case 0:
        cell.textLabel?.text = "配色"; cell.detailTextLabel?.text = appearance.settings.terminalTheme.displayName
        cell.accessoryType = .disclosureIndicator; cell.selectionStyle = .default
      case 1:
        cell.textLabel?.text = "字体"; cell.detailTextLabel?.text = appearance.settings.terminalFontName ?? "系统等宽"
        cell.accessoryType = .disclosureIndicator; cell.selectionStyle = .default
        cell.accessibilityIdentifier = "settings.font"
      case 2:
        fontSize.value = appearance.settings.terminalFontSize
        fontSizeLabel.text = "字号 · \(Int(fontSize.value)) pt"
        let stack = MobileUI.stack([fontSizeLabel, fontSize], axis: .horizontal)
        stack.alignment = .center; stack.distribution = .equalSpacing
        cell.contentView.addSubview(stack)
        stack.snp.makeConstraints { $0.edges.equalToSuperview().inset(UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)) }
      case 3:
        cell.textLabel?.text = "文字颜色"
        cell.detailTextLabel?.text = appearance.settings.terminalTextColor.map { String(format: "#%06X", $0) } ?? "主题默认"
        cell.accessoryType = .disclosureIndicator; cell.selectionStyle = .default
        cell.accessibilityIdentifier = "settings.textColor"
      default:
        let preview = MobileUI.label("user@server:~ $ ls -la\nDocuments  projects  README.md")
        preview.font = appearance.settings.terminalFontName.flatMap { UIFont(name: $0, size: appearance.settings.terminalFontSize) }
          ?? .monospacedSystemFont(ofSize: appearance.settings.terminalFontSize, weight: .regular)
        let palette = appearance.settings.terminalTheme.palette(effectiveDark: traitCollection.userInterfaceStyle == .dark)
        preview.textColor = color(TerminalColor(appearance.settings.terminalTextColor ?? palette.foreground.rgb))
        cell.contentView.backgroundColor = color(palette.background)
        cell.contentView.addSubview(preview)
        preview.snp.makeConstraints { $0.edges.equalToSuperview().inset(16) }
        preview.accessibilityLabel = "终端外观预览"
      }
    } else if indexPath.section == 2 {
      var content = cell.defaultContentConfiguration()
      content.text = ["终端键盘上方提供 Esc、Tab、Ctrl 和方向键。", "返回主机列表或切换会话会保留终端。", "iOS 在后台可能暂停应用，返回后请检查连接状态。"][indexPath.row]
      content.image = UIImage(systemName: ["keyboard", "rectangle.on.rectangle", "moon"][indexPath.row])
      content.textProperties.font = .preferredFont(forTextStyle: .subheadline)
      content.imageProperties.tintColor = .secondaryLabel
      cell.contentConfiguration = content
    } else {
      cell.textLabel?.text = appearance.error; cell.textLabel?.numberOfLines = 0; cell.textLabel?.textColor = .systemRed
    }
    return cell
  }
  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    if indexPath.section == 1 && indexPath.row == 0 {
      navigationController?.pushViewController(MobileTerminalThemeController(appearance: appearance), animated: true)
    } else if indexPath.section == 1 && indexPath.row == 1 {
      let menu = UIAlertController(title: "终端字体", message: nil, preferredStyle: .actionSheet)
      let fonts: [(String, String?)] = [("系统等宽", nil), ("Source Code Pro", "SourceCodePro-Regular"), ("Menlo", "Menlo-Regular"), ("Courier New", "CourierNewPSMT")]
      for (title, name) in fonts where name == nil || UIFont(name: name!, size: 13) != nil {
        menu.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in self?.update { $0.terminalFontName = name } })
      }
      menu.addAction(UIAlertAction(title: "取消", style: .cancel))
      menu.popoverPresentationController?.sourceView = tableView; menu.popoverPresentationController?.sourceRect = tableView.rectForRow(at: indexPath)
      present(menu, animated: true)
    } else if indexPath.section == 1 && indexPath.row == 3 {
      let menu = UIAlertController(title: "文字颜色", message: nil, preferredStyle: .actionSheet)
      menu.addAction(UIAlertAction(title: "主题默认", style: .default) { [weak self] _ in self?.update { $0.terminalTextColor = nil } })
      menu.addAction(UIAlertAction(title: "选择颜色", style: .default) { [weak self] _ in
        guard let self else { return }
        let picker = UIColorPickerViewController(); picker.delegate = self; picker.supportsAlpha = false
        let palette = appearance.settings.terminalTheme.palette(effectiveDark: traitCollection.userInterfaceStyle == .dark)
        picker.selectedColor = color(TerminalColor(appearance.settings.terminalTextColor ?? palette.foreground.rgb))
        present(picker, animated: true)
      })
      menu.addAction(UIAlertAction(title: "取消", style: .cancel))
      menu.popoverPresentationController?.sourceView = tableView; menu.popoverPresentationController?.sourceRect = tableView.rectForRow(at: indexPath)
      present(menu, animated: true)
    }
  }
  func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    guard viewController.selectedColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return }
    func byte(_ value: CGFloat) -> UInt32 { UInt32(max(0, min(255, (value * 255).rounded()))) }
    let rgb = byte(red) << 16 | byte(green) << 8 | byte(blue)
    update { $0.terminalTextColor = rgb }
  }
  private func color(_ color: TerminalColor) -> UIColor {
    UIColor(red: Double(color.red) / 255, green: Double(color.green) / 255, blue: Double(color.blue) / 255, alpha: color.alpha)
  }
}

private final class MobileTerminalThemeController: UITableViewController {
  private let appearance: AppearanceStore
  init(appearance: AppearanceStore) { self.appearance = appearance; super.init(style: .insetGrouped) }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func viewDidLoad() { super.viewDidLoad(); title = "终端配色" }
  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { TerminalTheme.catalog.count }
  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let theme = TerminalTheme.catalog[indexPath.row]
    let cell = UITableViewCell()
    cell.textLabel?.text = theme.displayName
    cell.accessoryType = theme == appearance.settings.terminalTheme ? .checkmark : .none
    return cell
  }
  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    var settings = appearance.settings; settings.terminalTheme = TerminalTheme.catalog[indexPath.row]
    do { try appearance.update(settings); navigationController?.popViewController(animated: true) }
    catch { presentError(appearance.error ?? error.localizedDescription) }
  }
}
