import AppKit
import Foundation
import SwiftUI
import Testing

@testable import PKPane

@MainActor
struct BrowserPaneLayoutTests {
  @Test(
    "ブラウザの幅を縮小して戻しても2ペインのモデルと表示幅を保つ",
    arguments: [DetailsDisplayMode.none, .pane])
  func preservesBothPanesAcrossOffscreenResize(detailsMode: DetailsDisplayMode) async throws {
    // 復元待ちProviderを使い、通信や実ユーザーのフォルダへのアクセスを発生させない。
    let provider = WorkspaceRemotePlaceholderProvider(
      providerKind: .sftp, connectionID: "pane-layout-test")
    let browser = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: "/", providerID: provider.id),
      transferQueue: .isolatedForTesting())
    let workspace = FileWorkspaceModel(initialBrowser: browser)
    let originalTabIDs = workspace.tabs.map(\.id)
    let hostingView = NSHostingView(
      rootView: ProviderBrowserView(
        title: "ペイン配置の検証",
        workspace: workspace,
        command: .constant(nil),
        browserViewMode: .constant(.list),
        showsSecondaryPane: .constant(true),
        detailsDisplayMode: .constant(detailsMode),
        detailsInspectorWidth: .constant(260),
        onLocationChanged: { _ in }))
    // 表示・前面化・入力イベント送信をせず、実際のAppKit階層だけを構築する。
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 600),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = hostingView
    defer {
      window.contentView = nil
      window.close()
      for tab in workspace.tabs {
        tab.browser.invalidate()
      }
    }

    for width: CGFloat in [1_200, 800, 1_200] {
      window.setContentSize(NSSize(width: width, height: 600))
      // SwiftUIの遅延更新とAppKitのレイアウトを既存の描画テストと同様に進める。
      for _ in 0..<4 {
        await Task.yield()
        hostingView.layoutSubtreeIfNeeded()
      }
      let splitView = try #require(
        filePaneSplitView(in: hostingView),
        "詳細表示=\(detailsMode.rawValue)、幅=\(width): 2つのファイル一覧を含む分割がない")
      let paneWidths = splitView.arrangedSubviews.map { $0.frame.width }
      let collapsed = splitView.arrangedSubviews.map { splitView.isSubviewCollapsed($0) }
      // 失敗時にモデルの1ペイン化と、モデルを維持した幅消失を区別できるようにする。
      let diagnosis =
        "詳細表示=\(detailsMode.rawValue)、要求幅=\(width)、実幅=\(hostingView.frame.width)、"
        + "ペイン幅=\(paneWidths)、折り畳み=\(collapsed)、"
        + "2ペインモデル=\(workspace.showsSecondaryPane)"
      print("PKPaneペイン配置診断: \(diagnosis)")

      #expect(!window.isVisible)
      #expect(workspace.showsSecondaryPane, Comment(rawValue: diagnosis))
      #expect(workspace.tabs.map(\.id) == originalTabIDs, Comment(rawValue: diagnosis))
      #expect(paneWidths.allSatisfy { $0 > 0 }, Comment(rawValue: diagnosis))
      #expect(collapsed.allSatisfy { !$0 }, Comment(rawValue: diagnosis))
    }
  }

  private func filePaneSplitView(in view: NSView) -> NSSplitView? {
    if let splitView = view as? NSSplitView,
      splitView.arrangedSubviews.count == 2,
      splitView.arrangedSubviews.allSatisfy({ containsFileTable(in: $0) })
    {
      return splitView
    }
    return view.subviews.lazy.compactMap { filePaneSplitView(in: $0) }.first
  }

  private func containsFileTable(in view: NSView) -> Bool {
    view is NSTableView || view.subviews.contains { containsFileTable(in: $0) }
  }
}
