import Foundation
import Testing

@testable import PKPane

struct FileBrowserColumnStateTests {
  private let root = FileLocation(localURL: URL(filePath: "/tmp/column-root"))

  @Test("フォルダ選択で右に読み込み中のカラムを追加し現在地を追従させる")
  func selectingFolderAppendsColumnAndFollowsLocation() throws {
    let folder = item("Documents", in: root, isDirectory: true)
    var state = FileBrowserColumnState()
    state.begin(at: root, items: [folder])

    let selection = state.select(folder, inColumnAt: 0)
    let transition = try #require(selection)

    #expect(state.columns.map(\.location) == [root, folder.location])
    try #require(state.columns.count == 2)
    #expect(state.columns[0].selectedItemURLs == [folder.url])
    #expect(state.columns[1].isLoading)
    #expect(state.currentLocation == folder.location)
    #expect(transition.destination == folder.location)
  }

  @Test("移動先で再開始するとその場所だけが左端カラムになる")
  func beginningAtNavigationDestinationReplacesColumns() throws {
    let folder = item("Documents", in: root, isDirectory: true)
    let destination = folder.location
    let destinationItem = item("report.txt", in: destination, isDirectory: false)
    var state = FileBrowserColumnState()
    state.begin(at: root, items: [folder])
    _ = state.select(folder, inColumnAt: 0)

    state.begin(at: destination, items: [destinationItem])

    #expect(state.columns.map(\.location) == [destination])
    try #require(state.columns.count == 1)
    #expect(state.columns[0].items == [destinationItem])
    #expect(state.columns[0].selectedItemURLs.isEmpty)
    #expect(!state.columns[0].isLoading)
  }

  @Test("途中カラムで別フォルダを選ぶと右側を巻き戻して新しいカラムを開く")
  func selectingDifferentFolderRewindsTrailingColumns() throws {
    let documents = item("Documents", in: root, isDirectory: true)
    let downloads = item("Downloads", in: root, isDirectory: true)
    let caria = item("caria", in: documents.location, isDirectory: true)
    var state = FileBrowserColumnState()
    state.begin(at: root, items: [documents, downloads])
    _ = state.select(documents, inColumnAt: 0)
    state.setItems([caria], at: documents.location)
    state.finishLoading(at: documents.location)
    _ = state.select(caria, inColumnAt: 1)

    let selection = state.select(downloads, inColumnAt: 0)
    let transition = try #require(selection)

    #expect(state.columns.map(\.location) == [root, downloads.location])
    try #require(!state.columns.isEmpty)
    #expect(state.columns[0].selectedItemURLs == [downloads.url])
    #expect(state.currentLocation == downloads.location)
    #expect(transition.destination == downloads.location)
  }

  @Test("途中カラムのファイル選択で右側を閉じ現在地をそのカラムへ戻す")
  func selectingFileRewindsToContainingColumn() throws {
    let documents = item("Documents", in: root, isDirectory: true)
    let report = item("report.txt", in: root, isDirectory: false)
    var state = FileBrowserColumnState()
    state.begin(at: root, items: [documents, report])
    _ = state.select(documents, inColumnAt: 0)
    state.setItems([], at: documents.location)
    state.finishLoading(at: documents.location)

    let selection = state.select(report, inColumnAt: 0)
    let transition = try #require(selection)

    try #require(state.columns.count == 1)
    #expect(state.columns[0].selectedItemURLs == [report.url])
    #expect(state.currentLocation == root)
    #expect(transition.destination == root)
  }

  @Test("複数選択は全URLを保持して右側の子カラムを閉じる")
  func multipleSelectionClosesTrailingColumns() throws {
    let documents = item("Documents", in: root, isDirectory: true)
    let report = item("report.txt", in: root, isDirectory: false)
    var state = FileBrowserColumnState()
    state.begin(at: root, items: [documents, report])
    _ = state.select(documents, inColumnAt: 0)

    let selectedURLs: Set<URL> = [documents.url, report.url]
    let selection = state.select(selectedURLs, inColumnAt: 0)
    let transition = try #require(selection)

    try #require(state.columns.count == 1)
    #expect(state.columns[0].selectedItemURLs == selectedURLs)
    #expect(state.currentLocation == root)
    #expect(transition.destination == root)
  }

  @Test("選択解除は選択集合を空にして右側の子カラムを閉じる")
  func clearingSelectionClosesTrailingColumns() throws {
    let documents = item("Documents", in: root, isDirectory: true)
    var state = FileBrowserColumnState()
    state.begin(at: root, items: [documents])
    _ = state.select(documents, inColumnAt: 0)

    let selection = state.select([], inColumnAt: 0)
    let transition = try #require(selection)

    try #require(state.columns.count == 1)
    #expect(state.columns[0].selectedItemURLs.isEmpty)
    #expect(transition.destination == root)
  }

  @Test("表示後にメタデータが補完されてもURLが同じ項目の選択を受理する")
  func selectionUsesStableURLIdentityAfterMetadataEnrichment() {
    let initial = item("Documents", in: root, isDirectory: true)
    let enriched = FileItem(
      url: initial.url, isDirectory: true, modifiedAt: Date(timeIntervalSince1970: 1))
    var state = FileBrowserColumnState()
    state.begin(at: root, items: [enriched])

    let transition = state.select(initial, inColumnAt: 0)

    #expect(transition?.destination == initial.location)
    #expect(state.columns.count == 2)
  }

  @Test("展開済みフォルダの再選択は読み込み済みの右カラムを保持する")
  func reselectingExpandedFolderKeepsLoadedChildColumn() throws {
    let folder = item("Folder", in: root, isDirectory: true)
    let child = item("child.txt", in: folder.location, isDirectory: false)
    var state = FileBrowserColumnState()
    state.begin(at: root, items: [folder])
    _ = state.select(folder, inColumnAt: 0)
    state.setItems([child], at: folder.location)
    state.finishLoading(at: folder.location)

    _ = state.select(folder, inColumnAt: 0)

    try #require(state.columns.count == 2)
    #expect(state.columns[1].items == [child])
    #expect(!state.columns[1].isLoading)
  }

  @Test("幅変更は対象カラムだけに適用し他カラムの実効幅を維持する")
  func columnWidthChangeOnlyUpdatesTargetColumn() throws {
    let folder = item("Folder", in: root, isDirectory: true)
    var state = FileBrowserColumnState()
    state.begin(at: root, items: [folder])
    _ = state.select(folder, inColumnAt: 0)

    state.setWidth(320, at: root, defaultWidth: 240)

    #expect(state.width(at: root, defaultWidth: 320) == 320)
    #expect(state.width(at: folder.location, defaultWidth: 320) == 240)
  }

  @Test("個別幅未指定のカラムは既定幅を使う")
  func columnWithoutOverrideUsesDefaultWidth() {
    var state = FileBrowserColumnState()
    state.begin(at: root, items: [])

    #expect(state.width(at: root, defaultWidth: 318) == 318)
  }

  @Test("個別幅は許容範囲へクランプする")
  func columnWidthIsClamped() {
    var state = FileBrowserColumnState()
    state.begin(at: root, items: [])

    state.setWidth(0, at: root, defaultWidth: 240)
    #expect(state.width(at: root, defaultWidth: 240) == FileBrowserColumnWidth.minimum)

    state.setWidth(10_000, at: root, defaultWidth: 240)
    #expect(state.width(at: root, defaultWidth: 240) == FileBrowserColumnWidth.maximum)
  }

  @Test("左右キーは親の展開行と子カラムの選択行を行き来する")
  func horizontalKeyboardNavigationMovesAcrossColumns() throws {
    let folder = item("Folder", in: root, isDirectory: true)
    let child = item("child.txt", in: folder.location, isDirectory: false)
    let columns = [
      FileBrowserColumn(
        location: root, items: [folder], selectedItemURLs: [folder.url], isLoading: false),
      FileBrowserColumn(
        location: folder.location, items: [child], selectedItemURLs: [], isLoading: false),
    ]

    let right = try #require(
      FileColumnKeyboardNavigation.horizontalTarget(
        in: columns, activeColumnIndex: 0, direction: .right))
    #expect(right.columnIndex == 1)
    #expect(right.item == child)

    let left = try #require(
      FileColumnKeyboardNavigation.horizontalTarget(
        in: columns, activeColumnIndex: 1, direction: .left))
    #expect(left.columnIndex == 0)
    #expect(left.item == folder)
  }

  @Test("左端カラムの左キーは移動せずイベントを消費する")
  func leftArrowAtFirstColumnIsHandledWithoutMovement() {
    let folder = item("Folder", in: root, isDirectory: true)
    let columns = [
      FileBrowserColumn(
        location: root, items: [folder], selectedItemURLs: [folder.url], isLoading: false)
    ]

    let result = FileColumnKeyboardNavigation.handlingResult(
      in: columns, activeColumnIndex: 0, direction: .left)

    #expect(result == .handledWithoutMovement)
  }

  @Test("完全に見えているカラムは追従スクロールしない")
  func fullyVisibleColumnDoesNotNeedScroll() {
    let viewport = CGRect(x: 0, y: 0, width: 600, height: 400)

    #expect(
      !FileColumnScrollVisibility.needsScroll(
        columnFrame: CGRect(x: 100, y: 0, width: 240, height: 400),
        viewportFrame: viewport))
  }

  @Test("左右が一部欠けたカラムは追従スクロールする")
  func partiallyHiddenColumnNeedsScroll() {
    let viewport = CGRect(x: 0, y: 0, width: 600, height: 400)

    #expect(
      FileColumnScrollVisibility.needsScroll(
        columnFrame: CGRect(x: -1, y: 0, width: 240, height: 400),
        viewportFrame: viewport))
    #expect(
      FileColumnScrollVisibility.needsScroll(
        columnFrame: CGRect(x: 400, y: 0, width: 240, height: 400),
        viewportFrame: viewport))
  }

  @Test("表示枠をまだ取得できないカラムは安全側で追従する")
  func unmeasuredColumnNeedsScroll() {
    #expect(
      FileColumnScrollVisibility.needsScroll(
        columnFrame: nil,
        viewportFrame: CGRect(x: 0, y: 0, width: 600, height: 400)))
  }

  @MainActor
  @Test("セッションのカラム展開は現在地を追従し親カラムの選択候補を保持する")
  func sessionExpansionFollowsLocationAndKeepsParentSelection() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appending(path: "pkpane-column-state-\(UUID().uuidString)", directoryHint: .isDirectory)
    let childURL = rootURL.appending(path: "Documents", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: childURL, withIntermediateDirectories: true)
    try Data("child".utf8).write(to: childURL.appending(path: "report.txt"))
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let provider = LocalFileProvider()
    let rootLocation = FileLocation(directoryURL: rootURL, providerID: provider.id)
    let session = FileBrowserSession(
      provider: provider, initialLocation: rootLocation, transferQueue: .isolatedForTesting())
    session.load()
    await waitForLoading(session)
    let folder = try #require(session.items.first { $0.name == "Documents" })

    session.beginColumnBrowsing()
    session.selectColumnItem(folder, inColumnAt: 0)
    await waitForLoading(session)

    #expect(session.currentLocation == folder.location)
    let childColumn = try #require(
      session.columnState.columns.first(where: { $0.location == folder.location }))
    #expect(childColumn.items.map(\.name) == ["report.txt"])
    let parentColumn = try #require(
      session.columnState.columns.first(where: { $0.location == rootLocation }))
    #expect(parentColumn.selectedItemURLs == [folder.url])
    #expect(session.selectableItems.contains(folder))
    #expect(session.selectableItems.contains { $0.name == "report.txt" })
  }

  @MainActor
  @Test("カラムの複数選択はセッション状態とワークスペース選択へ同じ集合を反映する")
  func columnMultipleSelectionSynchronizesSessionAndWorkspace() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appending(path: "pkpane-column-selection-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    try Data().write(to: rootURL.appending(path: "first.txt"))
    try Data().write(to: rootURL.appending(path: "second.txt"))
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let provider = LocalFileProvider()
    let rootLocation = FileLocation(directoryURL: rootURL, providerID: provider.id)
    let session = FileBrowserSession(
      provider: provider, initialLocation: rootLocation, transferQueue: .isolatedForTesting())
    let workspace = FileWorkspaceModel(initialBrowser: session)
    session.load()
    await waitForLoading(session)
    session.beginColumnBrowsing()
    let selectedURLs = Set(session.items.map(\.url))

    workspace.selectItems(selectedURLs, in: .primary)
    session.selectColumnItems(selectedURLs, inColumnAt: rootLocation)

    try #require(!session.columnState.columns.isEmpty)
    #expect(session.columnState.columns[0].selectedItemURLs == selectedURLs)
    #expect(workspace.activeTab.selectedItemURLs == selectedURLs)
    #expect(
      Set(
        session.selectableItems
          .filter { workspace.activeTab.selectedItemURLs.contains($0.url) }
          .map(\.url)) == selectedURLs)
  }

  @MainActor
  @Test("列挙前に開始したカラムへ初期ロード結果を反映する")
  func columnStartedBeforeLoadingReceivesInitialItems() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appending(
        path: "pkpane-column-initial-load-\(UUID().uuidString)",
        directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    try Data("loaded".utf8).write(to: rootURL.appending(path: "loaded.txt"))
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let provider = LocalFileProvider()
    let rootLocation = FileLocation(directoryURL: rootURL, providerID: provider.id)
    let session = FileBrowserSession(
      provider: provider, initialLocation: rootLocation, transferQueue: .isolatedForTesting())

    session.beginColumnBrowsing()
    #expect(session.columnState.columns.first?.items.isEmpty == true)
    session.loadIfNeeded()
    await waitForLoading(session)

    let rootColumn = try #require(
      session.columnState.columns.first { $0.location == rootLocation })
    #expect(rootColumn.location == rootLocation)
    #expect(rootColumn.items.map(\.name) == ["loaded.txt"])
  }

  @MainActor
  @Test("カラム表示中の差し替え後セッションも列挙結果を表示する")
  func replacementSessionReceivesItemsWhileColumnModeIsActive() async throws {
    let transferQueue = TransferQueue.isolatedForTesting()
    let rootURL = FileManager.default.temporaryDirectory
      .appending(
        path: "pkpane-column-replacement-\(UUID().uuidString)",
        directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    try Data("replacement".utf8).write(to: rootURL.appending(path: "replacement.txt"))
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let provider = LocalFileProvider()
    let oldSession = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(directoryURL: rootURL, providerID: provider.id),
      transferQueue: transferQueue)
    let workspace = FileWorkspaceModel(initialBrowser: oldSession)
    oldSession.beginColumnBrowsing()

    let replacement = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(directoryURL: rootURL, providerID: provider.id),
      transferQueue: transferQueue)
    workspace.replaceActiveBrowser(with: replacement)
    replacement.beginColumnBrowsing()
    replacement.loadIfNeeded()
    await waitForLoading(replacement)

    #expect(workspace.activeTab.browser === replacement)
    #expect(replacement.columnState.isActive)
    let rootLocation = FileLocation(directoryURL: rootURL, providerID: provider.id)
    let replacementColumn = try #require(
      replacement.columnState.columns.first { $0.location == rootLocation })
    #expect(replacementColumn.items.map(\.name) == ["replacement.txt"])
  }

  private func item(_ name: String, in location: FileLocation, isDirectory: Bool) -> FileItem {
    let url = try! #require(location.localURL).appending(path: name)
    return FileItem(url: url, providerID: location.providerID, isDirectory: isDirectory)
  }

  @MainActor
  private func waitForLoading(_ session: FileBrowserSession) async {
    await waitUntil("セッションの読み込みが期限内に完了しなかった") {
      !(session.isLoading || session.isRefreshing
        || session.columnState.columns.contains(where: \.isLoading))
    }
  }
}
