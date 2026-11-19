import Observation
import SwiftUI

@Observable
@MainActor
final class FolderComparisonPresentationState {
  private(set) var model: FolderComparisonModel?

  @discardableResult
  func handle(
    _ action: FileBrowserCommand.Action,
    workspace: FileWorkspaceModel
  ) -> Bool {
    guard model?.isSyncExecuting != true else { return false }
    let opensSyncPreview: Bool
    switch action {
    case .compareFolders:
      opensSyncPreview = false
    case .executeFolderSync:
      opensSyncPreview = true
    default:
      return false
    }
    guard let model = workspace.makeFolderComparisonModel() else { return false }
    self.model?.cancelComparison()
    self.model = model
    if opensSyncPreview {
      model.requestSyncPreviewAfterComparison()
    }
    model.startComparison()
    return true
  }

  func dismiss() {
    guard model?.isSyncExecuting != true else { return }
    model?.cancelComparison()
    model = nil
  }
}

struct FolderComparisonView: View {
  @Environment(\.themePalette) private var themePalette
  @Bindable var model: FolderComparisonModel
  @State private var selectedEntryID: FolderComparisonEntry.ID?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      filterBar
      resultTable
      statusBar
      actionBar
    }
    .padding(16)
    .frame(minWidth: 900, minHeight: 560)
    .modifier(transferConflictPresentation)
    .sheet(
      isPresented: Binding(
        get: { model.isPresentingSyncPreview },
        set: { if !$0 { model.dismissSyncPreview() } })
    ) {
      FolderSyncPreviewView(model: model)
    }
    .sheet(
      isPresented: Binding(
        get: { model.syncExecutionSummary != nil },
        set: { if !$0 { model.dismissSyncExecutionSummary() } })
    ) {
      if let summary = model.syncExecutionSummary {
        FolderSyncExecutionSummaryView(summary: summary)
      }
    }
    .interactiveDismissDisabled(model.isSyncExecuting)
  }

  private var transferConflictPresentation: TransferConflictPresentation {
    TransferConflictPresentation(
      conflict: model.pendingTransferConflict,
      resolutionNotice: Binding(
        get: { model.transferResolutionNotice },
        set: { model.transferResolutionNotice = $0 }),
      resolve: { resolution, applyToRemaining in
        model.resolvePendingTransferConflict(resolution, applyToRemaining: applyToRemaining)
      })
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("フォルダを比較")
        .font(.title2)
        .fontWeight(.semibold)
      Text("種類・サイズ・更新日時で比較します（日時の許容差は2秒）。内容は読み取りません。情報が未取得の項目は内容の一致を判断できません。")
        .font(.caption)
        .foregroundStyle(.secondary)
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text("左")
          .fontWeight(.medium)
        Text(pathDescription(model.leftRoot))
          .lineLimit(1)
          .truncationMode(.middle)
        Image(systemName: "arrow.left.and.right")
          .foregroundStyle(.secondary)
        Text("右")
          .fontWeight(.medium)
        Text(pathDescription(model.rightRoot))
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  private var filterBar: some View {
    Picker("表示", selection: $model.filter) {
      ForEach(FolderComparisonFilter.allCases) { filter in
        Text(filter.displayName).tag(filter)
      }
    }
    .pickerStyle(.segmented)
    .frame(maxWidth: 520)
    .onChange(of: model.filter) { _, _ in selectedEntryID = nil }
  }

  private var resultTable: some View {
    Table(model.displayedEntries, selection: $selectedEntryID) {
      TableColumn("相対パス") { entry in
        Text(entry.relativePath)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      .width(min: 220, ideal: 320)
      TableColumn("状態") { entry in
        Text(entry.comparisonDescription)
      }
      .width(min: 130, ideal: 160)
      TableColumn("左サイズ") { entry in
        Text(entry.leftItem?.displaySize ?? "—")
      }
      .width(min: 80, ideal: 100)
      TableColumn("左更新日時") { entry in
        Text(entry.leftItem?.displayModifiedAt ?? "—")
      }
      .width(min: 120, ideal: 150)
      TableColumn("右サイズ") { entry in
        Text(entry.rightItem?.displaySize ?? "—")
      }
      .width(min: 80, ideal: 100)
      TableColumn("右更新日時") { entry in
        Text(entry.rightItem?.displayModifiedAt ?? "—")
      }
      .width(min: 120, ideal: 150)
    }
    .overlay {
      if model.isComparing && model.snapshot == nil {
        ProgressView("フォルダを比較中…")
          .padding(16)
          .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
      } else if model.displayedEntries.isEmpty {
        ContentUnavailableView(
          "該当する項目はありません",
          systemImage: "checkmark.circle")
      }
    }
  }

  private var statusBar: some View {
    HStack(spacing: 12) {
      if model.isComparing {
        ProgressView()
          .controlSize(.small)
        Text("\(model.progress.enumeratedItemCount)項目を列挙済み")
      } else if let snapshot = model.snapshot {
        Text("\(snapshot.entries.count)項目の比較結果")
      }
      if model.incompleteMetadataCount > 0 {
        Label("比較情報不足 \(model.incompleteMetadataCount)件", systemImage: "questionmark.circle")
          .foregroundStyle(themePalette.warning)
      }
      if model.progress.skippedSymbolicLinkCount > 0 {
        Label(
          "シンボリックリンク \(model.progress.skippedSymbolicLinkCount)件を除外",
          systemImage: "link.badge.plus")
      }
      if model.progress.partialErrorCount > 0 {
        Label(
          "読み取り失敗 \(model.progress.partialErrorCount)件",
          systemImage: "exclamationmark.triangle"
        )
        .foregroundStyle(themePalette.warning)
      }
      if model.didReachItemLimit {
        Label(
          "50,000項目で打ち切りました",
          systemImage: "exclamationmark.triangle"
        )
        .foregroundStyle(themePalette.warning)
      }
      Spacer()
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  private var actionBar: some View {
    HStack {
      if model.isComparing {
        Button("比較をキャンセル") {
          model.cancelComparison()
        }
      }
      Button("再比較") {
        selectedEntryID = nil
        model.startComparison()
      }
      .disabled(model.isComparing)
      Spacer()
      Button("左へコピー") {
        guard let selectedEntry else { return }
        _ = model.copy(selectedEntry, to: .left)
      }
      .disabled(selectedEntry.map { !model.canCopy($0, to: .left) } ?? true)
      Button("右へコピー") {
        guard let selectedEntry else { return }
        _ = model.copy(selectedEntry, to: .right)
      }
      .disabled(selectedEntry.map { !model.canCopy($0, to: .right) } ?? true)
      Button("同期…") {
        _ = model.presentSyncPreview()
      }
      .disabled(model.isComparing || model.snapshot == nil || model.isSyncExecuting)
      if model.isSyncExecuting {
        ProgressView()
          .controlSize(.small)
        Text("同期を実行中…")
          .font(.caption)
          .foregroundStyle(.secondary)
        Button("同期をキャンセル", role: .destructive) {
          model.cancelSyncExecution()
        }
      }
      Button("閉じる") {
        dismiss()
      }
      .keyboardShortcut(.cancelAction)
      .disabled(model.isSyncExecuting)
    }
  }

  private var selectedEntry: FolderComparisonEntry? {
    guard let selectedEntryID else { return nil }
    return model.displayedEntries.first { $0.id == selectedEntryID }
  }

  private func pathDescription(_ location: FileLocation) -> String {
    location.localURL?.path ?? location.remotePath ?? "—"
  }
}

private struct FolderSyncPreviewView: View {
  @Environment(\.themePalette) private var themePalette
  @Bindable var model: FolderComparisonModel

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("同期内容を確認")
        .font(.title2)
        .fontWeight(.semibold)
      Text("比較結果を次の片方向へ反映します。実行前に方向と操作件数を確認してください。")
        .foregroundStyle(.secondary)

      Picker(
        "同期方向",
        selection: Binding(
          get: { model.syncDirection },
          set: { model.setSyncDirection($0) })
      ) {
        ForEach(FolderSyncDirection.allCases) { direction in
          Text(direction.displayName).tag(direction)
        }
      }
      .pickerStyle(.segmented)

      Toggle(
        "送り先の方が新しい項目も上書き",
        isOn: Binding(
          get: { model.overwritesNewerDestinationItems },
          set: { model.setOverwritesNewerDestinationItems($0) })
      )
      if model.syncPlan?.summary.newerDestinationOverwriteCount ?? 0 > 0 {
        Text("送り先の方が新しい項目は、明示的にONにするまで上書きしません。旧内容はゴミ箱に残りません。")
          .font(.caption)
          .foregroundStyle(themePalette.warning)
      }

      Toggle(
        "送り先にのみ存在する項目を削除",
        isOn: Binding(
          get: { model.deletesExtraneousItems },
          set: { model.setDeletesExtraneousItems($0) })
      )
      .disabled(!model.canDeleteExtraneousItems)

      if model.destinationDeletionMode == .trash {
        Text("削除対象はゴミ箱へ移動します。この設定はプレビューを開くたびにOFFへ戻ります。")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else if model.destinationDeletionMode == .permanent {
        Label(
          "この接続にはゴミ箱がありません。削除対象は完全に削除され、元に戻せません。実行時にもう一度確認します。",
          systemImage: "exclamationmark.triangle.fill"
        )
        .font(.caption)
        .foregroundStyle(themePalette.warning)
      } else {
        Label(
          "送り先が削除に対応していないため、削除つき同期は利用できません。",
          systemImage: "exclamationmark.shield"
        )
        .font(.caption)
        .foregroundStyle(themePalette.warning)
      }

      if let summary = model.syncPlan?.summary {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
          summaryRow("コピー", value: "\(summary.copyCount)件")
          summaryRow("上書き", value: "\(summary.overwriteCount)件")
          summaryRow(
            "送り先の方が新しい項目",
            value: "\(summary.newerDestinationOverwriteCount)件")
          summaryRow("削除", value: "\(summary.deleteCount)件")
          summaryRow("スキップ", value: "\(summary.skipCount)件")
          summaryRow(
            "合計サイズ",
            value: ByteCountFormatter.string(
              fromByteCount: summary.totalTransferBytes,
              countStyle: .file))
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
      }

      Spacer()
      HStack {
        Spacer()
        Button("キャンセル", role: .cancel) {
          model.dismissSyncPreview()
        }
        Button(
          model.deletesExtraneousItems ? "コピー・削除を実行" : "同期を実行",
          role: model.deletesExtraneousItems ? .destructive : nil
        ) {
          _ = model.executeSyncPlan()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(model.syncPlan?.hasExecutableOperations != true)
      }
    }
    .padding(20)
    .frame(width: 520)
    .frame(minHeight: 420)
    .alert(
      "完全削除を実行しますか？",
      isPresented: Binding(
        get: { model.isPresentingPermanentDeleteConfirmation },
        set: { if !$0 { model.cancelPermanentDeleteSync() } })
    ) {
      Button("完全削除して同期", role: .destructive) {
        model.confirmPermanentDeleteSync()
      }
      Button("キャンセル", role: .cancel) {
        model.cancelPermanentDeleteSync()
      }
    } message: {
      Text("送り先にのみ存在する項目を完全に削除します。この操作は元に戻せません。")
    }
  }

  private func summaryRow(_ label: LocalizedStringKey, value: String) -> some View {
    GridRow {
      Text(label)
        .foregroundStyle(.secondary)
      Text(value)
        .fontWeight(.medium)
    }
  }
}

private struct FolderSyncExecutionSummaryView: View {
  @Environment(\.themePalette) private var themePalette
  let summary: FolderSyncExecutionSummary
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("同期結果")
        .font(.title2)
        .fontWeight(.semibold)
      HStack(spacing: 16) {
        Label("成功 \(summary.successCount)件", systemImage: "checkmark.circle")
        Label("スキップ \(summary.skipCount)件", systemImage: "forward.circle")
        Label("失敗 \(summary.failureCount)件", systemImage: "xmark.octagon")
      }
      List(summary.results) { result in
        VStack(alignment: .leading, spacing: 3) {
          HStack {
            Text(result.relativePath)
              .lineLimit(1)
              .truncationMode(.middle)
            Spacer()
            Text(result.action.displayName)
              .foregroundStyle(.secondary)
          }
          Text(result.outcome.displayName)
            .font(.caption)
            .foregroundStyle(result.outcome.isFailure ? themePalette.error : Color.secondary)
        }
      }
      HStack {
        Spacer()
        Button("閉じる") { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(minWidth: 680, minHeight: 460)
  }
}
