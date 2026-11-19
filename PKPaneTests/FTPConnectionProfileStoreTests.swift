import Foundation
import Testing

@testable import PKPane

struct FTPConnectionProfileStoreTests {
  @Test("複数のFTP接続先を保存・置換・削除する")
  func persistsTargets() throws {
    let suiteName = "FTPConnectionProfileStoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let first = try FTPConnectionTarget(host: "one.example.com", username: "tester")
    let second = try FTPConnectionTarget(
      host: "two.example.com", port: 2121, username: "tester", security: .plain)
    let updated = try FTPConnectionTarget(host: "three.example.com", username: "tester")
    let store = FTPConnectionProfileStore(defaults: defaults)

    store.save(first)
    store.save(second)
    #expect(store.loadAll() == [first, second])

    store.replace(first, with: updated)
    #expect(store.loadAll() == [second, updated])

    store.remove(second)
    #expect(store.loadAll() == [updated])
  }
}
