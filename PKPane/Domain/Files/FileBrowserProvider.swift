import Foundation

struct FileBrowserBreadcrumb: Identifiable, Equatable, Sendable {
  let location: FileLocation
  let name: String

  var id: FileLocation { location }
}

protocol FileBrowserProvider: Sendable {
  var id: FileProviderID { get }
  var connectionID: FileProviderConnectionID? { get }
  var capabilities: FileProviderCapabilities { get }

  func contents(of location: FileLocation) async throws -> [FileItem]
  func contents(of location: FileLocation, includingHidden: Bool) async throws -> [FileItem]
  func parent(of location: FileLocation) -> FileLocation?
  func breadcrumbs(
    for location: FileLocation,
    constrainedTo root: FileLocation?
  ) -> [FileBrowserBreadcrumb]
}

extension FileBrowserProvider {
  func contents(of location: FileLocation, includingHidden _: Bool) async throws -> [FileItem] {
    try await contents(of: location)
  }

  /// Providerが宣言したCapabilityのうち、対応する実行プロトコルも備えるものだけを返す。
  /// メニューはこの値を使い、表示上は有効なのに実行時に unavailable となる状態を防ぐ。
  var executableCapabilities: FileProviderCapabilities {
    var result = capabilities
    if !(self is any FileBrowserOperationProvider) {
      result.subtract([.write, .rename])
    }
    if !(self is any FileBrowserTransferProvider) {
      result.subtract([.moveWithinProvider, .copyWithinProvider])
    }
    if !(self is any FileBrowserTrashProvider) {
      result.remove(.trash)
    }
    if !(self is any FileBrowserPermanentDeleteProvider) {
      result.remove(.deletePermanently)
    }
    return result
  }
}

protocol FileBrowserOperationProvider: FileBrowserProvider {
  func createDirectory(named name: String, in location: FileLocation) async throws
  func rename(_ item: FileItem, to name: String) async throws
  func delete(_ item: FileItem) async throws
}

/// `delete(_:)`が完全削除ではなく、OSまたはマウント先のゴミ箱へ移動するProviderです。
/// 同期実行はこの型に適合する送り先でだけ削除を許可します。
protocol FileBrowserTrashProvider: FileBrowserOperationProvider {}

/// ゴミ箱を経由せず、確認済みの項目を完全に削除できるProviderです。
protocol FileBrowserPermanentDeleteProvider: FileBrowserOperationProvider {
  func permanentlyDelete(_ item: FileItem) async throws
}

/// 同一フォルダ内への複製をサポートするProviderです。
protocol FileBrowserDuplicateProvider: FileBrowserOperationProvider {
  func duplicate(_ item: FileItem) async throws
}

enum FileBrowserOperationError: LocalizedError {
  case trashUnavailable
  case writeAccessRequired(directory: URL)
  case writeAccessFolderMismatch(directory: URL)
  case insufficientPermission(itemName: String)

  var errorDescription: String? {
    switch self {
    case .trashUnavailable:
      "この接続ではゴミ箱へ移動できません。"
    case .writeAccessRequired:
      String(localized: "フォルダへの書き込み許可が必要です")
    case .writeAccessFolderMismatch(let directory):
      String(
        format: String(localized: "選択したフォルダに「%@」が含まれていません。"),
        directory.lastPathComponent)
    case .insufficientPermission(let itemName):
      String(
        format: String(
          localized: "「%@」を削除する権限がありません。管理者が所有する項目(App Store からインストールしたアプリなど)は Finder で削除してください。"),
        itemName)
    }
  }
}

protocol FileBrowserTransferProvider: FileBrowserOperationProvider {
  func move(
    _ item: FileItem,
    to directory: FileLocation,
    replacingExisting: Bool
  ) async throws
  func copy(
    _ item: FileItem,
    to directory: FileLocation,
    replacingExisting: Bool
  ) async throws
  func removeAfterCrossProviderMove(_ item: FileItem) async throws
}

extension FileBrowserTransferProvider {
  func move(_ item: FileItem, to directory: FileLocation) async throws {
    try await move(item, to: directory, replacingExisting: false)
  }

  func copy(_ item: FileItem, to directory: FileLocation) async throws {
    try await copy(item, to: directory, replacingExisting: false)
  }
}

/// 同一Provider内のコピーでも、利用可能な進捗を転送キューへ報告できるProviderです。
protocol FileBrowserProgressTransferProvider: FileBrowserTransferProvider {
  func copy(
    _ item: FileItem,
    to directory: FileLocation,
    replacingExisting: Bool,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws
}

extension FileBrowserProgressTransferProvider {
  func copy(
    _ item: FileItem,
    to directory: FileLocation,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws {
    try await copy(
      item,
      to: directory,
      replacingExisting: false,
      progress: progress)
  }
}

/// 完了するまで確定名を公開しないファイル転送のコミット操作です。
protocol FileTransferCommitProvider: FileBrowserOperationProvider {
  /// 書き込み直後の一時ファイルを、書き込みと同じチャネルで検証できる場合の実サイズです。
  /// nilの場合はTransferSizeVerifierがProvider共通の検証経路へフォールバックします。
  func stagedFileSize(at temporaryLocation: FileLocation) async throws -> Int64?

  func commitTransferFile(
    from temporaryLocation: FileLocation,
    to destination: FileLocation,
    replacingExisting: Bool
  ) async throws

  func discardTransferFile(at temporaryLocation: FileLocation) async
}

extension FileTransferCommitProvider {
  func stagedFileSize(at _: FileLocation) async throws -> Int64? { nil }
}

protocol FileBrowserPreviewProvider: FileBrowserProvider {
  func previewURL(for item: FileItem) async throws -> URL

  /// 詳細ペインの単一選択だけで使うサムネイル元URL。選択だけで通信が発生しない
  /// Providerだけが実装し、既定では利用不可とする。
  func detailThumbnailURL(for item: FileItem) async throws -> URL?
}

extension FileBrowserPreviewProvider {
  func detailThumbnailURL(for _: FileItem) async throws -> URL? { nil }
}

/// 一覧表示とは別に、選択した1項目の詳細メタデータを取得するProviderです。
protocol FileBrowserItemDetailProvider: FileBrowserProvider {
  func detailedItem(at location: FileLocation) async throws -> FileItem
}

/// 単一項目のPOSIXパーミッションを変更できるProviderです。所有者・グループ変更や
/// 特殊ビットは扱わず、呼び出し側は下位9ビットだけを渡します。
protocol FileBrowserPosixPermissionsProvider: FileBrowserProvider {
  func setPosixPermissions(_ permissions: Int, at location: FileLocation) async throws
}

/// FinderタグをURLResourceValuesへ書き込めるローカル実体Providerです。
/// SFTPなどlocalURLを持たないProviderは準拠しません。
protocol FileBrowserFinderTagProvider: FileBrowserProvider {
  func setFinderTagNames(_ tagNames: [String], at location: FileLocation) async throws
}

/// 一覧で欠けているFinderタグだけを、サイズ・所有者・アクセス権などの詳細情報を
/// 取得せずに補完できるProviderです。
protocol FileBrowserFinderTagMetadataProvider: FileBrowserProvider {
  func finderTagNames(at location: FileLocation) async throws -> [String]
}

/// 一覧項目のiCloudダウンロード状態だけを、列挙後に補完できるProviderです。
protocol FileBrowserCloudStatusMetadataProvider: FileBrowserProvider {
  func cloudDownloadStatuses(itemLocations: [FileLocation]) async -> [URL: CloudDownloadStatus]
  /// 一覧を開くたびにメインスレッドで同期 XPC を呼ばないよう、クラウド管理下の判定を
  /// 非同期にしてProvider側へ移す。
  func isCloudManagedDirectory(_ location: FileLocation) async -> Bool
}

extension FileBrowserCloudStatusMetadataProvider {
  /// 属性を読まないパス判定だけの既定実装。
  func isCloudManagedDirectory(_ location: FileLocation) async -> Bool {
    guard let url = location.localURL else { return false }
    return isCloudManagedFolder(url, isUbiquitousItem: { _ in false })
  }
}

/// 選択した1項目の実サイズだけを軽量に取得できるProviderです。転送検証
/// (TransferSizeVerifier)は、親ディレクトリの全列挙や詳細メタデータ全体の取得より
/// 安価なこちらを優先します(例: SFTPの単一stat)。
protocol FileBrowserItemSizeProvider: FileBrowserProvider {
  func itemSize(at location: FileLocation) async throws -> Int64?
}

/// 大量フォルダを全件列挙完了前に表示するための逐次列挙Providerです。
protocol FileBrowserStreamingProvider: FileBrowserProvider {
  func contentsStream(
    of location: FileLocation,
    includingHidden: Bool,
    batchSize: Int
  ) -> AsyncThrowingStream<[FileItem], Error>
}

/// リモートファイルの作業コピーを外部アプリで編集するためのProviderです。
protocol RemoteEditProvider: FileBrowserProvider {
  func downloadWorkingCopy(for item: FileItem, to localURL: URL) async throws
  func item(at location: FileLocation) async throws -> FileItem?
  func uploadWorkingCopySafely(from localURL: URL, to location: FileLocation) async throws
}
