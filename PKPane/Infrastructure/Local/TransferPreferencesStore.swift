import Foundation
import Observation

struct TransferPreferences: Codable, Equatable {
  var bandwidthLimitBytesPerSecond: Int64?

  init(bandwidthLimitBytesPerSecond: Int64? = nil) {
    self.bandwidthLimitBytesPerSecond = bandwidthLimitBytesPerSecond
  }
}

enum TransferBandwidthOptions {
  static let values: [Int64] = [
    0, 1_000_000, 5_000_000, 10_000_000, 25_000_000, 50_000_000,
  ]

  static func normalized(_ value: Int64?) -> Int64? {
    value.flatMap { $0 > 0 ? $0 : nil }
  }

  static func label(for bytesPerSecond: Int64) -> String {
    guard bytesPerSecond > 0 else { return String(localized: "無制限") }
    return "\(bytesPerSecond / 1_000_000) \(String(localized: "MB/秒"))"
  }
}

/// 転送帯域のユーザー設定を、他の表示設定と同じUserDefaults上のJSONとして保存する。
@Observable
@MainActor
final class TransferPreferencesStore {
  static let shared = TransferPreferencesStore()

  private(set) var current: TransferPreferences
  private let defaults: UserDefaults
  private let key = "transfer-preferences"

  init(defaults: UserDefaults? = nil) {
    self.defaults = defaults ?? Self.defaultUserDefaults
    current = Self.decode(from: self.defaults, key: key)
  }

  func save(_ preferences: TransferPreferences) {
    let normalized = TransferPreferences(
      bandwidthLimitBytesPerSecond: TransferBandwidthOptions.normalized(
        preferences.bandwidthLimitBytesPerSecond))
    guard let data = try? JSONEncoder().encode(normalized) else { return }
    current = normalized
    defaults.set(data, forKey: key)
  }

  /// 初期化時または`save`/`remove`時に更新したメモリ内キャッシュを返す。
  /// 呼び出しごとにUserDefaultsを読み直さないため、外部変更の取り込みには再生成が必要。
  func load() -> TransferPreferences {
    current
  }

  func remove() {
    defaults.removeObject(forKey: key)
    current = TransferPreferences()
  }

  private static func decode(from defaults: UserDefaults, key: String) -> TransferPreferences {
    guard let data = defaults.data(forKey: key),
      let preferences = try? JSONDecoder().decode(TransferPreferences.self, from: data)
    else {
      return TransferPreferences()
    }
    return TransferPreferences(
      bandwidthLimitBytesPerSecond: TransferBandwidthOptions.normalized(
        preferences.bandwidthLimitBytesPerSecond))
  }

  private static var defaultUserDefaults: UserDefaults {
    PKPaneUserDefaults.resolve()
  }
}
