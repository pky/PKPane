import Foundation

enum CloudStatusCachePolicy {
  static let directoryLimit = 128
}

/// OSから観測できたクラウド取得状態。属性の欠落を取得済みと同一視しない。
enum CloudDownloadStatus: Equatable, Sendable {
  case notDownloaded
  case downloading
  case failed
  case unknown
  case downloaded
  case current

  init(_ status: URLUbiquitousItemDownloadingStatus) {
    switch status {
    case .notDownloaded:
      self = .notDownloaded
    case .downloaded:
      self = .downloaded
    case .current:
      self = .current
    default:
      self = .unknown
    }
  }

  static func observed(
    isUbiquitous: Bool?, downloadingStatus: URLUbiquitousItemDownloadingStatus?,
    isDownloading: Bool?, hasDownloadingError: Bool, isInCloudFolder: Bool
  ) -> Self? {
    guard isUbiquitous == true || isInCloudFolder else { return nil }
    if isDownloading == true { return .downloading }
    if hasDownloadingError { return .failed }
    guard let downloadingStatus else { return .unknown }
    return Self(downloadingStatus)
  }

  var indicatorLabel: String? {
    switch self {
    case .notDownloaded: String(localized: "未ダウンロード")
    case .downloading: String(localized: "クラウドから取得中")
    case .failed: String(localized: "クラウド取得に失敗")
    case .unknown: String(localized: "クラウド状態不明")
    case .downloaded, .current: nil
    }
  }

  var indicatorSystemImage: String? {
    switch self {
    case .notDownloaded: "icloud.and.arrow.down"
    case .downloading: "arrow.down.circle"
    case .failed: "exclamationmark.triangle"
    case .unknown: "questionmark.circle"
    case .downloaded, .current: nil
    }
  }

  var indicatorIdentifier: String? {
    switch self {
    case .notDownloaded: "cloud-status-notDownloaded"
    case .downloading: "cloud-status-downloading"
    case .failed: "cloud-status-failed"
    case .unknown: "cloud-status-unknown"
    case .downloaded, .current: nil
    }
  }

  var helpText: String {
    switch self {
    case .notDownloaded:
      String(localized: "内容はまだ取得されていません。必要な内容はmacOSが取得します。")
    case .downloading:
      String(localized: "macOSから取得中と報告されています。取得率は確認できません。")
    case .failed:
      String(localized: "macOSが取得失敗を報告しています。接続とアクセス権を確認し、一覧を更新して転送を再試行してください。")
    case .unknown:
      String(localized: "このクラウドサービスの取得状態を確認できません。公式アプリと一覧の更新で確認してください。")
    case .downloaded, .current:
      ""
    }
  }

  static var transferPreparationGuidance: String {
    String(
      localized: "クラウド取得を待つ場合があります。取消でmacOSの取得が止まるとは限りません。公式アプリとアクセス権を確認し、一覧更新後に転送を再試行してください。")
  }
}

/// フォルダ自体がクラウド管理下かを、パスとubiquitous属性の両方で判定する。
func isCloudManagedFolder(
  _ folderURL: URL,
  homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
  isUbiquitousItem: (URL) -> Bool = {
    (try? $0.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) ?? false
  }
) -> Bool {
  let resolvedFolderURL = folderURL.resolvingSymlinksInPath().standardizedFileURL
  let resolvedHomeURL = homeDirectory.resolvingSymlinksInPath().standardizedFileURL
  let cloudRoots = [
    resolvedHomeURL.appending(path: "Library/Mobile Documents", directoryHint: .isDirectory),
    resolvedHomeURL.appending(path: "Library/CloudStorage", directoryHint: .isDirectory),
  ]

  return cloudRoots.contains { rootURL in
    let rootPath = rootURL.standardizedFileURL.path
    let folderPath = resolvedFolderURL.path
    return folderPath == rootPath || folderPath.hasPrefix(rootPath + "/")
  } || isUbiquitousItem(folderURL)
}
