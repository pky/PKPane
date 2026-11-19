import AppKit
@preconcurrency import QuickLookUI

final class QuickLookController: NSObject, QLPreviewPanelDataSource {
  private var urls: [URL] = []

  @MainActor
  func show(urls: [URL]) {
    guard !urls.isEmpty else { return }
    self.urls = urls
    let panel = QLPreviewPanel.shared()
    panel?.dataSource = self
    panel?.makeKeyAndOrderFront(nil)
  }

  func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

  func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
    urls[index] as NSURL
  }
}
