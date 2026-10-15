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
  func presentError(_ message: String) {
    let alert = UIAlertController(title: "无法完成操作", message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "好", style: .cancel))
    present(alert, animated: true)
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
