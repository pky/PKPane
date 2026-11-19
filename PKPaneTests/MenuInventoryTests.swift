// メニュー変更時は期待リストを同じコミットで更新する。リスト更新のないメニュー変更は退行として扱う。
// (このファイルはメニュー項目の目録テスト。項目の追加・削除・並び替えを行った場合は、
//  下記の期待配列/写像をその変更と同じコミットで更新すること)

import Foundation
import SwiftUI
import Testing

@testable import PKPane

@MainActor
struct MenuInventoryTests {

  // MARK: - 右クリックメニュー(contextMenuItems)の目録

  @Test
  func singleFileContextMenuMatchesExpectedInventory() {
    let item = FileItem(url: localURL("資料.pdf"), isDirectory: false)
    let view = makeProviderBrowserView()

    let titles = view.contextMenuItems(
      for: item, selectedItems: [item], browser: browser(), pane: .primary
    ).map(inventoryLabel)

    #expect(
      titles == [
        "開く",
        "このアプリケーションで開く",
        "---",
        "ゴミ箱へ移動",
        "---",
        "情報を見る",
        "名前を変更",
        "ZIPに圧縮 \"資料.pdf\"",
        "7zに圧縮 \"資料.pdf\"",
        "複製",
        "Quick Look",
        "Finderで表示",
        "ターミナルで開く",
        "共有…",
        "外部アプリで編集",
        "\"資料.pdf\"をここに展開",
        "\"資料.pdf\"を同名フォルダへ展開",
        "---",
        "タグ",
        "タグ…",
        "---",
        "コピー \"資料.pdf\"",
        "カット",
        "ペースト",
        "パスをコピー",
        "コピー先を選択…",
        "移動先を選択…",
      ])
  }

  @Test
  func singleFolderContextMenuMatchesExpectedInventory() {
    let item = FileItem(url: localURL("サブフォルダ"), isDirectory: true)
    let view = makeProviderBrowserView(favoriteContextMenuItem: { _, _ in
      FileContextMenuItem(title: "お気に入りに追加", systemImage: "star") {}
    })

    let titles = view.contextMenuItems(
      for: item, selectedItems: [item], browser: browser(), pane: .primary
    ).map(inventoryLabel)

    #expect(
      titles == [
        "開く",
        "このアプリケーションで開く",
        "---",
        "ゴミ箱へ移動",
        "---",
        "情報を見る",
        "名前を変更",
        "ZIPに圧縮 \"サブフォルダ\"",
        "7zに圧縮 \"サブフォルダ\"",
        "複製",
        "Quick Look",
        "Finderで表示",
        "ターミナルで開く",
        "共有…",
        "外部アプリで編集",
        "\"サブフォルダ\"をここに展開",
        "\"サブフォルダ\"を同名フォルダへ展開",
        "---",
        "タグ",
        "タグ…",
        "---",
        "コピー \"サブフォルダ\"",
        "カット",
        "ペースト",
        "パスをコピー",
        "コピー先を選択…",
        "移動先を選択…",
        "お気に入りに追加",
      ])
  }

  @Test
  func multipleSelectionContextMenuMatchesExpectedInventory() {
    let clickedItem = FileItem(url: localURL("a.txt"), isDirectory: false)
    let otherItem = FileItem(url: localURL("b.txt"), isDirectory: false)
    let view = makeProviderBrowserView()

    let titles = view.contextMenuItems(
      for: clickedItem, selectedItems: [clickedItem, otherItem], browser: browser(),
      pane: .primary
    ).map(inventoryLabel)

    #expect(
      titles == [
        "開く",
        "このアプリケーションで開く",
        "---",
        "ゴミ箱へ移動",
        "---",
        "情報を見る",
        "一括リネーム",
        "ZIPに圧縮(2項目)",
        "7zに圧縮(2項目)",
        "複製",
        "Quick Look",
        "Finderで表示",
        "ターミナルで開く",
        "共有…",
        "外部アプリで編集",
        "\"a.txt\"をここに展開",
        "\"a.txt\"を同名フォルダへ展開",
        "---",
        "タグ",
        "タグ…",
        "---",
        "コピー(2項目)",
        "カット",
        "ペースト",
        "パスをコピー",
        "コピー先を選択…",
        "移動先を選択…",
      ])
  }

  @Test("SFTPメニューは完全削除を明示しローカル固有操作の無効理由を保つ")
  func sftpContextMenuExplainsLocalOnlyOperations() throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let provider = SFTPFileProvider(
      target: target,
      directoryListing: MenuInventorySFTPClientSession())
    let browser = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: "/", providerID: provider.id),
      transferQueue: .isolatedForTesting())
    let workspace = FileWorkspaceModel(initialBrowser: browser)
    let view = makeProviderBrowserView(browser: browser, workspace: workspace)
    let item = FileItem(
      remotePath: "/report.txt",
      url: URL(string: "sftp://tester@example.com/report.txt")!,
      providerID: provider.id,
      isDirectory: false)

    let items = view.contextMenuItems(
      for: item, selectedItems: [item], browser: browser, pane: .primary)

    #expect(items.first { $0.title == "完全に削除…" }?.isEnabled == true)
    #expect(
      items.first { $0.title == "このアプリケーションで開く" }?.disabledReason
        == "リモート項目は「外部アプリで編集」を使用してください。")
    #expect(
      items.first { $0.title == "Finderで表示" }?.disabledReason
        == "リモート項目はFinderで表示できません。")
    #expect(
      items.first { $0.title == "ターミナルで開く" }?.disabledReason
        == "リモート接続では利用できません。")
    #expect(
      items.first { $0.title == "共有…" }?.disabledReason
        == "リモート項目は共有できません。")
  }

  @Test("全展開形式で既存の展開導線を有効にし作成導線はZIPと7zだけに保つ")
  func expandedArchiveFormatsUseExistingExtractionMenuOnly() throws {
    let view = makeProviderBrowserView()
    let browser = browser()
    let extractableNames = [
      "sample.zip", "sample.7z", "sample.tar", "sample.tar.gz", "sample.tgz",
      "sample.tar.bz2", "sample.tbz", "sample.tar.xz", "sample.txz",
      "sample.gz", "sample.bz2", "sample.xz", "sample.rar",
    ]

    for name in extractableNames {
      let item = FileItem(url: localURL(name), isDirectory: false)
      let items = view.contextMenuItems(
        for: item,
        selectedItems: [item],
        browser: browser,
        pane: .primary)
      let extractHere = try #require(items.first { $0.title.contains("をここに展開") })
      let extractToFolder = try #require(items.first { $0.title.contains("を同名フォルダへ展開") })
      #expect(extractHere.isEnabled)
      #expect(extractToFolder.isEnabled)
    }

    let unsupported = FileItem(url: localURL("sample.cab"), isDirectory: false)
    let unsupportedItems = view.contextMenuItems(
      for: unsupported,
      selectedItems: [unsupported],
      browser: browser,
      pane: .primary)
    #expect(unsupportedItems.first { $0.title.contains("をここに展開") }?.isEnabled == false)
    #expect(ArchiveFormat.creationFormats == [.zip, .sevenZip])
    let creationTitles = unsupportedItems.map(\.title).filter { $0.contains("に圧縮") }
    #expect(creationTitles == ["ZIPに圧縮 \"sample.cab\"", "7zに圧縮 \"sample.cab\""])
    #expect(!creationTitles.contains { $0.contains("RAR") })
  }

  @Test("コンテキストメニューの各圧縮アクションは表示形式を作成処理へ渡す")
  func contextMenuArchiveActionsPassDisplayedFormats() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "PKPane-ContextArchive-\(UUID().uuidString)",
      directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let sourceURL = root.appending(path: "資料.txt")
    try Data("本文".utf8).write(to: sourceURL)
    let provider = LocalFileProvider()
    let zipCodec = ContextMenuRecordingArchiveCodec()
    let sevenZipCodec = ContextMenuRecordingArchiveCodec()
    let session = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: root, providerID: provider.id),
      transferQueue: .isolatedForTesting(),
      archiveService: ArchiveService(codecs: [.zip: zipCodec, .sevenZip: sevenZipCodec]))
    let workspace = FileWorkspaceModel(initialBrowser: session)
    let defaults = UserDefaults(
      suiteName: "MenuInventoryTests-actions-\(UUID().uuidString)")!
    let archivePreferencesStore = ArchivePreferencesStore(defaults: defaults)
    archivePreferencesStore.save(.sevenZip)
    let view = makeProviderBrowserView(
      browser: session,
      workspace: workspace,
      archivePreferencesStore: archivePreferencesStore)
    let item = try provider.item(at: sourceURL)
    let menuItems = view.contextMenuItems(
      for: item,
      selectedItems: [item],
      browser: session,
      pane: .primary)
    let sevenZipItem = try #require(menuItems.first { $0.title == "7zに圧縮 \"資料.txt\"" })
    let zipItem = try #require(menuItems.first { $0.title == "ZIPに圧縮 \"資料.txt\"" })

    sevenZipItem.action()
    await waitUntil("7z圧縮が期限内に完了しなかった") {
      sevenZipCodec.createCallCount == 1 && !session.isArchiving
    }
    #expect(sevenZipCodec.createCallCount == 1)
    #expect(zipCodec.createCallCount == 0)

    zipItem.action()
    await waitUntil("ZIP圧縮が期限内に完了しなかった") {
      zipCodec.createCallCount == 1 && !session.isArchiving
    }
    #expect(sevenZipCodec.createCallCount == 1)
    #expect(zipCodec.createCallCount == 1)
  }

  @Test
  func backgroundContextMenuDoesNotOfferTransferDestinationChoiceAndMatchesInventory() {
    let view = makeProviderBrowserView()

    let titles = view.backgroundContextMenuItems(browser: browser(), pane: .primary)
      .map(inventoryLabel)

    #expect(
      titles == [
        "新規フォルダ",
        "ペースト",
        "ターミナルで開く",
        "表示オプションを表示",
      ])
    #expect(!titles.contains("コピー先を選択…"))
    #expect(!titles.contains("移動先を選択…"))
  }

  // MARK: - メニューバーの共有ラベルと操作目録

  @Test("全メニュー項目でQuick Openとメニューバーの共有ラベルが一致する")
  func quickOpenTitlesMatchSharedMenuTitlesForEveryItem() throws {
    for item in AppMenuItem.allCases {
      let model = AppMenuModel()
      model.register(context: contextEnabling(item)) { _ in }

      let quickOpenItem = try #require(
        model.quickOpenCommandItems.first { $0.id == item.rawValue })
      #expect(quickOpenItem.title == model.menuTitle(for: item))
    }
  }

  @Test("状態依存ラベルもQuick Openとメニューバーで同じ定義を使う")
  func stateDependentQuickOpenTitlesMatchSharedMenuTitles() throws {
    let model = AppMenuModel()
    model.register(
      context: AppMenuContext(
        isBrowserAvailable: true,
        canToggleCurrentFavorite: true,
        isCurrentFavorite: true,
        sortAscending: false)
    ) { _ in }

    for item in [AppMenuItem.toggleCurrentFavorite, .toggleSortDirection] {
      let quickOpenItem = try #require(
        model.quickOpenCommandItems.first { $0.id == item.rawValue })
      #expect(quickOpenItem.title == model.menuTitle(for: item))
    }
    #expect(model.menuTitle(for: .toggleCurrentFavorite) == "お気に入りから削除")
    #expect(model.menuTitle(for: .toggleSortDirection) == "昇順にする")
  }

  @Test("同期ブラウズのメニューラベルを維持する")
  func syncBrowsingRemainsDirectViewMenuItem() {
    #expect(AppMenuCommands.syncBrowsingMenuInventory == ["同期ブラウズ"])
  }

  @Test("Quick SelectのメニューラベルとOption Command Aを維持する")
  func quickSelectRemainsDirectEditMenuItem() {
    #expect(AppMenuCommands.quickSelectMenuInventory == ["パターンで選択…"])
    #expect(AppMenuCommands.quickSelectShortcutKey == "a")
    #expect(AppMenuCommands.quickSelectShortcutModifiers == [.command, .option])
  }

  @Test("Quick Openは移動メニューの直接項目でShift Command Oを使う")
  func quickOpenRemainsDirectMoveMenuItem() {
    #expect(AppMenuCommands.quickOpenMenuInventory == ["クイックオープン…"])
    #expect(AppMenuCommands.quickOpenShortcutKey == "o")
    #expect(AppMenuCommands.quickOpenShortcutModifiers == [.command, .shift])
  }

  @Test("キーマップ警告用の静的ショートカット目録を公開する")
  func exposesStaticShortcutInventoryForKeymapWarnings() {
    #expect(AppMenuCommands.shortcutInventory.count == 32)
    #expect(
      AppMenuCommands.shortcutInventory.contains(
        KeymapShortcut(key: "o", modifiers: [.command])))
    #expect(
      AppMenuCommands.shortcutInventory.contains(
        KeymapShortcut(
          key: String(UnicodeScalar(NSUpArrowFunctionKey)!),
          modifiers: [.command])))
    #expect(
      AppMenuCommands.shortcutInventory.contains(
        KeymapShortcut(key: "k", modifiers: [.command, .shift])))
  }

  @Test("フォルダ比較と同期実行のメニューラベルを維持する")
  func folderComparisonAndSyncRemainDirectMoveMenuItems() {
    #expect(
      AppMenuCommands.folderComparisonMenuInventory == [
        "フォルダを比較",
        "同期を実行…",
      ])
  }

  @Test("転送履歴は表示メニューの直接項目に置く")
  func transferLogRemainsDirectViewMenuItem() {
    #expect(AppMenuCommands.transferLogMenuInventory == ["転送履歴"])
  }

  @Test("発見性改善のグローバル操作は既存メニューの直接項目に置く")
  func globalDiscoveryCommandsRemainDirectMenuItems() {
    #expect(AppMenuCommands.globalCommandMenuInventory == ["キャッシュを削除…"])
  }

  @Test("ショートカット一覧はヘルプメニューの直接項目に置く")
  func keyboardShortcutListRemainsDirectHelpMenuItem() {
    #expect(AppMenuCommands.keyboardShortcutListMenuInventory == ["キーボードショートカット一覧"])
  }

  @Test
  func detailsDisplayModeItemsMatchExpectedInventory() {
    #expect(AppMenuCommands.detailsDisplayModeMenuInventory == ["詳細を表示"])
    #expect(DetailsDisplayMode.allCases == [.pane, .none])
  }

  @Test
  func viewModeMenuInventoryIncludesColumnView() {
    let viewModeItems = AppMenuItem.allCases.filter {
      switch $0 {
      case .showIconView, .showListView, .showColumnView:
        true
      default:
        false
      }
    }

    #expect(viewModeItems == [.showIconView, .showListView, .showColumnView])
    #expect(FileBrowserViewMode.selectableCases == [.icon, .list, .column])
  }

  @Test
  func searchScopeInventoryMatchesApprovedTokens() {
    #expect(SearchScope.allCases == [.currentFolder, .thisMac])
    #expect(SearchScope.currentFolder.displayName == "現在のフォルダ")
    #expect(SearchScope.thisMac.displayName == "このMac")
  }

  // MARK: - ヘルパー

  private func localURL(_ name: String) -> URL {
    URL(fileURLWithPath: "/tmp/menu-inventory-tests/\(name)")
  }

  private func browser() -> FileBrowserSession {
    let provider = LocalFileProvider()
    let location = FileLocation(localURL: URL(fileURLWithPath: "/tmp", isDirectory: true))
    return FileBrowserSession(
      provider: provider, initialLocation: location, transferQueue: .isolatedForTesting())
  }

  private func makeProviderBrowserView(
    browser: FileBrowserSession? = nil,
    workspace: FileWorkspaceModel? = nil,
    archivePreferencesStore: ArchivePreferencesStore? = nil,
    favoriteContextMenuItem: (([FileItem], FileBrowserSession) -> FileContextMenuItem?)? = nil
  ) -> ProviderBrowserView {
    let browser = browser ?? self.browser()
    let workspace = workspace ?? FileWorkspaceModel(initialBrowser: browser)
    let archivePreferencesStore =
      archivePreferencesStore
      ?? ArchivePreferencesStore(
        defaults: UserDefaults(
          suiteName: "MenuInventoryTests-archive-\(UUID().uuidString)")!)
    return ProviderBrowserView(
      title: "テスト",
      workspace: workspace,
      command: .constant(nil),
      browserViewMode: .constant(.list),
      showsSecondaryPane: .constant(false),
      detailsDisplayMode: .constant(.none),
      detailsInspectorWidth: .constant(280),
      archivePreferencesStore: archivePreferencesStore,
      favoriteContextMenuItem: favoriteContextMenuItem,
      onLocationChanged: { _ in }
    )
  }

  /// FileContextMenuItemを比較しやすい文字列表現へ変換する。セパレータは"---"に統一する。
  private func inventoryLabel(_ item: FileContextMenuItem) -> String {
    item.isSeparator ? "---" : item.title
  }

  private func contextEnabling(_ item: AppMenuItem) -> AppMenuContext {
    AppMenuContext(
      isBrowserAvailable: true,
      capabilities: [.write, .rename, .trash, .copyWithinProvider],
      selectedItemCount: item == .batchRenameSelectedItems ? 2 : 1,
      displayedItemCount: 1,
      canPaste: true,
      canShowOriginal: true,
      canCompareFolders: true,
      canUndo: true,
      canRetry: true,
      showsSecondaryPane: true,
      selectedItemIsPackage: true,
      selectedItemIsArchive: true,
      selectedItemIsDirectory: false,
      canArchive: true,
      isArchiving: item == .cancelArchive,
      canPreviewSelectedItem: true,
      canDuplicate: true,
      canEditRemotely: true,
      canToggleCurrentFavorite: true,
      canGoBack: true,
      canGoForward: true,
      canOpenParent: true,
      canOpenInTerminal: true,
      canOpenWithApplication: true,
      canEditFinderTags: true,
      canShowArchiveContents: true,
      canShareSelectedItems: true,
      canCopySelectedItemPath: true,
      canRevealSearchResult: true,
      canToggleSelectedFolderFavorites: true,
      canCloseConnection: true,
      isLocalProvider: true)
  }
}

private final class ContextMenuRecordingArchiveCodec: ArchiveCodec, @unchecked Sendable {
  private let lock = NSLock()
  private var storedCreateCallCount = 0

  var createCallCount: Int {
    lock.withLock { storedCreateCallCount }
  }

  func createArchive(
    from sourceURLs: [URL],
    to destinationURL: URL,
    cancellationProgress: Progress,
    progress: @escaping @Sendable (ArchiveProgress) -> Void
  ) throws {
    lock.withLock { storedCreateCallCount += 1 }
    try Data().write(to: destinationURL)
  }

  func extractArchive(
    at archiveURL: URL,
    to destinationURL: URL,
    limits: ArchiveSafetyLimits,
    cancellationProgress: Progress,
    progress: @escaping @Sendable (ArchiveProgress) -> Void
  ) throws {}
}

private struct MenuInventorySFTPClientSession: SFTPClientSession {
  func contents(of _: String) async throws -> [SFTPDirectoryEntry] { [] }
  func createDirectory(at _: String) async throws {}
  func remove(at _: String, isDirectory _: Bool) async throws {}
  func rename(at _: String, to _: String) async throws {}
  func close() async throws {}
}
