import Foundation
import SwiftUI
import Synchronization
import Testing

@testable import PKPane

@MainActor
struct FileBrowserSearchSessionTests {
  @Test("検索中は実効リスト投影と選択候補を検索結果へ差し替える")
  func replacesDisplaySourcesWithSearchResults() async throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let resultURL = root.appending(path: "nested/result.txt")
    try FileManager.default.createDirectory(
      at: resultURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: resultURL)
    let resultItem = try LocalFileProvider().item(at: resultURL)
    let service = ScriptedSearchService(items: [resultItem])
    let session = makeSession(root: root, service: service)

    session.setSearchText("result")
    await waitForSearch(session)
    let displayed = session.displayItems(
      matching: "", sortOrder: .name, ascending: true, includesHiddenItems: false)
    let rows = session.flattenedRows(
      matching: "", sortOrder: .name, ascending: true, includesHiddenItems: false)

    #expect(displayed == [resultItem])
    #expect(rows.map(\.item) == [resultItem])
    #expect(rows.allSatisfy { $0.depth == 0 })
    #expect(session.selectableItems == [resultItem])

    let tab = FileWorkspaceTab(browser: session)
    tab.selectedItemURLs = [resultItem.url]
    #expect(tab.selectedItemURLs == [resultItem.url])
  }

  @Test("検索表示は場所列とカラムの一時リスト化を終了後に復元する")
  func searchPresentationRestoresConfiguredValues() {
    let options = FileBrowserDisplayOptions(showsLocationColumn: false)

    let searchingOptions = FileBrowserSearchPresentation.displayOptions(
      configuredOptions: options, isSearchActive: true)
    let restoredOptions = FileBrowserSearchPresentation.displayOptions(
      configuredOptions: options, isSearchActive: false)

    #expect(searchingOptions.showsLocationColumn)
    #expect(!restoredOptions.showsLocationColumn)
    #expect(
      FileBrowserSearchPresentation.viewMode(
        configuredMode: .column, isSearchActive: true) == .list)
    #expect(
      FileBrowserSearchPresentation.viewMode(
        configuredMode: .column, isSearchActive: false) == .column)
    #expect(
      FileBrowserSearchPresentation.viewMode(
        configuredMode: .icon, isSearchActive: true) == .icon)
  }

  @Test("このMacの権限案内は検索状態・範囲・FDAの全組み合わせに従う")
  func fullDiskAccessGuidanceConditions() {
    for isSearchActive in [false, true] {
      for scope in SearchScope.allCases {
        for status in [
          FullDiskAccessStatus.granted,
          .denied,
          .unknown,
        ] {
          let expected =
            isSearchActive && scope == .thisMac && status == .denied
          #expect(
            FileBrowserSearchPresentation.shouldShowThisMacAccessGuidance(
              isSearchActive: isSearchActive,
              scope: scope,
              fullDiskAccessStatus: status) == expected)
        }
      }
    }
  }

  @Test("このMac検索はFDAを再判定し範囲変更と終了で案内を消す")
  func updatesFullDiskAccessGuidanceWithSearchState() async throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let checker = FakeFullDiskAccessChecker(statuses: [.denied, .denied])
    let session = makeSession(
      root: root,
      service: ScriptedSearchService(items: []),
      fullDiskAccessChecker: checker)

    session.setSearchScope(.thisMac)
    session.setSearchText("target")
    await waitForSearch(session)

    #expect(session.showsThisMacAccessGuidance)
    #expect(checker.checkCount == 1)

    session.setSearchScope(.currentFolder)
    #expect(!session.showsThisMacAccessGuidance)
    await waitForSearch(session)

    session.setSearchScope(.thisMac)
    await waitForSearch(session)
    #expect(session.showsThisMacAccessGuidance)
    #expect(checker.checkCount == 2)

    session.endSearch()
    #expect(!session.showsThisMacAccessGuidance)
  }

  @Test("現在のフォルダではBFSを起動せず直下一覧のタグ絞り込みを案内する")
  func filtersLoadedItemsAndShowsTagScopeNoticeForCurrentFolder() async throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let lifecycle = SearchServiceLifecycle()
    let service = ScriptedSearchService(items: [], lifecycle: lifecycle)
    let session = makeSession(root: root, service: service)

    session.setSearchText("tag:仕事 報告書")
    await waitForSearch(session)

    #expect(lifecycle.receivedQueries.isEmpty)
    #expect(session.searchScopeNotice == "tag: はこのフォルダ直下のみを対象に絞り込みます")

    session.setSearchText("tag:仕事")
    await waitForSearch(session)

    #expect(lifecycle.receivedQueries.isEmpty)
    #expect(session.searchScopeNotice == "tag: はこのフォルダ直下のみを対象に絞り込みます")
  }

  @Test("このMacではtag:を含む入力をSpotlight検索へ渡して注意を消す")
  func passesTagQueryToThisMacSearchWithoutScopeNotice() async throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let lifecycle = SearchServiceLifecycle()
    let service = ScriptedSearchService(items: [], lifecycle: lifecycle)
    let session = makeSession(root: root, service: service)

    session.setSearchScope(.thisMac)
    session.setSearchText("tag:仕事 報告書")
    await waitForSearch(session)

    #expect(lifecycle.receivedQueries.last?.text == "tag:仕事 報告書")
    #expect(session.searchScopeNotice == nil)
  }

  @Test("このMacではcontent:を含む生入力をSpotlight検索へ渡して注意を出さない")
  func passesContentQueryToThisMacSearchWithoutScopeNotice() async throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let lifecycle = SearchServiceLifecycle()
    let service = ScriptedSearchService(items: [], lifecycle: lifecycle)
    let session = makeSession(root: root, service: service)

    session.setSearchScope(.thisMac)
    session.setSearchText("content:四半期  tag:仕事 報告書")
    await waitForSearch(session)

    #expect(lifecycle.receivedQueries.last?.text == "content:四半期  tag:仕事 報告書")
    #expect(session.searchScopeNotice == nil)
  }

  @Test("このMacの正規表現検索は開始せずモードOFFで通常検索へ戻る")
  func blocksRegexForThisMacAndRecoversWhenDisabled() async throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let lifecycle = SearchServiceLifecycle()
    let service = ScriptedSearchService(items: [], lifecycle: lifecycle)
    let session = makeSession(
      root: root,
      service: service,
      fullDiskAccessChecker: FakeFullDiskAccessChecker(statuses: [.granted, .granted]))

    session.setSearchScope(.thisMac)
    session.setSearchText("target")
    await waitForSearch(session)
    #expect(lifecycle.receivedQueries.count == 1)

    session.setSearchUsesRegex(true)

    #expect(!session.isSearching)
    #expect(lifecycle.receivedQueries.count == 1)
    #expect(session.searchScopeNotice == "このMacでは正規表現検索を利用できません")

    session.setSearchUsesRegex(false)
    await waitForSearch(session)

    #expect(lifecycle.receivedQueries.count == 2)
    #expect(lifecycle.receivedQueries.last?.nameMatchMode == .literal)
    #expect(session.searchScopeNotice == nil)
  }

  @Test("無効な正規表現は検索を開始せず入力修正で回復する")
  func rejectsInvalidRegexAndRecoversAfterEditing() async throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let lifecycle = SearchServiceLifecycle()
    let service = ScriptedSearchService(items: [], lifecycle: lifecycle)
    let session = makeSession(root: root, service: service)

    session.setSearchUsesRegex(true)
    session.setSearchText("(")

    #expect(!session.isSearching)
    #expect(lifecycle.receivedQueries.isEmpty)
    #expect(session.searchScopeNotice == "正規表現が無効です")

    session.setSearchText("^target$")
    await waitForSearch(session)

    #expect(lifecycle.receivedQueries.count == 1)
    #expect(lifecycle.receivedQueries.last?.nameMatchMode == .regex)
    #expect(session.searchScopeNotice == nil)
  }

  @Test("正規表現トグルは同じ入力を新しいgenerationで再検索する")
  func regexToggleRestartsSearchWithNewGeneration() async throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let lifecycle = SearchServiceLifecycle()
    let service = ScriptedSearchService(items: [], lifecycle: lifecycle)
    let session = makeSession(root: root, service: service)

    session.setSearchText("target")
    await waitForSearch(session)
    let literalQuery = try #require(lifecycle.receivedQueries.last)

    session.setSearchUsesRegex(true)
    await waitForSearch(session)
    let regexQuery = try #require(lifecycle.receivedQueries.last)

    #expect(lifecycle.receivedQueries.count == 2)
    #expect(literalQuery.text == regexQuery.text)
    #expect(literalQuery.generation != regexQuery.generation)
    #expect(regexQuery.nameMatchMode == .regex)
  }

  @Test("FDAがdeniedからgrantedへ変わると再検索で案内が消える")
  func refreshesGuidanceFromDeniedToGranted() async throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let checker = FakeFullDiskAccessChecker(statuses: [.denied, .granted])
    let session = makeSession(
      root: root,
      service: ScriptedSearchService(items: []),
      searchDebounceDuration: .milliseconds(100),
      fullDiskAccessChecker: checker)

    session.setSearchScope(.thisMac)
    session.setSearchText("first")
    await waitForSearch(session)
    #expect(session.showsThisMacAccessGuidance)
    #expect(checker.checkCount == 1)

    session.setSearchText("second")
    #expect(!session.showsThisMacAccessGuidance)
    #expect(checker.checkCount == 1)

    await waitForSearch(session)
    #expect(!session.showsThisMacAccessGuidance)
    #expect(checker.checkCount == 2)
  }

  @Test("FDAがgrantedからdeniedへ変わると再検索で案内が出る")
  func refreshesGuidanceFromGrantedToDenied() async throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let checker = FakeFullDiskAccessChecker(statuses: [.granted, .denied])
    let session = makeSession(
      root: root,
      service: ScriptedSearchService(items: []),
      fullDiskAccessChecker: checker)

    session.setSearchScope(.thisMac)
    session.setSearchText("first")
    await waitForSearch(session)
    #expect(!session.showsThisMacAccessGuidance)

    session.setSearchText("second")
    await waitForSearch(session)
    #expect(session.showsThisMacAccessGuidance)
    #expect(checker.checkCount == 2)
  }

  @Test("FDA付与済みのこのMac検索では権限案内を出さない")
  func hidesFullDiskAccessGuidanceWhenGranted() async throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let checker = FakeFullDiskAccessChecker(statuses: [.granted])
    let session = makeSession(
      root: root,
      service: ScriptedSearchService(items: []),
      fullDiskAccessChecker: checker)

    session.setSearchScope(.thisMac)
    session.setSearchText("target")
    await waitForSearch(session)

    #expect(!session.showsThisMacAccessGuidance)
    #expect(checker.checkCount == 1)
  }

  @Test("ナビゲーションは進行中の検索をキャンセルして状態を消去する")
  func navigationCancelsActiveSearch() async throws {
    let root = try makeDirectory()
    let destination = root.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let lifecycle = SearchServiceLifecycle()
    let service = ScriptedSearchService(items: [], waitsUntilCancelled: true, lifecycle: lifecycle)
    let session = makeSession(root: root, service: service)
    // content:やtag:を含めない素の名前検索にすること。含めると現在のフォルダスコープでは
    // ローカルフィルタ経路へ逸れてサービスが呼ばれず、非同期検索の実キャンセルを
    // 検証するこのテストが空洞化する(2026-08-20レビュー指摘)。
    session.setSearchText("pending")
    await waitUntil { lifecycle.didStart }
    #expect(lifecycle.didStart)

    session.open(location: FileLocation(directoryURL: destination))
    await waitUntil { lifecycle.wasCancelled }

    #expect(session.searchText.isEmpty)
    #expect(!session.isSearchActive)
    #expect(!session.isSearching)
    #expect(session.searchResults.isEmpty)
  }

  @Test("場所へ移動は親フォルダを開いて検索結果を選択要求する")
  func revealsSearchResultInItsParentDirectory() async throws {
    let root = try makeDirectory()
    let parentURL = root.appending(path: "child", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)
    let itemURL = parentURL.appending(path: "target.txt")
    try Data().write(to: itemURL)
    defer { try? FileManager.default.removeItem(at: root) }
    let resultItem = try LocalFileProvider().item(at: itemURL)
    let session = makeSession(root: root, service: ScriptedSearchService(items: [resultItem]))
    session.load()
    await waitForLoading(session)
    session.setSearchText("target")
    await waitForSearch(session)

    session.revealSearchResult(resultItem)
    await waitForLoading(session)
    await waitUntil { session.revealRequest != nil }
    let parentLocation = try #require(resultItem.location.deletingLastPathComponent())

    #expect(session.currentLocation.representsSameDirectory(as: parentLocation))
    #expect(session.searchText.isEmpty)
    #expect(session.revealRequest?.itemURL == itemURL)
    #expect(session.revealRequest?.directoryLocation == parentLocation)
  }

  @Test("検索結果の右クリックに場所へ移動を追加する")
  func searchContextMenuIncludesRevealLocation() async throws {
    let root = try makeDirectory()
    let itemURL = root.appending(path: "target.txt")
    try Data().write(to: itemURL)
    defer { try? FileManager.default.removeItem(at: root) }
    let resultItem = try LocalFileProvider().item(at: itemURL)
    let session = makeSession(root: root, service: ScriptedSearchService(items: [resultItem]))
    session.setSearchText("target")
    await waitForSearch(session)
    let workspace = FileWorkspaceModel(initialBrowser: session)
    let view = ProviderBrowserView(
      title: "テスト",
      workspace: workspace,
      command: .constant(nil),
      browserViewMode: .constant(.list),
      showsSecondaryPane: .constant(false),
      detailsDisplayMode: .constant(.none),
      detailsInspectorWidth: .constant(280),
      onLocationChanged: { _ in })

    let titles = view.contextMenuItems(
      for: resultItem,
      selectedItems: [resultItem],
      browser: session,
      pane: .primary
    ).filter { !$0.isSeparator }.map(\.title)

    #expect(titles.contains("場所へ移動"))
  }

  @Test("未ロードの現在フォルダへ場所移動しても対象をロード後に選択要求する")
  func revealsResultInCurrentDirectoryAfterLoading() async throws {
    let root = try makeDirectory()
    let itemURL = root.appending(path: "target.txt")
    try Data().write(to: itemURL)
    defer { try? FileManager.default.removeItem(at: root) }
    let resultItem = try LocalFileProvider().item(at: itemURL)
    let session = makeSession(root: root, service: ScriptedSearchService(items: [resultItem]))
    session.setSearchText("target")
    await waitForSearch(session)

    session.revealSearchResult(resultItem)
    await waitForLoading(session)
    await waitUntil { session.revealRequest != nil }

    #expect(session.revealRequest?.itemURL == itemURL)
    #expect(session.items.contains { $0.url == resultItem.url })
  }

  @Test("空の検索結果バッチを受けても終了まで安全に処理する")
  func acceptsEmptyResultBatch() async throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let emptyBatchService = EmptyBatchSearchService()
    let provider = LocalFileProvider()
    let emptyBatchSession = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(directoryURL: root, providerID: provider.id),
      transferQueue: .isolatedForTesting(),
      searchDebounceDuration: .zero,
      providerSearchServiceFactory: { _ in emptyBatchService },
      spotlightSearchService: emptyBatchService)

    emptyBatchSession.setSearchText("empty")
    await waitForSearch(emptyBatchSession)

    #expect(emptyBatchSession.searchResults.isEmpty)
    #expect(!emptyBatchSession.isSearching)
  }

  @Test("場所へ移動した後もZIP作成結果の追従要求を更新する")
  func archiveRevealSupersedesSearchReveal() async throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let itemURL = root.appending(path: "target.txt")
    try Data("target".utf8).write(to: itemURL)
    let resultItem = try LocalFileProvider().item(at: itemURL)
    let session = makeSession(root: root, service: ScriptedSearchService(items: [resultItem]))
    session.load()
    await waitForLoading(session)
    session.setSearchText("target")
    await waitForSearch(session)

    session.revealSearchResult(resultItem)
    await waitUntil { session.revealRequest?.itemURL == itemURL }
    let searchRevealGeneration = try #require(session.revealRequest?.generation)

    session.createArchive([resultItem])
    await waitUntil {
      session.revealRequest?.itemURL.lastPathComponent == "target.txt.zip"
    }

    let archiveReveal = try #require(session.revealRequest)
    #expect(archiveReveal.generation > searchRevealGeneration)
    #expect(archiveReveal.itemURL.lastPathComponent == "target.txt.zip")
  }

  @Test("FileBrowserSessionが選択された7z形式を作成サービスへ渡す")
  func createsSevenZipFromSelectedFormat() async throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let itemURL = root.appending(path: "target.txt")
    try Data("target".utf8).write(to: itemURL)
    let item = try LocalFileProvider().item(at: itemURL)
    let session = makeSession(root: root, service: ScriptedSearchService(items: []))

    session.createArchive([item], format: .sevenZip)
    await waitUntil {
      session.revealRequest?.itemURL.lastPathComponent == "target.txt.7z"
    }

    #expect(session.errorMessage == nil)
    let archiveURL = try #require(session.revealRequest?.itemURL)
    #expect(archiveURL.pathExtension == "7z")
    #expect(FileManager.default.fileExists(atPath: archiveURL.path))
  }

  @Test("検索終了時は場所が変わっていなければカラム階層を完全復元する")
  func restoresColumnHierarchyAfterSearch() async throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let childURL = root.appending(path: "child", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: childURL, withIntermediateDirectories: true)
    try Data().write(to: childURL.appending(path: "target.txt"))
    let session = makeSession(root: root, service: ScriptedSearchService(items: []))
    session.load()
    await waitForLoading(session)
    session.beginColumnBrowsing()
    let child = try #require(session.items.first(where: { $0.name == "child" }))
    session.selectColumnItem(child, inColumnAt: 0)
    await waitUntil {
      session.columnState.columns.count == 2
        && session.columnState.columns[1].isLoading == false
    }
    let savedState = session.columnState

    session.setSearchText("target")
    session.endColumnBrowsing()
    await waitForSearch(session)
    session.endSearch()
    session.beginColumnBrowsing()

    #expect(session.columnState == savedState)
  }

  @Test("1万件検索は最初の表示スナップショットを完了前に公開する")
  func progressivelyPublishesTenThousandResultSnapshots() async throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let items = (0..<10_000).map { index in
      FileItem(url: root.appending(path: "target-\(index).txt"), isDirectory: false)
    }
    let service = ScriptedSearchService(
      items: items,
      pauseAfterFirstBatch: .milliseconds(150))
    let session = makeSession(root: root, service: service)
    let clock = ContinuousClock()
    let start = clock.now

    session.setSearchText("target")
    await waitUntil { session.searchResults.count >= 100 }
    let firstBatchDuration = start.duration(to: clock.now)

    #expect(session.searchResults.count < 10_000)
    #expect(session.isSearching)
    #expect(firstBatchDuration < .milliseconds(500))

    await waitForSearch(session, timeout: .seconds(3))
    let totalDuration = start.duration(to: clock.now)
    #expect(session.searchResults.count == 10_000)
    #expect(totalDuration < .seconds(3))
  }

  @Test("検索結果はタブの現在ソートへ追従する")
  func followsCurrentTabSortOrder() async throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let items = ["charlie.txt", "alpha.txt", "bravo.txt"].map {
      FileItem(url: root.appending(path: $0), isDirectory: false)
    }
    let session = makeSession(root: root, service: ScriptedSearchService(items: items))
    let tab = FileWorkspaceTab(browser: session)

    session.setSearchText("txt")
    await waitForSearch(session)
    #expect(
      session.searchResults.map { $0.item.name }
        == ["alpha.txt", "bravo.txt", "charlie.txt"])

    tab.toggleSortDirection()
    await waitUntil {
      session.searchResults.map { $0.item.name } == ["charlie.txt", "bravo.txt", "alpha.txt"]
    }
    #expect(
      session.searchResults.map { $0.item.name }
        == ["charlie.txt", "bravo.txt", "alpha.txt"])
  }

  @Test("検索中のリネーム成功後は古い結果行を除去する")
  func removesRenamedItemFromSearchResults() async throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let itemURL = root.appending(path: "target.txt")
    try Data().write(to: itemURL)
    let item = try LocalFileProvider().item(at: itemURL)
    let session = makeSession(root: root, service: ScriptedSearchService(items: [item]))
    session.load()
    await waitForLoading(session)
    session.setSearchText("target")
    await waitForSearch(session)

    session.rename(item, to: "renamed.txt")
    await waitUntil {
      !session.isLoading && session.searchResults.isEmpty
    }

    #expect(session.searchResults.isEmpty)
    #expect(FileManager.default.fileExists(atPath: root.appending(path: "renamed.txt").path))
  }

  @Test("隠し項目の切替は検索文字列を保ったまま再検索する")
  func hiddenItemsChangeRestartsSearch() async throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let visible = FileItem(url: root.appending(path: "target.txt"), isDirectory: false)
    let hidden = FileItem(url: root.appending(path: ".target.txt"), isDirectory: false)
    let provider = LocalFileProvider()
    let session = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(directoryURL: root, providerID: provider.id),
      transferQueue: .isolatedForTesting(),
      searchDebounceDuration: .zero,
      providerSearchServiceFactory: { includesHiddenItems in
        ScriptedSearchService(items: includesHiddenItems ? [visible, hidden] : [visible])
      })
    session.setSearchText("target")
    await waitForSearch(session)
    #expect(session.searchResults.map(\.item) == [visible])

    session.setShowsHiddenFiles(true)
    await waitUntil {
      !session.isSearching
        && Set(session.searchResults.map { $0.item.name }) == ["target.txt", ".target.txt"]
    }

    #expect(session.searchText == "target")
    #expect(Set(session.searchResults.map { $0.item.name }) == ["target.txt", ".target.txt"])
  }

  @Test("入力更新後は新しいスナップショットが届くまで前の結果を保持する")
  func keepsPreviousResultsDuringDebounce() async throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let oldItem = FileItem(url: root.appending(path: "old.txt"), isDirectory: false)
    let newItem = FileItem(url: root.appending(path: "new.txt"), isDirectory: false)
    let service = QueryDelaySearchService(oldItem: oldItem, newItem: newItem)
    let provider = LocalFileProvider()
    let session = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(directoryURL: root, providerID: provider.id),
      transferQueue: .isolatedForTesting(),
      searchDebounceDuration: .zero,
      providerSearchServiceFactory: { _ in service })
    session.setSearchText("old")
    await waitForSearch(session)
    #expect(session.searchResults.map(\.item) == [oldItem])

    session.setSearchText("new")
    await Task.yield()
    #expect(session.searchResults.map(\.item) == [oldItem])

    await waitUntil {
      !session.isSearching && session.searchResults.map(\.item) == [newItem]
    }
    #expect(session.searchResults.map(\.item) == [newItem])
  }

  @Test("検索状態はセッションごとに独立し非ローカルProviderはこのMacを選べない")
  func keepsSearchStatePerSessionAndLimitsThisMacScope() async throws {
    let firstRoot = try makeDirectory()
    let secondRoot = try makeDirectory()
    defer {
      try? FileManager.default.removeItem(at: firstRoot)
      try? FileManager.default.removeItem(at: secondRoot)
    }
    let firstItem = FileItem(
      url: firstRoot.appending(path: "first-target.txt"), isDirectory: false)
    let first = makeSession(
      root: firstRoot, service: ScriptedSearchService(items: [firstItem]))
    let second = makeSession(
      root: secondRoot, service: ScriptedSearchService(items: []))

    first.setSearchScope(.thisMac)
    first.setSearchText("target")
    await waitForSearch(first)

    #expect(first.searchScope == .thisMac)
    #expect(first.searchResults.map(\.item) == [firstItem])
    #expect(second.searchText.isEmpty)
    #expect(second.searchResults.isEmpty)

    let remoteProvider = RemoteSearchProvider()
    let remote = FileBrowserSession(
      provider: remoteProvider,
      initialLocation: FileLocation(remotePath: "/", providerID: remoteProvider.id),
      transferQueue: .isolatedForTesting())
    remote.setSearchScope(.thisMac)
    #expect(!remote.supportsThisMacSearch)
    #expect(remote.searchScope == .currentFolder)
  }

  private func makeSession(
    root: URL,
    service: ScriptedSearchService,
    searchDebounceDuration: Duration = .zero,
    fullDiskAccessChecker: any FullDiskAccessChecking = FakeFullDiskAccessChecker(
      statuses: [.granted])
  ) -> FileBrowserSession {
    let provider = LocalFileProvider()
    return FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(directoryURL: root, providerID: provider.id),
      transferQueue: .isolatedForTesting(),
      searchDebounceDuration: searchDebounceDuration,
      providerSearchServiceFactory: { _ in service },
      spotlightSearchService: service,
      fullDiskAccessChecker: fullDiskAccessChecker)
  }

  private func makeDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "pkpane-search-session-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func waitForSearch(
    _ session: FileBrowserSession,
    timeout: Duration = .seconds(2)
  ) async {
    await PKPaneTests.waitUntil(timeout: timeout, "検索が期限内に完了しなかった") {
      !session.isSearching
    }
  }

  private func waitForLoading(_ session: FileBrowserSession) async {
    await PKPaneTests.waitUntil("セッションの読み込みが期限内に完了しなかった") {
      !session.isLoading && !session.isRefreshing
    }
  }

  private func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: () -> Bool
  ) async {
    await PKPaneTests.waitUntil(timeout: timeout, "検索セッションの状態が期限内に条件を満たさなかった") {
      condition()
    }
  }
}

private final class FakeFullDiskAccessChecker: FullDiskAccessChecking {
  private var results: [FullDiskAccessStatus]
  private(set) var checkCount = 0

  init(statuses: [FullDiskAccessStatus]) {
    if statuses.isEmpty {
      Issue.record("FakeFullDiskAccessCheckerにstatusesが空で渡されました")
    }
    results = statuses
  }

  var status: FullDiskAccessStatus {
    guard !results.isEmpty else {
      Issue.record("FDAフェイクの逐次応答を使い切りました")
      return .denied
    }
    checkCount += 1
    return results.removeFirst()
  }
}

private struct ScriptedSearchService: SearchService {
  let items: [FileItem]
  var waitsUntilCancelled = false
  var pauseAfterFirstBatch: Duration?
  var lifecycle = SearchServiceLifecycle()

  func search(_ query: SearchQuery) -> AsyncStream<SearchUpdate> {
    AsyncStream { continuation in
      let task = Task.detached {
        lifecycle.markStarted(query: query)
        if waitsUntilCancelled {
          do {
            try await Task.sleep(for: .seconds(10))
          } catch {
            return
          }
        } else {
          var startIndex = 0
          while startIndex < items.count {
            guard !Task.isCancelled else { return }
            let endIndex = min(startIndex + ProviderSearchEngine.batchSize, items.count)
            let results = items[startIndex..<endIndex].map { item in
              SearchResult(
                item: item,
                parent: item.location.deletingLastPathComponent() ?? query.root,
                providerID: item.location.providerID,
                generation: query.generation)
            }
            continuation.yield(.results(results, generation: query.generation))
            startIndex = endIndex
            if startIndex == ProviderSearchEngine.batchSize, let pauseAfterFirstBatch {
              try? await Task.sleep(for: pauseAfterFirstBatch)
            } else {
              await Task.yield()
            }
          }
          continuation.yield(.finished(query.generation))
          continuation.finish()
        }
      }
      continuation.onTermination = { termination in
        if case .cancelled = termination { lifecycle.markCancelled() }
        task.cancel()
      }
    }
  }
}

private struct EmptyBatchSearchService: SearchService {
  func search(_ query: SearchQuery) -> AsyncStream<SearchUpdate> {
    AsyncStream { continuation in
      continuation.yield(.results([], generation: query.generation))
      continuation.yield(.finished(query.generation))
      continuation.finish()
    }
  }
}

private struct QueryDelaySearchService: SearchService {
  let oldItem: FileItem
  let newItem: FileItem

  func search(_ query: SearchQuery) -> AsyncStream<SearchUpdate> {
    AsyncStream { continuation in
      let task = Task.detached {
        if query.text == "new" {
          try? await Task.sleep(for: .milliseconds(100))
        }
        guard !Task.isCancelled else { return }
        let item = query.text == "new" ? newItem : oldItem
        let result = SearchResult(
          item: item,
          parent: item.location.deletingLastPathComponent() ?? query.root,
          providerID: item.location.providerID,
          generation: query.generation)
        continuation.yield(.results([result], generation: query.generation))
        continuation.yield(.finished(query.generation))
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

private final class SearchServiceLifecycle: @unchecked Sendable {
  private struct State {
    var didStart = false
    var wasCancelled = false
    var receivedQueries = [SearchQuery]()
  }

  private let state = Mutex(State())

  var didStart: Bool { state.withLock(\.didStart) }
  var wasCancelled: Bool { state.withLock(\.wasCancelled) }
  var receivedQueries: [SearchQuery] { state.withLock(\.receivedQueries) }

  func markStarted(query: SearchQuery) {
    state.withLock {
      $0.didStart = true
      $0.receivedQueries.append(query)
    }
  }
  func markCancelled() { state.withLock { $0.wasCancelled = true } }
}

private struct RemoteSearchProvider: FileBrowserProvider {
  let id = FileProviderID(rawValue: "remote-search")
  let connectionID: FileProviderConnectionID? = nil
  let capabilities: FileProviderCapabilities = [.read]

  func contents(of _: FileLocation) async throws -> [FileItem] { [] }
  func parent(of _: FileLocation) -> FileLocation? { nil }
  func breadcrumbs(
    for _: FileLocation,
    constrainedTo _: FileLocation?
  ) -> [FileBrowserBreadcrumb] { [] }
}
