import Foundation
import Testing

@testable import PKPane

struct FolderBookmarkRepositoryTests {
  @Test("保存場所のiCloud管理判定は未解決URLを除外し結果をキャッシュする")
  func savedLocationICloudManagedFolderUsesInjectedValueAndCachesIt() {
    let unresolved = SavedFolderLocation(id: UUID(), name: "未解決", url: nil)
    #expect(
      !SavedFolderLocation.isICloudManagedFolder(
        url: unresolved.url,
        isUbiquitousItem: { _ in
          Issue.record("未解決URLで問い合わせてはいけません")
          return true
        }))

    let cloudURL = URL(filePath: "/tmp/icloud-status-\(UUID().uuidString)")
    var callCount = 0
    let first = SavedFolderLocation.isICloudManagedFolder(url: cloudURL) { _ in
      callCount += 1
      return true
    }
    let second = SavedFolderLocation.isICloudManagedFolder(url: cloudURL) { _ in
      callCount += 1
      return false
    }

    #expect(first)
    #expect(second)
    #expect(callCount == 1)
  }

  @Test("保存場所のiCloud管理判定はubiquitous属性がfalseならfalseを返す")
  func savedLocationICloudManagedFolderReflectsFalseUbiquitousValue() {
    let url = URL(filePath: "/tmp/not-icloud-\(UUID().uuidString)")

    #expect(!SavedFolderLocation.isICloudManagedFolder(url: url, isUbiquitousItem: { _ in false }))
  }

  @Test("選択したフォルダのSecurity-Scoped Bookmarkを保存する")
  func saveStoresBookmarkDataForSelectedFolder() throws {
    let folderURL = URL(fileURLWithPath: "/Users/test/Documents")
    let storage = InMemoryFolderBookmarkStorage()
    let codec = TestFolderBookmarkCodec(
      bookmarkDataByURL: [folderURL: Data("bookmark".utf8)],
      resolvedBookmarkByData: [:]
    )
    let repository = FolderBookmarkRepository(storage: storage, codec: codec)

    try repository.save(folderURL)

    #expect(storage.bookmarkData == Data("bookmark".utf8))
  }

  @Test("保存済みBookmarkからフォルダを復元する")
  func restoreReturnsSavedFolder() throws {
    let folderURL = URL(fileURLWithPath: "/Users/test/Documents")
    let bookmarkData = Data("bookmark".utf8)
    let storage = InMemoryFolderBookmarkStorage(bookmarkData: bookmarkData)
    let codec = TestFolderBookmarkCodec(
      bookmarkDataByURL: [:],
      resolvedBookmarkByData: [bookmarkData: ResolvedFolderBookmark(url: folderURL, isStale: false)]
    )
    let repository = FolderBookmarkRepository(storage: storage, codec: codec)

    let restoredURL = try repository.restore()

    #expect(restoredURL == folderURL)
    #expect(storage.bookmarkData == bookmarkData)
  }

  @Test("staleなBookmarkは解決したURLで再生成する")
  func restoreRefreshesStaleBookmark() throws {
    let folderURL = URL(fileURLWithPath: "/Volumes/External/Documents")
    let staleBookmarkData = Data("stale".utf8)
    let refreshedBookmarkData = Data("refreshed".utf8)
    let storage = InMemoryFolderBookmarkStorage(bookmarkData: staleBookmarkData)
    let codec = TestFolderBookmarkCodec(
      bookmarkDataByURL: [folderURL: refreshedBookmarkData],
      resolvedBookmarkByData: [
        staleBookmarkData: ResolvedFolderBookmark(url: folderURL, isStale: true)
      ]
    )
    let repository = FolderBookmarkRepository(storage: storage, codec: codec)

    let restoredURL = try repository.restore()

    #expect(restoredURL == folderURL)
    #expect(storage.bookmarkData == refreshedBookmarkData)
  }

  @Test("お気に入りを追加・並べ替え・削除する")
  func managesFavorites() throws {
    let firstURL = URL(fileURLWithPath: "/Users/test/Documents")
    let secondURL = URL(fileURLWithPath: "/Users/test/Downloads")
    let firstData = Data("documents".utf8)
    let secondData = Data("downloads".utf8)
    let storage = InMemoryFolderLocationListStorage()
    let codec = TestFolderBookmarkCodec(
      bookmarkDataByURL: [firstURL: firstData, secondURL: secondData],
      resolvedBookmarkByData: [
        firstData: ResolvedFolderBookmark(url: firstURL, isStale: false),
        secondData: ResolvedFolderBookmark(url: secondURL, isStale: false),
      ])
    let repository = FolderLocationListRepository(
      storage: storage, codec: codec, mode: .favorites)

    _ = try repository.add(firstURL)
    _ = try repository.add(secondURL)
    var favorites = try repository.add(firstURL)

    #expect(favorites.map(\.url) == [firstURL, secondURL])

    favorites = try repository.move(id: secondURLLocationID(in: favorites), by: -1)
    #expect(favorites.map(\.url) == [secondURL, firstURL])

    favorites = try repository.remove(id: secondURLLocationID(in: favorites))
    #expect(favorites.map(\.url) == [firstURL])
  }

  @Test("再許可したフォルダは保存先IDを保ってブックマークを更新する")
  func refreshesFavoriteBookmarkWithoutDuplicatingLocation() throws {
    struct StoredBookmark: Decodable {
      let bookmarkData: Data
    }

    let url = URL(filePath: "/Users/test/Library/CloudStorage/Dropbox")
    let oldData = Data("old".utf8)
    let newData = Data("new".utf8)
    let storage = InMemoryFolderLocationListStorage()
    let original = FolderLocationListRepository(
      storage: storage,
      codec: TestFolderBookmarkCodec(
        bookmarkDataByURL: [url: oldData],
        resolvedBookmarkByData: [oldData: ResolvedFolderBookmark(url: url, isStale: false)]),
      mode: .favorites)
    let id = try #require(original.add(url).first?.id)
    let refreshed = FolderLocationListRepository(
      storage: storage,
      codec: TestFolderBookmarkCodec(
        bookmarkDataByURL: [url: newData],
        resolvedBookmarkByData: [
          oldData: ResolvedFolderBookmark(url: url, isStale: false),
          newData: ResolvedFolderBookmark(url: url, isStale: false),
        ]),
      mode: .favorites)

    let locations = try refreshed.refreshFavoriteBookmark(for: url)
    let data = try #require(storage.locationListData)
    let records = try JSONDecoder().decode([StoredBookmark].self, from: data)

    #expect(locations.map(\.id) == [id])
    #expect(records.map(\.bookmarkData) == [newData])
  }

  @Test("最近使用した場所を重複なく新しい順に10件保持する")
  func limitsAndDeduplicatesRecentLocations() throws {
    let urls = (0..<12).map { URL(fileURLWithPath: "/Users/test/folder-\($0)") }
    let bookmarkPairs = urls.map { ($0, Data($0.path.utf8)) }
    let codec = TestFolderBookmarkCodec(
      bookmarkDataByURL: Dictionary(uniqueKeysWithValues: bookmarkPairs),
      resolvedBookmarkByData: Dictionary(
        uniqueKeysWithValues: bookmarkPairs.map {
          ($0.1, ResolvedFolderBookmark(url: $0.0, isStale: false))
        }))
    let repository = FolderLocationListRepository(
      storage: InMemoryFolderLocationListStorage(),
      codec: codec,
      mode: .recent(limit: 10))

    for url in urls {
      _ = try repository.add(url)
    }
    let recent = try repository.add(urls[5])

    #expect(recent.count == 10)
    #expect(recent.first?.url == urls[5])
    #expect(recent.filter { $0.url == urls[5] }.count == 1)
    #expect(!recent.contains { $0.url == urls[0] })
  }

  @Test("同じSMBフォルダの再訪で履歴を増やさず別サーバーと子フォルダは残す")
  func recentSMBLocationsDeduplicateByShareAndRelativePath() throws {
    let storage = InMemoryFolderLocationListStorage()
    let urls = ["/Volumes/common", "/Volumes/common-1", "/Volumes/other", "/Volumes/common/child"]
      .map { URL(fileURLWithPath: $0).standardizedFileURL }
    let codec = TestFolderBookmarkCodec(
      bookmarkDataByURL: Dictionary(uniqueKeysWithValues: urls.map { ($0, Data($0.path.utf8)) }),
      resolvedBookmarkByData: [:])
    let repository = FolderLocationListRepository(
      storage: storage, codec: codec, mode: .recent(limit: 10),
      smbLocationForURL: { url in
        SMBFolderLocation(
          host: url.lastPathComponent == "other" ? "other.invalid" : "nas.invalid",
          shareName: "common",
          relativePathComponents: url.lastPathComponent == "child" ? ["child"] : [])
      })

    _ = try repository.add(urls[0])
    _ = try repository.add(urls[2])
    _ = try repository.add(urls[3])
    _ = try repository.add(urls[1])
    let locations = try repository.add(urls[1])

    #expect(locations.count == 3)
    #expect(locations.first?.lastKnownPath == urls[1].path)
    #expect(locations.contains { $0.smbLocation?.host == "other.invalid" })
    #expect(locations.contains { $0.smbLocation?.relativePathComponents == ["child"] })
  }

  @Test("保存済みSMB重複履歴は読込時に最新のIDを残して整理し再読込でも保持する")
  func loadDeduplicatesPersistedSMBRecents() throws {
    let storage = InMemoryFolderLocationListStorage()
    let newestID = UUID()
    let records: [[String: Any]] = [
      (newestID, "NAS.INVALID", "common", "/Volumes/common-1"),
      (UUID(), "nas.invalid", "COMMON", "/Volumes/common"),
      (UUID(), "other.invalid", "common", "/Volumes/other"),
    ].map { id, host, share, path in
      [
        "id": id.uuidString, "name": "common", "bookmarkData": "",
        "lastKnownPath": path,
        "smbLocation": ["host": host, "shareName": share, "relativePathComponents": []],
      ]
    }
    storage.locationListData = try JSONSerialization.data(withJSONObject: records)
    let repository = FolderLocationListRepository(
      storage: storage, codec: UnavailableFolderBookmarkCodec(), mode: .recent(limit: 2))

    let locations = try repository.load()
    #expect(locations.count == 2)
    #expect(locations.first?.id == newestID)
    let reloaded = FolderLocationListRepository(
      storage: storage, codec: UnavailableFolderBookmarkCodec(), mode: .recent(limit: 2))
    #expect(try reloaded.load() == locations)
  }

  @Test("スコープ付き解決がフォーマットエラー(259)の場合はスコープなしで再解決しネットワークボリュームなら採用する")
  func resolveBookmarkFallsBackToUnscopedResolutionForNetworkVolume() throws {
    let networkURL = URL(fileURLWithPath: "/Volumes/NAS/Projects/Design", isDirectory: true)
    let bookmarkData = Data("smb-bookmark".utf8)
    let formatError = NSError(domain: NSCocoaErrorDomain, code: 259)
    let resolver = FakeBookmarkDataResolver(responses: [
      ([.withSecurityScope, .withoutMounting], .failure(formatError)),
      ([.withoutMounting], .success(networkURL, false)),
    ])
    let codec = SystemFolderBookmarkCodec(resolver: resolver)

    let resolved = try codec.resolveBookmark(bookmarkData)

    #expect(resolved.url == networkURL)
    #expect(resolved.isStale == false)
    #expect(resolver.callCount(for: [.withSecurityScope, .withoutMounting]) == 1)
    #expect(resolver.callCount(for: [.withoutMounting]) == 1)
  }

  @Test("スコープなし再解決の結果がローカルURLの場合は従来どおり失敗扱いにする")
  func resolveBookmarkKeepsFailingForLocalURLFallback() throws {
    let localURL = URL(fileURLWithPath: "/Users/test/Documents", isDirectory: true)
    let bookmarkData = Data("local-bookmark".utf8)
    let formatError = NSError(domain: NSCocoaErrorDomain, code: 259)
    let resolver = FakeBookmarkDataResolver(responses: [
      ([.withSecurityScope, .withoutMounting], .failure(formatError)),
      ([.withoutMounting], .success(localURL, false)),
    ])
    let codec = SystemFolderBookmarkCodec(resolver: resolver)

    #expect(throws: formatError) {
      try codec.resolveBookmark(bookmarkData)
    }
  }

  @Test("フォーマットエラー(259)以外はスコープなし再解決を試みない")
  func resolveBookmarkDoesNotFallBackForOtherErrors() throws {
    let bookmarkData = Data("other-error-bookmark".utf8)
    let otherError = NSError(domain: NSCocoaErrorDomain, code: 260)
    let resolver = FakeBookmarkDataResolver(responses: [
      ([.withSecurityScope, .withoutMounting], .failure(otherError))
    ])
    let codec = SystemFolderBookmarkCodec(resolver: resolver)

    #expect(throws: otherError) {
      try codec.resolveBookmark(bookmarkData)
    }
    #expect(resolver.callCount(for: [.withoutMounting]) == 0)
  }

  @Test("smbLocation未保存の既存レコードもload()でurlとlastKnownPathを自己修復し再読込でも保持する")
  func loadSelfHealsLegacyNASRecordMissingSMBLocation() throws {
    // SMBFolderLocation(folderURL:)は実際にマウント済みのボリュームでしか解決できないため、
    // このテスト環境(ボリューム未マウント)ではsmbLocationの自己修復までは検証できない。
    // url/lastKnownPathの自己修復とその永続化を検証し、smbLocationの実機検証は別途行う。
    let networkURL = URL(fileURLWithPath: "/Volumes/NAS/Projects/Design", isDirectory: true)
    let bookmarkData = Data("legacy-nas-bookmark".utf8)
    let storage = InMemoryFolderLocationListStorage()
    storage.locationListData = try legacyRecordListData(
      name: "設計書", bookmarkData: bookmarkData)
    let codec = TestFolderBookmarkCodec(
      bookmarkDataByURL: [:],
      resolvedBookmarkByData: [
        bookmarkData: ResolvedFolderBookmark(url: networkURL, isStale: false)
      ])
    let repository = FolderLocationListRepository(
      storage: storage, codec: codec, mode: .favorites)

    let favorites = try repository.load()

    try #require(favorites.count == 1)
    #expect(favorites[0].url == networkURL.standardizedFileURL)
    #expect(favorites[0].lastKnownPath == networkURL.path)

    // 自己修復したlastKnownPathが永続化され、コーデックが再び失敗するようになっても
    // (=切断中でも)名前とlastKnownPathは保持され続けることを確認する。
    let reloadedRepository = FolderLocationListRepository(
      storage: storage,
      codec: UnavailableFolderBookmarkCodec(),
      mode: .favorites)
    let reloadedFavorites = try reloadedRepository.load()

    try #require(reloadedFavorites.count == 1)
    #expect(reloadedFavorites[0].url == nil)
    #expect(reloadedFavorites[0].lastKnownPath == favorites[0].lastKnownPath)
  }

  @Test("解決できないお気に入りを警告対象として保持する")
  func keepsUnavailableFavorite() throws {
    let folderURL = URL(fileURLWithPath: "/Volumes/Disconnected")
    let bookmarkData = Data("disconnected".utf8)
    let storage = InMemoryFolderLocationListStorage()
    let writableRepository = FolderLocationListRepository(
      storage: storage,
      codec: TestFolderBookmarkCodec(
        bookmarkDataByURL: [folderURL: bookmarkData],
        resolvedBookmarkByData: [
          bookmarkData: ResolvedFolderBookmark(url: folderURL, isStale: false)
        ]),
      mode: .favorites)
    _ = try writableRepository.add(folderURL)
    let unavailableRepository = FolderLocationListRepository(
      storage: storage,
      codec: UnavailableFolderBookmarkCodec(),
      mode: .favorites)

    let favorites = try unavailableRepository.load()

    try #require(favorites.count == 1)
    #expect(favorites[0].name == "Disconnected")
    #expect(!favorites[0].isAvailable)
  }

  @Test("多数のお気に入りでも保存と復元を短時間で完了する")
  func managesManyFavoritesQuickly() throws {
    let urls = (0..<250).map { URL(fileURLWithPath: "/Users/test/folder-\($0)") }
    let bookmarkPairs = urls.map { ($0, Data($0.path.utf8)) }
    let callCounter = CodecCallCounter()
    let codec = TestFolderBookmarkCodec(
      bookmarkDataByURL: Dictionary(uniqueKeysWithValues: bookmarkPairs),
      resolvedBookmarkByData: Dictionary(
        uniqueKeysWithValues: bookmarkPairs.map {
          ($0.1, ResolvedFolderBookmark(url: $0.0, isStale: false))
        }),
      callCounter: callCounter)
    let repository = FolderLocationListRepository(
      storage: InMemoryFolderLocationListStorage(),
      codec: codec,
      mode: .favorites)
    let clock = ContinuousClock()

    let duration = try clock.measure {
      for url in urls {
        _ = try repository.add(url)
      }
      #expect(try repository.load().count == urls.count)
    }

    // 差分適用後のcodec呼び出しは、各addで新規レコードを生成・解決する500回と、
    // 最後の明示的なload()で全250件を再解決する250回の計750回。
    // 実測値の1.5倍に当たる1,125回を上限とし、全件再loadの再発を検出する。
    #expect(callCounter.totalCallCount <= 1_125)

    // 無限ループ・デッドロックなど明らかな異常だけを拾う緩い実時間の安全弁。
    #expect(duration < .seconds(60))
  }

  private func secondURLLocationID(in locations: [SavedFolderLocation]) throws -> UUID {
    try #require(locations.first { $0.name == "Downloads" }?.id)
  }

  /// FolderLocationListRepository.Recordはprivateで直接構築できないため、
  /// smbLocationフィールドを持たない旧スキーマ相当のJSONを直接組み立てる。
  private func legacyRecordListData(name: String, bookmarkData: Data) throws -> Data {
    struct LegacyRecord: Codable {
      let id: UUID
      let name: String
      var bookmarkData: Data
      var lastKnownPath: String?
    }
    let record = LegacyRecord(
      id: UUID(), name: name, bookmarkData: bookmarkData, lastKnownPath: nil)
    return try JSONEncoder().encode([record])
  }

  @Test("標準ローカルフォルダはアプリのローカライズ表示名を使う")
  func displayNameUsesLocalizedNameForLocalURL() {
    let home = UserHomeDirectory.current
    let location = SavedFolderLocation(
      id: UUID(), name: "Desktop",
      url: home.appending(path: "Desktop"), lastKnownPath: nil, smbLocation: nil)
    #expect(
      location.displayName
        == String(localized: "デスクトップ"))
  }

  @Test("URLが無い(未解決SMB等)場合は保存名をそのまま使う")
  func displayNameFallsBackToStoredName() {
    let location = SavedFolderLocation(
      id: UUID(), name: "share", url: nil, lastKnownPath: "/Volumes/share", smbLocation: nil)
    #expect(location.displayName == "share")
  }

  @Test("既知の標準フォルダは場所別のSF Symbolを返す")
  func sidebarSystemImageReturnsKnownFolderIcon() {
    let fileManager = FileManager.default
    let home = UserHomeDirectory.current
    let desktop = fileManager.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    let downloads = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask)[0]

    let homeLocation = SavedFolderLocation(id: UUID(), name: "Home", url: home)
    let desktopLocation = SavedFolderLocation(id: UUID(), name: "Desktop", url: desktop)
    let downloadsLocation = SavedFolderLocation(id: UUID(), name: "Downloads", url: downloads)

    #expect(homeLocation.sidebarSystemImage == "house")
    #expect(desktopLocation.sidebarSystemImage == "desktopcomputer")
    #expect(downloadsLocation.sidebarSystemImage == "arrow.down.circle")
  }

  @Test("未知のローカルフォルダはsidebarSystemImageがnilになる")
  func sidebarSystemImageReturnsNilForUnknownFolder() {
    let location = SavedFolderLocation(
      id: UUID(), name: "project", url: URL(fileURLWithPath: "/Users/test/project"))
    #expect(location.sidebarSystemImage == nil)
  }

  @Test("URLが無い場合はsidebarSystemImageがnilになる(呼び出し側で従来アイコンへフォールバック)")
  func sidebarSystemImageReturnsNilWhenURLIsMissing() {
    let location = SavedFolderLocation(
      id: UUID(), name: "share", url: nil, lastKnownPath: "/Volumes/share", smbLocation: nil)
    #expect(location.sidebarSystemImage == nil)
  }
}

// SystemFolderBookmarkCodecのフォールバック分岐を、URL(resolvingBookmarkData:options:)の
// 実データ(SMBブックマークでのみ発生する259エラー)に依存せず検証するためのフェイク。
// URL.BookmarkResolutionOptionsはHashable非準拠のためrawValueをキーに保持する。
private final class FakeBookmarkDataResolver: BookmarkDataResolving, @unchecked Sendable {
  enum Response {
    case success(URL, Bool)
    case failure(Error)
  }

  private struct UnexpectedOptionsError: Error {}

  private let responsesByRawOptions: [UInt: Response]
  private var callCountsByRawOptions: [UInt: Int] = [:]

  init(responses: [(URL.BookmarkResolutionOptions, Response)]) {
    responsesByRawOptions = Dictionary(
      uniqueKeysWithValues: responses.map { ($0.0.rawValue, $0.1) })
  }

  func resolve(
    _ data: Data,
    options: URL.BookmarkResolutionOptions
  ) throws -> (url: URL, isStale: Bool) {
    callCountsByRawOptions[options.rawValue, default: 0] += 1
    guard let response = responsesByRawOptions[options.rawValue] else {
      throw UnexpectedOptionsError()
    }
    switch response {
    case .success(let url, let isStale):
      return (url, isStale)
    case .failure(let error):
      throw error
    }
  }

  func callCount(for options: URL.BookmarkResolutionOptions) -> Int {
    callCountsByRawOptions[options.rawValue] ?? 0
  }
}

private final class InMemoryFolderBookmarkStorage: FolderBookmarkStoring {
  var bookmarkData: Data?

  init(bookmarkData: Data? = nil) {
    self.bookmarkData = bookmarkData
  }

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

/// FolderLocationListRepositoryが1回の操作で発行するcodec呼び出し回数を数える。
/// 実時間計測に代えて、呼び出し回数の決定的な上限で二次的な計算量爆発を検出するために使う。
private final class CodecCallCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var createCallCount = 0
  private var resolveCallCount = 0

  var totalCallCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return createCallCount + resolveCallCount
  }

  func recordCreateCall() {
    lock.lock()
    defer { lock.unlock() }
    createCallCount += 1
  }

  func recordResolveCall() {
    lock.lock()
    defer { lock.unlock() }
    resolveCallCount += 1
  }
}

private struct TestFolderBookmarkCodec: FolderBookmarkCoding {
  let bookmarkDataByURL: [URL: Data]
  let resolvedBookmarkByData: [Data: ResolvedFolderBookmark]
  var callCounter: CodecCallCounter? = nil

  func createBookmark(for url: URL) throws -> Data {
    callCounter?.recordCreateCall()
    return try #require(bookmarkDataByURL[url])
  }

  func resolveBookmark(_ data: Data) throws -> ResolvedFolderBookmark {
    callCounter?.recordResolveCall()
    return try #require(resolvedBookmarkByData[data])
  }
}

private struct UnavailableFolderBookmarkCodec: FolderBookmarkCoding {
  private struct UnavailableError: Error {}

  func createBookmark(for url: URL) throws -> Data {
    throw UnavailableError()
  }

  func resolveBookmark(_ data: Data) throws -> ResolvedFolderBookmark {
    throw UnavailableError()
  }
}
