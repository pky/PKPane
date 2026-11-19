import AppKit
import SwiftUI

/// ⌘Iダイアログ。表示部品(ヘッダ・詳細グリッド・複数選択サマリ)はFileInfoContentへ集約し、
/// 詳細ペイン(DetailsInspectorPane)と共有する。状態管理・非同期処理もFileInfoContentModelへ
/// 集約し、このViewはダイアログ固有の外枠(タイトル・閉じるボタン)だけを持つ。
struct FileInfoView: View {
  @Environment(\.dismiss) private var dismiss
  let items: [FileItem]
  let detailItem: ((FileItem) async -> FileItem)?
  let permissionUpdater: FileInfoContentModel.PermissionUpdater?
  let finderTagUpdater: FileInfoContentModel.FinderTagUpdater?
  let thumbnailURLResolver: FileInfoContentModel.ThumbnailURLResolver?
  @State private var model = FileInfoContentModel()

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(items.count == 1 ? "情報を見る" : "\(items.count)項目の情報")
        .font(.title2)
        .fontWeight(.semibold)
      FileInfoContent(
        items: items,
        displayedItem: model.displayedItem,
        headerImage: model.headerImage,
        // Finderの情報ウィンドウ相当の見え方へ128pt以上へ拡大(旧64pt)。
        thumbnailSize: 160,
        layout: .dialog,
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
      HStack {
        Spacer()
        Button("閉じる") { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding()
    .frame(minWidth: 420)
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
    .onDisappear {
      model.cancelFolderScan()
    }
  }

  private func copyPath(of item: FileItem) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(item.pathForClipboard, forType: .string)
  }
}
