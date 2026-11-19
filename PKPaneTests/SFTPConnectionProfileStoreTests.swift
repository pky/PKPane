import Foundation
import Testing

@testable import PKPane

struct SFTPConnectionProfileStoreTests {
  @Test("接続先を保存して復元する")
  func savesAndLoadsTarget() throws {
    let suiteName = "SFTPConnectionProfileStoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let store = SFTPConnectionProfileStore(defaults: defaults)

    store.save(target)

    #expect(store.load() == target)
  }

  @Test("複数のSFTP接続先を保持する")
  func savesMultipleTargets() throws {
    let suiteName = "SFTPConnectionProfileStoreMultipleTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let first = try SFTPConnectionTarget(host: "one.example.com", port: 22, username: "tester")
    let second = try SFTPConnectionTarget(host: "two.example.com", port: 2222, username: "tester")
    let store = SFTPConnectionProfileStore(defaults: defaults)

    store.save(first)
    store.save(second)

    #expect(store.loadAll() == [first, second])
  }

  @Test("接続先の編集時に以前のプロフィールを置き換える")
  func replacesExistingTarget() throws {
    let suiteName = "SFTPConnectionProfileStoreReplaceTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let existing = try SFTPConnectionTarget(host: "old.example.com", port: 22, username: "tester")
    let updated = try SFTPConnectionTarget(host: "new.example.com", port: 2222, username: "tester")
    let store = SFTPConnectionProfileStore(defaults: defaults)
    store.save(existing)

    store.replace(existing, with: updated)

    #expect(store.loadAll() == [updated])
  }
}
