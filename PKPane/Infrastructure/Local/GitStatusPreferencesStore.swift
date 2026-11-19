import Foundation
import Observation

/// Git状態表示の設定を1キーで保持する。未保存時は必ずOFFを返す。
@Observable
@MainActor
final class GitStatusPreferencesStore: GitStatusPreferenceReading {
  static let shared = GitStatusPreferencesStore()

  private let defaults: UserDefaults
  private let key = "shows-git-status"
  private(set) var isEnabled: Bool

  init(defaults: UserDefaults? = nil) {
    let defaults = defaults ?? Self.defaultUserDefaults
    self.defaults = defaults
    isEnabled = defaults.bool(forKey: key)
  }

  func save(_ isEnabled: Bool) {
    guard self.isEnabled != isEnabled else { return }
    self.isEnabled = isEnabled
    defaults.set(isEnabled, forKey: key)
  }

  func remove() {
    defaults.removeObject(forKey: key)
    isEnabled = false
  }

  private static var defaultUserDefaults: UserDefaults {
    PKPaneUserDefaults.resolve()
  }
}
