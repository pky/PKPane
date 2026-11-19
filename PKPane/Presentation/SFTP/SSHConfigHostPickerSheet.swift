import SwiftUI

struct SSHConfigHostPickerSheet: View {
  @Environment(\.themePalette) private var themePalette
  @Environment(\.dismiss) private var dismiss
  @Bindable var model: SSHConfigHostPickerModel
  let onConfirm: (SSHConfigImportResult, URL) -> Void
  @FocusState private var searchIsFocused: Bool

  var body: some View {
    VStack(spacing: 12) {
      TextField("ホスト名で検索", text: $model.query)
        .textFieldStyle(.roundedBorder)
        .focused($searchIsFocused)

      ScrollViewReader { proxy in
        List(selection: $model.selectedAlias) {
          ForEach(model.results) { candidate in
            SSHConfigHostCandidateRow(
              candidate: candidate,
              summary: candidateSummary(candidate)
            ) {
              confirm(alias: candidate.alias)
            }
            .tag(candidate.alias)
          }
        }
        .onChange(of: model.selectedAlias) { _, alias in
          guard let alias else { return }
          proxy.scrollTo(alias, anchor: .center)
        }
      }
      .frame(minHeight: 240)

      if !model.warnings.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(Array(model.warnings.enumerated()), id: \.offset) { _, warning in
            Text(warning.displayText)
              .font(.caption)
              .foregroundStyle(themePalette.caution)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      HStack {
        Spacer()
        Button("キャンセル") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("読み込む") { confirm() }
          .keyboardShortcut(.defaultAction)
          .disabled(model.selectedAlias == nil)
      }
    }
    .padding()
    .frame(width: 440)
    .frame(minHeight: 340)
    .onAppear { searchIsFocused = true }
    .onKeyPress(.upArrow) {
      model.moveSelection(by: -1)
      return .handled
    }
    .onKeyPress(.downArrow) {
      model.moveSelection(by: 1)
      return .handled
    }
    .onKeyPress(.escape) {
      dismiss()
      return .handled
    }
    .onKeyPress("\r") {
      confirm()
      return .handled
    }
  }

  private func candidateSummary(_ candidate: SSHConfigHostCandidate) -> String {
    if candidate.username.isEmpty {
      return candidate.hostName
    }
    return "\(candidate.username)@\(candidate.hostName)"
  }

  private func confirm() {
    guard let result = model.confirm() else { return }
    finishConfirmation(result)
  }

  private func confirm(alias: String) {
    guard let result = model.confirm(alias: alias) else { return }
    finishConfirmation(result)
  }

  private func finishConfirmation(_ result: SSHConfigImportResult) {
    onConfirm(result, model.folderURL)
    dismiss()
  }
}

private struct SSHConfigHostCandidateRow: View {
  @Environment(\.themePalette) private var themePalette
  let candidate: SSHConfigHostCandidate
  let summary: String
  let onConfirm: () -> Void
  @State private var isHovered = false

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(candidate.alias)
      Text(summary)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 3)
    .padding(.horizontal, 4)
    .background(
      isHovered ? themePalette.accentFill(.hover) : Color.clear,
      in: RoundedRectangle(cornerRadius: 4)
    )
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
    .onTapGesture(count: 2) { onConfirm() }
  }
}

extension SSHConfigWarning {
  var displayText: String {
    switch self {
    case .matchBlockIgnored:
      return String(localized: "Matchブロックは無視しました")
    case .includeOutsideAccessibleFolder(let path):
      return String.localizedStringWithFormat(
        String(localized: "アクセス可能なフォルダ外のIncludeを無視しました: %@"),
        maskedPath(path))
    case .includeUnreadable(let path):
      return String.localizedStringWithFormat(
        String(localized: "Includeを読み込めませんでした: %@"), maskedPath(path))
    case .unsupportedProxyCommand:
      return String(localized: "このProxyCommand形式には対応していません。ProxyJumpへの書き換えを検討してください")
    case .jumpChainLoop(let alias):
      return String.localizedStringWithFormat(
        String(localized: "踏み台の循環参照を無視しました: %@"), alias)
    case .jumpChainTooDeep(let alias):
      return String.localizedStringWithFormat(
        String(localized: "踏み台の段数上限を超えたため無視しました: %@"), alias)
    case .undefinedJumpAlias(let alias):
      return String.localizedStringWithFormat(
        String(localized: "定義されていない踏み台をそのまま使用します: %@"), alias)
    case .unsupportedKeyType(let path):
      return String.localizedStringWithFormat(
        String(localized: "対応していない秘密鍵を無視しました: %@"), maskedPath(path))
    case .identityFileOutsideAccessibleFolder(let path):
      return String.localizedStringWithFormat(
        String(localized: "アクセス可能なフォルダ外のIdentityFileを無視しました: %@"),
        maskedPath(path))
    }
  }

  private func maskedPath(_ path: String) -> String {
    SecretMasker.maskHomeDirectory(path, homePath: UserHomeDirectory.current.path)
  }
}
