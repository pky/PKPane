import SwiftUI

/// 開始時のProviderと対象項目を固定し、背後の選択変更から編集対象を切り離す。
struct FinderTagEditorRequest: Identifiable {
  let id = UUID()
  let browser: FileBrowserSession
  let items: [FileItem]
}

struct FinderTagEditorSheet: View {
  @Environment(\.themePalette) private var themePalette
  @Environment(\.dismiss) private var dismiss
  let request: FinderTagEditorRequest
  @State private var model = FileInfoContentModel()
  @State private var isLoading = true
  @State private var loadingError: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("タグ")
        .font(.title2)
        .fontWeight(.semibold)
      if request.items.count == 1 {
        Text(request.items[0].name)
          .lineLimit(2)
      } else {
        Text("\(request.items.count)項目")
      }
      if isLoading {
        ProgressView()
      }
      FinderTagTokenField(
        tagNames: Binding(
          get: { model.finderTagNames },
          set: { model.updateFinderTagNames($0) }),
        candidates: model.finderTagCandidates,
        isEnabled: !isLoading && loadingError == nil && !model.isApplyingFinderTags
      )
      .frame(height: 26)
      if model.isApplyingFinderTags {
        ProgressView()
          .controlSize(.small)
      }
      if let message = loadingError ?? model.finderTagErrorMessage {
        Text(message)
          .font(.caption)
          .foregroundStyle(themePalette.error)
      }
      HStack {
        Spacer()
        Button("閉じる") { dismiss() }
          .disabled(model.isApplyingFinderTags)
          .keyboardShortcut(.cancelAction)
      }
    }
    .padding()
    .frame(width: 420)
    .task(id: request.id) {
      isLoading = true
      loadingError = nil
      do {
        let items = try await request.browser.finderTagItemsForEditing(request.items)
        guard !Task.isCancelled else { return }
        model.setSelection(
          items,
          finderTagUpdater: { items, mutation in
            await request.browser.updateFinderTags(mutation, for: items)
          }, loadThumbnail: false)
      } catch {
        loadingError = PKPaneErrorClassifier.classify(error).displayMessage
      }
      isLoading = false
    }
  }
}
