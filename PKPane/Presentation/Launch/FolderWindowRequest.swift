import Foundation

/// 追加ウインドウは元ウインドウと独立したアクセス許可と復元データを持つ。
struct FolderWindowRequest: Codable, Hashable {
  static let sceneID = "folder-window"
  let id: UUID
  let folderURL: URL
  let bookmarkData: Data

  init?(location: FileLocation, codec: any FolderBookmarkCoding = SystemFolderBookmarkCodec())
    throws
  {
    guard let url = location.localURL, url.isFileURL else { return nil }
    id = UUID()
    folderURL = url
    bookmarkData = try codec.createBookmark(for: url)
  }

  func resolvedURL(codec: any FolderBookmarkCoding = SystemFolderBookmarkCodec()) -> URL {
    if let resolved = try? codec.resolveBookmark(bookmarkData), resolved.url.isFileURL {
      return resolved.url
    }
    // 解決できない場合も既存のフォルダ許可導線へ進め、別フォルダへ置換しない。
    return folderURL
  }

  func workspaceStore(defaultURL: URL = JSONWorkspaceStateStore().url) -> JSONWorkspaceStateStore {
    JSONWorkspaceStateStore(
      url: defaultURL.deletingLastPathComponent()
        .appending(path: "windows", directoryHint: .isDirectory)
        .appending(path: "\(id.uuidString).json"))
  }

  var selectedFolderBookmarkKey: String { "folder-window-selected-\(id.uuidString)" }
}
