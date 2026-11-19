import SwiftUI

struct TransferConflictPresentation: ViewModifier {
  let conflict: FileBrowserSession.TransferConflict?
  @Binding var resolutionNotice: String?
  let resolve: @MainActor (TransferConflictResolution, Bool) -> Void

  func body(content: Content) -> some View {
    content
      .sheet(
        isPresented: Binding(
          get: { conflict != nil },
          set: { if !$0 { resolve(.cancel, false) } })
      ) {
        if let conflict {
          TransferConflictView(conflict: conflict, resolve: resolve)
        }
      }
      .alert(
        "転送の確認",
        isPresented: Binding(
          get: { resolutionNotice != nil },
          set: { if !$0 { resolutionNotice = nil } })
      ) {
        Button("OK") { resolutionNotice = nil }
      } message: {
        Text(resolutionNotice ?? "")
      }
  }
}

struct TransferConflictView: View {
  @Environment(\.themePalette) private var themePalette
  let conflict: FileBrowserSession.TransferConflict
  let resolve: @MainActor (TransferConflictResolution, Bool) -> Void
  @State private var applyToRemaining = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("同名項目があります")
        .font(.title2.bold())
      Text(
        "\(conflict.selectedCount)項目中\(conflict.totalCount)項目が同名です。残り\(conflict.remainingCount)項目の方法を選択してください。"
      )
      .foregroundStyle(.secondary)
      Text(conflict.destinationName)
        .font(.headline)
        .textSelection(.enabled)
      Text("置き換えると既存の内容は失われ、元に戻せません。")
      let warning = conflict.replacementWarning(applyToRemaining: applyToRemaining)
      if !warning.isEmpty {
        Text(warning).foregroundStyle(themePalette.warning)
      }
      if conflict.remainingCount > 1 {
        Toggle("残りの同名項目すべてに同じ方法を適用", isOn: $applyToRemaining)
        if applyToRemaining {
          Text(conflict.remainingNames.joined(separator: "、"))
            .font(.caption)
            .foregroundStyle(.secondary)
          if conflict.remainingCount > conflict.remainingNames.count {
            Text("ほか \(conflict.remainingCount - conflict.remainingNames.count)件")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
      if !conflict.canKeepBoth {
        Text("この接続では既存項目を安全に保持した別名転送を利用できません。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if conflict.usesServerAssignedNames {
        Text("別名はFTPサーバーが決めるため、元の名前や拡張子と異なる場合があります。実際の名前は転送履歴に表示します。")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text("転送中の項目が見える場合があります。フォルダ内の名前を維持できないサーバーでは転送を中止します。")
          .font(.caption)
          .foregroundStyle(.secondary)
        Text("別名転送は自動再試行しません。失敗時は結果を確認してから手動で再試行してください。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      HStack {
        Button("キャンセル", role: .cancel) { resolve(.cancel, false) }
          .keyboardShortcut(.cancelAction)
        Spacer()
        Button("スキップ") { resolve(.skip, applyToRemaining) }
        Button("別名で両方保持") { resolve(.keepBoth, applyToRemaining) }
          .disabled(!conflict.canKeepBoth)
        Button("置き換える", role: .destructive) { resolve(.replace, applyToRemaining) }
      }
    }
    .padding(20)
    .frame(minWidth: 560, maxWidth: 720)
    .onChange(of: conflict.remainingCount) { _, _ in applyToRemaining = false }
  }
}
