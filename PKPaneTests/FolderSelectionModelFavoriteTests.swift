import Foundation
import Testing

@testable import PKPane

@MainActor
struct FolderSelectionModelFavoriteTests {
  @Test("実在するフォルダをお気に入りへ登録する")
  func addsExistingDirectory() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let (model, defaults, suiteName) = makeModel()
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(model.addFavorites(urls: [fixture.directory]))
    #expect(model.favoriteLocations.count == 1)
    #expect(model.favoriteLocations.first?.url == fixture.directory.standardizedFileURL)
  }

  @Test("同じフォルダの重複登録をスキップする")
  func skipsDuplicateDirectory() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let (model, defaults, suiteName) = makeModel()
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(model.addFavorites(urls: [fixture.directory]))
    #expect(model.addFavorites(urls: [fixture.directory]))
    #expect(model.favoriteLocations.count == 1)
  }

  @Test("ファイルと存在しないURLをお気に入りへ登録しない")
  func ignoresNonDirectoryURLs() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let (model, defaults, suiteName) = makeModel()
    defer { defaults.removePersistentDomain(forName: suiteName) }

    #expect(!model.addFavorites(urls: [fixture.file, fixture.missing]))
    #expect(model.favoriteLocations.isEmpty)
  }

  @Test("混在ドロップはフォルダだけを登録し、元ファイルを変更しない")
  func mixedDropPreservesSourceContents() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let (model, defaults, suiteName) = makeModel()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let child = fixture.directory.appending(path: "keep.txt")
    let contents = Data("変更しない".utf8)
    try contents.write(to: child)

    #expect(model.addFavorites(urls: [fixture.file, fixture.directory, fixture.missing]))
    #expect(model.favoriteLocations.map(\.url) == [fixture.directory.standardizedFileURL])
    #expect(FileManager.default.fileExists(atPath: fixture.file.path))
    #expect(try Data(contentsOf: child) == contents)
  }

  @Test(
    "リモート登録は既知のフォルダだけを受け取り、ファイルと不明URLを除外する",
    arguments: ["sftp", "ftp", "ftps"])
  func remoteDropRejectsFilesAndUnknownURLs(scheme: String) throws {
    let providerID = FileProviderID(rawValue: "\(scheme)-test")
    let folderURL = try #require(URL(string: "\(scheme)://example.invalid/folder"))
    let fileURL = try #require(URL(string: "\(scheme)://example.invalid/file.txt"))
    let unknownURL = try #require(URL(string: "\(scheme)://example.invalid/unknown"))
    let folder = FileItem(
      remotePath: "/folder", url: folderURL, providerID: providerID, isDirectory: true)
    let file = FileItem(
      remotePath: "/file.txt", url: fileURL, providerID: providerID, isDirectory: false)
    let snapshot = FileBrowserSelectableItemsSnapshot(uniqueItems: [folder, file])
    var lookedUpURLs = [URL]()
    let resolved = LaunchView.FavoriteDropTargetResolver.remoteFolders(
      urls: [URL(filePath: "/tmp/local"), folderURL, fileURL, unknownURL]
    ) { url in
      lookedUpURLs.append(url)
      return snapshot.item(for: url)
    }

    #expect(resolved == [folder])
    #expect(lookedUpURLs == [folderURL, fileURL, unknownURL])
  }

  @Test("行間への複数登録は順序と元フォルダ内容を保持する")
  func insertionDropRegistersInInputOrderWithoutMovingFiles() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let other = fixture.root.appending(path: "Other", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    let marker = fixture.directory.appending(path: "保持.txt")
    let original = Data("登録時に移動しない".utf8)
    try original.write(to: marker)
    let (model, defaults, suiteName) = makeModel()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let order = SidebarFavoriteOrderModel(defaults: defaults)
    #expect(model.addFavorites(urls: [other]))
    let anchor = try #require(model.favoriteID(for: other)).uuidString
    #expect(
      order.performDrop(
        [fixture.directory, other], before: anchor,
        available: { model.favoriteLocations.map { $0.id.uuidString } },
        register: { url in
          guard model.addFavorites(urls: [url]) else { return nil }
          return model.favoriteID(for: url)?.uuidString
        }))
    let first = try #require(model.favoriteID(for: fixture.directory)).uuidString
    #expect(
      order.orderedIDs(available: model.favoriteLocations.map { $0.id.uuidString })
        == [first, anchor])
    #expect(model.favoriteLocations.count == 2)
    #expect(try Data(contentsOf: marker) == original)
    #expect(FileManager.default.fileExists(atPath: other.path))
  }

  @Test("別ウインドウの登録を再読込しても表示場所を変えない")
  func reloadsFavoritesFromAnotherWindow() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let repository = FolderLocationListRepository(
      storage: InMemoryFolderLocationListStorage(), codec: SystemFolderBookmarkCodec(),
      mode: .favorites)
    let (first, firstDefaults, firstSuite) = makeModel(favoriteRepository: repository)
    let (second, secondDefaults, secondSuite) = makeModel(favoriteRepository: repository)
    defer {
      firstDefaults.removePersistentDomain(forName: firstSuite)
      secondDefaults.removePersistentDomain(forName: secondSuite)
    }
    #expect(first.addFavorites(urls: [fixture.directory]))
    #expect(second.favoriteLocations.isEmpty)
    second.reloadFavorites()
    #expect(second.favoriteID(for: fixture.directory) != nil)
    #expect(second.selectedFolderURL == nil)
    first.removeFavorite(id: try #require(first.favoriteID(for: fixture.directory)))
    second.reloadFavorites()
    #expect(second.favoriteLocations.isEmpty)
  }

  @Test("最近使用した場所の保存に失敗してもエラーメッセージを出さず履歴に載せない")
  func recentLocationSaveFailureStaysSilent() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let suiteName = "test-recent-silent-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let model = FolderSelectionModel(
      repository: FolderBookmarkRepository(
        storage: InMemoryFolderBookmarkStorage(),
        codec: SystemFolderBookmarkCodec()),
      favoriteRepository: FolderLocationListRepository(
        storage: InMemoryFolderLocationListStorage(),
        codec: SystemFolderBookmarkCodec(),
        mode: .favorites),
      recentRepository: FolderLocationListRepository(
        storage: InMemoryFolderLocationListStorage(),
        codec: AlwaysFailingBookmarkCodec(),
        mode: .recent(limit: 5)),
      defaults: defaults)

    model.recordRecentLocation(FileLocation(localURL: fixture.directory))
    // 保存タスクは非公開で完了を直接待てないため、失敗が表面化するのに十分な固定待ちを置く。
    try await Task.sleep(for: .milliseconds(500))

    #expect(model.errorMessage == nil)
    #expect(model.recentLocations.isEmpty)
  }

  private func makeFixture() throws -> (root: URL, directory: URL, file: URL, missing: URL) {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "PKPaneFavoriteTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    let directory = root.appending(path: "Directory", directoryHint: .isDirectory)
    let file = root.appending(path: "File.txt", directoryHint: .notDirectory)
    let missing = root.appending(path: "Missing", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data().write(to: file)
    return (root, directory, file, missing)
  }

  private func makeModel(favoriteRepository: FolderLocationListRepository? = nil) -> (
    model: FolderSelectionModel, defaults: UserDefaults, suiteName: String
  ) {
    let suiteName = "test-favorite-dnd-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    let model = FolderSelectionModel(
      repository: FolderBookmarkRepository(
        storage: InMemoryFolderBookmarkStorage(),
        codec: SystemFolderBookmarkCodec()),
      favoriteRepository: favoriteRepository
        ?? FolderLocationListRepository(
          storage: InMemoryFolderLocationListStorage(),
          codec: SystemFolderBookmarkCodec(),
          mode: .favorites),
      recentRepository: FolderLocationListRepository(
        storage: InMemoryFolderLocationListStorage(),
        codec: SystemFolderBookmarkCodec(),
        mode: .recent(limit: 5)),
      defaults: defaults)
    return (model, defaults, suiteName)
  }
}

/// Macintosh HDのようにブックマークを作れない場所を模す、常に失敗するコーデック。
private struct AlwaysFailingBookmarkCodec: FolderBookmarkCoding, Sendable {
  struct Failure: Error {}

  func createBookmark(for _: URL) throws -> Data { throw Failure() }
  func resolveBookmark(_: Data) throws -> ResolvedFolderBookmark { throw Failure() }
}

private final class InMemoryFolderBookmarkStorage: FolderBookmarkStoring {
  var bookmarkData: Data?

  func loadBookmarkData() -> Data? {
    bookmarkData
  }

  func saveBookmarkData(_ data: Data) {
    bookmarkData = data
  }

  func removeBookmarkData() {
    bookmarkData = nil
  }
}

private final class InMemoryFolderLocationListStorage: FolderLocationListStoring,
  @unchecked Sendable
{
  var locationListData: Data?

  func loadLocationListData() -> Data? {
    locationListData
  }

  func saveLocationListData(_ data: Data) {
    locationListData = data
  }

  func removeLocationListData() {
    locationListData = nil
  }
}
