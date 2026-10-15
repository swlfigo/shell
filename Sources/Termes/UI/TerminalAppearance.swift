import AppKit
import CoreText
import TermesKit
import SwiftTerm

extension TerminalColor {
  var nativeColor: NSColor {
    .init(srgbRed: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255, alpha: alpha)
  }
  var terminalColor: SwiftTerm.Color { .init(red: UInt16(red) * 257, green: UInt16(green) * 257, blue: UInt16(blue) * 257) }
}

@MainActor
enum TerminalFonts {
  struct Choice: Equatable { let name: String?, title: String }
  private static var registered = false
  static func registerBundledFonts() {
    guard !registered else { return }; registered = true
    #if SWIFT_PACKAGE
    let bundle = Bundle.module
    #else
    let bundle = Bundle.main
    #endif
    for name in ["Regular", "Bold", "It", "BoldIt"] {
      if let url = bundle.url(forResource: "SourceCodePro-\(name)", withExtension: "otf") {
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
      }
    }
  }
  static func resolve(name: String?, size: Double) -> NSFont {
    registerBundledFonts()
    if let name, let font = NSFont(name: name, size: size), font.isFixedPitch { return font }
    return .monospacedSystemFont(ofSize: size, weight: .regular)
  }
  static func isAvailable(_ name: String?) -> Bool {
    registerBundledFonts()
    guard let name else { return true }
    return NSFont(name: name, size: 13)?.isFixedPitch == true
  }
  static func choices() -> [Choice] {
    registerBundledFonts()
    let manager = NSFontManager.shared
    let available = manager.availableFontFamilies.compactMap { family -> Choice? in
      guard let font = manager.font(withFamily: family, traits: [], weight: 5, size: 13), font.isFixedPitch else { return nil }
      return .init(name: font.fontName, title: family)
    }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    return [.init(name: nil, title: "系统等宽字体")] + available
  }
}

@MainActor
func applyTerminalPalette(_ palette: TerminalPalette, to view: TerminalView) {
  // SwiftTerm's adaptive palette rebuilds on foreground changes and loses OSC color
  // overrides. Keep the standard xterm 256-color extension independent of text color.
  view.getTerminal().ansi256PaletteStrategy = .xterm
  view.nativeBackgroundColor = palette.background.nativeColor
  view.nativeForegroundColor = palette.foreground.nativeColor
  view.installColors(palette.ansi.map(\.terminalColor))
  view.caretColor = palette.cursor.nativeColor; view.caretTextColor = palette.background.nativeColor
  view.selectedTextBackgroundColor = palette.selection.nativeColor
  view.selectedTextForegroundColor = palette.selectionForeground.nativeColor
  view.needsDisplay = true
}
