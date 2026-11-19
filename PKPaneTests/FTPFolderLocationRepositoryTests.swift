import Foundation
import Testing

@testable import PKPane

struct FTPFolderLocationRepositoryTests {
  @Test("FTPのお気に入りを正規化して追加・解除する")
  func togglesFavorite() throws {
    let (defaults, suiteName) = isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let repository = FTPFolderFavoriteRepository(defaults: defaults)
    let target = try FTPConnectionTarget(host: "ftp.example.com", username: "tester")

    let added = repository.toggle(target: target, directory: "incoming/")

    #expect(added.count == 1)
    #expect(added.first?.directory == "/incoming")
    #expect(repository.load() == added)
    #expect(repository.toggle(target: target, directory: "/incoming").isEmpty)
  }

  @Test("FTPの履歴は同じ場所を先頭へ更新し上限を守る")
  func recordsRecentWithLimit() throws {
    let (defaults, suiteName) = isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let repository = FTPFolderRecentRepository(defaults: defaults, limit: 2)
    let target = try FTPConnectionTarget(host: "ftp.example.com", username: "tester")

    _ = repository.record(target: target, directory: "/one")
    _ = repository.record(target: target, directory: "/two")
    let recents = repository.record(target: target, directory: "one/")

    #expect(recents.map(\.directory) == ["/one", "/two"])
  }

  private func isolatedDefaults() -> (UserDefaults, String) {
    let suiteName = "FTPFolderLocationRepositoryTests-\(UUID().uuidString)"
    return (UserDefaults(suiteName: suiteName)!, suiteName)
  }
}
