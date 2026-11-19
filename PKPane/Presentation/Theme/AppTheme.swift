import AppKit
import Observation
import SwiftUI

enum AppTheme {
  static func appearanceName(for preference: AppAppearancePreference) -> NSAppearance.Name? {
    switch preference {
    case .system: nil
    case .light: .aqua
    case .dark: .darkAqua
    case .cream: .aqua
    }
  }

  static func palette(for preference: AppAppearancePreference) -> ThemePalette {
    switch preference {
    case .system, .light, .dark: .standard
    case .cream: .cream
    }
  }
}

struct ThemeRGB: Equatable, Sendable {
  let red: UInt8
  let green: UInt8
  let blue: UInt8

  var nsColor: NSColor {
    NSColor(
      srgbRed: Double(red) / 255, green: Double(green) / 255,
      blue: Double(blue) / 255, alpha: 1)
  }

  var color: Color { Color(nsColor: nsColor) }
}

enum ThemeColorRole: Equatable, Sendable {
  case systemBlue
  case rgb(ThemeRGB)

  var color: Color {
    switch self {
    case .systemBlue: Color.blue
    case .rgb(let rgb): rgb.color
    }
  }
}

enum ThemeAccentStrength: Sendable {
  case hover
  case selection
  case connectionSelection
  case sidebarSelection
  case border

  var opacity: Double {
    switch self {
    case .hover: 0.12
    case .selection: 0.2
    case .connectionSelection: 0.22
    case .sidebarSelection: 0.24
    case .border: 0.8
    }
  }
}

struct ThemePalette: Equatable, Sendable {
  let windowBackground: ThemeRGB?
  let sidebarBackground: ThemeRGB?
  let contentBackground: ThemeRGB?
  let alternatingRowBackground: ThemeRGB?
  let toolbarBackground: ThemeRGB?
  let separator: ThemeRGB?
  let activePaneIndicator: ThemeColorRole

  var error: Color { Color.red }
  var warning: Color { Color.orange }
  var caution: Color { Color.yellow }
  var success: Color { Color.green }

  func accentFill(_ strength: ThemeAccentStrength) -> Color {
    Color.accentColor.opacity(strength.opacity)
  }

  static let standard = ThemePalette(
    windowBackground: nil, sidebarBackground: nil, contentBackground: nil,
    alternatingRowBackground: nil, toolbarBackground: nil, separator: nil,
    activePaneIndicator: .systemBlue)

  static let cream = ThemePalette(
    windowBackground: ThemeRGB(red: 0xF2, green: 0xE8, blue: 0xD0),
    sidebarBackground: ThemeRGB(red: 0xEC, green: 0xE1, blue: 0xC5),
    contentBackground: ThemeRGB(red: 0xF2, green: 0xE8, blue: 0xD0),
    alternatingRowBackground: ThemeRGB(red: 0xEA, green: 0xE0, blue: 0xC4),
    toolbarBackground: ThemeRGB(red: 0xF2, green: 0xE8, blue: 0xD0),
    separator: ThemeRGB(red: 0xD5, green: 0xC6, blue: 0xA0),
    activePaneIndicator: .rgb(ThemeRGB(red: 0x9C, green: 0x6B, blue: 0x30)))
}

@MainActor
@Observable
final class AppThemeModel {
  static let shared = AppThemeModel()
  private(set) var palette: ThemePalette = .standard

  func apply(_ preference: AppAppearancePreference) {
    palette = AppTheme.palette(for: preference)
  }
}

@MainActor
enum AppThemeApplier {
  static func apply(
    _ preference: AppAppearancePreference,
    to model: AppThemeModel = .shared,
    applyAppearance: @MainActor (NSAppearance.Name?) -> Void = applyAppearance(named:)
  ) {
    model.apply(preference)
    applyAppearance(AppTheme.appearanceName(for: preference))
  }

  static func applyAppearance(named name: NSAppearance.Name?) {
    NSApp.appearance = name.flatMap(NSAppearance.init(named:))
  }
}

private struct ThemePaletteKey: EnvironmentKey {
  static let defaultValue = ThemePalette.standard
}

extension EnvironmentValues {
  var themePalette: ThemePalette {
    get { self[ThemePaletteKey.self] }
    set { self[ThemePaletteKey.self] = newValue }
  }
}
