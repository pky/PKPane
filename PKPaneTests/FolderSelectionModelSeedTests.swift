import Foundation
import Testing

@testable import PKPane

@MainActor
struct FolderSelectionModelSeedTests {
  @Test("お気に入りが空の初回起動でApplicationsを含む全候補を注入し、seeded-pathsに記録後は再注入しない")
  func seedsDefaultFavoritesOnlyOnce() throws {
    let suiteName = "test-favorite-seed.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let model = makeModel(defaults: defaults)

    model.seedDefaultFavoritesIfNeeded(environment: [:])
    let names = model.favoriteLocations.map(\.name)
    #expect(names.contains("Desktop"))
    #expect(names.contains("Downloads"))
    #expect(names.contains("Documents"))
    #expect(names.contains("Applications"))
    let seededPaths = defaults.stringArray(forKey: "favorite-defaults-seeded-paths") ?? []
    #expect(seededPaths.contains("/Applications"))

    // 全件削除してもseeded-paths記録済みなので再注入されない
    for favorite in model.favoriteLocations {
      model.removeFavorite(id: favorite.id)
    }
    model.seedDefaultFavoritesIfNeeded(environment: [:])

    #expect(model.favoriteLocations.isEmpty)
  }

  @Test("標準フォルダのブックマークを作成できなくても未許可の項目として保持する")
  func preservesStandardFavoritesWithoutAuthorization() throws {
    let suiteName = "test-favorite-seed-all-failed.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let favoriteStorage = InMemoryFolderLocationListStorage()
    let model = FolderSelectionModel(
      repository: FolderBookmarkRepository(
        storage: InMemoryFolderBookmarkStorage(),
        codec: SystemFolderBookmarkCodec()),
      favoriteRepository: FolderLocationListRepository(
        storage: favoriteStorage,
        codec: FailingFolderBookmarkCodec(),
        mode: .favorites),
      recentRepository: FolderLocationListRepository(
        storage: InMemoryFolderLocationListStorage(),
        codec: SystemFolderBookmarkCodec(),
        mode: .recent(limit: 5)),
      defaults: defaults)

    model.seedDefaultFavoritesIfNeeded(environment: [:])

    #expect(model.favoriteLocations.count == 7)
    #expect(model.favoriteLocations.allSatisfy { $0.requiresAuthorization })
    #expect(defaults.stringArray(forKey: "favorite-defaults-seeded-paths")?.count == 7)
  }

  @Test("旧boolフラグ環境からの移行ではMoviesとApplicationsだけ差分注入され、既存項目は重複しない")
  func migratesFromLegacyFlagAndInjectsOnlyNewCandidates() throws {
    let suiteName = "test-favorite-seed-legacy-migration.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(true, forKey: "favorite-defaults-seeded")
    let favoriteStorage = InMemoryFolderLocationListStorage()
    let favoriteRepository = FolderLocationListRepository(
      storage: favoriteStorage, codec: SystemFolderBookmarkCodec(), mode: .favorites)
    // Movies追加前の旧環境を模して、Movies/Applicationsを除く旧候補6件だけを事前登録する。
    let fileManager = FileManager.default
    let home = UserHomeDirectory.current
    let legacyCandidates =
      [
        FileManager.SearchPathDirectory.desktopDirectory, .downloadsDirectory, .documentDirectory,
        .picturesDirectory,
      ]
      .compactMap { fileManager.urls(for: $0, in: .userDomainMask).first }
      + [home, home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs")]
    for url in legacyCandidates {
      _ = try? favoriteRepository.add(url)
    }
    let model = makeModel(defaults: defaults, favoriteStorage: favoriteStorage)

    model.seedDefaultFavoritesIfNeeded(environment: [:])

    let names = model.favoriteLocations.map(\.name)
    #expect(names.contains("Movies"))
    #expect(names.contains("Applications"))
    // 旧候補が重複登録されていないことを件数で確認する
    #expect(model.favoriteLocations.count(where: { $0.name == "Desktop" }) == 1)
  }

  @Test("ユーザーが削除した項目は再度seedDefaultFavoritesIfNeededを呼んでも再注入されない")
  func doesNotReinjectUserRemovedFavorite() throws {
    let suiteName = "test-favorite-seed-user-removed.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let model = makeModel(defaults: defaults)

    model.seedDefaultFavoritesIfNeeded(environment: [:])
    guard let downloads = model.favoriteLocations.first(where: { $0.name == "Downloads" }) else {
      Issue.record("Downloadsが初回注入されていない")
      return
    }
    model.removeFavorite(id: downloads.id)
    model.seedDefaultFavoritesIfNeeded(environment: [:])

    #expect(!model.favoriteLocations.contains { $0.name == "Downloads" })
  }

  @Test("候補フォルダにiCloud Driveを含めず標準ユーザーフォルダ全種が含まれる")
  func allCandidatesExcludeICloudDriveAndIncludeStandardUserFolders() {
    let fileManager = FileManager.default
    let candidates = FolderSelectionModel.allFavoriteCandidateURLs(fileManager: fileManager)
    let home = UserHomeDirectory.current

    #expect(candidates.contains(home))
    #expect(
      !candidates.contains(home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs")))
    #expect(candidates.contains(fileManager.urls(for: .moviesDirectory, in: .userDomainMask)[0]))
    #expect(
      candidates.contains(
        fileManager.urls(for: .applicationDirectory, in: .localDomainMask).first
          ?? URL(fileURLWithPath: "/Applications")))
    #expect(candidates.count == 7)
  }

  @Test("実在しない候補パス(iCloud Drive無効環境などを想定)はフィルタで除外される")
  func existingCandidatesExcludesNonExistentPaths() {
    let fileManager = FileManager.default
    let existingURL = fileManager.temporaryDirectory
    let nonExistentURL = fileManager.temporaryDirectory
      .appending(path: "PKPaneNonExistentCandidate-\(UUID().uuidString)")

    let result = FolderSelectionModel.existingCandidates(
      among: [existingURL, nonExistentURL], fileManager: fileManager)

    #expect(result == [existingURL])
  }

  @Test("defaultFavoriteCandidateURLsは実在する候補だけを返す")
  func defaultCandidatesOnlyReturnExistingPaths() {
    let fileManager = FileManager.default
    let candidates = FolderSelectionModel.defaultFavoriteCandidateURLs(fileManager: fileManager)

    for url in candidates {
      #expect(fileManager.fileExists(atPath: url.path))
    }
  }

  @Test("ユニットテスト実行環境ではbookmark生成へ到達せず既定お気に入りを注入しない")
  func skipsSeedingUnderUnitTestEnvironment() throws {
    let suiteName = "test-favorite-seed-unit-skip.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let model = makeModel(defaults: defaults)

    model.seedDefaultFavoritesIfNeeded(
      environment: ["XCTestConfigurationFilePath": "/tmp/dummy.xctestconfiguration"])

    #expect(model.favoriteLocations.isEmpty)
    #expect(defaults.stringArray(forKey: "favorite-defaults-seeded-paths") == nil)
  }

  private func makeModel(
    defaults: UserDefaults,
    favoriteStorage: InMemoryFolderLocationListStorage = InMemoryFolderLocationListStorage()
  ) -> FolderSelectionModel {
    FolderSelectionModel(
      repository: FolderBookmarkRepository(
        storage: InMemoryFolderBookmarkStorage(),
        codec: SystemFolderBookmarkCodec()),
      favoriteRepository: FolderLocationListRepository(
        storage: favoriteStorage,
        codec: SystemFolderBookmarkCodec(),
        mode: .favorites),
      recentRepository: FolderLocationListRepository(
        storage: InMemoryFolderLocationListStorage(),
        codec: SystemFolderBookmarkCodec(),
        mode: .recent(limit: 5)),
      defaults: defaults)
  }
}

// テスト専用の可変スパイのため。
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

// 全滅時の再試行(フラグを立てない)を検証するため、常にブックマーク生成を失敗させる。
private struct FailingFolderBookmarkCodec: FolderBookmarkCoding {
  func createBookmark(for url: URL) throws -> Data {
    throw CocoaError(.fileWriteUnknown)
  }

  func resolveBookmark(_ data: Data) throws -> ResolvedFolderBookmark {
    throw CocoaError(.fileReadUnknown)
  }
}

// テスト専用の可変スパイのため。
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
