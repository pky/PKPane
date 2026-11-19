import Foundation
import Testing

@testable import PKPane

struct FileBrowserCapabilityTests {
  /// 操作パリティの恒久防護。ユーザー承認なしに削除・スキップ化禁止。
  @Test("能力表は全機能と3表示モードの期待値に完全一致する")
  func capabilityTableExactlyMatchesAllModes() {
    let allModes = Set(FileBrowserViewMode.allCases)
    let expected: [FileBrowserCapability: Set<FileBrowserViewMode>] = [
      .multipleSelection: allModes,
      .contextMenu: allModes,
      .dragAndDrop: allModes,
      .keyboardNavigation: allModes,
      .detailsTracking: allModes,
      .itemOperations: allModes,
      .search: allModes,
      .syncBrowsing: allModes,
      .quickSelect: allModes,
      .openInTerminal: allModes,
      .finderTagDisplay: allModes,
      .gitStatusDisplay: allModes,
      .cloudDownloadStatusDisplay: allModes,
      .tableColumnHeaders: [.list],
      .metadataColumns: [.list],
      .listTreeExpansion: [.list],
      .listColumnWidthDistribution: [.list],
      .columnNavigation: [.column],
      .columnBrowsing: [.column],
      .paneBackgroundDrop: [.list, .icon],
      .flatItemProjection: [.list, .icon],
      .swiftUIItemGestureMonitor: [.icon],
      .alternatingRowBackgrounds: [.list, .column],
      .horizontalTableScroller: [.list],
      .columnScrollRouting: [.column],
      .columnNameChevron: [.column],
    ]

    #expect(Set(expected.keys) == Set(FileBrowserCapability.allCases))
    for capability in FileBrowserCapability.allCases {
      let actual = Set(
        FileBrowserViewMode.allCases.filter {
          FileBrowserCapability.supports(capability, for: $0)
        })
      #expect(actual == expected[capability])
    }
  }

  /// 選択同期の表示モード別恒久防護。ユーザー承認なしに削除・スキップ化禁止。
  @MainActor
  @Test("複数選択は3表示モードすべてでワークスペース選択へ届く")
  func multipleSelectionSynchronizesForEveryViewMode() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appending(path: "pkpane-capability-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    try Data().write(to: rootURL.appending(path: "first.txt"))
    try Data().write(to: rootURL.appending(path: "second.txt"))
    defer { try? FileManager.default.removeItem(at: rootURL) }

    for mode in FileBrowserViewMode.allCases {
      let provider = LocalFileProvider()
      let location = FileLocation(directoryURL: rootURL, providerID: provider.id)
      let browser = FileBrowserSession(
        provider: provider, initialLocation: location, transferQueue: .isolatedForTesting())
      let workspace = FileWorkspaceModel(initialBrowser: browser)
      browser.load()
      await waitForLoading(browser)
      let selectedURLs = Set(browser.items.map(\.url))

      if FileBrowserCapability.supports(.columnBrowsing, for: mode) {
        browser.beginColumnBrowsing()
      }
      workspace.selectItems(selectedURLs, in: .primary)
      if FileBrowserCapability.supports(.columnBrowsing, for: mode) {
        browser.selectColumnItems(selectedURLs, inColumnAt: location)
        #expect(browser.columnState.columns.first?.selectedItemURLs == selectedURLs)
      }

      #expect(FileBrowserCapability.supports(.multipleSelection, for: mode))
      #expect(workspace.activeTab.selectedItemURLs == selectedURLs)
    }
  }

  @MainActor
  private func waitForLoading(_ browser: FileBrowserSession) async {
    await waitUntil("ブラウザの読み込みが期限内に完了しなかった") {
      !(browser.isLoading || browser.isRefreshing)
    }
  }
}
