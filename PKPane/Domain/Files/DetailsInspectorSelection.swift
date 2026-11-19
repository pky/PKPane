import Foundation

/// 詳細ペイン(インスペクタ)が表示すべき項目群を、アクティブペインの選択状態から解決する
/// 純粋関数。ProviderBrowserView(SFTPBrowserView.swift)から選択(単一/複数/なし)と
/// 現在フォルダの代替1件を渡すだけで結果が決まるため、SwiftUIやFileBrowserSessionの
/// 実体なしに単体テストできる。
enum DetailsInspectorSelection {
  /// - Parameters:
  ///   - allItems: アクティブペインの現在の一覧項目。
  ///   - selectedURLs: 選択中のURL集合。
  ///   - currentFolderItem: 選択が空のときに代わりに表示する「現在フォルダ」項目。
  /// - Returns: FileInfoContentへそのまま渡せるitems配列。1件なら単一詳細、2件以上なら
  ///   件数+合計サイズ、0件なら「選択項目がありません」としてFileInfoContentが描画する。
  static func resolveItems(
    allItems: [FileItem],
    selectedURLs: Set<URL>,
    currentFolderItem: FileItem?
  ) -> [FileItem] {
    guard !selectedURLs.isEmpty else {
      return currentFolderItem.map { [$0] } ?? []
    }
    return allItems.filter { selectedURLs.contains($0.url) }
  }
}
