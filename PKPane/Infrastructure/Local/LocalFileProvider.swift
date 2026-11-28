import CryptoKit
import Darwin
import Foundation

struct LocalFileProvider {
  let id: FileProviderID = .local
  let connectionID: FileProviderConnectionID? = nil
  let capabilities: FileProviderCapabilities = [
    .read, .write, .rename, .moveWithinProvider, .copyWithinProvider, .trash,
    .replaceAtomically, .observeChanges, .readSymbolicLink, .finderTags,
    .cloudDownloadStatus,
  ]
  /// Task 1(getattrlistbulk): 列挙対象ボリュームがローカル(APFS/HFS+等)かどうかを判定する。
  /// SMB等のネットワークボリュームはgetattrlistbulkのFB15497909回避のためreaddir経路を使う。
  /// テストで差し替え可能にするため注入可能にしている。
  let isLocalVolume: @Sendable (URL) -> Bool
  /// moveの同一ボリューム判定(nilなら実ボリューム判定を使う)。異ボリューム時のコピー+削除
  /// 経路(copyの破損を元削除前に検出する経路)をテストで確実に踏ませるための注入点。
  let isOnSameVolumeOverride: @Sendable (URL, URL) -> Bool?
  /// 異ボリュームmoveのコピー段階の実装(既定はCancellableFileCopier)。破損注入テストで
  /// 意図的に切り詰めたコピーを行わせ、検証→元削除前の停止を確認するための注入点。
  let crossVolumeMoveCopy: @Sendable (URL, URL, @escaping @Sendable () -> Bool) throws -> Void
  /// 通常copyの実装。実Provider経由のキャンセル回帰テストで高速パスだけを無効化し、
  /// 本番と同じステージング・専用キュー・キャンセル伝播を通すための注入点。
  let cancellableCopy:
    @Sendable (
      URL, URL, @escaping @Sendable () -> Bool, (@Sendable (Int64) -> Void)?
    ) throws -> Void
  /// iCloud の属性取得は応答しないことがあるため、専用キューと期限付きの読み出し口を使う。
  let cloudStatusReader: CloudStatusResourceReader
  private let trashItem: @Sendable (URL) throws -> Void
  private let isSandboxed: @Sendable () -> Bool
  private let writeAccessGrants: any FolderWriteAccessGrantStoring

  init(
    isLocalVolume: @escaping @Sendable (URL) -> Bool = LocalFileProvider.systemIsLocalVolume,
    isOnSameVolumeOverride: @escaping @Sendable (URL, URL) -> Bool? = { _, _ in nil },
    crossVolumeMoveCopy:
      @escaping @Sendable (
        URL, URL, @escaping @Sendable () -> Bool
      ) throws -> Void = LocalFileProvider.defaultCrossVolumeMoveCopy,
    cancellableCopy:
      @escaping @Sendable (
        URL, URL, @escaping @Sendable () -> Bool, (@Sendable (Int64) -> Void)?
      ) throws -> Void = LocalFileProvider.defaultCancellableCopy,
    cloudStatusReader: CloudStatusResourceReader = .shared,
    moveToTrash: @escaping @Sendable (URL) throws -> Void = {
      try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
    },
    isSandboxed: @escaping @Sendable () -> Bool = { FolderBookmarkAccessManager.isSandboxed },
    writeAccessGrants: any FolderWriteAccessGrantStoring = FolderWriteAccessGrantStore.shared
  ) {
    self.isLocalVolume = isLocalVolume
    self.isOnSameVolumeOverride = isOnSameVolumeOverride
    self.crossVolumeMoveCopy = crossVolumeMoveCopy
    self.cancellableCopy = cancellableCopy
    self.cloudStatusReader = cloudStatusReader
    trashItem = moveToTrash
    self.isSandboxed = isSandboxed
    self.writeAccessGrants = writeAccessGrants
  }

  private static func defaultCrossVolumeMoveCopy(
    from sourceURL: URL,
    to destinationURL: URL,
    isCancelled: @escaping @Sendable () -> Bool
  ) throws {
    try CancellableFileCopier.copy(
      from: sourceURL, to: destinationURL, isCancelled: isCancelled)
  }

  private static func defaultCancellableCopy(
    from sourceURL: URL,
    to destinationURL: URL,
    isCancelled: @escaping @Sendable () -> Bool,
    progress: (@Sendable (Int64) -> Void)?
  ) throws {
    try CancellableFileCopier.copy(
      from: sourceURL,
      to: destinationURL,
      isCancelled: isCancelled,
      progress: progress)
  }

  private static func systemIsLocalVolume(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) ?? false
  }

  /// displayName(atPath:)はファイルシステムへ触れる同期APIで、パンくずはbody評価の
  /// たびに再計算されるため、URL→表示名をキャッシュして繰り返しI/Oを避ける
  /// (SMBマウント上ではmain threadを掴むリスクがある)。NSCacheはスレッド安全なため
  /// nonisolated(unsafe)で問題ない。標準フォルダのローカライズ名は起動中に変わらないため
  /// 無効化は不要。
  nonisolated(unsafe) private static let displayNameCache: NSCache<NSURL, NSString> = {
    let cache = NSCache<NSURL, NSString>()
    cache.countLimit = 256
    return cache
  }()

  static func cachedDisplayName(for url: URL) -> String {
    if let cached = displayNameCache.object(forKey: url as NSURL) {
      return cached as String
    }
    let name = FileManager.default.displayName(atPath: url.path)
    displayNameCache.setObject(name as NSString, forKey: url as NSURL)
    return name
  }

  func item(
    at url: URL,
    providerID: FileProviderID? = nil,
    includingListMetadata: Bool = true,
    includingDetailMetadata: Bool = true
  ) throws -> FileItem {
    var keys: Set<URLResourceKey> = [.isDirectoryKey]
    if includingListMetadata {
      keys.formUnion([
        .isSymbolicLinkKey, .isAliasFileKey, .fileSizeKey, .contentModificationDateKey,
      ])
    }
    if includingDetailMetadata {
      keys.formUnion([.creationDateKey, .tagNamesKey])
    }
    let values = try url.resourceValues(forKeys: keys)
    let posixPermissions: Int?
    let ownerName: String?
    let groupName: String?
    if includingDetailMetadata {
      let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
      posixPermissions = (attributes?[.posixPermissions] as? NSNumber)?.intValue
      ownerName = attributes?[.ownerAccountName] as? String
      groupName = attributes?[.groupOwnerAccountName] as? String
    } else {
      posixPermissions = nil
      ownerName = nil
      groupName = nil
    }
    let isSymbolicLink = includingListMetadata && (values.isSymbolicLink ?? false)
    return FileItem(
      url: url, providerID: providerID ?? id, isDirectory: values.isDirectory ?? false,
      isSymbolicLink: isSymbolicLink,
      isAliasFile: includingListMetadata && !isSymbolicLink && (values.isAliasFile ?? false),
      size: includingListMetadata ? values.fileSize.map(Int64.init) : nil,
      createdAt: includingDetailMetadata ? values.creationDate : nil,
      modifiedAt: includingListMetadata ? values.contentModificationDate : nil,
      tags: includingDetailMetadata ? values.tagNames : nil,
      posixPermissions: posixPermissions,
      ownerName: ownerName,
      groupName: groupName)
  }

  func contents(
    of directoryURL: URL,
    includingHidden: Bool = false,
    providerID: FileProviderID? = nil
  ) throws -> [FileItem] {
    let options: FileManager.DirectoryEnumerationOptions =
      includingHidden ? [] : [.skipsHiddenFiles]
    let urls = try FileManager.default.contentsOfDirectory(
      at: directoryURL,
      includingPropertiesForKeys: [
        .isDirectoryKey, .isSymbolicLinkKey, .isAliasFileKey, .fileSizeKey,
        .contentModificationDateKey,
      ],
      options: options
    )
    return try urls.map { url in
      try item(at: url, providerID: providerID, includingDetailMetadata: false)
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  func createDirectory(named name: String, in directoryURL: URL) throws -> URL {
    let url = availableDirectoryURL(named: name, in: directoryURL)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
  }

  func rename(_ url: URL, to name: String, replacingExisting: Bool = false) throws -> URL {
    let destination = url.deletingLastPathComponent().appending(path: name)
    guard destination.standardizedFileURL != url.standardizedFileURL else { return url }
    try validateDestination(destination, replacingExisting: replacingExisting)
    try commitItem(from: url, to: destination, replacingExisting: replacingExisting)
    return destination
  }

  func moveToTrash(_ url: URL) throws {
    try trashItem(url)
  }

  func copy(
    _ url: URL,
    to directoryURL: URL,
    replacingExisting: Bool = false,
    progress: (@Sendable (Int64) -> Void)? = nil,
    isCancelled: @escaping @Sendable () -> Bool = { false }
  ) throws -> URL {
    let destinationURL = directoryURL.appending(path: url.lastPathComponent)
    if try LocalTransferLocationValidator.validate(source: url, destination: destinationURL)
      == .sameItem, replacingExisting
    {
      return destinationURL
    }
    try validateDestination(destinationURL, replacingExisting: replacingExisting)
    let temporaryURL = directoryURL.appending(
      path: ".\(destinationURL.lastPathComponent).pkpane-copy-\(UUID().uuidString)")
    do {
      try cancellableCopy(url, temporaryURL, isCancelled, progress)
      try commitItem(
        from: temporaryURL, to: destinationURL, replacingExisting: replacingExisting)
    } catch {
      try? FileManager.default.removeItem(at: temporaryURL)
      throw error
    }
    return destinationURL
  }

  func duplicate(_ url: URL) throws -> URL {
    let destination = availableDuplicateURL(for: url)
    try FileManager.default.copyItem(at: url, to: destination)
    return destination
  }

  func move(
    _ url: URL,
    to directoryURL: URL,
    replacingExisting: Bool = false,
    isCancelled: @escaping @Sendable () -> Bool = { false }
  ) throws -> URL {
    let destinationURL = directoryURL.appending(path: url.lastPathComponent)
    if try LocalTransferLocationValidator.validate(source: url, destination: destinationURL)
      == .sameItem, replacingExisting
    {
      return destinationURL
    }
    try validateDestination(destinationURL, replacingExisting: replacingExisting)
    guard isOnSameVolume(url, directoryURL) else {
      // 異なるボリュームへの移動はrenameできないため、中断可能コピー+削除で代替する。
      // copy()と同じ一時名ステージングを使い、中断・クラッシュ時に可視名(destinationURL)
      // の部分ファイルが残らないようにする。
      let temporaryURL = directoryURL.appending(
        path: ".\(destinationURL.lastPathComponent).pkpane-move-\(UUID().uuidString)")
      do {
        try crossVolumeMoveCopy(url, temporaryURL, isCancelled)
        // データを複製してから元を消す経路のため、元の削除前に複製結果を検証する。
        // ディレクトリはCancellableFileCopierが内部で再帰処理し、単純なサイズ比較が
        // 成立しないため対象外。シンボリックリンクもリンク自体が複製対象で、statの
        // sizeがリンク先を指すとは限らず意味のある比較にならないため対象外
        // (既存のTransferSizeVerifierと同じスコープ判断)。
        let sourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let sourceIsDirectory = sourceValues?.isDirectory == true
        let sourceIsSymbolicLink = sourceValues?.isSymbolicLink == true
        if !sourceIsDirectory, !sourceIsSymbolicLink {
          try verifyCopiedFileSize(source: url, copiedTo: temporaryURL)
        }
        try commitItem(
          from: temporaryURL, to: destinationURL, replacingExisting: replacingExisting)
      } catch {
        try? FileManager.default.removeItem(at: temporaryURL)
        throw error
      }
      try FileManager.default.removeItem(at: url)
      return destinationURL
    }
    try commitItem(from: url, to: destinationURL, replacingExisting: replacingExisting)
    return destinationURL
  }

  private func isOnSameVolume(_ url: URL, _ directoryURL: URL) -> Bool {
    if let overridden = isOnSameVolumeOverride(url, directoryURL) { return overridden }
    return (try? SystemFileOperationFileSystem().areOnSameVolume(url, directoryURL)) == true
  }

  /// 異ボリューム移動のコピー段階(元削除前)で使う、同期版のサイズ検証。
  /// 呼び出し元が既に非同期でないため、既存のTransferSizeVerifier(async)ではなく
  /// FileManagerで直接stat比較するが、投げるエラー型は同じTransferVerificationErrorに揃える。
  private func verifyCopiedFileSize(source: URL, copiedTo: URL) throws {
    guard let expectedBytes = Self.fileSize(at: source) else { return }
    guard let actualBytes = Self.fileSize(at: copiedTo) else { return }
    guard actualBytes == expectedBytes else {
      throw TransferVerificationError.sizeMismatch(
        itemName: source.lastPathComponent, expectedBytes: expectedBytes, actualBytes: actualBytes)
    }
  }

  private static func fileSize(at url: URL) -> Int64? {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value
  }

  func originalURL(for url: URL) throws -> URL? {
    let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isAliasFileKey])
    if values.isSymbolicLink != true, values.isAliasFile == true {
      return try URL(
        resolvingAliasFileAt: url,
        options: [.withoutUI, .withoutMounting]
      ).standardizedFileURL
    }
    guard values.isSymbolicLink == true else { return nil }
    let destination = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    let destinationURL =
      destination.hasPrefix("/")
      ? URL(fileURLWithPath: destination)
      : url.deletingLastPathComponent().appending(path: destination)
    return destinationURL.standardizedFileURL
  }

  private func availableDuplicateURL(for url: URL) -> URL {
    let directoryURL = url.deletingLastPathComponent()
    let fileExtension = url.pathExtension
    let baseName = url.deletingPathExtension().lastPathComponent
    var number = 1

    while true {
      let suffix = number == 1 ? "のコピー" : "のコピー\(number)"
      let name: String
      if fileExtension.isEmpty {
        name = baseName + suffix
      } else {
        name = baseName + suffix + "." + fileExtension
      }
      let candidate = directoryURL.appending(path: name)
      if !FileManager.default.fileExists(atPath: candidate.path) {
        return candidate
      }
      number += 1
    }
  }

  private func availableDirectoryURL(named name: String, in directoryURL: URL) -> URL {
    var number = 1
    while true {
      let candidateName = number == 1 ? name : "\(name) \(number)"
      let candidate = directoryURL.appending(path: candidateName, directoryHint: .isDirectory)
      if !FileManager.default.fileExists(atPath: candidate.path) {
        return candidate
      }
      number += 1
    }
  }

  /// コピー開始前は衝突だけを検証し、置換対象を削除しない。
  private func validateDestination(_ url: URL, replacingExisting: Bool) throws {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    guard replacingExisting else {
      throw CocoaError(.fileWriteFileExists)
    }
  }

  /// 同じボリューム上の完成済み項目を最終名へ確定する。コピー中に新しく宛先が
  /// 作られた競合もここで再判定し、置換未許可なら既存項目を保持して失敗する。
  private func commitItem(
    from source: URL,
    to destination: URL,
    replacingExisting: Bool
  ) throws {
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: destination.path) {
      guard replacingExisting else {
        throw CocoaError(.fileWriteFileExists)
      }
      _ = try fileManager.replaceItemAt(destination, withItemAt: source)
      return
    }

    do {
      try fileManager.moveItem(at: source, to: destination)
    } catch {
      // 存在確認直後に別プロセスが宛先を作った競合だけ、置換許可に従って再試行する。
      guard replacingExisting, fileManager.fileExists(atPath: destination.path) else {
        throw error
      }
      _ = try fileManager.replaceItemAt(destination, withItemAt: source)
    }
  }
}

extension LocalFileProvider: FileBrowserTrashProvider {
  func contents(of location: FileLocation) async throws -> [FileItem] {
    guard location.providerID == id, let url = location.localURL else {
      throw LocalFileProviderError.invalidLocation
    }
    return try contents(of: url)
  }

  func parent(of location: FileLocation) -> FileLocation? {
    guard location.providerID == id,
      let url = location.localURL,
      url.path != "/"
    else {
      return nil
    }
    return FileLocation(localURL: url.deletingLastPathComponent(), providerID: id)
  }

  func breadcrumbs(
    for location: FileLocation,
    constrainedTo root: FileLocation?
  ) -> [FileBrowserBreadcrumb] {
    guard location.providerID == id,
      let currentURL = location.localURL
    else {
      return []
    }
    let rootURL = root?.localURL ?? URL(fileURLWithPath: "/", isDirectory: true)
    return FolderBreadcrumb.make(root: rootURL, current: currentURL).map {
      FileBrowserBreadcrumb(
        location: FileLocation(localURL: $0.url, providerID: id),
        // ローカルはシステム標準フォルダ(デスクトップ、書類など)をユーザー言語で表示する
        name: Self.cachedDisplayName(for: $0.url))
    }
  }

  func createDirectory(named name: String, in location: FileLocation) async throws {
    guard location.providerID == id, let url = location.localURL else {
      throw LocalFileProviderError.invalidLocation
    }
    _ = try createDirectory(named: name, in: url)
  }

  func rename(_ item: FileItem, to name: String) async throws {
    guard item.location.providerID == id else {
      throw LocalFileProviderError.invalidLocation
    }
    _ = try rename(item.url, to: name)
  }

  func delete(_ item: FileItem) async throws {
    guard item.location.providerID == id else {
      throw LocalFileProviderError.invalidLocation
    }
    do {
      try moveToTrash(item.url)
    } catch  where Self.isTrashPermissionError(error) {
      let permissionError = FileBrowserOperationError.insufficientPermission(itemName: item.name)
      let directory = item.url.deletingLastPathComponent()
      guard isSandboxed(),
        !FolderWriteAccessGrantStore.covers(
          directory, from: URL(filePath: "/System", directoryHint: .isDirectory))
      else { throw permissionError }

      switch writeAccessGrants.activateGrant(covering: directory) {
      case .none:
        throw FileBrowserOperationError.writeAccessRequired(directory: directory)
      case .alreadyActive:
        throw permissionError
      case .activated:
        do {
          try moveToTrash(item.url)
        } catch  where Self.isTrashPermissionError(error) {
          throw permissionError
        }
      }
    }
  }

  private static func isTrashPermissionError(_ error: Error) -> Bool {
    let error = error as NSError
    if error.domain == NSCocoaErrorDomain, error.code == CocoaError.fileWriteNoPermission.rawValue {
      return true
    }
    let posixError =
      error.domain == NSPOSIXErrorDomain
      ? error : error.userInfo[NSUnderlyingErrorKey] as? NSError
    guard let posixError, posixError.domain == NSPOSIXErrorDomain else { return false }
    return posixError.code == Int(EPERM) || posixError.code == Int(EACCES)
  }
}

extension LocalFileProvider: FileBrowserDuplicateProvider {
  func duplicate(_ item: FileItem) async throws {
    guard item.location.providerID == id, let url = item.location.localURL else {
      throw LocalFileProviderError.invalidLocation
    }
    _ = try duplicate(url)
  }
}

extension LocalFileProvider {
  func contents(of location: FileLocation, includingHidden: Bool) async throws -> [FileItem] {
    guard location.providerID == id, let url = location.localURL else {
      throw LocalFileProviderError.invalidLocation
    }
    return try await Task.detached(priority: .userInitiated) {
      try self.contents(of: url, includingHidden: includingHidden)
    }.value
  }
}

extension LocalFileProvider: FileBrowserItemDetailProvider {
  func detailedItem(at location: FileLocation) async throws -> FileItem {
    guard location.providerID == id, let url = location.localURL else {
      throw LocalFileProviderError.invalidLocation
    }
    return try await Task.detached(priority: .userInitiated) {
      try self.item(at: url)
    }.value
  }
}

extension LocalFileProvider: FileBrowserPosixPermissionsProvider {
  func setPosixPermissions(_ permissions: Int, at location: FileLocation) async throws {
    guard location.providerID == id, let url = location.localURL else {
      throw LocalFileProviderError.invalidLocation
    }
    let normalizedPermissions = PosixPermissions.normalizedMode(permissions)
    try await Task.detached(priority: .userInitiated) {
      try FileManager.default.setAttributes(
        [.posixPermissions: normalizedPermissions],
        ofItemAtPath: url.path)
    }.value
  }
}

extension LocalFileProvider: FileBrowserFinderTagProvider {
  func setFinderTagNames(_ tagNames: [String], at location: FileLocation) async throws {
    guard location.providerID == id, let url = location.localURL else {
      throw LocalFileProviderError.invalidLocation
    }
    try await Task.detached(priority: .userInitiated) {
      try FinderTagResourceWriter.setTagNames(tagNames, at: url)
    }.value
  }
}

extension LocalFileProvider: FileBrowserFinderTagMetadataProvider {
  func finderTagNames(at location: FileLocation) async throws -> [String] {
    guard location.providerID == id, let url = location.localURL else {
      throw LocalFileProviderError.invalidLocation
    }
    return try await Task.detached(priority: .utility) {
      // 書込前のURLに残るリソース値キャッシュを引き継がず、現在のタグを読み直す。
      let freshURL = URL(fileURLWithPath: url.path)
      return try freshURL.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
    }.value
  }
}

extension LocalFileProvider: FileBrowserCloudStatusMetadataProvider {
  func isCloudManagedDirectory(_ location: FileLocation) async -> Bool {
    guard location.providerID == id, let url = location.localURL else { return false }
    if isCloudManagedFolder(url, isUbiquitousItem: { _ in false }) { return true }
    guard !cloudStatusReader.isDegraded else { return false }
    return await cloudStatusReader.values(for: url)?.isUbiquitousItem == true
  }

  func cloudDownloadStatuses(
    itemLocations: [FileLocation]
  ) async -> [URL: CloudDownloadStatus] {
    let urls = itemLocations.compactMap { location -> URL? in
      guard location.providerID == id else { return nil }
      return location.localURL
    }
    guard !urls.isEmpty else { return [:] }

    let reader = cloudStatusReader
    guard !reader.isDegraded else { return [:] }
    // 同じ親のクラウド判定は共有し、項目ごとにルート属性を取り直さない。
    let parents = Set(urls.map { $0.deletingLastPathComponent() })
    var parentFlags: [URL: Bool] = [:]
    await withTaskGroup(of: (URL, Bool).self) { group in
      var iterator = parents.makeIterator()
      func addNext() {
        guard !reader.isDegraded, let parent = iterator.next() else { return }
        group.addTask { (parent, await reader.values(for: parent)?.isUbiquitousItem == true) }
      }
      for _ in 0..<6 { addNext() }
      while let (parent, flag) = await group.next() {
        parentFlags[parent] = flag
        addNext()
      }
    }
    let precomputed = parentFlags
    let managedParents = Set(
      parents.filter { isCloudManagedFolder($0, isUbiquitousItem: { precomputed[$0] ?? false }) })
    return await withTaskGroup(
      of: (URL, CloudDownloadStatus)?.self, returning: [URL: CloudDownloadStatus].self
    ) { group in
      var iterator = urls.makeIterator()
      func addNext() {
        guard !reader.isDegraded, let url = iterator.next() else { return }
        group.addTask {
          let values = await reader.values(for: url)
          let status = CloudDownloadStatus.observed(
            isUbiquitous: values?.isUbiquitousItem,
            downloadingStatus: values?.downloadingStatus,
            isDownloading: values?.isDownloading,
            hasDownloadingError: values?.hasDownloadingError ?? false,
            isInCloudFolder: managedParents.contains(url.deletingLastPathComponent()))
          guard let status else { return nil }
          return (url, status)
        }
      }
      for _ in 0..<6 { addNext() }
      var statuses: [URL: CloudDownloadStatus] = [:]
      while let result = await group.next() {
        if let (url, status) = result { statuses[url] = status }
        addNext()
      }
      return statuses
    }
  }
}

/// .contentHash検証強度のローカル実装。現状はTransferSizeVerifier(既定の.size検証)から
/// 呼び出されず、どこからも有効化されていない基盤のみ(P1-1範囲)。
extension LocalFileProvider: FileContentHashProvider {
  func contentHash(at location: FileLocation) async throws -> Data {
    guard let url = location.localURL else {
      throw LocalFileProviderError.invalidLocation
    }
    return try await Task.detached(priority: .utility) {
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      var hasher = SHA256()
      while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
        hasher.update(data: chunk)
      }
      return Data(hasher.finalize())
    }.value
  }
}

extension LocalFileProvider: FileBrowserStreamingProvider {
  /// Finderに合わせ、実体がほぼ空(または存在しない)ローカルディレクトリへシステム側の
  /// アプリ群を重ねて見せるマージ元。キーはローカル側(優先)、値はシステム側(重複時は捨てる)。
  /// URL標準形で比較するため両辺ともstandardizedFileURLで保持する。
  private static let applicationsMergeOverlays: [URL: URL] = [
    URL(fileURLWithPath: "/Applications", isDirectory: true).standardizedFileURL:
      URL(fileURLWithPath: "/System/Applications", isDirectory: true).standardizedFileURL,
    URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true).standardizedFileURL:
      URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true).standardizedFileURL,
  ]

  /// directoryURLがマージ対象のローカルディレクトリなら、重ねて見せるシステム側ディレクトリを
  /// 返す。他の全フォルダ列挙への影響を標準形比較1回に抑えるための単純な辞書引き。
  static func applicationsMergeOverlay(for directoryURL: URL) -> URL? {
    applicationsMergeOverlays[directoryURL.standardizedFileURL]
  }

  /// primaryとoverlayを結合する純関数。名前が重複する場合はprimary(ローカル側)を優先し、
  /// overlay側の同名項目は捨てる。ソートは既存の名前昇順比較に合わせる。
  static func mergingApplications(primary: [FileItem], overlay: [FileItem]) -> [FileItem] {
    let primaryNames = Set(primary.map(\.name))
    let merged = primary + overlay.filter { !primaryNames.contains($0.name) }
    return merged.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  /// 1ディレクトリ分をボリューム種別に応じた既存の列挙経路(getattrlistbulk/readdir)で
  /// 収集する。マージ表示では小さいディレクトリ(Applications配下)しか対象にしないため、
  /// ストリーミングではなく全件収集で十分。
  private func collectContents(
    of directoryURL: URL,
    includingHidden: Bool
  ) async throws -> [FileItem] {
    var items = [FileItem]()
    let onEntry: (FileItem) async -> Void = { items.append($0) }
    if isLocalVolume(directoryURL) {
      try await enumerateWithGetattrlistbulk(
        directoryURL: directoryURL, includingHidden: includingHidden, onEntry: onEntry)
    } else {
      try await enumerateWithReaddir(
        directoryURL: directoryURL, includingHidden: includingHidden, onEntry: onEntry)
    }
    return items
  }

  func contentsStream(
    of location: FileLocation,
    includingHidden: Bool,
    batchSize: Int
  ) -> AsyncThrowingStream<[FileItem], Error> {
    AsyncThrowingStream { continuation in
      let task = Task.detached(priority: .userInitiated) {
        do {
          guard location.providerID == self.id, let directoryURL = location.localURL else {
            throw LocalFileProviderError.invalidLocation
          }

          // /Applications等を開くときだけシステム側ディレクトリの内容をマージする。他の
          // フォルダではこの判定(標準形の辞書引き1回)以外は既存の列挙経路と変わらない。
          if let overlayURL = Self.applicationsMergeOverlay(for: directoryURL) {
            let primaryItems = try await self.collectContents(
              of: directoryURL, includingHidden: includingHidden)
            // システム側の列挙に失敗しても、ローカル側(primary)の表示は妨げない。
            let overlayItems =
              (try? await self.collectContents(
                of: overlayURL, includingHidden: includingHidden)) ?? []
            let merged = Self.mergingApplications(primary: primaryItems, overlay: overlayItems)
            let chunkSize = max(batchSize, 1)
            var startIndex = 0
            while startIndex < merged.count {
              let endIndex = min(startIndex + chunkSize, merged.count)
              continuation.yield(Array(merged[startIndex..<endIndex]))
              startIndex = endIndex
              await Task.yield()
            }
            continuation.finish()
            return
          }

          var batch = [FileItem]()
          var hasPublishedInitialBatch = false
          let subsequentBatchSize = max(batchSize, 1)

          func appendItem(_ item: FileItem) async {
            batch.append(item)
            let requiredBatchSize =
              hasPublishedInitialBatch ? subsequentBatchSize : min(128, subsequentBatchSize)
            if batch.count == requiredBatchSize {
              continuation.yield(batch)
              batch.removeAll(keepingCapacity: true)
              hasPublishedInitialBatch = true
              await Task.yield()
            }
          }

          if self.isLocalVolume(directoryURL) {
            try await self.enumerateWithGetattrlistbulk(
              directoryURL: directoryURL,
              includingHidden: includingHidden,
              onEntry: appendItem)
          } else {
            try await self.enumerateWithReaddir(
              directoryURL: directoryURL,
              includingHidden: includingHidden,
              onEntry: appendItem)
          }

          if !batch.isEmpty {
            continuation.yield(batch)
          }
          continuation.finish()
        } catch is CancellationError {
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// ネットワークボリューム(SMB等)向けのreaddir(2)ベース列挙。
  /// macOS 15のSMBでgetattrlistbulkが不安定な問題(FB15497909)の回避経路として維持する。
  /// 属性を同時取得しないためsize/modifiedAtは常にnil。
  private func enumerateWithReaddir(
    directoryURL: URL,
    includingHidden: Bool,
    onEntry: (FileItem) async -> Void
  ) async throws {
    guard let directory = opendir(directoryURL.path) else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { closedir(directory) }
    while let pointer = readdir(directory) {
      try Task.checkCancellation()
      var entry = pointer.pointee
      let nameLength = Int(entry.d_namlen)
      let name = withUnsafePointer(to: &entry.d_name) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: nameLength + 1) {
          String(cString: $0)
        }
      }
      guard name != ".", name != ".." else { continue }
      guard includingHidden || !name.hasPrefix(".") else { continue }
      let url = directoryURL.appending(
        path: name,
        directoryHint: entry.d_type == UInt8(DT_DIR) ? .isDirectory : .notDirectory)
      let isDirectory: Bool
      if entry.d_type == UInt8(DT_DIR) {
        isDirectory = true
      } else if entry.d_type == UInt8(DT_UNKNOWN)
        || entry.d_type == UInt8(DT_LNK)
      {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        isDirectory = values.isDirectory ?? false
      } else {
        isDirectory = false
      }
      await onEntry(
        FileItem(
          normalizedLocalURL: url,
          name: name,
          isDirectory: isDirectory))
    }
  }

  /// getattrlistbulk(2)で要求する属性ビット。ClangImporterによる符号あり/なしの型の揺れを
  /// 避けるため、getattrlist(2)のヘッダー(sys/attr.h)に記載の値をそのままUInt32で持つ。
  private enum GetattrlistbulkAttribute {
    static let commonReturnedAttrs: UInt32 = 0x8000_0000  // ATTR_CMN_RETURNED_ATTRS
    static let commonName: UInt32 = 0x0000_0001  // ATTR_CMN_NAME
    static let commonObjType: UInt32 = 0x0000_0008  // ATTR_CMN_OBJTYPE
    static let commonModTime: UInt32 = 0x0000_0400  // ATTR_CMN_MODTIME
    static let commonError: UInt32 = 0x2000_0000  // ATTR_CMN_ERROR
    static let fileDataLength: UInt32 = 0x0000_0200  // ATTR_FILE_DATALENGTH
    static let bitmapCount: UInt16 = 5  // ATTR_BIT_MAP_COUNT
  }

  /// sys/vnode.hのenum vtype(fsobj_type_tの値)。同上の理由でリテラルとして持つ。
  private enum GetattrlistbulkObjectType {
    static let file: UInt32 = 1  // VREG
    static let directory: UInt32 = 2  // VDIR
    static let symbolicLink: UInt32 = 5  // VLNK
  }

  /// ローカルボリューム向けのgetattrlistbulk(2)ベース列挙。
  /// 名前・種別・更新日時・サイズを1回の呼び出しでまとめて取得し、readdir+都度stat相当の
  /// オーバーヘッドを避ける。バッファは64KB、戻り値0(列挙終了)まで反復する。
  private func enumerateWithGetattrlistbulk(
    directoryURL: URL,
    includingHidden: Bool,
    onEntry: (FileItem) async -> Void
  ) async throws {
    let dirFileDescriptor = open(directoryURL.path, O_RDONLY, 0)
    guard dirFileDescriptor >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { close(dirFileDescriptor) }

    var attributeList = attrlist()
    attributeList.bitmapcount = GetattrlistbulkAttribute.bitmapCount
    attributeList.commonattr =
      GetattrlistbulkAttribute.commonReturnedAttrs
      | GetattrlistbulkAttribute.commonName
      | GetattrlistbulkAttribute.commonObjType
      | GetattrlistbulkAttribute.commonModTime
      | GetattrlistbulkAttribute.commonError
    attributeList.fileattr = GetattrlistbulkAttribute.fileDataLength

    let bufferSize = 64 * 1024
    var buffer = [UInt8](repeating: 0, count: bufferSize)

    while true {
      try Task.checkCancellation()
      let entryCount = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
        Int(
          getattrlistbulk(
            dirFileDescriptor, &attributeList, rawBuffer.baseAddress, rawBuffer.count, 0))
      }
      if entryCount < 0 {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      if entryCount == 0 { break }

      let items = try buffer.withUnsafeBytes { rawBuffer in
        try Self.parseGetattrlistbulkEntries(
          rawBuffer,
          entryCount: entryCount,
          directoryURL: directoryURL,
          includingHidden: includingHidden)
      }
      for item in items {
        try Task.checkCancellation()
        await onEntry(item)
      }
    }
  }

  /// getattrlistbulkが書き込んだバッファを解析してFileItemへ変換する。
  /// 各エントリは [長さ(u32)] [attribute_set_t(返却済み属性,20byte)] に続けて、
  /// ERROR→NAME→OBJTYPE→MODTIME→[ファイル属性群]DATALENGTHの順で各値が詰められている。
  /// man getattrlistbulk(2)に明記のとおりATTR_CMN_ERRORはATTR_CMN_RETURNED_ATTRS
  /// (attribute_set_t)の直後に位置する。ビット値の昇順(ERROR=0x2000_0000が最後)という
  /// 誤った仮定で他フィールドの後ろに置くと、ERRORが返るエントリだけ以降の全フィールドが
  /// 4byteずれ、文字化けした行名や不正なサイズを生む。
  static func parseGetattrlistbulkEntries(
    _ rawBuffer: UnsafeRawBufferPointer,
    entryCount: Int,
    directoryURL: URL,
    includingHidden: Bool
  ) throws -> [FileItem] {
    var results = [FileItem]()
    results.reserveCapacity(entryCount)
    var cursor = 0

    for _ in 0..<entryCount {
      let entryStart = cursor
      let entryLength = Int(rawBuffer.loadUnaligned(fromByteOffset: cursor, as: UInt32.self))
      var fieldCursor = cursor + 4

      let returnedCommonAttr = rawBuffer.loadUnaligned(
        fromByteOffset: fieldCursor, as: UInt32.self)
      let returnedFileAttr = rawBuffer.loadUnaligned(
        fromByteOffset: fieldCursor + 12, as: UInt32.self)
      fieldCursor += 20  // attribute_set_t (commonattr/volattr/dirattr/fileattr/forkattr各4byte)

      // ATTR_CMN_ERRORはattribute_set_tの直後(NAME等の実データより前)に位置する。ここで
      // 先に読み切っておかないと以降のNAME/OBJTYPE/MODTIME/SIZEの読み取り位置が4byteずれる。
      let hasAttributeError = returnedCommonAttr & GetattrlistbulkAttribute.commonError != 0
      if hasAttributeError {
        fieldCursor += 4
      }

      guard returnedCommonAttr & GetattrlistbulkAttribute.commonName != 0 else {
        // ATTR_BULK_REQUIREDによりNAMEは常に返る想定だが、防御的に次のエントリへ進む。
        cursor = entryStart + entryLength
        continue
      }
      let nameReferenceOffset = fieldCursor
      let nameDataOffset = Int(
        rawBuffer.loadUnaligned(fromByteOffset: fieldCursor, as: Int32.self))
      let nameAttrLength = Int(
        rawBuffer.loadUnaligned(fromByteOffset: fieldCursor + 4, as: UInt32.self))
      fieldCursor += 8
      let nameBytesStart = nameReferenceOffset + nameDataOffset
      // attr_lengthは終端NULを含むため、文字列本体はnameAttrLength-1byte。
      let nameByteCount = max(0, nameAttrLength - 1)
      let namePointer = rawBuffer.baseAddress!.advanced(by: nameBytesStart)
      let name = String(
        decoding: UnsafeRawBufferPointer(start: namePointer, count: nameByteCount),
        as: UTF8.self)

      var objectType: UInt32?
      if returnedCommonAttr & GetattrlistbulkAttribute.commonObjType != 0 {
        objectType = rawBuffer.loadUnaligned(fromByteOffset: fieldCursor, as: UInt32.self)
        fieldCursor += 4
      }

      var modifiedAt: Date?
      if returnedCommonAttr & GetattrlistbulkAttribute.commonModTime != 0 {
        let modificationTime = rawBuffer.loadUnaligned(
          fromByteOffset: fieldCursor, as: timespec.self)
        fieldCursor += MemoryLayout<timespec>.size
        modifiedAt = Date(
          timeIntervalSince1970: Double(modificationTime.tv_sec)
            + Double(modificationTime.tv_nsec) / 1_000_000_000)
      }

      var size: Int64?
      if returnedFileAttr & GetattrlistbulkAttribute.fileDataLength != 0 {
        let dataLength = rawBuffer.loadUnaligned(fromByteOffset: fieldCursor, as: UInt64.self)
        size = Int64(bitPattern: dataLength)
        fieldCursor += 8
      }

      cursor = entryStart + entryLength

      guard name != ".", name != ".." else { continue }
      guard includingHidden || !name.hasPrefix(".") else { continue }

      let url = directoryURL.appending(
        path: name,
        directoryHint: !hasAttributeError && objectType == GetattrlistbulkObjectType.directory
          ? .isDirectory : .notDirectory)

      let isDirectory: Bool
      let isSymbolicLink: Bool
      if hasAttributeError {
        // エラーコード非ゼロのエントリはOBJTYPE等の値を信用せず、readdir経路と同様に
        // resourceValuesへ確実にフォールバックする(ビットがたまたま立っていても値は無効の想定)。
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        isDirectory = values.isDirectory ?? false
        isSymbolicLink = false
      } else {
        switch objectType {
        case GetattrlistbulkObjectType.directory:
          isDirectory = true
          isSymbolicLink = false
        case GetattrlistbulkObjectType.file:
          isDirectory = false
          isSymbolicLink = false
        case GetattrlistbulkObjectType.symbolicLink:
          let values = try url.resourceValues(forKeys: [.isDirectoryKey])
          isDirectory = values.isDirectory ?? false
          isSymbolicLink = true
        default:
          // OBJTYPE不明(exFAT等)はreaddir経路と同様にresourceValuesへフォールバックする。
          let values = try url.resourceValues(forKeys: [.isDirectoryKey])
          isDirectory = values.isDirectory ?? false
          isSymbolicLink = false
        }
      }

      results.append(
        FileItem(
          normalizedLocalURL: url,
          name: name,
          isDirectory: isDirectory,
          isSymbolicLink: isSymbolicLink,
          size: size,
          modifiedAt: modifiedAt))
    }
    return results
  }
}

extension LocalFileProvider: FileBrowserTransferProvider {
  func move(
    _ item: FileItem,
    to directory: FileLocation,
    replacingExisting: Bool
  ) async throws {
    guard item.location.providerID == id,
      directory.providerID == id,
      let directoryURL = directory.localURL
    else {
      throw LocalFileProviderError.invalidLocation
    }
    _ = try await CancellableFileCopier.performOnDedicatedThread { isCancelled in
      try self.move(
        item.url,
        to: directoryURL,
        replacingExisting: replacingExisting,
        isCancelled: isCancelled)
    }
  }

  func copy(
    _ item: FileItem,
    to directory: FileLocation,
    replacingExisting: Bool
  ) async throws {
    guard item.location.providerID == id,
      directory.providerID == id,
      let directoryURL = directory.localURL
    else {
      throw LocalFileProviderError.invalidLocation
    }
    _ = try await CancellableFileCopier.performOnDedicatedThread { isCancelled in
      try self.copy(
        item.url,
        to: directoryURL,
        replacingExisting: replacingExisting,
        isCancelled: isCancelled)
    }
  }

  func removeAfterCrossProviderMove(_ item: FileItem) async throws {
    guard item.location.providerID == id else {
      throw LocalFileProviderError.invalidLocation
    }
    try FileManager.default.removeItem(at: item.url)
  }
}

extension LocalFileProvider: FileBrowserProgressTransferProvider {
  func copy(
    _ item: FileItem,
    to directory: FileLocation,
    replacingExisting: Bool,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws {
    guard item.location.providerID == id,
      directory.providerID == id,
      let directoryURL = directory.localURL
    else {
      throw LocalFileProviderError.invalidLocation
    }
    _ = try await CancellableFileCopier.performOnDedicatedThread { isCancelled in
      try self.copy(
        item.url,
        to: directoryURL,
        replacingExisting: replacingExisting,
        progress: progress,
        isCancelled: isCancelled)
    }
  }
}

extension LocalFileProvider: FileStreamTransferProvider {
  var preferredTransferChunkSize: Int { 1_048_576 }

  func fileChunks(for item: FileItem, chunkSize: Int) -> AsyncThrowingStream<Data, Error> {
    // 約4MB分をバッファする(チャンクサイズが小さいほど多くの個数を許容する)。
    let limit = max(4, (4 * 1_048_576) / chunkSize)
    return BoundedChunkPipe.stream(limit: limit) { yield in
      guard item.location.providerID == self.id else {
        throw LocalFileProviderError.invalidLocation
      }
      let handle = try FileHandle(forReadingFrom: item.url)
      defer { try? handle.close() }
      while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
        try Task.checkCancellation()
        try await yield(chunk)
      }
    }
  }

  func writeFileChunks(
    _ chunks: AsyncThrowingStream<Data, Error>,
    to destination: FileLocation,
    replacingExisting: Bool,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws {
    guard destination.providerID == id,
      let destinationURL = destination.localURL
    else {
      throw LocalFileProviderError.invalidLocation
    }
    if FileManager.default.fileExists(atPath: destinationURL.path) {
      guard replacingExisting else { throw CocoaError(.fileWriteFileExists) }
      try FileManager.default.removeItem(at: destinationURL)
    }
    FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
    let handle = try FileHandle(forWritingTo: destinationURL)
    defer { try? handle.close() }
    var completedBytes: Int64 = 0
    for try await chunk in chunks {
      try Task.checkCancellation()
      try handle.write(contentsOf: chunk)
      completedBytes += Int64(chunk.count)
      progress(completedBytes)
    }
  }
}

extension LocalFileProvider: FileTransferCommitProvider {
  func commitTransferFile(
    from temporaryLocation: FileLocation,
    to destination: FileLocation,
    replacingExisting: Bool
  ) async throws {
    guard temporaryLocation.providerID == id,
      destination.providerID == id,
      let temporaryURL = temporaryLocation.localURL,
      let destinationURL = destination.localURL
    else {
      throw LocalFileProviderError.invalidLocation
    }
    if FileManager.default.fileExists(atPath: destinationURL.path) {
      guard replacingExisting else { throw CocoaError(.fileWriteFileExists) }
      _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: temporaryURL)
    } else {
      try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
    }
  }

  func discardTransferFile(at temporaryLocation: FileLocation) async {
    guard temporaryLocation.providerID == id,
      let temporaryURL = temporaryLocation.localURL
    else { return }
    try? FileManager.default.removeItem(at: temporaryURL)
  }
}

extension LocalFileProvider: FileBrowserPreviewProvider {
  func previewURL(for item: FileItem) async throws -> URL {
    guard item.location.providerID == id else {
      throw LocalFileProviderError.invalidLocation
    }
    return item.url
  }
}

enum LocalFileProviderError: LocalizedError {
  case invalidLocation

  var errorDescription: String? {
    "このローカル接続に属さない場所です。"
  }
}
