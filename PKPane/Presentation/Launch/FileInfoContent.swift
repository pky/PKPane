import AppKit
import SwiftUI

/// FileInfoView(⌘Iダイアログ)と詳細ペイン(インスペクタ)が共有する表示部品。二重実装を
/// 避けるため、単一選択のヘッダ・詳細グリッド・複数選択サマリの描画はすべてここへ集約する。
/// データの読み込み・非同期処理はFileInfoContentModelが担い、この型は受け取った値を
/// そのまま描画する(状態を持たない)。
struct FileInfoContent: View {
  @Environment(\.themePalette) private var themePalette
  enum Layout {
    /// ⌘Iダイアログ: アイコンと名前・種類を横並びで表示するヘッダ。
    case dialog
    /// 詳細ペイン: ペイン幅いっぱいの大きなプレビューを縦に表示するヘッダ。
    case pane
  }

  let items: [FileItem]
  let displayedItem: FileItem?
  let headerImage: NSImage?
  let thumbnailSize: CGFloat
  let layout: Layout
  let folderScanPhase: FileInfoContentModel.FolderScanPhase
  let onStartFolderScan: (FileItem) -> Void
  let onCancelFolderScan: () -> Void
  let onCopyPath: (FileItem) -> Void
  let permissionMode: Int?
  let permissionOctalInput: String
  let canEditPermissions: Bool
  let isApplyingPermissions: Bool
  let permissionErrorMessage: String?
  let onSetPermission: (Int, Bool) -> Void
  let onChangePermissionOctalInput: (String) -> Void
  let onCommitPermissionOctalInput: () -> Void
  let finderTagNames: [String]
  let finderTagCandidates: [String]
  let canEditFinderTags: Bool
  let isApplyingFinderTags: Bool
  let finderTagErrorMessage: String?
  let onChangeFinderTagNames: ([String]) -> Void

  @FocusState private var isPermissionOctalFieldFocused: Bool

  var body: some View {
    if items.count == 1, let item = displayedItem {
      VStack(alignment: .leading, spacing: 16) {
        header(for: item)
        Divider()
        detailGrid(for: item)
        if shouldShowFinderTagSection {
          Divider()
          finderTagSection
        }
        if let permissionMode {
          Divider()
          permissionsSection(for: item, mode: permissionMode)
        }
      }
    } else if items.isEmpty {
      Text("選択項目がありません。")
    } else {
      VStack(alignment: .leading, spacing: 16) {
        multiSelectionSummary
        if shouldShowFinderTagSection {
          Divider()
          finderTagSection
        }
      }
    }
  }

  // MARK: - ヘッダ

  @ViewBuilder
  private func header(for item: FileItem) -> some View {
    switch layout {
    case .dialog:
      HStack(spacing: 12) {
        thumbnailImage(for: item)
          .frame(width: thumbnailSize, height: thumbnailSize)
        VStack(alignment: .leading, spacing: 2) {
          Text(item.name)
            .font(.headline)
            .lineLimit(2)
          Text(item.kindDisplayName)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }
    case .pane:
      VStack(alignment: .leading, spacing: 6) {
        thumbnailImage(for: item)
          .frame(maxWidth: .infinity)
          .frame(height: thumbnailSize)
        Text(item.name)
          .font(.headline)
          .fontWeight(.bold)
          .lineLimit(2)
        Text(item.kindDisplayName)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func thumbnailImage(for item: FileItem) -> some View {
    Image(nsImage: headerImage ?? FileIconProvider.shared.icon(for: item))
      .resizable()
      .aspectRatio(contentMode: .fit)
      .accessibilityIdentifier("file-info-thumbnail")
  }

  // MARK: - 詳細グリッド(単一選択共通)

  @ViewBuilder
  private func detailGrid(for item: FileItem) -> some View {
    Grid(alignment: .leading, horizontalSpacing: gridHorizontalSpacing, verticalSpacing: 10) {
      GridRow {
        Text("名前")
        Text(item.name)
      }
      GridRow {
        Text("種類")
        Text(item.kindDisplayName)
      }
      GridRow {
        Text("サイズ")
        HStack(spacing: 8) {
          Text(sizeDisplayText(for: item))
          folderScanControl(for: item)
        }
      }
      GridRow {
        Text("作成日")
        Text(item.displayCreatedAt)
      }
      GridRow {
        Text("変更日")
        Text(item.displayModifiedAt)
      }
      GridRow {
        Text("場所")
        HStack(spacing: 8) {
          Text(item.displayParentPath)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
          Button("パスをコピー") { onCopyPath(item) }
            .controlSize(.small)
            .accessibilityIdentifier("file-info-copy-path")
        }
      }
    }
  }

  private var shouldShowFinderTagSection: Bool {
    canEditFinderTags || !finderTagNames.isEmpty
  }

  private var finderTagSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("タグ")
          .font(.headline)
        if isApplyingFinderTags {
          ProgressView()
            .controlSize(.small)
        } else if !canEditFinderTags {
          Text("（読み取り専用）")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      FinderTagTokenField(
        tagNames: Binding(
          get: { finderTagNames },
          set: { names in onChangeFinderTagNames(names) }),
        candidates: finderTagCandidates,
        isEnabled:
          canEditFinderTags && !isApplyingFinderTags
      )
      .frame(height: 26)
      if let finderTagErrorMessage {
        Text(finderTagErrorMessage)
          .font(.caption)
          .foregroundStyle(themePalette.error)
      }
    }
  }

  private func permissionsSection(for item: FileItem, mode: Int) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("アクセス権")
          .font(.headline)
        if isApplyingPermissions {
          ProgressView()
            .controlSize(.small)
        } else if !canEditPermissions {
          Text("（読み取り専用）")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
        GridRow {
          Text("")
          Text("R")
          Text("W")
          Text("X")
        }
        .font(.caption)
        .foregroundStyle(.secondary)

        ForEach(PosixPermissions.rows) { row in
          GridRow {
            Text(row.label)
            ForEach(row.options) { option in
              Toggle(
                "",
                isOn: Binding(
                  get: { mode & option.bit == option.bit },
                  set: { onSetPermission(option.bit, $0) })
              )
              .labelsHidden()
              .toggleStyle(.checkbox)
              .disabled(!canEditPermissions || isApplyingPermissions)
              .accessibilityLabel("\(row.label) \(option.label)")
            }
          }
        }
      }

      HStack(spacing: 8) {
        Text("8進数")
        TextField(
          "755",
          text: Binding(
            get: { permissionOctalInput },
            set: { value in onChangePermissionOctalInput(value) })
        )
        .frame(width: 52)
        .textFieldStyle(.roundedBorder)
        .disabled(!canEditPermissions || isApplyingPermissions)
        .focused($isPermissionOctalFieldFocused)
        .onSubmit(onCommitPermissionOctalInput)
        .onChange(of: isPermissionOctalFieldFocused) { wasFocused, isFocused in
          if wasFocused, !isFocused {
            onCommitPermissionOctalInput()
          }
        }
        Text(PosixPermissions.symbolicString(for: mode))
          .monospaced()
          .textSelection(.enabled)
      }

      if let ownerName = item.ownerName {
        LabeledContent("所有者", value: ownerName)
      }
      if let groupName = item.groupName {
        LabeledContent("グループ", value: groupName)
      }
      if let permissionErrorMessage {
        Text(permissionErrorMessage)
          .font(.caption)
          .foregroundStyle(themePalette.error)
      }
    }
  }

  private var gridHorizontalSpacing: CGFloat {
    switch layout {
    case .dialog: 20
    case .pane: 12
    }
  }

  private func sizeDisplayText(for item: FileItem) -> String {
    if case .completed(let summary) = folderScanPhase {
      let sizeText = ByteCountFormatter.string(fromByteCount: summary.totalSize, countStyle: .file)
      return "\(sizeText)（\(summary.itemCount)項目）"
    }
    return item.displaySize
  }

  @ViewBuilder
  private func folderScanControl(for item: FileItem) -> some View {
    if item.isDirectory {
      if !item.supportsFolderContentsScan {
        Text("(SFTPでは計算できません)")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        switch folderScanPhase {
        case .idle:
          Button("計算") { onStartFolderScan(item) }
            .controlSize(.small)
            .accessibilityIdentifier("file-info-calculate-size")
        case .scanning:
          HStack(spacing: 6) {
            ProgressView()
              .controlSize(.small)
            Button("キャンセル") { onCancelFolderScan() }
              .controlSize(.small)
              .accessibilityIdentifier("file-info-cancel-calculate-size")
          }
        case .completed:
          EmptyView()
        case .failed:
          Text("計算に失敗しました")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  // MARK: - 複数選択

  private var multiSelectionSummary: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("\(items.count)項目")
        .font(.headline)
      Text("合計サイズ: \(items.displayTotalKnownSize)")
        .foregroundStyle(.secondary)
    }
  }
}
