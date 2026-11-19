import Foundation
import Testing

@testable import PKPane

struct DetailsInspectorPreferencesStoreTests {
  @Test("詳細表示モードとペイン幅を保存して復元する")
  func savesAndLoadsModeAndWidth() {
    let suiteName = "DetailsInspectorPreferencesStoreTests-current"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = DetailsInspectorPreferencesStore(defaults: defaults)

    store.save(DetailsInspectorPreferences(mode: .pane, width: 312))

    #expect(store.load() == DetailsInspectorPreferences(mode: .pane, width: 312))
  }

  @Test("旧isVisibleのtrueを別ペインへ移行する")
  func migratesLegacyVisiblePreferenceToPane() {
    let preferences = decodeLegacyPreferences(isVisible: true)

    #expect(preferences.mode == .pane)
    #expect(preferences.width == 284)
  }

  @Test("旧isVisibleのfalseを出さないへ移行する")
  func migratesLegacyHiddenPreferenceToNone() {
    let preferences = decodeLegacyPreferences(isVisible: false)

    #expect(preferences.mode == .none)
    #expect(preferences.width == 284)
  }

  @Test("廃止したダイアログ設定を別ペインへ移行する")
  func migratesDialogPreferenceToPane() {
    let data = Data("{\"mode\":\"dialog\",\"width\":312}".utf8)
    let preferences = try! JSONDecoder().decode(DetailsInspectorPreferences.self, from: data)

    #expect(preferences == DetailsInspectorPreferences(mode: .pane, width: 312))
  }

  @Test("ペイン切替は別ペインと出さないを往復する")
  func togglesPane() {
    #expect(DetailsDisplayMode.pane.togglingPane == .none)
    #expect(DetailsDisplayMode.none.togglingPane == .pane)
    #expect(DetailsDisplayMode.allCases == [.pane, .none])
  }

  private func decodeLegacyPreferences(isVisible: Bool) -> DetailsInspectorPreferences {
    let data = Data("{\"isVisible\":\(isVisible),\"width\":284}".utf8)
    return try! JSONDecoder().decode(DetailsInspectorPreferences.self, from: data)
  }
}
