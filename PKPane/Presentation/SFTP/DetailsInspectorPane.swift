import AppKit
import SwiftUI

enum DetailsThumbnailSizing {
  static let minimumDisplaySize: CGFloat = 120
  static let maximumDisplaySize: CGFloat = 400
  static let horizontalContentPadding: CGFloat = 32

  static func displaySize(paneWidth: CGFloat) -> CGFloat {
    min(
      max(paneWidth - horizontalContentPadding, minimumDisplaySize),
      maximumDisplaySize)
  }
}

/// ProviderBrowserView右端の詳細ペイン(インスペクタ)。アクティブペインの選択に追従する
/// itemsを外側(ProviderBrowserView)が解決して渡す(単一選択/複数選択/選択なし→現在
/// フォルダの代替1件、のいずれか)。表示部品はFileInfoContentをFileInfoView(⌘Iダイアログ)と
/// 共有し、二重実装を避ける。このView自体はペインが表示されている間だけ生成されるため、
/// 閉じている間はitemsの変化を一切観測せず、詳細取得・サムネイル生成も発生しない。
struct DetailsInspectorPane: View {
  let items: [FileItem]
  let detailItem: ((FileItem) async -> FileItem)?
  let permissionUpdater: FileInfoContentModel.PermissionUpdater?
  let finderTagUpdater: FileInfoContentModel.FinderTagUpdater?
  let thumbnailURLResolver: FileInfoContentModel.ThumbnailURLResolver?
  @State private var model = FileInfoContentModel()

  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        FileInfoContent(
          items: items,
          displayedItem: model.displayedItem,
          headerImage: model.headerImage,
          thumbnailSize: DetailsThumbnailSizing.displaySize(paneWidth: geometry.size.width),
          layout: .pane,
          folderScanPhase: model.folderScanPhase,
          onStartFolderScan: { model.startFolderScan(for: $0) },
          onCancelFolderScan: { model.cancelFolderScan() },
          onCopyPath: { copyPath(of: $0) },
          permissionMode: model.permissionMode,
          permissionOctalInput: model.permissionOctalInput,
          canEditPermissions: model.canEditPermissions,
          isApplyingPermissions: model.isApplyingPermissions,
          permissionErrorMessage: model.permissionErrorMessage,
          onSetPermission: { model.setPermission($0, enabled: $1) },
          onChangePermissionOctalInput: { model.updatePermissionOctalInput($0) },
          onCommitPermissionOctalInput: { model.commitPermissionOctalInput() },
          finderTagNames: model.finderTagNames,
          finderTagCandidates: model.finderTagCandidates,
          canEditFinderTags: model.canEditFinderTags,
          isApplyingFinderTags: model.isApplyingFinderTags,
          finderTagErrorMessage: model.finderTagErrorMessage,
          onChangeFinderTagNames: { model.updateFinderTagNames($0) }
        )
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .accessibilityIdentifier("details-inspector-pane")
    .onAppear {
      model.setSelection(
        items,
        detailItem: detailItem,
        permissionUpdater: permissionUpdater,
        finderTagUpdater: finderTagUpdater,
        thumbnailURLResolver: thumbnailURLResolver)
    }
    .onChange(of: items) { _, newItems in
      model.setSelection(
        newItems,
        detailItem: detailItem,
        permissionUpdater: permissionUpdater,
        finderTagUpdater: finderTagUpdater,
        thumbnailURLResolver: thumbnailURLResolver)
    }
  }

  private func copyPath(of item: FileItem) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(item.pathForClipboard, forType: .string)
  }
}
