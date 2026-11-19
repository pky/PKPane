import Foundation
import Testing

@testable import PKPane

struct SFTPFolderRecentRepositoryTests {
  @Test("SFTPフォルダの最近使用した場所は最新順に重複なく保存する")
  func recordsRecentFolder() throws {
    let suiteName = "SFTPFolderRecentRepositoryTests-\(UUID())"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let repository = SFTPFolderRecentRepository(defaults: defaults)
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")

    repository.record(target: target, directory: "/srv/first")
    let recents = repository.record(target: target, directory: "/srv/second")
    let reordered = repository.record(target: target, directory: "/srv/first")

    #expect(recents.map(\.directory) == ["/srv/second", "/srv/first"])
    #expect(reordered.map(\.directory) == ["/srv/first", "/srv/second"])
  }

  @Test("SFTPフォルダの最近使用した場所は保存上限を守る")
  func limitsRecentFolders() throws {
    let suiteName = "SFTPFolderRecentRepositoryLimitTests-\(UUID())"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let repository = SFTPFolderRecentRepository(defaults: defaults, limit: 2)
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")

    repository.record(target: target, directory: "/srv/one")
    repository.record(target: target, directory: "/srv/two")
    let recents = repository.record(target: target, directory: "/srv/three")

    #expect(recents.map(\.directory) == ["/srv/three", "/srv/two"])
  }
}
