import Foundation
import Testing

@testable import PKPane

struct NASConnectionProfileStoreTests {
  @Test("NAS接続先を保存、更新、削除できる")
  func savesUpdatesAndRemovesProfiles() throws {
    let suiteName = "NASConnectionProfileStoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = NASConnectionProfileStore(defaults: defaults)
    let id = UUID()
    let initial = try NASConnectionProfile(
      id: id, displayName: "NAS", host: "nas.example.local", shareName: "Documents")
    let updated = try NASConnectionProfile(
      id: id, displayName: "開発用NAS", host: "nas.example.local", shareName: "Projects")

    store.save(initial)
    store.save(updated)

    #expect(store.load() == [updated])

    store.remove(id: id)

    #expect(store.load().isEmpty)
  }
}
