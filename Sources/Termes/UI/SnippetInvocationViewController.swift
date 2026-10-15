import AppKit
import SnapKit
import TermesKit

/// Parameter values live only in this sheet; the resolved script is shown before insertion.
@MainActor
final class SnippetInvocationViewController: NSViewController, NSTextFieldDelegate {
  let snippet: Snippet
  private let destination: String
  private(set) var parameterFields: [String: NSTextField] = [:]
  let preview = NSTextView()
  let errorLabel = NSTextField(wrappingLabelWithString: "")
  let insertButton = NSButton(title: "插入终端", target: nil, action: nil)
  var onInsert: (([String: String]) throws -> Void)?
  var onDismiss: (() -> Void)?
  private var finished = false

  init(snippet: Snippet, destination: String) {
    self.snippet = snippet; self.destination = destination
    super.init(nibName: nil, bundle: nil)
  }
  required init?(coder: NSCoder) { fatalError("unsupported") }

  override func loadView() {
    view = NSView(frame: NSRect(x: 0, y: 0, width: 660, height: 500))
    let stack = NSStackView()
    stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
    view.addSubview(stack)
    stack.snp.makeConstraints { make in make.edges.equalToSuperview().inset(20).labeled("SnippetInvocation.column") }
    let title = NSTextField(wrappingLabelWithString: "\(snippet.name) → \(destination)")
    title.font = .boldSystemFont(ofSize: 14)
    title.maximumNumberOfLines = 2; title.lineBreakMode = .byTruncatingTail
    title.toolTip = title.stringValue
    stack.addArrangedSubview(title)
    title.snp.makeConstraints { make in make.width.equalTo(stack.snp.width) }
    if !snippet.parameterNames.isEmpty {
      let fields = NSStackView()
      fields.orientation = .vertical; fields.alignment = .leading; fields.spacing = 8
      for name in snippet.parameterNames {
        let field = NSTextField()
        field.delegate = self
        field.usesSingleLineMode = true
        field.setAccessibilityLabel("参数 " + name)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        parameterFields[name] = field
        let label = NSTextField(labelWithString: name)
        label.snp.makeConstraints { make in make.width.equalTo(120) }
        label.lineBreakMode = .byTruncatingTail; label.toolTip = name
        let row = NSStackView(views: [label, field]); row.spacing = 8
        fields.addArrangedSubview(row)
        row.snp.makeConstraints { make in make.width.equalTo(fields.snp.width) }
      }
      let scroll = NSScrollView()
      scroll.hasVerticalScroller = true; scroll.scrollerStyle = .legacy
      let document = SnippetParameterDocumentView()
      scroll.documentView = document
      document.addSubview(fields)
      document.snp.makeConstraints { make in make.width.equalTo(scroll.contentView.snp.width) }
      fields.snp.makeConstraints { make in make.edges.equalToSuperview() }
      stack.addArrangedSubview(scroll)
      scroll.snp.makeConstraints { make in
        make.width.equalTo(stack.snp.width)
        make.height.equalTo(min(150, CGFloat(snippet.parameterNames.count) * 30))
      }
    }
    let hint = NSTextField(wrappingLabelWithString: snippet.kind == .script
      ? "核对脚本后插入；终端中按回车执行。参数按原文替换，本次输入不会保存。脚本需要 POSIX 兼容的 shell（如 sh、bash、zsh）。"
      : "核对命令后插入；终端中按回车执行。参数按原文替换，本次输入不会保存。")
    hint.textColor = .secondaryLabelColor
    hint.maximumNumberOfLines = 3
    stack.addArrangedSubview(hint)
    hint.snp.makeConstraints { make in make.width.equalTo(stack.snp.width) }
    preview.isEditable = false; preview.isRichText = false
    preview.isVerticallyResizable = true
    preview.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    preview.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    preview.isHorizontallyResizable = false
    preview.textContainer?.widthTracksTextView = true
    preview.autoresizingMask = [.width]
    preview.setAccessibilityLabel("插入内容预览")
    let scroll = NSScrollView()
    scroll.documentView = preview; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
    stack.addArrangedSubview(scroll)
    scroll.snp.makeConstraints { make in
      make.width.equalTo(stack.snp.width)
      make.height.greaterThanOrEqualTo(120)
    }
    scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
    errorLabel.textColor = .systemRed
    errorLabel.maximumNumberOfLines = 3
    errorLabel.isHidden = true
    stack.addArrangedSubview(errorLabel)
    errorLabel.snp.makeConstraints { make in make.width.equalTo(stack.snp.width) }
    let cancel = NSButton(title: "取消", target: self, action: #selector(cancelTapped))
    cancel.keyEquivalent = "\u{1b}"
    insertButton.target = self; insertButton.action = #selector(insertTapped)
    for button in [cancel, insertButton] { button.bezelStyle = .rounded }
    stack.addArrangedSubview(NSStackView(views: [cancel, insertButton]))
    refreshPreview()
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    if let scroll = preview.enclosingScrollView {
      preview.minSize = scroll.contentSize
      preview.setFrameSize(NSSize(width: scroll.contentSize.width,
        height: max(preview.frame.height, scroll.contentSize.height)))
      preview.sizeToFit()
    }
  }

  var parameters: [String: String] { parameterFields.mapValues(\.stringValue) }

  func controlTextDidChange(_ obj: Notification) { refreshPreview() }

  func refreshPreview() {
    do {
      preview.string = try snippet.resolvedCommand(parameters: parameters)
      insertButton.isEnabled = !finished
      errorLabel.isHidden = true
    } catch {
      preview.string = ""
      insertButton.isEnabled = false
      showError(error)
    }
  }

  @discardableResult
  func insert() -> Bool {
    _ = view
    guard !finished else { return false }
    view.window?.makeFirstResponder(nil)
    do {
      _ = try snippet.insertionCommand(parameters: parameters)
      guard let onInsert else { return false }
      try onInsert(parameters)
      finished = true
      insertButton.isEnabled = false
      onDismiss?()
      return true
    } catch { showError(error); return false }
  }

  func cancel() {
    guard !finished else { return }
    finished = true
    insertButton.isEnabled = false
    onDismiss?()
  }

  private func showError(_ error: Error) {
    errorLabel.stringValue = error.localizedDescription; errorLabel.isHidden = false
  }
  @objc private func insertTapped() { insert() }
  @objc private func cancelTapped() { cancel() }
}

private final class SnippetParameterDocumentView: NSView {
  override var isFlipped: Bool { true }
}
