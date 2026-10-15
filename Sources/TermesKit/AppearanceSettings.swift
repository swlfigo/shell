import Foundation
import Combine

public enum AppTheme: String, Codable, CaseIterable, Sendable {
  case system, light, dark
}

public enum TerminalTheme: String, Codable, CaseIterable, Sendable {
  case graphite, light, appearance
  case termiusDark, termiusLight, flexokiDark, flexokiLight
  case kanagawaWave, kanagawaDragon, kanagawaLotus
  case hackerBlue, hackerGreen, hackerRed
}

public enum AppearanceSettingsError: Error { case invalidFontSize, invalidFontName, invalidTextColor }

/// Platform-neutral preferences. Applying them must never recreate a connection or terminal.
public struct AppearanceSettings: Codable, Equatable, Sendable {
  public var theme: AppTheme
  public var terminalTheme: TerminalTheme
  public var terminalFontSize: Double
  /// A PostScript font name, or nil for the platform's system monospaced font.
  public var terminalFontName: String?
  /// An opaque sRGB foreground override; nil follows the selected terminal theme.
  public var terminalTextColor: UInt32?
  public init(theme: AppTheme = .system, terminalTheme: TerminalTheme = .graphite, terminalFontSize: Double = 13,
              terminalFontName: String? = nil, terminalTextColor: UInt32? = nil) {
    self.theme = theme; self.terminalTheme = terminalTheme; self.terminalFontSize = terminalFontSize
    self.terminalFontName = terminalFontName
    self.terminalTextColor = terminalTextColor
  }
}

@MainActor
public final class AppearanceStore: ObservableObject {
  @Published public private(set) var settings = AppearanceSettings()
  @Published public private(set) var error: String?
  private let fileURL: URL

  public init(fileURL: URL) {
    self.fileURL = fileURL
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
    do {
      let data = try Data(contentsOf: fileURL)
      guard data.count <= 16_384 else { throw CocoaError(.fileReadCorruptFile) }
      let value = try JSONDecoder().decode(AppearanceSettings.self, from: data)
      try Self.validate(value)
      settings = value
    } catch { self.error = "外观设置读取失败，当前使用默认外观。" }
  }

  /// Save first, publish second: a failed write retains the currently applied settings.
  public func update(_ value: AppearanceSettings) throws {
    do {
      try Self.validate(value)
      let data = try JSONEncoder().encode(value)
      try data.write(to: fileURL, options: .atomic)
      error = nil; settings = value
    } catch {
      self.error = "外观设置保存失败，请检查本机文件权限或磁盘空间。"
      throw error
    }
  }

  private static func validate(_ value: AppearanceSettings) throws {
    guard value.terminalFontSize.isFinite, (10...28).contains(value.terminalFontSize) else {
      throw AppearanceSettingsError.invalidFontSize
    }
    if let name = value.terminalFontName {
      guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 256,
            name.rangeOfCharacter(from: .controlCharacters) == nil else { throw AppearanceSettingsError.invalidFontName }
    }
    if let color = value.terminalTextColor, color > 0xFFFFFF { throw AppearanceSettingsError.invalidTextColor }
  }
}
