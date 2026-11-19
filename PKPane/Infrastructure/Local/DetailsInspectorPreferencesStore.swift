import Foundation

enum DetailsDisplayMode: String, Codable, CaseIterable, Identifiable {
  case pane
  case none

  var id: Self { self }

  var displayName: String {
    switch self {
    case .pane: "別ペイン"
    case .none: "出さない"
    }
  }

  var togglingPane: DetailsDisplayMode {
    self == .pane ? .none : .pane
  }
}

/// 詳細の自動表示先・ペイン幅の永続化。旧isVisible値も読み込み、既存ユーザーの設定を
/// pane/noneへ移行する。FileBrowserDisplayOptionsStoreと同じUserDefaults運用に揃える。
struct DetailsInspectorPreferences: Codable, Equatable {
  var mode: DetailsDisplayMode = .none
  var width: Double = 260

  private enum CodingKeys: String, CodingKey {
    case mode
    case isVisible
    case width
  }

  init(mode: DetailsDisplayMode = .none, width: Double = 260) {
    self.mode = mode
    self.width = width
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let storedMode = try container.decodeIfPresent(String.self, forKey: .mode) {
      // 廃止したdialogは、詳細を表示する側のpaneへ移行する。
      mode = storedMode == "dialog" ? .pane : DetailsDisplayMode(rawValue: storedMode) ?? .none
    } else {
      let wasVisible = try container.decodeIfPresent(Bool.self, forKey: .isVisible) ?? false
      mode = wasVisible ? .pane : .none
    }
    width = try container.decodeIfPresent(Double.self, forKey: .width) ?? 260
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(mode, forKey: .mode)
    try container.encode(width, forKey: .width)
  }
}

final class DetailsInspectorPreferencesStore {
  private let defaults: UserDefaults
  private let key = "details-inspector-preferences"

  init(defaults: UserDefaults? = nil) {
    self.defaults = defaults ?? Self.defaultUserDefaults
  }

  func save(_ preferences: DetailsInspectorPreferences) {
    guard let data = try? JSONEncoder().encode(preferences) else { return }
    defaults.set(data, forKey: key)
  }

  func load() -> DetailsInspectorPreferences {
    guard let data = defaults.data(forKey: key),
      let preferences = try? JSONDecoder().decode(DetailsInspectorPreferences.self, from: data)
    else {
      return DetailsInspectorPreferences()
    }
    return preferences
  }

  func remove() {
    defaults.removeObject(forKey: key)
  }

  private static var defaultUserDefaults: UserDefaults {
    PKPaneUserDefaults.resolve()
  }
}
