import SwiftUI

struct KeyboardShortcutListView: View {
  let entries: [KeyboardShortcutEntry]
  @Environment(\.dismiss) private var dismiss
  @State private var searchText = ""

  var body: some View {
    VStack(spacing: 12) {
      HStack {
        Text("キーボードショートカット一覧")
          .font(.title2.bold())
        Spacer()
        Button("閉じる") { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
      TextField("機能名またはショートカットで検索", text: $searchText)
        .textFieldStyle(.roundedBorder)
        .accessibilityIdentifier("keyboard-shortcut-search")
      List {
        ForEach(KeyboardShortcutCategory.allCases) { category in
          let categoryEntries = filteredEntries.filter { $0.category == category }
          if !categoryEntries.isEmpty {
            Section(category.title) {
              ForEach(categoryEntries) { entry in
                HStack {
                  Text(entry.title)
                  Spacer()
                  Text(entry.shortcutDisplayText)
                    .foregroundStyle(.secondary)
                    .monospaced()
                }
              }
            }
          }
        }
      }
    }
    .padding()
    .frame(width: 640, height: 560)
  }

  private var filteredEntries: [KeyboardShortcutEntry] {
    KeyboardShortcutCatalog.filtered(entries, query: searchText)
  }
}
