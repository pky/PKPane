import AppKit
import Foundation
import Testing

@testable import PKPane

@MainActor
struct AppThemeTests {
  @Test("全外観モードを期待するAppKit外観とパレットへ写像する")
  func mapsEveryAppearanceToNameAndPalette() {
    let expectations: [(AppAppearancePreference, NSAppearance.Name?, ThemePalette)] = [
      (.system, nil, .standard),
      (.light, .aqua, .standard),
      (.dark, .darkAqua, .standard),
      (.cream, .aqua, .cream),
    ]

    for (preference, name, palette) in expectations {
      #expect(AppTheme.appearanceName(for: preference) == name)
      #expect(AppTheme.palette(for: preference) == palette)
    }
  }

  @Test("標準パレットは背景を上書きせずアクティブペイン線をシステム青にする")
  func standardPalettePreservesSystemBackgrounds() {
    let palette = ThemePalette.standard

    #expect(palette.windowBackground == nil)
    #expect(palette.sidebarBackground == nil)
    #expect(palette.contentBackground == nil)
    #expect(palette.alternatingRowBackground == nil)
    #expect(palette.toolbarBackground == nil)
    #expect(palette.separator == nil)
    #expect(palette.activePaneIndicator == ThemeColorRole.systemBlue)
  }

  @Test("クリームパレットの背景・区切り線・アクティブペイン線は指定色になる")
  func creamPaletteUsesSpecifiedColors() {
    let palette = ThemePalette.cream
    let content = ThemeRGB(red: 0xF2, green: 0xE8, blue: 0xD0)

    #expect(palette.windowBackground == content)
    #expect(palette.contentBackground == content)
    #expect(palette.toolbarBackground == content)
    #expect(palette.sidebarBackground == ThemeRGB(red: 0xEC, green: 0xE1, blue: 0xC5))
    #expect(palette.alternatingRowBackground == ThemeRGB(red: 0xEA, green: 0xE0, blue: 0xC4))
    #expect(palette.separator == ThemeRGB(red: 0xD5, green: 0xC6, blue: 0xA0))
    #expect(
      palette.activePaneIndicator == .rgb(ThemeRGB(red: 0x9C, green: 0x6B, blue: 0x30)))
  }

  @Test("アクセントの強さは既存の用途ごとの透明度を維持する")
  func accentStrengthsPreserveExistingOpacities() {
    let expectations: [(ThemeAccentStrength, Double)] = [
      (.hover, 0.12),
      (.selection, 0.2),
      (.connectionSelection, 0.22),
      (.sidebarSelection, 0.24),
      (.border, 0.8),
    ]

    for (strength, opacity) in expectations {
      #expect(abs(strength.opacity - opacity) < 0.000_001)
    }
  }

  @Test("クリーム背景上のAqua主文字色はコントラスト比7以上、副文字色は白背景比の9割以上を保つ")
  func creamBackgroundsPreserveAquaLabelContrast() throws {
    let appearance = try #require(NSAppearance(named: .aqua))
    let palette = ThemePalette.cream
    let backgrounds = [
      ("content", try #require(palette.contentBackground)),
      ("sidebar", try #require(palette.sidebarBackground)),
      ("alternatingRow", try #require(palette.alternatingRowBackground)),
    ]
    let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    for (labelName, label) in [
      ("labelColor", NSColor.labelColor),
      ("secondaryLabelColor", NSColor.secondaryLabelColor),
    ] {
      let foreground = try components(of: label, appearance: appearance)
      let reference = try contrastRatio(
        foreground: foreground, background: white, appearance: appearance)

      for (backgroundName, background) in backgrounds {
        let contrast = try contrastRatio(
          foreground: foreground, background: background.nsColor, appearance: appearance)
        if labelName == "labelColor" {
          #expect(
            contrast >= 7.0,
            "\(labelName)/\(backgroundName): \(contrast)、必要な比: 7.0")
        } else {
          #expect(
            contrast >= reference * 0.9,
            "\(labelName)/\(backgroundName): \(contrast)、白背景: \(reference)")
        }
      }
    }
  }

  private func components(
    of color: NSColor, appearance: NSAppearance
  ) throws -> (red: Double, green: Double, blue: Double, alpha: Double) {
    var resolved: NSColor?
    appearance.performAsCurrentDrawingAppearance {
      resolved = color.usingColorSpace(.sRGB)
    }
    let rgb = try #require(resolved)
    return (
      Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent),
      Double(rgb.alphaComponent)
    )
  }

  private func contrastRatio(
    foreground: (red: Double, green: Double, blue: Double, alpha: Double),
    background: NSColor,
    appearance: NSAppearance
  ) throws -> Double {
    let backgroundRGB = try components(of: background, appearance: appearance)
    // 半透明の文字色をsRGB背景に合成してから相対輝度を求める。
    let alpha = foreground.alpha
    let textLuminance = luminance(
      red: foreground.red * alpha + backgroundRGB.red * (1 - alpha),
      green: foreground.green * alpha + backgroundRGB.green * (1 - alpha),
      blue: foreground.blue * alpha + backgroundRGB.blue * (1 - alpha))
    let backgroundLuminance = luminance(
      red: backgroundRGB.red, green: backgroundRGB.green, blue: backgroundRGB.blue)
    return (max(textLuminance, backgroundLuminance) + 0.05)
      / (min(textLuminance, backgroundLuminance) + 0.05)
  }

  private func luminance(red: Double, green: Double, blue: Double) -> Double {
    func linear(_ component: Double) -> Double {
      component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
  }
}
