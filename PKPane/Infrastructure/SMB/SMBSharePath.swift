import Foundation

/// マウント済みSMB共有内のパスを、直接SMB接続に必要な情報へ変換した値です。
struct SMBSharePath: Equatable, Sendable {
  let host: String
  let shareName: String
  let relativePathComponents: [String]

  /// SMBClientへ渡す共有ルートからの相対パスです。
  var relativePath: String { relativePathComponents.joined(separator: "/") }

  /// SMB2 CREATEへ渡す共有ルートからの相対パスです。
  /// SMBClientのSession.createは経路を正規化しないため、SMBの区切り文字とNFCを明示します。
  var createPath: String {
    relativePath
      .replacingOccurrences(of: "/", with: "\\")
      .precomposedStringWithCanonicalMapping
  }

  init(host: String, shareName: String, relativePathComponents: [String]) {
    self.host = host
    self.shareName = shareName
    self.relativePathComponents = relativePathComponents
  }

  /// 現在マウント済みのSMBボリュームを調べて変換します。
  init?(folderURL: URL) {
    let mountedVolumes =
      FileManager.default.mountedVolumeURLs(
        includingResourceValuesForKeys: [.volumeURLForRemountingKey],
        options: [.skipHiddenVolumes]
      ) ?? []
    self.init(
      folderURL: folderURL,
      mountedVolumeURLs: mountedVolumes,
      remountingURLForVolume: { volumeURL in
        let resourceValues = try? volumeURL.resourceValues(
          forKeys: [.volumeURLForRemountingKey])
        return resourceValues?.volumeURLForRemounting
      })
  }

  /// テスト時はマウント一覧と再マウントURLを注入できます。
  init?(
    folderURL: URL,
    mountedVolumeURLs: [URL],
    remountingURLForVolume: (URL) -> URL?
  ) {
    let folderPathComponents = folderURL.standardizedFileURL.pathComponents
    let volumeURL = mountedVolumeURLs.first { volumeURL in
      let standardizedVolumeURL = volumeURL.standardizedFileURL
      guard folderPathComponents.starts(with: standardizedVolumeURL.pathComponents) else {
        return false
      }
      return remountingURLForVolume(volumeURL)?.scheme?.lowercased() == "smb"
    }
    guard let volumeURL else { return nil }

    guard
      let remountingURL = remountingURLForVolume(volumeURL),
      remountingURL.scheme?.lowercased() == "smb",
      let host = remountingURL.host,
      !host.isEmpty
    else {
      return nil
    }

    let shareName = remountingURL.lastPathComponent
    guard !shareName.isEmpty else { return nil }

    let volumePathComponents = volumeURL.standardizedFileURL.pathComponents
    guard folderPathComponents.starts(with: volumePathComponents) else { return nil }

    self.host = host
    self.shareName = shareName
    relativePathComponents = Array(folderPathComponents.dropFirst(volumePathComponents.count))
  }
}
