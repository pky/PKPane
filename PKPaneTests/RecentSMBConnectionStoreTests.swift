import Foundation
import Testing

@testable import PKPane

struct RecentSMBConnectionStoreTests {
  @Test("最近のSMB接続は新しい順に5件まで保持する")
  func retainsFiveMostRecentConnections() throws {
    let suiteName = "RecentSMBConnectionStoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = RecentSMBConnectionStore(defaults: defaults)

    for index in 0..<6 {
      store.record(try RecentSMBConnection(host: "nas\(index).local", shareName: "Documents"))
    }

    #expect(
      store.load().map(\.host) == [
        "nas5.local", "nas4.local", "nas3.local", "nas2.local", "nas1.local",
      ])
  }
}
