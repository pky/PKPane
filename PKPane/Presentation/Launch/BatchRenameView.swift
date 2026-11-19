import SwiftUI

@MainActor
struct BatchRenameView: View {
  @Environment(\.themePalette) private var themePalette
  let items: [FileItem]
  let existingItems: [FileItem]
  let apply: @MainActor ([(item: FileItem, newName: String)]) async -> Void
  let cancel: @MainActor () -> Void

  @State private var replacementMode = BatchRenameReplacementMode.none
  @State private var searchText = ""
  @State private var replacementText = ""
  @State private var isCaseSensitive = true
  @State private var prefix = ""
  @State private var suffix = ""
  @State private var includesSequence = false
  @State private var sequenceStart = 1
  @State private var sequencePadding = 1
  @State private var isApplying = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("一括リネーム")
        .font(.title2.bold())

      ruleForm

      Text("プレビュー")
        .font(.headline)
      previewList

      if !validation.issues.isEmpty {
        validationIssues
      }

      HStack {
        Text("\(items.count)項目中\(renames.count)項目を変更")
          .foregroundStyle(.secondary)
        Spacer()
        Button("キャンセル", role: .cancel, action: cancel)
          .keyboardShortcut(.cancelAction)
          .disabled(isApplying)
        Button("変更") {
          isApplying = true
          Task {
            await apply(renames)
            isApplying = false
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!validation.isSafe || renames.isEmpty || isApplying)
      }
    }
    .padding(20)
    .frame(minWidth: 680, minHeight: 560)
  }

  @ViewBuilder
  private var ruleForm: some View {
    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
      GridRow {
        Text("置換")
        Picker("置換", selection: $replacementMode) {
          ForEach(BatchRenameReplacementMode.allCases, id: \.self) { mode in
            Text(replacementModeTitle(mode)).tag(mode)
          }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
      }

      if replacementMode != .none {
        GridRow {
          Text(replacementMode == .regex ? "正規表現" : "検索文字列")
          TextField("検索文字列", text: $searchText)
        }
        GridRow {
          Text("置換文字列")
          TextField("置換文字列", text: $replacementText)
        }
        if replacementMode == .regex {
          GridRow {
            Color.clear.frame(width: 1, height: 1)
            Toggle("大文字と小文字を区別する", isOn: $isCaseSensitive)
          }
        }
      }

      GridRow {
        Text("前置")
        TextField("ファイル名の先頭へ追加", text: $prefix)
      }
      GridRow {
        Text("後置")
        TextField("拡張子の前へ追加", text: $suffix)
      }
      GridRow {
        Toggle("連番", isOn: $includesSequence)
        HStack {
          Text("開始")
          TextField("開始番号", value: $sequenceStart, format: .number)
            .frame(width: 70)
          Stepper(value: $sequencePadding, in: 0...12) {
            Text("ゼロ埋め \(sequencePadding)桁")
          }
        }
        .disabled(!includesSequence)
      }
    }
  }

  private var previewList: some View {
    List(previews) { preview in
      HStack(spacing: 10) {
        Text(preview.item.name)
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)
        Image(systemName: "arrow.right")
          .foregroundStyle(.secondary)
        Text(preview.renamedName)
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)
        if !preview.hasChanged {
          Text("変更なし")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .frame(minHeight: 220)
  }

  private var validationIssues: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(validation.issues) { issue in
        Label(issue.message, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(themePalette.error)
      }
    }
  }

  private var rule: BatchRenameRule {
    var rule = BatchRenameRule()
    rule.replacementMode = replacementMode
    rule.searchText = searchText
    rule.replacementText = replacementText
    rule.isCaseSensitive = isCaseSensitive
    rule.prefix = prefix
    rule.suffix = suffix
    rule.sequenceStart = includesSequence ? sequenceStart : nil
    rule.sequencePadding = sequencePadding
    return rule
  }

  private var previews: [BatchRenamePreview] {
    BatchRenamePreviewBuilder.make(items: items, rule: rule)
  }

  private var validation: BatchRenameValidation {
    BatchRenameValidator.validate(
      previews: previews,
      existingItems: existingItems,
      rule: rule
    )
  }

  private var renames: [(item: FileItem, newName: String)] {
    previews.filter(\.hasChanged).map { (item: $0.item, newName: $0.renamedName) }
  }

  private func replacementModeTitle(_ mode: BatchRenameReplacementMode) -> String {
    switch mode {
    case .none: String(localized: "なし")
    case .plain: String(localized: "通常置換")
    case .regex: String(localized: "正規表現置換")
    }
  }
}
