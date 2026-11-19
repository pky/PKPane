import Foundation
import Testing

@testable import PKPane

struct FavoriteSyncRepositoryTests {
  @Test("ローカルとNASのお気に入りをポータブル表現へ変換してブックマークを除外する")
  func convertsLocalAndNASWithoutBookmarkData() throws {
    let fixture = try TemporaryFavoriteDirectory()
    defer { fixture.remove() }
    let repository = FolderLocationListRepository(
      storage: FavoriteSyncFolderListStorage(),
      codec: FavoriteSyncPathBookmarkCodec(),
      mode: .favorites)
    _ = try repository.add(fixture.url)
    let local = try #require(repository.portableFavorites().first)
    let smbIdentifier = try #require(
      PortableFavoriteConnectionIdentifier.smb(host: "nas.local", shareName: "Team Share"))
    let smb = PortableFavorite(
      provider: .smb,
      connectionIdentifier: smbIdentifier,
      path: "/projects/app",
      displayName: "NAS App")
    let document = FavoriteSyncMerger.initialDocument(
      favorites: [local, smb], at: Date(timeIntervalSince1970: 10)
    ).document

    let locations = try repository.applySyncedFavorites(document)
    let portable = try repository.portableFavorites()
    let encoded = try FavoriteSyncCodec.encode(document)

    try #require(locations.count == 2)
    #expect(locations[1].smbLocation?.host == "nas.local")
    #expect(locations[1].smbLocation?.shareName == "Team Share")
    #expect(locations[1].smbLocation?.relativePathComponents == ["projects", "app"])
    #expect(portable.map(\.key) == [local.key, smb.key])
    #expect(!String(decoding: encoded, as: UTF8.self).contains("BOOKMARK:"))

    let deleted = FavoriteSyncMerger.applyingLocalFavorites(
      [], to: document, at: Date(timeIntervalSince1970: 20)
    ).document
    #expect(try repository.applySyncedFavorites(deleted).isEmpty)
  }

  @Test("別端末のローカルパスは利用可能になった初回アクセス時にブックマークを作る")
  func activatesSyncedLocalPathWhenItBecomesAvailable() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "FavoriteSyncUnavailable-\(UUID())", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = FolderLocationListRepository(
      storage: FavoriteSyncFolderListStorage(),
      codec: FavoriteSyncPathBookmarkCodec(),
      mode: .favorites)
    let favorite = PortableFavorite(
      provider: .local, path: root.path, displayName: "Later")
    let document = FavoriteSyncMerger.initialDocument(
      favorites: [favorite], at: Date(timeIntervalSince1970: 10)
    ).document

    let unavailable = try repository.applySyncedFavorites(document)
    #expect(unavailable.first?.url == nil)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    #expect(try repository.add(root).count == 1)
    let activated = try repository.activateSyncedLocalFavorite(
      id: try #require(unavailable.first?.id))

    #expect(activated.first?.url?.standardizedFileURL.path == root.standardizedFileURL.path)
  }

  @Test("SFTPの接続識別子とリモートパスをお気に入りへ往復する")
  func roundTripsSFTPFavorite() throws {
    let suiteName = "FavoriteSyncSFTP-\(UUID())"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let repository = SFTPFolderFavoriteRepository(defaults: defaults)
    let target = try SFTPConnectionTarget(
      host: "example.com", port: 2222, username: "sync-user")
    let identifier = try #require(PortableFavoriteConnectionIdentifier.sftp(target: target))
    let portable = PortableFavorite(
      provider: .sftp,
      connectionIdentifier: identifier,
      path: "/srv/projects",
      displayName: "Remote")
    let document = FavoriteSyncMerger.initialDocument(
      favorites: [portable], at: Date(timeIntervalSince1970: 10)
    ).document

    let favorites = repository.applySyncedFavorites(document)

    try #require(favorites.count == 1)
    #expect(favorites[0].target == target)
    #expect(favorites[0].directory == "/srv/projects")
    #expect(try repository.portableFavorites().first?.key == portable.key)
  }
}

private struct TemporaryFavoriteDirectory {
  let url: URL

  init() throws {
    url = FileManager.default.temporaryDirectory.appending(
      path: "FavoriteSyncRepository-\(UUID())", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  func remove() {
    try? FileManager.default.removeItem(at: url)
  }
}

private final class FavoriteSyncFolderListStorage: FolderLocationListStoring,
  @unchecked Sendable
{
  private var data: Data?

  func loadLocationListData() -> Data? { data }
  func saveLocationListData(_ data: Data) { self.data = data }
  func removeLocationListData() { data = nil }
}

private struct FavoriteSyncPathBookmarkCodec: FolderBookmarkCoding, Sendable {
  private struct InvalidBookmark: Error {}

  func createBookmark(for url: URL) throws -> Data {
    Data("BOOKMARK:\(url.standardizedFileURL.path)".utf8)
  }

  func resolveBookmark(_ data: Data) throws -> ResolvedFolderBookmark {
    let value = String(decoding: data, as: UTF8.self)
    guard value.hasPrefix("BOOKMARK:") else { throw InvalidBookmark() }
    return ResolvedFolderBookmark(
      url: URL(filePath: String(value.dropFirst("BOOKMARK:".count))),
      isStale: false)
  }
}
