import Foundation
import Observation

enum FileWorkspaceUndoKind: Equatable, Sendable {
  case transfer
  case batchRename
}

@Observable
@MainActor
final class FileWorkspaceTab: Identifiable {
  let id: UUID
  var browser: FileBrowserSession
  private(set) var sortState: FileListSortState
  private(set) var viewMode: FileBrowserViewMode
  private(set) var selectedItemLocations: Set<FileLocation> = []
  private var selectedItemURLsStorage: Set<URL> = []

  init(
    id: UUID = UUID(),
    browser: FileBrowserSession,
    sortState: FileListSortState = FileListSortState(order: .name, ascending: true),
    viewMode: FileBrowserViewMode = .list
  ) {
    self.id = id
    self.browser = browser
    self.sortState = sortState
    self.viewMode =
      FileBrowserViewMode.selectableCases.contains(viewMode) ? viewMode : .list
    browser.setSearchSortOrder(sortState.order, ascending: sortState.ascending)
  }

  var title: String {
    browser.currentPathDescription
  }

  var selectedItemURLs: Set<URL> {
    get {
      guard !selectedItemURLsStorage.isEmpty else { return [] }
      let snapshot = browser.selectableItemsSnapshot
      return Set(
        selectedItemURLsStorage.filter { url in
          guard let location = snapshot.item(for: url)?.location else { return false }
          return selectedItemLocations.contains(location)
        })
    }
    set {
      guard !newValue.isEmpty else {
        selectedItemLocations = []
        selectedItemURLsStorage = []
        return
      }
      let snapshot = browser.selectableItemsSnapshot
      let items = newValue.compactMap { snapshot.item(for: $0) }
      selectedItemLocations = Set(items.map(\.location))
      selectedItemURLsStorage = Set(items.map(\.url))
    }
  }

  @discardableResult
  func selectRevealedItem(
    for request: FileItemRevealRequest,
    visibleItemURLs: Set<URL>
  ) -> Bool {
    guard visibleItemURLs.contains(request.itemURL) else { return false }
    selectedItemURLs = [request.itemURL]
    return selectedItemURLs == [request.itemURL]
  }

  func duplicated() -> FileWorkspaceTab {
    FileWorkspaceTab(browser: browser.makePeerSession(), sortState: sortState, viewMode: viewMode)
  }

  var sortOrder: FileItemSortOrder { sortState.order }
  var sortAscending: Bool { sortState.ascending }

  func setSortOrder(_ order: FileItemSortOrder) {
    guard order != sortState.order else { return }
    sortState = FileListSortState(order: order, ascending: sortState.ascending)
    browser.setSearchSortOrder(sortState.order, ascending: sortState.ascending)
  }

  func toggleSortDirection() {
    sortState = FileListSortState(order: sortState.order, ascending: !sortState.ascending)
    browser.setSearchSortOrder(sortState.order, ascending: sortState.ascending)
  }

  func applySortRequest(_ requestedOrder: FileItemSortOrder) {
    let nextState = sortState.applying(requestedOrder: requestedOrder)
    guard nextState != sortState else { return }
    sortState = nextState
    browser.setSearchSortOrder(sortState.order, ascending: sortState.ascending)
  }

  func setViewMode(_ viewMode: FileBrowserViewMode) {
    guard FileBrowserViewMode.selectableCases.contains(viewMode) else { return }
    self.viewMode = viewMode
  }
}

@Observable
@MainActor
final class FileWorkspaceModel {
  typealias RemoteActivationHandler =
    @MainActor (
      _ location: WorkspaceLocationState,
      _ completion: @escaping @MainActor (FileBrowserSession?) -> Void
    ) -> Void

  private enum ClipboardOperation: Equatable {
    case copy
    case move
  }

  private struct ClipboardContents {
    let operation: ClipboardOperation
    let items: [FileItem]
    let source: FileBrowserSession
    let isRecentOrigin: Bool
  }

  private typealias DroppedItemsBySource =
    [ObjectIdentifier: (source: FileBrowserSession, items: [FileItem])]

  private struct TransferUndo {
    let source: FileBrowserSession
    let destination: FileBrowserSession
    let items: [FileItem]
    let wasMove: Bool
    var originalNames: [FileLocation: String] = [:]
  }

  private struct BatchRenameUndo {
    let browser: FileBrowserSession
    let successes: [BatchRenameSuccess]
  }

  private enum LastUndo {
    case transfer(TransferUndo)
    case transferGroup([TransferUndo])
    case batchRename(BatchRenameUndo)

    var referencedBrowsers: [FileBrowserSession] {
      switch self {
      case .transfer(let undo): [undo.source, undo.destination]
      case .transferGroup(let undos): undos.flatMap { [$0.source, $0.destination] }
      case .batchRename(let undo): [undo.browser]
      }
    }

    var kind: FileWorkspaceUndoKind {
      switch self {
      case .transfer, .transferGroup: .transfer
      case .batchRename: .batchRename
      }
    }
  }

  private final class RecentTransferUndoAccumulator {
    private let expectedCount: Int
    private var completedCount = 0
    private var allUndoable = true
    private var entries = [TransferUndo]()

    init(expectedCount: Int) { self.expectedCount = expectedCount }

    func record(_ undo: TransferUndo?) -> (finished: Bool, entries: [TransferUndo]?) {
      completedCount += 1
      if let undo {
        entries.append(undo)
      } else {
        allUndoable = false
      }
      guard completedCount == expectedCount else { return (false, nil) }
      return (true, allUndoable ? entries : nil)
    }
  }

  @MainActor
  private final class RecentInventoryWait {
    var continuation: CheckedContinuation<Bool, Never>?
    var loadingTask: Task<Void, Never>?
    var timeoutTask: Task<Void, Never>?

    func finish(loaded: Bool) {
      guard let continuation else { return }
      self.continuation = nil
      if loaded {
        timeoutTask?.cancel()
      } else {
        loadingTask?.cancel()
      }
      continuation.resume(returning: loaded)
    }
  }

  private struct ArchiveBrowsingContext {
    let sourceBrowser: FileBrowserSession
    let archiveBrowser: FileBrowserSession
    let rootLocation: FileLocation
  }

  private(set) var tabs: [FileWorkspaceTab]
  @ObservationIgnored private var retainedActiveTab: FileWorkspaceTab?
  private let paneDiagnosticID = String(UUID().uuidString.prefix(8))
  private(set) var activeTabID: UUID
  private(set) var paneLayout = FolderPaneLayout()
  private var clipboard: ClipboardContents?
  private let fileClipboard: any FileClipboard
  private let recentSourceBookmarkReader: RecentSourceBookmarkReader
  private let recentDestinationInventoryTimeout: Duration
  private var clipboardChangeCount = -1
  private var consumedClipboardURLs: Set<URL> = []
  private var clipboardSourceIDs: Set<ObjectIdentifier> = []
  private var selectionOpenError: String?
  private var lastUndo: LastUndo?
  private var retiredBrowsers: [ObjectIdentifier: FileBrowserSession] = [:]
  private var pendingRecentRestoreJobIDs = Set<UUID>()
  private var archiveBrowsingContexts: [UUID: ArchiveBrowsingContext] = [:]
  private var archiveOpeningTokens: [UUID: UUID] = [:]
  private var remoteLocationStateByTabID: [UUID: WorkspaceLocationState] = [:]
  private var remoteActivationRequests: Set<UUID> = []
  private var remoteActivationHandler: RemoteActivationHandler?
  private var syncNavigationTask: Task<Void, Never>?
  private var syncNavigationToken: UUID?
  private(set) var isSyncBrowsingEnabled = false
  private(set) var syncNavigationRequestCount = 0
  var onStateChange: (@MainActor () -> Void)?
  var onOpenAdditionalFolder: (@MainActor (FileLocation) -> Bool)?

  init(
    initialBrowser: FileBrowserSession, initialViewMode: FileBrowserViewMode = .list,
    fileClipboard: (any FileClipboard)? = nil,
    recentSourceBookmarkReader: RecentSourceBookmarkReader = .shared,
    recentDestinationInventoryTimeout: Duration = .seconds(5)
  ) {
    self.fileClipboard = fileClipboard ?? defaultFileClipboard()
    self.recentSourceBookmarkReader = recentSourceBookmarkReader
    self.recentDestinationInventoryTimeout = recentDestinationInventoryTimeout
    let initialTab = FileWorkspaceTab(browser: initialBrowser, viewMode: initialViewMode)
    tabs = [initialTab]
    retainedActiveTab = initialTab
    activeTabID = initialTab.id
    paneLayout.registerInitialTab(id: initialTab.id)
    // 2ペインを既定にする(ユーザー明示指示)。setShowsSecondaryPane(true)経由にすることで、
    // 手動で「2ペイン」を押した場合と同じ経路(タブ複製・paneLayout.showSecondaryPane)を通り、
    // セカンダリペインのbrowserも既存のbrowserPane側.task { loadIfNeeded() }で自然に読み込まれる。
    setShowsSecondaryPane(true)
    restoreInterruptedTransfers()
    recordPaneDiagnostic("新規生成完了")
  }

  init(
    restoring state: WorkspaceState,
    browserFactory: WorkspaceBrowserFactory,
    onActivateRemote: RemoteActivationHandler? = nil,
    recentSourceBookmarkReader: RecentSourceBookmarkReader = .shared,
    recentDestinationInventoryTimeout: Duration = .seconds(5)
  ) {
    fileClipboard = defaultFileClipboard()
    self.recentSourceBookmarkReader = recentSourceBookmarkReader
    self.recentDestinationInventoryTimeout = recentDestinationInventoryTimeout
    let restoredTabs = state.tabs.map { tabState in
      FileWorkspaceTab(
        id: tabState.id,
        browser: browserFactory.makeBrowser(for: tabState.location),
        viewMode: tabState.viewMode)
    }
    precondition(!restoredTabs.isEmpty)
    tabs = restoredTabs
    retainedActiveTab = restoredTabs.first
    remoteActivationHandler = onActivateRemote
    remoteLocationStateByTabID = Dictionary(
      uniqueKeysWithValues: state.tabs.compactMap { tabState in
        guard case .remote = tabState.location else { return nil }
        return (tabState.id, tabState.location)
      })

    let restoredTabIDs = Set(restoredTabs.map(\.id))
    let primaryTabID =
      restoredTabIDs.contains(state.pane.primaryTabID)
      ? state.pane.primaryTabID : restoredTabs[0].id
    let secondaryTabID = state.pane.secondaryTabID.flatMap {
      restoredTabIDs.contains($0) && $0 != primaryTabID ? $0 : nil
    }
    let activePane =
      state.pane.activePane == .secondary && secondaryTabID == nil
      ? FolderPaneID.primary : state.pane.activePane
    activeTabID = primaryTabID
    paneLayout.restore(
      showsSecondaryPane: state.pane.showsSecondaryPane,
      activePane: activePane,
      primaryTabID: primaryTabID,
      secondaryTabID: secondaryTabID)
    isSyncBrowsingEnabled =
      paneLayout.showsSecondaryPane && state.pane.isSyncBrowsingEnabled
    let paneActiveTabID = paneLayout.activeTabID ?? primaryTabID
    activeTabID =
      restoredTabIDs.contains(state.activeTabID)
        && paneLayout.paneDisplaying(tabID: state.activeTabID) != nil
      ? state.activeTabID : paneActiveTabID
    if activeTabID != paneActiveTabID,
      let pane = paneLayout.paneDisplaying(tabID: activeTabID)
    {
      paneLayout.activate(pane)
    }
    restoreInterruptedTransfers()
    recordPaneDiagnostic("保存状態から復元完了")
  }

  var activeTab: FileWorkspaceTab {
    if let resolvedTab = tabs.first(where: { $0.id == activeTabID }) ?? tabs.first {
      retainedActiveTab = resolvedTab
      return resolvedTab
    }
    if let retainedActiveTab {
      return retainedActiveTab
    }
    let placeholderTab = Self.makePlaceholderTab()
    retainedActiveTab = placeholderTab
    return placeholderTab
  }

  private static func makePlaceholderTab() -> FileWorkspaceTab {
    let provider = LocalFileProvider()
    let browser = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(
        directoryURL: UserHomeDirectory.current, providerID: provider.id),
      startsBrowsing: false)
    browser.invalidate()
    return FileWorkspaceTab(browser: browser)
  }

  var activePane: FolderPaneID { paneLayout.activePane }
  var showsSecondaryPane: Bool { paneLayout.showsSecondaryPane }
  var visiblePanes: [FolderPaneID] { paneLayout.visiblePanes }

  /// 個別の場所や接続情報を含めず、同一起動中のペイン変更経路を識別する。
  func recordPaneDiagnostic(_ event: String) {
    AppLog.notice(
      "ワークスペース=\(paneDiagnosticID) 操作=\(event) "
        + "2ペイン=\(showsSecondaryPane) タブ数=\(tabs.count) 操作対象=\(activePane.rawValue)",
      category: "PaneLayout")
  }
  private var canCloseActiveTab: Bool { tabs.count > 1 }
  private var currentInternalClipboard: ClipboardContents? {
    clipboardChangeCount == fileClipboard.changeCount ? clipboard : nil
  }
  private var externalClipboardURLs: [URL] {
    let consumed = clipboardChangeCount == fileClipboard.changeCount ? consumedClipboardURLs : []
    var seen: Set<URL> = []
    return fileClipboard.fileURLs.filter {
      !consumed.contains($0) && seen.insert($0.standardizedFileURL).inserted
    }
  }
  var canPasteItems: Bool { currentInternalClipboard != nil || !externalClipboardURLs.isEmpty }
  func canPasteItems(to destination: FileBrowserSession) -> Bool {
    guard !destination.isRecentFilesActive else { return false }
    guard let clipboard = currentInternalClipboard else {
      return !externalClipboardURLs.isEmpty && destination.capabilities.contains(.write)
    }
    return clipboard.source.canTransferItems(
      to: destination,
      removesSourceAfterCopy: clipboard.operation == .move)
  }
  /// 表示外の外部clipboard元も、既存の衝突確認ダイアログへ接続する。
  var pendingTransferConflictBrowser: FileBrowserSession? {
    if activeTab.browser.pendingTransferConflict != nil { return activeTab.browser }
    return (tabs.map(\.browser) + Array(retiredBrowsers.values)).first {
      $0.pendingTransferConflict != nil
    }
  }
  var fileOperationErrorBrowser: FileBrowserSession? {
    if activeTab.browser.errorMessage != nil { return activeTab.browser }
    return clipboardSourceIDs.compactMap { retiredBrowsers[$0] }.first { $0.errorMessage != nil }
  }
  var fileOperationErrorMessage: String? {
    selectionOpenError ?? fileOperationErrorBrowser?.errorMessage
  }
  func clearFileOperationError() {
    if selectionOpenError != nil {
      selectionOpenError = nil
    } else {
      fileOperationErrorBrowser?.clearError()
    }
  }
  var canUndoLastTransfer: Bool { lastUndo != nil }
  var lastUndoKind: FileWorkspaceUndoKind? { lastUndo?.kind }
  var hasPendingSyncNavigation: Bool { syncNavigationTask != nil }
  var canCopySelectedItemsToOppositePane: Bool {
    canTransferSelectedItemsToOppositePane(wasMove: false)
  }
  var canMoveSelectedItemsToOppositePane: Bool {
    canTransferSelectedItemsToOppositePane(wasMove: true)
  }

  /// 履歴画面と転送バーが共有する再試行ディスパッチ。再試行処理は既存の
  /// FileBrowserSession.prepareTransferRetry/retryLastTransferへそのまま委譲する。
  @discardableResult
  func retryTransferJob(_ job: TransferJob) -> Bool {
    guard let primary = tab(for: .primary)?.browser,
      let secondary = tab(for: .secondary)?.browser
    else { return false }
    if Self.matchesDisplayedSource(primary, for: job),
      primary.prepareTransferRetry(job, to: secondary)
    {
      primary.retryLastTransfer()
      return true
    }
    if Self.matchesDisplayedSource(secondary, for: job),
      secondary.prepareTransferRetry(job, to: primary)
    {
      secondary.retryLastTransfer()
      return true
    }
    if job.sourceAccessBookmarkData != nil,
      let destination = [primary, secondary].first(where: {
        $0.providerID == job.destinationProviderID && $0.currentLocation == job.destination
      })
    {
      guard pendingRecentRestoreJobIDs.insert(job.id).inserted else { return true }
      Task { [weak self, destination] in
        guard let self else { return }
        defer { self.pendingRecentRestoreJobIDs.remove(job.id) }
        guard
          let source = await self.restoredRecentTransferSource(
            for: job, transferQueue: destination.transferQueue)
        else {
          destination.presentError(FileBrowserSessionError.transferResumeUnavailable)
          return
        }
        self.retiredBrowsers[ObjectIdentifier(source)] = source
        if source.prepareTransferRetry(job, to: destination) {
          source.retryLastTransfer()
        } else {
          destination.presentError(FileBrowserSessionError.transferResumeUnavailable)
        }
      }
      return true
    }
    tab(for: activePane)?.browser.presentError(FileBrowserSessionError.transferResumeUnavailable)
    return false
  }

  /// 同一起動中の一時停止は各セッションが保持するactiveTransferから再開し、再起動後は
  /// TransferJobのProvider・場所情報を使って2ペインへ対応付けてから再開する。
  @discardableResult
  func resumeTransferJob(_ job: TransferJob) -> Bool {
    guard job.state == .paused else { return false }
    guard let primary = tab(for: .primary)?.browser,
      let secondary = tab(for: .secondary)?.browser
    else {
      tab(for: activePane)?.browser.presentError(FileBrowserSessionError.transferResumeUnavailable)
      return false
    }
    if primary.resumeTransfer(job.id) || secondary.resumeTransfer(job.id) {
      return true
    }
    if Self.matchesDisplayedSource(primary, for: job),
      primary.prepareTransferResume(job, to: secondary)
    {
      return primary.resumeTransfer(job.id)
    }
    if Self.matchesDisplayedSource(secondary, for: job),
      secondary.prepareTransferResume(job, to: primary)
    {
      return secondary.resumeTransfer(job.id)
    }
    if job.sourceAccessBookmarkData != nil,
      let destination = [primary, secondary].first(where: {
        $0.providerID == job.destinationProviderID && $0.currentLocation == job.destination
      })
    {
      guard pendingRecentRestoreJobIDs.insert(job.id).inserted else { return true }
      Task { [weak self, destination] in
        guard let self else { return }
        defer { self.pendingRecentRestoreJobIDs.remove(job.id) }
        guard
          let source = await self.restoredRecentTransferSource(
            for: job, transferQueue: destination.transferQueue)
        else {
          destination.presentError(FileBrowserSessionError.transferResumeUnavailable)
          return
        }
        self.retiredBrowsers[ObjectIdentifier(source)] = source
        if source.prepareTransferResume(job, to: destination) {
          if !source.resumeTransfer(job.id) {
            destination.presentError(FileBrowserSessionError.transferResumeUnavailable)
          }
        } else {
          destination.presentError(FileBrowserSessionError.transferResumeUnavailable)
        }
      }
      return true
    }
    tab(for: activePane)?.browser.presentError(FileBrowserSessionError.transferResumeUnavailable)
    return false
  }

  var canCompareFolders: Bool {
    guard showsSecondaryPane,
      let leftBrowser = tab(for: .primary)?.browser,
      let rightBrowser = tab(for: .secondary)?.browser,
      !leftBrowser.isWorkspaceRemotePlaceholder,
      !rightBrowser.isWorkspaceRemotePlaceholder,
      !leftBrowser.isRecentFilesActive,
      !rightBrowser.isRecentFilesActive
    else {
      return false
    }
    return true
  }

  func makeFolderComparisonModel() -> FolderComparisonModel? {
    guard canCompareFolders,
      let leftBrowser = tab(for: .primary)?.browser,
      let rightBrowser = tab(for: .secondary)?.browser
    else { return nil }
    let leftRoot = leftBrowser.currentLocation
    let rightRoot = rightBrowser.currentLocation
    let leftSource = leftBrowser.makePeerSession(at: leftRoot)
    let rightSource = rightBrowser.makePeerSession(at: rightRoot)
    let transferCoordinator = FolderComparisonTransferCoordinator(
      workspace: self,
      leftSource: leftSource,
      rightSource: rightSource,
      leftTargetTemplate: leftBrowser,
      rightTargetTemplate: rightBrowser,
      leftRoot: leftRoot,
      rightRoot: rightRoot)
    return FolderComparisonModel(
      leftRoot: leftRoot,
      rightRoot: rightRoot,
      engine: leftBrowser.makeFolderComparisonEngine(comparingWith: rightBrowser),
      syncExecutionEngine: leftBrowser.makeFolderSyncExecutionEngine(
        comparingWith: rightBrowser),
      transferCoordinator: transferCoordinator)
  }

  func tab(for pane: FolderPaneID) -> FileWorkspaceTab? {
    guard let tabID = paneLayout.tabID(for: pane) else { return nil }
    return tabs.first(where: { $0.id == tabID })
  }

  /// アーカイブ閲覧中は、元フォルダまでの階層とZIP内の階層を連結して表示する。
  /// 合成はワークスペース固有の文脈なので、個々のFileBrowserSessionには持ち込まない。
  func displayedBreadcrumbs(in pane: FolderPaneID) -> [FileBrowserBreadcrumb] {
    guard let tab = tab(for: pane) else { return [] }
    guard let context = archiveBrowsingContexts[tab.id],
      tab.browser === context.archiveBrowser
    else {
      return tab.browser.breadcrumbs
    }
    return context.sourceBrowser.breadcrumbs + context.archiveBrowser.breadcrumbs
  }

  /// タブUIは廃止済みだが、2ペイン管理の実装詳細(タブ数=常にペイン数)として
  /// FileWorkspaceTab/paneLayoutは内部モデルに残しているため、その管理APIも
  /// private実装として保持する。
  private func addTab() {
    let tab = activeTab.duplicated()
    tabs.append(tab)
    paneLayout.assignTab(id: tab.id, to: activePane)
    activeTabID = tab.id
    restoreInterruptedTransfers()
  }

  private func closeActiveTab() {
    guard canCloseActiveTab else { return }
    closeTab(id: activeTabID)
  }

  func closeTab(id: UUID) {
    guard tabs.count > 1,
      let index = tabs.firstIndex(where: { $0.id == id })
    else {
      return
    }
    recordPaneDiagnostic("タブ削除前")
    let closingTab = tabs.remove(at: index)
    archiveBrowsingContexts[id] = nil
    archiveOpeningTokens[id] = nil
    remoteLocationStateByTabID[id] = nil
    remoteActivationRequests.remove(id)
    closingTab.browser.invalidate()
    paneLayout.removeTab(id: id, remainingTabIDs: tabs.map(\.id))
    if tabs.count == 1 {
      paneLayout.hideSecondaryPane()
    }
    disableSyncBrowsingIfSinglePane()
    if id == activeTabID {
      activeTabID = paneLayout.activeTabID ?? tabs[min(index, tabs.count - 1)].id
    }
    cleanupRetiredBrowsers()
    recordPaneDiagnostic("タブ削除後")
    onStateChange?()
  }

  private func activateTab(id: UUID) {
    guard id != activeTabID, tabs.contains(where: { $0.id == id }) else { return }
    paneLayout.assignTab(id: id, to: activePane)
    activeTabID = id
    activeTab.browser.reloadForHiddenFilesIfNeeded()
  }

  func setShowsSecondaryPane(_ showsSecondaryPane: Bool, source: String = "内部指定") {
    guard showsSecondaryPane != paneLayout.showsSecondaryPane else { return }
    recordPaneDiagnostic("表示変更前 入口=\(source) 要求2ペイン=\(showsSecondaryPane)")
    if showsSecondaryPane {
      let oppositePane = activePane.opposite
      if let tabID = paneLayout.tabID(for: oppositePane),
        tabID != activeTabID,
        tabs.contains(where: { $0.id == tabID })
      {
        paneLayout.showSecondaryPane(tabID: tabID)
      } else {
        let tab = activeTab.duplicated()
        tabs.append(tab)
        paneLayout.showSecondaryPane(tabID: tab.id)
      }
    } else {
      paneLayout.hideSecondaryPane()
      disableSyncBrowsingIfSinglePane()
    }
    recordPaneDiagnostic("表示変更後 入口=\(source)")
    onStateChange?()
  }

  func setSyncBrowsingEnabled(_ isEnabled: Bool) {
    let nextValue = isEnabled && showsSecondaryPane
    guard nextValue != isSyncBrowsingEnabled else { return }
    isSyncBrowsingEnabled = nextValue
    if !nextValue {
      syncNavigationTask?.cancel()
      syncNavigationTask = nil
      syncNavigationToken = nil
    }
    onStateChange?()
  }

  func toggleSyncBrowsing() {
    setSyncBrowsingEnabled(!isSyncBrowsingEnabled)
  }

  private func disableSyncBrowsingIfSinglePane() {
    guard !showsSecondaryPane, isSyncBrowsingEnabled else { return }
    isSyncBrowsingEnabled = false
    syncNavigationTask?.cancel()
    syncNavigationTask = nil
    syncNavigationToken = nil
  }

  func setShowsHiddenFiles(_ showsHiddenFiles: Bool) {
    let visibleTabIDs = Set(visiblePanes.compactMap { paneLayout.tabID(for: $0) })
    for tab in tabs {
      tab.browser.setShowsHiddenFiles(
        showsHiddenFiles,
        reload: visibleTabIDs.contains(tab.id))
    }
  }

  func revalidateDisplayedLocations() {
    for tab in tabs {
      tab.browser.revalidateDisplayedLocations(
        includesExpandedChildren: FileBrowserCapability.supports(
          .listTreeExpansion, for: tab.viewMode))
    }
  }

  func activatePane(_ pane: FolderPaneID, connectingRestoredRemote: Bool = true) {
    guard let tab = tab(for: pane) else { return }
    if pane != activePane {
      paneLayout.activate(pane)
      activeTabID = tab.id
      onStateChange?()
    }
    // ホバーは操作対象だけを変え、復元先への接続はクリック等の明示操作まで待つ。
    if connectingRestoredRemote {
      activateRestoredRemoteTabIfNeeded()
    }
  }

  func selectItems(_ urls: Set<URL>, in pane: FolderPaneID) {
    activatePane(pane)
    tab(for: pane)?.selectedItemURLs = urls
  }

  func open(_ original: FileItem, in pane: FolderPaneID) {
    selectionOpenError = nil
    guard let browser = tab(for: pane)?.browser else { return }
    let item: FileItem
    do { item = try browser.resolvedOriginalItem(original) } catch {
      browser.presentError(error)
      return
    }
    if shouldBrowseAsArchive(item, in: pane) {
      showArchiveContents(item, in: pane)
      return
    }
    performRelativeNavigation(in: pane) { $0.open(item) }
  }

  func openSelectedItem(in pane: FolderPaneID) {
    guard let tab = tab(for: pane) else { return }
    let browser = tab.browser
    let selected = browser.selectableItemsSnapshot.orderedItems(for: tab.selectedItemURLs)
    if selected.count == 1, let item = selected.first {
      open(item, in: pane)
      return
    }
    selectionOpenError = nil
    var openedFolder = false
    var files: [FileItem] = []
    var archives: [FileItem] = []
    var previews: [FileItem] = []
    for original in selected {
      do {
        let item = try browser.resolvedOriginalItem(original)
        if item.isDirectory, FileBrowserSession.localApplicationBundleURL(for: item) == nil {
          if openedFolder {
            guard onOpenAdditionalFolder?(item.location) == true else {
              selectionOpenError = String(localized: "この接続のフォルダは複数同時に開けません。個別に開いてください。")
              continue
            }
          } else {
            openedFolder = true
            open(item, in: pane)
          }
        } else if shouldBrowseAsArchive(item, in: pane) {
          archives.append(item)
        } else if item.location.localURL == nil {
          previews.append(item)
        } else {
          files.append(item)
        }
      } catch { browser.presentError(error) }
    }
    if archives.count == 1, let item = archives.first {
      showArchiveContents(item, in: pane)
    } else if archives.count > 1 {
      selectionOpenError = String(localized: "アーカイブの内部表示は1件ずつ開いてください。")
    }
    if previews.count == 1, let item = previews.first {
      browser.open(item)
    } else if previews.count > 1 {
      selectionOpenError = String(localized: "リモートファイルのプレビューは1件ずつ開いてください。")
    }
    // ZIPは同一セッションのアーカイブ処理が終わってから次を開く。
    browser.openItems(files)
  }

  private func shouldBrowseAsArchive(_ item: FileItem, in pane: FolderPaneID) -> Bool {
    guard let browser = tab(for: pane)?.browser,
      !item.isDirectory,
      item.location.providerID == browser.providerID,
      let archiveURL = item.location.localURL
    else {
      return false
    }
    guard let format = ArchiveFormat(url: archiveURL) else { return false }
    return format != .zip && format.isBrowsable
  }

  func showPackageContents(_ item: FileItem, in pane: FolderPaneID) {
    performRelativeNavigation(in: pane) { $0.showPackageContents(item) }
  }

  /// コンテキストメニューの実操作からZIP専用Providerを生成し、対象ペインだけを
  /// 読み取り専用ブラウザへ差し替える。ZIPの中央ディレクトリ走査はMainActor外で行う。
  func showArchiveContents(_ item: FileItem, in pane: FolderPaneID) {
    activatePane(pane)
    guard let tab = tab(for: pane),
      item.location.providerID == tab.browser.providerID,
      !item.isDirectory,
      item.location.localURL.flatMap(ArchiveFormat.init(url:))?.isBrowsable == true,
      let archiveURL = item.location.localURL
    else {
      return
    }
    let tabID = tab.id
    let sourceBrowser = tab.browser
    let sourceLocation = sourceBrowser.currentLocation
    let token = UUID()
    archiveOpeningTokens[tabID] = token
    sourceBrowser.clearError()
    Task { [weak self, weak sourceBrowser] in
      do {
        let provider = try await Task.detached(priority: .userInitiated) {
          try ArchiveFileProvider(archiveURL: archiveURL)
        }.value
        guard let self, let sourceBrowser,
          self.archiveOpeningTokens[tabID] == token,
          let currentTab = self.tabs.first(where: { $0.id == tabID }),
          currentTab.browser === sourceBrowser,
          sourceBrowser.currentLocation.representsSameDirectory(as: sourceLocation)
        else {
          return
        }
        self.archiveOpeningTokens[tabID] = nil
        let archiveBrowser = FileBrowserSession(
          provider: provider,
          initialLocation: provider.rootLocation,
          hasExternalParent: true,
          transferQueue: sourceBrowser.transferQueue)
        self.archiveBrowsingContexts[tabID] = ArchiveBrowsingContext(
          sourceBrowser: sourceBrowser,
          archiveBrowser: archiveBrowser,
          rootLocation: provider.rootLocation)
        self.replaceBrowser(in: currentTab, with: archiveBrowser)
        archiveBrowser.loadIfNeeded()
      } catch {
        guard let self, self.archiveOpeningTokens[tabID] == token else { return }
        self.archiveOpeningTokens[tabID] = nil
        sourceBrowser?.presentError(error)
      }
    }
  }

  func goBack(in pane: FolderPaneID) {
    performRelativeNavigation(in: pane) { $0.goBack() }
  }

  func goForward(in pane: FolderPaneID) {
    performRelativeNavigation(in: pane) { $0.goForward() }
  }

  func openParent(in pane: FolderPaneID) {
    activatePane(pane)
    if let tab = tab(for: pane),
      let context = archiveBrowsingContexts[tab.id],
      tab.browser === context.archiveBrowser,
      tab.browser.currentLocation == context.rootLocation
    {
      exitArchiveBrowsing(in: tab, context: context)
      return
    }
    performRelativeNavigation(in: pane) { $0.openParent() }
  }

  func openBreadcrumb(_ breadcrumb: FileBrowserBreadcrumb, in pane: FolderPaneID) {
    activatePane(pane)
    if let tab = tab(for: pane),
      let context = archiveBrowsingContexts[tab.id],
      tab.browser === context.archiveBrowser,
      breadcrumb.location.providerID != context.archiveBrowser.providerID
    {
      guard context.sourceBrowser.breadcrumbs.contains(where: { $0.id == breadcrumb.id }) else {
        return
      }
      exitArchiveBrowsing(in: tab, context: context)
      if context.sourceBrowser.currentLocation != breadcrumb.location {
        context.sourceBrowser.openBreadcrumb(breadcrumb)
      }
      return
    }
    performRelativeNavigation(in: pane) { $0.openBreadcrumb(breadcrumb) }
  }

  private func exitArchiveBrowsing(
    in tab: FileWorkspaceTab,
    context: ArchiveBrowsingContext
  ) {
    archiveBrowsingContexts[tab.id] = nil
    replaceBrowser(in: tab, with: context.sourceBrowser)
    context.sourceBrowser.loadIfNeeded()
  }

  func selectColumnItems(
    _ selectedItemURLs: Set<URL>,
    inColumnAt columnLocation: FileLocation,
    pane: FolderPaneID
  ) {
    guard let tab = tab(for: pane) else { return }
    activatePane(pane)
    tab.selectedItemURLs = selectedItemURLs
    performRelativeNavigation(in: pane, activatesPane: false) {
      $0.selectColumnItems(selectedItemURLs, inColumnAt: columnLocation)
    }
  }

  private func performRelativeNavigation(
    in pane: FolderPaneID,
    activatesPane: Bool = true,
    _ navigation: (FileBrowserSession) -> Void
  ) {
    if activatesPane {
      activatePane(pane)
    }
    guard let sourceTab = tab(for: pane) else { return }
    let sourceBrowser = sourceTab.browser
    let sourceBefore = sourceBrowser.currentLocation
    navigation(sourceBrowser)
    let sourceAfter = sourceBrowser.currentLocation
    guard sourceAfter != sourceBefore else { return }
    synchronizeNavigation(
      from: sourceBefore,
      to: sourceAfter,
      sourceTab: sourceTab,
      sourcePane: pane)
  }

  private func synchronizeNavigation(
    from sourceBefore: FileLocation,
    to sourceAfter: FileLocation,
    sourceTab: FileWorkspaceTab,
    sourcePane: FolderPaneID
  ) {
    guard isSyncBrowsingEnabled,
      showsSecondaryPane,
      FileBrowserCapability.supports(.syncBrowsing, for: sourceTab.viewMode),
      let move = SyncBrowsingRelativeMove.resolve(from: sourceBefore, to: sourceAfter),
      let targetTab = tab(for: sourcePane.opposite),
      FileBrowserCapability.supports(.syncBrowsing, for: targetTab.viewMode),
      !targetTab.browser.isWorkspaceRemotePlaceholder
    else {
      return
    }
    let targetBrowser = targetTab.browser
    let targetBefore = targetBrowser.currentLocation
    guard let destination = move.applying(to: targetBefore) else { return }

    syncNavigationTask?.cancel()
    let token = UUID()
    syncNavigationToken = token
    syncNavigationRequestCount += 1
    syncNavigationTask = Task { [weak self, targetBrowser] in
      guard let self else { return }
      let didNavigate = await targetBrowser.followSyncBrowsing(
        to: destination,
        expectedCurrentLocation: targetBefore)
      guard self.syncNavigationToken == token else { return }
      self.syncNavigationTask = nil
      self.syncNavigationToken = nil
      if didNavigate {
        self.onStateChange?()
      }
    }
  }

  func setSortOrder(_ order: FileItemSortOrder) {
    activeTab.setSortOrder(order)
  }

  func setViewMode(_ viewMode: FileBrowserViewMode) {
    activeTab.setViewMode(viewMode)
    onStateChange?()
  }

  func toggleSortDirection() {
    activeTab.toggleSortDirection()
  }

  func applySortRequest(_ requestedOrder: FileItemSortOrder, in pane: FolderPaneID) {
    guard let tab = tab(for: pane) else { return }
    activatePane(pane)
    tab.applySortRequest(requestedOrder)
  }

  func replaceActiveBrowser(with browser: FileBrowserSession) {
    archiveBrowsingContexts[activeTab.id] = nil
    archiveOpeningTokens[activeTab.id] = nil
    replaceBrowser(in: activeTab, with: browser)
  }

  private func replaceBrowser(in tab: FileWorkspaceTab, with browser: FileBrowserSession) {
    remoteLocationStateByTabID[tab.id] = nil
    remoteActivationRequests.remove(tab.id)
    let previousBrowser = tab.browser
    guard previousBrowser !== browser else {
      browser.loadIfNeeded()
      return
    }
    browser.setShowsHiddenFiles(previousBrowser.showsHiddenFiles, reload: false)
    retiredBrowsers[ObjectIdentifier(browser)] = nil
    browser.resumeBrowsing()
    tab.browser = browser
    browser.setSearchSortOrder(tab.sortOrder, ascending: tab.sortAscending)
    tab.selectedItemURLs = []
    let identifier = ObjectIdentifier(previousBrowser)
    retiredBrowsers[identifier] = previousBrowser
    previousBrowser.retireFromBrowsing { [weak self] in
      self?.cleanupRetiredBrowsers()
    }
    cleanupRetiredBrowsers()
    restoreInterruptedTransfers()
    onStateChange?()
  }

  func setRemoteActivationHandler(_ handler: RemoteActivationHandler?) {
    remoteActivationHandler = handler
  }

  private func cleanupRetiredBrowsers() {
    let referencedBrowsers =
      [clipboard?.source].compactMap { $0 }
      + (lastUndo?.referencedBrowsers ?? [])
      + archiveBrowsingContexts.values.map(\.sourceBrowser)
    let removableIdentifiers = retiredBrowsers.compactMap { identifier, browser in
      let isReferenced = referencedBrowsers.contains { $0 === browser }
      return !isReferenced && !browser.hasBackgroundFileOperation
        && browser.pendingTransferConflict == nil
        && !(clipboardSourceIDs.contains(identifier) && browser.errorMessage != nil)
        ? identifier : nil
    }
    for identifier in removableIdentifiers {
      retiredBrowsers[identifier]?.invalidate()
      retiredBrowsers[identifier] = nil
      clipboardSourceIDs.remove(identifier)
    }
  }

  @discardableResult
  func removeTabs(for connectionID: FileProviderConnectionID) -> Bool {
    let removedTabIDs =
      tabs
      .filter {
        $0.browser.connectionID == connectionID
          || archiveBrowsingContexts[$0.id]?.sourceBrowser.connectionID == connectionID
      }
      .map(\.id)
    guard !removedTabIDs.isEmpty else { return tabs.isEmpty }
    recordPaneDiagnostic("接続タブ除去前 対象数=\(removedTabIDs.count)")
    for tab in tabs where removedTabIDs.contains(tab.id) {
      tab.browser.invalidate()
    }
    for tabID in removedTabIDs {
      archiveBrowsingContexts[tabID] = nil
      archiveOpeningTokens[tabID] = nil
      remoteLocationStateByTabID[tabID] = nil
      remoteActivationRequests.remove(tabID)
    }
    tabs.removeAll { removedTabIDs.contains($0.id) }
    for tabID in removedTabIDs {
      paneLayout.removeTab(id: tabID, remainingTabIDs: tabs.map(\.id))
    }
    if tabs.count <= 1 {
      paneLayout.hideSecondaryPane()
    }
    disableSyncBrowsingIfSinglePane()
    cleanupRetiredBrowsers()
    recordPaneDiagnostic("接続タブ除去後")
    guard let nextTab = tabs.first else { return true }
    if !tabs.contains(where: { $0.id == activeTabID }) {
      activeTabID = paneLayout.activeTabID ?? nextTab.id
    }
    onStateChange?()
    return false
  }

  func activateRestoredRemoteTabIfNeeded() {
    let tab = activeTab
    guard let location = remoteLocationStateByTabID[tab.id],
      remoteActivationRequests.insert(tab.id).inserted,
      let remoteActivationHandler
    else {
      return
    }
    remoteActivationHandler(location) { [weak self] browser in
      guard let self else { return }
      guard let browser else {
        self.remoteActivationRequests.remove(tab.id)
        return
      }
      self.completeRemoteActivation(tabID: tab.id, browser: browser)
    }
  }

  func makeState(bookmarkCodec: any FolderBookmarkCoding) throws -> WorkspaceState {
    guard let primaryTabID = paneLayout.tabID(for: .primary) else {
      throw CocoaError(.coderInvalidValue)
    }
    let tabStates = try tabs.map { tab in
      // アーカイブ内閲覧は一時的な画面として扱い、再起動時は元フォルダを復元する。
      let restorableBrowser = archiveBrowsingContexts[tab.id]?.sourceBrowser ?? tab.browser
      return WorkspaceTabState(
        id: tab.id,
        location: try restorableBrowser.makeWorkspaceLocationState(bookmarkCodec: bookmarkCodec),
        viewMode: tab.viewMode)
    }
    return WorkspaceState(
      tabs: tabStates,
      activeTabID: activeTabID,
      pane: WorkspacePaneState(
        showsSecondaryPane: showsSecondaryPane,
        activePane: activePane,
        primaryTabID: primaryTabID,
        secondaryTabID: paneLayout.tabID(for: .secondary),
        isSyncBrowsingEnabled: isSyncBrowsingEnabled))
  }

  private func completeRemoteActivation(tabID: UUID, browser: FileBrowserSession) {
    guard let tab = tabs.first(where: { $0.id == tabID }),
      remoteLocationStateByTabID[tabID] != nil
    else {
      browser.invalidate()
      return
    }
    let previousBrowser = tab.browser
    tab.browser = browser
    browser.setSearchSortOrder(tab.sortOrder, ascending: tab.sortAscending)
    remoteLocationStateByTabID[tabID] = nil
    remoteActivationRequests.remove(tabID)
    previousBrowser.invalidate()
    if paneLayout.paneDisplaying(tabID: tabID) != nil {
      browser.loadIfNeeded()
    }
    restoreInterruptedTransfers()
    onStateChange?()
  }

  func copySelectedItems() {
    storeSelectedItems(operation: .copy)
  }

  func cutSelectedItems() {
    storeSelectedItems(operation: .move)
  }

  func pasteItems(moving: Bool = false) {
    let destination = activeTab.browser
    guard !destination.isRecentFilesActive else { return }
    if let clipboard = currentInternalClipboard {
      transfer(
        clipboard.items, from: clipboard.source, to: destination,
        wasMove: moving || clipboard.operation == .move,
        recentOrigin: clipboard.isRecentOrigin)
      return
    }
    let urls = externalClipboardURLs
    let generation = fileClipboard.changeCount
    if clipboardChangeCount != generation {
      clipboard = nil
      consumedClipboardURLs = []
      clipboardChangeCount = generation
    }
    guard !urls.isEmpty, destination.capabilities.contains(.write) else { return }
    let provider = LocalFileProvider()
    do {
      // URLだけで権限を広げない。Sandboxで未許可の項目は通常の読取エラーとして扱う。
      let items = try urls.map { try provider.item(at: $0) }
      let groups = Dictionary(grouping: items) { $0.url.deletingLastPathComponent() }
      var parents: [URL] = []
      for item in items {
        let parent = item.url.deletingLastPathComponent()
        if !parents.contains(parent) { parents.append(parent) }
      }
      for parent in parents {
        guard let items = groups[parent] else { continue }
        let source = FileBrowserSession(
          provider: provider,
          initialLocation: FileLocation(localURL: parent, providerID: provider.id),
          transferQueue: destination.transferQueue, startsBrowsing: false)
        retiredBrowsers[ObjectIdentifier(source)] = source
        clipboardSourceIDs.insert(ObjectIdentifier(source))
        transfer(
          items, from: source, to: destination, wasMove: moving,
          onCompleted: { [weak self, weak source] in
            guard let self, moving, self.fileClipboard.changeCount == generation else { return }
            if self.clipboardChangeCount != generation {
              self.clipboardChangeCount = generation
              self.consumedClipboardURLs = []
            }
            self.consumedClipboardURLs.formUnion(
              source?.lastCompletedTransfer?.items.map(\.url) ?? [])
          })
      }
    } catch { destination.presentError(error) }
  }

  @discardableResult
  func transferDroppedItems(
    _ urls: [URL],
    to pane: FolderPaneID,
    wasMove: Bool,
    trace: DropPreparationTrace? = nil
  ) -> Bool {
    guard let destination = tab(for: pane)?.browser else {
      trace?.finish(.rejected)
      return false
    }
    let itemsBySource = resolveDroppedItems(urls, excluding: destination, trace: trace)
    return enqueueDroppedItems(
      itemsBySource, to: destination, wasMove: wasMove, trace: trace)
  }

  func canTransferDroppedItems(
    _ urls: [URL],
    to pane: FolderPaneID,
    trace: DropPreparationTrace? = nil
  ) -> Bool {
    guard let destination = tab(for: pane)?.browser else {
      trace?.finish(.rejected)
      return false
    }
    let itemsBySource = resolveDroppedItems(urls, excluding: destination, trace: trace)
    return canTransferDroppedItems(
      itemsBySource, to: destination, removesSourceAfterCopy: false)
  }

  /// 1回のドロップ操作について、受理判定、移動/コピー判定、転送開始を連続して行う。
  /// 呼び出し側が同じURLを3段階へ別々に渡さず、操作単位の準備情報を共有できる入口。
  @discardableResult
  func transferDroppedItems(
    _ urls: [URL],
    to pane: FolderPaneID,
    copyForced: Bool,
    trace: DropPreparationTrace? = nil
  ) -> Bool {
    guard let destination = tab(for: pane)?.browser else {
      trace?.finish(.rejected)
      return false
    }
    let itemsBySource = resolveDroppedItems(urls, excluding: destination, trace: trace)
    guard
      canTransferDroppedItems(
        itemsBySource, to: destination, removesSourceAfterCopy: false)
    else {
      trace?.finish(.rejected)
      return false
    }
    let movesItems: Bool
    if destination.usesLocalFileProvider,
      let destinationURL = destination.currentLocation.localURL
    {
      movesItems = shouldMoveDroppedItems(
        itemsBySource,
        originalURLCount: urls.count,
        to: destinationURL,
        trace: trace)
    } else {
      trace?.recordOperationDecision(volumeResourceLookupCount: 0, movesItems: false)
      movesItems = false
    }
    return enqueueDroppedItems(
      itemsBySource,
      to: destination,
      wasMove: movesItems && !copyForced,
      trace: trace)
  }

  /// お気に入り・履歴など、表示中ペインとは独立して生成した保存先へのドロップ転送。
  /// 転送先目録の取得、同一ボリューム移動、Optionコピー強制はペイン内D&Dと同じ規則を使う。
  @discardableResult
  func transferDroppedItems(
    _ urls: [URL],
    to destination: FileBrowserSession,
    copyForced: Bool,
    trace: DropPreparationTrace? = nil
  ) -> Bool {
    let matchingDisplayedBrowser = tabs.lazy.map(\.browser).first { browser in
      browser.providerID == destination.providerID
        && browser.currentLocation.representsSameDirectory(as: destination.currentLocation)
    }
    let itemsBySource = resolveDroppedItems(
      urls, excluding: matchingDisplayedBrowser, trace: trace)
    guard
      !itemsBySource.values.contains(where: { entry in
        entry.source.providerID == destination.providerID
          && entry.source.currentLocation.representsSameDirectory(
            as: destination.currentLocation)
      }),
      canTransferDroppedItems(
        itemsBySource, to: destination, removesSourceAfterCopy: false)
    else {
      trace?.finish(.rejected)
      return false
    }

    let movesItems: Bool
    if destination.usesLocalFileProvider,
      let destinationURL = destination.currentLocation.localURL
    {
      movesItems = shouldMoveDroppedItems(
        itemsBySource,
        originalURLCount: urls.count,
        to: destinationURL,
        trace: trace)
    } else {
      trace?.recordOperationDecision(volumeResourceLookupCount: 0, movesItems: false)
      movesItems = false
    }

    trace?.recordTemporarySession()
    Task { [weak self] in
      await destination.loadTransferDestinationInventory()
      guard let self else {
        trace?.finish(.cancelled)
        return
      }
      trace?.recordTemporarySessionActivity(
        hasTransferUpdateSubscription: destination.hasTransferUpdateSubscription,
        hasActiveBrowsingResources: destination.hasActiveBrowsingResources)
      trace?.recordDestinationInventory(itemCount: destination.items.count, listingCount: 1)
      trace?.prepareForTransfers(sourceGroupCount: itemsBySource.count)
      for entry in itemsBySource.values {
        self.transfer(
          entry.items,
          from: entry.source,
          to: destination,
          wasMove: movesItems && !copyForced,
          trace: trace,
          onCompleted: { [weak self] in
            self?.refreshDisplayedDestination(
              at: destination.currentLocation,
              providerID: destination.providerID)
          })
      }
    }
    return true
  }

  /// フォルダ行へのドロップ。対象行と同じProviderの一時セッションを転送先にし、既存の
  /// TransferQueue経路をそのまま使う。未展開フォルダでも衝突判定できるよう転送前に列挙する。
  @discardableResult
  func transferDroppedItems(
    _ urls: [URL],
    into folder: FileItem,
    in pane: FolderPaneID,
    wasMove: Bool,
    trace: DropPreparationTrace? = nil
  ) -> Bool {
    guard let destinationBrowser = tab(for: pane)?.browser,
      destinationBrowser.capabilities.contains(.write),
      folder.isDirectory,
      folder.location.providerID == destinationBrowser.providerID
    else {
      trace?.finish(.rejected)
      return false
    }
    return transferDroppedItems(
      urls, to: folder.location, in: pane, wasMove: wasMove, trace: trace)
  }

  @discardableResult
  func transferDroppedItems(
    _ urls: [URL],
    into folder: FileItem,
    in pane: FolderPaneID,
    copyForced: Bool,
    trace: DropPreparationTrace? = nil
  ) -> Bool {
    guard let destinationBrowser = tab(for: pane)?.browser,
      destinationBrowser.capabilities.contains(.write),
      folder.isDirectory,
      folder.location.providerID == destinationBrowser.providerID
    else {
      trace?.finish(.rejected)
      return false
    }
    return transferDroppedItems(
      urls, to: folder.location, in: pane, copyForced: copyForced, trace: trace)
  }

  /// カラム背景など、表示中セッションの現在地とは異なる階層を明示したドロップ転送。
  /// 転送先と同じProviderの一時セッションを使い、既存のTransferQueue経路へ接続する。
  @discardableResult
  func transferDroppedItems(
    _ urls: [URL],
    to location: FileLocation,
    in pane: FolderPaneID,
    wasMove: Bool,
    trace: DropPreparationTrace? = nil
  ) -> Bool {
    guard let destinationBrowser = tab(for: pane)?.browser,
      destinationBrowser.capabilities.contains(.write),
      location.providerID == destinationBrowser.providerID
    else {
      trace?.finish(.rejected)
      return false
    }
    let excludedBrowser =
      destinationBrowser.currentLocation.representsSameDirectory(as: location)
      ? destinationBrowser : nil
    let itemsBySource = resolveDroppedItems(urls, excluding: excludedBrowser, trace: trace)
    guard !itemsBySource.isEmpty else {
      trace?.finish(.rejected)
      return false
    }
    let destination = destinationBrowser.makeTransferDestinationSession(at: location)
    trace?.recordTemporarySession()
    return enqueueDroppedItems(
      itemsBySource,
      to: destination,
      refreshing: destinationBrowser,
      at: location,
      wasMove: wasMove,
      trace: trace)
  }

  @discardableResult
  func transferDroppedItems(
    _ urls: [URL],
    to location: FileLocation,
    in pane: FolderPaneID,
    copyForced: Bool,
    trace: DropPreparationTrace? = nil
  ) -> Bool {
    guard let destinationBrowser = tab(for: pane)?.browser,
      destinationBrowser.capabilities.contains(.write),
      location.providerID == destinationBrowser.providerID
    else {
      trace?.finish(.rejected)
      return false
    }
    let excludedBrowser =
      destinationBrowser.currentLocation.representsSameDirectory(as: location)
      ? destinationBrowser : nil
    let itemsBySource = resolveDroppedItems(urls, excluding: excludedBrowser, trace: trace)
    guard !itemsBySource.isEmpty else {
      trace?.finish(.rejected)
      return false
    }
    let destination = destinationBrowser.makeTransferDestinationSession(at: location)
    trace?.recordTemporarySession()
    guard
      canTransferDroppedItems(
        itemsBySource, to: destination, removesSourceAfterCopy: false)
    else {
      trace?.finish(.rejected)
      return false
    }
    let movesItems: Bool
    if destinationBrowser.usesLocalFileProvider,
      let destinationURL = location.localURL
    {
      movesItems = shouldMoveDroppedItems(
        itemsBySource,
        originalURLCount: urls.count,
        to: destinationURL,
        trace: trace)
    } else {
      trace?.recordOperationDecision(volumeResourceLookupCount: 0, movesItems: false)
      movesItems = false
    }
    return enqueueDroppedItems(
      itemsBySource,
      to: destination,
      refreshing: destinationBrowser,
      at: location,
      wasMove: movesItems && !copyForced,
      trace: trace)
  }

  func canTransferDroppedItems(
    _ urls: [URL],
    into folder: FileItem,
    in pane: FolderPaneID,
    trace: DropPreparationTrace? = nil
  ) -> Bool {
    guard let destinationBrowser = tab(for: pane)?.browser,
      destinationBrowser.capabilities.contains(.write),
      folder.isDirectory,
      folder.location.providerID == destinationBrowser.providerID
    else {
      trace?.finish(.rejected)
      return false
    }
    return canTransferDroppedItems(urls, to: folder.location, in: pane, trace: trace)
  }

  func canTransferDroppedItems(
    _ urls: [URL],
    to location: FileLocation,
    in pane: FolderPaneID,
    trace: DropPreparationTrace? = nil
  ) -> Bool {
    guard let destinationBrowser = tab(for: pane)?.browser,
      destinationBrowser.capabilities.contains(.write),
      location.providerID == destinationBrowser.providerID
    else {
      trace?.finish(.rejected)
      return false
    }
    let excludedBrowser =
      destinationBrowser.currentLocation.representsSameDirectory(as: location)
      ? destinationBrowser : nil
    let itemsBySource = resolveDroppedItems(urls, excluding: excludedBrowser, trace: trace)
    guard !itemsBySource.isEmpty else {
      trace?.finish(.rejected)
      return false
    }
    let destination = destinationBrowser.makeTransferDestinationSession(at: location)
    trace?.recordTemporarySession()
    return itemsBySource.values.allSatisfy {
      $0.source.canTransferItems(to: destination, removesSourceAfterCopy: false)
    }
  }

  /// ドロップ元・先がすべてローカルProviderで、各項目が転送先と同一ボリュームに
  /// ある場合だけ移動する。URLの由来またはボリュームを判定できなければ安全側で
  /// コピーを選ぶ。
  func shouldMoveDroppedItems(
    _ urls: [URL],
    to pane: FolderPaneID,
    trace: DropPreparationTrace? = nil
  ) -> Bool {
    guard let destination = tab(for: pane)?.browser,
      destination.usesLocalFileProvider,
      let destinationURL = destination.currentLocation.localURL
    else {
      trace?.recordOperationDecision(volumeResourceLookupCount: 0, movesItems: false)
      return false
    }

    return shouldMoveDroppedItems(
      urls,
      to: destinationURL,
      excluding: destination,
      trace: trace)
  }

  func shouldMoveDroppedItems(
    _ urls: [URL],
    into folder: FileItem,
    in pane: FolderPaneID,
    trace: DropPreparationTrace? = nil
  ) -> Bool {
    guard let destinationBrowser = tab(for: pane)?.browser,
      destinationBrowser.usesLocalFileProvider,
      folder.isDirectory,
      folder.location.providerID == destinationBrowser.providerID
    else {
      trace?.recordOperationDecision(volumeResourceLookupCount: 0, movesItems: false)
      return false
    }

    return shouldMoveDroppedItems(urls, to: folder.location, in: pane, trace: trace)
  }

  func shouldMoveDroppedItems(
    _ urls: [URL],
    to location: FileLocation,
    in pane: FolderPaneID,
    trace: DropPreparationTrace? = nil
  ) -> Bool {
    guard let destinationBrowser = tab(for: pane)?.browser,
      destinationBrowser.usesLocalFileProvider,
      location.providerID == destinationBrowser.providerID,
      let destinationURL = location.localURL
    else {
      trace?.recordOperationDecision(volumeResourceLookupCount: 0, movesItems: false)
      return false
    }

    let excludedBrowser =
      destinationBrowser.currentLocation.representsSameDirectory(as: location)
      ? destinationBrowser : nil
    return shouldMoveDroppedItems(
      urls,
      to: destinationURL,
      excluding: excludedBrowser,
      trace: trace)
  }

  private func shouldMoveDroppedItems(
    _ urls: [URL],
    to destinationURL: URL,
    excluding destination: FileBrowserSession?,
    trace: DropPreparationTrace?
  ) -> Bool {
    let itemsBySource = resolveDroppedItems(urls, excluding: destination, trace: trace)
    return shouldMoveDroppedItems(
      itemsBySource,
      originalURLCount: urls.count,
      to: destinationURL,
      trace: trace)
  }

  private func shouldMoveDroppedItems(
    _ itemsBySource: DroppedItemsBySource,
    originalURLCount: Int,
    to destinationURL: URL,
    trace: DropPreparationTrace?
  ) -> Bool {
    let resolvedItems = itemsBySource.values.flatMap(\.items)
    guard !resolvedItems.isEmpty,
      resolvedItems.count == originalURLCount,
      itemsBySource.values.allSatisfy({ $0.source.usesLocalFileProvider })
    else {
      trace?.recordOperationDecision(volumeResourceLookupCount: 0, movesItems: false)
      return false
    }

    // 転送先は1操作中に不変なので1回だけ取得する。転送元は親フォルダと別ボリュームの
    // マウントポイント自体をドラッグできるため、項目ごとの確認を省かない。
    var volumeResourceLookupCount = 1
    guard let destinationVolumeIdentifier = Self.volumeIdentifier(of: destinationURL) else {
      trace?.recordOperationDecision(
        volumeResourceLookupCount: volumeResourceLookupCount,
        movesItems: false)
      return false
    }
    let movesItems = resolvedItems.allSatisfy { item in
      volumeResourceLookupCount += 1
      return Self.volumeIdentifier(of: item.url) == destinationVolumeIdentifier
    }
    trace?.recordOperationDecision(
      volumeResourceLookupCount: volumeResourceLookupCount,
      movesItems: movesItems)
    return movesItems
  }

  private func canTransferDroppedItems(
    _ itemsBySource: DroppedItemsBySource,
    to destination: FileBrowserSession,
    removesSourceAfterCopy: Bool
  ) -> Bool {
    !itemsBySource.isEmpty
      && itemsBySource.values.allSatisfy {
        $0.source.canTransferItems(
          to: destination, removesSourceAfterCopy: removesSourceAfterCopy)
      }
  }

  private func enqueueDroppedItems(
    _ itemsBySource: DroppedItemsBySource,
    to destination: FileBrowserSession,
    wasMove: Bool,
    trace: DropPreparationTrace?
  ) -> Bool {
    guard
      canTransferDroppedItems(
        itemsBySource, to: destination, removesSourceAfterCopy: wasMove)
    else {
      trace?.finish(.rejected)
      return false
    }
    trace?.recordDestinationInventory(itemCount: destination.items.count, listingCount: 0)
    trace?.prepareForTransfers(sourceGroupCount: itemsBySource.count)
    for entry in itemsBySource.values {
      transfer(
        entry.items,
        from: entry.source,
        to: destination,
        wasMove: wasMove,
        trace: trace)
    }
    return true
  }

  private func enqueueDroppedItems(
    _ itemsBySource: DroppedItemsBySource,
    to destination: FileBrowserSession,
    refreshing destinationBrowser: FileBrowserSession,
    at location: FileLocation,
    wasMove: Bool,
    trace: DropPreparationTrace?
  ) -> Bool {
    guard
      canTransferDroppedItems(
        itemsBySource, to: destination, removesSourceAfterCopy: wasMove)
    else {
      trace?.finish(.rejected)
      return false
    }
    trace?.prepareForTransfers(sourceGroupCount: itemsBySource.count)
    Task { [weak self, weak destinationBrowser] in
      await destination.loadTransferDestinationInventory()
      guard let self else {
        trace?.finish(.cancelled)
        return
      }
      trace?.recordTemporarySessionActivity(
        hasTransferUpdateSubscription: destination.hasTransferUpdateSubscription,
        hasActiveBrowsingResources: destination.hasActiveBrowsingResources)
      trace?.recordDestinationInventory(itemCount: destination.items.count, listingCount: 1)
      for entry in itemsBySource.values {
        self.transfer(
          entry.items,
          from: entry.source,
          to: destination,
          wasMove: wasMove,
          trace: trace,
          onCompleted: {
            destinationBrowser?.refreshExpandedChildren(at: location)
            destinationBrowser?.refreshDisplayedColumn(at: location, with: destination.items)
          })
      }
    }
    return true
  }

  private static func volumeIdentifier(of url: URL) -> String? {
    var uncachedURL = url
    uncachedURL.removeAllCachedResourceValues()
    guard
      let identifier = try? uncachedURL.resourceValues(forKeys: [.volumeIdentifierKey])
        .volumeIdentifier
    else { return nil }
    return String(reflecting: identifier)
  }

  private func refreshDisplayedDestination(
    at location: FileLocation,
    providerID: FileProviderID
  ) {
    for browser in tabs.lazy.map(\.browser)
    where browser.providerID == providerID
      && browser.currentLocation.representsSameDirectory(as: location)
    {
      browser.refresh()
    }
  }

  private func resolveDroppedItems(
    _ urls: [URL],
    excluding destination: FileBrowserSession?,
    trace: DropPreparationTrace? = nil
  ) -> DroppedItemsBySource {
    // 選択と共有する世代別索引を各セッション1回だけ取得し、候補配列をURL辞書へ
    // 作り直さない。
    let sourceCandidates = tabs.compactMap {
      tab -> (FileBrowserSession, FileBrowserSelectableItemsSnapshot)? in
      let browser = tab.browser
      guard destination.map({ browser !== $0 }) ?? true else { return nil }
      return (browser, browser.selectableItemsSnapshot)
    }
    var itemsBySource: DroppedItemsBySource = [:]
    for url in urls {
      guard
        let (source, sourceItems) = sourceCandidates.first(where: { $0.1.item(for: url) != nil }),
        let item = sourceItems.item(for: url)
      else {
        continue
      }
      let identifier = ObjectIdentifier(source)
      itemsBySource[identifier, default: (source, [])].items.append(item)
    }
    trace?.recordResolution(
      sourceCandidateCount: sourceCandidates.reduce(0) { $0 + $1.1.count },
      resolvedItemCount: itemsBySource.values.reduce(0) { $0 + $1.items.count })
    return itemsBySource
  }

  func transferSelectedItems(to destinationTabID: UUID, wasMove: Bool) {
    guard let destination = tabs.first(where: { $0.id == destinationTabID })?.browser else {
      return
    }
    transferSelectedItems(to: destination, wasMove: wasMove)
  }

  func transferSelectedItems(to destination: FileBrowserSession, wasMove: Bool) {
    let source = activeTab.browser
    let items = source.selectableItemsSnapshot.orderedItems(for: activeTab.selectedItemURLs)
    guard !items.isEmpty, source !== destination,
      source.canTransferItems(to: destination, removesSourceAfterCopy: wasMove)
    else { return }
    // タブ宛先は既にload済みでdestination.itemsが非空のため、この分岐に入らず従来どおり
    // 同期で転送する。ProviderTransferDestinationCatalog由来のその場生成の宛先は一度も
    // load()されておらずitemsが常に空のため、そのまま転送するとtransfer内部の衝突事前判定
    // (destination.itemsを見る)が素通りしてしまう。ロード完了を待ってから転送する。
    guard destination.items.isEmpty else {
      transfer(items, from: source, to: destination, wasMove: wasMove)
      return
    }
    destination.loadIfNeeded()
    Task { [weak self] in
      await Self.waitUntilLoadCompletes(destination)
      guard let self else { return }
      self.transfer(items, from: source, to: destination, wasMove: wasMove)
    }
  }

  /// フォルダ比較で選んだ1項目を、既存のFileBrowserSession.copy→TransferQueue経路へ
  /// 委譲する。比較機能独自の転送処理や削除処理は持たない。
  @discardableResult
  func enqueueFolderComparisonCopy(
    _ item: FileItem,
    from source: FileBrowserSession,
    to destinationLocation: FileLocation,
    using targetTemplate: FileBrowserSession
  ) -> Bool {
    guard item.location.providerID == source.providerID,
      destinationLocation.providerID == targetTemplate.providerID
    else {
      return false
    }
    let destination = targetTemplate.makePeerSession(at: destinationLocation)
    let identifier = ObjectIdentifier(source)
    retiredBrowsers[identifier] = source
    source.retireFromBrowsing { [weak self] in
      self?.cleanupRetiredBrowsers()
    }
    destination.loadIfNeeded()
    Task { [weak self, source, destination] in
      await Self.waitUntilLoadCompletes(destination)
      guard let self else { return }
      self.transfer([item], from: source, to: destination, wasMove: false)
    }
    return true
  }

  /// 宛先セッションのロード完了(isLoading == false)を待つ。ロードが極端に遅延・停止しても
  /// 転送そのものが永久にブロックされないよう待機上限(5秒)を設ける(上限到達時は衝突事前
  /// 判定こそ効かないが、providerの書き込み時エラーとして扱われるだけで転送自体は進む)。
  private static func waitUntilLoadCompletes(_ destination: FileBrowserSession) async {
    for _ in 0..<1_000 {
      guard destination.isLoading else { return }
      try? await Task.sleep(for: .milliseconds(5))
    }
  }

  private static func loadRecentDestinationInventory(
    _ destination: FileBrowserSession, timeout: Duration
  ) async -> Bool {
    let wait = RecentInventoryWait()
    return await withCheckedContinuation { continuation in
      wait.continuation = continuation
      wait.loadingTask = Task {
        await destination.loadTransferDestinationInventory()
        wait.finish(loaded: true)
      }
      wait.timeoutTask = Task {
        try? await Task.sleep(for: timeout)
        wait.finish(loaded: false)
      }
    }
  }

  func undoLastTransfer() {
    guard let lastUndo else { return }
    self.lastUndo = nil
    switch lastUndo {
    case .transfer(let transferUndo):
      guard !transferUndo.items.isEmpty else {
        cleanupRetiredBrowsers()
        return
      }
      if transferUndo.wasMove {
        transferUndo.destination.move(
          transferUndo.items, to: transferUndo.source,
          destinationNames: transferUndo.originalNames)
      } else {
        transferUndo.destination.discardTransferredItems(transferUndo.items)
      }
      cleanupRetiredBrowsers()
    case .transferGroup(let transferUndos):
      if transferUndos.first?.wasMove == true {
        for undo in transferUndos {
          undo.destination.move(
            undo.items, to: undo.source, destinationNames: undo.originalNames)
        }
      } else if let destination = transferUndos.first?.destination {
        destination.discardTransferredItems(transferUndos.flatMap(\.items))
      }
      cleanupRetiredBrowsers()
    case .batchRename(let batchRenameUndo):
      let renames = batchRenameUndo.successes.reversed().map {
        (item: $0.renamedItem, newName: $0.oldName)
      }
      Task { [weak self, browser = batchRenameUndo.browser] in
        _ = await browser.batchRename(renames)
        self?.cleanupRetiredBrowsers()
      }
    }
  }

  func recordBatchRenameUndo(
    _ successes: [BatchRenameSuccess],
    in browser: FileBrowserSession
  ) {
    guard !successes.isEmpty else { return }
    lastUndo = .batchRename(BatchRenameUndo(browser: browser, successes: successes))
    cleanupRetiredBrowsers()
  }

  private func transfer(
    _ items: [FileItem],
    from source: FileBrowserSession,
    to destination: FileBrowserSession,
    wasMove: Bool,
    trace: DropPreparationTrace? = nil,
    recentOrigin: Bool = false,
    recordsUndo: Bool = true,
    onCompleted additionalCompletion: @escaping @MainActor () -> Void = {}
  ) {
    if recentOrigin || source.isRecentFilesActive {
      let groups = Self.recentTransferGroups(items)
      guard groups.reduce(0, { $0 + $1.items.count }) == items.count,
        Set(items.map(\.name)).count == items.count
      else {
        source.presentError(FileBrowserSessionError.transferUnavailable)
        trace?.finish(.rejected)
        return
      }
      lastUndo = nil
      let undoAccumulator = RecentTransferUndoAccumulator(expectedCount: groups.count)
      let destinationLocation = destination.currentLocation
      let fixedDestination = destination.makeTransferDestinationSession(at: destinationLocation)
      retiredBrowsers[ObjectIdentifier(fixedDestination)] = fixedDestination
      Task { [weak self, source, destination, fixedDestination, groups] in
        guard let self else { return }
        defer {
          fixedDestination.retireFromBrowsing { [weak self] in
            self?.cleanupRetiredBrowsers()
          }
        }
        let inventoryLoaded = await Self.loadRecentDestinationInventory(
          fixedDestination, timeout: self.recentDestinationInventoryTimeout)
        guard inventoryLoaded, fixedDestination.errorMessage == nil else {
          destination.presentError(FileBrowserSessionError.transferUnavailable)
          trace?.finish(.rejected)
          return
        }
        for group in groups {
          let peer = source.makePeerSession(at: group.parent)
          guard
            await peer.prepareRecentTransferBookmark(
              using: self.recentSourceBookmarkReader)
          else {
            source.presentError(FileBrowserSessionError.transferUnavailable)
            destination.presentError(FileBrowserSessionError.transferUnavailable)
            trace?.finish(.rejected)
            return
          }
          self.retiredBrowsers[ObjectIdentifier(peer)] = peer
          self.transfer(
            group.items, from: peer, to: fixedDestination, wasMove: wasMove,
            recordsUndo: false,
            onCompleted: { [weak self, weak source, weak peer] in
              guard let self, let peer else { return }
              if wasMove, let source,
                let clipboard = self.currentInternalClipboard,
                clipboard.source === source
              {
                let moved = Set(peer.lastCompletedTransfer?.items.map(\.location) ?? [])
                let remaining = clipboard.items.filter { !moved.contains($0.location) }
                self.consumedClipboardURLs.formUnion(moved.compactMap(\.localURL))
                self.clipboard =
                  remaining.isEmpty
                  ? nil
                  : ClipboardContents(
                    operation: clipboard.operation, items: remaining, source: source,
                    isRecentOrigin: clipboard.isRecentOrigin)
              }
              let completedUndo = peer.lastCompletedTransfer.flatMap {
                Self.transferUndo(
                  from: $0, source: peer, destination: fixedDestination, wasMove: wasMove)
              }
              let outcome = undoAccumulator.record(completedUndo)
              if outcome.finished {
                if let undos = outcome.entries {
                  self.lastUndo = undos.count == 1 ? .transfer(undos[0]) : .transferGroup(undos)
                }
                if destination.currentLocation == destinationLocation,
                  !destination.isRecentFilesActive
                {
                  destination.load()
                }
                additionalCompletion()
                self.cleanupRetiredBrowsers()
              }
            })
          peer.retireFromBrowsing { [weak self] in self?.cleanupRetiredBrowsers() }
        }
      }
      return
    }
    guard source.canTransferItems(to: destination, removesSourceAfterCopy: wasMove) else {
      trace?.finish(.rejected)
      return
    }
    // PendingTransfer(FileBrowserSession.swift:18)などの転送簿記(activeTransfers/
    // failedTransfer)もdestinationを強参照しており、挙動としてはこの強参照キャプチャは
    // 冗長である。ただし簿記側がdestinationを保持し続ける仕様に暗黙依存させないよう、
    // その場生成の宛先の寿命はこのクロージャでも転送完了まで明示的に支える。
    // sourceはこのクロージャを保持する側なので強参照にすると循環するためweakのまま維持する。
    let completed: @MainActor () -> Void = { [weak self, weak source] in
      guard let self, let source else { return }
      if recordsUndo {
        if let completed = source.lastCompletedTransfer,
          let undo = Self.transferUndo(
            from: completed, source: source, destination: destination, wasMove: wasMove)
        {
          self.lastUndo = .transfer(undo)
        } else {
          // 置換前の内容を保存していないため、上書き後のUndoは提供しない。
          self.lastUndo = nil
        }
      }
      if wasMove, let clipboard = self.currentInternalClipboard, clipboard.source === source {
        let transferredLocations = Set(source.lastCompletedTransfer?.items.map(\.location) ?? [])
        let remaining = clipboard.items.filter { !transferredLocations.contains($0.location) }
        self.consumedClipboardURLs.formUnion(transferredLocations.compactMap(\.localURL))
        self.clipboard =
          remaining.isEmpty
          ? nil
          : ClipboardContents(
            operation: clipboard.operation, items: remaining, source: source,
            isRecentOrigin: clipboard.isRecentOrigin)
      }
      additionalCompletion()
      self.cleanupRetiredBrowsers()
    }
    if wasMove {
      source.move(
        items,
        to: destination,
        onCompleted: completed,
        dropPreparationTrace: trace)
    } else {
      source.copy(
        items,
        to: destination,
        onCompleted: completed,
        dropPreparationTrace: trace)
    }
  }

  private static func transferUndo(
    from completed: FileBrowserSession.CompletedTransfer,
    source: FileBrowserSession,
    destination: FileBrowserSession,
    wasMove: Bool
  ) -> TransferUndo? {
    guard !completed.replacedExisting else { return nil }
    let transferred = transferredItems(
      completed.items, to: destination, at: completed.destination,
      itemOptions: completed.itemOptions)
    let originalNames = Dictionary(
      uniqueKeysWithValues: zip(transferred, completed.items).map {
        ($0.0.location, $0.1.name)
      })
    return TransferUndo(
      source: source, destination: destination, items: transferred,
      wasMove: wasMove, originalNames: originalNames)
  }

  static func recentTransferGroups(
    _ items: [FileItem]
  ) -> [(parent: FileLocation, items: [FileItem])] {
    var groups = [(parent: FileLocation, items: [FileItem])]()
    for item in items {
      guard let parent = item.location.deletingLastPathComponent() else { continue }
      if let index = groups.firstIndex(where: { $0.parent == parent }) {
        groups[index].items.append(item)
      } else {
        groups.append((parent, [item]))
      }
    }
    return groups
  }

  private func storeSelectedItems(operation: ClipboardOperation) {
    let source = activeTab.browser
    let items = source.selectableItemsSnapshot.orderedItems(for: activeTab.selectedItemURLs)
    guard !items.isEmpty else { return }
    fileClipboard.write(items.compactMap(\.location.localURL))
    clipboardChangeCount = fileClipboard.changeCount
    consumedClipboardURLs = []
    clipboard = ClipboardContents(
      operation: operation, items: items, source: source,
      isRecentOrigin: source.isRecentFilesActive)
    cleanupRetiredBrowsers()
  }

  private func canTransferSelectedItemsToOppositePane(wasMove: Bool) -> Bool {
    guard showsSecondaryPane,
      let destination = tab(for: activePane.opposite)?.browser,
      !activeTab.selectedItemURLs.isEmpty
    else {
      return false
    }
    return activeTab.browser.canTransferItems(
      to: destination,
      removesSourceAfterCopy: wasMove)
  }

  private static func transferredItems(
    _ sourceItems: [FileItem], to destination: FileBrowserSession,
    at destinationLocation: FileLocation? = nil,
    itemOptions: [FileLocation: TransferItemOptions] = [:]
  ) -> [FileItem] {
    sourceItems.compactMap { item in
      let name = itemOptions[item.location]?.destinationName ?? item.name
      guard
        let location = (destinationLocation ?? destination.currentLocation).appending(
          pathComponent: name)
      else {
        return nil
      }
      switch location.path {
      case .local(let url):
        return FileItem(
          url: url,
          providerID: destination.providerID,
          isDirectory: item.isDirectory,
          isSymbolicLink: item.isSymbolicLink,
          isAliasFile: item.isAliasFile,
          size: item.size,
          createdAt: item.createdAt,
          modifiedAt: item.modifiedAt,
          tags: item.tags,
          posixPermissions: item.posixPermissions,
          ownerName: item.ownerName,
          groupName: item.groupName)
      case .remote(let path):
        return FileItem(
          remotePath: path,
          url: URL(fileURLWithPath: "/\(name)"),
          providerID: destination.providerID,
          isDirectory: item.isDirectory,
          isSymbolicLink: item.isSymbolicLink,
          size: item.size,
          createdAt: item.createdAt,
          modifiedAt: item.modifiedAt,
          tags: item.tags,
          posixPermissions: item.posixPermissions,
          ownerName: item.ownerName,
          groupName: item.groupName,
          name: name)
      }
    }
  }

  private func restoreInterruptedTransfers() {
    Task { [weak self] in
      guard let self else { return }
      guard let queue = self.tabs.first?.browser.transferQueue else { return }
      let jobs = await queue.allJobs()
      let matches = Self.matchedRestorableTransfers(jobs: jobs, browsers: self.tabs.map(\.browser))
      for match in matches {
        match.source.restoreInterruptedTransfer(match.job, to: match.destination)
      }
      let matchedIDs = Set(matches.map { $0.job.id })
      for job in jobs where job.state == .interrupted && job.sourceAccessBookmarkData != nil {
        guard !matchedIDs.contains(job.id) else { continue }
        guard self.pendingRecentRestoreJobIDs.insert(job.id).inserted else { continue }
        defer { self.pendingRecentRestoreJobIDs.remove(job.id) }
        guard
          let destination = self.tabs.map(\.browser).first(where: {
            $0.providerID == job.destinationProviderID && $0.currentLocation == job.destination
          })
        else { continue }
        guard
          let source = await self.restoredRecentTransferSource(
            for: job, transferQueue: destination.transferQueue)
        else {
          destination.presentError(FileBrowserSessionError.transferResumeUnavailable)
          continue
        }
        self.retiredBrowsers[ObjectIdentifier(source)] = source
        source.restoreInterruptedTransfer(job, to: destination)
      }
    }
  }

  private static func matchesDisplayedSource(
    _ source: FileBrowserSession, for job: TransferJob
  ) -> Bool {
    guard job.sourceAccessBookmarkData != nil else { return true }
    guard let parent = job.items.first?.location.deletingLastPathComponent() else { return false }
    return source.providerID == job.sourceProviderID
      && source.currentLocation.representsSameDirectory(as: parent)
  }

  private func restoredRecentTransferSource(
    for job: TransferJob, transferQueue: TransferQueue
  ) async -> FileBrowserSession? {
    await Self.restoredRecentTransferSource(
      for: job, transferQueue: transferQueue,
      bookmarkCodec: SystemFolderBookmarkCodec(),
      accessManager: FolderBookmarkAccessManager())
  }

  static func restoredRecentTransferSource(
    for job: TransferJob,
    transferQueue: TransferQueue,
    bookmarkCodec: any FolderBookmarkCoding,
    accessManager: FolderBookmarkAccessManager,
    pathValidator: RecentFilePathValidator = .shared
  ) async -> FileBrowserSession? {
    guard job.sourceProviderID == .local,
      let bookmarkData = job.sourceAccessBookmarkData,
      let parent = job.items.first?.location.deletingLastPathComponent(),
      let parentURL = parent.localURL,
      job.items.allSatisfy({ $0.location.deletingLastPathComponent() == parent })
    else { return nil }
    // bookmark解決とscope開始は既存WorkspaceBrowserFactoryと同じ境界を使う。
    guard let resolved = try? bookmarkCodec.resolveBookmark(bookmarkData),
      parentURL.standardizedFileURL.pathComponents.starts(
        with: resolved.url.standardizedFileURL.pathComponents),
      let lease = try? WorkspaceBookmarkAccessLease(
        url: resolved.url, manager: accessManager, requiresSecurityScope: true)
    else { return nil }
    guard await pathValidator.contains(parentURL, within: resolved.url) else { return nil }
    return FileBrowserSession(
      provider: LocalFileProvider(), initialLocation: parent,
      transferQueue: transferQueue, startsBrowsing: false,
      workspaceBookmarkAccessLease: lease)
  }

  /// 復元対象のジョブ(.interrupted状態のみ。.failed/.cancelledは転送バー側の再試行動線が
  /// 担うため対象外)を、転送元・転送先どちらもプロバイダIDと現在地の両方が一致する
  /// タブへ対応付ける。ローカルプロバイダは全タブで同一providerIDを共有するため、
  /// providerIDだけの一致では無関係なローカルペインへ誤って復元してしまう
  /// (実機第2報バグA)。転送元の場所はjob.items先頭の親ディレクトリから導出し、
  /// 導出できない場合はそのジョブを復元対象から外す。
  static func matchedRestorableTransfers(
    jobs: [TransferJob], browsers: [FileBrowserSession]
  ) -> [(source: FileBrowserSession, destination: FileBrowserSession, job: TransferJob)] {
    var matches: [(source: FileBrowserSession, destination: FileBrowserSession, job: TransferJob)] =
      []
    for job in jobs {
      guard job.state == .interrupted else { continue }
      guard let firstItemLocation = job.items.first?.location,
        let sourceLocation = firstItemLocation.deletingLastPathComponent()
      else {
        continue
      }
      guard
        let source = browsers.first(where: {
          $0.providerID == job.sourceProviderID
            && $0.currentLocation.representsSameDirectory(as: sourceLocation)
        }),
        let destination = browsers.first(where: {
          $0.providerID == job.destinationProviderID
            && $0.currentLocation.representsSameDirectory(as: job.destination)
        })
      else {
        continue
      }
      matches.append((source, destination, job))
    }
    return matches
  }
}
