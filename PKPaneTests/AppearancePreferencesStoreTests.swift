import AppKit
import Foundation
import Testing

@testable import PKPane

struct AppearancePreferencesStoreTests {
  @Test("クリーム外観を既存の保存キーで保存して復元する")
  func savesAndRestoresCreamAppearance() {
    let (defaults, store, suiteName) = makeStore(suffix: "cream-round-trip")
    defer { defaults.removePersistentDomain(forName: suiteName) }

    store.save(.cream)

    #expect(defaults.string(forKey: "appearance-preference") == "cream")
    #expect(AppearancePreferencesStore(defaults: defaults).load() == .cream)
  }

  @Test("クリーム外観はAquaへ写像する")
  func mapsCreamAppearanceToAqua() {
    #expect(AppAppearanceMapping.appearanceName(for: .cream) == .aqua)
  }

  @Test("外観の選択肢はシステム・ライト・ダーク・クリームの順に並ぶ")
  func exposesAppearanceChoicesInOrder() {
    #expect(AppAppearancePreference.allCases == [.system, .light, .dark, .cream])
  }

  @Test("外観設定を保存して復元する")
  func savesAndLoadsAppearance() {
    let (defaults, store, suiteName) = makeStore(suffix: "round-trip")
    defer { defaults.removePersistentDomain(forName: suiteName) }

    for preference in AppAppearancePreference.allCases {
      store.save(preference)
      #expect(store.load() == preference)
    }
  }

  @Test("未保存または不正な外観設定はシステムへ戻す")
  func fallsBackToSystemAppearance() {
    let (defaults, store, suiteName) = makeStore(suffix: "fallback")
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(store.load() == .system)
    defaults.set("invalid", forKey: "appearance-preference")
    #expect(store.load() == .system)
  }

  @Test("外観選択をAppKitの外観名へ写像する")
  func mapsAppearanceNames() {
    #expect(AppAppearanceMapping.appearanceName(for: .system) == nil)
    #expect(AppAppearanceMapping.appearanceName(for: .light) == .aqua)
    #expect(AppAppearanceMapping.appearanceName(for: .dark) == .darkAqua)
  }

  private func makeStore(
    suffix: String
  ) -> (UserDefaults, AppearancePreferencesStore, String) {
    let suiteName = "AppearancePreferencesStoreTests-\(suffix)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, AppearancePreferencesStore(defaults: defaults), suiteName)
  }
}
