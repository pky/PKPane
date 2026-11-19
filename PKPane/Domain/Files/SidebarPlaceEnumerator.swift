import Foundation

/// 「場所」セクションの列挙ロジック。FileManager依存を全てクロージャ/引数注入にし、
/// 実ボリュームなしで表駆動テストできるようにする。
enum SidebarPlaceEnumerator {
  struct VolumeInfo: Equatable, Sendable {
    let url: URL
    let localizedName: String?
    let isLocal: Bool
    let isRootFileSystem: Bool
    let isInternal: Bool
    let isRemovable: Bool
    let isEjectable: Bool
    let availableCapacity: Int64?

    init(
      url: URL,
      localizedName: String?,
      isLocal: Bool,
      isRootFileSystem: Bool,
      isInternal: Bool,
      isRemovable: Bool,
      isEjectable: Bool,
      availableCapacity: Int64? = nil
    ) {
      self.url = url
      self.localizedName = localizedName
      self.isLocal = isLocal
      self.isRootFileSystem = isRootFileSystem
      self.isInternal = isInternal
      self.isRemovable = isRemovable
      self.isEjectable = isEjectable
      self.availableCapacity = availableCapacity
    }
  }

  /// Finderの「場所」と同様、ローカルボリュームを名前順のSidebarPlaceへ変換する。
  /// ネットワークボリュームはNASの接続状態を持つ専用モデルで表示するため、ここでは除外する。
  static func volumePlaces(from volumes: [VolumeInfo]) -> [SidebarPlace] {
    volumes
      .filter(\.isLocal)
      .filter {
        !$0.url.standardizedFileURL.pathComponents.starts(with: ["/", "System", "Volumes"])
      }
      .map { info in
        SidebarPlace(
          id: info.url.standardizedFileURL.path,
          url: info.url,
          displayName: info.localizedName ?? info.url.lastPathComponent,
          detail: info.url.standardizedFileURL.path,
          kind: .volume(isEjectable: info.isEjectable))
      }
      .sorted {
        $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
      }
  }

  /// iCloud Drive(存在時のみ1件)。
  static func iCloudDrivePlace(homeDirectory: URL, fileExists: (URL) -> Bool) -> SidebarPlace? {
    let url = homeDirectory.appending(path: "Library/Mobile Documents/com~apple~CloudDocs")
    guard fileExists(url) else { return nil }
    return SidebarPlace(
      id: url.standardizedFileURL.path,
      url: url,
      displayName: "iCloud Drive",
      detail: nil,
      kind: .iCloudDrive)
  }

  /// ~/Library/CloudStorage 配下のクラウドドライブを名前順の場所へ変換する。
  static func cloudStoragePlaces(
    directories: [URL],
    displayNameProvider: (URL) -> String
  ) -> [SidebarPlace] {
    directories
      .map { url in
        let folderName = url.lastPathComponent
        let accountSuffix = folderName.split(separator: "-", maxSplits: 1)
          .dropFirst().first.map(String.init)
        return SidebarPlace(
          id: url.standardizedFileURL.path,
          url: url,
          displayName: displayNameProvider(url),
          detail: accountSuffix,
          kind: .cloudStorage)
      }
      .sorted {
        $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
      }
  }
}
