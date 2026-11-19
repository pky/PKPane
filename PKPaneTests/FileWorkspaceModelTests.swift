import Foundation
import Testing

@testable import PKPane

@MainActor
struct FileWorkspaceModelTests {
  @Test("閉じたタブのブラウザ状態を無効化する")
  func invalidatesBrowserWhenClosingTab() async throws {
    let provider = ClipboardWorkspaceProvider()
    let workspace = FileWorkspaceModel(
      initialBrowser: FileBrowserSession(
        provider: provider,
        initialLocation: FileLocation(remotePath: ".", providerID: provider.id),
        transferQueue: .isolatedForTesting()))
    let closingTab = try #require(workspace.tab(for: .secondary))

    closingTab.browser.load()
    await waitForLoading(closingTab.browser)
    #expect(!closingTab.browser.items.isEmpty)

    workspace.closeTab(id: closingTab.id)

    #expect(closingTab.browser.items.isEmpty)
  }

  @Test("同期ブラウズ未使用でも残り1タブなら1ペイン化する")
  func closesSecondaryPaneWhenOnlyOneTabRemains() throws {
    let workspace = FileWorkspaceModel(initialBrowser: browser())
    let closingTab = try #require(workspace.tab(for: .secondary))
    #expect(!workspace.isSyncBrowsingEnabled)

    workspace.closeTab(id: closingTab.id)

    #expect(workspace.tabs.count == 1)
    #expect(!workspace.showsSecondaryPane)
    #expect(!workspace.isSyncBrowsingEnabled)
  }

  @Test("Providerに関係なくタブを複製して2ペインへ配置できる")
  func duplicatesTabForSecondaryPane() {
    let workspace = FileWorkspaceModel(initialBrowser: browser())

    workspace.setShowsSecondaryPane(true)

    #expect(workspace.showsSecondaryPane)
    #expect(workspace.tabs.count == 2)
    #expect(workspace.tab(for: .primary)?.browser.currentLocation.providerID == .local)
    #expect(workspace.tab(for: .secondary)?.browser.currentLocation.providerID == .local)
  }

  @Test("リモートProviderもローカルと同じタブ・ペイン状態で扱う")
  func usesSamePaneStateForRemoteProvider() {
    let provider = RemoteWorkspaceProvider()
    let browser = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: "/projects", providerID: provider.id),
      transferQueue: .isolatedForTesting())
    let workspace = FileWorkspaceModel(initialBrowser: browser)

    workspace.setShowsSecondaryPane(true)

    #expect(workspace.tabs.count == 2)
    #expect(workspace.tab(for: .primary)?.browser.currentLocation.providerID == provider.id)
    #expect(workspace.tab(for: .secondary)?.browser.currentLocation.providerID == provider.id)
  }

  @Test("ソート状態はペインごとに独立し既定値は名前の昇順になる")
  func storesSortStateIndependentlyForEachPane() throws {
    let workspace = FileWorkspaceModel(initialBrowser: browser())
    let primary = try #require(workspace.tab(for: .primary))
    let secondary = try #require(workspace.tab(for: .secondary))

    #expect(primary.sortState == FileListSortState(order: .name, ascending: true))
    #expect(secondary.sortState == FileListSortState(order: .name, ascending: true))

    workspace.setSortOrder(.size)
    workspace.toggleSortDirection()

    #expect(primary.sortState == FileListSortState(order: .size, ascending: false))
    #expect(secondary.sortState == FileListSortState(order: .name, ascending: true))
  }

  @Test("列ヘッダのソート要求は対象ペインだけを変更して操作対象にする")
  func headerSortRequestOnlyChangesItsPane() throws {
    let workspace = FileWorkspaceModel(initialBrowser: browser())
    let primary = try #require(workspace.tab(for: .primary))
    let secondary = try #require(workspace.tab(for: .secondary))

    workspace.applySortRequest(.modifiedAt, in: .secondary)

    #expect(workspace.activePane == .secondary)
    #expect(primary.sortState == FileListSortState(order: .name, ascending: true))
    #expect(secondary.sortState == FileListSortState(order: .modifiedAt, ascending: false))
  }

  @Test("操作対象ペインを切り替えても各ペインのソート状態を維持する")
  func preservesSortStateWhenSwitchingActivePane() throws {
    let workspace = FileWorkspaceModel(initialBrowser: browser())
    let primary = try #require(workspace.tab(for: .primary))
    let secondary = try #require(workspace.tab(for: .secondary))
    primary.applySortRequest(.kind)
    secondary.applySortRequest(.size)

    workspace.activatePane(.secondary)
    workspace.activatePane(.primary)

    #expect(primary.sortState == FileListSortState(order: .kind, ascending: true))
    #expect(secondary.sortState == FileListSortState(order: .size, ascending: false))
  }

  @Test("操作対象ペインのブラウザを差し替えてもソート状態を維持する")
  func preservesSortStateWhenReplacingActiveBrowser() throws {
    let workspace = FileWorkspaceModel(initialBrowser: browser())
    workspace.activatePane(.secondary)
    workspace.applySortRequest(.size, in: .secondary)
    let secondary = try #require(workspace.tab(for: .secondary))
    let replacement = browser()

    workspace.replaceActiveBrowser(with: replacement)

    #expect(secondary.browser === replacement)
    #expect(secondary.sortState == FileListSortState(order: .size, ascending: false))
    #expect(
      workspace.tab(for: .primary)?.sortState
        == FileListSortState(order: .name, ascending: true))
  }

  @Test("メニュー相当のソート操作は操作対象ペインだけを変更する")
  func activePaneSortCommandsOnlyChangeActivePane() throws {
    let workspace = FileWorkspaceModel(initialBrowser: browser())
    let primary = try #require(workspace.tab(for: .primary))
    let secondary = try #require(workspace.tab(for: .secondary))
    workspace.activatePane(.secondary)

    workspace.setSortOrder(.modifiedAt)
    workspace.toggleSortDirection()

    #expect(primary.sortState == FileListSortState(order: .name, ascending: true))
    #expect(secondary.sortState == FileListSortState(order: .modifiedAt, ascending: false))
  }

  @Test("片方のソート変更で反対側の表示配列を再計算しない")
  func sortChangeKeepsOppositePaneDisplayCache() throws {
    let workspace = FileWorkspaceModel(initialBrowser: browser())
    let primary = try #require(workspace.tab(for: .primary))
    let secondary = try #require(workspace.tab(for: .secondary))

    _ = primary.browser.displayItems(
      matching: "", sortOrder: primary.sortOrder, ascending: primary.sortAscending,
      includesHiddenItems: false)
    _ = secondary.browser.displayItems(
      matching: "", sortOrder: secondary.sortOrder, ascending: secondary.sortAscending,
      includesHiddenItems: false)
    let primaryCount = primary.browser.displayItemsComputationCount
    let secondaryCount = secondary.browser.displayItemsComputationCount

    workspace.setSortOrder(.size)
    _ = primary.browser.displayItems(
      matching: "", sortOrder: primary.sortOrder, ascending: primary.sortAscending,
      includesHiddenItems: false)
    _ = secondary.browser.displayItems(
      matching: "", sortOrder: secondary.sortOrder, ascending: secondary.sortAscending,
      includesHiddenItems: false)

    #expect(primary.browser.displayItemsComputationCount == primaryCount + 1)
    #expect(secondary.browser.displayItemsComputationCount == secondaryCount)
  }

  @Test("隠しファイル表示の切替で非表示タブを再読み込みしない")
  func reloadsOnlyVisibleTabsWhenTogglingHiddenFiles() async {
    let provider = CountingWorkspaceProvider()
    let location = FileLocation(remotePath: "/projects", providerID: provider.id)
    let workspace = FileWorkspaceModel(
      initialBrowser: FileBrowserSession(
        provider: provider, initialLocation: location, transferQueue: .isolatedForTesting()))
    // 2ペイン表示後に1ペインへ戻すと、secondaryのタブIDはpaneLayoutに保持されたまま
    // 非表示になる(FolderPaneLayout.hideSecondaryPaneはタブ紐付けを消さない)。
    // タブ数は常にペイン数と同数の運用だが、この非表示タブ状態は現行仕様で発生する。
    workspace.setShowsSecondaryPane(true)
    workspace.setShowsSecondaryPane(false)

    workspace.setShowsHiddenFiles(true)
    for pane in workspace.visiblePanes {
      if let browser = workspace.tab(for: pane)?.browser {
        await waitForLoading(browser)
      }
    }

    #expect(provider.contentsCallCount == 1)
  }

  @Test("片方のペインだけを別Providerのブラウザへ差し替えられる")
  func replacesOnlyActivePaneBrowser() {
    let remoteProvider = RemoteWorkspaceProvider()
    let remoteBrowser = FileBrowserSession(
      provider: remoteProvider,
      initialLocation: FileLocation(remotePath: "/projects", providerID: remoteProvider.id),
      transferQueue: .isolatedForTesting())
    let workspace = FileWorkspaceModel(initialBrowser: remoteBrowser)
    workspace.setShowsSecondaryPane(true)
    let localBrowser = browser()

    workspace.replaceActiveBrowser(with: localBrowser)

    #expect(workspace.activeTab.browser.currentLocation.providerID == .local)
    #expect(workspace.tab(for: .secondary)?.browser.currentLocation.providerID == remoteProvider.id)
  }

  @Test("新しい場所を開いても1ペイン構成とアクティブペインを維持する")
  func preservesSinglePaneLayoutWhenReplacingBrowser() {
    let session = ProviderBrowserSession(
      title: "最初の場所",
      browser: browser(),
      connectionID: nil,
      sftpTarget: nil)
    session.workspace.activatePane(.secondary)
    session.showsSecondaryPane = false
    let replacement = browser()

    session.replaceActiveBrowser(with: replacement, title: "次の場所", sftpTarget: nil)

    #expect(!session.showsSecondaryPane)
    #expect(session.workspace.activePane == .secondary)
    #expect(session.workspace.activeTab.browser === replacement)
  }

  @Test("新しい場所を開いても2ペイン構成とアクティブペインを維持する")
  func preservesTwoPaneLayoutWhenReplacingBrowser() throws {
    let session = ProviderBrowserSession(
      title: "最初の場所",
      browser: browser(),
      connectionID: nil,
      sftpTarget: nil)
    session.showsSecondaryPane = true
    session.workspace.activatePane(.secondary)
    let primaryBrowser = try #require(session.workspace.tab(for: .primary)?.browser)
    let replacement = browser()

    session.replaceActiveBrowser(with: replacement, title: "次の場所", sftpTarget: nil)

    #expect(session.showsSecondaryPane)
    #expect(session.workspace.activePane == .secondary)
    #expect(session.workspace.activeTab.browser === replacement)
    #expect(session.workspace.tab(for: .primary)?.browser === primaryBrowser)
  }

  @Test("場所を開き直した初回列挙に隠し項目の表示設定を適用する")
  func appliesHiddenFileSettingToInitialListingWhenReplacingActiveBrowser() async {
    let initial = browser()
    initial.setShowsHiddenFiles(true, reload: false)
    let session = ProviderBrowserSession(
      title: "最初の場所",
      browser: initial,
      connectionID: nil,
      sftpTarget: nil)
    let provider = HiddenItemsWorkspaceProvider()
    let replacement = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: "/next", providerID: provider.id),
      transferQueue: .isolatedForTesting())

    session.replaceActiveBrowser(with: replacement, title: "次の場所", sftpTarget: nil)
    await waitForLoadingWithSleep(replacement)

    #expect(replacement.showsHiddenFiles)
    #expect(replacement.items.map(\.name) == ["visible.txt", ".hidden.txt"])
  }

  @Test("クリップボードが旧ブラウザを保持しても閲覧処理と転送購読を停止する")
  func retiresBrowsingResourcesKeptByClipboard() async throws {
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let provider = ClipboardWorkspaceProvider()
    let source = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: ".", providerID: provider.id),
      transferQueue: queue)
    let session = ProviderBrowserSession(
      title: "転送元",
      browser: source,
      connectionID: nil,
      sftpTarget: nil)
    source.load()
    await waitForLoadingWithSleep(source)
    let item = try #require(source.items.first)
    session.workspace.activeTab.selectedItemURLs = [item.url]
    session.workspace.copySelectedItems()
    let replacement = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: "/next", providerID: provider.id),
      transferQueue: queue)

    session.replaceActiveBrowser(with: replacement, title: "次の場所", sftpTarget: nil)

    #expect(session.workspace.canPasteItems)
    #expect(source.items.isEmpty)
    #expect(!source.hasActiveBrowsingResources)
    #expect(await waitForSubscriberCount(queue, expected: 2) == 2)
  }

  @Test("ナビゲーションを繰り返しても転送キュー購読数が増え続けない")
  func keepsTransferQueueSubscriberCountStableAcrossReplacements() async {
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let provider = CountingWorkspaceProvider()
    let initial = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: "/initial", providerID: provider.id),
      transferQueue: queue)
    let session = ProviderBrowserSession(
      title: "最初の場所",
      browser: initial,
      connectionID: nil,
      sftpTarget: nil)
    #expect(await waitForSubscriberCount(queue, expected: 2) == 2)

    for index in 0..<10 {
      let replacement = FileBrowserSession(
        provider: provider,
        initialLocation: FileLocation(remotePath: "/next-\(index)", providerID: provider.id),
        transferQueue: queue)
      session.replaceActiveBrowser(
        with: replacement, title: "次の場所\(index)", sftpTarget: nil)
      #expect(await waitForSubscriberCount(queue, expected: 2) == 2)
    }
  }

  @Test("共通ワークスペースはコピーとカットのクリップボード状態を保持する")
  func storesCopyAndCutClipboardState() async throws {
    let provider = ClipboardWorkspaceProvider()
    let browser = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: ".", providerID: provider.id),
      transferQueue: .isolatedForTesting())
    let workspace = FileWorkspaceModel(initialBrowser: browser)
    workspace.activeTab.browser.load()
    await waitForLoading(browser)
    let item = try #require(browser.items.first)
    workspace.activeTab.selectedItemURLs = [item.url]

    workspace.copySelectedItems()

    #expect(workspace.canPasteItems)
    workspace.cutSelectedItems()
    #expect(workspace.canPasteItems)
    #expect(workspace.activeTab.selectedItemLocations == [item.location])
  }

  @Test("共通ワークスペースは別ペインへのコピーを取り消せる")
  func undoesCopyAcrossPanes() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = root.appending(path: "source", directoryHint: .isDirectory)
    let destinationURL = root.appending(path: "destination", directoryHint: .isDirectory)
    let nextURL = root.appending(path: "next", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: nextURL, withIntermediateDirectories: true)
    try Data("転送内容".utf8).write(to: sourceURL.appending(path: "report.txt"))

    let provider = LocalFileProvider()
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let source = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: sourceURL, providerID: provider.id),
      transferQueue: queue)
    let destination = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: destinationURL, providerID: provider.id),
      transferQueue: queue)
    let workspace = FileWorkspaceModel(initialBrowser: source)
    workspace.setShowsSecondaryPane(true)
    workspace.replaceActiveBrowser(with: destination)
    destination.load()
    // FileWorkspaceModel.initが常に2ペイン化(secondaryペイン用のpeerセッション生成)を
    // 行うようになり、このテスト自体の負荷がわずかに増えたため、高負荷実行時に
    // yieldのみのwaitForLoadingでは実時間を稼ぎきれずフレークすることを確認した。
    // sleep併用版へ置き換えて確実に待つ。
    await waitForLoadingWithSleep(destination)

    workspace.activatePane(.secondary)
    // secondaryペインのbrowserはsetShowsSecondaryPane(true)がmakePeerSession()で
    // 複製した別インスタンスであり、sourceの読み込み状態を引き継がない。
    // 明示的にloadしないとitemsが空のままselectedItemURLsが何にも一致せず、
    // 後続のcopySelectedItems()が無言で失敗する。実際に転送元として使われるのも
    // このpeerセッションであり、sourceそのものではないため転送完了もこちらで待つ。
    let peerSource = workspace.activeTab.browser
    peerSource.load()
    await waitForLoadingWithSleep(peerSource)
    let item = try #require(peerSource.items.first)
    workspace.activeTab.selectedItemURLs = [item.url]
    workspace.copySelectedItems()
    workspace.activatePane(.primary)
    workspace.pasteItems()
    await waitForTransfer(peerSource)
    await waitForLoading(peerSource)
    await waitForLoading(destination)
    // isTransferringがfalseに戻った後、非同期のrefreshContents()完了を経てから
    // onCompleted(Undo登録)が呼ばれるため、isLoading監視だけでは開始検知の隙間に
    // 抜けてしまうことがある。Undo可能になったこと自体を直接ポーリングする。
    let undoClock = ContinuousClock()
    let undoDeadline = undoClock.now.advanced(by: .seconds(2))
    while !workspace.canUndoLastTransfer, undoClock.now < undoDeadline {
      try? await Task.sleep(for: .milliseconds(10))
    }

    let copiedFileURL = destinationURL.appending(path: "report.txt")
    #expect(FileManager.default.fileExists(atPath: copiedFileURL.path))
    #expect(workspace.canUndoLastTransfer)

    let nextBrowser = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: nextURL, providerID: provider.id),
      transferQueue: queue)
    workspace.replaceActiveBrowser(with: nextBrowser)
    #expect(destination.items.isEmpty)
    #expect(!destination.hasActiveBrowsingResources)
    #expect(await waitForSubscriberCount(queue, expected: 2) == 2)

    workspace.undoLastTransfer()
    // discardTransferredItemsのisLoading完了待ちもyieldのみでは高負荷下で
    // 実時間を稼げず未完了のままアサーションへ進むことがあるため、
    // waitForTransferと同じyield+sleep併用の待機を使う。
    await waitForLoadingWithSleep(destination)

    #expect(!FileManager.default.fileExists(atPath: copiedFileURL.path))
    #expect(!workspace.canUndoLastTransfer)
  }

  @Test("cutSelectedItems→pasteItemsで別ペインへ実際に移動する(元の場所から消える)")
  func cutPasteMovesItemAcrossPanes() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = root.appending(path: "source", directoryHint: .isDirectory)
    let destinationURL = root.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
    let originalFileURL = sourceURL.appending(path: "delete-me.txt")
    try Data("カット対象".utf8).write(to: originalFileURL)

    let provider = LocalFileProvider()
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let source = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: sourceURL, providerID: provider.id),
      transferQueue: queue)
    let destination = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: destinationURL, providerID: provider.id),
      transferQueue: queue)
    let workspace = FileWorkspaceModel(initialBrowser: source)
    workspace.setShowsSecondaryPane(true)
    workspace.replaceActiveBrowser(with: destination)
    destination.load()
    await waitForLoadingWithSleep(destination)

    workspace.activatePane(.secondary)
    let peerSource = workspace.activeTab.browser
    peerSource.load()
    await waitForLoadingWithSleep(peerSource)
    let item = try #require(peerSource.items.first)
    workspace.activeTab.selectedItemURLs = [item.url]
    workspace.cutSelectedItems()
    workspace.activatePane(.primary)
    workspace.pasteItems()
    await waitForTransfer(peerSource)
    await waitForLoadingWithSleep(peerSource)
    await waitForLoadingWithSleep(destination)

    let movedFileURL = destinationURL.appending(path: "delete-me.txt")
    #expect(FileManager.default.fileExists(atPath: movedFileURL.path))
    #expect(!FileManager.default.fileExists(atPath: originalFileURL.path))
  }

  @Test("任意のローカルフォルダから生成した未ロード宛先セッションへ転送できる")
  func transfersSelectedItemsToUnloadedAdHocLocalDestinationSession() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = root.appending(path: "source", directoryHint: .isDirectory)
    let destinationURL = root.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
    try Data("転送内容".utf8).write(to: sourceURL.appending(path: "report.txt"))

    let provider = LocalFileProvider()
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let source = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: sourceURL, providerID: provider.id),
      transferQueue: queue)
    let workspace = FileWorkspaceModel(initialBrowser: source)
    // initが2ペイン化でpeerセッションを作るため、操作対象はactiveTabのbrowserを使う。
    let activeBrowser = workspace.activeTab.browser
    activeBrowser.load()
    await waitForLoadingWithSleep(activeBrowser)
    let item = try #require(activeBrowser.items.first)
    workspace.activeTab.selectedItemURLs = [item.url]

    let destination = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(directoryURL: destinationURL, providerID: provider.id),
      transferQueue: queue)

    workspace.transferSelectedItems(to: destination, wasMove: false)
    await waitForTransfer(activeBrowser)
    // onCompleted(Undo登録)は転送完了後の非同期refreshを経て呼ばれるため直接ポーリングする。
    let undoClock = ContinuousClock()
    let undoDeadline = undoClock.now.advanced(by: .seconds(2))
    while !workspace.canUndoLastTransfer, undoClock.now < undoDeadline {
      try? await Task.sleep(for: .milliseconds(10))
    }

    let copiedFileURL = destinationURL.appending(path: "report.txt")
    #expect(FileManager.default.fileExists(atPath: copiedFileURL.path))
    #expect(workspace.canUndoLastTransfer)
  }

  @Test("その場生成の未ロード宛先へ転送する前にロードを待ち衝突事前判定を効かせる")
  func loadsAdHocDestinationBeforeTransferringToDetectConflict() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = root.appending(path: "source", directoryHint: .isDirectory)
    let destinationURL = root.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
    try Data("転送内容".utf8).write(to: sourceURL.appending(path: "report.txt"))
    try Data("既存内容".utf8).write(to: destinationURL.appending(path: "report.txt"))

    let provider = LocalFileProvider()
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let source = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: sourceURL, providerID: provider.id),
      transferQueue: queue)
    let workspace = FileWorkspaceModel(initialBrowser: source)
    // initが2ペイン化でpeerセッションを作るため、操作対象はactiveTabのbrowserを使う。
    let activeBrowser = workspace.activeTab.browser
    activeBrowser.load()
    await waitForLoadingWithSleep(activeBrowser)
    let item = try #require(activeBrowser.items.first)
    workspace.activeTab.selectedItemURLs = [item.url]

    // ProviderTransferDestinationCatalog由来の宛先と同じく、一度もload()されていない
    // (itemsが常に空の)その場生成の宛先セッション。
    let destination = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: destinationURL, providerID: provider.id),
      transferQueue: queue)

    workspace.transferSelectedItems(to: destination, wasMove: false)

    let conflictClock = ContinuousClock()
    let conflictDeadline = conflictClock.now.advanced(by: .seconds(2))
    while activeBrowser.pendingTransferConflict == nil, conflictClock.now < conflictDeadline {
      try? await Task.sleep(for: .milliseconds(10))
    }

    #expect(activeBrowser.pendingTransferConflict != nil)
    #expect(activeBrowser.pendingTransferConflict?.destinationName == "report.txt")
  }

  @Test("ドラッグした項目もProviderに関係なく反対側へコピーできる")
  func copiesDroppedItemAcrossPanes() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = root.appending(path: "source", directoryHint: .isDirectory)
    let destinationURL = root.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
    try Data("ドラッグ転送".utf8).write(to: sourceURL.appending(path: "report.txt"))

    let provider = LocalFileProvider()
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let source = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: sourceURL, providerID: provider.id),
      transferQueue: queue)
    let destination = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: destinationURL, providerID: provider.id),
      transferQueue: queue)
    let workspace = FileWorkspaceModel(initialBrowser: source)
    workspace.setShowsSecondaryPane(true)
    workspace.replaceActiveBrowser(with: destination)
    destination.load()
    // FileWorkspaceModel.initが常に2ペイン化(secondaryペイン用のpeerセッション生成)を
    // 行うようになり、このテスト自体の負荷がわずかに増えたため、高負荷実行時に
    // yieldのみのwaitForLoadingでは実時間を稼ぎきれずフレークすることを確認した。
    // sleep併用版へ置き換えて確実に待つ。
    await waitForLoadingWithSleep(destination)
    // secondaryペインのbrowserはmakePeerSession()による別インスタンスで
    // 読み込み状態を引き継がないため、transferDroppedItemsが転送元を検索できるよう
    // 明示的にloadしておく。
    let secondaryBrowser = try #require(workspace.tab(for: .secondary)?.browser)
    secondaryBrowser.load()
    await waitForLoadingWithSleep(secondaryBrowser)

    // 実際に転送元として使われるのはsecondaryBrowser(URL一致で選ばれたペイン側)
    // であり、テストローカルのsourceそのものではないため、参照元も揃える。
    let item = try #require(secondaryBrowser.items.first)
    #expect(workspace.transferDroppedItems([item.url], to: .primary, copyForced: true))
    await waitForTransfer(secondaryBrowser)
    await waitForLoading(destination)

    let copiedFileURL = destinationURL.appending(path: "report.txt")
    #expect(FileManager.default.fileExists(atPath: copiedFileURL.path))
    #expect(
      FileManager.default.fileExists(
        atPath: sourceURL.appending(path: "report.txt").path))
  }

  @Test("サイドバー保存先へのドロップは同一ボリュームで移動する")
  func movesDroppedItemToSidebarDestination() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = root.appending(path: "source", directoryHint: .isDirectory)
    let destinationURL = root.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
    let originalURL = sourceURL.appending(path: "report.txt")
    try Data("サイドバーD&D".utf8).write(to: originalURL)

    let provider = LocalFileProvider()
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let source = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: sourceURL, providerID: provider.id),
      transferQueue: queue)
    let workspace = FileWorkspaceModel(initialBrowser: source)
    let activeBrowser = workspace.activeTab.browser
    activeBrowser.load()
    await waitForLoadingWithSleep(activeBrowser)
    let item = try #require(activeBrowser.items.first)
    let destination = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: destinationURL, providerID: provider.id),
      transferQueue: queue)
    let trace = DropPreparationTrace(
      itemCount: 1, destinationKind: .sidebarSavedLocation)

    #expect(
      workspace.transferDroppedItems(
        [item.url], to: destination, copyForced: false, trace: trace))

    let movedURL = destinationURL.appending(path: "report.txt")
    await waitUntil("サイドバー保存先への移動が完了しなかった") {
      FileManager.default.fileExists(atPath: movedURL.path)
        && !FileManager.default.fileExists(atPath: originalURL.path)
    }
    #expect(FileManager.default.fileExists(atPath: movedURL.path))
    #expect(!FileManager.default.fileExists(atPath: originalURL.path))
    #expect(trace.measurement.destinationListingCount == 1)
    #expect(trace.outcome == .enqueued)
  }

  @Test("Option付きのサイドバー保存先ドロップはコピーを強制する")
  func copiesDroppedItemToSidebarDestinationWhenOptionIsPressed() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = root.appending(path: "source", directoryHint: .isDirectory)
    let destinationURL = root.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
    let originalURL = sourceURL.appending(path: "report.txt")
    try Data("サイドバーD&D".utf8).write(to: originalURL)

    let provider = LocalFileProvider()
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let source = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: sourceURL, providerID: provider.id),
      transferQueue: queue)
    let workspace = FileWorkspaceModel(initialBrowser: source)
    let activeBrowser = workspace.activeTab.browser
    activeBrowser.load()
    await waitForLoadingWithSleep(activeBrowser)
    let item = try #require(activeBrowser.items.first)
    let destination = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: destinationURL, providerID: provider.id),
      transferQueue: queue)

    #expect(
      workspace.transferDroppedItems(
        [item.url], to: destination, copyForced: true))

    let copiedURL = destinationURL.appending(path: "report.txt")
    await waitUntil("サイドバー保存先へのコピーが完了しなかった") {
      FileManager.default.fileExists(atPath: copiedURL.path)
    }
    #expect(FileManager.default.fileExists(atPath: copiedURL.path))
    #expect(FileManager.default.fileExists(atPath: originalURL.path))
  }

  @Test("現在表示中と同じ場所へのサイドバードロップを拒否する")
  func rejectsSidebarDropToCurrentDirectory() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("自己ドロップ".utf8).write(to: root.appending(path: "report.txt"))

    let provider = LocalFileProvider()
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let source = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: root, providerID: provider.id),
      transferQueue: queue)
    let workspace = FileWorkspaceModel(initialBrowser: source)
    let activeBrowser = workspace.activeTab.browser
    activeBrowser.load()
    await waitForLoadingWithSleep(activeBrowser)
    let item = try #require(activeBrowser.items.first)
    let duplicateDestination = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: root, providerID: provider.id),
      transferQueue: queue)

    #expect(
      !workspace.transferDroppedItems(
        [item.url], to: duplicateDestination, copyForced: false))
  }

  @Test("サイドバー保存先を列挙して同名衝突を転送前に確認する")
  func detectsConflictBeforeSidebarDropTransfer() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = root.appending(path: "source", directoryHint: .isDirectory)
    let destinationURL = root.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
    try Data("転送内容".utf8).write(to: sourceURL.appending(path: "report.txt"))
    try Data("既存内容".utf8).write(to: destinationURL.appending(path: "report.txt"))

    let provider = LocalFileProvider()
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let source = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: sourceURL, providerID: provider.id),
      transferQueue: queue)
    let workspace = FileWorkspaceModel(initialBrowser: source)
    let activeBrowser = workspace.activeTab.browser
    activeBrowser.load()
    await waitForLoadingWithSleep(activeBrowser)
    let item = try #require(activeBrowser.items.first)
    let destination = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: destinationURL, providerID: provider.id),
      transferQueue: queue)

    #expect(
      workspace.transferDroppedItems(
        [item.url], to: destination, copyForced: true))
    await waitUntil("サイドバーD&Dの衝突確認が表示されなかった") {
      activeBrowser.pendingTransferConflict != nil
    }

    #expect(activeBrowser.pendingTransferConflict?.destinationName == "report.txt")
    #expect(
      try String(contentsOf: destinationURL.appending(path: "report.txt"), encoding: .utf8)
        == "既存内容")
  }

  @Test("ドロップ由来の移動は転送後に元の場所からファイルが消える")
  func movesDroppedItemAcrossPanes() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = root.appending(path: "source", directoryHint: .isDirectory)
    let destinationURL = root.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
    try Data("ドラッグ転送".utf8).write(to: sourceURL.appending(path: "report.txt"))

    let provider = LocalFileProvider()
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let source = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: sourceURL, providerID: provider.id),
      transferQueue: queue)
    let destination = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: destinationURL, providerID: provider.id),
      transferQueue: queue)
    let workspace = FileWorkspaceModel(initialBrowser: source)
    workspace.setShowsSecondaryPane(true)
    workspace.replaceActiveBrowser(with: destination)
    destination.load()
    // FileWorkspaceModel.initが常に2ペイン化(secondaryペイン用のpeerセッション生成)を
    // 行うようになり、このテスト自体の負荷がわずかに増えたため、高負荷実行時に
    // yieldのみのwaitForLoadingでは実時間を稼ぎきれずフレークすることを確認した。
    // sleep併用版へ置き換えて確実に待つ。
    await waitForLoadingWithSleep(destination)
    // secondaryペインのbrowserはmakePeerSession()による別インスタンスで
    // 読み込み状態を引き継がないため、transferDroppedItemsが転送元を検索できるよう
    // 明示的にloadしておく。
    let secondaryBrowser = try #require(workspace.tab(for: .secondary)?.browser)
    secondaryBrowser.load()
    await waitForLoadingWithSleep(secondaryBrowser)

    // 実際に転送元として使われるのはsecondaryBrowser(URL一致で選ばれたペイン側)
    // であり、テストローカルのsourceそのものではないため、参照元も揃える。
    let item = try #require(secondaryBrowser.items.first)

    let shouldMove = workspace.shouldMoveDroppedItems([item.url], to: .primary)
    let started = workspace.transferDroppedItems([item.url], to: .primary, wasMove: shouldMove)

    #expect(shouldMove)
    #expect(started)
    await waitForTransfer(secondaryBrowser)
    await waitForLoadingWithSleep(destination)
    let movedURL = destinationURL.appending(path: "report.txt")
    #expect(FileManager.default.fileExists(atPath: movedURL.path))
    // 移動なので元の場所からは消える。転送完了後の再列挙を待って確認する。
    let removalClock = ContinuousClock()
    let removalDeadline = removalClock.now.advanced(by: .seconds(2))
    while FileManager.default.fileExists(
      atPath: sourceURL.appending(path: "report.txt").path),
      removalClock.now < removalDeadline
    {
      try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(!FileManager.default.fileExists(atPath: sourceURL.appending(path: "report.txt").path))
  }

  @Test("展開中の複数子項目をフォルダ行へドロップしてその中へ移動できる")
  func movesExpandedChildrenIntoDroppedFolder() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceFolderURL = root.appending(path: "source", directoryHint: .isDirectory)
    let destinationFolderURL = root.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: sourceFolderURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: destinationFolderURL, withIntermediateDirectories: true)
    let childURLs = ["child-1.txt", "child-2.txt"].map {
      sourceFolderURL.appending(path: $0)
    }
    for childURL in childURLs {
      try Data("展開子ドラッグ".utf8).write(to: childURL)
    }

    let provider = LocalFileProvider()
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let browser = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: root, providerID: provider.id),
      transferQueue: queue)
    let workspace = FileWorkspaceModel(initialBrowser: browser)
    browser.load()
    await waitForLoadingWithSleep(browser)
    let sourceFolder = try #require(browser.items.first { $0.url == sourceFolderURL })
    let destinationFolder = try #require(browser.items.first { $0.url == destinationFolderURL })
    browser.toggleExpansion(of: sourceFolder)
    let expansionClock = ContinuousClock()
    let expansionDeadline = expansionClock.now.advanced(by: .seconds(2))
    while childURLs.contains(where: { childURL in
      !browser.selectableItems.contains(where: { $0.url == childURL })
    }),
      expansionClock.now < expansionDeadline
    {
      try? await Task.sleep(for: .milliseconds(10))
    }
    let children = childURLs.compactMap { childURL in
      browser.selectableItems.first { $0.url == childURL }
    }
    #expect(children.count == childURLs.count)
    let trace = DropPreparationTrace(itemCount: children.count, destinationKind: .folderRow)
    let snapshotBuildCountBeforeDrop = browser.selectableItemsSnapshotBuildCount

    #expect(
      workspace.transferDroppedItems(
        children.map(\.url),
        into: destinationFolder,
        in: .primary,
        copyForced: false,
        trace: trace))
    #expect(browser.selectableItemsSnapshotBuildCount == snapshotBuildCountBeforeDrop)

    let movedURLs = children.map { destinationFolderURL.appending(path: $0.name) }
    let moveClock = ContinuousClock()
    let moveDeadline = moveClock.now.advanced(by: .seconds(2))
    while movedURLs.contains(where: { !FileManager.default.fileExists(atPath: $0.path) }),
      moveClock.now < moveDeadline
    {
      try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(movedURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    #expect(childURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    #expect(trace.measurement.resolutionPassCount == 1)
    #expect(trace.measurement.resolvedItemCount == children.count)
    #expect(trace.measurement.volumeResourceLookupCount <= children.count + 1)
    #expect(trace.measurement.temporarySessionCount == 1)
    #expect(trace.measurement.temporarySessionTransferSubscriptionCount == 0)
    #expect(trace.measurement.temporarySessionBrowsingResourceCount == 0)
    #expect(trace.measurement.destinationListingCount == 1)
    #expect(trace.measurement.collisionPassCount == 1)
    #expect(trace.measurement.collisionNameLookupCount == children.count)
    #expect(trace.measurement.collisionSourceItemCount == children.count)
    #expect(trace.measurement.enqueuedSourceGroupCount == 1)
    #expect(trace.outcome == .enqueued)
  }

  @Test("転送元1000件と転送先1万件の衝突なしを線形回数で判定する")
  func measuresWorstCaseTransferCollisionLookup() {
    let sourceItems = (0..<1_000).map { index in
      FileItem(
        url: URL(filePath: "/tmp/source-\(index).txt"),
        isDirectory: false)
    }
    let destinationItems = (0..<10_000).map { index in
      FileItem(
        url: URL(filePath: "/tmp/destination-\(index).txt"),
        isDirectory: false)
    }
    let clock = ContinuousClock()
    var collision: (item: FileItem?, nameLookupCount: Int)?

    let duration = clock.measure {
      collision = FileBrowserSession.firstTransferConflict(
        in: sourceItems,
        destinationItems: destinationItems)
    }

    #expect(collision?.item == nil)
    #expect(
      collision?.nameLookupCount ?? .max
        <= sourceItems.count + destinationItems.count)
    print(
      "PKPane性能計測: D&D衝突なし1000×1万 "
        + "\(Self.milliseconds(duration))ms/"
        + "\(collision?.nameLookupCount ?? 0)回照合")
  }

  @Test("1万件一覧の選択URL往復を1フレーム以内に完了する")
  func selectsItemInLargeListingWithinOneFrame() async throws {
    let provider = LargeSelectionWorkspaceProvider(itemCount: 10_000)
    let browser = FileBrowserSession(
      provider: provider, initialLocation: provider.root, transferQueue: .isolatedForTesting())
    let tab = FileWorkspaceTab(browser: browser)
    browser.load()
    await waitUntil(timeout: .seconds(10), "1万件一覧の読込が期限内に完了しなかった") {
      browser.items.count == 10_000 && !browser.isLoading
    }
    let targetURL = try #require(browser.items.last?.url)
    #expect(tab.selectedItemURLs.isEmpty)
    #expect(browser.selectableItemsSnapshotBuildCount == 0)
    let clock = ContinuousClock()
    var selectedURLs = Set<URL>()

    let duration = clock.measure {
      tab.selectedItemURLs = [targetURL]
      selectedURLs = tab.selectedItemURLs
    }

    print("PKPane性能計測: 1万件一覧の選択URL往復 \(Self.milliseconds(duration))ms")
    #expect(selectedURLs == [targetURL])
    #expect(browser.selectableItemsSnapshotBuildCount == 1)
    #expect(duration < .milliseconds(16))
  }

  @Test("展開中の子項目を選択してコピーとペーストを実行できる")
  func copiesSelectedExpandedChildThroughClipboard() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = root.appending(path: "source", directoryHint: .isDirectory)
    let treeFolderURL = sourceURL.appending(path: "tree", directoryHint: .isDirectory)
    let destinationURL = root.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: treeFolderURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
    let childURL = treeFolderURL.appending(path: "child.txt")
    try Data("展開子コピー".utf8).write(to: childURL)

    let provider = LocalFileProvider()
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let source = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: sourceURL, providerID: provider.id),
      transferQueue: queue)
    let destination = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: destinationURL, providerID: provider.id),
      transferQueue: queue)
    let workspace = FileWorkspaceModel(initialBrowser: source)
    source.load()
    await waitForLoadingWithSleep(source)
    let treeFolder = try #require(source.items.first { $0.url == treeFolderURL })
    source.toggleExpansion(of: treeFolder)
    let expansionClock = ContinuousClock()
    let expansionDeadline = expansionClock.now.advanced(by: .seconds(2))
    while !source.selectableItems.contains(where: { $0.name == "child.txt" }),
      expansionClock.now < expansionDeadline
    {
      try? await Task.sleep(for: .milliseconds(10))
    }
    let child = try #require(source.selectableItems.first { $0.name == "child.txt" })
    workspace.activeTab.selectedItemURLs = [child.url]

    workspace.copySelectedItems()
    workspace.replaceActiveBrowser(with: destination)
    destination.load()
    await waitForLoadingWithSleep(destination)
    workspace.pasteItems()

    let copiedURL = destinationURL.appending(path: child.name)
    let copyClock = ContinuousClock()
    let copyDeadline = copyClock.now.advanced(by: .seconds(2))
    while !FileManager.default.fileExists(atPath: copiedURL.path), copyClock.now < copyDeadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(FileManager.default.fileExists(atPath: copiedURL.path))
    #expect(FileManager.default.fileExists(atPath: childURL.path))
  }

  @Test("ドロップURLがどのペインの表示項目とも一致しなければ転送可能と判定しない")
  func reportsDroppedItemsUntransferableForUnknownURLs() {
    let workspace = FileWorkspaceModel(initialBrowser: browser())

    let unknown = URL(fileURLWithPath: "/nonexistent/outside.txt")

    #expect(!workspace.canTransferDroppedItems([unknown], to: .primary))
    #expect(!workspace.shouldMoveDroppedItems([unknown], to: .primary))
  }

  @Test("SFTP系Providerへのドロップは同一ボリュームでもコピーを選ぶ")
  func doesNotMoveDroppedItemToRemoteProvider() async throws {
    let transferQueue = TransferQueue.isolatedForTesting()
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = root.appending(path: "source", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
    try Data("ドラッグ転送".utf8).write(to: sourceURL.appending(path: "report.txt"))

    let provider = LocalFileProvider()
    let source = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: sourceURL, providerID: provider.id),
      transferQueue: transferQueue)
    let workspace = FileWorkspaceModel(initialBrowser: source)
    let remoteProvider = RemoteWorkspaceProvider()
    workspace.replaceActiveBrowser(
      with: FileBrowserSession(
        provider: remoteProvider,
        initialLocation: FileLocation(remotePath: "/projects", providerID: remoteProvider.id),
        transferQueue: transferQueue))

    let secondaryBrowser = try #require(workspace.tab(for: .secondary)?.browser)
    secondaryBrowser.load()
    await waitForLoadingWithSleep(secondaryBrowser)
    let item = try #require(secondaryBrowser.items.first)

    #expect(!workspace.shouldMoveDroppedItems([item.url], to: .primary))
  }

  @Test("ドロップURLが反対ペインの表示項目に一致すれば転送可能と判定する")
  func reportsDroppedItemsTransferableForVisiblePaneItems() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = root.appending(path: "source", directoryHint: .isDirectory)
    let destinationURL = root.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
    try Data("ドラッグ転送".utf8).write(to: sourceURL.appending(path: "report.txt"))

    let provider = LocalFileProvider()
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let source = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: sourceURL, providerID: provider.id),
      transferQueue: queue)
    let destination = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: destinationURL, providerID: provider.id),
      transferQueue: queue)
    let workspace = FileWorkspaceModel(initialBrowser: source)
    workspace.setShowsSecondaryPane(true)
    workspace.replaceActiveBrowser(with: destination)
    destination.load()
    await waitForLoadingWithSleep(destination)
    let secondaryBrowser = try #require(workspace.tab(for: .secondary)?.browser)
    secondaryBrowser.load()
    await waitForLoadingWithSleep(secondaryBrowser)

    let item = try #require(secondaryBrowser.items.first)

    #expect(workspace.canTransferDroppedItems([item.url], to: .primary))
  }

  @Test("切断した接続のタブだけをワークスペースから外す")
  func removesOnlyDisconnectedProviderTabs() throws {
    let remoteProvider = RemoteWorkspaceProvider()
    let remoteBrowser = FileBrowserSession(
      provider: remoteProvider,
      initialLocation: FileLocation(remotePath: "/projects", providerID: remoteProvider.id),
      transferQueue: .isolatedForTesting())
    let workspace = FileWorkspaceModel(initialBrowser: remoteBrowser)
    workspace.setShowsSecondaryPane(true)
    workspace.replaceActiveBrowser(with: browser())
    let connectionID = try #require(remoteProvider.connectionID)

    let isEmpty = workspace.removeTabs(for: connectionID)

    #expect(!isEmpty)
    #expect(workspace.tabs.count == 1)
    #expect(workspace.activeTab.browser.currentLocation.providerID == .local)
    #expect(!workspace.showsSecondaryPane)
  }

  @Test("接続の全タブを除去した直後も操作対象タブを参照できる")
  func activeTabDoesNotTrapAfterRemovingAllTabsOfConnection() throws {
    let provider = RemoteWorkspaceProvider()
    let remoteBrowser = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: "/projects", providerID: provider.id),
      transferQueue: .isolatedForTesting())
    let workspace = FileWorkspaceModel(initialBrowser: remoteBrowser)
    let secondaryTab = try #require(workspace.tab(for: .secondary))
    let connectionID = try #require(provider.connectionID)
    workspace.closeTab(id: secondaryTab.id)
    let activeTabID = workspace.activeTab.id

    let isEmpty = workspace.removeTabs(for: connectionID)

    #expect(isEmpty)
    #expect(workspace.activeTab.id == activeTabID)
  }

  @Test("空のワークスペースにタブを追加すると操作対象になる")
  func activeTabReflectsNewTabAfterRecoveringFromEmpty() throws {
    let provider = RemoteWorkspaceProvider()
    let remoteBrowser = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: "/projects", providerID: provider.id),
      transferQueue: .isolatedForTesting())
    let workspace = FileWorkspaceModel(initialBrowser: remoteBrowser)
    let secondaryTab = try #require(workspace.tab(for: .secondary))
    let connectionID = try #require(provider.connectionID)
    workspace.closeTab(id: secondaryTab.id)
    #expect(workspace.removeTabs(for: connectionID))

    workspace.setShowsSecondaryPane(true)

    let newTab = try #require(workspace.tabs.first)
    #expect(workspace.activeTab.id == newTab.id)
  }

  @Test("注入した転送キューから中断転送を復元する")
  func restoresInterruptedTransfersFromInjectedQueue() async throws {
    let provider = RemoteWorkspaceProvider()
    let sourceLocation = FileLocation(remotePath: "./source", providerID: provider.id)
    let destinationLocation = FileLocation(remotePath: "./destination", providerID: provider.id)
    let item = FileItem(
      remotePath: "./source/report.txt",
      url: URL(fileURLWithPath: "/report.txt"),
      providerID: provider.id,
      isDirectory: false,
      size: 10)
    var interruptedJob = TransferJob(
      kind: .copy,
      items: [item],
      sourceProviderID: provider.id,
      destinationProviderID: provider.id,
      destination: destinationLocation)
    interruptedJob.state = .interrupted
    interruptedJob.errorDescription = "テスト用の中断理由"
    let store = InMemoryTransferJobStore()
    try store.save([interruptedJob])
    let queue = TransferQueue(store: store, maximumConcurrentTransfers: 1)
    let sourceBrowser = FileBrowserSession(
      provider: provider,
      initialLocation: sourceLocation,
      transferQueue: queue)

    #expect((await TransferQueue.shared.allJobs()).isEmpty)

    let workspace = FileWorkspaceModel(initialBrowser: sourceBrowser)
    workspace.activatePane(.secondary)
    let destinationBrowser = FileBrowserSession(
      provider: provider,
      initialLocation: destinationLocation,
      transferQueue: queue)
    workspace.replaceActiveBrowser(with: destinationBrowser)

    await waitUntil("注入した転送キューの中断ジョブが復元されなかった") {
      sourceBrowser.canRetryLastTransfer
        && sourceBrowser.errorMessage == interruptedJob.errorDescription
    }
    #expect((await TransferQueue.shared.allJobs()).isEmpty)
  }

  @Test("中断転送の復元は転送元ロケーションが一致するタブにだけ行い無関係なペインを誤爆しない")
  func restoresInterruptedTransferOnlyToMatchingSourceLocation() {
    let transferQueue = TransferQueue.isolatedForTesting()
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let sourceURL = root.appending(path: "source", directoryHint: .isDirectory)
    let unrelatedURL = root.appending(path: "unrelated", directoryHint: .isDirectory)
    let destinationURL = root.appending(path: "destination", directoryHint: .isDirectory)
    let provider = LocalFileProvider()
    // ローカルProviderは全タブでproviderIDを共有するため、意図的に無関係なタブを
    // 先頭に置き、provider一致だけでは誤って選ばれてしまうことを検証する。
    let unrelatedBrowser = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: unrelatedURL, providerID: provider.id),
      transferQueue: transferQueue)
    let sourceBrowser = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: sourceURL, providerID: provider.id),
      transferQueue: transferQueue)
    let destinationBrowser = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: destinationURL, providerID: provider.id),
      transferQueue: transferQueue)
    let job = TransferJob(
      kind: .copy,
      items: [
        FileItem(
          url: sourceURL.appending(path: "report.txt"), providerID: provider.id,
          isDirectory: false, size: 10)
      ],
      sourceProviderID: provider.id,
      destinationProviderID: provider.id,
      destination: FileLocation(localURL: destinationURL, providerID: provider.id))
    var interruptedJob = job
    interruptedJob.state = .interrupted

    let matches = FileWorkspaceModel.matchedRestorableTransfers(
      jobs: [interruptedJob],
      browsers: [unrelatedBrowser, sourceBrowser, destinationBrowser])

    #expect(matches.count == 1)
    #expect(matches.first?.source === sourceBrowser)
    #expect(matches.first?.destination === destinationBrowser)

    for match in matches {
      match.source.restoreInterruptedTransfer(match.job, to: match.destination)
    }
    #expect(unrelatedBrowser.errorMessage == nil)
    #expect(sourceBrowser.errorMessage != nil)
  }

  @Test("pausedジョブをペインへ対応付けられない場合は再開方法を案内する")
  func explainsHowToResumeWhenPaneLocationsDoNotMatch() throws {
    let workspace = FileWorkspaceModel(initialBrowser: browser())
    let activeBrowser = try #require(workspace.tab(for: workspace.activePane)?.browser)
    let providerID = activeBrowser.providerID
    let item = FileItem(
      url: URL(fileURLWithPath: "/tmp/resume-source/report.txt"),
      providerID: providerID,
      isDirectory: false,
      size: 10)
    var job = TransferJob(
      kind: .copy,
      items: [item],
      sourceProviderID: providerID,
      destinationProviderID: providerID,
      destination: FileLocation(
        localURL: URL(fileURLWithPath: "/tmp/resume-destination"), providerID: providerID))
    job.state = .paused

    #expect(!workspace.resumeTransferJob(job))
    #expect(activeBrowser.errorMessage?.contains("ペインを元の場所に合わせて") == true)
  }

  @Test(".failed/.cancelledのジョブは復元スキャン対象外(転送バーの再試行動線に委ねる)")
  func excludesNonInterruptedJobsFromRestoreScan() {
    let transferQueue = TransferQueue.isolatedForTesting()
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let sourceURL = root.appending(path: "source", directoryHint: .isDirectory)
    let destinationURL = root.appending(path: "destination", directoryHint: .isDirectory)
    let provider = LocalFileProvider()
    let sourceBrowser = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: sourceURL, providerID: provider.id),
      transferQueue: transferQueue)
    let destinationBrowser = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: destinationURL, providerID: provider.id),
      transferQueue: transferQueue)
    let baseJob = TransferJob(
      kind: .copy,
      items: [
        FileItem(
          url: sourceURL.appending(path: "report.txt"), providerID: provider.id,
          isDirectory: false, size: 10)
      ],
      sourceProviderID: provider.id,
      destinationProviderID: provider.id,
      destination: FileLocation(localURL: destinationURL, providerID: provider.id))
    var failedJob = baseJob
    failedJob.state = .failed
    var cancelledJob = baseJob
    cancelledJob.state = .cancelled

    let matches = FileWorkspaceModel.matchedRestorableTransfers(
      jobs: [failedJob, cancelledJob],
      browsers: [sourceBrowser, destinationBrowser])

    #expect(matches.isEmpty)
  }

  @Test("転送元ロケーションを導出できないジョブは復元対象から外す")
  func excludesJobsWithUndeliverableSourceLocation() {
    let transferQueue = TransferQueue.isolatedForTesting()
    let remoteProvider = RemoteWorkspaceProvider()
    let destinationURL = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let sourceBrowser = FileBrowserSession(
      provider: remoteProvider,
      initialLocation: FileLocation(remotePath: ".", providerID: remoteProvider.id),
      transferQueue: transferQueue)
    let destinationBrowser = FileBrowserSession(
      provider: LocalFileProvider(),
      initialLocation: FileLocation(localURL: destinationURL),
      transferQueue: transferQueue)
    var job = TransferJob(
      kind: .copy,
      // アイテムの場所自体がルート("."）だと親ディレクトリを導出できない
      // (FileLocation.deletingLastPathComponentがnilを返す、通常は起こらない
      // 壊れたデータを想定した安全側フォールバック)。
      items: [
        FileItem(
          remotePath: ".", url: URL(fileURLWithPath: "/"),
          providerID: remoteProvider.id, isDirectory: true, size: nil)
      ],
      sourceProviderID: remoteProvider.id,
      destinationProviderID: .local,
      destination: FileLocation(localURL: destinationURL))
    job.state = .interrupted

    let matches = FileWorkspaceModel.matchedRestorableTransfers(
      jobs: [job], browsers: [sourceBrowser, destinationBrowser])

    #expect(matches.isEmpty)
  }

  private func waitForLoading(_ browser: FileBrowserSession) async {
    await waitUntil("isLoadingが期限内にfalseにならなかった") {
      !browser.isLoading
    }
  }

  private func waitForLoadingWithSleep(_ browser: FileBrowserSession) async {
    await waitUntil("isLoadingが期限内にfalseにならなかった(sleep版)") {
      !browser.isLoading
    }
  }

  /// 転送UI一元化以降、転送中に立つのはisLoadingではなくisTransferringのため、
  /// 転送完了待ちには専用のヘルパーを使う。開始が次のRunLoopへ回ることがあるため
  /// 立ち上がりを短時間観測してから、完了(falseに戻る)まで実時間を確保して待つ。
  private func waitForTransfer(_ browser: FileBrowserSession) async {
    for _ in 0..<20 {
      if browser.isTransferring { break }
      await Task.yield()
    }
    await waitUntil("転送(isTransferring)が期限内に完了しなかった") {
      !browser.isTransferring
    }
  }

  private func waitForSubscriberCount(
    _ queue: TransferQueue, expected: Int
  ) async -> Int {
    var lastCount = 0
    await waitUntil("購読者数が期限内に期待値にならなかった") {
      lastCount = await queue.updateSubscriberCount
      return lastCount == expected
    }
    return lastCount
  }

  private static func milliseconds(_ duration: Duration) -> String {
    let components = duration.components
    let seconds = Double(components.seconds) * 1_000
    let attoseconds = Double(components.attoseconds) / 1_000_000_000_000_000
    return String(format: "%.1f", seconds + attoseconds)
  }

  private func browser() -> FileBrowserSession {
    let provider = LocalFileProvider()
    let location = FileLocation(localURL: URL(fileURLWithPath: "/tmp", isDirectory: true))
    return FileBrowserSession(
      provider: provider, initialLocation: location, transferQueue: .isolatedForTesting())
  }
}

private struct RemoteWorkspaceProvider: FileBrowserProvider {
  let id = FileProviderID(rawValue: "workspace-test-remote")
  let connectionID: FileProviderConnectionID? = FileProviderConnectionID(
    rawValue: "workspace-test-connection")
  let capabilities: FileProviderCapabilities = [.read]

  func contents(of _: FileLocation) async throws -> [FileItem] { [] }

  func parent(of _: FileLocation) -> FileLocation? { nil }

  func breadcrumbs(
    for location: FileLocation,
    constrainedTo _: FileLocation?
  ) -> [FileBrowserBreadcrumb] {
    [FileBrowserBreadcrumb(location: location, name: "Remote")]
  }
}

private struct ClipboardWorkspaceProvider: FileBrowserProvider {
  let id = FileProviderID(rawValue: "workspace-test-clipboard")
  let connectionID: FileProviderConnectionID? = nil
  let capabilities: FileProviderCapabilities = [.read]

  func contents(of _: FileLocation) async throws -> [FileItem] {
    [
      FileItem(
        remotePath: "./report.txt",
        url: URL(fileURLWithPath: "/report.txt"),
        providerID: id,
        isDirectory: false)
    ]
  }

  func parent(of _: FileLocation) -> FileLocation? { nil }

  func breadcrumbs(
    for _: FileLocation,
    constrainedTo _: FileLocation?
  ) -> [FileBrowserBreadcrumb] { [] }
}

private struct HiddenItemsWorkspaceProvider: FileBrowserProvider {
  let id = FileProviderID(rawValue: "workspace-test-hidden-items")
  let connectionID: FileProviderConnectionID? = nil
  let capabilities: FileProviderCapabilities = [.read]

  func contents(of location: FileLocation) async throws -> [FileItem] {
    try await contents(of: location, includingHidden: false)
  }

  func contents(of _: FileLocation, includingHidden: Bool) async throws -> [FileItem] {
    var items = [
      FileItem(
        remotePath: "/next/visible.txt",
        url: URL(fileURLWithPath: "/visible.txt"),
        providerID: id,
        isDirectory: false)
    ]
    if includingHidden {
      items.append(
        FileItem(
          remotePath: "/next/.hidden.txt",
          url: URL(fileURLWithPath: "/.hidden.txt"),
          providerID: id,
          isDirectory: false))
    }
    return items
  }

  func parent(of _: FileLocation) -> FileLocation? { nil }

  func breadcrumbs(
    for _: FileLocation,
    constrainedTo _: FileLocation?
  ) -> [FileBrowserBreadcrumb] { [] }
}

private final class CountingWorkspaceProvider: FileBrowserProvider, @unchecked Sendable {
  let id = FileProviderID(rawValue: "workspace-test-counting")
  let connectionID: FileProviderConnectionID? = nil
  let capabilities: FileProviderCapabilities = [.read]
  private let lock = NSLock()
  private var count = 0

  var contentsCallCount: Int {
    lock.withLock { count }
  }

  func contents(of _: FileLocation) async throws -> [FileItem] {
    lock.withLock { count += 1 }
    return []
  }

  func parent(of _: FileLocation) -> FileLocation? { nil }

  func breadcrumbs(
    for _: FileLocation,
    constrainedTo _: FileLocation?
  ) -> [FileBrowserBreadcrumb] { [] }
}

private struct LargeSelectionWorkspaceProvider: FileBrowserProvider {
  let id = FileProviderID(rawValue: "workspace-test-large-selection")
  let connectionID: FileProviderConnectionID? = nil
  let capabilities: FileProviderCapabilities = [.read]
  let items: [FileItem]
  var root: FileLocation { FileLocation(remotePath: "/root", providerID: id) }

  init(itemCount: Int) {
    let providerID = FileProviderID(rawValue: "workspace-test-large-selection")
    items = (0..<itemCount).map { index in
      let path = "/root/item-\(index).txt"
      return FileItem(
        remotePath: path,
        url: URL(string: "workspace-test-large-selection://host\(path)")!,
        providerID: providerID,
        isDirectory: false,
        size: 1,
        modifiedAt: Date(timeIntervalSince1970: 1),
        tags: [])
    }
  }

  func contents(of _: FileLocation) async throws -> [FileItem] { items }

  func parent(of _: FileLocation) -> FileLocation? { nil }

  func breadcrumbs(
    for _: FileLocation,
    constrainedTo _: FileLocation?
  ) -> [FileBrowserBreadcrumb] { [] }
}
