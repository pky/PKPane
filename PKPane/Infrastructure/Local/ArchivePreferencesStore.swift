import Foundation
import Observation

/// アーカイブ作成時の既定形式をUserDefaultsの1キーへ保存する。
@Observable
@MainActor
final class ArchivePreferencesStore {
  static let shared = ArchivePreferencesStore()

  private let defaults: UserDefaults
  private let key = "default-archive-format"
  private(set) var defaultFormat: ArchiveFormat

  init(defaults: UserDefaults? = nil) {
    let defaults = defaults ?? Self.defaultUserDefaults
    self.defaults = defaults
    let storedFormat = defaults.string(forKey: key).flatMap(ArchiveFormat.init(rawValue:))
    defaultFormat = storedFormat.flatMap { $0.supportsCreation ? $0 : nil } ?? .zip
  }

  func save(_ format: ArchiveFormat) {
    guard format.supportsCreation else { return }
    guard defaultFormat != format else { return }
    defaultFormat = format
    defaults.set(format.rawValue, forKey: key)
  }

  func remove() {
    defaults.removeObject(forKey: key)
    defaultFormat = .zip
  }

  private static var defaultUserDefaults: UserDefaults {
    PKPaneUserDefaults.resolve()
  }
}
