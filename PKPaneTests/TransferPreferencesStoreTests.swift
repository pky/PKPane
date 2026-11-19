import Foundation
import Testing

@testable import PKPane

@MainActor
struct TransferPreferencesStoreTests {
  @Test("帯域制限を保存して復元する")
  func savesAndLoadsBandwidthLimit() {
    let (defaults, store) = makeStore(suffix: "round-trip")
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName(suffix: "round-trip")) }

    store.save(TransferPreferences(bandwidthLimitBytesPerSecond: 5_000_000))

    #expect(
      store.load() == TransferPreferences(bandwidthLimitBytesPerSecond: 5_000_000))
  }

  @Test("未保存または壊れた設定は無制限の既定値へ戻す")
  func fallsBackToUnlimitedDefault() {
    let suffix = "default"
    let (defaults, store) = makeStore(suffix: suffix)
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName(suffix: suffix)) }

    #expect(store.load() == TransferPreferences())
    defaults.set(Data("invalid".utf8), forKey: "transfer-preferences")
    #expect(
      TransferPreferencesStore(defaults: defaults).load()
        == TransferPreferences())
  }

  private func makeStore(suffix: String) -> (UserDefaults, TransferPreferencesStore) {
    let suiteName = defaultsSuiteName(suffix: suffix)
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, TransferPreferencesStore(defaults: defaults))
  }

  private func defaultsSuiteName(suffix: String) -> String {
    "TransferPreferencesStoreTests-\(suffix)"
  }
}
