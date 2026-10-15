import AppKit
import XCTest
import TermesKit
import SSHCore
import SwiftTerm
@testable import Termes

@MainActor
private final class PaletteProbe: @preconcurrency TerminalViewDelegate {
  var output = Data()
  func send(source: TerminalView, data: ArraySlice<UInt8>) { output.append(contentsOf: data) }
  func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
  func setTerminalTitle(source: TerminalView, title: String) {}
  func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
  func scrolled(source: TerminalView, position: Double) {}
  func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
  func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

@MainActor
final class TerminalThemeTests: XCTestCase {
  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
  }
  private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
  private func assertColor(_ actual: NSColor, _ expected: TerminalColor, file: StaticString = #filePath, line: UInt = #line) throws {
    let color = try XCTUnwrap(actual.usingColorSpace(.sRGB), file: file, line: line)
    XCTAssertEqual(color.redComponent, Double(expected.red) / 255, accuracy: 0.00001, file: file, line: line)
    XCTAssertEqual(color.greenComponent, Double(expected.green) / 255, accuracy: 0.00001, file: file, line: line)
    XCTAssertEqual(color.blueComponent, Double(expected.blue) / 255, accuracy: 0.00001, file: file, line: line)
    XCTAssertEqual(color.alphaComponent, expected.alpha, accuracy: 0.00001, file: file, line: line)
  }

  func test_all_palettes_reach_terminal_ansi_queries_cursor_selection_and_font_only_changes_preserve_program_colors() throws {
    _ = NSApplication.shared
    let session = SessionManager(knownHosts: KnownHostsStore(fileURL: try directory().appendingPathComponent("known_hosts")))
    let controller = TerminalViewController(session: session); _ = controller.view
    defer { controller.teardown() }
    let terminal = controller.terminalView, buffer = terminal.getTerminal(), probe = PaletteProbe()
    terminal.terminalDelegate = probe
    session.onData?(Data("retained output\r\n".utf8))
    for theme in TerminalTheme.catalog {
      controller.applyAppearance(.init(terminalTheme: theme, terminalFontSize: 15, terminalFontName: "SourceCodePro-Regular"))
      let dark = controller.view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      let palette = theme.palette(effectiveDark: dark)
      XCTAssertEqual(palette.ansi.count, 16)
      try assertColor(terminal.nativeBackgroundColor, palette.background)
      try assertColor(terminal.nativeForegroundColor, palette.foreground)
      try assertColor(terminal.caretColor, palette.cursor)
      try assertColor(terminal.selectedTextBackgroundColor, palette.selection)
      try assertColor(terminal.selectedTextForegroundColor, palette.selectionForeground)
      for (index, color) in palette.ansi.enumerated() {
        probe.output = Data(); terminal.feed(text: "\u{1B}]4;\(index);?\u{7}")
        let expected = String(format: "rgb:%04x/%04x/%04x", Int(color.red) * 257, Int(color.green) * 257, Int(color.blue) * 257)
        XCTAssertTrue(String(decoding: probe.output, as: UTF8.self).contains(expected), "ANSI \(index) of \(theme.displayName)")
      }
      XCTAssertEqual(terminal.font.fontName, "SourceCodePro-Regular")
      XCTAssertTrue(terminal.getTerminal() === buffer)
      XCTAssertTrue(String(decoding: buffer.getBufferAsData(), as: UTF8.self).contains("retained output"))
    }
    controller.applyAppearance(.init(terminalTheme: .termiusDark))
    terminal.feed(text: "\u{1B}]4;1;#123456;200;#654321\u{7}")
    controller.applyAppearance(.init(terminalTheme: .termiusDark, terminalFontSize: 18, terminalFontName: "Menlo-Regular"))
    probe.output = Data(); terminal.feed(text: "\u{1B}]4;1;?\u{7}")
    XCTAssertTrue(String(decoding: probe.output, as: UTF8.self).contains("rgb:1212/3434/5656"), "font edits must not reset a program's OSC palette")
  }

  func test_missing_or_proportional_fonts_fall_back_without_overwriting_the_saved_preference() throws {
    let store = AppearanceStore(fileURL: try directory().appendingPathComponent("appearance.json"))
    for name in ["MissingFontForTermes-Test", "Helvetica"] {
      let value = AppearanceSettings(terminalTheme: .kanagawaWave, terminalFontSize: 17, terminalFontName: name)
      try store.update(value)
      let resolved = TerminalFonts.resolve(name: value.terminalFontName, size: value.terminalFontSize)
      XCTAssertEqual(resolved, NSFont.monospacedSystemFont(ofSize: 17, weight: .regular))
      XCTAssertEqual(store.settings, value)
      XCTAssertFalse(TerminalFonts.isAvailable(name))
    }
    XCTAssertTrue(TerminalFonts.isAvailable("SourceCodePro-Regular"))
    let source = TerminalFonts.resolve(name: "SourceCodePro-Regular", size: 14)
    XCTAssertEqual(NSFontManager.shared.convert(source, toHaveTrait: .boldFontMask).fontName, "SourceCodePro-Bold")
    XCTAssertEqual(NSFontManager.shared.convert(source, toHaveTrait: .italicFontMask).fontName, "SourceCodePro-It")
    for choice in TerminalFonts.choices() { XCTAssertTrue(TerminalFonts.resolve(name: choice.name, size: 14).isFixedPitch) }
  }

  func test_custom_default_color_preserves_ansi_truecolor_osc_palette_and_terminal_buffer() throws {
    _ = NSApplication.shared
    let session = SessionManager(knownHosts: KnownHostsStore(fileURL: try directory().appendingPathComponent("known_hosts")))
    let controller = TerminalViewController(session: session); _ = controller.view
    defer { controller.teardown() }
    let terminal = controller.terminalView, buffer = terminal.getTerminal(), probe = PaletteProbe()
    terminal.terminalDelegate = probe
    controller.applyAppearance(.init(terminalTheme: .termiusDark))
    terminal.feed(text: "plain \u{1B}[31mred\u{1B}[0m \u{1B}[38;2;18;52;86mtrue\u{1B}[0m")
    let cells = try XCTUnwrap(buffer.getLine(row: 0)).getData()
    XCTAssertEqual(cells[6].attribute.fg, .ansi256(code: 1))
    XCTAssertEqual(cells[10].attribute.fg, .trueColor(red: 18, green: 52, blue: 86))
    terminal.feed(text: "\u{1B}]4;1;#123456;200;#654321\u{7}")
    var value = AppearanceSettings(terminalTheme: .termiusDark, terminalTextColor: 0x40E090)
    controller.applyAppearance(value)
    try assertColor(terminal.nativeForegroundColor, TerminalColor(0x40E090))
    XCTAssertTrue(terminal.getTerminal() === buffer)
    XCTAssertEqual(try XCTUnwrap(buffer.getLine(row: 0)).getData().map(\.attribute), cells.map(\.attribute))
    probe.output = Data(); terminal.feed(text: "\u{1B}]4;1;?\u{7}")
    XCTAssertTrue(String(decoding: probe.output, as: UTF8.self).contains("rgb:1212/3434/5656"))
    probe.output = Data(); terminal.feed(text: "\u{1B}]4;200;?\u{7}")
    XCTAssertTrue(String(decoding: probe.output, as: UTF8.self).contains("rgb:6565/4343/2121"))
    value.terminalTextColor = nil; controller.applyAppearance(value)
    try assertColor(terminal.nativeForegroundColor, TerminalTheme.termiusDark.palette(effectiveDark: true).foreground)
    probe.output = Data(); terminal.feed(text: "\u{1B}]4;1;?\u{7}")
    XCTAssertTrue(String(decoding: probe.output, as: UTF8.self).contains("rgb:1212/3434/5656"))
    value.terminalTextColor = 0x40E090; value.terminalTheme = .kanagawaLotus; controller.applyAppearance(value)
    try assertColor(terminal.nativeForegroundColor, TerminalColor(0x40E090))
    try assertColor(terminal.nativeBackgroundColor, TerminalTheme.kanagawaLotus.palette(effectiveDark: false).background)
    XCTAssertEqual(try XCTUnwrap(buffer.getLine(row: 0)).getData().map(\.attribute), cells.map(\.attribute))
  }

  func test_color_controls_sync_preview_other_settings_pages_and_restore_follow_theme() async throws {
    _ = NSApplication.shared
    let url = try directory().appendingPathComponent("appearance.json"), store = AppearanceStore(fileURL: url)
    let page = AppearanceViewController(store: store), other = AppearanceViewController(store: store)
    _ = page.view; _ = other.view
    XCTAssertFalse(page.textColorWell.isEnabled)
    page.textColorMode.selectItem(at: 1); page.textColorModeChanged()
    XCTAssertTrue(page.textColorWell.isEnabled); XCTAssertNotNil(store.settings.terminalTextColor)
    page.textColorWell.color = TerminalColor(0x40E090).nativeColor; page.textColorChanged()
    XCTAssertEqual(store.settings.terminalTextColor, 0x40E090)
    try assertColor(page.preview.nativeForegroundColor, TerminalColor(0x40E090))
    try assertColor(other.preview.nativeForegroundColor, TerminalColor(0x40E090))
    try assertColor(other.textColorWell.color, TerminalColor(0x40E090))
    XCTAssertEqual(other.textColorMode.indexOfSelectedItem, 1)
    XCTAssertEqual(AppearanceStore(fileURL: url).settings, store.settings)
    page.textColorMode.selectItem(at: 0); page.textColorModeChanged()
    XCTAssertNil(store.settings.terminalTextColor); XCTAssertFalse(other.textColorWell.isEnabled)
    try assertColor(page.preview.nativeForegroundColor, TerminalTheme.graphite.palette(effectiveDark: true).foreground)
    try assertColor(other.preview.nativeForegroundColor, TerminalTheme.graphite.palette(effectiveDark: true).foreground)
    if ProcessInfo.processInfo.environment["TERMES_TERMINAL_COLORS_VISUAL_REVIEW"] == "1" {
      let window = NSWindow(contentViewController: page); window.isReleasedWhenClosed = false
      defer { window.close() }
      try store.update(.init(theme: .dark, terminalTheme: .termiusDark, terminalFontSize: 14, terminalFontName: "SourceCodePro-Regular", terminalTextColor: 0xC8D2F6))
      window.setContentSize(.init(width: 820, height: 660)); window.makeKeyAndOrderFront(nil)
      page.view.needsLayout = true; page.view.layoutSubtreeIfNeeded()
      window.title = "Termes 文字颜色 · 自定义示例"
      await Task.yield(); print("TEXT_COLOR_REVIEW=\(window.windowNumber)")
      try await Task.sleep(for: .seconds(15))
    }
  }

  func test_settings_rows_font_controls_keyboard_selection_and_resizing_keep_preview_and_saved_selection() async throws {
    _ = NSApplication.shared
    let url = try directory().appendingPathComponent("appearance.json"), store = AppearanceStore(fileURL: url)
    let page = AppearanceViewController(store: store), other = AppearanceViewController(store: store)
    let window = NSWindow(contentViewController: page); window.isReleasedWhenClosed = false; _ = other.view
    defer { window.close() }
    let preview = page.preview.getTerminal()
    let row = try XCTUnwrap(page.themeRows.first { $0.theme == .termiusDark })
    row.performClick(nil)
    XCTAssertEqual(store.settings.terminalTheme, .termiusDark)
    try assertColor(page.preview.nativeBackgroundColor, TerminalTheme.termiusDark.palette(effectiveDark: true).background)
    XCTAssertEqual(page.themeRows.filter { $0.state == .on }.map(\.theme), [.termiusDark])
    XCTAssertEqual(other.themeRows.filter { $0.state == .on }.map(\.theme), [.termiusDark])
    let fontIndex = try XCTUnwrap(page.fontChoices.firstIndex { $0.name == "SourceCodePro-Regular" })
    page.fontPopup.selectItem(at: fontIndex); page.fontChanged(); page.increaseButton.performClick(nil)
    XCTAssertEqual(store.settings.terminalFontName, "SourceCodePro-Regular"); XCTAssertEqual(store.settings.terminalFontSize, 14)
    XCTAssertEqual(page.preview.font.fontName, "SourceCodePro-Regular")
    XCTAssertEqual(page.preview.font.pointSize, 14)
    for text in ["9", "29", "nan", "bad"] {
      page.sizeField.stringValue = text
      page.controlTextDidEndEditing(.init(name: NSControl.textDidEndEditingNotification, object: page.sizeField))
      XCTAssertEqual(store.settings.terminalFontSize, 14); XCTAssertEqual(page.sizeField.stringValue, "14")
    }
    for (text, decreasing, increasing) in [("10", false, true), ("28", true, false)] {
      page.sizeField.stringValue = text
      page.controlTextDidEndEditing(.init(name: NSControl.textDidEndEditingNotification, object: page.sizeField))
      XCTAssertEqual(page.decreaseButton.isEnabled, decreasing); XCTAssertEqual(page.increaseButton.isEnabled, increasing)
    }
    let down = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125))
    row.keyDown(with: down)
    XCTAssertEqual(store.settings.terminalTheme, .termiusLight)
    try assertColor(page.preview.nativeBackgroundColor, TerminalTheme.termiusLight.palette(effectiveDark: true).background)
    XCTAssertEqual(window.firstResponder, page.themeRows[1])
    XCTAssertEqual(AppearanceStore(fileURL: url).settings, store.settings)
    for size in [NSSize(width: 820, height: 660), .init(width: 360, height: 480)] {
      window.setContentSize(size); page.view.needsLayout = true; page.view.layoutSubtreeIfNeeded()
      for child in page.view.subviews { XCTAssertTrue(page.view.bounds.contains(child.frame), "settings child exceeds the window") }
      let scroll = try XCTUnwrap(page.view.subviews.first { $0 is NSScrollView } as? NSScrollView), document = try XCTUnwrap(scroll.documentView)
      XCTAssertLessThanOrEqual(document.frame.width, scroll.contentSize.width + 0.5, "font and theme controls must not be clipped by the scroller")
      for control in descendants(document).compactMap({ $0 as? NSControl }).filter({ !$0.isHiddenOrHasHiddenAncestor }) {
        XCTAssertTrue(document.bounds.contains(control.convert(control.bounds, to: document)), "\(control)")
      }
      XCTAssertTrue(page.preview.getTerminal() === preview)
      XCTAssertTrue(String(decoding: preview.getBufferAsData(), as: UTF8.self).contains("deploy@production"))
    }
    page.fontToggle.performClick(nil); XCTAssertFalse(page.isFontExpanded); XCTAssertTrue(page.fontPopup.isHidden)
    page.fontToggle.performClick(nil); XCTAssertTrue(page.isFontExpanded); XCTAssertFalse(page.fontPopup.isHidden)
    if ProcessInfo.processInfo.environment["TERMES_TERMINAL_THEMES_VISUAL_REVIEW"] == "1" {
      window.styleMask = [.titled, .closable, .resizable]; window.makeKeyAndOrderFront(nil)
      for (theme, terminal, size, mode) in [(AppTheme.dark, TerminalTheme.termiusDark, NSSize(width: 820, height: 660), "dark"),
                                          (.light, .termiusLight, .init(width: 820, height: 660), "light"),
                                          (.dark, .termiusDark, .init(width: 360, height: 660), "compact")] {
        try store.update(.init(theme: theme, terminalTheme: terminal, terminalFontSize: 14, terminalFontName: "SourceCodePro-Regular"))
        window.title = "Termes 主题与字体预览 · \(mode)"; window.setContentSize(size)
        page.view.needsLayout = true; page.view.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(page.view.subviews.first { $0 is NSScrollView } as? NSScrollView)
        scroll.documentView?.scroll(.zero)
        await Task.yield(); print("THEME_REVIEW_\(mode)=\(window.windowNumber)")
        try await Task.sleep(nanoseconds: 15_000_000_000)
      }
    }
  }

  func test_failed_settings_save_rolls_back_theme_font_size_and_preview_with_visible_error() throws {
    _ = NSApplication.shared
    let url = try directory().appendingPathComponent("appearance.json"), store = AppearanceStore(fileURL: url)
    let value = AppearanceSettings(terminalTheme: .termiusDark, terminalFontSize: 14, terminalFontName: "SourceCodePro-Regular")
    try store.update(value)
    let page = AppearanceViewController(store: store); _ = page.view
    try FileManager.default.removeItem(at: url); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    try XCTUnwrap(page.themeRows.first { $0.theme == .termiusLight }).performClick(nil)
    page.fontPopup.selectItem(at: 0); page.fontChanged(); page.increaseButton.performClick(nil)
    page.textColorMode.selectItem(at: 1); page.textColorModeChanged()
    page.textColorWell.color = .systemPink; page.textColorChanged()
    XCTAssertEqual(store.settings, value); XCTAssertEqual(page.sizeField.stringValue, "14")
    XCTAssertEqual(page.fontChoices[page.fontPopup.indexOfSelectedItem].name, "SourceCodePro-Regular")
    XCTAssertEqual(page.themeRows.filter { $0.state == .on }.map(\.theme), [.termiusDark])
    try assertColor(page.preview.nativeBackgroundColor, TerminalTheme.termiusDark.palette(effectiveDark: true).background)
    XCTAssertEqual(page.textColorMode.indexOfSelectedItem, 0); XCTAssertFalse(page.textColorWell.isEnabled)
    try assertColor(page.preview.nativeForegroundColor, TerminalTheme.termiusDark.palette(effectiveDark: true).foreground)
    XCTAssertTrue(descendants(page.view).compactMap { $0 as? NSTextField }.contains { !$0.isHiddenOrHasHiddenAncestor && $0.stringValue.contains("保存失败") })
  }
}
