import UIKit
import SnapKit
import TermesKit

@MainActor
enum MobileUI {
  static func label(_ text: String, style: UIFont.TextStyle = .body, color: UIColor = .label) -> UILabel {
    let label = UILabel()
    label.text = text; label.font = .preferredFont(forTextStyle: style)
    label.adjustsFontForContentSizeCategory = true
    label.textColor = color; label.numberOfLines = 0
    return label
  }

  static func stack(_ views: [UIView] = [], axis: NSLayoutConstraint.Axis = .vertical, spacing: CGFloat = 12) -> UIStackView {
    let stack = UIStackView(arrangedSubviews: views)
    stack.axis = axis; stack.spacing = spacing
    return stack
  }

  static func button(_ title: String, symbol: String? = nil, filled: Bool = false,
                     id: String? = nil, action: @escaping () -> Void) -> UIButton {
    var configuration: UIButton.Configuration = filled ? .filled() : .tinted()
    configuration.title = title
    configuration.image = symbol.flatMap(UIImage.init(systemName:))
    configuration.imagePadding = 8
    configuration.cornerStyle = .medium
    configuration.contentInsets = .init(top: 12, leading: 16, bottom: 12, trailing: 16)
    let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
    button.accessibilityIdentifier = id
    return button
  }

  static func symbol(_ name: String, size: CGFloat = 42) -> UIImageView {
    let view = UIImageView(image: UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size)))
    view.contentMode = .scaleAspectFit; view.tintColor = .systemTeal
    view.snp.makeConstraints { $0.height.equalTo(size + 8) }
    return view
  }
}

extension UIViewController {
  func presentSheet(_ controller: UIViewController) {
    let navigation = UINavigationController(rootViewController: controller)
    navigation.modalPresentationStyle = .formSheet
    navigation.preferredContentSize = CGSize(width: 760, height: 820)
    present(navigation, animated: true)
  }

  func prompt(_ title: String, value: String = "", message: String? = nil, actionTitle: String = "保存",
              action: @escaping (String) -> Void) {
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addTextField { $0.text = value; $0.autocorrectionType = .no; $0.autocapitalizationType = .none }
    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
    alert.addAction(UIAlertAction(title: actionTitle, style: .default) { _ in action(alert.textFields?.first?.text ?? "") })
    present(alert, animated: true)
  }

  func confirm(_ title: String, message: String, actionTitle: String = "删除", action: @escaping () -> Void) {
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
    alert.addAction(UIAlertAction(title: actionTitle, style: .destructive) { _ in action() })
    present(alert, animated: true)
  }

  func share(_ url: URL, source: UIView? = nil) {
    let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
    controller.popoverPresentationController?.sourceView = source ?? view
    controller.popoverPresentationController?.sourceRect = (source ?? view).bounds
    present(controller, animated: true)
  }

  func presentError(_ message: String) {
    let alert = UIAlertController(title: "无法完成操作", message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "好", style: .cancel))
    present(alert, animated: true)
  }
}

/// Shared scrollable form layout for the mobile management screens.
class MobileFormController: UIViewController {
  let content = MobileUI.stack(spacing: 18)
  let errorLabel = MobileUI.label("", style: .subheadline, color: .systemRed)
  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemGroupedBackground
    navigationItem.largeTitleDisplayMode = .never
    let scroll = UIScrollView(); scroll.keyboardDismissMode = .interactive
    view.addSubview(scroll)
    scroll.snp.makeConstraints { make in
      make.top.leading.trailing.equalTo(view.safeAreaLayoutGuide)
      make.bottom.equalTo(view.keyboardLayoutGuide.snp.top)
    }
    scroll.addSubview(content)
    content.snp.makeConstraints { make in
      make.edges.equalTo(scroll.contentLayoutGuide).inset(20)
      make.width.equalTo(scroll.frameLayoutGuide).offset(-40)
    }
    errorLabel.accessibilityIdentifier = "form.error"
  }
  func field(_ title: String, text: String = "", id: String? = nil, secure: Bool = false) -> UITextField {
    let field = UITextField()
    field.text = text; field.placeholder = title; field.borderStyle = .roundedRect
    field.autocapitalizationType = .none; field.autocorrectionType = .no
    field.isSecureTextEntry = secure; field.accessibilityIdentifier = id
    field.accessibilityLabel = title
    content.addArrangedSubview(MobileUI.stack([MobileUI.label(title, style: .subheadline), field], spacing: 6))
    field.snp.makeConstraints { $0.height.greaterThanOrEqualTo(44) }
    return field
  }
  func textEditor(_ title: String, text: String = "", id: String, height: CGFloat = 220) -> UITextView {
    let editor = UITextView()
    editor.text = text; editor.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
    editor.backgroundColor = .secondarySystemGroupedBackground; editor.layer.cornerRadius = 10
    editor.autocapitalizationType = .none; editor.autocorrectionType = .no
    editor.smartQuotesType = .no; editor.smartDashesType = .no
    editor.accessibilityLabel = title; editor.accessibilityIdentifier = id
    content.addArrangedSubview(MobileUI.stack([MobileUI.label(title, style: .subheadline), editor], spacing: 6))
    editor.snp.makeConstraints { $0.height.equalTo(height) }
    return editor
  }
}

extension SessionManager.State {
  var mobileColor: UIColor {
    switch status {
    case .connected: return .systemGreen
    case .pending: return .systemOrange
    case .problem: return .systemRed
    case .idle: return .secondaryLabel
    }
  }
}
