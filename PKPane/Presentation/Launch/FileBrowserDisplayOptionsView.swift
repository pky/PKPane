import SwiftUI

struct FileBrowserDisplayOptionsView: View {
  @Environment(\.dismiss) private var dismiss
  @Binding var browserViewMode: FileBrowserViewMode
  @Binding var displayOptions: FileBrowserDisplayOptions
  @Binding var sortOrder: FileItemSortOrder
  @Binding var sortAscending: Bool
  @Binding var showsHiddenFiles: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("表示オプション")
        .font(.title2)
        .fontWeight(.semibold)
      Form {
        Section("表示形式") {
          Picker("表示形式", selection: $browserViewMode) {
            ForEach(FileBrowserViewMode.selectableCases) { mode in
              Text(mode.displayName).tag(mode)
            }
          }
        }
        Section("並べ替え") {
          Picker("並べ替え", selection: $sortOrder) {
            ForEach(FileItemSortOrder.allCases) { order in
              Text(order.displayName).tag(order)
            }
          }
          Toggle("昇順で並べ替え", isOn: $sortAscending)
          Toggle("隠しファイルを表示", isOn: $showsHiddenFiles)
        }
        Section("アイコンサイズ") {
          VStack(alignment: .leading, spacing: 4) {
            Slider(
              value: iconSizeSliderValue,
              in: 0...Double(IconGridSize.allCases.count - 1),
              step: 1
            ) {
              Text("アイコンサイズ")
            }
            .accessibilityIdentifier("display-option-icon-size-slider")
            Text(displayOptions.iconSize.displayName)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Section("リスト表示の列") {
          Toggle("種類", isOn: $displayOptions.showsKindColumn)
            .accessibilityIdentifier("display-option-kind-column")
          Toggle("サイズ", isOn: $displayOptions.showsSizeColumn)
            .accessibilityIdentifier("display-option-size-column")
          Toggle("更新日時", isOn: $displayOptions.showsModifiedAtColumn)
            .accessibilityIdentifier("display-option-modified-at-column")
          Toggle("場所", isOn: $displayOptions.showsLocationColumn)
            .accessibilityIdentifier("display-option-location-column")
          Toggle("タグ", isOn: $displayOptions.showsTagsColumn)
            .accessibilityIdentifier("display-option-tags-column")
        }
      }
      HStack {
        Spacer()
        Button("閉じる") { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding()
    .frame(minWidth: 420)
  }

  /// IconGridSize(段階の列挙)とSliderが要求する数値軸(0...段階数-1)を相互変換する。
  /// setはstepで丸められた整数へ量子化してから該当段階を反映する(4段階スナップ)。
  private var iconSizeSliderValue: Binding<Double> {
    Binding(
      get: {
        Double(IconGridSize.allCases.firstIndex(of: displayOptions.iconSize) ?? 1)
      },
      set: { newValue in
        let index = Int(newValue.rounded())
        guard IconGridSize.allCases.indices.contains(index) else { return }
        displayOptions.iconSize = IconGridSize.allCases[index]
      }
    )
  }
}
