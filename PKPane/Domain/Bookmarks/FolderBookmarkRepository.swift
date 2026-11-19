import Darwin
import Foundation
import Security
import Synchronization

struct ResolvedFolderBookmark: Equatable {
  let url: URL
  let isStale: Bool
}

protocol FolderBookmarkCoding {
  func createBookmark(for url: URL) throws -> Data
  func resolveBookmark(_ data: Data) throws -> ResolvedFolderBookmark
}

protocol FolderBookmarkStoring: AnyObject {
  func loadBookmarkData() -> Data?
  func saveBookmarkData(_ data: Data)
  func removeBookmarkData()
}

final class FolderBookmarkRepository {
  private let storage: any FolderBookmarkStoring
  private let codec: any FolderBookmarkCoding

  init(storage: any FolderBookmarkStoring, codec: any FolderBookmarkCoding) {
    self.storage = storage
    self.codec = codec
  }

  func save(_ folderURL: URL) throws {
    let bookmarkData = try codec.createBookmark(for: folderURL)
    storage.saveBookmarkData(bookmarkData)
  }

  func restore() throws -> URL? {
    guard let bookmarkData = storage.loadBookmarkData() else {
      return nil
    }

    let resolvedBookmark = try codec.resolveBookmark(bookmarkData)
    if resolvedBookmark.isStale {
      try save(resolvedBookmark.url)
    }

    return resolvedBookmark.url
  }
}

/// URL(resolvingBookmarkData:options:)の実呼び出しを差し替え可能にする境界。
/// SMBブックマークのフォーマットエラー(259)はOS APIの実データでしか再現できないため、
/// SystemFolderBookmarkCodecのフォールバック分岐をフェイクで検証できるようにする。
protocol BookmarkDataResolving: Sendable {
  func resolve(
    _ data: Data,
    options: URL.BookmarkResolutionOptions
  ) throws -> (url: URL, isStale: Bool)
}

struct SystemBookmarkDataResolver: BookmarkDataResolving {
  func resolve(
    _ data: Data,
    options: URL.BookmarkResolutionOptions
  ) throws -> (url: URL, isStale: Bool) {
    var isStale = false
    let url = try URL(
      resolvingBookmarkData: data,
      options: options,
      relativeTo: nil,
      bookmarkDataIsStale: &isStale
    )
    return (url, isStale)
  }
}

struct SystemFolderBookmarkCodec: FolderBookmarkCoding {
  private let resolver: any BookmarkDataResolving

  init(resolver: any BookmarkDataResolving = SystemBookmarkDataResolver()) {
    self.resolver = resolver
  }

  func createBookmark(for url: URL) throws -> Data {
    try url.bookmarkData(
      options: .withSecurityScope,
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    )
  }

  func resolveBookmark(_ data: Data) throws -> ResolvedFolderBookmark {
    do {
      let (url, isStale) = try resolver.resolve(
        data, options: [.withSecurityScope, .withoutMounting])
      return ResolvedFolderBookmark(url: url, isStale: isStale)
    } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == 259 {
      // SMBネットワークボリューム上のフォルダはスコープ付き解決がマウント状態に関わらず
      // 常にフォーマットエラー(259)になるmacOSの制約がある。スコープなしで再解決し、
      // ネットワークボリューム配下だと確認できた場合のみ採用する。ローカルのブックマークが
      // スコープなしでしか解決できない場合は不正なアクセス許可の可能性があるため、
      // 従来どおり失敗扱いにする。
      let (url, isStale) = try resolver.resolve(data, options: [.withoutMounting])
      guard Self.isOnNetworkVolume(url) else { throw error }
      return ResolvedFolderBookmark(url: url, isStale: isStale)
    }
  }

  private static func isOnNetworkVolume(_ url: URL) -> Bool {
    let standardizedURL = url.standardizedFileURL
    if let isLocal = try? standardizedURL.resourceValues(forKeys: [.volumeIsLocalKey])
      .volumeIsLocal
    {
      return !isLocal
    }
    // 未マウント等でリソース値が取得できない場合は "/Volumes/<name>/..." という
    // パスパターンで判定する(ローカルの直下フォルダがこの配下に来ることはない)。
    let components = standardizedURL.pathComponents
    return components.count >= 3 && components[1] == "Volumes"
  }
}

final class UserDefaultsFolderBookmarkStore: FolderBookmarkStoring {
  private let defaults: UserDefaults
  private let key: String

  init(
    defaults: UserDefaults? = nil,
    key: String = "selected-folder-bookmark"
  ) {
    self.defaults = defaults ?? Self.defaultUserDefaults
    self.key = key
  }

  func loadBookmarkData() -> Data? {
    defaults.data(forKey: key)
  }

  func saveBookmarkData(_ data: Data) {
    defaults.set(data, forKey: key)
  }

  func removeBookmarkData() {
    defaults.removeObject(forKey: key)
  }

  private static var defaultUserDefaults: UserDefaults {
    PKPaneUserDefaults.resolve()
  }
}

struct SavedFolderLocation: Identifiable, Equatable {
  let id: UUID
  let name: String
  let url: URL?
  let lastKnownPath: String?
  let smbLocation: SMBFolderLocation?

  init(
    id: UUID,
    name: String,
    url: URL?,
    lastKnownPath: String? = nil,
    smbLocation: SMBFolderLocation? = nil
  ) {
    self.id = id
    self.name = name
    self.url = url
    self.lastKnownPath = lastKnownPath ?? url?.path
    self.smbLocation = smbLocation
  }

  var isAvailable: Bool {
    url != nil
  }

  var requiresAuthorization: Bool {
    url == nil && smbLocation == nil && lastKnownPath != nil
  }

  /// Finderのサイドバーと同様、ブックマーク解決済みのiCloud管理フォルダだけを示す。
  /// body評価ごとに同期I/Oを行わないようURL単位で保持する。iCloud管理状態は起動中に
  /// 変わらないため、キャッシュの明示的な無効化は不要。
  var isICloudManagedFolder: Bool {
    Self.isICloudManagedFolder(url: url)
  }

  static func isICloudManagedFolder(
    url: URL?,
    isUbiquitousItem: (URL) -> Bool = {
      (try? $0.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) ?? false
    }
  ) -> Bool {
    guard let url else { return false }
    let key = url.standardizedFileURL as NSURL
    if let cached = iCloudManagedFolderCache.object(forKey: key) {
      return cached.boolValue
    }
    let isManaged = isUbiquitousItem(url)
    iCloudManagedFolderCache.setObject(NSNumber(value: isManaged), forKey: key)
    return isManaged
  }

  /// NSCacheはスレッド安全で、URLごとの問い合わせ結果は起動中に変わらない。
  nonisolated(unsafe) private static let iCloudManagedFolderCache: NSCache<NSURL, NSNumber> = {
    let cache = NSCache<NSURL, NSNumber>()
    cache.countLimit = 256
    return cache
  }()

  /// 表示専用のローカライズ名。ローカルURLがあるものは FileManager が
  /// システム標準フォルダ(デスクトップ、書類など)をユーザー言語で返す。
  /// リモート・未解決の項目は保存名のまま。保存データは英語名を維持する
  /// (ロケール切替や既存データとの互換のため)。
  var displayName: String {
    let localURL = url ?? (smbLocation == nil ? lastKnownPath.map { URL(filePath: $0) } : nil)
    guard let url = localURL, url.isFileURL else { return name }
    if let standardName = UserHomeDirectory.localizedStandardFolderName(for: url) {
      return standardName
    }
    guard self.url != nil else { return name }
    return FileManager.default.displayName(atPath: url.path)
  }

  /// Finder同様、既知の標準フォルダは種別ごとのSF Symbolを返す。
  /// url が無い、またはFinder標準フォルダに一致しない場合は nil を返し、
  /// 呼び出し側で従来のアイコン(種別アイコン)へフォールバックする。
  var sidebarSystemImage: String? {
    let localURL = url ?? (requiresAuthorization ? lastKnownPath.map { URL(filePath: $0) } : nil)
    guard let url = localURL, url.isFileURL else { return nil }
    return UserHomeDirectory.standardFolderSystemImage(for: url)
  }
}

struct SMBFolderLocation: Codable, Equatable {
  let host: String
  let shareName: String
  let relativePathComponents: [String]

  init?(folderURL: URL) {
    guard let sharePath = SMBSharePath(folderURL: folderURL) else { return nil }
    host = sharePath.host
    shareName = sharePath.shareName
    relativePathComponents = sharePath.relativePathComponents
  }

  init(host: String, shareName: String, relativePathComponents: [String]) {
    self.host = host
    self.shareName = shareName
    self.relativePathComponents = relativePathComponents
  }
}

protocol FolderLocationListStoring: AnyObject, Sendable {
  func loadLocationListData() -> Data?
  func saveLocationListData(_ data: Data)
  func removeLocationListData()
}

enum FolderLocationListMode: Equatable {
  case favorites
  case recent(limit: Int)
}

final class FolderLocationListRepository: Sendable {
  private struct Record: Codable, Equatable {
    let id: UUID
    let name: String
    var bookmarkData: Data
    var lastKnownPath: String?
    var smbLocation: SMBFolderLocation?
  }

  private struct SMBLocationIdentity: Hashable {
    let host: String
    let shareName: String
    let relativePathComponents: [String]

    init(_ location: SMBFolderLocation) {
      host = location.host.lowercased()
      shareName = location.shareName.lowercased()
      relativePathComponents = location.relativePathComponents
    }
  }

  private struct ResolvedList {
    var records: [Record]
    var locations: [SavedFolderLocation]
  }

  private let storage: any FolderLocationListStoring
  private let codec: any FolderBookmarkCoding & Sendable
  private let mode: FolderLocationListMode
  private let smbLocationForURL: @Sendable (URL) -> SMBFolderLocation?
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()
  private let cachedList = Mutex<ResolvedList?>(nil)

  init(
    storage: any FolderLocationListStoring,
    codec: any FolderBookmarkCoding & Sendable,
    mode: FolderLocationListMode,
    smbLocationForURL: @escaping @Sendable (URL) -> SMBFolderLocation? = {
      SMBFolderLocation(folderURL: $0)
    }
  ) {
    self.storage = storage
    self.codec = codec
    self.mode = mode
    self.smbLocationForURL = smbLocationForURL
  }

  func load() throws -> [SavedFolderLocation] {
    try cachedList.withLock { cachedList in
      let resolvedList = try loadResolvedList()
      cachedList = resolvedList
      return resolvedList.locations
    }
  }

  private func loadResolvedList() throws -> ResolvedList {
    var records = try loadRecords()
    var didRefreshBookmark = false
    var locations = records.indices.map { index in
      let result = resolveLocation(for: &records[index])
      didRefreshBookmark = didRefreshBookmark || result.didRefreshBookmark
      return result.location
    }
    if case .recent(let limit) = mode {
      // 保存済みの重複も最新の記録を残して整理し、別サーバーや子フォルダは区別する。
      var seenSMBLocations: Set<SMBLocationIdentity> = []
      let keptIndices = locations.indices.filter { index in
        guard let smbLocation = locations[index].smbLocation else { return true }
        return seenSMBLocations.insert(SMBLocationIdentity(smbLocation)).inserted
      }.prefix(max(0, limit))
      if keptIndices.count != records.count {
        records = keptIndices.map { records[$0] }
        locations = keptIndices.map { locations[$0] }
        didRefreshBookmark = true
      }
    }
    if didRefreshBookmark {
      try saveRecords(records)
    }
    return ResolvedList(records: records, locations: locations)
  }

  @discardableResult
  func add(
    _ folderURL: URL, allowingMissingAuthorization: Bool = false
  ) throws -> [SavedFolderLocation] {
    try cachedList.withLock { cachedList in
      let standardizedURL = folderURL.standardizedFileURL
      var resolvedList = try cachedList ?? loadResolvedList()
      var matchingIndex = resolvedList.locations.firstIndex { location in
        location.url?.standardizedFileURL == standardizedURL
          || (location.smbLocation == nil
            && location.lastKnownPath.map {
              URL(filePath: $0).standardizedFileURL.path == standardizedURL.path
            } == true)
      }

      if case .favorites = mode, matchingIndex != nil {
        cachedList = resolvedList
        return resolvedList.locations
      }
      // マウント情報の取得は新規レコード生成と共有し、一覧ごとの再取得を避ける。
      let smbLocation = smbLocationForURL(standardizedURL)
      if matchingIndex == nil, let smbLocation {
        let identity = SMBLocationIdentity(smbLocation)
        matchingIndex = resolvedList.locations.firstIndex {
          $0.smbLocation.map { SMBLocationIdentity($0) == identity } == true
        }
      }

      switch mode {
      case .favorites:
        guard matchingIndex == nil else {
          cachedList = resolvedList
          return resolvedList.locations
        }
        var record = try makeRecord(
          for: standardizedURL, smbLocation: smbLocation,
          allowingMissingAuthorization: allowingMissingAuthorization)
        let resolvedRecord = resolveLocation(for: &record)
        resolvedList.records.append(record)
        resolvedList.locations.append(resolvedRecord.location)
      case .recent(let limit):
        if let matchingIndex {
          resolvedList.records.remove(at: matchingIndex)
          resolvedList.locations.remove(at: matchingIndex)
        }
        var record = try makeRecord(for: standardizedURL, smbLocation: smbLocation)
        let resolvedRecord = resolveLocation(for: &record)
        resolvedList.records.insert(record, at: 0)
        resolvedList.locations.insert(resolvedRecord.location, at: 0)
        let maximumCount = max(0, limit)
        if resolvedList.records.count > maximumCount {
          resolvedList.records.removeLast(resolvedList.records.count - maximumCount)
          resolvedList.locations.removeLast(resolvedList.locations.count - maximumCount)
        }
      }

      try saveRecords(resolvedList.records)
      cachedList = resolvedList
      return resolvedList.locations
    }
  }

  /// 再許可したフォルダのブックマークを、既存の保存先IDを保って更新する。
  @discardableResult
  func refreshFavoriteBookmark(for folderURL: URL) throws -> [SavedFolderLocation] {
    guard case .favorites = mode else { return try add(folderURL) }
    return try cachedList.withLock { cachedList in
      let standardizedURL = folderURL.standardizedFileURL
      var resolvedList = try cachedList ?? loadResolvedList()
      let bookmarkData = try codec.createBookmark(for: standardizedURL)
      if let index = resolvedList.locations.firstIndex(where: {
        $0.url?.standardizedFileURL.path == standardizedURL.path
          || $0.lastKnownPath.map {
            URL(filePath: $0).standardizedFileURL.path == standardizedURL.path
          } == true
      }) {
        resolvedList.records[index].bookmarkData = bookmarkData
        resolvedList.records[index].lastKnownPath = standardizedURL.path
        resolvedList.locations[index] = resolveLocation(for: &resolvedList.records[index]).location
      } else {
        var record = Record(
          id: UUID(),
          name: standardizedURL.lastPathComponent.isEmpty
            ? standardizedURL.path : standardizedURL.lastPathComponent,
          bookmarkData: bookmarkData,
          lastKnownPath: standardizedURL.path,
          smbLocation: SMBFolderLocation(folderURL: standardizedURL))
        let location = resolveLocation(for: &record).location
        resolvedList.records.append(record)
        resolvedList.locations.append(location)
      }
      try saveRecords(resolvedList.records)
      cachedList = resolvedList
      return resolvedList.locations
    }
  }

  @discardableResult
  func remove(id: UUID) throws -> [SavedFolderLocation] {
    try cachedList.withLock { cachedList in
      var resolvedList = try cachedList ?? loadResolvedList()
      resolvedList.records.removeAll { $0.id == id }
      resolvedList.locations.removeAll { $0.id == id }
      try saveRecords(resolvedList.records)
      cachedList = resolvedList
      return resolvedList.locations
    }
  }

  @discardableResult
  func move(id: UUID, by offset: Int) throws -> [SavedFolderLocation] {
    try cachedList.withLock { cachedList in
      var resolvedList = try cachedList ?? loadResolvedList()
      guard case .favorites = mode, offset != 0,
        let sourceIndex = resolvedList.records.firstIndex(where: { $0.id == id })
      else {
        cachedList = resolvedList
        return resolvedList.locations
      }
      let destinationIndex = min(max(0, sourceIndex + offset), resolvedList.records.count - 1)
      guard sourceIndex != destinationIndex else {
        cachedList = resolvedList
        return resolvedList.locations
      }
      let record = resolvedList.records.remove(at: sourceIndex)
      resolvedList.records.insert(record, at: destinationIndex)
      let location = resolvedList.locations.remove(at: sourceIndex)
      resolvedList.locations.insert(location, at: destinationIndex)
      try saveRecords(resolvedList.records)
      cachedList = resolvedList
      return resolvedList.locations
    }
  }

  func portableFavorites() throws -> [PortableFavorite] {
    try cachedList.withLock { cachedList in
      guard case .favorites = mode else { return [] }
      let resolvedList = try cachedList ?? loadResolvedList()
      cachedList = resolvedList
      return resolvedList.records.compactMap(portableFavorite(for:))
    }
  }

  @discardableResult
  func applySyncedFavorites(_ document: FavoriteSyncDocument) throws -> [SavedFolderLocation] {
    try cachedList.withLock { cachedList in
      guard case .favorites = mode else {
        let resolvedList = try cachedList ?? loadResolvedList()
        cachedList = resolvedList
        return resolvedList.locations
      }
      let current = try cachedList ?? loadResolvedList()
      let desiredFavorites = document.items.map(\.favorite).filter {
        $0.provider == .local || $0.provider == .smb
      }
      let tombstoneKeys = Set(
        document.tombstones.map(\.key).filter {
          $0.provider == .local || $0.provider == .smb
        })
      var usedRecordIDs: Set<UUID> = []
      var nextRecords: [Record] = []

      for favorite in desiredFavorites {
        if let existing = current.records.first(where: {
          !usedRecordIDs.contains($0.id) && portableFavorite(for: $0)?.key == favorite.key
        }) {
          usedRecordIDs.insert(existing.id)
          nextRecords.append(record(existing, updatingNameTo: favorite.displayName))
        } else if let record = makeSyncedRecord(for: favorite) {
          nextRecords.append(record)
        }
      }

      for record in current.records where !usedRecordIDs.contains(record.id) {
        if let key = portableFavorite(for: record)?.key, tombstoneKeys.contains(key) {
          continue
        }
        nextRecords.append(record)
      }

      var resolvedRecords = nextRecords
      let locations = resolvedRecords.indices.map { index in
        resolveLocation(for: &resolvedRecords[index]).location
      }
      if resolvedRecords != current.records {
        try saveRecords(resolvedRecords)
      }
      let next = ResolvedList(records: resolvedRecords, locations: locations)
      cachedList = next
      return next.locations
    }
  }

  @discardableResult
  func activateSyncedLocalFavorite(id: UUID) throws -> [SavedFolderLocation] {
    try cachedList.withLock { cachedList in
      var resolvedList = try cachedList ?? loadResolvedList()
      guard let index = resolvedList.records.firstIndex(where: { $0.id == id }),
        resolvedList.records[index].smbLocation == nil,
        resolvedList.locations[index].url == nil,
        let path = resolvedList.records[index].lastKnownPath
      else {
        cachedList = resolvedList
        return resolvedList.locations
      }
      let url = URL(filePath: path).standardizedFileURL
      guard Self.isReadableDirectory(url) else {
        cachedList = resolvedList
        return resolvedList.locations
      }
      resolvedList.records[index].bookmarkData = try codec.createBookmark(for: url)
      resolvedList.locations[index] = resolveLocation(for: &resolvedList.records[index]).location
      try saveRecords(resolvedList.records)
      cachedList = resolvedList
      return resolvedList.locations
    }
  }

  private func resolveLocation(
    for record: inout Record
  ) -> (location: SavedFolderLocation, didRefreshBookmark: Bool) {
    if record.smbLocation != nil {
      return (
        SavedFolderLocation(
          id: record.id,
          name: record.name,
          url: nil,
          lastKnownPath: record.lastKnownPath,
          smbLocation: record.smbLocation),
        false
      )
    }

    do {
      let resolvedBookmark = try codec.resolveBookmark(record.bookmarkData)
      var didRefreshBookmark = false
      if resolvedBookmark.isStale {
        record.bookmarkData = try codec.createBookmark(for: resolvedBookmark.url)
        didRefreshBookmark = true
      }
      if record.lastKnownPath == nil {
        record.lastKnownPath = resolvedBookmark.url.path
        didRefreshBookmark = true
      }
      if record.smbLocation == nil,
        let smbLocation = SMBFolderLocation(folderURL: resolvedBookmark.url)
      {
        record.smbLocation = smbLocation
        didRefreshBookmark = true
      }
      return (
        SavedFolderLocation(
          id: record.id,
          name: record.name,
          url: resolvedBookmark.url.standardizedFileURL,
          lastKnownPath: record.lastKnownPath,
          smbLocation: record.smbLocation),
        didRefreshBookmark
      )
    } catch {
      return (
        SavedFolderLocation(
          id: record.id,
          name: record.name,
          url: nil,
          lastKnownPath: record.lastKnownPath,
          smbLocation: record.smbLocation),
        false
      )
    }
  }

  private func makeRecord(
    for folderURL: URL, smbLocation: SMBFolderLocation?,
    allowingMissingAuthorization: Bool = false
  ) throws -> Record {
    // 標準お気に入りの初期登録では未許可パスのブックマーク生成を試さない。
    // Sandboxの承認処理が起動を止めるため、選択時にだけ許可・生成する。
    let bookmarkData =
      allowingMissingAuthorization ? Data() : try codec.createBookmark(for: folderURL)
    return Record(
      id: UUID(),
      name: folderURL.lastPathComponent.isEmpty ? folderURL.path : folderURL.lastPathComponent,
      bookmarkData: bookmarkData,
      lastKnownPath: folderURL.path,
      smbLocation: smbLocation)
  }

  private func portableFavorite(for record: Record) -> PortableFavorite? {
    if let smbLocation = record.smbLocation,
      let connectionIdentifier = PortableFavoriteConnectionIdentifier.smb(
        host: smbLocation.host, shareName: smbLocation.shareName)
    {
      let remotePath = "/" + smbLocation.relativePathComponents.joined(separator: "/")
      return PortableFavorite(
        provider: .smb,
        connectionIdentifier: connectionIdentifier,
        path: remotePath,
        displayName: record.name)
    }
    guard let path = record.lastKnownPath else { return nil }
    return PortableFavorite(
      provider: .local,
      path: URL(filePath: path).standardizedFileURL.path,
      displayName: record.name)
  }

  private func makeSyncedRecord(for favorite: PortableFavorite) -> Record? {
    switch favorite.provider {
    case .local:
      let url = URL(filePath: favorite.path).standardizedFileURL
      let bookmarkData =
        Self.isReadableDirectory(url) ? (try? codec.createBookmark(for: url)) ?? Data() : Data()
      return Record(
        id: UUID(),
        name: favorite.displayName,
        bookmarkData: bookmarkData,
        lastKnownPath: url.path,
        smbLocation: nil)
    case .smb:
      guard let connectionIdentifier = favorite.connectionIdentifier,
        let smbLocation = PortableFavoriteConnectionIdentifier.smbLocation(
          identifier: connectionIdentifier, remotePath: favorite.path)
      else {
        return nil
      }
      return Record(
        id: UUID(),
        name: favorite.displayName,
        bookmarkData: Data(),
        lastKnownPath: favorite.path,
        smbLocation: smbLocation)
    case .sftp:
      return nil
    }
  }

  private func record(_ record: Record, updatingNameTo name: String) -> Record {
    guard record.name != name else { return record }
    return Record(
      id: record.id,
      name: name,
      bookmarkData: record.bookmarkData,
      lastKnownPath: record.lastKnownPath,
      smbLocation: record.smbLocation)
  }

  private static func isReadableDirectory(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
      && isDirectory.boolValue
      && FileManager.default.isReadableFile(atPath: url.path)
  }

  private func loadRecords() throws -> [Record] {
    guard let data = storage.loadLocationListData() else {
      return []
    }
    return try decoder.decode([Record].self, from: data)
  }

  private func saveRecords(_ records: [Record]) throws {
    if records.isEmpty {
      storage.removeLocationListData()
    } else {
      storage.saveLocationListData(try encoder.encode(records))
    }
  }
}

// UserDefaultsはスレッド安全であり、格納プロパティは不変のため。
final class UserDefaultsFolderLocationListStore: FolderLocationListStoring, @unchecked Sendable {
  private let defaults: UserDefaults
  private let key: String

  init(defaults: UserDefaults? = nil, key: String) {
    self.defaults = defaults ?? Self.defaultUserDefaults
    self.key = key
  }

  func loadLocationListData() -> Data? {
    defaults.data(forKey: key)
  }

  func saveLocationListData(_ data: Data) {
    defaults.set(data, forKey: key)
  }

  func removeLocationListData() {
    defaults.removeObject(forKey: key)
  }

  private static var defaultUserDefaults: UserDefaults {
    PKPaneUserDefaults.resolve()
  }
}

enum FolderBookmarkAccessError: LocalizedError {
  case accessDenied

  var errorDescription: String? {
    switch self {
    case .accessDenied:
      "選択したフォルダへのアクセスを開始できませんでした。"
    }
  }
}

@MainActor
final class FolderBookmarkAccessManager {
  private var accessCounts: [URL: Int] = [:]
  private var securityScopedURLs: Set<URL> = []
  private let startAccess: (URL) -> Bool
  private let stopAccess: (URL) -> Void
  private let sandboxed: () -> Bool
  private let canReadDirectory: (URL) -> Bool

  init(
    startAccess: @escaping (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
    stopAccess: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() },
    isSandboxed: @escaping () -> Bool = { FolderBookmarkAccessManager.isSandboxed },
    canReadDirectory: @escaping (URL) -> Bool = { url in
      // 親の許可や標準権限で既に開ける場合、追加のsecurity scopeは不要。
      let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
      guard descriptor >= 0 else { return false }
      close(descriptor)
      return true
    }
  ) {
    self.startAccess = startAccess
    self.stopAccess = stopAccess
    self.sandboxed = isSandboxed
    self.canReadDirectory = canReadDirectory
  }

  func replaceAccess(from currentURL: URL?, to nextURL: URL) throws {
    guard currentURL != nextURL else {
      return
    }

    try beginAccess(to: nextURL)
    if let currentURL {
      endAccess(to: currentURL)
    }
  }

  /// 未解決の保存パスを、保持中の親の許可だけで開けるかを確かめる。
  func isReadableDirectory(at url: URL) -> Bool {
    canReadDirectory(url)
  }

  func endAccess(to url: URL) {
    guard let accessCount = accessCounts[url] else {
      return
    }

    if accessCount == 1 {
      if securityScopedURLs.remove(url) != nil {
        stopAccess(url)
      }
      accessCounts[url] = nil
    } else {
      accessCounts[url] = accessCount - 1
    }
  }

  func beginAccess(to url: URL, requiresSecurityScope: Bool = false) throws {
    let needsScope = requiresSecurityScope && sandboxed()
    if let accessCount = accessCounts[url] {
      // 可読性だけで保持した参照を、後から得た本物のスコープ付きURLで昇格する。
      if needsScope, !securityScopedURLs.contains(url) {
        guard startAccess(url) else { throw FolderBookmarkAccessError.accessDenied }
        securityScopedURLs.insert(url)
      }
      accessCounts[url] = accessCount + 1
      return
    }

    if ProcessInfo.processInfo.environment["PKPANE_UI_TESTING"] == "1" {
      accessCounts[url] = 1
      return
    }

    if startAccess(url) {
      securityScopedURLs.insert(url)
      accessCounts[url] = 1
      return
    }

    guard !needsScope else { throw FolderBookmarkAccessError.accessDenied }

    guard sandboxed(), !canReadDirectory(url) else {
      accessCounts[url] = 1
      return
    }

    throw FolderBookmarkAccessError.accessDenied
  }

  private static var isSandboxed: Bool {
    guard let task = SecTaskCreateFromSelf(nil) else {
      return true
    }
    return SecTaskCopyValueForEntitlement(
      task,
      "com.apple.security.app-sandbox" as CFString,
      nil
    ) != nil
  }
}
