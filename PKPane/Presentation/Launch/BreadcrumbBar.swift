import SwiftUI

struct BreadcrumbBar<Item: Identifiable>: View where Item.ID: Hashable {
  let items: [Item]
  let name: (Item) -> String
  let select: (Item) -> Void

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView(.horizontal) {
        HStack(spacing: 4) {
          ForEach(items) { item in
            Button(name(item)) {
              select(item)
            }
            .buttonStyle(.link)
            .id(item.id)
            if item.id != items.last?.id {
              Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
        }
        .padding(.horizontal)
        .padding(.vertical, 7)
      }
      .onAppear { scrollToCurrentFolder(proxy) }
      .onChange(of: items.map(\.id)) { _, _ in scrollToCurrentFolder(proxy) }
    }
  }

  /// 深い階層でも現在フォルダ(末尾)が常に見えるよう、階層変更のたびに末尾へ寄せる。
  /// 先頭側はユーザーが左へスクロールすれば辿れる。
  private func scrollToCurrentFolder(_ proxy: ScrollViewProxy) {
    guard let lastID = items.last?.id else { return }
    proxy.scrollTo(lastID, anchor: .trailing)
  }
}
