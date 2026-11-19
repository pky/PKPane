import AppKit
import Foundation

enum AppAppearancePreference: String, CaseIterable, Identifiable, Sendable {
  case system
  case light
  case dark
  case cream

  var id: Self { self }

  var displayName: String {
    switch self {
    case .system:
      String(localized: "システム")
    case .light:
      String(localized: "ライト")
    case .dark:
      String(localized: "ダーク")
    case .cream:
      String(localized: "クリーム")
    }
  }
}

enum AppAppearanceMapping {
  static func appearanceName(for preference: AppAppearancePreference) -> NSAppearance.Name? {
    AppTheme.appearanceName(for: preference)
  }
}

/// アプリ全体の外観設定をUserDefaultsの1キーへ保存する。
final class AppearancePreferencesStore {
  private let defaults: UserDefaults
  private let key = "appearance-preference"

  init(defaults: UserDefaults? = nil) {
    self.defaults = defaults ?? Self.defaultUserDefaults
  }

  func save(_ preference: AppAppearancePreference) {
    defaults.set(preference.rawValue, forKey: key)
  }

  func load() -> AppAppearancePreference {
    guard let rawValue = defaults.string(forKey: key),
      let preference = AppAppearancePreference(rawValue: rawValue)
    else {
      return .system
    }
    return preference
  }

  func remove() {
    defaults.removeObject(forKey: key)
  }

  private static var defaultUserDefaults: UserDefaults {
    PKPaneUserDefaults.resolve()
  }
}
