import Foundation
import Testing

@testable import PKPane

struct SFTPFolderFavoriteRepositoryTests {
  @Test("SFTPフォルダをお気に入りへ追加・削除する")
  func togglesFavorite() throws {
    let suiteName = "SFTPFolderFavoriteRepositoryTests-\(UUID())"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let repository = SFTPFolderFavoriteRepository(defaults: defaults)
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")

    let added = repository.toggle(target: target, directory: "/srv/projects")
    try #require(added.count == 1)
    #expect(added[0].target == target)
    #expect(added[0].directory == "/srv/projects")

    let removed = repository.toggle(target: target, directory: "/srv/projects")
    #expect(removed.isEmpty)
  }
}
