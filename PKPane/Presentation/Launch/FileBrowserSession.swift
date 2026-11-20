import AppKit
import Darwin
import Foundation
import Observation
import Synchronization
import UniformTypeIdentifiers
import os

enum ColumnDirectoryDatePolicy {
  static func canSkipRevalidation(fileSystemType: String?) -> Bool {
    fileSystemType == "apfs"
  }
}

/// カラム列挙や無音再検証で使うmtimeを専用キューで読む。応答しないファイルプロバイダが
/// 協調スレッドやメインスレッドを塞がないよう、期限ではnilを返して再列挙へ倒す。
private final class ColumnDirectoryDateReader: @unchecked Sendable {
  static let shared = ColumnDirectoryDateReader()

  private let queue: OperationQueue

  private init() {
    let dispatchQueue = DispatchQueue(
      label: "com.pky.PKPane.column-directory-date", qos: .userInitiated,
      attributes: .concurrent)
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 2
    queue.qualityOfService = .userInitiated
    queue.underlyingQueue = dispatchQueue
    self.queue = queue
  }

  func read(_ url: URL, requiresAPFS: Bool = true) async -> Date? {
    let race = ColumnDirectoryDateRace()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Date?, Never>) in
        race.install(continuation)
        let timer = Task {
          do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
          race.take()?.resume(returning: nil)
        }
        queue.addOperation {
          guard race.isPending else { return }
          guard !requiresAPFS || Self.canSkipRevalidation(at: url) else {
            race.take()?.resume(returning: nil)
            return
          }
          var freshURL = URL(fileURLWithPath: url.path, isDirectory: true)
          freshURL.removeAllCachedResourceValues()
          let modifiedAt = (try? freshURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
          if let continuation = race.take() {
            timer.cancel()
            continuation.resume(returning: modifiedAt)
          }
        }
      }
    } onCancel: {
      race.take()?.resume(returning: nil)
    }
  }

  private static func canSkipRevalidation(at url: URL) -> Bool {
    let descriptor = open(url.path, O_EVTONLY)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }
    var fileSystem = statfs()
    guard Darwin.fstatfs(descriptor, &fileSystem) == 0 else { return false }
    let fileSystemType = withUnsafeBytes(of: fileSystem.f_fstypename) { bytes in
      String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
    return ColumnDirectoryDatePolicy.canSkipRevalidation(fileSystemType: fileSystemType)
  }
}

private final class ColumnDirectoryDateRace: Sendable {
  private let continuation = Mutex<CheckedContinuation<Date?, Never>?>(nil)

  func install(_ value: CheckedContinuation<Date?, Never>) {
    continuation.withLock { $0 = value }
  }

  var isPending: Bool { continuation.withLock { $0 != nil } }

  func take() -> CheckedContinuation<Date?, Never>? {
    continuation.withLock { value in
      defer { value = nil }
      return value
    }
  }
}

struct FileItemRevealRequest: Equatable, Sendable {
  let generation: Int
  let itemURL: URL
  let directoryLocation: FileLocation
}

/// 選択とD&Dが共有する、表示済み項目の世代別索引。同じURLがルート・展開ツリー・
/// カラムへ重複していても最初の項目だけを採用し、従来のselectableItems順を維持する。
struct FileBrowserSelectableItemsSnapshot {
  private struct Entry {
    let item: FileItem
    let position: Int
  }

  private(set) var items: [FileItem] = []
  private var entriesByURL: [URL: Entry] = [:]

  init(estimatedCount: Int) {
    items.reserveCapacity(estimatedCount)
    entriesByURL.reserveCapacity(estimatedCount)
  }

  init(uniqueItems: [FileItem]) {
    items = uniqueItems
    entriesByURL.reserveCapacity(uniqueItems.count)
    for (position, item) in uniqueItems.enumerated() {
      entriesByURL[item.url] = Entry(item: item, position: position)
    }
  }

  mutating func append(contentsOf candidates: [FileItem]) {
    for item in candidates where entriesByURL[item.url] == nil {
      entriesByURL[item.url] = Entry(item: item, position: items.count)
      items.append(item)
    }
  }

  var count: Int { items.count }

  func item(for url: URL) -> FileItem? {
    entriesByURL[url]?.item
  }

  func orderedItems(for urls: Set<URL>) -> [FileItem] {
    urls.compactMap { entriesByURL[$0] }
      .sorted { $0.position < $1.position }
      .map(\.item)
  }
}

enum DirectorySnapshotCachePolicy {
  static let directoryLimit = 32
}

@Observable
@MainActor
final class FileBrowserSession {
  typealias ProviderSearchServiceFactory = @Sendable (Bool) -> any SearchService

  private struct RecentFilesPresentation {
    let roots: [URL]
    let accessLeases: [WorkspaceBookmarkAccessLease]
  }

  private enum NavigationEntry {
    case directory(FileLocation)
    case recentFiles(RecentFilesPresentation)
  }

  struct TransferConflict: Equatable {
    let sourceName: String
    let destinationName: String
    let remainingNames: [String]
    let remainingCount: Int
    let totalCount: Int
    let selectedCount: Int
    let replacesDirectory: Bool
    let remainingReplacesDirectory: Bool
    let isRemote: Bool
    let canKeepBoth: Bool
    let usesServerAssignedNames: Bool

    func replacementWarning(applyToRemaining: Bool) -> String {
      var warnings: [String] = []
      if replacesDirectory || (applyToRemaining && remainingReplacesDirectory) {
        warnings.append(
          String(
            localized: "フォルダ全体を置き換えます。既存フォルダ内だけにある項目も失われ、元に戻せません。"))
      }
      if isRemote {
        warnings.append(
          String(
            localized: "この接続では既存項目の削除後に転送します。中断・失敗すると旧宛先の内容が失われる場合があります。"))
      }
      return warnings.joined(separator: "\n")
    }
  }

  struct CompletedTransfer {
    let items: [FileItem]
    let destination: FileLocation
    let itemOptions: [FileLocation: TransferItemOptions]
    let replacedExisting: Bool
  }

  private struct ConflictResolutionState {
    var remainingItems: [FileItem]
    let destinationItemsByName: [String: FileItem]
    let totalCount: Int
    var occupiedNames: Set<String>
    var itemOptions: [FileLocation: TransferItemOptions]
    var skippedLocations: Set<FileLocation> = []
  }

  private struct PendingTransfer {
    let items: [FileItem]
    let destination: FileBrowserSession
    let removesSourceAfterCopy: Bool
    let onCompleted: @MainActor () -> Void
    let refreshesBrowsersOnCompletion: Bool
    let replacingExisting: Bool
    var itemOptions: [FileLocation: TransferItemOptions] = [:]
    var skippedItemCount = 0
  }

  private let provider: any FileBrowserProvider
  private let navigationBoundary: FileLocation?
  private let hasExternalParent: Bool
  private let workspaceBookmarkAccessLease: WorkspaceBookmarkAccessLease?
  private struct DirectorySnapshot {
    let items: [FileItem]
    let includesHiddenItems: Bool
    let directoryModifiedAt: Date?
  }

  private var directoryCache: LRUDictionary<FileLocation, DirectorySnapshot>
  private let directoryCacheLimit: Int
  private var history: [NavigationEntry] = []
  private var forwardHistory: [NavigationEntry] = []
  private var loadTask: Task<Void, Never>?
  private var hasStartedInitialLoad = false
  private var transferUpdateTask: Task<Void, Never>?
  private var isRetiredFromBrowsing = false
  private var retiredLifecycleDidBecomeIdle: (@MainActor () -> Void)?
  private var isPerformingFileOperation = false
  private var pendingTransfer: PendingTransfer?
  private var failedTransfer: PendingTransfer?
  /// pausedジョブの再起動後復元用。failed/cancelled/interruptedの再試行状態とは分離し、
  /// 一時停止ジョブの準備や再開が無関係なfailedTransferを上書きしないようにする。
  private var pausedTransfers: [UUID: PendingTransfer] = [:]
  private var activeTransfers: [UUID: PendingTransfer] = [:]
  private var activeTransferJobIDs: Set<UUID> = []
  /// activeTransferJobIDsはpausedも再開用に保持する一方、こちらは実際に実行中または
  /// 実行待ちのジョブだけを持つ。isTransferringと退役ライフサイクル判定の正本。
  private var executingTransferJobIDs: Set<UUID> = []
  private var resumingTransferJobIDs: Set<UUID> = []
  private var failedTransferJobID: UUID?
  /// 自動再接続(P1-3)がジョブIDごとに消費した自動リトライ試行回数。手動retryLastTransfer
  /// が呼ばれた時点でリセットされる(手動リトライは自動側の回数制限と独立して常に可能)。
  /// バックオフ待機・キャンセル対応自体はTransferQueue側(Fix A)で完結するため、ここでは
  /// 回数カウンタのみを持つ。
  private var autoReconnectAttempts: [UUID: Int] = [:]
  /// 自動再接続(P1-3)の試行間バックオフ。要素数がそのまま最大自動リトライ回数になる。
  /// テストでは短い値を注入し、実時間のTask.sleep(TransferQueue側)に依存せず検証する。
  private let autoReconnectBackoff: [Duration]
  let transferQueue: TransferQueue
  private let archiveService: ArchiveService
  private let remoteArchiveService: RemoteArchiveService
  private let providerSearchServiceFactory: ProviderSearchServiceFactory
  private let spotlightSearchService: any SearchService
  private let recentFilesService: any RecentFileSearching
  private var recentFilesPresentation: RecentFilesPresentation?
  /// 退役後もクリップボード・転送が元セッションを使う間、元ファイルの許可を保つ。
  private var retainedRecentAccessLeases: [String: WorkspaceBookmarkAccessLease] = [:]
  private var recentTransferSourceRoot: URL?
  private var recentTransferSourceBookmarkData: Data?
  private let fullDiskAccessChecker: any FullDiskAccessChecking
  private let gitStatusPreferences: any GitStatusPreferenceReading
  private let gitStatusProvider: any GitStatusProviding
  private let searchDebounceDuration: Duration
  private var searchDebounceTask: Task<Void, Never>?
  private var searchTask: Task<Void, Never>?
  private var currentFolderTagFilterTask: Task<Void, Never>?
  private var currentFolderTagFilterToken: UUID?
  private var currentFolderTagFilterText: String?
  private var currentFolderTagFilterMatchMode = NameMatchMode.literal
  private var searchSnapshotPublishTask: Task<Void, Never>?
  /// 現行publishタスクの識別トークン。ハンドルnil化の正当性確認に使う
  /// (scheduleSearchSnapshotPublication内のコメントを参照)。
  private var searchSnapshotPublishToken: UUID?
  private var activeSearchGeneration: UUID?
  private var searchProjection: SearchResultProjection?
  private var publishedSearchProjectionRevision: Int?
  private var searchSortOrder = FileItemSortOrder.name
  private var searchSortAscending = true
  private var pendingRevealRequest: FileItemRevealRequest?
  private var archiveTask: Task<Void, Never>?
  private var openItemsTask: Task<Void, Never>?
  private var openItemsToken: UUID?
  private var pendingOpenItems: [FileItem] = []
  private var revealGeneration = 0
  private var columnStateBeforeSearch: FileBrowserColumnState?
  private var columnLocationBeforeSearch: FileLocation?
  private var directoryWatcher: LocalDirectoryWatcher?
  private var watchedDirectoryPath: String?
  private var revalidationTask: Task<Void, Never>?
  @ObservationIgnored private var gitStatusTasks: [URL: Task<Void, Never>] = [:]
  @ObservationIgnored private var gitStatusTaskTokens: [URL: UUID] = [:]
  @ObservationIgnored private var gitStatusItemURLsByDirectory: [URL: Set<URL>] = [:]
  @ObservationIgnored private var gitStatusLocationsByDirectory: [URL: FileLocation] = [:]
  @ObservationIgnored private var gitStatusDirectoryRecency: [URL] = []
  @ObservationIgnored private var cloudStatusTasks: [FileLocation: Task<Void, Never>] = [:]
  @ObservationIgnored private var cloudStatusTaskTokens: [FileLocation: UUID] = [:]
  @ObservationIgnored private var cloudStatusItemURLsByDirectory: [FileLocation: Set<URL>] = [:]
  @ObservationIgnored private var cloudStatusDirectoryRecency: [FileLocation] = []
  /// 一覧の初期表示後に欠落したサイズ・更新日時を補完するタスク。読み込み世代が変わったら
  /// cancelし、古い場所の詳細取得結果が現在の一覧へ混入しないようにする。
  private var metadataEnrichmentTask: Task<Void, Never>?
  private var metadataEnrichmentGeneration = 0
  /// 初期表示後に自動取得するFinderタグ件数。一般的なペインの可視行を覆いつつ、
  /// 巨大フォルダで項目数に比例した属性I/Oを開始しない上限として固定する。
  private static let initialFinderTagEnrichmentLimit = 64
  /// リスト/アイコン/カラム/展開ツリーで実際にセルが構成された未補完項目。進行中のバッチへ
  /// 割り込まず、完了後の次バッチで最大64件ずつ消費する。
  @ObservationIgnored private var pendingVisibleFinderTagItems: [FileLocation: FileItem] = [:]
  /// ルート補完と展開ツリー補完が同じ可視項目を同時取得しないための集合。
  @ObservationIgnored private var finderTagEnrichmentLocationsInFlight = Set<FileLocation>()
  /// `tag:`検索だけは未表示項目も含む完全な結果が必要なため、次の補完で全件を要求する。
  @ObservationIgnored private var requiresAllFinderTagsForSearch = false
  @ObservationIgnored private(set) var isMetadataEnrichmentActive = false
  @ObservationIgnored private(set) var metadataEnrichmentRunCount = 0
  @ObservationIgnored private(set) var lastMetadataEnrichmentMeasurement:
    MetadataEnrichmentMeasurement?
  @ObservationIgnored private(set) var lastMetadataEnrichmentPreparationDuration = Duration.zero
  @ObservationIgnored private(set) var lastMetadataEnrichmentApplicationDuration = Duration.zero
  /// サイドバー用タグ名投影で走査したルート項目数。巨大一覧の再描画ごとに全件走査しない
  /// 性能契約をテストから観測する。
  @ObservationIgnored private(set) var sidebarFinderTagItemProjectionCount = 0
  /// isLoading/isRefreshing中に監視イベントが来て無音再検証を見送った場合に立てるフラグ。
  /// そのロードが完了した時点で1回だけ無音再検証を行い、取りこぼしを防ぐ。
  private var hasPendingWatcherEvent = false
  /// 監視武装完了チェックが無音再検証と重なった場合、チェック対象の場所を
  /// 完了時のmtime確認まで保留する。
  @ObservationIgnored private var pendingArmCompletionCheckLocation: FileLocation?
  /// 無音再検証の結果が正常にキャッシュへ適用されるたびに進む世代値。監視武装中に
  /// 再検証が完了したかを、タスクの完了順に依存せず判定するために使う。
  /// LocalDirectoryWatcher.opening(directoryURL:onChange:)によるfd取得(非同期)を
  /// 保持するタスク。新しい武装開始時とinvalidate()でcancelし、古いフォルダの武装が
  /// 遅れて完了して監視を差し替える(invalidate後に監視が復活する等)ことを防ぐ。
  private var watcherArmTask: Task<Void, Never>?
  /// リスト表示のフォルダその場展開(開閉三角)の状態。展開中フォルダの集合と子項目
  /// キャッシュを持つ純モデル(FileTreeState.swift参照)。@ObservableなクラスのStored
  /// プロパティのため、値の書き換えは通常のitems等と同じくObservationで検知される。
  private(set) var treeState = FileTreeState()
  /// 展開フォルダごとの子ロードタスク。折りたたみ→再展開や外部変更による再ロードで
  /// 前のタスクをcancelし、多重ロードを防ぐ。
  private var childLoadTasks: [FileLocation: Task<Void, Never>] = [:]
  /// 展開中フォルダのローカル監視(currentLocation自体のdirectoryWatcherとは別枠)。
  /// 折りたたみで解除する。
  private var expandedDirectoryWatchers: [FileLocation: LocalDirectoryWatcher] = [:]
  private var expandedWatcherArmTasks: [FileLocation: Task<Void, Never>] = [:]
  /// カラム表示中の階層と各階層の項目スナップショット。カラムのクリックでは通常の
  /// ナビゲーションloadを使わず、列専用タスクで必要な階層だけを読み込む。
  private(set) var columnState = FileBrowserColumnState() {
    didSet { selectableItemsColumnStateRevision &+= 1 }
  }
  private var columnLoadTasks: [FileLocation: Task<Void, Never>] = [:]
  private var columnLoadGenerations: [FileLocation: Int] = [:]
  @ObservationIgnored private var columnDirectoryWatchers: [FileLocation: LocalDirectoryWatcher] =
    [:]
  @ObservationIgnored private var columnWatcherArmTasks: [FileLocation: Task<Void, Never>] = [:]
  @ObservationIgnored private var columnRevalidationTasks: [FileLocation: Task<Void, Never>] = [:]
  private struct ColumnDisplayQuery: Equatable {
    let filterText: String
    let sortOrder: FileItemSortOrder
    let ascending: Bool
    let includesHiddenItems: Bool
  }
  private struct ColumnDisplayCacheEntry {
    let itemsRevision: Int
    let query: ColumnDisplayQuery
    let items: [FileItem]
  }
  @ObservationIgnored private var columnDisplayCache: [FileLocation: ColumnDisplayCacheEntry] = [:]
  /// テスト観測用: displayColumnsがフィルタ・ソート対象として走査した項目数。
  /// 選択だけの変更で全件再変換していないことを実操作相当のテストで検証する。
  @ObservationIgnored private(set) var columnItemsProjectionCount = 0
  @ObservationIgnored
  private(set) var columnItemsProjectionCountByLocation: [FileLocation: Int] = [:]

  private(set) var currentLocation: FileLocation
  private(set) var loadedFinderTagNames: [String] = []
  private(set) var items: [FileItem] = [] {
    didSet {
      if capabilities.contains(.finderTags) {
        sidebarFinderTagItemProjectionCount += items.count
        var seenNames = Set<String>()
        var updatedFinderTagNames: [String] = []
        for item in items {
          for rawName in item.tags ?? [] {
            let components = rawName.split(
              separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            guard let first = components.first, !first.isEmpty else { continue }
            if seenNames.insert(String(first)).inserted {
              updatedFinderTagNames.append(rawName)
            }
          }
        }
        if loadedFinderTagNames != updatedFinderTagNames {
          loadedFinderTagNames = updatedFinderTagNames
        }
      }
      itemsGeneration &+= 1
      itemsReplacementCount &+= 1
      // itemsへの書き込みはすべてここを通るため、無音再検証(revalidateSilently)が
      // 古い結果で上書きしないようにする権威世代の更新もここへ一元化する。
      itemsAuthorityEpoch &+= 1
      if columnState.isActive {
        var state = columnState
        state.setItems(items, at: currentLocation)
        if state != columnState {
          columnState = state
        }
      }
      refreshCurrentFolderTagFilterIfNeeded()
    }
  }
  private(set) var isLoading = false
  private(set) var isRefreshing = false
  private(set) var isTransferring = false
  private var cloudTransferJobIDs: Set<UUID> = []
  private(set) var cloudTransferPreparationNotice: String?
  private(set) var pendingTransferConflict: TransferConflict?
  private var transferConflictState: ConflictResolutionState?
  private(set) var lastCompletedTransfer: CompletedTransfer?
  var transferResolutionNotice: String?
  private(set) var pendingPermanentDeleteItems: [FileItem] = []
  private(set) var isArchiving = false
  private(set) var archiveProgress: ArchiveProgress?
  private(set) var revealRequest: FileItemRevealRequest?
  private(set) var searchText = ""
  private(set) var searchScope = SearchScope.currentFolder
  private(set) var searchUsesRegex = false
  private(set) var isSearching = false
  private(set) var isRecentFilesActive = false
  private(set) var searchResults: [SearchResult] = []
  private var searchDisplayItems: [FileItem] = []
  private var searchResultLocations: Set<FileLocation> = []
  private(set) var searchPartialErrorCount = 0
  private(set) var searchLimitReached: SearchLimit?
  private(set) var searchScopeNotice: String?
  private var fullDiskAccessStatus = FullDiskAccessStatus.unknown
  private(set) var showsHiddenFiles = false
  private var needsHiddenFilesReload = false
  private(set) var errorMessage: String?
  private(set) var previewURL: URL?
  private(set) var gitStatuses: [URL: GitFileStatus] = [:]
  private(set) var cloudDownloadStatuses: [URL: CloudDownloadStatus] = [:]
  var gitStatusTrackedDirectoryCount: Int { gitStatusItemURLsByDirectory.count }
  var cloudStatusTrackedDirectoryCount: Int { cloudStatusItemURLsByDirectory.count }
  var cloudStatusActiveTaskCount: Int { cloudStatusTasks.count }
  var directorySnapshotCacheCount: Int { directoryCache.count }
  var hasTransferUpdateSubscription: Bool { transferUpdateTask != nil }

  func hasCachedDirectorySnapshot(at location: FileLocation) -> Bool {
    directoryCache.value(forKey: location, touching: false) != nil
  }

  init(
    provider: any FileBrowserProvider,
    initialLocation: FileLocation,
    navigationBoundary: FileLocation? = nil,
    hasExternalParent: Bool = false,
    transferQueue: TransferQueue = .shared,
    archiveService: ArchiveService = ArchiveService(),
    remoteArchiveService: RemoteArchiveService = RemoteArchiveService(),
    autoReconnectBackoff: [Duration] = [.seconds(1), .seconds(2), .seconds(4)],
    searchDebounceDuration: Duration = .milliseconds(300),
    providerSearchServiceFactory: ProviderSearchServiceFactory? = nil,
    spotlightSearchService: (any SearchService)? = nil,
    recentFilesService: any RecentFileSearching = RecentFilesService(),
    fullDiskAccessChecker: any FullDiskAccessChecking = SystemFullDiskAccessChecker(),
    gitStatusPreferences: any GitStatusPreferenceReading = GitStatusPreferencesStore.shared,
    gitStatusProvider: any GitStatusProviding = GitStatusService(),
    directoryCacheLimit: Int = DirectorySnapshotCachePolicy.directoryLimit,
    startsBrowsing: Bool = true,
    workspaceBookmarkAccessLease: WorkspaceBookmarkAccessLease? = nil
  ) {
    self.provider = provider
    currentLocation = initialLocation
    directoryCache = LRUDictionary(capacity: directoryCacheLimit)
    self.directoryCacheLimit = directoryCacheLimit
    self.navigationBoundary = navigationBoundary
    self.hasExternalParent = hasExternalParent
    self.transferQueue = transferQueue
    self.archiveService = archiveService
    self.remoteArchiveService = remoteArchiveService
    self.autoReconnectBackoff = autoReconnectBackoff
    self.searchDebounceDuration = searchDebounceDuration
    self.providerSearchServiceFactory =
      providerSearchServiceFactory
      ?? { includesHiddenItems in
        ProviderSearchEngine(provider: provider, includesHiddenItems: includesHiddenItems)
      }
    self.spotlightSearchService = spotlightSearchService ?? SpotlightSearchEngine()
    self.recentFilesService = recentFilesService
    self.fullDiskAccessChecker = fullDiskAccessChecker
    self.gitStatusPreferences = gitStatusPreferences
    self.gitStatusProvider = gitStatusProvider
    self.workspaceBookmarkAccessLease = workspaceBookmarkAccessLease
    isRetiredFromBrowsing = !startsBrowsing
    if startsBrowsing {
      startObservingTransferUpdatesIfNeeded()
    }
  }

  private func startObservingTransferUpdatesIfNeeded() {
    guard transferUpdateTask == nil else { return }
    transferUpdateTask = Task { [weak self, transferQueue] in
      let updates = await transferQueue.updates()
      for await jobs in updates {
        guard !Task.isCancelled, let self else { return }
        self.receiveTransferUpdates(jobs)
      }
    }
  }

  private func stopObservingTransferUpdates() {
    transferUpdateTask?.cancel()
    transferUpdateTask = nil
  }

  var capabilities: FileProviderCapabilities { provider.capabilities }
  var executableCapabilities: FileProviderCapabilities { provider.executableCapabilities }
  var providerID: FileProviderID { provider.id }
  var connectionID: FileProviderConnectionID? { provider.connectionID }
  var isWorkspaceRemotePlaceholder: Bool {
    provider is WorkspaceRemotePlaceholderProvider
  }
  var usesLocalFileProvider: Bool { provider is LocalFileProvider }
  var supportsThisMacSearch: Bool { usesLocalFileProvider }
  var isSearchActive: Bool {
    isRecentFilesActive || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
  var showsThisMacAccessGuidance: Bool {
    !isRecentFilesActive
      && FileBrowserSearchPresentation.shouldShowThisMacAccessGuidance(
        isSearchActive: isSearchActive,
        scope: searchScope,
        fullDiskAccessStatus: fullDiskAccessStatus)
  }
  var currentPathDescription: String {
    currentLocation.localURL?.path ?? currentLocation.remotePath ?? ""
  }
  var canGoBack: Bool { !history.isEmpty }
  var canGoForward: Bool { !forwardHistory.isEmpty }
  var breadcrumbs: [FileBrowserBreadcrumb] {
    provider.breadcrumbs(for: currentLocation, constrainedTo: navigationBoundary)
  }
  var canGoToParent: Bool { parentLocation != nil || hasExternalParent }
  var canEditRemotely: Bool { provider is any RemoteEditProvider }
  var canDuplicate: Bool {
    executableCapabilities.contains(.copyWithinProvider)
      && provider is any FileBrowserDuplicateProvider
  }
  var canResolveDetailThumbnailURL: Bool {
    provider is any FileBrowserPreviewProvider
  }
  var canSetPosixPermissions: Bool {
    provider is any FileBrowserPosixPermissionsProvider
      && provider is any FileBrowserItemDetailProvider
  }
  var canEditFinderTags: Bool {
    capabilities.contains(.finderTags)
      && provider is any FileBrowserFinderTagProvider
      && provider is any FileBrowserItemDetailProvider
  }
  var hasActiveBrowsingResources: Bool {
    loadTask != nil
      || revalidationTask != nil
      || metadataEnrichmentTask != nil
      || watcherArmTask != nil
      || directoryWatcher != nil
      || !childLoadTasks.isEmpty
      || !expandedWatcherArmTasks.isEmpty
      || !expandedDirectoryWatchers.isEmpty
      || !columnLoadTasks.isEmpty
      || columnState.isActive
      || searchDebounceTask != nil
      || searchTask != nil
      || currentFolderTagFilterTask != nil
      || searchSnapshotPublishTask != nil
      || !gitStatusTasks.isEmpty
      || !cloudStatusTasks.isEmpty
  }
  var hasBackgroundFileOperation: Bool {
    isTransferring || isArchiving || isPerformingFileOperation || openItemsTask != nil
  }
  var canArchive: Bool {
    guard capabilities.contains(.write) else { return false }
    return currentLocation.localURL != nil || RemoteArchiveService.supports(provider)
  }
  var archiveInvalidEntryCount: Int {
    (provider as? ArchiveFileProvider)?.invalidEntryCount ?? 0
  }
  var canRemoveItemsAfterCopy: Bool {
    provider is any FileBrowserTransferProvider
  }

  var supportsGitStatusDisplay: Bool {
    capabilities.contains(.gitStatus) && currentLocation.localURL != nil
  }

  var supportsCloudDownloadStatusDisplay: Bool {
    capabilities.contains(.cloudDownloadStatus) && currentLocation.localURL != nil
  }

  /// 設定画面の変更を現在表示中のフォルダへ反映する実経路。OFFでは進行中の取得と
  /// 表示状態だけを破棄し、検出・status実行・キャッシュAPIへは入らない。
  func applyGitStatusPreference() {
    guard gitStatusPreferences.isEnabled else {
      cancelAllGitStatusLoadsAndClearStatuses()
      return
    }
    var locations = treeState.expandedLocations
    locations.insert(currentLocation)
    locations.formUnion(columnState.columns.map(\.location))
    for location in locations {
      startGitStatusLoad(at: location, invalidatingCache: false)
    }
  }

  private func startGitStatusLoad(
    at location: FileLocation,
    invalidatingCache: Bool
  ) {
    guard gitStatusPreferences.isEnabled,
      capabilities.contains(.gitStatus),
      let directory = location.localURL?.standardizedFileURL
    else { return }

    let previousTask = gitStatusTasks[directory]
    previousTask?.cancel()
    if invalidatingCache {
      removeGitStatuses(in: directory)
    }
    let token = UUID()
    gitStatusTaskTokens[directory] = token
    let task = Task { [weak self, gitStatusProvider] in
      guard let self else { return }
      defer {
        if self.gitStatusTaskTokens[directory] == token {
          self.gitStatusTasks[directory] = nil
          self.gitStatusTaskTokens[directory] = nil
        }
      }
      if let previousTask {
        await previousTask.value
      }
      guard !Task.isCancelled,
        self.gitStatusTaskTokens[directory] == token,
        self.isGitStatusDirectoryDisplayed(location)
      else { return }
      if invalidatingCache {
        await gitStatusProvider.invalidate(directory: directory)
      }
      guard !Task.isCancelled, self.gitStatusTaskTokens[directory] == token else { return }
      let statuses = await gitStatusProvider.statuses(in: directory)
      guard !Task.isCancelled,
        self.gitStatusTaskTokens[directory] == token,
        self.isGitStatusDirectoryDisplayed(location)
      else { return }
      self.replaceGitStatuses(statuses, in: directory, at: location)
    }
    gitStatusTasks[directory] = task
  }

  private func isGitStatusDirectoryDisplayed(_ location: FileLocation) -> Bool {
    currentLocation == location
      || treeState.isExpanded(location)
      || columnState.columns.contains(where: { $0.location == location })
  }

  private func replaceGitStatuses(
    _ statuses: [URL: GitFileStatus],
    in directory: URL,
    at location: FileLocation
  ) {
    removeGitStatuses(in: directory)
    guard !statuses.isEmpty else { return }
    let itemURLs = Set(statuses.keys)
    gitStatusItemURLsByDirectory[directory] = itemURLs
    gitStatusLocationsByDirectory[directory] = location
    gitStatuses.merge(statuses, uniquingKeysWith: { _, newValue in newValue })
    recordGitStatusDirectoryAccess(directory)
  }

  private func removeGitStatuses(in directory: URL) {
    gitStatusDirectoryRecency.removeAll { $0 == directory }
    removeGitStatusEntries(in: directory)
  }

  private func removeGitStatusEntries(in directory: URL) {
    gitStatusLocationsByDirectory[directory] = nil
    guard let itemURLs = gitStatusItemURLsByDirectory.removeValue(forKey: directory) else {
      return
    }
    for itemURL in itemURLs {
      gitStatuses[itemURL] = nil
    }
  }

  private func recordGitStatusDirectoryAccess(_ directory: URL) {
    gitStatusDirectoryRecency.append(directory)
    while gitStatusDirectoryRecency.count > GitStatusCachePolicy.directoryLimit {
      guard
        let evictionIndex = gitStatusDirectoryRecency.firstIndex(where: { candidate in
          guard let location = gitStatusLocationsByDirectory[candidate] else { return true }
          return !isGitStatusDirectoryDisplayed(location)
        })
      else {
        // 表示中のカラム・展開フォルダ・現在地はバッジを消さない。全件が表示中なら
        // 128件超過を許容し、保持数は表示中件数+非表示キャッシュ上限の範囲に収める。
        break
      }
      let evictedDirectory = gitStatusDirectoryRecency.remove(at: evictionIndex)
      // recencyは上で除去済みなので、通常削除を経由せず状態エントリだけを掃除する。
      removeGitStatusEntries(in: evictedDirectory)
    }
  }

  private func cancelAllGitStatusLoadsAndClearStatuses() {
    for task in gitStatusTasks.values { task.cancel() }
    gitStatusTasks.removeAll()
    gitStatusTaskTokens.removeAll()
    gitStatusItemURLsByDirectory.removeAll()
    gitStatusLocationsByDirectory.removeAll()
    gitStatusDirectoryRecency.removeAll()
    if !gitStatuses.isEmpty {
      gitStatuses.removeAll(keepingCapacity: true)
    }
  }

  /// 一覧の初回列挙を遅らせず、iCloudの状態だけを後追いで補完する。Finderで
  /// 「ダウンロードを削除」した場合はディレクトリmtimeが変わらないため、明示更新時に
  /// この状態を再取得する。
  private func startCloudStatusLoad(
    at location: FileLocation,
    invalidatingCache: Bool = false
  ) {
    guard capabilities.contains(.cloudDownloadStatus),
      let cloudStatusProvider = provider as? any FileBrowserCloudStatusMetadataProvider
    else { return }

    cloudStatusTasks[location]?.cancel()
    if invalidatingCache {
      removeCloudStatuses(in: location)
    }
    let token = UUID()
    cloudStatusTaskTokens[location] = token
    let itemLocations = cloudStatusItemLocations(at: location)
    let task = Task { [weak self] in
      guard let self else { return }
      defer {
        if self.cloudStatusTaskTokens[location] == token {
          self.cloudStatusTasks[location] = nil
          self.cloudStatusTaskTokens[location] = nil
        }
      }
      guard await cloudStatusProvider.isCloudManagedDirectory(location) else { return }
      let statuses = await cloudStatusProvider.cloudDownloadStatuses(itemLocations: itemLocations)
      guard !Task.isCancelled,
        self.cloudStatusTaskTokens[location] == token,
        self.isCloudStatusDirectoryDisplayed(location)
      else { return }
      self.replaceCloudStatuses(statuses, in: location)
    }
    cloudStatusTasks[location] = task
  }

  private func cloudStatusItemLocations(at location: FileLocation) -> [FileLocation] {
    if currentLocation == location {
      return items.map(\.location)
    }
    if let childItems = treeState.children(of: location) {
      return childItems.map(\.location)
    }
    if let column = columnState.columns.first(where: { $0.location == location }) {
      return column.items.map(\.location)
    }
    return []
  }

  private func isCloudStatusDirectoryDisplayed(_ location: FileLocation) -> Bool {
    currentLocation == location
      || treeState.isExpanded(location)
      || columnState.columns.contains(where: { $0.location == location })
  }

  private func replaceCloudStatuses(
    _ statuses: [URL: CloudDownloadStatus],
    in directory: FileLocation
  ) {
    removeCloudStatuses(in: directory)
    guard !statuses.isEmpty else { return }
    cloudStatusItemURLsByDirectory[directory] = Set(statuses.keys)
    cloudDownloadStatuses.merge(statuses, uniquingKeysWith: { _, newValue in newValue })
    recordCloudStatusDirectoryAccess(directory)
  }

  private func removeCloudStatuses(in directory: FileLocation) {
    cloudStatusDirectoryRecency.removeAll { $0 == directory }
    removeCloudStatusEntries(in: directory)
  }

  private func removeCloudStatusEntries(in directory: FileLocation) {
    guard let itemURLs = cloudStatusItemURLsByDirectory.removeValue(forKey: directory) else {
      return
    }
    for itemURL in itemURLs {
      cloudDownloadStatuses[itemURL] = nil
    }
  }

  private func recordCloudStatusDirectoryAccess(_ directory: FileLocation) {
    cloudStatusDirectoryRecency.append(directory)
    while cloudStatusDirectoryRecency.count > CloudStatusCachePolicy.directoryLimit {
      guard
        let evictionIndex = cloudStatusDirectoryRecency.firstIndex(where: { candidate in
          !isCloudStatusDirectoryDisplayed(candidate)
        })
      else {
        // 表示中のカラム・展開フォルダ・現在地はバッジを消さない。全件が表示中なら
        // 128件超過を許容し、保持数は表示中件数+非表示キャッシュ上限の範囲に収める。
        break
      }
      let evictedDirectory = cloudStatusDirectoryRecency.remove(at: evictionIndex)
      // recencyは上で除去済みなので、通常削除を経由せず状態エントリだけを掃除する。
      removeCloudStatusEntries(in: evictedDirectory)
    }
  }

  private func removeCloudStatusesOutsideDisplayedDirectories() {
    let obsoleteLocations = cloudStatusItemURLsByDirectory.keys.filter {
      !isCloudStatusDirectoryDisplayed($0)
    }
    for location in obsoleteLocations {
      removeCloudStatuses(in: location)
    }
    let obsoleteTaskLocations = cloudStatusTasks.keys.filter {
      !isCloudStatusDirectoryDisplayed($0)
    }
    for location in obsoleteTaskLocations {
      cancelCloudStatusLoad(at: location)
    }
  }

  private func cancelCloudStatusLoad(at location: FileLocation) {
    cloudStatusTasks[location]?.cancel()
    cloudStatusTasks[location] = nil
    cloudStatusTaskTokens[location] = nil
  }

  private func cancelAllCloudStatusLoadsAndClearStatuses() {
    for task in cloudStatusTasks.values { task.cancel() }
    cloudStatusTasks.removeAll()
    cloudStatusTaskTokens.removeAll()
    cloudStatusItemURLsByDirectory.removeAll()
    cloudStatusDirectoryRecency.removeAll()
    if !cloudDownloadStatuses.isEmpty {
      cloudDownloadStatuses.removeAll(keepingCapacity: true)
    }
  }

  func canTransferItems(
    to destination: FileBrowserSession,
    removesSourceAfterCopy: Bool
  ) -> Bool {
    guard !destination.isRecentFilesActive else { return false }
    guard destination.capabilities.contains(.write) else { return false }
    if provider.id == destination.provider.id {
      guard provider is any FileBrowserTransferProvider else { return false }
      return !removesSourceAfterCopy || canRemoveItemsAfterCopy
    }
    guard provider is any FileStreamReadableProvider,
      destination.provider is any FileStreamTransferProvider,
      destination.provider is any FileTransferCommitProvider,
      destination.provider is any FileBrowserOperationProvider
    else {
      return false
    }
    return !removesSourceAfterCopy || canRemoveItemsAfterCopy
  }

  func canCreateArchive(from archiveItems: [FileItem]) -> Bool {
    !isRecentFilesActive && archiveDirectoryLocation(for: archiveItems) != nil
  }

  func createArchive(_ archiveItems: [FileItem], format: ArchiveFormat = .zip) {
    guard !isRecentFilesActive,
      let directoryLocation = archiveDirectoryLocation(for: archiveItems),
      !isArchiving
    else { return }
    let name = archiveName(for: archiveItems, format: format)
    if let directoryURL = directoryLocation.localURL {
      createLocalArchive(
        archiveItems,
        directoryURL: directoryURL,
        directoryLocation: directoryLocation,
        name: name,
        format: format)
      return
    }
    let provider = provider
    startArchiveOperation {
      try await self.remoteArchiveService.createArchive(
        from: archiveItems,
        in: directoryLocation,
        preferredName: name,
        format: format,
        using: provider,
        archiveService: self.archiveService,
        progress: Self.archiveProgressHandler(for: self))
    } onSuccess: { archiveName in
      try await self.refreshAndRevealCreatedArchive(
        named: archiveName,
        at: nil,
        in: directoryLocation)
    }
  }

  private func createLocalArchive(
    _ archiveItems: [FileItem],
    directoryURL: URL,
    directoryLocation: FileLocation,
    name: String,
    format: ArchiveFormat
  ) {
    // 完了URLから場所を作り直すと、/varと/private/varのような同一実体の表記差で
    // 展開状態・カラム状態の安定IDと一致しない。作成開始時点の表示モデルからIDを捕捉する。
    let sourceURLs = archiveItems.compactMap(\.location.localURL)
    startArchiveOperation {
      try await self.archiveService.createArchive(
        from: sourceURLs,
        in: directoryURL,
        name: name,
        format: format,
        progress: Self.archiveProgressHandler(for: self))
    } onSuccess: { archiveURL in
      try await self.refreshAndRevealCreatedArchive(
        named: archiveURL.lastPathComponent,
        at: archiveURL,
        in: directoryLocation)
    }
  }

  func extractArchive(_ item: FileItem, destination: ArchiveExtractionDestination) {
    guard !isRecentFilesActive, canArchive,
      !item.isDirectory,
      ArchiveFormat(url: item.url) != nil,
      !isArchiving
    else { return }
    if let archiveURL = item.location.localURL,
      let directoryURL = currentLocation.localURL
    {
      extractLocalArchive(item, archiveURL: archiveURL, directoryURL: directoryURL, to: destination)
      return
    }
    let provider = provider
    let directoryLocation = currentLocation
    startArchiveOperation {
      try await self.remoteArchiveService.extractArchive(
        item,
        in: directoryLocation,
        destination: destination,
        using: provider,
        archiveService: self.archiveService,
        progress: Self.archiveProgressHandler(for: self))
    } onSuccess: {
      try await self.refreshContents()
    }
  }

  private func extractLocalArchive(
    _ item: FileItem,
    archiveURL: URL,
    directoryURL: URL,
    to destination: ArchiveExtractionDestination,
    organizingForDefaultOpen: Bool = false
  ) {
    let directoryLocation =
      organizingForDefaultOpen
      ? displayedArchiveDirectoryLocation(for: directoryURL) : nil
    startArchiveOperation {
      try await self.archiveService.extractArchive(
        at: archiveURL,
        in: directoryURL,
        destination: destination,
        organizingForDefaultOpen: organizingForDefaultOpen,
        progress: Self.archiveProgressHandler(for: self))
    } onSuccess: { outputURL in
      if organizingForDefaultOpen {
        if let directoryLocation {
          try await self.refreshAndRevealCreatedArchive(
            named: outputURL.lastPathComponent, at: outputURL, in: directoryLocation)
        }
      } else {
        try await self.refreshContents()
      }
    }
  }

  func cancelArchiveOperation() {
    pendingOpenItems = []
    openItemsTask?.cancel()
    archiveTask?.cancel()
  }

  func editExternally(_ item: FileItem, using controller: RemoteEditController = .shared) {
    Task {
      await controller.startEditing(item, using: provider)
    }
  }

  func restoreRemoteEdits(using controller: RemoteEditController = .shared) {
    controller.restore(using: provider)
  }

  private nonisolated static func directoryModifiedAt(of location: FileLocation) -> Date? {
    guard let url = location.localURL else { return nil }
    return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
      .contentModificationDate
  }

  // MARK: - 検索

  func startRecentFiles(
    authorizedRoots: [URL],
    accessLeases: [WorkspaceBookmarkAccessLease] = []
  ) {
    guard !accessLeases.isEmpty else { return }
    let roots = authorizedRoots.filter { root in
      accessLeases.contains { $0.rootURL.standardizedFileURL == root.standardizedFileURL }
    }
    for lease in accessLeases {
      retainedRecentAccessLeases[lease.rootURL.standardizedFileURL.path] = lease
    }
    startRecentFiles(
      RecentFilesPresentation(roots: roots, accessLeases: accessLeases),
      recordsHistory: true)
  }

  private func startRecentFiles(
    _ presentation: RecentFilesPresentation,
    recordsHistory: Bool
  ) {
    guard usesLocalFileProvider, !presentation.roots.isEmpty else { return }
    if recordsHistory, !isRecentFilesActive {
      history.append(.directory(currentLocation))
      forwardHistory.removeAll()
    }
    cancelSearch(clearText: true, clearRevealRequest: true)
    recentFilesPresentation = presentation
    isRecentFilesActive = true
    isSearching = true
    searchScopeNotice = String(localized: "アクセスを許可した場所の最近のファイル")
    let generation = UUID()
    activeSearchGeneration = generation
    let projection = SearchResultProjection(
      sortOrder: .name, ascending: true,
      includesHiddenItems: showsHiddenFiles, sortsByLastUsedAt: true)
    searchProjection = projection
    let service = recentFilesService
    searchTask = Task { [weak self] in
      guard let self else { return }
      await self.consumeSearchUpdates(
        service.search(authorizedRoots: presentation.roots, generation: generation),
        generation: generation, projection: projection)
    }
  }

  func setSearchText(_ text: String) {
    guard text != searchText else { return }
    if isRecentFilesActive {
      cancelSearch(clearText: true, clearRevealRequest: true)
    }
    let wasSearchActive = isSearchActive
    searchText = text
    if !wasSearchActive, isSearchActive, columnState.isActive {
      columnStateBeforeSearch = columnState
      columnLocationBeforeSearch = currentLocation
    }
    scheduleSearch()
  }

  func setSearchScope(_ scope: SearchScope) {
    guard !isRecentFilesActive else { return }
    guard scope != searchScope else { return }
    guard scope != .thisMac || supportsThisMacSearch else { return }
    searchScope = scope
    guard isSearchActive else { return }
    scheduleSearch()
  }

  func setSearchUsesRegex(_ usesRegex: Bool) {
    guard !isRecentFilesActive else { return }
    guard usesRegex != searchUsesRegex else { return }
    searchUsesRegex = usesRegex
    guard isSearchActive else { return }
    scheduleSearch()
  }

  func setSearchSortOrder(_ sortOrder: FileItemSortOrder, ascending: Bool) {
    guard self.searchSortOrder != sortOrder || searchSortAscending != ascending else { return }
    self.searchSortOrder = sortOrder
    searchSortAscending = ascending
    guard isSearchActive, let projection = searchProjection,
      let generation = activeSearchGeneration
    else { return }
    Task { [weak self] in
      await projection.updateSortOrder(sortOrder, ascending: ascending)
      guard let self, self.activeSearchGeneration == generation else { return }
      await self.publishSearchSnapshot(from: projection, generation: generation)
    }
  }

  func endSearch() {
    cancelSearch(clearText: true, clearRevealRequest: true)
    reloadForHiddenFilesIfNeeded()
  }

  func isSearchResult(_ item: FileItem) -> Bool {
    isSearchActive && searchResultLocations.contains(item.location)
  }

  func revealSearchResult(_ item: FileItem) {
    guard let result = searchResults.first(where: { $0.item.location == item.location }) else {
      return
    }
    let recent = recentFilesPresentation
    if let recent {
      history.append(.recentFiles(recent))
      forwardHistory.removeAll()
    }
    cancelSearch(clearText: true, clearRevealRequest: true)
    revealItem(
      at: result.item.url, in: result.parent,
      recordsHistory: recent == nil)
  }

  func revealItem(
    at itemURL: URL, in directory: FileLocation,
    recordsHistory: Bool = true
  ) {
    revealGeneration &+= 1
    pendingRevealRequest = FileItemRevealRequest(
      generation: revealGeneration,
      itemURL: itemURL,
      directoryLocation: directory)
    if directory == currentLocation {
      publishPendingSearchRevealIfNeeded(at: currentLocation, items: items)
      if pendingRevealRequest != nil {
        load()
      }
    } else {
      navigate(to: directory, recordsHistory: recordsHistory)
    }
  }

  private func scheduleSearch() {
    searchDebounceTask?.cancel()
    searchTask?.cancel()
    currentFolderTagFilterTask?.cancel()
    searchSnapshotPublishTask?.cancel()
    searchDebounceTask = nil
    searchTask = nil
    currentFolderTagFilterTask = nil
    currentFolderTagFilterToken = nil
    currentFolderTagFilterText = nil
    currentFolderTagFilterMatchMode = .literal
    searchSnapshotPublishTask = nil
    searchProjection = nil
    publishedSearchProjectionRevision = nil
    activeSearchGeneration = nil
    searchPartialErrorCount = 0
    searchLimitReached = nil
    searchScopeNotice = nil

    let normalizedText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedText.isEmpty else {
      isSearching = false
      resetSearchResults()
      reloadForHiddenFilesIfNeeded()
      return
    }
    let parsedQuery = SearchQueryParser.parse(normalizedText)
    if searchUsesRegex {
      let nameText =
        parsedQuery.hasTagTerms || parsedQuery.hasContentTerms
        ? parsedQuery.nameText
        : normalizedText
      guard NameMatcher(pattern: nameText, mode: .regex).isValid else {
        isSearching = false
        resetSearchResults()
        searchScopeNotice = String(localized: "正規表現が無効です")
        return
      }
      guard searchScope != .thisMac else {
        isSearching = false
        resetSearchResults()
        searchScopeNotice = String(localized: "このMacでは正規表現検索を利用できません")
        return
      }
    }
    if parsedQuery.hasTagTerms, !capabilities.contains(.finderTags) {
      isSearching = false
      resetSearchResults()
      searchScopeNotice = String(localized: "この接続ではタグ検索を利用できません")
      return
    }
    if searchScope == .currentFolder {
      if parsedQuery.hasContentTerms {
        searchScopeNotice = String(localized: "この検索範囲では内容を検索できません")
      } else if parsedQuery.hasTagTerms {
        searchScopeNotice = String(
          localized: "tag: はこのフォルダ直下のみを対象に絞り込みます")
      }
    }
    isSearching = true
    let generation = UUID()
    activeSearchGeneration = generation
    fullDiskAccessStatus = .unknown
    let task = Task { [weak self] in
      do {
        try await Task.sleep(for: self?.searchDebounceDuration ?? .milliseconds(300))
      } catch {
        return
      }
      guard !Task.isCancelled, let self, self.activeSearchGeneration == generation else { return }
      self.searchDebounceTask = nil
      self.startSearch(
        text: normalizedText,
        parsedQuery: parsedQuery,
        generation: generation)
    }
    searchDebounceTask = task
  }

  private func startSearch(
    text: String,
    parsedQuery: ParsedSearchQuery,
    generation: UUID
  ) {
    if searchScope == .thisMac {
      fullDiskAccessStatus = fullDiskAccessChecker.status
    } else {
      fullDiskAccessStatus = .unknown
    }
    let filtersCurrentFolderItems =
      searchScope == .currentFolder
      && (parsedQuery.hasTagTerms || parsedQuery.hasContentTerms)
    let query = SearchQuery(
      text: text,
      root: currentLocation,
      scope: searchScope,
      nameMatchMode: searchUsesRegex ? .regex : .literal,
      generation: generation)
    let projection = SearchResultProjection(
      sortOrder: searchSortOrder,
      ascending: searchSortAscending,
      includesHiddenItems: showsHiddenFiles)
    searchProjection = projection
    publishedSearchProjectionRevision = nil
    if filtersCurrentFolderItems {
      if parsedQuery.hasTagTerms {
        enrichAllFinderTagsForSearch()
      }
      let localFilterText = parsedQuery.textExcludingContentTerms
      currentFolderTagFilterText = localFilterText
      currentFolderTagFilterMatchMode = searchUsesRegex ? .regex : .literal
      publishCurrentFolderTagFilter(
        text: localFilterText,
        matchMode: currentFolderTagFilterMatchMode,
        generation: generation,
        projection: projection)
      return
    }
    let service: any SearchService =
      searchScope == .thisMac
      ? spotlightSearchService
      : providerSearchServiceFactory(showsHiddenFiles)
    searchTask = Task { [weak self] in
      guard let self else { return }
      await self.consumeSearchUpdates(
        service.search(query), generation: generation, projection: projection)
    }
  }

  private func consumeSearchUpdates(
    _ updates: AsyncStream<SearchUpdate>,
    generation: UUID,
    projection: SearchResultProjection
  ) async {
    for await update in updates {
      guard !Task.isCancelled,
        activeSearchGeneration == generation,
        update.generation == generation
      else { return }
      switch update {
      case .results(let results, _):
        await projection.append(results)
        // append(アクターホップ)の中断中に新しい検索が始まっていたら、旧タスクが
        // 新検索側のsearchSnapshotPublishTaskへ自分のpublishタスクを差し込んでは
        // ならない(ハンドルが埋まり、新検索の増分publishが完了まで抑止される)。
        guard !Task.isCancelled, activeSearchGeneration == generation else { return }
        scheduleSearchSnapshotPublication(
          from: projection, generation: generation)
      case .partialError(let error):
        searchPartialErrorCount += error.count
      case .limitReached(let limit, _):
        searchLimitReached = limit
      case .finished:
        // 両検索エンジンとも.finishedが終端(直後にストリームが閉じる)ため、ここで
        // 後始末してreturnし、末尾の後始末(異常終端用)と二重実行しない。
        searchSnapshotPublishTask?.cancel()
        searchSnapshotPublishTask = nil
        await publishSearchSnapshot(from: projection, generation: generation)
        // publishの中断中に新しい検索が始まっていたら、この旧タスクが新検索の
        // isSearchingを倒してはならない(判定前の状態が外から完了扱いに見える)。
        // guardでreturnしても取り残しは出ない: activeSearchGenerationを書くのは
        // scheduleSearch/cancelSearchだけで、どちらも同じ同期区間でisSearchingも
        // 併せて設定する(この不変条件を崩す変更は禁止)。
        guard activeSearchGeneration == generation else { return }
        isSearching = false
        searchTask = nil
        return
      }
    }
    // .finishedなしでストリームが閉じた異常終端の後始末。guardの理由は上と同じ。
    guard !Task.isCancelled, activeSearchGeneration == generation else { return }
    searchSnapshotPublishTask?.cancel()
    searchSnapshotPublishTask = nil
    await publishSearchSnapshot(from: projection, generation: generation)
    guard activeSearchGeneration == generation else { return }
    isSearching = false
    searchTask = nil
  }

  private func refreshCurrentFolderTagFilterIfNeeded() {
    guard let text = currentFolderTagFilterText,
      let generation = activeSearchGeneration,
      let projection = searchProjection
    else { return }
    publishCurrentFolderTagFilter(
      text: text,
      matchMode: currentFolderTagFilterMatchMode,
      generation: generation,
      projection: projection)
  }

  private func publishCurrentFolderTagFilter(
    text: String,
    matchMode: NameMatchMode,
    generation: UUID,
    projection: SearchResultProjection
  ) {
    currentFolderTagFilterTask?.cancel()
    let token = UUID()
    currentFolderTagFilterToken = token
    let sourceRevision = itemsGeneration
    let parent = currentLocation
    let sourceItems = items
    currentFolderTagFilterTask = Task { [weak self] in
      let results = await Self.makeCurrentFolderSearchResults(
        from: sourceItems,
        text: text,
        matchMode: matchMode,
        parent: parent,
        generation: generation)
      guard !Task.isCancelled else { return }
      guard let self,
        self.activeSearchGeneration == generation,
        self.currentFolderTagFilterToken == token
      else { return }
      let didReplace = await projection.replace(
        results,
        sourceRevision: sourceRevision)
      guard !Task.isCancelled, didReplace,
        self.activeSearchGeneration == generation,
        self.currentFolderTagFilterToken == token
      else { return }
      await self.publishSearchSnapshot(from: projection, generation: generation)
      guard self.activeSearchGeneration == generation,
        self.currentFolderTagFilterToken == token
      else { return }
      self.isSearching = false
      self.currentFolderTagFilterTask = nil
    }
  }

  private nonisolated static func makeCurrentFolderSearchResults(
    from items: [FileItem],
    text: String,
    matchMode: NameMatchMode,
    parent: FileLocation,
    generation: UUID
  ) async -> [SearchResult] {
    FileItemFilter.filteredAndSorted(
      items,
      matching: text,
      matchMode: matchMode,
      sortOrder: .name,
      ascending: true
    ).map { item in
      SearchResult(
        item: item,
        parent: parent,
        providerID: item.location.providerID,
        generation: generation)
    }
  }

  private func scheduleSearchSnapshotPublication(
    from projection: SearchResultProjection,
    generation: UUID
  ) {
    guard searchSnapshotPublishTask == nil else { return }
    // ハンドルのnil化は「自分がまだ現行のpublishタスクであること」をトークンで確認して
    // 行う。generationのみを代理にすると、同一generation内でpublishタスクが世代交代
    // した場合に旧タスクが新タスクのハンドルをnil化し、キャンセル不能な迷子タスクを
    // 残しうる(現状.finishedが終端のため成立しないが、構造として塞ぐ)。
    let token = UUID()
    searchSnapshotPublishToken = token
    searchSnapshotPublishTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(50))
      } catch {
        return
      }
      guard !Task.isCancelled, let self, self.activeSearchGeneration == generation else { return }
      await self.publishSearchSnapshot(from: projection, generation: generation)
      guard self.searchSnapshotPublishToken == token else { return }
      self.searchSnapshotPublishTask = nil
    }
  }

  private func publishSearchSnapshot(
    from projection: SearchResultProjection,
    generation: UUID
  ) async {
    let snapshot = await projection.snapshot(after: publishedSearchProjectionRevision)
    guard activeSearchGeneration == generation, let snapshot else { return }
    publishedSearchProjectionRevision = snapshot.revision
    searchResults = snapshot.results
    searchDisplayItems = snapshot.items
    searchResultLocations = snapshot.locations
    searchResultsGeneration &+= 1
  }

  private func removeSearchResults(at locations: Set<FileLocation>) {
    guard isSearchActive, !locations.isEmpty, let projection = searchProjection,
      let generation = activeSearchGeneration
    else { return }
    Task { [weak self] in
      await projection.remove(locations: locations)
      guard let self, self.activeSearchGeneration == generation else { return }
      await self.publishSearchSnapshot(from: projection, generation: generation)
    }
  }

  private func resetSearchResults() {
    if !searchResults.isEmpty {
      searchResults.removeAll(keepingCapacity: true)
    }
    searchDisplayItems.removeAll(keepingCapacity: true)
    searchResultLocations.removeAll(keepingCapacity: true)
    searchResultsGeneration &+= 1
    searchPartialErrorCount = 0
    searchLimitReached = nil
  }

  private func cancelSearch(clearText: Bool, clearRevealRequest: Bool) {
    searchDebounceTask?.cancel()
    searchTask?.cancel()
    currentFolderTagFilterTask?.cancel()
    searchSnapshotPublishTask?.cancel()
    searchDebounceTask = nil
    searchTask = nil
    currentFolderTagFilterTask = nil
    currentFolderTagFilterToken = nil
    currentFolderTagFilterText = nil
    currentFolderTagFilterMatchMode = .literal
    searchSnapshotPublishTask = nil
    searchProjection = nil
    publishedSearchProjectionRevision = nil
    activeSearchGeneration = nil
    isSearching = false
    isRecentFilesActive = false
    recentFilesPresentation = nil
    if clearText { searchText = "" }
    searchScopeNotice = nil
    resetSearchResults()
    if clearRevealRequest {
      pendingRevealRequest = nil
      revealRequest = nil
    }
  }

  private func publishPendingSearchRevealIfNeeded(
    at directory: FileLocation,
    items: [FileItem]
  ) {
    guard let request = pendingRevealRequest,
      request.directoryLocation == directory,
      items.contains(where: { $0.url == request.itemURL })
    else { return }
    pendingRevealRequest = nil
    revealRequest = request
  }

  func load(location: FileLocation? = nil) {
    load(
      location: location,
      preservingColumnState: false,
      preloadedItems: nil,
      includesHiddenItems: nil,
      invalidatesGitStatusCache: false)
  }

  private func load(
    location: FileLocation?,
    preservingColumnState: Bool,
    preloadedItems: [FileItem]?,
    includesHiddenItems: Bool?,
    invalidatesGitStatusCache: Bool
  ) {
    guard !isRetiredFromBrowsing else { return }
    pendingArmCompletionCheckLocation = nil
    if isSearchActive || isSearching {
      cancelSearch(clearText: true, clearRevealRequest: true)
    }
    needsHiddenFilesReload = false
    hasStartedInitialLoad = true
    let destination = location ?? currentLocation
    let providerKind = InteractionPerformanceProviderKind.classify(provider)
    let signpostID = OSSignpostID(log: BrowsePerformanceSignpost.log)
    browseSignpostID = signpostID
    os_signpost(
      .begin, log: BrowsePerformanceSignpost.log, name: BrowsePerformanceSignpost.name,
      signpostID: signpostID)
    BrowsePerformanceSignpost.event(
      .requestAccepted,
      signpostID: signpostID,
      providerKind: providerKind)
    // 中断(loadTask.cancel())によりこのTaskが早期returnする場合、.endを発行せず抜けると
    // Instruments上でこの区間が閉じない孤児区間として残り続ける。中断時も必ず閉じる。
    func endBrowseSignpostAsCancelled() {
      os_signpost(
        .end, log: BrowsePerformanceSignpost.log, name: BrowsePerformanceSignpost.name,
        signpostID: signpostID, "中断")
    }
    if destination != columnLocationBeforeSearch {
      columnStateBeforeSearch = nil
      columnLocationBeforeSearch = nil
    }
    // フォルダ移動(ナビゲート)を伴う場合だけ展開状態をリセットする(計画どおり展開は
    // セッション内のみ・currentLocation単位で意味を持つ)。同一フォルダの再読み込み
    // (refresh()・隠しファイル表示切替後のload())は展開状態を保持する。
    if destination != currentLocation {
      cancelAllGitStatusLoadsAndClearStatuses()
      resetTreeState()
      if columnState.isActive, !preservingColumnState {
        var state = columnState
        state.begin(at: destination, items: [])
        columnState = state
      }
    }
    loadTask?.cancel()
    cancelMetadataEnrichment()
    // revalidateSilentlyはloadTaskを触れなくなった(このタスク自身の識別はrevalidationTask
    // のみで行う)ため、ユーザー操作によるload()側からも進行中の無音再検証を明示的に
    // cancelする。cancelされたタスクのdeferはisRevalidatingInBackgroundを下ろさない設計
    // (先発が後発のフラグを壊さないため)なので、ここで直接下ろしておく。
    revalidationTask?.cancel()
    revalidationTask = nil
    isRevalidatingInBackground = false
    currentLocation = destination
    updateColumnWatchers()
    BrowsePerformanceSignpost.event(
      .locationCommitted,
      signpostID: signpostID,
      providerKind: providerKind)
    removeCloudStatusesOutsideDisplayedDirectories()
    startWatchingCurrentLocationIfNeeded()
    startGitStatusLoad(at: destination, invalidatingCache: invalidatesGitStatusCache)
    if let preloadedItems, let includesHiddenItems {
      cacheDirectorySnapshot(
        DirectorySnapshot(
          items: preloadedItems,
          includesHiddenItems: includesHiddenItems,
          directoryModifiedAt: Self.directoryModifiedAt(of: destination)), at: destination)
      if items != preloadedItems {
        items = preloadedItems
      } else {
        synchronizeColumnItems(preloadedItems, at: destination)
      }
      isLoading = false
      isRefreshing = false
      errorMessage = nil
      hasPendingWatcherEvent = false
      finishColumnLoading(at: destination)
      BrowsePerformanceSignpost.event(
        .firstBatchReceived,
        signpostID: signpostID,
        providerKind: providerKind,
        itemCount: preloadedItems.count,
        cacheHit: true)
      BrowsePerformanceSignpost.event(
        .listingModelCompleted,
        signpostID: signpostID,
        providerKind: providerKind,
        itemCount: preloadedItems.count,
        cacheHit: true)
      os_signpost(
        .end, log: BrowsePerformanceSignpost.log, name: BrowsePerformanceSignpost.name,
        signpostID: signpostID)
      enrichMissingMetadataIfNeeded(at: destination, browseSignpostID: signpostID)
      startCloudStatusLoad(at: destination)
      return
    }
    let snapshot = directoryCache[destination]
    if let snapshot {
      if items != snapshot.items {
        items = snapshot.items
      } else {
        synchronizeColumnItems(snapshot.items, at: destination)
      }
      BrowsePerformanceSignpost.event(
        .firstBatchReceived,
        signpostID: signpostID,
        providerKind: providerKind,
        itemCount: snapshot.items.count,
        cacheHit: true)
      // ディレクトリのmtimeは直下の追加・削除・リネームでのみ変わる。子ファイルの内容
      // (サイズ・更新日時)だけが変わっている可能性は消せないため、mtime一致時もキャッシュを
      // 即表示しつつ無音でバックグラウンド再検証し、差分だけを反映する(内容が完全一致なら
      // itemsは再代入されず再描画も起きない)。
      if snapshot.includesHiddenItems == showsHiddenFiles,
        let cachedModifiedAt = snapshot.directoryModifiedAt,
        let currentModifiedAt = Self.directoryModifiedAt(of: destination),
        cachedModifiedAt == currentModifiedAt
      {
        isLoading = false
        isRefreshing = false
        errorMessage = nil
        hasPendingWatcherEvent = false
        finishColumnLoading(at: destination)
        publishPendingSearchRevealIfNeeded(at: destination, items: snapshot.items)
        BrowsePerformanceSignpost.event(
          .listingModelCompleted,
          signpostID: signpostID,
          providerKind: providerKind,
          itemCount: snapshot.items.count,
          cacheHit: true)
        BrowsePerformanceSignpost.event(
          .criticalEnrichmentCompleted,
          signpostID: signpostID,
          providerKind: providerKind,
          cacheHit: true)
        os_signpost(
          .end, log: BrowsePerformanceSignpost.log, name: BrowsePerformanceSignpost.name,
          signpostID: signpostID)
        startCloudStatusLoad(at: destination)
        revalidateSilently(destination, includingHidden: showsHiddenFiles)
        return
      }
      isRefreshing = true
    } else {
      items = []
      isLoading = true
    }
    let includingHidden = showsHiddenFiles
    let task = Task { [weak self] in
      guard let self else { return }
      var didLoadItems = false
      do {
        let directoryModifiedAt = Self.directoryModifiedAt(of: destination)
        let loadedItems = try await self.loadItems(
          at: destination,
          includingHidden: includingHidden,
          publishesPartialResults: snapshot == nil,
          browseSignpostID: snapshot == nil ? signpostID : nil,
          providerKind: providerKind)
        try Task.checkCancellation()
        self.cacheDirectorySnapshot(
          DirectorySnapshot(
            items: loadedItems,
            includesHiddenItems: includingHidden,
            directoryModifiedAt: directoryModifiedAt), at: destination)
        // loadItems(publishesPartialResults:)やrefreshContents()の「内容が等しくても
        // 必ず代入する」規則(下記2箇所の同コメント参照)の例外。load()は冒頭(:179)で
        // revalidationTaskを明示cancelするため、この代入と競合しうる無音再検証は
        // 存在せず、epochが進まなくても後発タスクが誤って生き残ることはない。また
        // publishesPartialResultsがtrueの経路ではloadItems内の各バッチ代入で既にepochが
        // 進んでいるため、ここでの重複代入自体が不要。よってここだけは内容が等しければ
        // 代入を省略してよい(無駄な再描画とdisplayItemsCache破棄を避ける)。
        if self.items != loadedItems {
          self.items = loadedItems
        } else {
          self.synchronizeColumnItems(loadedItems, at: destination)
        }
        self.errorMessage = nil
        self.publishPendingSearchRevealIfNeeded(at: destination, items: loadedItems)
        didLoadItems = true
      } catch {
        guard !Task.isCancelled else {
          endBrowseSignpostAsCancelled()
          return
        }
        self.presentError(error)
      }
      guard !Task.isCancelled else {
        endBrowseSignpostAsCancelled()
        return
      }
      BrowsePerformanceSignpost.event(
        .listingModelCompleted,
        signpostID: signpostID,
        providerKind: providerKind,
        itemCount: self.items.count,
        cacheHit: snapshot != nil)
      self.isLoading = false
      self.isRefreshing = false
      self.finishColumnLoading(at: destination)
      if didLoadItems {
        self.enrichMissingMetadataIfNeeded(at: destination, browseSignpostID: signpostID)
        self.startCloudStatusLoad(at: destination)
      }
      // load中に監視イベントを見送っていたら、完了した今ここで1回だけ拾い直す
      // (見送っている間に落ちた最後の外部変更の取りこぼし防止)。
      if self.hasPendingWatcherEvent {
        self.hasPendingWatcherEvent = false
        self.handleWatcherEvent(for: destination)
      }
      os_signpost(
        .end, log: BrowsePerformanceSignpost.log, name: BrowsePerformanceSignpost.name,
        signpostID: signpostID)
    }
    loadTask = task
  }

  /// キャッシュのディレクトリmtimeが一致した場合、または監視イベント由来の無音再検証。
  /// isLoading/isRefreshingは更新中インジケータを表示させないため意図的に立てない。
  /// 取得結果が現在のitemsと等しければ再代入しない(FileItemのEquatableにより
  /// 再描画も発生しない)。失敗しても表示中のキャッシュ内容を維持するだけでerrorMessageは
  /// 出さない。
  ///
  /// 監視イベントは短時間に連続しうるため、直前の再検証タスクをcancelしてから新しい
  /// タスクを起動する(同一ディレクトリの多重列挙を防ぐ)。また、この再検証が進行中に
  /// 転送完了・ZIP展開・別のload()などitemsへの権威的な書き込みが割り込んだ場合は、
  /// 開始時に捕捉したitemsAuthorityEpochとの比較で自分の結果を古いものとして破棄する。
  ///
  /// loadTaskへは代入しない(revalidationTaskだけで自身を識別する)。ここでloadTaskを
  /// 差し替えると、進行中のユーザー操作load(load()が生成したTask)への参照が失われ、
  /// load()側のloadTask?.cancel()でそのTaskを中断できなくなってしまう
  /// (中断できないloadTaskが生き残り、後から古いフォルダのitems/directoryCache/
  /// isLoadingを書き戻す不整合につながる)。
  private func revalidateSilently(
    _ destination: FileLocation, includingHidden: Bool, preservesExistingMetadata: Bool = false
  ) {
    revalidationTask?.cancel()
    cancelMetadataEnrichment()
    isRevalidatingInBackground = true
    let epoch = itemsAuthorityEpoch
    let task = Task { [weak self] in
      guard let self, !Task.isCancelled else { return }
      defer {
        // 自分が後発の再検証タスクにcancelされて中断された場合、後発タスクが
        // まだ完了していないのにこのdeferが先に走って"再検証中"フラグを誤って
        // 下ろしてしまうことがある。cancelされていない(=自分が最後発のまま
        // 完了した)ときだけフラグを下ろす。
        if !Task.isCancelled {
          self.isRevalidatingInBackground = false
        }
      }
      do {
        let directoryURL = destination.localURL
        let directoryModifiedAt: Date? =
          if let directoryURL {
            await ColumnDirectoryDateReader.shared.read(directoryURL, requiresAPFS: false)
          } else {
            nil
          }
        try Task.checkCancellation()
        let listedItems = try await self.loadItems(
          at: destination,
          includingHidden: includingHidden,
          publishesPartialResults: false)
        try Task.checkCancellation()
        guard self.currentLocation == destination else { return }
        guard self.itemsAuthorityEpoch == epoch else {
          // 編集済みの項目を古い結果で上書きせず、同じ場所の最新の一覧を取り直す。
          self.revalidateSilently(
            destination, includingHidden: self.showsHiddenFiles,
            preservesExistingMetadata: preservesExistingMetadata)
          return
        }
        let loadedItems =
          preservesExistingMetadata
          ? listedItems.fillingMissingMetadata(from: self.items) : listedItems
        self.cacheDirectorySnapshot(
          DirectorySnapshot(
            items: loadedItems,
            includesHiddenItems: includingHidden,
            directoryModifiedAt: directoryModifiedAt), at: destination)
        if self.items != loadedItems {
          self.items = loadedItems
        }
        self.enrichMissingMetadataIfNeeded(at: destination)
        if self.pendingArmCompletionCheckLocation == destination {
          self.pendingArmCompletionCheckLocation = nil
          // 監視が捉える直下の追加・削除・リネームはディレクトリmtimeにも反映される。
          // 子ファイル内容だけの変更は監視でも捉えられないため、同じ精度で武装中の
          // 変更を判定し、必要な場合だけもう一度列挙する。
          let modifiedAtAfterRevalidation: Date? =
            if let directoryURL, directoryModifiedAt != nil {
              await ColumnDirectoryDateReader.shared.read(directoryURL, requiresAPFS: false)
            } else {
              nil
            }
          try Task.checkCancellation()
          if self.currentLocation == destination,
            directoryModifiedAt == nil || modifiedAtAfterRevalidation != directoryModifiedAt
          {
            self.revalidateSilently(
              destination, includingHidden: includingHidden,
              preservesExistingMetadata: preservesExistingMetadata)
          }
        }
      } catch {
        // 無音の再検証のため、失敗してもキャッシュ表示を維持し利用者へは通知しない。
      }
    }
    revalidationTask = task
  }

  /// 監視イベントの取りこぼしに備え、前景に戻ったときに表示中のローカル一覧を再取得する。
  func revalidateDisplayedLocations(includesExpandedChildren: Bool = true) {
    guard hasStartedInitialLoad, !isRetiredFromBrowsing else { return }
    if currentLocation.localURL != nil, !isLoading, !isRefreshing,
      columnLoadTasks[currentLocation] == nil
    {
      revalidateSilently(
        currentLocation, includingHidden: showsHiddenFiles, preservesExistingMetadata: true)
    }
    for column in columnState.columns where column.location != currentLocation {
      revalidateAncestorColumn(at: column.location, preservesExistingMetadata: true)
    }
    if includesExpandedChildren, !columnState.isActive {
      for location in treeState.expandedLocations where isDisplayedExpandedLocation(location) {
        refreshExpandedChildren(at: location, preservesExistingMetadata: true)
      }
    }
  }

  private func isDisplayedExpandedLocation(_ location: FileLocation) -> Bool {
    guard location.localURL != nil else { return false }
    var descendant = location
    // 折りたたんだフォルダの配下には、復元用の展開状態が残っている。
    while let parent = descendant.deletingLastPathComponent(), parent != descendant {
      if parent == currentLocation { return true }
      guard treeState.isExpanded(parent) else { return false }
      descendant = parent
    }
    return false
  }

  private static let metadataEnrichmentMaximumConcurrency = 6

  private struct FinderTagEnrichmentBatch: Sendable {
    let items: [FileItem]
    let locations: Set<FileLocation>
  }

  private enum MetadataEnrichmentWork: Sendable {
    case prepared(fullDetailItems: [FileItem], tagOnlyItems: [FileItem])
    case allFinderTags(sourceItems: [FileItem])
  }

  private func cancelMetadataEnrichment() {
    metadataEnrichmentTask?.cancel()
    metadataEnrichmentTask = nil
    pendingVisibleFinderTagItems.removeAll()
    finderTagEnrichmentLocationsInFlight.removeAll()
    requiresAllFinderTagsForSearch = false
    isMetadataEnrichmentActive = false
    metadataEnrichmentGeneration &+= 1
  }

  /// 初期列挙で省いた一覧用のサイズ・更新日時・Finderタグを後追いで補完する。初期表示を遅らせず、
  /// Finderタグは初回64件と実際に可視化された項目だけを小バッチで取得する。サイズ・更新日時が
  /// 揃っていてタグだけが欠ける項目は、所有者・アクセス権まで読む詳細取得を避ける。
  private func enrichMissingMetadataIfNeeded(
    at destination: FileLocation,
    browseSignpostID: OSSignpostID? = nil,
    includesInitialFinderTagBatch: Bool = true
  ) {
    guard currentLocation == destination, metadataEnrichmentTask == nil else { return }
    let preparationStartedAt = ContinuousClock.now
    let providerKind = InteractionPerformanceProviderKind.classify(provider)
    let detailProvider = provider as? any FileBrowserItemDetailProvider
    let tagMetadataProvider = provider as? any FileBrowserFinderTagMetadataProvider
    let loadsFinderTags = capabilities.contains(.finderTags) && tagMetadataProvider != nil
    if loadsFinderTags, requiresAllFinderTagsForSearch {
      // tag:検索では1万件規模の未補完項目抽出と場所集合生成をMainActorで行わない。
      // itemsは値型配列のスナップショットとして渡し、結果適用前に世代を再確認する。
      requiresAllFinderTagsForSearch = false
      startMetadataEnrichment(
        .allFinderTags(sourceItems: items),
        at: destination,
        browseSignpostID: browseSignpostID,
        providerKind: providerKind,
        detailProvider: detailProvider,
        tagMetadataProvider: tagMetadataProvider)
      lastMetadataEnrichmentPreparationDuration = ContinuousClock.now - preparationStartedAt
      return
    }
    let fullDetailItems =
      detailProvider.map { _ in
        items.filter(Self.needsFullMetadataEnrichment)
      } ?? []
    let fullDetailLocations = Set(fullDetailItems.map(\.location))
    let tagOnlyItems: [FileItem]
    if !loadsFinderTags {
      tagOnlyItems = []
    } else {
      var selectedLocations = Set<FileLocation>()
      var selectedItems = [FileItem]()
      if includesInitialFinderTagBatch {
        for item in items
        where item.tags == nil
          && !fullDetailLocations.contains(item.location)
          && !finderTagEnrichmentLocationsInFlight.contains(item.location)
        {
          selectedLocations.insert(item.location)
          selectedItems.append(item)
          if selectedItems.count == Self.initialFinderTagEnrichmentLimit { break }
        }
      }
      if selectedItems.count < Self.initialFinderTagEnrichmentLimit {
        // 可視通知時に保持した項目を直接使い、追加20件のために1万件の
        // selectableItems辞書をMainActor上で作り直さない。
        for item in pendingVisibleFinderTagItems.values
        where item.tags == nil
          && !fullDetailLocations.contains(item.location)
          && !finderTagEnrichmentLocationsInFlight.contains(item.location)
          && !selectedLocations.contains(item.location)
        {
          selectedLocations.insert(item.location)
          selectedItems.append(item)
          if selectedItems.count == Self.initialFinderTagEnrichmentLimit { break }
        }
      }
      for location in selectedLocations {
        pendingVisibleFinderTagItems[location] = nil
      }
      tagOnlyItems = selectedItems
    }
    guard !fullDetailItems.isEmpty || !tagOnlyItems.isEmpty else {
      lastMetadataEnrichmentPreparationDuration = ContinuousClock.now - preparationStartedAt
      if let browseSignpostID {
        BrowsePerformanceSignpost.event(
          .criticalEnrichmentCompleted,
          signpostID: browseSignpostID,
          providerKind: providerKind)
      }
      return
    }
    startMetadataEnrichment(
      .prepared(fullDetailItems: fullDetailItems, tagOnlyItems: tagOnlyItems),
      at: destination,
      browseSignpostID: browseSignpostID,
      providerKind: providerKind,
      detailProvider: detailProvider,
      tagMetadataProvider: tagMetadataProvider)
    lastMetadataEnrichmentPreparationDuration = ContinuousClock.now - preparationStartedAt
  }

  private func startMetadataEnrichment(
    _ work: MetadataEnrichmentWork,
    at destination: FileLocation,
    browseSignpostID: OSSignpostID?,
    providerKind: InteractionPerformanceProviderKind,
    detailProvider: (any FileBrowserItemDetailProvider)?,
    tagMetadataProvider: (any FileBrowserFinderTagMetadataProvider)?
  ) {
    let generation = metadataEnrichmentGeneration
    let authorityEpoch = itemsAuthorityEpoch
    metadataEnrichmentRunCount += 1
    isMetadataEnrichmentActive = true
    let task = Task { [weak self] in
      let fullDetailItems: [FileItem]
      let tagBatch: FinderTagEnrichmentBatch
      let tracksTagLocationsInFlight: Bool
      let allFinderTagSourceItems: [FileItem]?
      switch work {
      case .prepared(let preparedFullDetailItems, let preparedTagOnlyItems):
        fullDetailItems = preparedFullDetailItems
        tracksTagLocationsInFlight = true
        allFinderTagSourceItems = nil
        tagBatch = FinderTagEnrichmentBatch(
          items: preparedTagOnlyItems,
          locations: Set(preparedTagOnlyItems.map(\.location)))
      case .allFinderTags(let sourceItems):
        fullDetailItems = []
        // ルート側はmetadataEnrichmentTask自体が多重起動を防ぐ。1万件の場所を
        // MainActor上の進行中集合へ出し入れする必要はない。
        tracksTagLocationsInFlight = false
        allFinderTagSourceItems = sourceItems
        tagBatch = await Self.prepareAllFinderTagEnrichment(from: sourceItems)
      }
      guard !Task.isCancelled,
        let self,
        self.metadataEnrichmentGeneration == generation,
        self.itemsAuthorityEpoch == authorityEpoch,
        self.currentLocation == destination
      else { return }
      let tagOnlyItems = tagBatch.items
      let tagOnlyLocations = tagBatch.locations
      if tracksTagLocationsInFlight {
        self.finderTagEnrichmentLocationsInFlight.formUnion(tagOnlyLocations)
      }
      if let browseSignpostID {
        BrowsePerformanceSignpost.beginMetadataEnrichment(
          signpostID: browseSignpostID,
          providerKind: providerKind,
          fullDetailCount: fullDetailItems.count,
          finderTagCount: tagOnlyItems.count)
      }
      var successfulDetailCount = 0
      var successfulTagCount = 0
      var appliedItemCount = 0
      defer {
        let measurement = MetadataEnrichmentMeasurement(
          fullDetailRequestCount: fullDetailItems.count,
          finderTagRequestCount: tagOnlyItems.count,
          successfulDetailCount: successfulDetailCount,
          successfulTagCount: successfulTagCount,
          appliedItemCount: appliedItemCount,
          wasCancelled: Task.isCancelled)
        if let browseSignpostID {
          BrowsePerformanceSignpost.endMetadataEnrichment(
            signpostID: browseSignpostID,
            measurement: measurement)
          BrowsePerformanceSignpost.event(
            .criticalEnrichmentCompleted,
            signpostID: browseSignpostID,
            providerKind: providerKind,
            itemCount: appliedItemCount)
        }
        if self.metadataEnrichmentGeneration == generation {
          // セル構成通知がこのバッチ開始後に同じURLを再登録していても、完了直後に
          // 同じ属性を再取得しない。失敗項目は次にセルが再構成されたとき再要求できる。
          if tracksTagLocationsInFlight {
            self.finderTagEnrichmentLocationsInFlight.subtract(tagOnlyLocations)
          }
          // 全件検索バッチではtagOnlyLocationsが1万件規模になるため、候補側ではなく
          // 通常64件以下の保留側だけを走査して完了項目を取り除く。
          self.pendingVisibleFinderTagItems = self.pendingVisibleFinderTagItems.filter {
            !tagOnlyLocations.contains($0.key)
          }
          self.lastMetadataEnrichmentMeasurement = measurement
          self.isMetadataEnrichmentActive = false
          self.metadataEnrichmentTask = nil
          if self.requiresAllFinderTagsForSearch || !self.pendingVisibleFinderTagItems.isEmpty {
            self.enrichMissingMetadataIfNeeded(
              at: destination,
              includesInitialFinderTagBatch: false)
          }
        }
      }
      let detailedItems: [FileLocation: FileItem]
      if let detailProvider {
        detailedItems = await Self.loadDetailedItems(
          for: fullDetailItems,
          from: detailProvider,
          maximumConcurrency: Self.metadataEnrichmentMaximumConcurrency)
      } else {
        detailedItems = [:]
      }
      successfulDetailCount = detailedItems.count
      let tagNamesByLocation: [FileLocation: [String]]
      if let tagMetadataProvider {
        tagNamesByLocation = await Self.loadFinderTagNames(
          for: tagOnlyItems,
          from: tagMetadataProvider,
          maximumConcurrency: Self.metadataEnrichmentMaximumConcurrency)
      } else {
        tagNamesByLocation = [:]
      }
      successfulTagCount = tagNamesByLocation.count
      guard !Task.isCancelled,
        self.metadataEnrichmentGeneration == generation,
        self.itemsAuthorityEpoch == authorityEpoch,
        self.currentLocation == destination,
        !detailedItems.isEmpty || !tagNamesByLocation.isEmpty
      else { return }
      let enrichedItems: [FileItem]
      if let allFinderTagSourceItems {
        enrichedItems = await Self.replacingFinderTags(
          in: allFinderTagSourceItems,
          tagNamesByLocation: tagNamesByLocation)
      } else {
        enrichedItems = await Self.mergeMetadataEnrichmentResults(
          detailedItems: detailedItems,
          tagOnlyItems: tagOnlyItems,
          tagNamesByLocation: tagNamesByLocation)
      }
      guard !Task.isCancelled,
        self.metadataEnrichmentGeneration == generation,
        self.itemsAuthorityEpoch == authorityEpoch,
        self.currentLocation == destination,
        !enrichedItems.isEmpty
      else { return }
      // 列挙スナップショットは未補完値のまま保ち、再表示時に可視範囲を再補完する。
      // 1万件キャッシュ全体の比較・再保存を初期64件の完了条件へ持ち込まない。
      let applicationStartedAt = ContinuousClock.now
      if allFinderTagSourceItems != nil {
        // 完成したルート配列はMainActor外で構築済み。ここで再び辞書化・全件走査せず、
        // itemsのdidSetに現在カラムと検索投影の更新だけを委ねる。
        self.items = enrichedItems
      } else {
        self.replaceCachedItems(
          enrichedItems,
          updatesDirectoryCache: false)
      }
      self.lastMetadataEnrichmentApplicationDuration =
        ContinuousClock.now - applicationStartedAt
      appliedItemCount =
        allFinderTagSourceItems == nil
        ? enrichedItems.count : tagNamesByLocation.count
    }
    metadataEnrichmentTask = task
  }

  private nonisolated static func prepareAllFinderTagEnrichment(
    from sourceItems: [FileItem]
  ) async -> FinderTagEnrichmentBatch {
    let items = sourceItems.filter { $0.tags == nil }
    return FinderTagEnrichmentBatch(
      items: items,
      locations: Set(items.map(\.location)))
  }

  private nonisolated static func mergeMetadataEnrichmentResults(
    detailedItems: [FileLocation: FileItem],
    tagOnlyItems: [FileItem],
    tagNamesByLocation: [FileLocation: [String]]
  ) async -> [FileItem] {
    var enrichedItemsByLocation = detailedItems
    for item in tagOnlyItems {
      guard let tagNames = tagNamesByLocation[item.location] else { continue }
      enrichedItemsByLocation[item.location] = item.replacingTags(tagNames)
    }
    return Array(enrichedItemsByLocation.values)
  }

  private nonisolated static func replacingFinderTags(
    in sourceItems: [FileItem],
    tagNamesByLocation: [FileLocation: [String]]
  ) async -> [FileItem] {
    sourceItems.map { item in
      guard let tagNames = tagNamesByLocation[item.location] else { return item }
      return item.replacingTags(tagNames)
    }
  }

  /// AppKit/SwiftUIが実際に構成したセルだけをFinderタグ補完の優先対象へ加える。
  /// 同じ項目の複数列や再描画は場所IDで統合し、1バッチ64件を超えてI/Oを開始しない。
  func enrichFinderTags(forVisibleItems visibleItems: [FileItem]) {
    guard capabilities.contains(.finderTags),
      provider is any FileBrowserFinderTagMetadataProvider
    else { return }
    for item in visibleItems where item.tags == nil {
      pendingVisibleFinderTagItems[item.location] = item
    }
    guard !pendingVisibleFinderTagItems.isEmpty else { return }
    enrichMissingMetadataIfNeeded(
      at: currentLocation,
      includesInitialFinderTagBatch: false)
  }

  private func enrichAllFinderTagsForSearch() {
    guard capabilities.contains(.finderTags),
      provider is any FileBrowserFinderTagMetadataProvider,
      items.contains(where: { $0.tags == nil })
    else { return }
    requiresAllFinderTagsForSearch = true
    enrichMissingMetadataIfNeeded(
      at: currentLocation,
      includesInitialFinderTagBatch: false)
  }

  private nonisolated static func needsFullMetadataEnrichment(_ item: FileItem) -> Bool {
    (!item.isDirectory && item.size == nil) || item.modifiedAt == nil
  }

  private nonisolated static func loadDetailedItems(
    for items: [FileItem],
    from detailProvider: any FileBrowserItemDetailProvider,
    maximumConcurrency: Int
  ) async -> [FileLocation: FileItem] {
    await withTaskGroup(of: FileItem?.self, returning: [FileLocation: FileItem].self) { group in
      var details: [FileLocation: FileItem] = [:]
      var nextIndex = 0
      let initialCount = min(maximumConcurrency, items.count)
      for _ in 0..<initialCount {
        let item = items[nextIndex]
        nextIndex += 1
        group.addTask {
          guard !Task.isCancelled else { return nil }
          return try? await detailProvider.detailedItem(at: item.location)
        }
      }
      while let detailedItem = await group.next() {
        if let detailedItem {
          details[detailedItem.location] = detailedItem
        }
        guard !Task.isCancelled, nextIndex < items.count else { continue }
        let item = items[nextIndex]
        nextIndex += 1
        group.addTask {
          guard !Task.isCancelled else { return nil }
          return try? await detailProvider.detailedItem(at: item.location)
        }
      }
      return details
    }
  }

  private nonisolated static func loadFinderTagNames(
    for items: [FileItem],
    from tagMetadataProvider: any FileBrowserFinderTagMetadataProvider,
    maximumConcurrency: Int
  ) async -> [FileLocation: [String]] {
    await withTaskGroup(
      of: (FileLocation, [String])?.self,
      returning: [FileLocation: [String]].self
    ) { group in
      var tagNamesByLocation: [FileLocation: [String]] = [:]
      var nextIndex = 0
      let initialCount = min(maximumConcurrency, items.count)
      for _ in 0..<initialCount {
        let item = items[nextIndex]
        nextIndex += 1
        group.addTask {
          guard !Task.isCancelled,
            let tagNames = try? await tagMetadataProvider.finderTagNames(at: item.location)
          else { return nil }
          return (item.location, tagNames)
        }
      }
      while let result = await group.next() {
        if let (location, tagNames) = result {
          tagNamesByLocation[location] = tagNames
        }
        guard !Task.isCancelled, nextIndex < items.count else { continue }
        let item = items[nextIndex]
        nextIndex += 1
        group.addTask {
          guard !Task.isCancelled,
            let tagNames = try? await tagMetadataProvider.finderTagNames(at: item.location)
          else { return nil }
          return (item.location, tagNames)
        }
      }
      return tagNamesByLocation
    }
  }

  /// currentLocationがローカルディレクトリなら監視を開始する。同じパスを既に監視中なら
  /// 張り直さない。リモート(localURLなし)なら監視を解除するだけ。
  ///
  /// open(2)によるfd取得は停止中のSMB/NFSマウントなどでブロックしうるため、
  /// LocalDirectoryWatcher.opening(directoryURL:onChange:)はTask.detachedへ処理を
  /// 出す。ここではそれをTask内でawaitし、メインスレッド(呼び出し元のload())を
  /// 塞がないようにする。武装が完了するまでの間に別のフォルダへ移動していたら、
  /// 得られたwatcherは使わずに破棄する(deinitでfdがclose(2)される)。
  private func startWatchingCurrentLocationIfNeeded() {
    guard !isRetiredFromBrowsing else { return }
    guard let directoryURL = currentLocation.localURL else {
      watcherArmTask?.cancel()
      watcherArmTask = nil
      directoryWatcher = nil
      watchedDirectoryPath = nil
      return
    }
    guard watchedDirectoryPath != directoryURL.path else { return }
    // パスが変わった時点で前のフォルダの監視を即座に解く。武装が失敗した場合に
    // 前のフォルダのfdを掴み続けたままにしない。
    directoryWatcher = nil
    watchedDirectoryPath = nil
    watcherArmTask?.cancel()
    let location = currentLocation
    let armTask = Task { [weak self] in
      guard let self else { return }
      let watcher = await LocalDirectoryWatcher.opening(directoryURL: directoryURL) {
        [weak self] in
        self?.handleWatcherEvent(for: location)
      }
      // invalidate()や別フォルダへの移動でこの武装タスク自体がcancelされていたら
      // (currentLocationは変わっていなくても)監視を復活させない。
      guard !Task.isCancelled, self.currentLocation == location, let watcher else { return }
      self.directoryWatcher = watcher
      self.watchedDirectoryPath = directoryURL.path
      // 監視が生きた後のmtimeをメインスレッド外で読む。列挙前に保存したmtimeと
      // 一致すれば、武装までの間に直下の追加・削除・改名はなかった。
      let modifiedAtAfterArm = await ColumnDirectoryDateReader.shared.read(directoryURL)
      guard !Task.isCancelled, self.currentLocation == location else { return }
      // 武装完了までの間に落ちた外部変更を取りこぼさないよう、直後に1回だけチェックする。
      // ただしisLoading/isRefreshing中(=進行中のload()がまさに同じディレクトリを列挙中)
      // ならこのチェックは捨ててよい。その列挙が同じ窓をすでにカバーしているため。
      self.handleWatcherEvent(
        for: location,
        isArmCompletionCheck: true,
        armCompletionModifiedAt: modifiedAtAfterArm)
    }
    watcherArmTask = armTask
  }

  /// 監視イベント(または武装完了直後の取りこぼし防止チェック)を、進行中のload()と
  /// 衝突しないようゲートしてから無音再検証へつなぐ。isLoading/isRefreshing中に届いた
  /// 実際の監視イベント(isArmCompletionCheck: false)は再検証を見送ってhasPendingWatcherEvent
  /// を立て、そのload()自身の完了処理(load()のTask完了時など)が1回だけ拾い直す。
  ///
  /// 一方、武装完了直後の取りこぼし防止チェック(isArmCompletionCheck: true)は、ゲートが
  /// 閉じているならpendingを立てずにそのまま捨てる。進行中のload()の列挙が同じ窓を
  /// すでにカバーしているため保留する必要がなく、pendingを立ててしまうとload()完了後に
  /// もう一度同じディレクトリを列挙する二重列挙が起きる。
  private func handleWatcherEvent(
    for location: FileLocation,
    isArmCompletionCheck: Bool = false,
    armCompletionModifiedAt: Date? = nil
  ) {
    guard !isRetiredFromBrowsing else { return }
    guard currentLocation == location else { return }
    guard !isLoading, !isRefreshing else {
      if !isArmCompletionCheck {
        hasPendingWatcherEvent = true
      }
      return
    }
    if isArmCompletionCheck {
      if isRevalidatingInBackground {
        pendingArmCompletionCheckLocation = location
        return
      }
      if let cachedModifiedAt = directoryCache[location]?.directoryModifiedAt,
        let armCompletionModifiedAt,
        cachedModifiedAt == armCompletionModifiedAt
      {
        // 直下の変更がなければ列挙済み一覧を再利用する。mtime不明または変化時は
        // 従来どおり無音再検証し、武装までの外部変更を取りこぼさない。
        return
      }
    }
    // ここから無音再検証が今まさに始まるため、それ以前に立っていた保留は不要になる。
    // クリアしないと、無関係な余分な再検証がのちに1回走ってしまう。
    hasPendingWatcherEvent = false
    if !isArmCompletionCheck {
      startGitStatusLoad(at: location, invalidatingCache: true)
    }
    revalidateSilently(location, includingHidden: showsHiddenFiles)
  }

  func loadIfNeeded() {
    guard !isRetiredFromBrowsing, !hasStartedInitialLoad, !isRecentFilesActive else { return }
    load()
  }

  /// 表示外の転送先で衝突判定用の目録だけを取得する。通常のload()が始める
  /// 監視、Git・クラウド・Finderタグ補完、表示キャッシュは必要ないため起動しない。
  func loadTransferDestinationInventory() async {
    isLoading = true
    defer { isLoading = false }
    do {
      let loadedItems = try await loadItems(
        at: currentLocation,
        includingHidden: showsHiddenFiles,
        publishesPartialResults: false)
      try Task.checkCancellation()
      items = loadedItems
      errorMessage = nil
    } catch {
      guard !Task.isCancelled else { return }
      presentError(error)
    }
  }

  /// aliasを既定アプリへ渡す前に解決し、フォルダは内部で開く。
  func resolvedOriginalItem(_ item: FileItem) throws -> FileItem {
    var resolved = item
    var visited: Set<URL> = []
    for _ in 0..<32 {
      guard resolved.isAliasFile, let url = resolved.location.localURL else { return resolved }
      guard visited.insert(url.standardizedFileURL).inserted,
        let original = try LocalFileProvider().originalURL(for: url)
      else { throw CocoaError(.fileReadCorruptFile) }
      if let mounted = provider as? MountedVolumeProvider,
        !original.resolvingSymlinksInPath().pathComponents.starts(
          with: mounted.volumeURL.resolvingSymlinksInPath().pathComponents)
      {
        throw MountedVolumeProviderError.outsideVolume
      }
      resolved = try LocalFileProvider().item(at: original, providerID: provider.id)
    }
    throw CocoaError(.fileReadCorruptFile)
  }

  func showOriginal(_ item: FileItem) {
    guard item.location.providerID == provider.id, let url = item.location.localURL else { return }
    do {
      guard let original = try LocalFileProvider().originalURL(for: url) else { return }
      let target: FileItem
      if item.isAliasFile {
        target = try resolvedOriginalItem(item)
      } else {
        if let mounted = provider as? MountedVolumeProvider,
          !original.resolvingSymlinksInPath().pathComponents.starts(
            with: mounted.volumeURL.resolvingSymlinksInPath().pathComponents)
        {
          throw MountedVolumeProviderError.outsideVolume
        }
        target = try LocalFileProvider().item(at: original, providerID: provider.id)
      }
      if let parent = target.location.deletingLastPathComponent() {
        revealItem(at: target.url, in: parent)
      }
    } catch { presentError(error) }
  }

  func open(_ originalItem: FileItem) {
    guard originalItem.location.providerID == provider.id else { return }
    let item: FileItem
    do { item = try resolvedOriginalItem(originalItem) } catch {
      presentError(error)
      return
    }
    if let applicationURL = Self.localApplicationBundleURL(for: item) {
      launchApplication(at: applicationURL)
      return
    }
    if item.isDirectory {
      navigate(to: item.location)
    } else if let archiveURL = item.location.localURL, ArchiveFormat(url: archiveURL) == .zip {
      guard canArchive else { return }
      if isArchiving {
        openItems([item])
        return
      }
      // 検索結果や展開行でも、表示中の場所ではなくZIP自身の隣へ展開する。
      extractLocalArchive(
        item, archiveURL: archiveURL, directoryURL: archiveURL.deletingLastPathComponent(),
        to: .currentDirectory, organizingForDefaultOpen: true)
    } else if let localURL = item.location.localURL {
      // Finder同等: ローカル/マウント済みNASのファイルは既定アプリで開く。
      // 内部プレビューはQuick Look(Space/⌘Y)・ホバー・情報画面の役割として残す。
      openWithDefaultApplication(at: localURL)
    } else {
      // リモート(SFTP等)はダウンロードなしで外部アプリに渡せないため従来どおり内部プレビュー。
      preview(item)
    }
  }

  private func openWithDefaultApplication(at url: URL) {
    // ユニットテストがopen経路を検証する際に実際の既定アプリ起動やFinder表示を
    // 発火させない(テスト実行のたびに消える一時ファイルが外部アプリで開かれ
    // 「ファイルが見つかりません」が出る実害の封じ込め、2026-08-31)。
    guard
      !TestEnvironmentDetector.isRunningTests(environment: ProcessInfo.processInfo.environment)
    else { return }
    NSWorkspace.shared.open(
      url, configuration: NSWorkspace.OpenConfiguration()
    ) { [weak self] _, error in
      guard let error else { return }
      Task { @MainActor in
        self?.presentError(error)
      }
    }
  }

  /// itemがローカルの.appバンドルなら起動対象のURLを返す。ローカル項目(location.localURLを
  /// 持つ)のみが対象で、SFTP等リモート項目は該当しない(navigate/previewの既存挙動のまま)。
  /// NSWorkspace呼び出しを含まない純粋な判定関数のためユニットテストで直接検証できる。
  nonisolated static func localApplicationBundleURL(for item: FileItem) -> URL? {
    guard item.isDirectory, let localURL = item.location.localURL else { return nil }
    let hasAppExtension = localURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame
    let conformsToApplication =
      UTType(filenameExtension: localURL.pathExtension)?.conforms(to: .application) ?? false
    guard hasAppExtension || conformsToApplication else { return nil }
    return localURL
  }

  /// フォルダとして侵入せず、NSWorkspaceでアプリとして起動する。起動失敗時のみ
  /// errorMessageへ反映する(一覧はそのまま維持)。
  private func launchApplication(at url: URL) {
    // ユニットテストからは実アプリを起動しない(openWithDefaultApplicationと同じ封じ込め)。
    guard
      !TestEnvironmentDetector.isRunningTests(environment: ProcessInfo.processInfo.environment)
    else { return }
    NSWorkspace.shared.openApplication(
      at: url, configuration: NSWorkspace.OpenConfiguration()
    ) { [weak self] _, error in
      guard let error else { return }
      Task { @MainActor in
        self?.presentError(error)
      }
    }
  }

  func open(location: FileLocation) {
    guard location.providerID == provider.id else { return }
    navigate(to: location)
  }

  /// 同期ブラウズの相手側移動。移動先を先に列挙し、失敗時は表示場所もエラーも変えない。
  /// 成功時は取得済み一覧をそのまま適用し、リモートProviderの二重列挙を避ける。
  @discardableResult
  func followSyncBrowsing(
    to destination: FileLocation,
    expectedCurrentLocation: FileLocation
  ) async -> Bool {
    guard !isRetiredFromBrowsing,
      !isWorkspaceRemotePlaceholder,
      destination.providerID == provider.id,
      currentLocation == expectedCurrentLocation,
      destination != expectedCurrentLocation
    else {
      return false
    }
    let includingHidden = showsHiddenFiles
    do {
      let loadedItems = try await loadItems(
        at: destination,
        includingHidden: includingHidden,
        publishesPartialResults: false)
      try Task.checkCancellation()
      guard !isRetiredFromBrowsing, currentLocation == expectedCurrentLocation else {
        return false
      }
      navigate(
        to: destination,
        preloadedItems: loadedItems,
        includesHiddenItems: includingHidden)
      return true
    } catch {
      return false
    }
  }

  /// .appバンドルを起動せずフォルダとして侵入する(Finderの「パッケージの内容を表示」相当)。
  /// open(_:)は.appを起動へ振り分けるため、これがバンドル内部への唯一の侵入経路になる。
  func showPackageContents(_ item: FileItem) {
    guard item.location.providerID == provider.id, item.isDirectory else { return }
    navigate(to: item.location)
  }

  func setShowsHiddenFiles(_ showsHiddenFiles: Bool, reload: Bool = true) {
    guard self.showsHiddenFiles != showsHiddenFiles else { return }
    self.showsHiddenFiles = showsHiddenFiles
    if let recentFilesPresentation {
      if reload {
        startRecentFiles(recentFilesPresentation, recordsHistory: false)
      }
      return
    }
    if isSearchActive {
      // 検索結果は新しい隠し項目設定で再検索し、背後の通常一覧は検索終了時に再読込する。
      needsHiddenFilesReload = true
      if reload {
        resetTreeState()
        scheduleSearch()
      }
      return
    }
    guard hasStartedInitialLoad else {
      // 初回列挙前なら次のload()が新しい値を直接捕捉するため、遅延リロードは不要。
      // 差し替え先へ設定を継承してから初回ロードする経路でも、この順序を保証する。
      needsHiddenFilesReload = false
      if reload {
        load()
      }
      return
    }
    needsHiddenFilesReload = !reload
    if reload {
      // load()は同一フォルダの再読み込みでは展開状態を保持するが、隠しファイル表示の
      // 切替は展開済み子項目の内容自体(隠し項目の有無)を変えるため、ここで明示的に
      // リセットする(展開済みのまま古い内容が残るのを防ぐ)。
      resetTreeState()
      load()
    }
  }

  func reloadForHiddenFilesIfNeeded() {
    guard needsHiddenFilesReload else { return }
    if isSearchActive {
      scheduleSearch()
      return
    }
    needsHiddenFilesReload = false
    resetTreeState()
    load()
  }

  func refresh() {
    if let recentFilesPresentation {
      startRecentFiles(recentFilesPresentation, recordsHistory: false)
      return
    }
    // ディレクトリが同名の別物へ差し替えられていた場合(アンマウント→再マウント等)の
    // エスケープハッチ。古いfdを握ったままの監視を明示的に張り直させる。
    watchedDirectoryPath = nil
    directoryCache[currentLocation] = nil
    cancelCloudStatusLoad(at: currentLocation)
    removeCloudStatuses(in: currentLocation)
    reloadExpandedChildren()
    load(
      location: nil,
      preservingColumnState: false,
      preloadedItems: nil,
      includesHiddenItems: nil,
      invalidatesGitStatusCache: true)
  }

  func openSelectedItem(_ selectedItemURLs: Set<URL>) {
    openItems(selectableItemsSnapshot.orderedItems(for: selectedItemURLs))
  }

  func openItems(_ items: [FileItem]) {
    pendingOpenItems.append(contentsOf: items)
    guard !pendingOpenItems.isEmpty,
      openItemsTask == nil || openItemsTask?.isCancelled == true
    else { return }
    let token = UUID()
    openItemsToken = token
    openItemsTask = Task { [weak self] in
      guard let self else { return }
      var failures: [String] = []
      defer {
        if openItemsToken == token {
          openItemsTask = nil
          openItemsToken = nil
          if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
          purgeRetiredBrowsingSnapshot()
          notifyRetiredLifecycleDidBecomeIdle()
        }
      }
      while !pendingOpenItems.isEmpty {
        guard !Task.isCancelled else { return }
        // 連続した「開く」も同じキューへ入れ、先行ZIPの完了を待つ。
        if let archiveTask { await archiveTask.value }
        guard !Task.isCancelled else { return }
        let item = pendingOpenItems.removeFirst()
        open(item)
        if let archiveTask {
          await archiveTask.value
          if let errorMessage { failures.append(errorMessage) }
        }
      }
    }
  }

  func goBack() {
    guard let destination = history.popLast() else { return }
    forwardHistory.append(currentNavigationEntry)
    openNavigationEntry(destination)
  }

  func goForward() {
    guard let destination = forwardHistory.popLast() else { return }
    history.append(currentNavigationEntry)
    openNavigationEntry(destination)
  }

  private var currentNavigationEntry: NavigationEntry {
    if let recentFilesPresentation { return .recentFiles(recentFilesPresentation) }
    return .directory(currentLocation)
  }

  private func openNavigationEntry(_ entry: NavigationEntry) {
    switch entry {
    case .directory(let location):
      load(location: location)
    case .recentFiles(let presentation):
      startRecentFiles(presentation, recordsHistory: false)
    }
  }

  func openParent() {
    guard let parentLocation else { return }
    navigate(to: parentLocation)
  }

  func openBreadcrumb(_ breadcrumb: FileBrowserBreadcrumb) {
    guard breadcrumbs.contains(where: { $0.id == breadcrumb.id }) else { return }
    navigate(to: breadcrumb.location)
  }

  func createDirectory(named name: String) {
    guard !isRecentFilesActive else { return }
    perform { operations in
      try await operations.createDirectory(named: name, in: self.currentLocation)
    }
  }

  func rename(_ item: FileItem, to name: String) {
    guard !isLoading else { return }
    var reloadLocation: FileLocation?
    var onSuccess: (@MainActor (FileBrowserSession) -> Void)?
    if item.isDirectory,
      provider is any FileBrowserOperationProvider,
      let childIndex = columnState.columns.firstIndex(where: { $0.location == item.location }),
      childIndex > 0
    {
      // 改名で消えるパスを再列挙しないよう、対象を含む親カラムまで戻す。
      let parentLocation = columnState.columns[childIndex - 1].location
      selectColumnItemsForRename([], inColumnAt: parentLocation)
      reloadLocation = parentLocation

      let renamedName =
        item.location.remotePath == nil
        ? name : name.trimmingCharacters(in: .whitespacesAndNewlines)
      onSuccess = { session in
        guard session.columnState.columns.last?.location == parentLocation,
          let renamedItem = session.items.first(where: { $0.isDirectory && $0.name == renamedName })
        else { return }
        // 同じ名前の別フォルダを以前開いていても、改名後の内容を新たに読み込む。
        session.directoryCache[item.location] = nil
        session.directoryCache[renamedItem.location] = nil
        session.selectColumnItemsForRename([renamedItem.url], inColumnAt: parentLocation)
      }
    }
    perform(removingSearchResults: [item], reloadingAt: reloadLocation, onSuccess: onSuccess) {
      operations in
      try await operations.rename(item, to: name)
    }
  }

  /// 改名で右端を切り替えるときは、移動前の一覧更新を打ち切ってカラム選択を適用する。
  private func selectColumnItemsForRename(
    _ selectedURLs: Set<URL>, inColumnAt location: FileLocation
  ) {
    if isRefreshing {
      loadTask?.cancel()
      isRefreshing = false
    }
    selectColumnItems(selectedURLs, inColumnAt: location)
  }

  func batchRename(
    _ renames: [(item: FileItem, newName: String)]
  ) async -> BatchRenameResult {
    guard !renames.isEmpty else {
      return BatchRenameResult(requestedCount: 0, successes: [], failures: [])
    }
    if isRecentFilesActive {
      let error = PKPaneErrorClassifier.classify(FileBrowserSessionError.renameUnavailable)
      let result = BatchRenameResult(
        requestedCount: renames.count,
        successes: [],
        failures: renames.map {
          BatchRenameFailure(itemName: $0.item.name, newName: $0.newName, error: error)
        })
      presentError(error)
      return result
    }
    let validation = BatchRenameValidator.validate(
      renames: renames,
      existingItems: items + renames.map(\.item)
    )
    guard validation.isSafe else {
      let error = PKPaneError(
        category: .conflict,
        userMessage: String(localized: "一括リネームを実行できません。"),
        recoverySuggestion: validation.issues.prefix(3).map(\.message).joined(separator: "\n")
      )
      let result = BatchRenameResult(
        requestedCount: renames.count,
        successes: [],
        failures: renames.map {
          BatchRenameFailure(itemName: $0.item.name, newName: $0.newName, error: error)
        }
      )
      presentError(error)
      return result
    }
    guard !isLoading, let operations = provider as? any FileBrowserOperationProvider else {
      let error = PKPaneErrorClassifier.classify(FileBrowserSessionError.renameUnavailable)
      let result = BatchRenameResult(
        requestedCount: renames.count,
        successes: [],
        failures: renames.map {
          BatchRenameFailure(itemName: $0.item.name, newName: $0.newName, error: error)
        }
      )
      if let partialFailureError = result.partialFailureError {
        presentError(partialFailureError)
      }
      return result
    }

    let destination = currentLocation
    isPerformingFileOperation = true
    isLoading = true
    var successes = [BatchRenameSuccess]()
    var failures = [BatchRenameFailure]()
    for rename in renames {
      do {
        try Task.checkCancellation()
        try await operations.rename(rename.item, to: rename.newName)
        successes.append(BatchRenameSuccess(item: rename.item, newName: rename.newName))
      } catch {
        failures.append(
          BatchRenameFailure(
            itemName: rename.item.name,
            newName: rename.newName,
            error: PKPaneErrorClassifier.classify(error)
          ))
      }
    }

    var didFailRefresh = false
    do {
      let directoryModifiedAt = Self.directoryModifiedAt(of: destination)
      let loadedItems = try await provider.contents(
        of: destination,
        includingHidden: showsHiddenFiles
      )
      if currentLocation == destination {
        cacheDirectorySnapshot(
          DirectorySnapshot(
            items: loadedItems,
            includesHiddenItems: showsHiddenFiles,
            directoryModifiedAt: directoryModifiedAt),
          at: destination
        )
        items = loadedItems
      }
    } catch {
      didFailRefresh = true
      presentError(error)
    }

    removeSearchResults(
      at: Set(
        successes.compactMap {
          $0.parentLocation.appending(pathComponent: $0.oldName)
        }
      ))
    let result = BatchRenameResult(
      requestedCount: renames.count,
      successes: successes,
      failures: failures
    )
    if let partialFailureError = result.partialFailureError {
      presentError(partialFailureError)
    } else if !didFailRefresh {
      errorMessage = nil
    }
    isPerformingFileOperation = false
    if currentLocation == destination {
      isLoading = false
      consumePendingWatcherEventIfNeeded()
    }
    purgeRetiredBrowsingSnapshot()
    notifyRetiredLifecycleDidBecomeIdle()
    return result
  }

  func delete(_ item: FileItem) {
    delete([item])
  }

  func delete(_ items: [FileItem]) {
    guard !items.isEmpty else { return }
    guard !isLoading else { return }
    guard let operations = provider as? any FileBrowserOperationProvider else {
      errorMessage = "この接続ではファイル操作を利用できません。"
      return
    }
    isPerformingFileOperation = true
    isLoading = true
    Task { [weak self] in
      guard let self else { return }
      var itemsWithoutTrash = [FileItem]()
      var removedLocations = Set<FileLocation>()
      do {
        for item in items {
          try Task.checkCancellation()
          do {
            try await operations.delete(item)
            removedLocations.insert(item.location)
          } catch FileBrowserOperationError.trashUnavailable {
            itemsWithoutTrash.append(item)
          }
        }
        try await refreshContents()
        pendingPermanentDeleteItems = itemsWithoutTrash
        errorMessage = nil
      } catch {
        presentError(error)
      }
      removeSearchResults(at: removedLocations)
      isPerformingFileOperation = false
      isLoading = false
      consumePendingWatcherEventIfNeeded()
      purgeRetiredBrowsingSnapshot()
      notifyRetiredLifecycleDidBecomeIdle()
    }
  }

  func confirmPermanentDelete() {
    let items = pendingPermanentDeleteItems
    guard !items.isEmpty else { return }
    pendingPermanentDeleteItems = []
    perform(removingSearchResults: items) { [provider] _ in
      guard let permanentDeleteProvider = provider as? any FileBrowserPermanentDeleteProvider else {
        throw FileBrowserSessionError.permanentDeleteUnavailable
      }
      for item in items {
        try Task.checkCancellation()
        try await permanentDeleteProvider.permanentlyDelete(item)
      }
    }
  }

  func cancelPermanentDelete() {
    pendingPermanentDeleteItems = []
  }

  func discardTransferredItems(_ items: [FileItem]) {
    guard !items.isEmpty else { return }
    guard let transferProvider = provider as? any FileBrowserTransferProvider else {
      errorMessage = "この接続では転送の取り消しを利用できません。"
      return
    }
    guard !isLoading else { return }
    isPerformingFileOperation = true
    isLoading = true
    Task { [weak self] in
      guard let self else { return }
      var removedLocations = Set<FileLocation>()
      do {
        for item in items {
          try Task.checkCancellation()
          try await transferProvider.removeAfterCrossProviderMove(item)
          removedLocations.insert(item.location)
        }
        try await refreshContents()
        errorMessage = nil
      } catch {
        presentError(error)
      }
      removeSearchResults(at: removedLocations)
      isPerformingFileOperation = false
      isLoading = false
      consumePendingWatcherEventIfNeeded()
      purgeRetiredBrowsingSnapshot()
      notifyRetiredLifecycleDidBecomeIdle()
    }
  }

  /// 選択項目を同一フォルダ内へ複製する(ローカル/マウント済みNASのみ)。命名衝突は
  /// Provider側(LocalFileProvider.duplicate)が「(名前)のコピー」「のコピー2」…で解決する。
  func duplicate(_ items: [FileItem]) {
    guard !items.isEmpty else { return }
    perform { operations in
      guard let duplicateProvider = operations as? any FileBrowserDuplicateProvider else {
        throw FileBrowserSessionError.duplicateUnavailable
      }
      for item in items {
        try Task.checkCancellation()
        try await duplicateProvider.duplicate(item)
      }
    }
  }

  func move(_ items: [FileItem], to directory: FileLocation) {
    guard !items.isEmpty else { return }
    perform(removingSearchResults: items) { provider in
      guard let transferProvider = provider as? any FileBrowserTransferProvider else {
        throw FileBrowserSessionError.transferUnavailable
      }
      for item in items {
        try Task.checkCancellation()
        try await transferProvider.move(item, to: directory)
      }
    }
  }

  func copy(_ items: [FileItem], to directory: FileLocation) {
    guard !items.isEmpty else { return }
    perform { provider in
      guard let transferProvider = provider as? any FileBrowserTransferProvider else {
        throw FileBrowserSessionError.transferUnavailable
      }
      for item in items {
        try Task.checkCancellation()
        try await transferProvider.copy(item, to: directory)
      }
    }
  }

  func move(
    _ items: [FileItem],
    to destination: FileBrowserSession,
    destinationNames: [FileLocation: String] = [:],
    onCompleted: @escaping @MainActor () -> Void = {},
    dropPreparationTrace: DropPreparationTrace? = nil
  ) {
    transfer(
      items,
      to: destination,
      removesSourceAfterCopy: true,
      onCompleted: onCompleted,
      destinationNames: destinationNames,
      dropPreparationTrace: dropPreparationTrace)
  }

  func copy(
    _ items: [FileItem],
    to destination: FileBrowserSession,
    onCompleted: @escaping @MainActor () -> Void = {},
    dropPreparationTrace: DropPreparationTrace? = nil
  ) {
    transfer(
      items,
      to: destination,
      removesSourceAfterCopy: false,
      onCompleted: onCompleted,
      dropPreparationTrace: dropPreparationTrace)
  }

  func preview(_ item: FileItem) {
    guard !item.isDirectory else { return }
    guard let previewProvider = provider as? any FileBrowserPreviewProvider else {
      errorMessage = "この接続ではファイルのプレビューを利用できません。"
      return
    }
    Task { [weak self] in
      guard let self else { return }
      do {
        previewURL = try await previewProvider.previewURL(for: item)
        errorMessage = nil
      } catch {
        presentError(error)
      }
    }
  }

  func detailedItem(for item: FileItem) async -> FileItem {
    guard item.location.providerID == provider.id,
      let detailProvider = provider as? any FileBrowserItemDetailProvider
    else {
      return item
    }
    return (try? await detailProvider.detailedItem(at: item.location)) ?? item
  }

  func detailThumbnailURL(for item: FileItem) async throws -> URL? {
    guard item.location.providerID == provider.id,
      let previewProvider = provider as? any FileBrowserPreviewProvider
    else {
      return nil
    }
    return try await previewProvider.detailThumbnailURL(for: item)
  }

  func setPosixPermissions(_ permissions: Int, for item: FileItem) async throws -> FileItem {
    guard item.location.providerID == provider.id,
      let permissionsProvider = provider as? any FileBrowserPosixPermissionsProvider,
      let detailProvider = provider as? any FileBrowserItemDetailProvider
    else {
      throw FileBrowserSessionError.permissionsUnavailable
    }
    do {
      try await permissionsProvider.setPosixPermissions(
        PosixPermissions.normalizedMode(permissions),
        at: item.location)
      let updatedItem = try await detailProvider.detailedItem(at: item.location)
      replaceCachedItem(updatedItem)
      errorMessage = nil
      return updatedItem
    } catch {
      presentError(error)
      throw error
    }
  }

  /// 一括操作の判定前に全件を読み込み、読取失敗時の部分的な書込を防ぐ。
  func finderTagItemsForEditing(_ items: [FileItem]) async throws -> [FileItem] {
    guard canEditFinderTags,
      let detailProvider = provider as? any FileBrowserItemDetailProvider
    else { throw FileBrowserSessionError.finderTagsUnavailable }
    let expectedProviderID = provider.id
    let expectedConnectionID = provider.connectionID
    var resolved: [FileItem] = []
    for item in items {
      try Task.checkCancellation()
      guard item.location.providerID == provider.id else {
        throw FileBrowserSessionError.finderTagsUnavailable
      }
      var detailed = try await detailProvider.detailedItem(at: item.location)
      if let metadataProvider = provider as? any FileBrowserFinderTagMetadataProvider {
        // 専用の読取は正常な無タグを[]、取得失敗をthrowとして区別できる。
        detailed = detailed.replacingTags(
          try await metadataProvider.finderTagNames(at: item.location))
      }
      guard detailed.location == item.location,
        provider.id == expectedProviderID,
        provider.connectionID == expectedConnectionID,
        detailed.tags != nil
      else { throw FileBrowserSessionError.finderTagReadUnavailable }
      resolved.append(detailed)
    }
    return resolved
  }

  func toggleFinderTag(name: String, for items: [FileItem]) async -> FinderTagUpdateResult {
    await FinderTagOperationQueue.shared.perform(items: items) {
      await self.applyFinderTagToggle(name: name, for: items)
    }
  }

  private func applyFinderTagToggle(name: String, for items: [FileItem]) async
    -> FinderTagUpdateResult
  {
    guard let normalizedName = FinderTagEditing.normalizedNames([name]).first,
      !items.isEmpty
    else {
      return FinderTagUpdateResult(items: items, failedCount: 0, firstErrorDescription: nil)
    }
    do {
      let resolved = try await finderTagItemsForEditing(items)
      let allHaveTag = FinderTagEditing.commonNames(in: resolved).contains(normalizedName)
      let mutation = FinderTagMutation(
        additions: allHaveTag ? [] : [normalizedName],
        removals: allHaveTag ? [normalizedName] : [])
      return await applyFinderTagMutation(mutation, for: resolved)
    } catch {
      let message = PKPaneErrorClassifier.classify(error).displayMessage
      let result = FinderTagUpdateResult(
        items: items, failedCount: items.count, firstErrorDescription: message)
      errorMessage = result.errorMessage
      return result
    }
  }

  func updateFinderTags(
    _ mutation: FinderTagMutation,
    for selectedItems: [FileItem]
  ) async -> FinderTagUpdateResult {
    await FinderTagOperationQueue.shared.perform(items: selectedItems) {
      await self.applyFinderTagMutation(mutation, for: selectedItems)
    }
  }

  private func applyFinderTagMutation(
    _ mutation: FinderTagMutation,
    for selectedItems: [FileItem]
  ) async -> FinderTagUpdateResult {
    guard !mutation.isEmpty, !selectedItems.isEmpty else {
      return FinderTagUpdateResult(
        items: selectedItems, failedCount: 0, firstErrorDescription: nil)
    }
    let unavailableMessage =
      PKPaneErrorClassifier.classify(FileBrowserSessionError.finderTagsUnavailable).displayMessage
    guard let tagProvider = provider as? any FileBrowserFinderTagProvider,
      provider is any FileBrowserItemDetailProvider,
      capabilities.contains(.finderTags)
    else {
      errorMessage = unavailableMessage
      return FinderTagUpdateResult(
        items: selectedItems,
        failedCount: selectedItems.count,
        firstErrorDescription: unavailableMessage)
    }

    var resultingItems: [FileItem] = []
    resultingItems.reserveCapacity(selectedItems.count)
    var failedCount = 0
    var firstErrorDescription: String?

    for item in selectedItems {
      guard item.location.providerID == provider.id else {
        failedCount += 1
        firstErrorDescription = firstErrorDescription ?? unavailableMessage
        resultingItems.append(item)
        continue
      }
      do {
        // 一覧のtagsは未補完(nil)の場合があるため、書き込み直前にディスク上の現在値を
        // 取得し直してread-modify-writeする。nilを空配列として丸ごと置換すると、既存タグを
        // 静かに消してしまう。
        guard let currentItem = try await finderTagItemsForEditing([item]).first else {
          throw FileBrowserSessionError.finderTagReadUnavailable
        }
        let currentNames = FinderTagEditing.normalizedNames(currentItem.tags ?? [])
        let updatedNames = mutation.applying(to: currentItem.tags)
        guard updatedNames != currentNames else {
          replaceCachedItem(currentItem)
          resultingItems.append(currentItem)
          continue
        }
        try Task.checkCancellation()
        try await tagProvider.setFinderTagNames(updatedNames, at: item.location)
        let updatedItem =
          (try? await finderTagItemsForEditing([item]).first)
          ?? currentItem.replacingTags(updatedNames)
        replaceCachedItem(updatedItem)
        resultingItems.append(updatedItem)
      } catch {
        failedCount += 1
        firstErrorDescription =
          firstErrorDescription ?? PKPaneErrorClassifier.classify(error).displayMessage
        resultingItems.append(item)
      }
    }

    let result = FinderTagUpdateResult(
      items: resultingItems,
      failedCount: failedCount,
      firstErrorDescription: firstErrorDescription)
    errorMessage = result.errorMessage
    return result
  }

  private func replaceCachedItem(_ updatedItem: FileItem) {
    replaceCachedItems([updatedItem])
  }

  /// 同じ補完バッチの項目を表示コンテナごとに1回の差し替えへまとめる。Finderタグの
  /// 64件補完で、1万件のルート配列やディレクトリキャッシュを64回走査しないための経路。
  private func replaceCachedItems(
    _ updatedItems: [FileItem],
    updatesDirectoryCache: Bool = true
  ) {
    guard !updatedItems.isEmpty else { return }
    let updatesByLocation = Dictionary(
      updatedItems.map { ($0.location, $0) }, uniquingKeysWith: { _, latest in latest })
    let updatedRootItems = items.map { item in
      updatesByLocation[item.location] ?? item
    }
    if updatedRootItems != items {
      items = updatedRootItems
    }

    var updatedTreeState = treeState
    var didUpdateTreeState = false
    for (location, children) in treeState.childrenByLocation {
      let updatedChildren = children.map { updatesByLocation[$0.location] ?? $0 }
      guard updatedChildren != children else { continue }
      _ = updatedTreeState.setChildren(
        updatedChildren,
        for: location,
        generation: updatedTreeState.currentGeneration(for: location))
      didUpdateTreeState = true
    }
    if didUpdateTreeState {
      treeState = updatedTreeState
      treeStateRevision &+= 1
    }

    var updatedColumnState = columnState
    for column in columnState.columns {
      let updatedColumnItems = column.items.map { updatesByLocation[$0.location] ?? $0 }
      updatedColumnState.setItems(updatedColumnItems, at: column.location)
    }
    if updatedColumnState != columnState {
      columnState = updatedColumnState
      columnDisplayCache.removeAll()
    }

    guard updatesDirectoryCache else { return }
    for location in Array(directoryCache.keys) {
      guard let snapshot = directoryCache.value(forKey: location, touching: false) else { continue }
      let updatedSnapshotItems = snapshot.items.map { item in
        updatesByLocation[item.location] ?? item
      }
      guard updatedSnapshotItems != snapshot.items else { continue }
      cacheDirectorySnapshot(
        DirectorySnapshot(
          items: updatedSnapshotItems,
          includesHiddenItems: snapshot.includesHiddenItems,
          directoryModifiedAt: snapshot.directoryModifiedAt), at: location)
    }
  }

  private func cacheDirectorySnapshot(_ snapshot: DirectorySnapshot, at location: FileLocation) {
    let currentLocation = currentLocation
    let displayedColumnLocations = columnState.columns.map(\.location)
    directoryCache.setValue(snapshot, forKey: location) { candidate in
      candidate == currentLocation
        || treeState.isExpanded(candidate)
        || displayedColumnLocations.contains(candidate)
    }
  }

  func clearError() {
    errorMessage = nil
  }

  func presentError(_ error: Error) {
    errorMessage = PKPaneErrorClassifier.classify(error).displayMessage
  }

  func cancelTransfer() {
    let jobIDs = activeTransferJobIDs
    Task {
      for jobID in jobIDs {
        await transferQueue.cancel(jobID)
      }
    }
  }

  var canRetryLastTransfer: Bool { failedTransfer != nil && !isTransferring }

  func retryLastTransfer() {
    guard let failedTransfer else { return }
    self.failedTransfer = nil
    guard let failedTransferJobID else {
      startTransfer(
        failedTransfer.items,
        to: failedTransfer.destination,
        removesSourceAfterCopy: failedTransfer.removesSourceAfterCopy,
        onCompleted: failedTransfer.onCompleted,
        replacingExisting: failedTransfer.replacingExisting,
        refreshesBrowsersOnCompletion: failedTransfer.refreshesBrowsersOnCompletion,
        itemOptions: failedTransfer.itemOptions,
        skippedItemCount: failedTransfer.skippedItemCount)
      return
    }
    self.failedTransferJobID = nil
    // 手動リトライは自動再接続(P1-3)の回数制限とは無関係に常に可能なため、自動側の
    // 試行回数カウンタをここでリセットする(このジョブへの新しい取り組みとみなす)。
    autoReconnectAttempts[failedTransferJobID] = nil
    performQueuedRetry(failedTransfer, jobID: failedTransferJobID)
  }

  /// 一時停止中のジョブを、停止前から保持している転送情報または復元済みの転送情報から
  /// 再開する。failed/cancelledのretry経路とは分離し、TransferQueue.resumeだけを使う。
  @discardableResult
  func resumeTransfer(_ jobID: UUID) -> Bool {
    if resumingTransferJobIDs.contains(jobID) {
      return true
    }
    let pending: PendingTransfer
    if let activeTransfer = activeTransfers[jobID] {
      pending = activeTransfer
    } else if let pausedTransfer = pausedTransfers[jobID] {
      pending = pausedTransfer
    } else {
      return false
    }
    resumingTransferJobIDs.insert(jobID)
    executingTransferJobIDs.insert(jobID)
    isTransferring = true
    autoReconnectAttempts[jobID] = nil
    performQueuedResume(pending, jobID: jobID)
    return true
  }

  /// キュー上のjobIDに対する再試行を実行する。手動retryLastTransferから呼ばれる。
  /// 自動再接続(P1-3、Fix A)はTransferQueue内部でバックオフを挟みながら完結するため、
  /// ここではautoRetryPlannerを一緒に登録するだけでよい(バックオフのTaskをこの層で
  /// 管理しない)。
  private func performQueuedRetry(_ pending: PendingTransfer, jobID: UUID) {
    let sourceProvider = provider
    let destinationProvider = pending.destination.provider
    let destinationLocation = pending.destination.currentLocation
    beginTransfer(pending, jobID: jobID)
    let autoRetryPlanner = makeAutoRetryPlanner(pending: pending, jobID: jobID)
    Task { [weak self, transferQueue] in
      let (execution, totalBytes, narrowedItems) = await Self.buildRetryAttempt(
        items: pending.items,
        jobID: jobID,
        sourceProvider: sourceProvider,
        destinationProvider: destinationProvider,
        destinationLocation: destinationLocation,
        removesSourceAfterCopy: pending.removesSourceAfterCopy,
        replacingExisting: pending.replacingExisting,
        itemOptions: pending.itemOptions,
        transferQueue: transferQueue)
      await transferQueue.retry(
        jobID,
        items: narrowedItems,
        execution: execution,
        autoRetryPlanner: autoRetryPlanner)
      await transferQueue.applyAggregatedTotalBytes(jobID, totalBytes: totalBytes)
      guard let self else { return }
      self.receiveTransferUpdates(await transferQueue.allJobs())
    }
  }

  /// paused専用の再開処理。停止前のactiveTransferが残っている場合は登録を重ねず、
  /// 再起動後の復元経路だけbeginTransferで購読とセッション状態を再構成する。
  private func performQueuedResume(_ pending: PendingTransfer, jobID: UUID) {
    let sourceProvider = provider
    let destinationProvider = pending.destination.provider
    let destinationLocation = pending.destination.currentLocation
    let registeredForRestoredResume = activeTransfers[jobID] == nil
    if registeredForRestoredResume {
      beginTransfer(pending, jobID: jobID)
    }
    let autoRetryPlanner = makeAutoRetryPlanner(pending: pending, jobID: jobID)
    Task { [weak self, transferQueue] in
      let (execution, totalBytes, narrowedItems) = await Self.buildRetryAttempt(
        items: pending.items,
        jobID: jobID,
        sourceProvider: sourceProvider,
        destinationProvider: destinationProvider,
        destinationLocation: destinationLocation,
        removesSourceAfterCopy: pending.removesSourceAfterCopy,
        replacingExisting: pending.replacingExisting,
        itemOptions: pending.itemOptions,
        transferQueue: transferQueue)
      let didResume = await transferQueue.resume(
        jobID,
        items: narrowedItems,
        execution: execution,
        autoRetryPlanner: autoRetryPlanner)
      guard let self else { return }
      self.resumingTransferJobIDs.remove(jobID)
      guard didResume else {
        if registeredForRestoredResume {
          self.activeTransfers[jobID] = nil
          self.finishActiveTransfer(jobID)
          if pending.destination !== self {
            pending.destination.finishActiveTransfer(jobID)
          }
        } else {
          self.executingTransferJobIDs.remove(jobID)
          self.isTransferring = !self.executingTransferJobIDs.isEmpty
        }
        return
      }
      self.pausedTransfers[jobID] = nil
      await transferQueue.applyAggregatedTotalBytes(jobID, totalBytes: totalBytes)
      self.receiveTransferUpdates(await transferQueue.allJobs())
    }
  }

  /// 転送レジューム(P1-2): 前回のこのジョブの実行で検証まで通って完了した記録
  /// (completedItems)と、宛先の軽量な再確認を突き合わせ、安全にスキップできる項目を
  /// 除いた分だけを再試行対象にし、そこから実行可能なexecutionを組み立てる。
  /// 手動retryLastTransfer(performQueuedRetry)と自動再接続(makeAutoRetryPlannerが
  /// 返すクロージャ)の両方から共有する。
  nonisolated private static func buildRetryAttempt(
    items: [FileItem],
    jobID: UUID,
    sourceProvider: any FileBrowserProvider,
    destinationProvider: any FileBrowserProvider,
    destinationLocation: FileLocation,
    removesSourceAfterCopy: Bool,
    replacingExisting: Bool,
    itemOptions: [FileLocation: TransferItemOptions] = [:],
    transferQueue: TransferQueue
  ) async -> (execution: TransferQueue.Execution, totalBytes: Int64?, items: [TransferJob.Item]) {
    var itemOptions = itemOptions
    if let current = await transferQueue.allJobs().first(where: { $0.id == jobID }) {
      for item in current.completedItems + current.items {
        itemOptions[item.location] = item.transferOptions
      }
    }
    let completedItems = await transferQueue.completedItems(
      for: jobID, currentDestination: destinationLocation)
    let (itemsToTransfer, skippedBytes) = await partitionResumableItems(
      items,
      completedItems: completedItems,
      destinationLocation: destinationLocation,
      destinationProvider: destinationProvider,
      itemOptions: itemOptions)
    let (remainingTotal, itemSizes) = await transferSizes(
      of: itemsToTransfer, using: sourceProvider,
      moveDestination: removesSourceAfterCopy ? destinationLocation : nil, itemOptions: itemOptions)
    let totalBytes = remainingTotal.map { $0 + skippedBytes }
    let execution = makeTransferExecution(
      items: itemsToTransfer,
      itemSizes: itemSizes,
      totalBytes: totalBytes,
      sourceProvider: sourceProvider,
      destinationProvider: destinationProvider,
      destinationLocation: destinationLocation,
      removesSourceAfterCopy: removesSourceAfterCopy,
      replacingExisting: replacingExisting,
      itemOptions: itemOptions,
      completedBytesBaseline: skippedBytes,
      mergingExistingDirectoryTrees: true,
      destinationReserved: { location, options in
        guard let name = options.destinationName else { throw FTPFileProviderError.invalidName }
        try await transferQueue.recordReservedDestinationName(name, for: location, jobID: jobID)
      })
    return (
      execution, totalBytes,
      itemsToTransfer.map {
        TransferJob.Item($0, options: itemOptions[$0.location] ?? TransferItemOptions())
      }
    )
  }

  /// 自動再接続(P1-3)用のプランナーを作る。TransferQueueが失敗を検知するたびに呼ばれ、
  /// SFTP限定のスコープ(AutoReconnectEligibleProvider)に適合し、かつ自動リトライの
  /// 残り回数があれば、バックオフと次のexecutionを返す。このジョブは失敗してもactive
  /// Transfers/activeTransferJobIDsに登録されたままのため(Fix A、stateがterminalに
  /// ならない)、ここでbeginTransferを呼び直す必要はない。
  private func makeAutoRetryPlanner(
    pending: PendingTransfer, jobID: UUID
  ) -> TransferQueue.AutoRetryPlanner {
    let sourceProvider = provider
    let destinationProvider = pending.destination.provider
    let destinationLocation = pending.destination.currentLocation
    let backoffSchedule = autoReconnectBackoff
    let items = pending.items
    let removesSourceAfterCopy = pending.removesSourceAfterCopy
    let transferQueue = transferQueue
    // 新規予約のFTP別名ジョブは、結果確認後に失敗項目だけ手動再試行する。
    let requiresManualRetry =
      destinationProvider is FTPFileProvider
      && pending.itemOptions.values.contains { $0.destinationName != nil && !$0.replacingExisting }
    return { [weak self] isReconnectFutile in
      guard !requiresManualRetry, !isReconnectFutile,
        TransferReconnectionPolicy.isEligible(
          sourceProvider: sourceProvider, destinationProvider: destinationProvider)
      else { return nil }
      guard let self, let attemptNumber = await self.nextAutoReconnectAttempt(for: jobID) else {
        return nil
      }
      let backoff = backoffSchedule[attemptNumber - 1]
      let (execution, _, _) = await Self.buildRetryAttempt(
        items: items,
        jobID: jobID,
        sourceProvider: sourceProvider,
        destinationProvider: destinationProvider,
        destinationLocation: destinationLocation,
        removesSourceAfterCopy: removesSourceAfterCopy,
        replacingExisting: pending.replacingExisting,
        itemOptions: pending.itemOptions,
        transferQueue: transferQueue)
      return (backoff, execution)
    }
  }

  /// completedItems(前回以前に検証済みで完了した記録)と実際のdestination再確認を
  /// 突き合わせ、安全にスキップできる項目を除いた再試行対象と、スキップ分の
  /// バイト数を返す。宛先が消えている・サイズ不一致・再確認手段が無い・
  /// ディレクトリ/シンボリックリンク(そもそも記録対象外だが念のため)は、
  /// 安全側に倒して再転送対象に含める。
  private struct ResumeCandidate: Sendable {
    let index: Int
    let expectedBytes: Int64
    let destinationItemLocation: FileLocation
  }

  nonisolated private static func partitionResumableItems(
    _ items: [FileItem],
    completedItems: [TransferJob.Item],
    destinationLocation: FileLocation,
    destinationProvider: any FileBrowserProvider,
    itemOptions: [FileLocation: TransferItemOptions] = [:]
  ) async -> (itemsToTransfer: [FileItem], skippedBytes: Int64) {
    guard !completedItems.isEmpty else { return (items, 0) }
    let completedLocations = Set(completedItems.map(\.location))

    // 宛先の再確認が必要な項目(candidate)と、判定に非同期I/Oが要らない項目を先に分ける。
    // 後者は元の順序のまま無条件で転送対象になる。
    var candidates: [ResumeCandidate] = []
    for (index, item) in items.enumerated() {
      guard completedLocations.contains(item.location),
        !item.isDirectory, !item.isSymbolicLink,
        let expectedBytes = item.size,
        let destinationItemLocation = destinationLocation.appending(
          pathComponent: itemOptions[item.location]?.destinationName ?? item.name)
      else { continue }
      candidates.append(
        ResumeCandidate(
          index: index, expectedBytes: expectedBytes,
          destinationItemLocation: destinationItemLocation))
    }
    guard !candidates.isEmpty else { return (items, 0) }

    // 1件ずつawaitすると大量ファイルの再開でRTT×件数かかる(1万件・20msなら3分超)ため、
    // TaskGroupで並列化する。並列度は接続への負荷を抑えるため一定数に制限する。
    // 結果はindexで受け取り、後段でitemsの元の順序どおりに組み立て直す。
    let maximumConcurrency = 8
    let skippedIndices = await withTaskGroup(of: Int?.self) { group -> Set<Int> in
      var iterator = candidates.makeIterator()
      func addNext() {
        guard let candidate = iterator.next() else { return }
        group.addTask {
          let actualBytes: Int64?
          do {
            actualBytes = try await TransferSizeVerifier.actualSize(
              at: candidate.destinationItemLocation, using: destinationProvider)
          } catch {
            actualBytes = nil
          }
          guard let actualBytes, actualBytes == candidate.expectedBytes else { return nil }
          return candidate.index
        }
      }
      for _ in 0..<min(maximumConcurrency, candidates.count) {
        addNext()
      }
      var skipped = Set<Int>()
      while let result = await group.next() {
        if let index = result { skipped.insert(index) }
        addNext()
      }
      return skipped
    }

    var itemsToTransfer: [FileItem] = []
    var skippedBytes: Int64 = 0
    for (index, item) in items.enumerated() {
      if skippedIndices.contains(index) {
        skippedBytes += item.size ?? 0
      } else {
        itemsToTransfer.append(item)
      }
    }
    return (itemsToTransfer, skippedBytes)
  }

  /// job(中断・失敗・キャンセル済み)が自分→destinationの転送に一致するときだけ、
  /// 再試行に必要な状態(failedTransfer/failedTransferJobID)を整える。errorMessage
  /// (一覧エラー)へは書き込まない。転送バーの「再試行」など、一覧のエラー表示を
  /// 巻き添えにしたくない呼び出し元向け。マッチしたかどうかを返す。
  @discardableResult
  func prepareTransferRetry(_ job: TransferJob, to destination: FileBrowserSession) -> Bool {
    guard job.state == .interrupted || job.state == .failed || job.state == .cancelled,
      job.sourceProviderID == provider.id,
      job.destinationProviderID == destination.provider.id,
      job.destination == destination.currentLocation,
      failedTransferJobID != job.id
    else {
      return false
    }
    failedTransfer = PendingTransfer(
      items: job.items.map(\.fileItem),
      destination: destination,
      removesSourceAfterCopy: job.kind == .move,
      onCompleted: {},
      refreshesBrowsersOnCompletion: true,
      replacingExisting: false,
      itemOptions: Dictionary(
        uniqueKeysWithValues: job.items.map { ($0.location, $0.transferOptions) }),
      skippedItemCount: job.skippedItemCount)
    failedTransferJobID = job.id
    return true
  }

  /// 再起動後に残ったpausedジョブを、現在の2ペインへ安全に対応付けて再開準備する。
  /// failed/cancelled/interruptedの再試行状態とは別の器へ保持する。
  @discardableResult
  func prepareTransferResume(_ job: TransferJob, to destination: FileBrowserSession) -> Bool {
    guard job.state == .paused,
      job.sourceProviderID == provider.id,
      job.destinationProviderID == destination.provider.id,
      job.destination == destination.currentLocation
    else {
      return false
    }
    pausedTransfers[job.id] = PendingTransfer(
      items: job.items.map(\.fileItem),
      destination: destination,
      removesSourceAfterCopy: job.kind == .move,
      onCompleted: {},
      refreshesBrowsersOnCompletion: true,
      replacingExisting: false,
      itemOptions: Dictionary(
        uniqueKeysWithValues: job.items.map { ($0.location, $0.transferOptions) }),
      skippedItemCount: job.skippedItemCount)
    return true
  }

  /// アプリ再起動時に見つかった中断済み転送を、一覧エラーとして通知しながら復元する。
  func restoreInterruptedTransfer(_ job: TransferJob, to destination: FileBrowserSession) {
    guard prepareTransferRetry(job, to: destination) else { return }
    errorMessage = job.errorDescription ?? "中断した転送があります。最初から再試行してください。"
  }

  func resolvePendingTransferConflict(replaceExisting: Bool) {
    resolvePendingTransferConflict(replaceExisting ? .replace : .cancel)
  }

  func resolvePendingTransferConflict(
    _ resolution: TransferConflictResolution, applyToRemaining: Bool = false
  ) {
    guard let pendingTransfer, var state = transferConflictState else { return }
    if case .cancel = resolution {
      clearPendingTransferConflict()
      return
    }
    if case .keepBoth = resolution, pendingTransferConflict?.canKeepBoth != true { return }
    let resolvingItems =
      applyToRemaining ? state.remainingItems : Array(state.remainingItems.prefix(1))
    for item in resolvingItems {
      var options = state.itemOptions[item.location] ?? TransferItemOptions()
      switch resolution {
      case .replace:
        options.replacingExisting = true
      case .skip:
        state.skippedLocations.insert(item.location)
      case .keepBoth:
        options.destinationName = TransferItemOptions.availableName(
          for: options.destinationName ?? item.name,
          isDirectory: item.isDirectory, occupiedNames: state.occupiedNames)
        options.replacingExisting = false
        options.destinationNameWasReserved = false
        options.requiredDestinationName = nil
        if let name = options.destinationName { state.occupiedNames.insert(name) }
      case .cancel:
        break
      }
      state.itemOptions[item.location] = options
    }
    state.remainingItems.removeFirst(resolvingItems.count)
    transferConflictState = state
    if !state.remainingItems.isEmpty {
      updatePendingTransferConflict()
      return
    }
    clearPendingTransferConflict()
    let transferringItems = pendingTransfer.items.filter {
      !state.skippedLocations.contains($0.location)
    }
    guard !transferringItems.isEmpty else {
      transferResolutionNotice = String(
        localized: "\(state.skippedLocations.count)項目をスキップしました。転送は行っていません。")
      return
    }
    startTransfer(
      transferringItems,
      to: pendingTransfer.destination,
      removesSourceAfterCopy: pendingTransfer.removesSourceAfterCopy,
      onCompleted: pendingTransfer.onCompleted,
      itemOptions: state.itemOptions,
      skippedItemCount: state.skippedLocations.count)
  }

  private func clearPendingTransferConflict() {
    pendingTransfer = nil
    pendingTransferConflict = nil
    transferConflictState = nil
  }

  private func updatePendingTransferConflict() {
    guard let pendingTransfer, let state = transferConflictState,
      let item = state.remainingItems.first
    else { return }
    let names = state.remainingItems.prefix(3).map {
      state.itemOptions[$0.location]?.destinationName ?? $0.name
    }
    let destinationName = state.itemOptions[item.location]?.destinationName ?? item.name
    let directoryIsReplaced = { (name: String) in
      state.destinationItemsByName[name]?.isDirectory == true
        && state.destinationItemsByName[name]?.isSymbolicLink != true
    }
    pendingTransferConflict = TransferConflict(
      sourceName: item.name, destinationName: destinationName,
      remainingNames: names, remainingCount: state.remainingItems.count,
      totalCount: state.totalCount,
      selectedCount: pendingTransfer.items.count,
      replacesDirectory: directoryIsReplaced(destinationName),
      remainingReplacesDirectory: state.remainingItems.contains {
        directoryIsReplaced(state.itemOptions[$0.location]?.destinationName ?? $0.name)
      },
      isRemote: pendingTransfer.destination.currentLocation.localURL == nil,
      canKeepBoth: pendingTransfer.destination.provider is any FileTransferCommitProvider
        && pendingTransfer.destination.provider is any FileBrowserTransferProvider,
      usesServerAssignedNames: pendingTransfer.destination.provider is FTPFileProvider)
  }

  /// 表示対象から外れたセッションの閲覧処理だけを停止する。クリップボードやUndoが
  /// 転送元・転送先としてこのセッションを参照している場合でも、Providerと現在地は
  /// 保持しつつ、一覧列挙・監視・カラムロードを残さない。
  func retireFromBrowsing(onLifecycleDidBecomeIdle: @escaping @MainActor () -> Void) {
    isRetiredFromBrowsing = true
    retiredLifecycleDidBecomeIdle = onLifecycleDidBecomeIdle
    stopBrowsingResources()
    if !isTransferring {
      stopObservingTransferUpdates()
    }
  }

  /// アーカイブ内閲覧などの一時セッションから戻る際、退役前の履歴を保持したまま
  /// 一覧・監視・転送更新だけを再開する。
  func resumeBrowsing() {
    guard isRetiredFromBrowsing else { return }
    isRetiredFromBrowsing = false
    retiredLifecycleDidBecomeIdle = nil
    hasStartedInitialLoad = false
    isLoading = false
    isRefreshing = false
    startObservingTransferUpdatesIfNeeded()
  }

  private func stopBrowsingResources() {
    cancelSearch(clearText: true, clearRevealRequest: true)
    loadTask?.cancel()
    revalidationTask?.cancel()
    cancelMetadataEnrichment()
    watcherArmTask?.cancel()
    resetTreeState()
    cancelAllColumnLoads()
    cancelAllGitStatusLoadsAndClearStatuses()
    cancelAllCloudStatusLoadsAndClearStatuses()
    columnState.reset()
    updateColumnWatchers()
    columnDisplayCache.removeAll()
    loadTask = nil
    revalidationTask = nil
    watcherArmTask = nil
    directoryWatcher = nil
    watchedDirectoryPath = nil
    hasPendingWatcherEvent = false
    directoryCache.removeAll()
    items = []
    isLoading = isPerformingFileOperation
    isRefreshing = false
    // revalidationTaskをcancelしただけではdeferがcancel時にフラグを下ろさない設計
    // (先発が後発のフラグを壊さないための意図的な挙動、revalidateSilently内のdefer参照)
    // なので、ここで直接下ろしておく。
    isRevalidatingInBackground = false
  }

  private func purgeRetiredBrowsingSnapshot() {
    guard isRetiredFromBrowsing else { return }
    directoryCache.removeAll()
    items = []
  }

  private func notifyRetiredLifecycleDidBecomeIdle() {
    guard isRetiredFromBrowsing, !hasBackgroundFileOperation else { return }
    retiredLifecycleDidBecomeIdle?()
  }

  func invalidate() {
    cancelArchiveOperation()
    isRetiredFromBrowsing = true
    retiredLifecycleDidBecomeIdle = nil
    stopBrowsingResources()
    stopObservingTransferUpdates()
    cancelTransfer()
    isTransferring = false
    isPerformingFileOperation = false
    clearPendingTransferConflict()
    pendingPermanentDeleteItems = []
    failedTransfer = nil
    pausedTransfers.removeAll()
    activeTransfers.removeAll()
    cloudTransferJobIDs.removeAll()
    cloudTransferPreparationNotice = nil
    activeTransferJobIDs.removeAll()
    executingTransferJobIDs.removeAll()
    resumingTransferJobIDs.removeAll()
    failedTransferJobID = nil
    previewURL = nil
    autoReconnectAttempts.removeAll()
  }

  func makePeerSession(at location: FileLocation? = nil) -> FileBrowserSession {
    let peer = FileBrowserSession(
      provider: provider,
      initialLocation: location ?? currentLocation,
      navigationBoundary: navigationBoundary,
      transferQueue: transferQueue,
      gitStatusPreferences: gitStatusPreferences,
      directoryCacheLimit: directoryCacheLimit,
      workspaceBookmarkAccessLease: workspaceBookmarkAccessLease)
    peer.setShowsHiddenFiles(showsHiddenFiles, reload: false)
    peer.retainedRecentAccessLeases = retainedRecentAccessLeases
    if let parent = location?.localURL?.standardizedFileURL {
      peer.recentTransferSourceRoot = retainedRecentAccessLeases.values
        .map(\.rootURL)
        .filter { parent.pathComponents.starts(with: $0.standardizedFileURL.pathComponents) }
        .max { $0.pathComponents.count < $1.pathComponents.count }
    }
    return peer
  }

  func prepareRecentTransferBookmark(
    using reader: RecentSourceBookmarkReader = .shared
  ) async -> Bool {
    guard let recentTransferSourceRoot,
      let data = await reader.bookmark(for: recentTransferSourceRoot)
    else { return false }
    recentTransferSourceBookmarkData = data
    return true
  }

  /// 表示外の転送先として使うセッション。衝突判定と転送状態だけを保持し、通常の
  /// ブラウザが使う転送更新購読と表示用ライフサイクルは開始しない。
  func makeTransferDestinationSession(at location: FileLocation) -> FileBrowserSession {
    let destination = FileBrowserSession(
      provider: provider,
      initialLocation: location,
      navigationBoundary: navigationBoundary,
      transferQueue: transferQueue,
      gitStatusPreferences: gitStatusPreferences,
      directoryCacheLimit: directoryCacheLimit,
      startsBrowsing: false,
      workspaceBookmarkAccessLease: workspaceBookmarkAccessLease)
    destination.setShowsHiddenFiles(showsHiddenFiles, reload: false)
    return destination
  }

  func makeFolderComparisonEngine(comparingWith other: FileBrowserSession) -> FolderComparisonEngine
  {
    FolderComparisonEngine(leftProvider: provider, rightProvider: other.provider)
  }

  /// 同期実行でも通常転送と同じセッション登録経路を通し、転送バーからの一時停止・
  /// キャンセル・再開を既存実装へそのまま委譲する。
  func makeFolderSyncExecutionEngine(
    comparingWith other: FileBrowserSession
  ) -> FolderSyncExecutionEngine {
    let left = self
    let right = other
    return FolderSyncExecutionEngine(
      leftProvider: provider,
      rightProvider: other.provider,
      transferQueue: transferQueue,
      transferEnqueuer: { operation, direction, destinationRoot in
        switch direction {
        case .leftToRight:
          left.enqueueFolderSyncTransfer(
            operation,
            to: right,
            destinationRoot: destinationRoot)
        case .rightToLeft:
          right.enqueueFolderSyncTransfer(
            operation,
            to: left,
            destinationRoot: destinationRoot)
        }
      })
  }

  private func enqueueFolderSyncTransfer(
    _ operation: FolderSyncOperation,
    to targetTemplate: FileBrowserSession,
    destinationRoot: FileLocation
  ) -> TransferJob? {
    guard let item = operation.sourceItem,
      let destinationLocation = FolderComparisonPath.parentDirectory(
        for: operation.relativePath,
        under: destinationRoot)
    else {
      return nil
    }
    let destination = targetTemplate.makePeerSession(at: destinationLocation)
    let job = startTransfer(
      [item],
      to: destination,
      removesSourceAfterCopy: false,
      onCompleted: {},
      replacingExisting: operation.action == .overwrite,
      refreshesBrowsersOnCompletion: false)
    // 同期専用のピアはジョブの場所を保持するためだけに必要で、一覧・監視は不要。
    // 転送中に退役させれば完了通知までは購読を維持し、完了後に確実に解放される。
    destination.retireFromBrowsing {}
    return job
  }

  func makeWorkspaceLocationState(
    bookmarkCodec: any FolderBookmarkCoding
  ) throws -> WorkspaceLocationState {
    if let placeholder = provider as? WorkspaceRemotePlaceholderProvider,
      let path = currentLocation.remotePath
    {
      return .remote(
        providerKind: placeholder.providerKind,
        connectionID: placeholder.restoredConnectionID,
        path: path)
    }
    if let sftpProvider = provider as? SFTPFileProvider,
      let connectionID = sftpProvider.connectionID,
      let path = currentLocation.remotePath
    {
      return .remote(
        providerKind: .sftp,
        connectionID: connectionID.rawValue,
        path: path)
    }
    if let ftpProvider = provider as? FTPFileProvider,
      let connectionID = ftpProvider.connectionID,
      let path = currentLocation.remotePath
    {
      return .remote(
        providerKind: .ftp,
        connectionID: connectionID.rawValue,
        path: path)
    }
    if let mountedProvider = provider as? MountedVolumeProvider,
      let path = mountedProvider.workspaceRelativePath(for: currentLocation)
    {
      return .remote(
        providerKind: .smb,
        connectionID: mountedProvider.workspaceConnectionID,
        path: path)
    }
    guard usesLocalFileProvider, let url = currentLocation.localURL else {
      throw CocoaError(.fileWriteUnsupportedScheme)
    }
    return .local(
      bookmarkData: try bookmarkCodec.createBookmark(for: url),
      lastKnownPath: url.path)
  }

  // MARK: - カラム表示

  /// 現在地を左端カラムとして開始する。祖先は自動構築せず、お気に入り・パンくず・
  /// 履歴からの移動もリスト表示と同じく移動先を表示起点にする。
  func beginColumnBrowsing() {
    guard !isRetiredFromBrowsing, !columnState.isActive else { return }
    if !isSearchActive,
      let savedState = columnStateBeforeSearch,
      columnLocationBeforeSearch == currentLocation
    {
      columnState = savedState
      columnStateBeforeSearch = nil
      columnLocationBeforeSearch = nil
      columnDisplayCache.removeAll()
      updateColumnWatchers()
      for column in savedState.columns where column.isLoading {
        loadColumn(at: column.location)
      }
      return
    }
    columnStateBeforeSearch = nil
    columnLocationBeforeSearch = nil
    columnState.begin(at: currentLocation, items: items)
    columnDisplayCache.removeAll()
  }

  /// カラム表示を終了する。currentLocationとitemsは右端カラムのままなので、リスト・
  /// アイコン表示へ戻っても最後に展開した場所をそのまま表示できる。
  func endColumnBrowsing() {
    cancelAllColumnLoads()
    columnState.reset()
    updateColumnWatchers()
    columnDisplayCache.removeAll()
    removeCloudStatusesOutsideDisplayedDirectories()
    guard !isRetiredFromBrowsing else { return }
    startWatchingCurrentLocationIfNeeded()
    enrichMissingMetadataIfNeeded(at: currentLocation)
  }

  /// カラム内の選択集合を階層状態へ反映する。単一フォルダなら列専用の非同期タスクで
  /// 右カラムを読み込み、それ以外は選択元カラムまで巻き戻す。
  func selectColumnItems(_ selectedURLs: Set<URL>, inColumnAt index: Int) {
    guard !isLoading, !isRefreshing else { return }
    var updatedColumnState = columnState
    guard let transition = updatedColumnState.select(selectedURLs, inColumnAt: index) else {
      return
    }
    if updatedColumnState != columnState {
      columnState = updatedColumnState
    }
    let destination = transition.destination
    cancelColumnLoadsOutsideDisplayedColumns()
    removeCloudStatusesOutsideDisplayedDirectories()

    guard let destinationColumn = columnState.columns.first(where: { $0.location == destination })
    else { return }
    if destinationColumn.isLoading,
      let snapshot = directoryCache[destination],
      snapshot.includesHiddenItems == showsHiddenFiles
    {
      synchronizeColumnItems(snapshot.items, at: destination)
      finishColumnLoading(at: destination)
      followColumnLocation(destination, items: snapshot.items)
      return
    }

    followColumnLocation(destination, items: destinationColumn.items)
    if destinationColumn.isLoading {
      loadColumn(at: destination)
    }
  }

  func selectColumnItem(_ item: FileItem, inColumnAt index: Int) {
    selectColumnItems([item.url], inColumnAt: index)
  }

  /// UIイベントはカラムの安定ID(FileLocation)で受け、処理時点のindexを引き直す。
  func selectColumnItem(_ item: FileItem, inColumnAt location: FileLocation) {
    selectColumnItems([item.url], inColumnAt: location)
  }

  func selectColumnItems(_ selectedURLs: Set<URL>, inColumnAt location: FileLocation) {
    guard let index = columnState.columns.firstIndex(where: { $0.location == location }) else {
      return
    }
    selectColumnItems(selectedURLs, inColumnAt: index)
  }

  func displayColumns(
    matching filterText: String,
    sortOrder: FileItemSortOrder,
    ascending: Bool,
    includesHiddenItems: Bool
  ) -> [FileBrowserColumn] {
    let query = ColumnDisplayQuery(
      filterText: filterText,
      sortOrder: sortOrder,
      ascending: ascending,
      includesHiddenItems: includesHiddenItems)
    let displayedLocations = Set(columnState.columns.map(\.location))
    columnDisplayCache = columnDisplayCache.filter { displayedLocations.contains($0.key) }
    return columnState.columns.map { column in
      let displayedItems: [FileItem]
      if let cached = columnDisplayCache[column.location],
        cached.itemsRevision == column.itemsRevision,
        cached.query == query
      {
        displayedItems = cached.items
      } else {
        columnItemsProjectionCount += column.items.count
        columnItemsProjectionCountByLocation[column.location, default: 0] += column.items.count
        displayedItems = FileBrowserColumnDisplay.items(
          from: column,
          matching: filterText,
          sortOrder: sortOrder,
          ascending: ascending,
          includesHiddenItems: includesHiddenItems)
        columnDisplayCache[column.location] = ColumnDisplayCacheEntry(
          itemsRevision: column.itemsRevision,
          query: query,
          items: displayedItems)
      }
      return FileBrowserColumn(
        location: column.location,
        items: displayedItems,
        itemsRevision: column.itemsRevision,
        selectedItemURLs: column.selectedItemURLs,
        isLoading: column.isLoading,
        widthOverride: column.widthOverride)
    }
  }

  func setColumnWidth(_ width: Double, at location: FileLocation, defaultWidth: Double) {
    var state = columnState
    state.setWidth(width, at: location, defaultWidth: defaultWidth)
    if state != columnState {
      columnState = state
    }
  }

  /// カラム内の追従では現在地と、その場所の通常操作用itemsだけを差し替える。
  /// 履歴更新・パンくず以外のナビゲーション副作用は起動しない。
  /// 監視は右端カラムの列挙が終わってから現在地へ張り直す。
  private func followColumnLocation(_ location: FileLocation, items columnItems: [FileItem]) {
    if currentLocation != location {
      revalidationTask?.cancel()
      revalidationTask = nil
      isRevalidatingInBackground = false
      cancelMetadataEnrichment()
      watcherArmTask?.cancel()
      watcherArmTask = nil
      directoryWatcher = nil
      watchedDirectoryPath = nil
      hasPendingWatcherEvent = false
      pendingArmCompletionCheckLocation = nil
      currentLocation = location
    }
    updateColumnWatchers()
    if items != columnItems {
      items = columnItems
    } else {
      synchronizeColumnItems(columnItems, at: location)
    }
    startGitStatusLoad(at: location, invalidatingCache: false)
    startCloudStatusLoad(at: location)
    // 右端カラムの初回列挙中はその場所の監視を待ち、列挙完了後に武装する。
    // キャッシュ命中時もfinishColumnLoading後にここへ来るため、同じ経路で武装する。
    if columnState.columns.first(where: { $0.location == location })?.isLoading == false {
      startWatchingCurrentLocationIfNeeded()
    }
  }

  /// 選択したフォルダの右カラムだけを列挙する。通常のload(location:)を経由しないため、
  /// 履歴・監視・一覧表示状態をクリックごとに作り直さない。
  private func loadColumn(at location: FileLocation) {
    guard columnLoadTasks[location] == nil else { return }
    let includingHidden = showsHiddenFiles
    let generation = (columnLoadGenerations[location] ?? 0) &+ 1
    columnLoadGenerations[location] = generation
    let task = Task { [weak self] in
      guard let self else { return }
      do {
        let directoryModifiedAt: Date?
        if let directoryURL = location.localURL {
          directoryModifiedAt = await ColumnDirectoryDateReader.shared.read(directoryURL)
        } else {
          directoryModifiedAt = nil
        }
        let loadedItems = try await self.loadItems(
          at: location,
          includingHidden: includingHidden,
          publishesPartialResults: false)
        try Task.checkCancellation()
        guard self.columnLoadGenerations[location] == generation,
          self.columnState.columns.contains(where: { $0.location == location })
        else { return }
        self.cacheDirectorySnapshot(
          DirectorySnapshot(
            items: loadedItems,
            includesHiddenItems: includingHidden,
            directoryModifiedAt: directoryModifiedAt), at: location)
        self.synchronizeColumnItems(loadedItems, at: location)
        self.finishColumnLoading(at: location)
        if self.currentLocation == location {
          self.followColumnLocation(location, items: loadedItems)
          self.enrichMissingMetadataIfNeeded(at: location)
          self.errorMessage = nil
        }
      } catch {
        guard !Task.isCancelled,
          self.columnLoadGenerations[location] == generation,
          self.columnState.columns.contains(where: { $0.location == location })
        else { return }
        self.finishColumnLoading(at: location)
        if self.currentLocation == location {
          self.presentError(error)
        }
      }
      if self.columnLoadGenerations[location] == generation {
        self.columnLoadTasks[location] = nil
      }
    }
    columnLoadTasks[location] = task
  }

  private func cancelColumnLoadsOutsideDisplayedColumns() {
    let displayedLocations = Set(columnState.columns.map(\.location))
    let obsoleteLocations = columnLoadTasks.keys.filter { !displayedLocations.contains($0) }
    for location in obsoleteLocations {
      columnLoadTasks[location]?.cancel()
      columnLoadTasks[location] = nil
      columnLoadGenerations[location] = (columnLoadGenerations[location] ?? 0) &+ 1
    }
  }

  private func cancelAllColumnLoads() {
    for task in columnLoadTasks.values { task.cancel() }
    columnLoadTasks.removeAll()
    columnLoadGenerations.removeAll()
  }

  /// 階層が変わったときだけ、現在地の監視とは別に表示中の祖先カラムを監視する。
  private func updateColumnWatchers() {
    let locations = Set(
      columnState.columns.map(\.location).filter { $0 != currentLocation && $0.localURL != nil })
    let trackedLocations = Set(columnDirectoryWatchers.keys)
      .union(columnWatcherArmTasks.keys)
      .union(columnRevalidationTasks.keys)
    for location in trackedLocations.subtracting(locations) {
      columnWatcherArmTasks.removeValue(forKey: location)?.cancel()
      columnDirectoryWatchers[location] = nil
      columnRevalidationTasks.removeValue(forKey: location)?.cancel()
    }
    for location in locations {
      startColumnWatcher(for: location)
    }
  }

  private func startColumnWatcher(for location: FileLocation) {
    guard let directoryURL = location.localURL,
      columnDirectoryWatchers[location] == nil, columnWatcherArmTasks[location] == nil
    else { return }
    columnWatcherArmTasks[location] = Task { [weak self] in
      guard !Task.isCancelled else { return }
      let watcher = await LocalDirectoryWatcher.opening(directoryURL: directoryURL) {
        [weak self] in
        self?.revalidateAncestorColumn(at: location)
      }
      guard let self, !Task.isCancelled else { return }
      defer {
        if !Task.isCancelled {
          self.columnWatcherArmTasks[location] = nil
        }
      }
      guard let watcher else { return }
      self.columnDirectoryWatchers[location] = watcher
      // 列挙から監視開始までの間に入った変更を、キャッシュのmtimeと照合して拾う。
      // mtimeを比べられないボリューム(APFS以外)ではクリックごとの再列挙を避けて照合しない。
      guard let cachedModifiedAt = self.directoryCache[location]?.directoryModifiedAt else {
        return
      }
      let modifiedAtAfterArm = await ColumnDirectoryDateReader.shared.read(directoryURL)
      guard !Task.isCancelled, let modifiedAtAfterArm, modifiedAtAfterArm != cachedModifiedAt
      else { return }
      self.revalidateAncestorColumn(at: location, preservesExistingMetadata: true)
    }
  }

  private func revalidateAncestorColumn(
    at location: FileLocation, preservesExistingMetadata: Bool = false
  ) {
    guard !isRetiredFromBrowsing, location != currentLocation, let directoryURL = location.localURL,
      let column = columnState.columns.first(where: { $0.location == location })
    else { return }
    columnRevalidationTasks[location]?.cancel()
    let includingHidden = showsHiddenFiles
    let itemsRevision = column.itemsRevision
    columnRevalidationTasks[location] = Task { [weak self] in
      guard let self, !Task.isCancelled else { return }
      defer {
        if !Task.isCancelled {
          self.columnRevalidationTasks[location] = nil
        }
      }
      do {
        let directoryModifiedAt = await ColumnDirectoryDateReader.shared.read(directoryURL)
        try Task.checkCancellation()
        let listedItems = try await self.loadItems(
          at: location, includingHidden: includingHidden, publishesPartialResults: false)
        try Task.checkCancellation()
        guard location != self.currentLocation,
          let column = self.columnState.columns.first(where: { $0.location == location })
        else { return }
        guard itemsRevision == column.itemsRevision, includingHidden == self.showsHiddenFiles else {
          self.revalidateAncestorColumn(
            at: location, preservesExistingMetadata: preservesExistingMetadata)
          return
        }
        let loadedItems =
          preservesExistingMetadata
          ? listedItems.fillingMissingMetadata(from: column.items) : listedItems
        self.cacheDirectorySnapshot(
          DirectorySnapshot(
            items: loadedItems,
            includesHiddenItems: includingHidden,
            directoryModifiedAt: directoryModifiedAt), at: location)
        self.synchronizeColumnItems(loadedItems, at: location)
      } catch {
        // 無音の再検証では既存のカラム表示を保つ。
      }
    }
  }

  private func synchronizeColumnItems(_ items: [FileItem], at location: FileLocation) {
    guard columnState.isActive else { return }
    var state = columnState
    state.setItems(items, at: location)
    if state != columnState {
      columnState = state
    }
  }

  private func finishColumnLoading(at location: FileLocation) {
    guard columnState.isActive else { return }
    var state = columnState
    state.finishLoading(at: location)
    if state != columnState {
      columnState = state
    }
  }

  /// カラム内の任意階層を転送先にした後、その階層の表示スナップショットだけを更新する。
  /// 現在地の通常一覧は転送完了処理のrefreshContents()が別途更新する。
  func refreshDisplayedColumn(at location: FileLocation, with items: [FileItem]) {
    synchronizeColumnItems(items, at: location)
    startGitStatusLoad(at: location, invalidatingCache: true)
  }

  func filteredItems(
    matching query: String,
    sortOrder: FileItemSortOrder = .name,
    ascending: Bool = true
  ) -> [FileItem] {
    FileItemFilter.filteredAndSorted(
      items,
      matching: query,
      matchMode: .literal,
      sortOrder: sortOrder,
      ascending: ascending)
  }

  private struct DisplayItemsQuery: Equatable {
    let filterText: String
    let sortOrder: FileItemSortOrder
    let ascending: Bool
    let includesHiddenItems: Bool
    let usesSearchResults: Bool
  }

  @ObservationIgnored private var itemsGeneration = 0
  @ObservationIgnored private var searchResultsGeneration = 0
  @ObservationIgnored private var selectableItemsColumnStateRevision = 0
  private struct SelectableItemsSnapshotKey: Equatable {
    let usesSearchResults: Bool
    let itemsGeneration: Int
    let treeStateRevision: Int
    let columnStateRevision: Int
    let searchResultsGeneration: Int
  }
  @ObservationIgnored private var selectableItemsSnapshotCache:
    (key: SelectableItemsSnapshotKey, snapshot: FileBrowserSelectableItemsSnapshot)?
  @ObservationIgnored private(set) var selectableItemsSnapshotBuildCount = 0
  @ObservationIgnored private var displayItemsCache:
    (generation: Int, query: DisplayItemsQuery, result: [FileItem])?
  @ObservationIgnored private(set) var displayItemsComputationCount = 0
  private struct FlattenedRowsCacheKey: Equatable {
    let displayItemsGeneration: Int
    let treeStateRevision: Int
    let usesSearchResults: Bool
    let sortOrder: FileItemSortOrder
    let ascending: Bool
  }
  @ObservationIgnored private var flattenedRowsCache:
    (key: FlattenedRowsCacheKey, rows: [FileTreeRow])?
  @ObservationIgnored private(set) var flattenedRowsComputationCount = 0
  /// displayItems(...)が実際に返す配列が変わりうるたびに増える軽量な世代値。
  /// FileListView側でO(n)深比較を避けるための識別に使う(呼び出し側供給の世代値)。
  @ObservationIgnored private(set) var displayItemsGeneration = 0
  /// treeState(展開状態・子項目キャッシュ)への変更のたびに増える軽量な世代値。
  /// treeRowsRevision(flattenedRowsの内容が変わりうるたびに変化する合成世代値)の
  /// 構成要素。mutateTreeState(_:)だけが更新する。
  @ObservationIgnored private(set) var treeStateRevision = 0
  /// テスト観測用: itemsが再代入された回数(内容が等しければ再代入されないため増えない)。
  @ObservationIgnored private(set) var itemsReplacementCount = 0
  /// itemsへの権威的な書き込み(load/refreshContents/perform系、無音再検証自身の適用も含む)
  /// が起きるたびに増える世代値。revalidateSilentlyは開始時に捕捉した値と比較し、
  /// 検証中に別の書き込みが割り込んでいたら自分の結果を古いものとして破棄する。
  @ObservationIgnored private var itemsAuthorityEpoch = 0
  /// テスト観測用: mtime一致時の無音バックグラウンド再検証が進行中かどうか。
  /// isLoading/isRefreshingはUIに更新中を示すため意図的に立てないので、テストの完了待ちに使う。
  @ObservationIgnored private(set) var isRevalidatingInBackground = false
  /// 直近のフォルダ表示操作(キャッシュ即応も含む)を識別するsignpost ID。
  /// FileListView側のセル構成・差分適用計装がこの操作へ相関できるよう、
  /// 呼び出し元(FileBrowserContent経由)へそのまま供給する。
  @ObservationIgnored private(set) var browseSignpostID: OSSignpostID?

  func displayItems(
    matching filterText: String,
    sortOrder: FileItemSortOrder,
    ascending: Bool,
    includesHiddenItems: Bool
  ) -> [FileItem] {
    // キャッシュヒット時も items を読み、Observationの依存集合に確実に含める。
    let browsingItems = items
    let usesSearchResults = isSearchActive
    if usesSearchResults {
      // 検索スナップショットの更新もObservationの依存集合に含める。
      _ = searchResults.count
    }
    let sourceGeneration = usesSearchResults ? searchResultsGeneration : itemsGeneration
    let query = DisplayItemsQuery(
      filterText: filterText,
      sortOrder: sortOrder,
      ascending: ascending,
      includesHiddenItems: includesHiddenItems,
      usesSearchResults: usesSearchResults)
    if let displayItemsCache,
      displayItemsCache.generation == sourceGeneration,
      displayItemsCache.query == query
    {
      return displayItemsCache.result
    }
    let result: [FileItem]
    if usesSearchResults {
      result = searchDisplayItems
    } else {
      var browsingResult = FileItemFilter.filteredAndSorted(
        browsingItems, matching: filterText, matchMode: .literal,
        sortOrder: sortOrder, ascending: ascending)
      if !includesHiddenItems {
        // SFTPなど列挙側で隠し項目を除外しないProviderのため、ビュー表示直前でも除外する。
        browsingResult = browsingResult.filter { !$0.name.hasPrefix(".") }
      }
      result = browsingResult
    }
    displayItemsComputationCount += 1
    displayItemsGeneration &+= 1
    displayItemsCache = (sourceGeneration, query, result)
    return result
  }

  // MARK: - リスト表示のフォルダその場展開(開閉三角)

  /// 選択(FileWorkspaceTab.selectedItemURLs)がFileLocationベースの集合と相互変換する際に
  /// 参照する候補項目の全体。ルート項目(items)に加え、展開有無を問わずtreeStateに
  /// キャッシュ済みの子項目もすべて含める。これがないと、フォルダその場展開で選択した
  /// 子項目のURLがitems(ルートのみ)の中に見つからず、選択が静かに空集合へ落ちてしまう
  /// (2026-08-16 発見: ←→キーでの親行選択・折りたたみ操作が効かなくなる退行の真因)。
  var selectableItems: [FileItem] {
    selectableItemsSnapshot.items
  }

  var selectableItemsSnapshot: FileBrowserSelectableItemsSnapshot {
    // キャッシュヒット時も元の表示状態を読み、Observationの依存集合を維持する。
    // これがないと、キャッシュ値だけを返したbody評価の後に一覧・ツリー・カラムが
    // 変化しても、選択やメニューを使うビューが再評価されない可能性がある。
    let browsingItems = items
    let browsingTreeState = treeState
    let browsingColumnState = columnState
    let usesSearchResults = isSearchActive
    if usesSearchResults {
      _ = searchResults.count
    }
    let key = SelectableItemsSnapshotKey(
      usesSearchResults: usesSearchResults,
      itemsGeneration: itemsGeneration,
      treeStateRevision: treeStateRevision,
      columnStateRevision: selectableItemsColumnStateRevision,
      searchResultsGeneration: searchResultsGeneration)
    if let selectableItemsSnapshotCache, selectableItemsSnapshotCache.key == key {
      return selectableItemsSnapshotCache.snapshot
    }

    let estimatedCount: Int
    if usesSearchResults {
      estimatedCount = searchDisplayItems.count
    } else {
      estimatedCount =
        browsingItems.count
        + browsingTreeState.childrenByLocation.values.reduce(0) { $0 + $1.count }
        + browsingColumnState.columns.reduce(0) { $0 + $1.items.count }
    }
    let canUseUniqueItemsDirectly =
      usesSearchResults
      || (browsingTreeState.childrenByLocation.isEmpty && browsingColumnState.columns.isEmpty)
    var snapshot: FileBrowserSelectableItemsSnapshot
    if canUseUniqueItemsDirectly {
      snapshot = FileBrowserSelectableItemsSnapshot(
        uniqueItems: usesSearchResults ? searchDisplayItems : browsingItems)
    } else {
      snapshot = FileBrowserSelectableItemsSnapshot(estimatedCount: estimatedCount)
    }
    if usesSearchResults {
      // uniqueItems初期化で追加済み。
    } else if !canUseUniqueItemsDirectly {
      snapshot.append(contentsOf: browsingItems)
      for children in browsingTreeState.childrenByLocation.values {
        snapshot.append(contentsOf: children)
      }
      for column in browsingColumnState.columns {
        snapshot.append(contentsOf: column.items)
      }
    }
    selectableItemsSnapshotBuildCount += 1
    selectableItemsSnapshotCache = (key, snapshot)
    return snapshot
  }

  /// リスト表示用: 表示条件でフィルタ・ソートしたルート項目に、展開状態を反映した
  /// 深さ付き行配列を組み立てて返す。純関数のFileTreeFlattening.flattenへ委譲する薄い配線
  /// (doc/plans/2026-08-16-list-tree-expansion.md 設計方針: 展開状態を反映したフラット化
  /// 済み行配列をActivatingTableViewへ流す)。
  func flattenedRows(
    matching filterText: String,
    sortOrder: FileItemSortOrder,
    ascending: Bool,
    includesHiddenItems: Bool
  ) -> [FileTreeRow] {
    let rootItems = displayItems(
      matching: filterText, sortOrder: sortOrder, ascending: ascending,
      includesHiddenItems: includesHiddenItems)
    // キャッシュヒット時もtreeStateを読み、展開状態に対するObservation依存を維持する。
    let browsingTreeState = treeState
    let usesSearchResults = isSearchActive
    let key = FlattenedRowsCacheKey(
      displayItemsGeneration: displayItemsGeneration,
      treeStateRevision: treeStateRevision,
      usesSearchResults: usesSearchResults,
      sortOrder: sortOrder,
      ascending: ascending)
    if let flattenedRowsCache, flattenedRowsCache.key == key {
      return flattenedRowsCache.rows
    }

    flattenedRowsComputationCount += 1
    let rows: [FileTreeRow]
    if usesSearchResults {
      rows = rootItems.map {
        FileTreeRow(item: $0, depth: 0, isExpanded: false, isLoadingChildren: false)
      }
    } else {
      rows = FileTreeFlattening.flatten(
        rootItems: rootItems, treeState: browsingTreeState, sortOrder: sortOrder,
        ascending: ascending)
    }
    flattenedRowsCache = (key, rows)
    return rows
  }

  /// flattenedRows(...)が返す内容が変わりうるたびに変化する軽量な世代値。displayItems
  /// Generation(ルート項目の変化)とtreeStateRevision(展開状態・子ロード完了・スピナー
  /// 表示切替等)を合成する。FileListView.itemsRevisionへそのまま渡し、O(n)深比較を
  /// 避けるために使う。treeStateは通常のObservation対象プロパティのため呼び出し元の
  /// SwiftUI再描画自体はこの値を読まなくても正しく起きるが、更新後のupdateNSViewが
  /// 「内容は変わっていない」と誤判定してAppKit側へ反映しない事故を防ぐため必須。
  var treeRowsRevision: Int {
    displayItemsGeneration &* 1_000_003 &+ treeStateRevision &+ searchResultsGeneration
  }

  /// treeStateへのすべての変更(展開・折りたたみ・子ロード結果の反映等)が経由する唯一の
  /// 入口。呼び出しのたびにtreeStateRevisionを進めることで、上記treeRowsRevisionが
  /// 変化を確実に検知できるようにする(個々の変更箇所でrevisionを手動管理して漏らす
  /// リスクを避けるための一元化)。
  @discardableResult
  private func mutateTreeState<T>(_ body: (inout FileTreeState) -> T) -> T {
    var state = treeState
    let result = body(&state)
    treeState = state
    treeStateRevision &+= 1
    return result
  }

  /// 開閉三角のクリック・←→キーからの展開/折りたたみ要求。recursivelyはOption同時押し
  /// (配下全展開/全折りたたみ、Finder同等)。
  func toggleExpansion(of item: FileItem, recursively: Bool = false) {
    guard item.isDirectory else { return }
    if treeState.isExpanded(item.location) {
      if recursively {
        collapseRecursively(item)
      } else {
        collapse(item)
      }
    } else {
      if recursively {
        expandRecursively(item)
      } else {
        expand(item)
      }
    }
  }

  private func expand(_ item: FileItem) {
    let location = item.location
    guard let generation = mutateTreeState({ $0.expand(location) }) else { return }
    startExpandedWatcher(for: location)
    loadChildren(at: location, generation: generation)
  }

  /// 折りたたみ。子孫の展開状態・キャッシュは保持する(再展開時に復元、計画どおり)。
  /// 監視だけは配下の展開済みフォルダも含めて止める(見えなくなった間の無駄な再検証を防ぐ)。
  private func collapse(_ item: FileItem) {
    let location = item.location
    mutateTreeState { $0.collapse(location) }
    stopWatchersInSubtree(location)
    removeCloudStatusesOutsideDisplayedDirectories()
  }

  /// Option+クリック相当: 配下のフォルダをすべて非同期に展開する。未ロードの子は
  /// Provider列挙を待ってから、その子directoryをさらに展開する形で深さ優先に進む。
  private func expandRecursively(_ item: FileItem) {
    Task { [weak self] in
      await self?.expandRecursivelyAwaiting(item.location)
    }
  }

  private func expandRecursivelyAwaiting(_ location: FileLocation) async {
    guard let children = await loadChildrenAwaiting(location) else { return }
    for child in children where child.isDirectory {
      await expandRecursivelyAwaiting(child.location)
    }
  }

  /// locationを展開し、子項目が届くまで待って返す(既にキャッシュ済みならそのまま返す)。
  /// expandRecursively専用の内部ヘルパー。
  private func loadChildrenAwaiting(_ location: FileLocation) async -> [FileItem]? {
    if let generation = mutateTreeState({ $0.expand(location) }) {
      startExpandedWatcher(for: location)
      return await performChildLoad(at: location, generation: generation)
    }
    return treeState.children(of: location)
  }

  /// Option+クリック相当: 配下のフォルダをすべて折りたたむ(通常の折りたたみと異なり、
  /// 子孫の展開状態も含めて完全に「忘れる」。Finderの配下全折りたたみと同等)。
  private func collapseRecursively(_ item: FileItem) {
    collapseSubtreeRecursively(item.location)
  }

  private func collapseSubtreeRecursively(_ location: FileLocation) {
    if let children = treeState.children(of: location) {
      for child in children where child.isDirectory {
        collapseSubtreeRecursively(child.location)
      }
    }
    mutateTreeState { $0.collapse(location) }
    stopExpandedWatcher(for: location)
    removeCloudStatusesOutsideDisplayedDirectories()
  }

  private func stopWatchersInSubtree(_ location: FileLocation) {
    stopExpandedWatcher(for: location)
    guard let children = treeState.children(of: location) else { return }
    for child in children where child.isDirectory {
      stopWatchersInSubtree(child.location)
    }
  }

  private func loadChildren(
    at location: FileLocation,
    generation: Int,
    invalidatesGitStatusCache: Bool = false,
    preservesExistingMetadata: Bool = false
  ) {
    childLoadTasks[location]?.cancel()
    let task = Task { [weak self] in
      guard let self else { return }
      _ = await self.performChildLoad(
        at: location,
        generation: generation,
        invalidatesGitStatusCache: invalidatesGitStatusCache,
        preservesExistingMetadata: preservesExistingMetadata)
    }
    childLoadTasks[location] = task
  }

  /// 既存Provider列挙経路(FileBrowserProvider.contents(of:includingHidden:))で子項目を
  /// 取得し、世代が一致すればtreeStateへ反映する。反映できた場合だけメタデータ補完
  /// (NASのサイズ後追い補完と同じ経路)も試みる。
  @discardableResult
  private func performChildLoad(
    at location: FileLocation,
    generation: Int,
    invalidatesGitStatusCache: Bool = false,
    preservesExistingMetadata: Bool = false
  ) async -> [FileItem]? {
    startGitStatusLoad(at: location, invalidatingCache: invalidatesGitStatusCache)
    do {
      let listedItems = try await provider.contents(of: location, includingHidden: showsHiddenFiles)
      let childItems =
        if preservesExistingMetadata, let previousChildren = treeState.children(of: location) {
          listedItems.fillingMissingMetadata(from: previousChildren)
        } else {
          listedItems
        }
      let accepted = mutateTreeState {
        $0.setChildren(
          childItems, for: location, generation: generation,
          skipsUnchangedItems: preservesExistingMetadata)
      }
      guard accepted else { return nil }
      startCloudStatusLoad(at: location, invalidatingCache: invalidatesGitStatusCache)
      enrichMissingChildMetadataIfNeeded(at: location, items: childItems, generation: generation)
      return childItems
    } catch {
      mutateTreeState { $0.failedLoad(for: location, generation: generation) }
      return nil
    }
  }

  /// ルート項目のenrichMissingMetadataIfNeeded(:)と同じ考え方を、展開済みフォルダの
  /// 子項目にも適用する(NASのサイズ後追い補完を展開子項目にも適用、設計方針どおり)。
  private func enrichMissingChildMetadataIfNeeded(
    at location: FileLocation, items childItems: [FileItem], generation: Int
  ) {
    let detailProvider = provider as? any FileBrowserItemDetailProvider
    let tagMetadataProvider = provider as? any FileBrowserFinderTagMetadataProvider
    let loadsFinderTags = capabilities.contains(.finderTags) && tagMetadataProvider != nil
    let fullDetailItems =
      detailProvider.map { _ in
        childItems.filter(Self.needsFullMetadataEnrichment)
      } ?? []
    let fullDetailLocations = Set(fullDetailItems.map(\.location))
    let tagOnlyItems =
      loadsFinderTags
      ? Array(
        childItems.lazy.filter {
          $0.tags == nil
            && !fullDetailLocations.contains($0.location)
            && !self.finderTagEnrichmentLocationsInFlight.contains($0.location)
        }.prefix(Self.initialFinderTagEnrichmentLimit))
      : []
    guard !fullDetailItems.isEmpty || !tagOnlyItems.isEmpty else { return }
    let tagOnlyLocations = Set(tagOnlyItems.map(\.location))
    finderTagEnrichmentLocationsInFlight.formUnion(tagOnlyLocations)
    Task { [weak self] in
      guard let self else { return }
      defer {
        self.finderTagEnrichmentLocationsInFlight.subtract(tagOnlyLocations)
        for location in tagOnlyLocations {
          self.pendingVisibleFinderTagItems[location] = nil
        }
        if !self.pendingVisibleFinderTagItems.isEmpty {
          self.enrichMissingMetadataIfNeeded(
            at: self.currentLocation,
            includesInitialFinderTagBatch: false)
        }
      }
      let detailedItems: [FileLocation: FileItem]
      if let detailProvider {
        detailedItems = await Self.loadDetailedItems(
          for: fullDetailItems, from: detailProvider,
          maximumConcurrency: Self.metadataEnrichmentMaximumConcurrency)
      } else {
        detailedItems = [:]
      }
      let tagNamesByLocation: [FileLocation: [String]]
      if let tagMetadataProvider {
        tagNamesByLocation = await Self.loadFinderTagNames(
          for: tagOnlyItems, from: tagMetadataProvider,
          maximumConcurrency: Self.metadataEnrichmentMaximumConcurrency)
      } else {
        tagNamesByLocation = [:]
      }
      guard !Task.isCancelled, !detailedItems.isEmpty || !tagNamesByLocation.isEmpty,
        let currentChildren = self.treeState.children(of: location)
      else { return }
      let enrichedItems = currentChildren.map { item in
        if let detailedItem = detailedItems[item.location] {
          return detailedItem
        }
        if let tagNames = tagNamesByLocation[item.location] {
          return item.replacingTags(tagNames)
        }
        return item
      }
      guard enrichedItems != currentChildren else { return }
      // setChildrenが内部で世代の一致を再確認するため、折りたたみ→再展開で世代が
      // 進んでいた場合は自動的に古い結果として破棄される。
      self.mutateTreeState {
        $0.setChildren(enrichedItems, for: location, generation: generation)
      }
    }
  }

  /// refresh()から呼ぶ: 現在展開中の各フォルダの子を再ロードする(外部変更を明示的な
  /// 更新操作でも取りこぼさないようにする)。
  private func reloadExpandedChildren() {
    for location in treeState.expandedLocations {
      let generation = mutateTreeState { $0.beginLoad(location) }
      loadChildren(
        at: location,
        generation: generation,
        invalidatesGitStatusCache: true)
    }
  }

  /// フォルダ行への転送完了後、そのフォルダが展開中なら子一覧を再取得する。ローカルは
  /// ディレクトリ監視でも更新されるが、監視を持たないNAS/SFTPでも即時反映させるための経路。
  func refreshExpandedChildren(at location: FileLocation, preservesExistingMetadata: Bool = false) {
    guard treeState.isExpanded(location) else { return }
    let generation = mutateTreeState { $0.beginLoad(location) }
    loadChildren(
      at: location,
      generation: generation,
      invalidatesGitStatusCache: true,
      preservesExistingMetadata: preservesExistingMetadata)
  }

  /// 展開中フォルダのローカル監視を開始する(currentLocation自体の監視と同じ
  /// LocalDirectoryWatcher.opening(directoryURL:onChange:)を使う、リモートはlocalURLが
  /// nilのため何もしない=対象外)。
  private func startExpandedWatcher(for location: FileLocation) {
    guard let directoryURL = location.localURL else { return }
    guard expandedDirectoryWatchers[location] == nil, expandedWatcherArmTasks[location] == nil
    else { return }
    let armTask = Task { [weak self] in
      guard let self else { return }
      let watcher = await LocalDirectoryWatcher.opening(directoryURL: directoryURL) {
        [weak self] in
        self?.handleExpandedWatcherEvent(for: location)
      }
      self.expandedWatcherArmTasks[location] = nil
      guard !Task.isCancelled, self.treeState.isExpanded(location), let watcher else { return }
      self.expandedDirectoryWatchers[location] = watcher
    }
    expandedWatcherArmTasks[location] = armTask
  }

  private func stopExpandedWatcher(for location: FileLocation) {
    expandedWatcherArmTasks[location]?.cancel()
    expandedWatcherArmTasks[location] = nil
    expandedDirectoryWatchers[location] = nil
  }

  private func handleExpandedWatcherEvent(for location: FileLocation) {
    guard treeState.isExpanded(location) else { return }
    let generation = mutateTreeState { $0.beginLoad(location) }
    loadChildren(
      at: location,
      generation: generation,
      invalidatesGitStatusCache: true)
  }

  /// フォルダ移動・隠しファイル表示切替・invalidate()時に呼び、展開状態・子ロード・
  /// 監視をすべて破棄する(展開はセッション内のみ・currentLocation単位の仕様)。
  private func resetTreeState() {
    for task in childLoadTasks.values { task.cancel() }
    childLoadTasks.removeAll()
    for task in expandedWatcherArmTasks.values { task.cancel() }
    expandedWatcherArmTasks.removeAll()
    expandedDirectoryWatchers.removeAll()
    mutateTreeState { $0.reset() }
    removeCloudStatusesOutsideDisplayedDirectories()
  }

  private var parentLocation: FileLocation? {
    guard let parent = provider.parent(of: currentLocation), parent != navigationBoundary else {
      return nil
    }
    return parent
  }

  private func navigate(
    to destination: FileLocation,
    preloadedItems: [FileItem]? = nil,
    includesHiddenItems: Bool? = nil,
    recordsHistory: Bool = true
  ) {
    guard destination != currentLocation || isRecentFilesActive else { return }
    if recordsHistory {
      history.append(currentNavigationEntry)
      forwardHistory.removeAll()
    }
    load(
      location: destination,
      preservingColumnState: false,
      preloadedItems: preloadedItems,
      includesHiddenItems: includesHiddenItems,
      invalidatesGitStatusCache: false)
  }

  private func startArchiveOperation<Result: Sendable>(
    _ operation: @escaping @MainActor () async throws -> Result,
    onSuccess: @escaping @MainActor (Result) async throws -> Void
  ) {
    isArchiving = true
    archiveProgress = nil
    archiveTask = Task { [weak self] in
      guard let self else { return }
      do {
        let resultURL = try await operation()
        try Task.checkCancellation()
        try await onSuccess(resultURL)
        errorMessage = nil
      } catch is CancellationError {
        errorMessage = "アーカイブ処理をキャンセルしました。"
      } catch {
        presentError(error)
      }
      isArchiving = false
      archiveProgress = nil
      archiveTask = nil
      purgeRetiredBrowsingSnapshot()
      notifyRetiredLifecycleDidBecomeIdle()
    }
  }

  /// 作成先が現在表示中の一覧・展開ツリー・カラムに含まれる場合だけ、その場所を再列挙して
  /// ZIPの選択・スクロール要求を発行する。Provider呼び出しはasyncで行いMainActor上の同期
  /// ファイルシステム走査を持ち込まない。
  private func refreshAndRevealCreatedArchive(
    named archiveName: String,
    at archiveURL: URL?,
    in directoryLocation: FileLocation
  ) async throws {
    guard isDisplayedArchiveDirectory(directoryLocation) else { return }
    let loadedItems = try await provider.contents(
      of: directoryLocation, includingHidden: showsHiddenFiles)
    try Task.checkCancellation()
    // ZIP作成中にナビゲーションや折りたたみが行われた場合は、現在の表示状態へ
    // 古い列挙結果や選択要求を混入させない。
    let isCurrentDirectory = currentLocation == directoryLocation
    let isExpandedDirectory = treeState.isExpanded(directoryLocation)
    let columnIndex = columnState.columns.firstIndex {
      $0.location == directoryLocation
    }
    guard isCurrentDirectory || isExpandedDirectory || columnIndex != nil else { return }

    cacheDirectorySnapshot(
      DirectorySnapshot(
        items: loadedItems,
        includesHiddenItems: showsHiddenFiles,
        directoryModifiedAt: Self.directoryModifiedAt(of: directoryLocation)), at: directoryLocation
    )
    if isCurrentDirectory {
      items = loadedItems
      enrichMissingMetadataIfNeeded(at: directoryLocation)
    }
    if isExpandedDirectory {
      mutateTreeState { state in
        let generation = state.beginLoad(directoryLocation)
        state.setChildren(loadedItems, for: directoryLocation, generation: generation)
      }
    }
    synchronizeColumnItems(loadedItems, at: directoryLocation)
    startGitStatusLoad(at: directoryLocation, invalidatingCache: true)
    startCloudStatusLoad(at: directoryLocation, invalidatingCache: true)

    guard
      let archiveItem = archiveURL.flatMap({ createdURL in
        loadedItems.first(where: { $0.url == createdURL })
      }) ?? loadedItems.first(where: { $0.name == archiveName })
    else { return }
    if let columnIndex {
      var state = columnState
      _ = state.select(archiveItem, inColumnAt: columnIndex)
      columnState = state
      followColumnLocation(directoryLocation, items: loadedItems)
    }
    revealGeneration &+= 1
    revealRequest = FileItemRevealRequest(
      generation: revealGeneration,
      itemURL: archiveItem.url,
      directoryLocation: directoryLocation)
  }

  /// ZIP保存先が現在表示している場所なら、表示モデルが保持するFileLocationをそのまま返す。
  /// 完了後のURL表記に依存せず、ツリー・カラムの辞書キーと同じ安定IDで再列挙できる。
  private func displayedArchiveDirectoryLocation(for directoryURL: URL) -> FileLocation? {
    let destination = FileLocation(localURL: directoryURL, providerID: provider.id)
    var candidates = [currentLocation]
    candidates.append(contentsOf: columnState.columns.map(\.location))
    candidates.append(contentsOf: treeState.expandedLocations)

    if let exactMatch = candidates.first(where: { $0 == destination }) {
      return exactMatch
    }
    return candidates.first(where: { $0.representsSameDirectory(as: destination) })
  }

  private func isDisplayedArchiveDirectory(_ location: FileLocation) -> Bool {
    currentLocation == location
      || treeState.isExpanded(location)
      || columnState.columns.contains(where: { $0.location == location })
  }

  private func archiveName(for archiveItems: [FileItem], format: ArchiveFormat) -> String {
    let baseName =
      archiveItems.count == 1 ? archiveItems.first?.name ?? "Archive" : "Archive"
    return "\(baseName).\(format.fileExtension)"
  }

  private func archiveDirectoryLocation(for archiveItems: [FileItem]) -> FileLocation? {
    guard !archiveItems.isEmpty,
      capabilities.contains(.write),
      archiveItems.allSatisfy({ $0.location.providerID == provider.id })
    else { return nil }
    if let directoryURL = archiveDirectoryURL(for: archiveItems) {
      return displayedArchiveDirectoryLocation(for: directoryURL)
        ?? FileLocation(localURL: directoryURL, providerID: provider.id)
    }
    guard RemoteArchiveService.supports(provider) else { return nil }
    let parentLocations = archiveItems.compactMap { provider.parent(of: $0.location) }
    guard parentLocations.count == archiveItems.count,
      let firstParent = parentLocations.first
    else { return nil }
    var candidates: [FileLocation] = []
    var candidate: FileLocation? = firstParent
    while let location = candidate {
      candidates.append(location)
      candidate = provider.parent(of: location)
    }
    return candidates.first { candidate in
      parentLocations.allSatisfy { location in
        var ancestor: FileLocation? = location
        while let current = ancestor {
          if current == candidate { return true }
          ancestor = provider.parent(of: current)
        }
        return false
      }
    }
  }

  private func archiveDirectoryURL(for archiveItems: [FileItem]) -> URL? {
    let sourceURLs = archiveItems.compactMap(\.location.localURL)
    guard sourceURLs.count == archiveItems.count else { return nil }
    return ArchiveDestinationDirectory.deepestCommonAncestor(
      of: sourceURLs.map { $0.deletingLastPathComponent() })
  }

  private static func archiveProgressHandler(
    for session: FileBrowserSession
  ) -> ArchiveService.ProgressHandler {
    { [weak session] progress in
      Task { @MainActor in
        session?.archiveProgress = progress
      }
    }
  }

  private func perform(
    removingSearchResults removedItems: [FileItem] = [],
    reloadingAt location: FileLocation? = nil,
    onSuccess: (@MainActor (FileBrowserSession) -> Void)? = nil,
    _ operation: @escaping @MainActor (any FileBrowserOperationProvider) async throws -> Void
  ) {
    guard !isLoading else { return }
    guard let operations = provider as? any FileBrowserOperationProvider else {
      errorMessage = "この接続ではファイル操作を利用できません。"
      return
    }
    isPerformingFileOperation = true
    isLoading = true
    Task { [weak self] in
      guard let self else { return }
      // refreshContents()と同じ理由で、operation(operations)のawait中にユーザーがload()で
      // 別フォルダへ移動しうる。currentLocationをawait後に読み直すと移動後のロケーションへ
      // 旧フォルダの列挙結果を書き込んでしまうため、冒頭で捕捉したdestinationだけを使い、
      // 権威的な書き込みの直前でcurrentLocationとの一致を確認する。
      let destination = location ?? currentLocation
      var didSucceed = false
      do {
        try await operation(operations)
        removeSearchResults(at: Set(removedItems.map(\.location)))
        // mtimeは操作(operation)後・列挙(contents)前に取得する。操作前に取ると
        // 操作自身がmtimeを進めてしまいスナップショットが再利用不能になる。
        let directoryModifiedAt = Self.directoryModifiedAt(of: destination)
        let loadedItems = try await provider.contents(
          of: destination,
          includingHidden: showsHiddenFiles)
        if currentLocation == destination {
          cacheDirectorySnapshot(
            DirectorySnapshot(
              items: loadedItems,
              includesHiddenItems: showsHiddenFiles,
              directoryModifiedAt: directoryModifiedAt), at: destination)
          items = loadedItems
        }
        errorMessage = nil
        didSucceed = true
      } catch {
        presentError(error)
      }
      // currentLocationがdestinationから動いていたら、isLoadingは既に別ロケーションの
      // load()側の完了処理が下ろしている(load()はisLoadingを見ずに進行するため)。
      // ここで無条件に下ろすと、そのload()完了後に新しく始まった操作のisLoading=trueを
      // 誤って踏み消してしまう。
      isPerformingFileOperation = false
      if currentLocation == destination {
        isLoading = false
        consumePendingWatcherEventIfNeeded()
        if didSucceed {
          onSuccess?(self)
        }
      }
      purgeRetiredBrowsingSnapshot()
      notifyRetiredLifecycleDidBecomeIdle()
    }
  }

  /// isLoadingを下ろした直後にhasPendingWatcherEventを拾い直す。perform()/delete()/
  /// discardTransferredItems()はいずれもisLoading=trueで包んでrefreshContents()や
  /// 自前の列挙を呼ぶため、その最中に見送られた監視イベントの消費はrefreshContents()の
  /// defer(まだisLoading=trueのため空振りしてhasPendingWatcherEventを再セットするだけで
  /// 終わる)に任せられない。isLoadingを下ろした後にここで改めて拾い直す必要がある。
  private func consumePendingWatcherEventIfNeeded() {
    guard hasPendingWatcherEvent else { return }
    hasPendingWatcherEvent = false
    handleWatcherEvent(for: currentLocation)
  }

  private func transfer(
    _ items: [FileItem],
    to destination: FileBrowserSession,
    removesSourceAfterCopy: Bool,
    onCompleted: @escaping @MainActor () -> Void,
    destinationNames: [FileLocation: String] = [:],
    dropPreparationTrace: DropPreparationTrace? = nil
  ) {
    guard !items.isEmpty else {
      dropPreparationTrace?.finish(.rejected)
      return
    }
    guard
      !currentLocation.representsSameDirectory(as: destination.currentLocation)
    else {
      errorMessage = "同じフォルダへは転送できません。"
      dropPreparationTrace?.finish(.rejected)
      return
    }
    guard pendingTransfer == nil else {
      errorMessage = String(localized: "先に同名項目の転送方法を選択してください。")
      return
    }
    let inventory = Self.transferConflictInventory(
      in: items, destinationItems: destination.items, destinationNames: destinationNames)
    let destinationItemsByName = inventory.destinationItemsByName
    let conflicts = inventory.conflicts
    let itemOptions = Dictionary(
      uniqueKeysWithValues: items.map {
        (
          $0.location,
          TransferItemOptions(
            destinationName: destinationNames[$0.location],
            requiredDestinationName: destinationNames[$0.location])
        )
      })
    if !conflicts.isEmpty {
      dropPreparationTrace?.recordCollisionCheck(
        sourceItemCount: items.count,
        destinationItemCount: destination.items.count,
        nameLookupCount: inventory.nameLookupCount,
        hasConflict: true)
      pendingTransfer = PendingTransfer(
        items: items,
        destination: destination,
        removesSourceAfterCopy: removesSourceAfterCopy,
        onCompleted: onCompleted,
        refreshesBrowsersOnCompletion: true,
        replacingExisting: false)
      transferConflictState = ConflictResolutionState(
        remainingItems: conflicts, destinationItemsByName: destinationItemsByName,
        totalCount: conflicts.count,
        occupiedNames: Set(destination.items.map(\.name)).union(items.map(\.name)),
        itemOptions: itemOptions)
      updatePendingTransferConflict()
      return
    }
    dropPreparationTrace?.recordCollisionCheck(
      sourceItemCount: items.count,
      destinationItemCount: destination.items.count,
      nameLookupCount: inventory.nameLookupCount,
      hasConflict: false)
    startTransfer(
      items,
      to: destination,
      removesSourceAfterCopy: removesSourceAfterCopy,
      onCompleted: onCompleted,
      itemOptions: itemOptions,
      dropPreparationTrace: dropPreparationTrace)
  }

  /// 本番の全衝突探索と同じ関数を使い、照合回数の性能契約を維持する。
  nonisolated static func firstTransferConflict(
    in sourceItems: [FileItem],
    destinationItems: [FileItem]
  ) -> (item: FileItem?, nameLookupCount: Int) {
    let inventory = transferConflictInventory(in: sourceItems, destinationItems: destinationItems)
    return (inventory.conflicts.first, inventory.nameLookupCount)
  }

  nonisolated private static func transferConflictInventory(
    in sourceItems: [FileItem], destinationItems: [FileItem],
    destinationNames: [FileLocation: String] = [:]
  ) -> (conflicts: [FileItem], destinationItemsByName: [String: FileItem], nameLookupCount: Int) {
    let destinationItemsByName = Dictionary(
      destinationItems.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    let conflicts = sourceItems.filter {
      destinationItemsByName[destinationNames[$0.location] ?? $0.name] != nil
    }
    return (conflicts, destinationItemsByName, destinationItems.count + sourceItems.count)
  }

  @discardableResult
  private func startTransfer(
    _ items: [FileItem],
    to destination: FileBrowserSession,
    removesSourceAfterCopy: Bool,
    onCompleted: @escaping @MainActor () -> Void,
    replacingExisting: Bool = false,
    refreshesBrowsersOnCompletion: Bool = true,
    itemOptions: [FileLocation: TransferItemOptions] = [:],
    skippedItemCount: Int = 0,
    dropPreparationTrace: DropPreparationTrace? = nil
  ) -> TransferJob {
    let pending = PendingTransfer(
      items: items,
      destination: destination,
      removesSourceAfterCopy: removesSourceAfterCopy,
      onCompleted: onCompleted,
      refreshesBrowsersOnCompletion: refreshesBrowsersOnCompletion,
      replacingExisting: replacingExisting,
      itemOptions: itemOptions,
      skippedItemCount: skippedItemCount)
    let sourceProvider = provider
    let destinationProvider = destination.provider
    let destinationLocation = destination.currentLocation
    var job = TransferJob(
      kind: removesSourceAfterCopy ? .move : .copy,
      items: items,
      sourceProviderID: sourceProvider.id,
      destinationProviderID: destinationProvider.id,
      destination: destinationLocation)
    job.sourceAccessBookmarkData = recentTransferSourceBookmarkData
    job.items = items.map {
      TransferJob.Item(
        $0,
        options: itemOptions[$0.location]
          ?? TransferItemOptions(replacingExisting: replacingExisting))
    }
    job.skippedItemCount = skippedItemCount
    let reservedJobID = job.id
    beginTransfer(pending, jobID: job.id)
    dropPreparationTrace?.recordQueueRegistration()
    // 自動再接続(P1-3)は初回の転送(startTransfer)から効く必要がある。手動retryLastTransfer
    // と同じmakeAutoRetryPlannerを登録し、TransferQueueが失敗を検知したら自動的に
    // バックオフ・再試行してくれるようにする。
    let autoRetryPlanner = makeAutoRetryPlanner(pending: pending, jobID: job.id)
    Task { [weak self, transferQueue] in
      let sizeAggregation = Task {
        await Self.transferSizes(
          of: items, using: sourceProvider,
          moveDestination: removesSourceAfterCopy ? destinationLocation : nil,
          itemOptions: itemOptions)
      }
      let execution = Self.makeQueuedTransferExecution(
        items: items,
        sourceProvider: sourceProvider,
        destinationProvider: destinationProvider,
        destinationLocation: destinationLocation,
        removesSourceAfterCopy: removesSourceAfterCopy,
        replacingExisting: replacingExisting,
        itemOptions: itemOptions,
        sizeAggregation: sizeAggregation,
        destinationReserved: { location, options in
          guard let name = options.destinationName else { throw FTPFileProviderError.invalidName }
          try await transferQueue.recordReservedDestinationName(
            name, for: location, jobID: reservedJobID)
        })
      _ = await transferQueue.enqueue(
        job, execution: execution, autoRetryPlanner: autoRetryPlanner)
      await transferQueue.applyAggregatedTotalBytes(
        job.id, totalBytes: sizeAggregation.value.total)
      guard let self else { return }
      self.receiveTransferUpdates(await transferQueue.allJobs())
    }
    return job
  }

  private func beginTransfer(_ transfer: PendingTransfer, jobID: UUID) {
    startObservingTransferUpdatesIfNeeded()
    activeTransfers[jobID] = transfer
    // 開始時に観測した状態の案内であり、現在OS取得を待っているという断定ではない。
    if transfer.items.contains(where: { cloudDownloadStatuses[$0.url]?.indicatorLabel != nil }) {
      cloudTransferJobIDs.insert(jobID)
    }
    registerActiveTransfer(jobID)
    if transfer.destination !== self {
      transfer.destination.registerActiveTransfer(jobID)
    }
  }

  private func registerActiveTransfer(_ jobID: UUID) {
    activeTransferJobIDs.insert(jobID)
    executingTransferJobIDs.insert(jobID)
    isTransferring = !executingTransferJobIDs.isEmpty
    updateCloudTransferPreparationNotice()
  }

  private func updateCloudTransferPreparationNotice() {
    cloudTransferPreparationNotice =
      !cloudTransferJobIDs.isDisjoint(with: executingTransferJobIDs)
      ? CloudDownloadStatus.transferPreparationGuidance : nil
  }

  private func finishActiveTransfer(_ jobID: UUID) {
    cloudTransferJobIDs.remove(jobID)
    activeTransferJobIDs.remove(jobID)
    executingTransferJobIDs.remove(jobID)
    resumingTransferJobIDs.remove(jobID)
    pausedTransfers[jobID] = nil
    isTransferring = !executingTransferJobIDs.isEmpty
    updateCloudTransferPreparationNotice()
    if isRetiredFromBrowsing, !isTransferring {
      stopObservingTransferUpdates()
    }
  }

  /// itemsそれぞれの転送バイト数を求める。ファイルはsize、フォルダは
  /// providerで再帰的に列挙して子の合計を求める(転送実行と同じ深さを走査する)。
  /// rename型の移動はサイズ目的の再帰列挙を省略する。コピーの事前集計は維持する。
  /// 集計不能・rename項目が1つでもあれば全体をnilにフォールバックする。
  nonisolated private static func transferSizes(
    of items: [FileItem], using provider: any FileBrowserProvider,
    moveDestination: FileLocation? = nil, itemOptions: [FileLocation: TransferItemOptions] = [:]
  ) async -> (total: Int64?, perItem: [Int64?]) {
    var perItem: [Int64?] = []
    var total: Int64 = 0
    var totalKnown = true
    for item in items {
      let size: Int64?
      if item.isDirectory, let destination = moveDestination,
        LocalSameVolumeTransfer.canMove(item, toDirectory: destination)
          || (destination.providerID == provider.id && destination.remotePath != nil
            && item.location.remotePath != nil
            && (provider is FTPFileProvider || provider is SFTPFileProvider)
            && (itemOptions[item.location]?.destinationName ?? item.name) == item.name)
      {
        // renameは内容をコピーしない。未知Providerやremote別名保持のcopy経路は省略しない。
        size = nil
      } else {
        size = await itemTransferSize(of: item, using: provider)
      }
      perItem.append(size)
      if let size {
        total += size
      } else {
        totalKnown = false
      }
    }
    return (totalKnown ? total : nil, perItem)
  }

  nonisolated private static func itemTransferSize(
    of item: FileItem, using provider: any FileBrowserProvider
  ) async -> Int64? {
    guard item.isDirectory else { return item.size }
    guard let children = try? await provider.contents(of: item.location) else { return nil }
    var total: Int64 = 0
    for child in children {
      guard let childSize = await itemTransferSize(of: child, using: provider) else { return nil }
      total += childSize
    }
    return total
  }

  /// 検証失敗した転送先ファイルをbest-effort削除するため、FileLocationから
  /// removeAfterCrossProviderMove呼び出し用の最小限のFileItemを組み立てる。
  /// TransferJob.Item.fileItemと同じ変換方針(local/remoteでの分岐)を踏襲する。
  nonisolated private static func makeFileItem(
    at location: FileLocation, name: String, isDirectory: Bool = false
  ) -> FileItem {
    switch location.path {
    case .local(let url):
      FileItem(url: url, providerID: location.providerID, isDirectory: isDirectory)
    case .remote(let path):
      FileItem(
        remotePath: path,
        url: URL(fileURLWithPath: "/\(name)"),
        providerID: location.providerID,
        isDirectory: isDirectory)
    }
  }

  /// 別名公開は転送元名を偽装せず、一時フォルダ内でコピーを完成してから確定する。
  /// 同一Providerの通常コピーを使うことでリンクと属性の既存契約も保持する。
  nonisolated private static func copyToDifferentName(
    item: FileItem, destinationName: String,
    from source: any FileBrowserProvider,
    to directory: FileLocation,
    using target: any FileBrowserProvider,
    replacingExisting: Bool,
    destinationNameWasReserved: Bool,
    requiredDestinationName: String?,
    destinationReserved: @escaping @Sendable (String) async throws -> Void,
    progress: @escaping @Sendable (FileTransferProgress) -> Void
  ) async throws {
    guard let operations = target as? any FileBrowserOperationProvider,
      let cleanup = target as? any FileBrowserTransferProvider,
      let commit = target as? any FileTransferCommitProvider,
      let finalLocation = directory.appending(pathComponent: destinationName)
    else { throw FileBrowserSessionError.transferUnavailable }
    if !replacingExisting, let ftp = target as? FTPFileProvider {
      if destinationNameWasReserved,
        try await ftp.contents(of: directory).contains(where: { $0.name == destinationName })
      {
        throw FTPKeepBothRetryError.existingReservation(destinationName)
      }
      _ = try await ftp.copyKeepingBoth(
        item: item, from: source, to: directory, destinationName: destinationName,
        requiredDestinationName: requiredDestinationName,
        reserved: { actual in
          guard let name = actual.remotePath?.split(separator: "/").last.map(String.init) else {
            throw FTPFileProviderError.invalidName
          }
          try await destinationReserved(name)
        }, progress: progress)
      return
    }
    let temporaryName = ".pkpane-keep-both-\(UUID().uuidString)"
    guard let temporaryDirectory = directory.appending(pathComponent: temporaryName),
      let stagedItem = temporaryDirectory.appending(pathComponent: item.name)
    else { throw FileBrowserSessionError.transferUnavailable }
    try Task.checkCancellation()
    try await operations.createDirectory(named: temporaryName, in: directory)
    let temporaryItem = makeFileItem(
      at: temporaryDirectory, name: temporaryName, isDirectory: true)
    do {
      if source.id == target.id, let transfer = source as? any FileBrowserTransferProvider {
        if let transfer = source as? any FileBrowserProgressTransferProvider {
          try await transfer.copy(item, to: temporaryDirectory, replacingExisting: false) { bytes in
            progress(FileTransferProgress(completedBytes: bytes, totalBytes: item.size))
          }
        } else {
          try await transfer.copy(item, to: temporaryDirectory, replacingExisting: false)
        }
        if !item.isDirectory {
          try await TransferSizeVerifier.verify(
            itemName: item.name, expectedBytes: item.size, isSymbolicLink: item.isSymbolicLink,
            at: stagedItem, using: target)
        }
      } else {
        try await ProviderFileTransferService().copyTree(
          item: item, from: source, toDirectory: temporaryDirectory, using: target,
          progress: progress)
      }
      try Task.checkCancellation()
      try await commit.commitTransferFile(
        from: stagedItem, to: finalLocation, replacingExisting: replacingExisting)
      try? await Task.detached { try await cleanup.removeAfterCrossProviderMove(temporaryItem) }
        .value
    } catch {
      try? await Task.detached { try await cleanup.removeAfterCrossProviderMove(temporaryItem) }
        .value
      throw error
    }
  }

  nonisolated private static func makeQueuedTransferExecution(
    items: [FileItem],
    sourceProvider: any FileBrowserProvider,
    destinationProvider: any FileBrowserProvider,
    destinationLocation: FileLocation,
    removesSourceAfterCopy: Bool,
    replacingExisting: Bool,
    itemOptions: [FileLocation: TransferItemOptions] = [:],
    sizeAggregation: Task<(total: Int64?, perItem: [Int64?]), Never>,
    completedBytesBaseline: Int64 = 0,
    destinationReserved: TransferDestinationReservationReporter? = nil
  ) -> TransferQueue.Execution {
    { report, itemCompleted in
      let (remainingTotal, itemSizes) = await sizeAggregation.value
      let totalBytes = remainingTotal.map { $0 + completedBytesBaseline }
      let execution = makeTransferExecution(
        items: items,
        itemSizes: itemSizes,
        totalBytes: totalBytes,
        sourceProvider: sourceProvider,
        destinationProvider: destinationProvider,
        destinationLocation: destinationLocation,
        removesSourceAfterCopy: removesSourceAfterCopy,
        replacingExisting: replacingExisting,
        itemOptions: itemOptions,
        completedBytesBaseline: completedBytesBaseline,
        destinationReserved: destinationReserved)
      try await execution(report, itemCompleted)
    }
  }

  /// scheduleProgressReport: fire-and-forgetな進捗報告Taskの生成方法。既定は実際に
  /// Task{}で発火する本番動作。テストではこれを差し替え、報告の発火タイミングを
  /// 手動制御することでstale報告の破棄を決定的に検証できるようにする。
  nonisolated static func makeTransferExecution(
    items: [FileItem],
    itemSizes: [Int64?],
    totalBytes: Int64?,
    sourceProvider: any FileBrowserProvider,
    destinationProvider: any FileBrowserProvider,
    destinationLocation: FileLocation,
    removesSourceAfterCopy: Bool,
    replacingExisting: Bool,
    itemOptions: [FileLocation: TransferItemOptions] = [:],
    completedBytesBaseline: Int64 = 0,
    mergingExistingDirectoryTrees: Bool = false,
    destinationReserved: TransferDestinationReservationReporter? = nil,
    scheduleProgressReport: @escaping @Sendable (@escaping @Sendable () async -> Void) -> Void = {
      work in Task { await work() }
    }
  ) -> TransferQueue.Execution {
    { report, itemCompleted in
      var completedBytes: Int64 = completedBytesBaseline
      var failedItems: [TransferJob.Item] = []
      var failureDescriptions: [String] = []
      var recoveryDescriptions: [String] = []
      // 自動再接続(P1-3)対象外の判定。失敗項目のうち1つでも再接続では直らない種類の
      // エラーであれば、ジョブ全体を自動リトライ対象から外す(下のTransferJobPartialFailure
      // 参照)。
      var encounteredReconnectFutileError = false
      // レジューム(P1-2)でスキップした項目分の下駄。ループが1件も回らなくても
      // (全項目スキップ済みの再試行)ジョブへ確実に反映されるよう先に報告する。
      if completedBytesBaseline > 0 {
        await report(
          FileTransferProgress(completedBytes: completedBytesBaseline, totalBytes: totalBytes))
      }
      let progressThrottle = Mutex<ContinuousClock.Instant?>(nil)
      // ループが現在処理中のアイテム番号。fire-and-forgetで発火した進捗報告が実際に
      // 実行される時点でこの値と一致しない場合、そのアイテムの処理(成功/失敗)が
      // 既に確定した後に届いたstaleな報告とみなして破棄する。失敗確定後に古い報告が
      // 届いて次アイテムの進捗が一時的に凍結する不具合の対策。
      let currentItemIndex = Mutex<Int>(0)
      @Sendable
      func reportThrottled(
        _ progress: FileTransferProgress,
        itemIndex: Int,
        report: @escaping @Sendable (FileTransferProgress) async -> Void
      ) {
        let now = ContinuousClock().now
        let shouldReport = progressThrottle.withLock { last -> Bool in
          if let previous = last, now - previous < .milliseconds(150) {
            return false
          }
          last = now
          return true
        }
        guard shouldReport else { return }
        scheduleProgressReport {
          guard currentItemIndex.withLock({ $0 }) == itemIndex else { return }
          await report(progress)
        }
      }
      for (index, item) in items.enumerated() {
        if Task.isCancelled, !recoveryDescriptions.isEmpty {
          throw TransferRecoveryError(
            underlyingDescription: String(localized: "転送をキャンセルしました。"),
            recoveryDescription: recoveryDescriptions.joined(separator: "\n"))
        }
        try Task.checkCancellation()
        currentItemIndex.withLock { $0 = index }
        let options = itemOptions[item.location]
        let replacesItem = options?.replacingExisting ?? replacingExisting
        let destinationName = options?.destinationName ?? item.name
        let actualOptions = Mutex(options ?? TransferItemOptions(replacingExisting: replacesItem))
        // copyTreeを通るクロスProviderコピーは、検証済みリーフをcopyTree側で記録する。
        // 同一ボリューム高速moveなどcopyTreeを通らない経路は、この後のセッション側で
        // 記録する。移動の最上位ファイルだけは、移動元削除成功後まで記録を遅らせる。
        var copiedThroughTree = false
        // 現在のアイテムに入るまでに完了した分の累積(itemBaseline)を、アイテム内進捗へ
        // 加算して報告する。アイテム内進捗だけを報告すると、2件目以降がジョブ全体の
        // 既報告値(TransferQueue.recordの単調増加ガード)より小さくなり無視され続ける。
        let itemBaseline = completedBytes
        do {
          if removesSourceAfterCopy,
            LocalSameVolumeTransfer.canMove(item, toDirectory: destinationLocation)
          {
            try LocalSameVolumeTransfer.move(
              item, toDirectory: destinationLocation, replacingExisting: replacesItem,
              destinationName: destinationName)
          } else if destinationName != item.name {
            try await copyToDifferentName(
              item: item, destinationName: destinationName,
              from: sourceProvider, to: destinationLocation, using: destinationProvider,
              replacingExisting: replacesItem,
              destinationNameWasReserved: options?.destinationNameWasReserved ?? false,
              requiredDestinationName: options?.requiredDestinationName,
              destinationReserved: { name in
                let updated = actualOptions.withLock { value in
                  value.destinationName = name
                  value.destinationNameWasReserved = true
                  value.replacingExisting = false
                  return value
                }
                try await destinationReserved?(item.location, updated)
              },
              progress: { progress in
                reportThrottled(
                  FileTransferProgress(
                    completedBytes: itemBaseline + progress.completedBytes,
                    totalBytes: totalBytes),
                  itemIndex: index, report: report)
              })
            if removesSourceAfterCopy {
              guard let transferProvider = sourceProvider as? any FileBrowserTransferProvider else {
                throw FileBrowserSessionError.crossProviderMoveUnavailable
              }
              try await transferProvider.removeAfterCrossProviderMove(item)
            }
          } else if sourceProvider.id == destinationProvider.id {
            guard let transferProvider = sourceProvider as? any FileBrowserTransferProvider else {
              throw FileBrowserSessionError.transferUnavailable
            }
            if removesSourceAfterCopy {
              try await transferProvider.move(
                item,
                to: destinationLocation,
                replacingExisting: replacesItem)
            } else {
              if let progressTransferProvider =
                sourceProvider as? any FileBrowserProgressTransferProvider
              {
                try await progressTransferProvider.copy(
                  item,
                  to: destinationLocation,
                  replacingExisting: replacesItem
                ) {
                  completedBytes in
                  reportThrottled(
                    FileTransferProgress(
                      completedBytes: itemBaseline + completedBytes,
                      totalBytes: totalBytes),
                    itemIndex: index,
                    report: report)
                }
              } else {
                try await transferProvider.copy(
                  item,
                  to: destinationLocation,
                  replacingExisting: replacesItem)
              }
              // ここではcopyのみ検証する。moveはSFTP等ではサーバー側rename相当で
              // データが複製されず検証の意味がない一方、LocalFileProviderの異ボリューム
              // move(コピー+削除で代替する経路)は実際にデータを複製するが、元を削除する
              // 前にLocalFileProvider.move内で検証済み(このセッション層で二重に検証しない)。
              // ディレクトリはProvider内部が丸ごと再帰処理するため、ファイル単位の
              // 期待サイズと比較できずここでは対象外(既知のスコープ外、cross-provider側の
              // copyTreeはリーフファイル単位でProviderFileTransferService.copy内が検証する)。
              if !item.isDirectory,
                let destinationItemLocation = destinationLocation.appending(
                  pathComponent: item.name)
              {
                do {
                  try await TransferSizeVerifier.verify(
                    itemName: item.name,
                    expectedBytes: itemSizes[index],
                    isSymbolicLink: item.isSymbolicLink,
                    at: destinationItemLocation,
                    using: destinationProvider)
                } catch {
                  // このcopy経路には一時名ステージングが無く、copyの時点で転送先パスへ
                  // 直接書き込まれている。検証失敗を転送先に破損ファイルとして残すと、
                  // 次回retryLastTransferがreplacingExisting: falseで必ず「既に存在する」
                  // 失敗になり再試行不能になるため、ベストエフォートで除去してから
                  // 元の検証エラーを報告する(除去自体の失敗は握りつぶす)。
                  try? await transferProvider.removeAfterCrossProviderMove(
                    Self.makeFileItem(at: destinationItemLocation, name: item.name))
                  throw error
                }
              }
            }
          } else {
            copiedThroughTree = true
            try await ProviderFileTransferService().copyTree(
              item: item,
              from: sourceProvider,
              toDirectory: destinationLocation,
              using: destinationProvider,
              replacingExisting: replacesItem,
              mergingExistingDirectory: mergingExistingDirectoryTrees && item.isDirectory,
              progress: { progress in
                reportThrottled(
                  FileTransferProgress(
                    completedBytes: itemBaseline + progress.completedBytes,
                    totalBytes: totalBytes),
                  itemIndex: index,
                  report: report)
              },
              itemCompleted: itemCompleted,
              reportRootItemCompletion: !removesSourceAfterCopy)
            if removesSourceAfterCopy {
              guard let transferProvider = sourceProvider as? any FileBrowserTransferProvider else {
                throw FileBrowserSessionError.crossProviderMoveUnavailable
              }
              try await transferProvider.removeAfterCrossProviderMove(item)
            }
          }
          completedBytes += itemSizes[index] ?? 0
          await report(
            FileTransferProgress(completedBytes: completedBytes, totalBytes: totalBytes))
          // レジューム(P1-2)用の完了記録。copyTreeを通らないファイルはここで、クロスProviderの
          // copyTreeリーフはProviderFileTransferService.copyTree内で検証直後に記録する。移動の
          // 最上位ファイルは移動元削除成功後のこの位置で記録する。ディレクトリ・
          // シンボリックリンクは対象外(P1-1のTransferSizeVerifierと同じ理由でファイル単位の
          // 期待サイズ比較が成立せず、再検証の安全性を担保できないため常に再転送させる)。
          // 新FTP予約転送だけは、完成rootの実名を履歴へ残す。directory/linkを無検証で
          // 再開スキップする条件は広げず、未完成の予約もここには到達しない。
          let recordsAtSessionLayer = !copiedThroughTree || removesSourceAfterCopy
          if recordsAtSessionLayer,
            (!item.isDirectory && !item.isSymbolicLink && itemSizes[index] != nil)
              || actualOptions.withLock({ $0.destinationNameWasReserved })
          {
            await itemCompleted(
              TransferJob.Item(
                item, options: actualOptions.withLock { $0 }))
          }
        } catch is CancellationError {
          if !recoveryDescriptions.isEmpty {
            throw TransferRecoveryError(
              underlyingDescription: String(localized: "転送をキャンセルしました。"),
              recoveryDescription: recoveryDescriptions.joined(separator: "\n"))
          }
          throw CancellationError()
        } catch {
          failedItems.append(
            TransferJob.Item(
              item, options: actualOptions.withLock { $0 }))
          failureDescriptions.append(PKPaneErrorClassifier.classify(error).displayMessage)
          if let recovery = (error as? TransferRecoveryDescribing)?.recoveryDescription {
            recoveryDescriptions.append(recovery)
          }
          if !TransferReconnectionPolicy.isEligibleForAutoReconnect(error) {
            encounteredReconnectFutileError = true
          }
        }
      }
      if !failedItems.isEmpty {
        throw TransferJobPartialFailure(
          failedItems: failedItems,
          underlyingErrorDescription: failureDescriptions.joined(separator: "\n"),
          isReconnectFutile: encounteredReconnectFutileError,
          recoveryDescription: recoveryDescriptions.isEmpty
            ? nil : recoveryDescriptions.joined(separator: "\n"))
      }
    }
  }

  /// 実行中集合の再計算。ローカルでは登録済み(current∩active)だがキュー一覧にまだ
  /// 現れないジョブはenqueue前の窓とみなして保持する。startTransferの同期登録から
  /// 非同期enqueue完了までの間に無関係ジョブの更新が届くと、ここで自ジョブが消えて
  /// isTransferringが偽りのfalseへ落ちるレースがあった。
  nonisolated static func recomputedExecutingTransferJobIDs(
    current: Set<UUID>,
    active: Set<UUID>,
    jobs: [TransferJob]
  ) -> Set<UUID> {
    let executing = Set(
      jobs.lazy.filter {
        active.contains($0.id) && ($0.state == .queued || $0.state == .running)
      }.map(\.id))
    let knownIDs = Set(jobs.lazy.map(\.id))
    let awaitingEnqueue = current.intersection(active).subtracting(knownIDs)
    return executing.union(awaitingEnqueue)
  }

  private func receiveTransferUpdates(_ jobs: [TransferJob]) {
    executingTransferJobIDs = Self.recomputedExecutingTransferJobIDs(
      current: executingTransferJobIDs,
      active: activeTransferJobIDs,
      jobs: jobs)
    isTransferring = !executingTransferJobIDs.isEmpty
    updateCloudTransferPreparationNotice()
    let hasTerminalActiveTransfer = jobs.contains {
      self.activeTransferJobIDs.contains($0.id) && $0.state.isTerminal
    }

    for job in jobs where job.state.isTerminal && activeTransferJobIDs.contains(job.id) {
      finishActiveTransfer(job.id)
      guard var activeTransfer = activeTransfers.removeValue(forKey: job.id) else { continue }
      for item in job.completedItems + job.items {
        activeTransfer.itemOptions[item.location] = item.transferOptions
      }
      if activeTransfer.destination !== self {
        activeTransfer.destination.finishActiveTransfer(job.id)
      }

      // 自動再接続(P1-3、Fix A)の成否に関わらず、ジョブがここに到達した時点で
      // このセッションが把握すべき自動リトライの試行回数管理は終わっている
      // (TransferQueue側がバックオフ中もstateを.runningのまま維持するため、
      // 自動リトライが続いている間はそもそもこのfor文の条件(state.isTerminal)を
      // 満たさずここへ来ない)。
      autoReconnectAttempts[job.id] = nil

      switch job.state {
      case .completed:
        let destination = activeTransfer.destination
        Task { [weak self, weak destination] in
          guard let self, let destination else { return }
          if activeTransfer.removesSourceAfterCopy {
            self.removeSearchResults(at: Set(activeTransfer.items.map(\.location)))
          }
          do {
            if activeTransfer.refreshesBrowsersOnCompletion {
              try await self.refreshContentsIfBrowsing()
              try await destination.refreshContentsIfBrowsing()
            }
            self.errorMessage = nil
            destination.errorMessage = nil
            self.lastCompletedTransfer = CompletedTransfer(
              items: activeTransfer.items, destination: job.destination,
              itemOptions: activeTransfer.itemOptions,
              replacedExisting: activeTransfer.replacingExisting
                || activeTransfer.itemOptions.values.contains(where: \.replacingExisting))
            activeTransfer.onCompleted()
          } catch {
            self.presentError(error)
            destination.presentError(error)
          }
          self.purgeRetiredBrowsingSnapshot()
          destination.purgeRetiredBrowsingSnapshot()
          self.notifyRetiredLifecycleDidBecomeIdle()
          destination.notifyRetiredLifecycleDidBecomeIdle()
        }
      case .failed, .cancelled, .interrupted:
        presentFailedTransfer(job: job, activeTransfer: activeTransfer)
      case .queued, .running, .paused:
        // このswitchは上のstate.isTerminal条件により到達しない。Stateの網羅性維持用。
        break
      }
    }
    if !isTransferring, !hasTerminalActiveTransfer {
      if isRetiredFromBrowsing {
        stopObservingTransferUpdates()
      }
      notifyRetiredLifecycleDidBecomeIdle()
    }
  }

  /// 転送の失敗・キャンセルは一覧エラー(errorMessage)ではなく転送バー
  /// (TransferActivityBar)がTransferJobの状態から直接表示するため、ここでは
  /// errorMessageへ書き込まない。ただし一覧(items)は部分的に転送済みの可能性が
  /// あるため、両ペインとも再列挙だけは行う(失敗してもエラー表示はしない)。
  private func presentFailedTransfer(job: TransferJob, activeTransfer: PendingTransfer) {
    let destination = activeTransfer.destination
    failedTransfer = PendingTransfer(
      items: job.items.map(\.fileItem),
      destination: activeTransfer.destination,
      removesSourceAfterCopy: activeTransfer.removesSourceAfterCopy,
      onCompleted: activeTransfer.onCompleted,
      // 同期全体の実行中はジョブ単位更新を抑止するが、結果確定後にユーザーが転送バーから
      // 手動再試行する場合は同期エンジンの一括更新がもう走らないため、通常どおり更新する。
      refreshesBrowsersOnCompletion: true,
      replacingExisting: activeTransfer.replacingExisting,
      itemOptions: activeTransfer.itemOptions,
      skippedItemCount: activeTransfer.skippedItemCount)
    failedTransferJobID = job.id
    Task { [weak self, weak destination] in
      guard let self, let destination else { return }
      if activeTransfer.refreshesBrowsersOnCompletion {
        try? await self.refreshContentsIfBrowsing()
        try? await destination.refreshContentsIfBrowsing()
      }
      self.purgeRetiredBrowsingSnapshot()
      destination.purgeRetiredBrowsingSnapshot()
      self.notifyRetiredLifecycleDidBecomeIdle()
      destination.notifyRetiredLifecycleDidBecomeIdle()
    }
  }

  /// 自動再接続(P1-3)の次の試行番号(1始まり)を返す。autoReconnectBackoff.count回を
  /// 使い切っていたらnil(=呼び出し元は自動リトライを諦め、TransferQueueがfailedへ
  /// 確定して既存の手動リトライUIへフォールバックする)。
  private func nextAutoReconnectAttempt(for jobID: UUID) -> Int? {
    let attempted = autoReconnectAttempts[jobID] ?? 0
    guard attempted < autoReconnectBackoff.count else { return nil }
    let next = attempted + 1
    autoReconnectAttempts[jobID] = next
    return next
  }

  private func refreshContentsIfBrowsing() async throws {
    guard !isRetiredFromBrowsing else { return }
    try await refreshContents()
  }

  private func refreshContents() async throws {
    // delete/discardTransferredItems/転送完了・失敗/ZIP処理完了のいずれの呼び出し元も、
    // このawait中にユーザーがload()で別フォルダへ移動しうる。currentLocationをawait後に
    // 読み直すと、移動後のロケーションへ旧フォルダの列挙結果を書き込んでしまう
    // (リモートでは自己修復しない)。冒頭で捕捉したdestinationだけを使い、権威的な
    // 書き込みの直前でcurrentLocationとの一致を確認して、不一致ならすべて捨てる。
    let destination = currentLocation
    isRefreshing = true
    startGitStatusLoad(at: destination, invalidatingCache: true)
    cancelMetadataEnrichment()
    // mtimeは列挙開始前に取得する(load()と同じ安全順序)。列挙中に変更が
    // 起きた場合は保存されるmtimeが古い値になり、次回必ず再検証される。
    let directoryModifiedAt = Self.directoryModifiedAt(of: destination)
    defer {
      // currentLocationがdestinationから動いていたら、この呼び出しはもう権威を
      // 持たない。isRefreshingの書き戻しも監視イベントの拾い直しも、別ロケーションの
      // load()/refreshContents()側の責任に委ねる。
      if currentLocation == destination {
        // 再列挙中は完成済み一覧を保ち、監視イベントを保留する。throwを含む
        // どの経路でも完了時に必ず解除する。戻し忘れると監視イベントのゲートが常にpending側へ
        // 倒れ、以後の自動反映が死ぬ(delete/discardTransferredItems/転送完了・失敗/
        // ZIP処理完了のすべての呼び出し元がここを通る)。
        isRefreshing = false
        // 削除・転送・ZIP処理などの実行中に落ちてきた外部変更の取りこぼし防止。
        if hasPendingWatcherEvent {
          hasPendingWatcherEvent = false
          handleWatcherEvent(for: destination)
        }
      }
    }
    // 同じ場所の更新では完成済み一覧を保持する。途中バッチへの置換で文書高が
    // 縮むと、リスト・アイコン・カラムのスクロール位置が先頭側へ制限される。
    let loadedItems = try await loadItems(
      at: destination,
      includingHidden: showsHiddenFiles,
      publishesPartialResults: false)
    guard currentLocation == destination else { return }
    cacheDirectorySnapshot(
      DirectorySnapshot(
        items: loadedItems,
        includesHiddenItems: showsHiddenFiles,
        directoryModifiedAt: directoryModifiedAt), at: destination)
    // itemsAuthorityEpochの更新はitemsのdidSetに一元化されているため、内容が等しくても
    // 必ず代入する(items != loadedItemsの条件分岐にしてはならない)。
    items = loadedItems
    enrichMissingMetadataIfNeeded(at: destination)
  }

  private func loadItems(
    at location: FileLocation,
    includingHidden: Bool,
    publishesPartialResults: Bool,
    browseSignpostID: OSSignpostID? = nil,
    providerKind: InteractionPerformanceProviderKind = .unknown
  ) async throws -> [FileItem] {
    guard let streamingProvider = provider as? any FileBrowserStreamingProvider else {
      let loadedItems = try await provider.contents(of: location, includingHidden: includingHidden)
      if let browseSignpostID {
        BrowsePerformanceSignpost.event(
          .firstBatchReceived,
          signpostID: browseSignpostID,
          providerKind: providerKind,
          itemCount: loadedItems.count)
      }
      return loadedItems
    }
    var sortedItems = [FileItem]()
    var didEmitFirstBatch = false
    for try await batch in streamingProvider.contentsStream(
      of: location,
      includingHidden: includingHidden,
      batchSize: 4_096)
    {
      try Task.checkCancellation()
      if !didEmitFirstBatch, let browseSignpostID {
        didEmitFirstBatch = true
        BrowsePerformanceSignpost.event(
          .firstBatchReceived,
          signpostID: browseSignpostID,
          providerKind: providerKind,
          itemCount: batch.count)
      }
      sortedItems = await Task.detached(priority: .userInitiated) { [sortedItems] in
        Self.mergingSorted(sortedItems, with: batch)
      }.value
      try Task.checkCancellation()
      // Task.cancel()はフラグを立てるだけで即座に中断させない。load()のloadTask?.cancel()
      // 直後もこのループの残り1回分は既に開始済みで走りきりうるため、直上の
      // checkCancellation()だけでは足りない。currentLocationがlocationから動いていたら
      // (=すでに別フォルダへ移動済み)、その1回分の逐次公開は捨てて書き込まない。
      // 捨てないとB表示中にAの内容が混入し、かつisRefreshing=trueのまま誰も戻さず
      // 監視イベントのゲートが恒久的に閉じたままになる。
      if publishesPartialResults, currentLocation == location {
        // itemsAuthorityEpochの更新はitemsのdidSetに一元化されているため、内容が
        // 等しくても必ず代入する(items != sortedItemsの条件分岐にしてはならない)。
        items = sortedItems
        isLoading = false
        isRefreshing = true
      }
    }
    if !didEmitFirstBatch, let browseSignpostID {
      BrowsePerformanceSignpost.event(
        .firstBatchReceived,
        signpostID: browseSignpostID,
        providerKind: providerKind)
    }
    return sortedItems
  }

  nonisolated static func mergingSorted(
    _ sortedItems: [FileItem],
    with batch: [FileItem]
  ) -> [FileItem] {
    func precedes(_ lhs: FileItem, _ rhs: FileItem) -> Bool {
      lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
    guard !batch.isEmpty else { return sortedItems }
    let sortedBatch = batch.sorted(by: precedes)
    guard !sortedItems.isEmpty else { return sortedBatch }
    var merged = [FileItem]()
    merged.reserveCapacity(sortedItems.count + sortedBatch.count)
    var leftIndex = 0
    var rightIndex = 0
    while leftIndex < sortedItems.count, rightIndex < sortedBatch.count {
      if precedes(sortedBatch[rightIndex], sortedItems[leftIndex]) {
        merged.append(sortedBatch[rightIndex])
        rightIndex += 1
      } else {
        merged.append(sortedItems[leftIndex])
        leftIndex += 1
      }
    }
    merged.append(contentsOf: sortedItems[leftIndex...])
    merged.append(contentsOf: sortedBatch[rightIndex...])
    return merged
  }

  private func removeExistingItem(named name: String) async throws {
    guard let existingItem = items.first(where: { $0.name == name }) else { return }
    guard let operations = provider as? any FileBrowserOperationProvider else {
      throw FileBrowserSessionError.transferUnavailable
    }
    if capabilities.contains(.trash) {
      try await operations.delete(existingItem)
      return
    }
    try await removePermanently(existingItem, using: operations)
  }

  private func removePermanently(
    _ item: FileItem,
    using operations: any FileBrowserOperationProvider
  ) async throws {
    if item.isDirectory {
      let children = try await provider.contents(
        of: item.location,
        includingHidden: showsHiddenFiles)
      for child in children {
        try Task.checkCancellation()
        try await removePermanently(child, using: operations)
      }
    }
    try await operations.delete(item)
  }

}

enum FileBrowserSessionError: LocalizedError {
  case transferUnavailable
  case namedTransferUnavailable
  case transferResumeUnavailable
  case crossProviderMoveUnavailable
  case permanentDeleteUnavailable
  case duplicateUnavailable
  case permissionsUnavailable
  case finderTagsUnavailable
  case finderTagReadUnavailable
  case renameUnavailable

  var errorDescription: String? {
    switch self {
    case .transferUnavailable:
      "この接続では項目を移動できません。"
    case .namedTransferUnavailable:
      String(localized: "この接続では既存項目を安全に保持した別名転送を利用できません。")
    case .transferResumeUnavailable:
      "転送元と転送先のペインを元の場所に合わせてから再開してください。"
    case .crossProviderMoveUnavailable:
      "この接続では、転送後に元の項目を削除できません。"
    case .permanentDeleteUnavailable:
      "この接続では完全削除を利用できません。"
    case .duplicateUnavailable:
      "この接続では複製を利用できません。"
    case .permissionsUnavailable:
      "この接続ではアクセス権を変更できません。"
    case .finderTagReadUnavailable:
      String(localized: "タグを読み込めませんでした。")
    case .finderTagsUnavailable:
      "この接続ではFinderタグを変更できません。"
    case .renameUnavailable:
      String(localized: "この接続では名前を変更できません。")
    }
  }
}
