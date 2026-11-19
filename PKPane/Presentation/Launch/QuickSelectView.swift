import SwiftUI

struct QuickSelectView: View {
  @Environment(\.themePalette) private var themePalette
  @Binding var pattern: String
  @Binding var isCaseSensitive: Bool
  @Binding var interpretsAsRegex: Bool
  @Binding var mode: QuickSelectMode
  let apply: () -> Void
  let cancel: () -> Void

  @FocusState private var isPatternFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("パターンで選択")
        .font(.headline)

      TextField("パターン（* と ? が使用可能）", text: $pattern)
        .focused($isPatternFocused)

      Toggle("正規表現として解釈", isOn: $interpretsAsRegex)

      if interpretsAsRegex, !compiledPattern.isValid {
        Text("正規表現が無効です")
          .font(.caption)
          .foregroundStyle(themePalette.error)
      }

      Toggle("大文字小文字を区別する", isOn: $isCaseSensitive)

      VStack(alignment: .leading, spacing: 8) {
        Text("選択方法")
          .font(.subheadline)
          .foregroundStyle(.secondary)
        Picker("選択方法", selection: $mode) {
          ForEach(QuickSelectMode.allCases) { mode in
            Text(mode.displayName).tag(mode)
          }
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()
      }

      HStack {
        Spacer()
        Button("キャンセル", role: .cancel, action: cancel)
          .keyboardShortcut(.cancelAction)
        Button("選択", action: apply)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 360)
    .onAppear {
      isPatternFocused = true
    }
  }

  private var compiledPattern: QuickSelectPattern {
    QuickSelectPattern(
      pattern,
      isCaseSensitive: isCaseSensitive,
      interpretsAsRegex: interpretsAsRegex)
  }
}
