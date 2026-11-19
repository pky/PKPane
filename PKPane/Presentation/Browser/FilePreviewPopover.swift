import AppKit
import SwiftUI

/// ホバープレビューの内容ビュー。サムネイル+基本メタデータ。
struct FilePreviewContentView: View {
  let item: FileItem
  @State private var thumbnail: NSImage?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let thumbnail {
        Image(nsImage: thumbnail)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(maxWidth: 280, maxHeight: 200)
          .clipShape(RoundedRectangle(cornerRadius: 6))
      } else {
        ProgressView()
          .frame(width: 280, height: 120)
      }
      Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
        GridRow {
          Text("名前").foregroundStyle(.secondary)
          Text(item.name).lineLimit(2)
        }
        GridRow {
          Text("種類").foregroundStyle(.secondary)
          Text(item.kindDisplayName)
        }
        GridRow {
          Text("サイズ").foregroundStyle(.secondary)
          Text(item.displaySize)
        }
        GridRow {
          Text("更新日時").foregroundStyle(.secondary)
          Text(item.displayModifiedAt)
        }
      }
      .font(.caption)
    }
    .padding(12)
    .task(id: item.url) {
      thumbnail = await FileThumbnailService.shared.thumbnail(
        for: item.url, modifiedAt: item.modifiedAt, size: CGSize(width: 280, height: 200))
    }
  }
}
