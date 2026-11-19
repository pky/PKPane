import Foundation
import Testing

@testable import PKPane

@MainActor
struct FavoriteSyncIntegrationTests {
  @Test("お気に入り追加の実経路でKVSへ書き出し外部変更を一覧へ反映する")
  func connectsModelsToSyncCoordinator() async throws {
    let localDirectory = try makeDirectory(named: "Local")
    let remoteDirectory = try makeDirectory(named: "Remote")
    defer {
      try? FileManager.default.removeItem(at: localDirectory.deletingLastPathComponent())
      try? FileManager.default.removeItem(at: remoteDirectory.deletingLastPathComponent())
    }
    let (folderSelection, folderSelectionDefaults, folderSelectionSuiteName) =
      makeFolderSelectionModel()
    defer { folderSelectionDefaults.removePersistentDomain(forName: folderSelectionSuiteName) }
    let (sftpConnections, sftpConnectionsDefaults, sftpConnectionsSuiteName) =
      makeSFTPConnectionListModel()
    defer { sftpConnectionsDefaults.removePersistentDomain(forName: sftpConnectionsSuiteName) }
    let kvs = IntegrationFavoriteSyncKeyValueStore()
    let coordinator = FavoriteSyncCoordinator(
      store: kvs,
      localStore: IntegrationFavoriteSyncLocalStore(),
      debounceDuration: .milliseconds(1),
      now: { Date(timeIntervalSince1970: 100) })
    let integration = FavoriteSyncIntegrationController(
      coordinator: coordinator,
      folderSelection: folderSelection,
      sftpConnections: sftpConnections)
    integration.start()
    await coordinator.waitForPendingWrite()
    kvs.setCallCount = 0

    folderSelection.toggleFavorite(url: localDirectory)
    await coordinator.waitForPendingWrite()

    #expect(kvs.setCallCount == 1)
    let writtenData = try #require(kvs.values[FavoriteSyncCoordinator.key])
    let written = try FavoriteSyncCodec.decode(writtenData)
    #expect(written.items.map(\.favorite.path) == [localDirectory.standardizedFileURL.path])

    let sftpTarget = try SFTPConnectionTarget(
      host: "sync.example.com", port: 22, username: "tester")
    let sftpIdentifier = try #require(
      PortableFavoriteConnectionIdentifier.sftp(target: sftpTarget))
    let remoteDocument = FavoriteSyncMerger.initialDocument(
      favorites: [
        PortableFavorite(
          provider: .local,
          path: remoteDirectory.standardizedFileURL.path,
          displayName: "Remote"),
        PortableFavorite(
          provider: .sftp,
          connectionIdentifier: sftpIdentifier,
          path: "/srv/shared",
          displayName: "SFTP Shared"),
      ],
      at: Date(timeIntervalSince1970: 200)
    ).document
    kvs.values[FavoriteSyncCoordinator.key] = try FavoriteSyncCodec.encode(remoteDocument)

    kvs.sendExternalChange()
    await coordinator.waitForPendingWrite()

    #expect(
      Set(folderSelection.favoriteLocations.compactMap(\.url?.standardizedFileURL.path))
        == [localDirectory.standardizedFileURL.path, remoteDirectory.standardizedFileURL.path])
    #expect(sftpConnections.favoriteFolders.map(\.directory) == ["/srv/shared"])
  }

  @Test("起動時のローカルお気に入りデコード失敗では同期を開始しない")
  func skipsStartWhenLocalFavoritesCannotBeDecoded() async {
    let (folderSelection, folderSelectionDefaults, folderSelectionSuiteName) =
      makeFolderSelectionModel(
        favoriteStorage: IntegrationFolderListStorage(data: Data([0xFF])))
    defer { folderSelectionDefaults.removePersistentDomain(forName: folderSelectionSuiteName) }
    let (sftpConnections, sftpConnectionsDefaults, sftpConnectionsSuiteName) =
      makeSFTPConnectionListModel()
    defer { sftpConnectionsDefaults.removePersistentDomain(forName: sftpConnectionsSuiteName) }
    let kvs = IntegrationFavoriteSyncKeyValueStore()
    let coordinator = FavoriteSyncCoordinator(
      store: kvs,
      localStore: IntegrationFavoriteSyncLocalStore(),
      debounceDuration: .milliseconds(1))
    let integration = FavoriteSyncIntegrationController(
      coordinator: coordinator,
      folderSelection: folderSelection,
      sftpConnections: sftpConnections)

    integration.start()
    await coordinator.waitForPendingWrite()

    #expect(kvs.synchronizeCallCount == 0)
    #expect(kvs.setCallCount == 0)
  }

  @Test("実行中のSFTPお気に入りデコード失敗では同期発行と削除をスキップする")
  func skipsPublishWhenSFTPFavoritesCannotBeDecoded() async throws {
    let localDirectory = try makeDirectory(named: "LocalAfterCorruption")
    defer { try? FileManager.default.removeItem(at: localDirectory.deletingLastPathComponent()) }
    let (folderSelection, folderSelectionDefaults, folderSelectionSuiteName) =
      makeFolderSelectionModel()
    defer { folderSelectionDefaults.removePersistentDomain(forName: folderSelectionSuiteName) }
    let suiteName = "FavoriteSyncCorruption-\(UUID())"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let favoriteRepository = SFTPFolderFavoriteRepository(defaults: defaults)
    let target = try SFTPConnectionTarget(
      host: "corruption.example.com", port: 22, username: "tester")
    _ = favoriteRepository.toggle(target: target, directory: "/kept")
    let sftpConnections = SFTPConnectionListModel(
      profileStore: SFTPConnectionProfileStore(defaults: defaults),
      hostKeyTrustStore: SFTPHostKeyTrustStore(defaults: defaults),
      favoriteRepository: favoriteRepository,
      recentRepository: SFTPFolderRecentRepository(defaults: defaults))
    let kvs = IntegrationFavoriteSyncKeyValueStore()
    let coordinator = FavoriteSyncCoordinator(
      store: kvs,
      localStore: IntegrationFavoriteSyncLocalStore(),
      debounceDuration: .milliseconds(1),
      now: { Date(timeIntervalSince1970: 100) })
    let integration = FavoriteSyncIntegrationController(
      coordinator: coordinator,
      folderSelection: folderSelection,
      sftpConnections: sftpConnections)
    integration.start()
    await coordinator.waitForPendingWrite()
    kvs.setCallCount = 0
    defaults.set(Data([0xFF]), forKey: "favorite-sftp-folders")

    folderSelection.toggleFavorite(url: localDirectory)
    await coordinator.waitForPendingWrite()

    #expect(kvs.setCallCount == 0)
    let data = try #require(kvs.values[FavoriteSyncCoordinator.key])
    let document = try FavoriteSyncCodec.decode(data)
    #expect(document.items.map(\.favorite.path) == ["/kept"])
    #expect(document.tombstones.isEmpty)
  }

  private func makeDirectory(named name: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "FavoriteSyncIntegration-\(UUID())", directoryHint: .isDirectory)
    let directory = root.appending(path: name, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func makeFolderSelectionModel(
    favoriteStorage: IntegrationFolderListStorage = IntegrationFolderListStorage()
  ) -> (model: FolderSelectionModel, defaults: UserDefaults, suiteName: String) {
    let suiteName = "FavoriteSyncIntegrationFolder-\(UUID())"
    let defaults = UserDefaults(suiteName: suiteName)!
    let model = FolderSelectionModel(
      repository: FolderBookmarkRepository(
        storage: IntegrationFolderBookmarkStorage(),
        codec: IntegrationPathBookmarkCodec()),
      favoriteRepository: FolderLocationListRepository(
        storage: favoriteStorage,
        codec: IntegrationPathBookmarkCodec(),
        mode: .favorites),
      recentRepository: FolderLocationListRepository(
        storage: IntegrationFolderListStorage(),
        codec: IntegrationPathBookmarkCodec(),
        mode: .recent(limit: 5)),
      defaults: defaults)
    return (model, defaults, suiteName)
  }

  private func makeSFTPConnectionListModel() -> (
    model: SFTPConnectionListModel, defaults: UserDefaults, suiteName: String
  ) {
    let suiteName = "FavoriteSyncIntegrationSFTP-\(UUID())"
    let defaults = UserDefaults(suiteName: suiteName)!
    let model = SFTPConnectionListModel(
      profileStore: SFTPConnectionProfileStore(defaults: defaults),
      hostKeyTrustStore: SFTPHostKeyTrustStore(defaults: defaults),
      favoriteRepository: SFTPFolderFavoriteRepository(defaults: defaults),
      recentRepository: SFTPFolderRecentRepository(defaults: defaults))
    return (model, defaults, suiteName)
  }
}

@MainActor
private final class IntegrationFavoriteSyncKeyValueStore: FavoriteSyncKeyValueStoring {
  var values: [String: Data] = [:]
  var synchronizeCallCount = 0
  var setCallCount = 0
  private var handler: (@MainActor @Sendable () -> Void)?

  func data(forKey key: String) -> Data? { values[key] }
  func set(_ data: Data, forKey key: String) {
    setCallCount += 1
    values[key] = data
  }
  func synchronize() { synchronizeCallCount += 1 }
  func setExternalChangeHandler(
    forKey _: String,
    _ handler: (@MainActor @Sendable () -> Void)?
  ) {
    self.handler = handler
  }
  func sendExternalChange() { handler?() }
}

@MainActor
private final class IntegrationFavoriteSyncLocalStore: FavoriteSyncLocalDocumentStoring {
  private var data: Data?
  func loadDocumentData() -> Data? { data }
  func saveDocumentData(_ data: Data) { self.data = data }
}

private final class IntegrationFolderBookmarkStorage: FolderBookmarkStoring {
  private var data: Data?
  func loadBookmarkData() -> Data? { data }
  func saveBookmarkData(_ data: Data) { self.data = data }
  func removeBookmarkData() { data = nil }
}

private final class IntegrationFolderListStorage: FolderLocationListStoring,
  @unchecked Sendable
{
  private var data: Data?

  init(data: Data? = nil) {
    self.data = data
  }
  func loadLocationListData() -> Data? { data }
  func saveLocationListData(_ data: Data) { self.data = data }
  func removeLocationListData() { data = nil }
}

private struct IntegrationPathBookmarkCodec: FolderBookmarkCoding, Sendable {
  private struct InvalidBookmark: Error {}

  func createBookmark(for url: URL) throws -> Data {
    Data(url.standardizedFileURL.path.utf8)
  }

  func resolveBookmark(_ data: Data) throws -> ResolvedFolderBookmark {
    let path = String(decoding: data, as: UTF8.self)
    guard !path.isEmpty else { throw InvalidBookmark() }
    return ResolvedFolderBookmark(url: URL(filePath: path), isStale: false)
  }
}
