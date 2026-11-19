import Foundation
import Testing

@testable import PKPane

@MainActor
struct GitStatusPreferencesStoreTests {
  @Test("Gitステータス表示は未保存時OFFで保存後に復元できる")
  func defaultsToOffAndRestoresSavedValue() {
    let suiteName = "GitStatusPreferencesStoreTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.removePersistentDomain(forName: suiteName)
    let store = GitStatusPreferencesStore(defaults: defaults)

    #expect(!store.isEnabled)
    store.save(true)
    #expect(GitStatusPreferencesStore(defaults: defaults).isEnabled)

    store.remove()
    #expect(!store.isEnabled)
    #expect(!GitStatusPreferencesStore(defaults: defaults).isEnabled)
  }
}
