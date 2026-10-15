import Foundation

/// sRGB data shared by previews and terminals, with no AppKit dependency.
public struct TerminalColor: Equatable, Sendable {
  public let rgb: UInt32
  public let alpha: Double
  public init(_ rgb: UInt32, alpha: Double = 1) { self.rgb = rgb; self.alpha = alpha }
  public var red: UInt8 { UInt8((rgb >> 16) & 255) }
  public var green: UInt8 { UInt8((rgb >> 8) & 255) }
  public var blue: UInt8 { UInt8(rgb & 255) }
}

public struct TerminalPalette: Equatable, Sendable {
  public let background, foreground, cursor, selection, selectionForeground: TerminalColor
  /// Black, red, green, yellow, blue, magenta, cyan, white; then their bright variants.
  public let ansi: [TerminalColor]
  init(background: UInt32, foreground: UInt32, cursor: UInt32, selection: UInt32, selectionAlpha: Double = 1, ansi: [UInt32]) {
    self.background = .init(background); self.foreground = .init(foreground); self.cursor = .init(cursor)
    self.selection = .init(selection, alpha: selectionAlpha); selectionForeground = .init(foreground)
    self.ansi = ansi.map { .init($0) }
  }
}

extension TerminalTheme {
  public static let catalog: [TerminalTheme] = [.termiusDark, .termiusLight, .flexokiDark, .flexokiLight,
    .kanagawaWave, .kanagawaDragon, .kanagawaLotus, .hackerBlue, .hackerGreen, .hackerRed,
    .graphite, .light, .appearance]

  public var displayName: String {
    switch self {
    case .graphite: return "Termes Graphite"
    case .light: return "Termes Light"
    case .appearance: return "跟随界面"
    case .termiusDark: return "Termius Dark"
    case .termiusLight: return "Termius Light"
    case .flexokiDark: return "Flexoki Dark"
    case .flexokiLight: return "Flexoki Light"
    case .kanagawaWave: return "Kanagawa Wave"
    case .kanagawaDragon: return "Kanagawa Dragon"
    case .kanagawaLotus: return "Kanagawa Lotus"
    case .hackerBlue: return "Hacker Blue"
    case .hackerGreen: return "Hacker Green"
    case .hackerRed: return "Hacker Red"
    }
  }

  /// Reference palette values checked against the installed Termius 10.1.3 static theme table.
  /// Flexoki: https://github.com/kepano/flexoki (Steph Ango).
  /// Kanagawa: https://github.com/rebelot/kanagawa.nvim (Tommaso Laurenzi).
  /// Bundled licenses: Sources/Termes/Resources/Theme-Licenses/.
  public func palette(effectiveDark: Bool) -> TerminalPalette {
    switch self {
    case .appearance: return (effectiveDark ? TerminalTheme.graphite : .light).palette(effectiveDark: effectiveDark)
    case .graphite, .light:
      let dark = self == .graphite
      return .init(background: dark ? 0x0E1216 : 0xFFFFFF, foreground: dark ? 0xD9E3F0 : 0x212933,
        cursor: dark ? 0xD9E3F0 : 0x212933, selection: dark ? 0x35516D : 0xBDDCF5,
        ansi: [0x000000, 0xC23621, 0x25BC24, 0xADAD27, 0x492EE1, 0xD338D3, 0x33BBC8, 0xCBCCCD,
               0x818383, 0xFC391F, 0x31E722, 0xEAEC23, 0x5833FF, 0xF935F8, 0x14F0F0, 0xE9EBEB])
    case .termiusDark:
      return .init(background: 0x141729, foreground: 0x21B568, cursor: 0x21B568,
        selection: 0x21B568, selectionAlpha: 128.0 / 255,
        ansi: [0x343851, 0xF24E50, 0x008463, 0xECA855, 0x08639F, 0xC13282, 0x2091F6, 0xE2E3E8,
               0x8D91A5, 0xFF7375, 0x3ED7BE, 0xFDC47D, 0x6BA0C3, 0xFF7DC5, 0x44A7FF, 0xFFFFFF])
    case .termiusLight:
      return .init(background: 0xD5DDE0, foreground: 0x32364A, cursor: 0x32364A,
        selection: 0x32364A, selectionAlpha: 128.0 / 255,
        ansi: [0x141729, 0xF24E50, 0x198C51, 0xAB6918, 0x004878, 0x8F3C91, 0x2091F6, 0xEEEEEE,
               0x3E4257, 0xFF7375, 0x21B568, 0xFDC47D, 0x1D6DA2, 0xFF7DC5, 0x44A7FF, 0xFFFFFF])
    case .flexokiDark:
      return .init(background: 0x100F0F, foreground: 0xCECDC3, cursor: 0xCECDC3,
        selection: 0xCECDC3, selectionAlpha: 128.0 / 255,
        ansi: [0x100F0F, 0xAF3029, 0x66800B, 0xAD8301, 0x205EA6, 0xA02F6F, 0x24837B, 0x878580,
               0x6F6E69, 0xD14D41, 0x879A39, 0xD0A215, 0x4385BE, 0xCE5D97, 0x3AA99F, 0xCECDC3])
    case .flexokiLight:
      return .init(background: 0xFFFCF0, foreground: 0x100F0F, cursor: 0x100F0F,
        selection: 0x100F0F, selectionAlpha: 128.0 / 255,
        ansi: [0x100F0F, 0xD14D41, 0x879A39, 0xD0A215, 0x4385BE, 0xCE5D97, 0x3AA99F, 0xFFFCF0,
               0x6F6E69, 0xAF3029, 0x66800B, 0xAD8301, 0x205EA6, 0xA02F6F, 0x24837B, 0xF2F0E5])
    case .kanagawaWave:
      return .init(background: 0x1F1F28, foreground: 0xDCD7BA, cursor: 0xC8C093,
        selection: 0xD7BA80, selectionAlpha: 128.0 / 255,
        ansi: [0x16161D, 0xC34043, 0x5D864D, 0xC0A36E, 0x7E9CD8, 0x6F549B, 0x6A9589, 0xC8C093,
               0x727169, 0xE9585B, 0x98BB6C, 0xE6C384, 0x7FB4CA, 0xA18BC4, 0x8BC5B9, 0xDCD7BA])
    case .kanagawaDragon:
      return .init(background: 0x181616, foreground: 0xC5C9C5, cursor: 0xC8C093,
        selection: 0xC9C580, selectionAlpha: 128.0 / 255,
        ansi: [0x0D0C0C, 0xC4746E, 0x596F44, 0xC4B28A, 0x8BA4B0, 0x9C5F9F, 0x5A948F, 0xE6E2C7,
               0xA6A69C, 0xE88A83, 0x9CCD9C, 0xE6C384, 0x7FB4CA, 0xD7BDD9, 0x77C7C0, 0xFFFAD9])
    case .kanagawaLotus:
      return .init(background: 0xF2ECBC, foreground: 0x545464, cursor: 0x43436C,
        selection: 0x546480, selectionAlpha: 128.0 / 255,
        ansi: [0x1F1F28, 0xC84053, 0x6F894E, 0xCBBC41, 0x4871AF, 0xE56792, 0x5FA99C, 0x545464,
               0x555448, 0xE65569, 0x88A760, 0xE5D978, 0x6693BF, 0xC299FF, 0x7CC4B0, 0x43436C])
    case .hackerBlue:
      return .init(background: 0x010515, foreground: 0x11B7FF, cursor: 0x10B6FF,
        selection: 0xC1E4FF, selectionAlpha: 128.0 / 255,
        ansi: [0x1E2644, 0x0D7EAF, 0x529CBD, 0x00608A, 0x034765, 0x648593, 0x7AD6FF, 0xD1F1FF,
               0x2F385A, 0x0FBDFF, 0x6FB7D3, 0x43C3F4, 0x5CC0E6, 0x7AB2C7, 0x4DCEFF, 0xFEFEFE])
    case .hackerGreen:
      return .init(background: 0x020F01, foreground: 0x16B10E, cursor: 0x15D00D,
        selection: 0xD4FFC1, selectionAlpha: 128.0 / 255,
        ansi: [0x243128, 0x14AF0D, 0x86CE83, 0x068A00, 0x50BE4B, 0x4B7649, 0xA8F0A4, 0xD6FCD4,
               0x36463B, 0x28F11D, 0x90E08B, 0x4CF443, 0x63E65C, 0xA8D9A5, 0x59EA51, 0xFEFEFE])
    case .hackerRed:
      return .init(background: 0x200000, foreground: 0xB10E0E, cursor: 0xB00D0D,
        selection: 0xEBC1FF, selectionAlpha: 128.0 / 255,
        ansi: [0x381313, 0xB00D0D, 0x5D2020, 0x890000, 0xBE4A4A, 0x7A3B3B, 0xFF7979, 0xFFD2D2,
               0x993F3F, 0xFF1111, 0xD26D6D, 0xF54242, 0xE55B5B, 0xC87B7B, 0xFF4D4D, 0xFEFEFE])
    }
  }
}
