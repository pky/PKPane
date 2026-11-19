import Foundation

/// ターミナルへ渡すローカル実体パスを、UI状態から解決する純関数群。
enum DeveloperToolTargetResolver {
  /// 選択項目があれば一覧順の先頭を使い、ファイルなら親フォルダを対象にする。
  /// 未選択時は現在のフォルダを使う。SFTPなどローカル実体パスがなければnilを返す。
  static func terminalDirectory(
    selectedItems: [FileItem],
    currentLocation: FileLocation
  ) -> URL? {
    guard let firstItem = selectedItems.first else {
      return currentLocation.localURL
    }
    guard let localURL = firstItem.location.localURL else { return nil }
    return firstItem.isDirectory ? localURL : localURL.deletingLastPathComponent()
  }
}
