import Foundation
import Synchronization
import Testing

@testable import PKPane

@MainActor
struct FileBrowserCloudStatusTests {
  @Test("一般クラウドの不明・取得中・失敗・回復は公開更新で観測値だけを反映する")
  func refreshesUnknownDownloadingFailureAndRecovery() async {
    let fixture = makeFixture(
      directory: FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/CloudStorage/Fixture"))
    let observed = Mutex(CloudDownloadStatus.unknown)
    let provider = CloudStatusSessionProvider(
      id: fixture.location.providerID, itemsByLocation: [fixture.location: [fixture.item]],
      statusLoader: { _ in [fixture.item.url: observed.withLock { $0 }] })
    let session = FileBrowserSession(
      provider: provider, initialLocation: fixture.location, transferQueue: .isolatedForTesting())
    defer { session.invalidate() }
    session.load()
    await waitUntil { session.cloudDownloadStatuses[fixture.item.url] == .unknown }
    for state in [CloudDownloadStatus.downloading, .failed, .current] {
      observed.withLock { $0 = state }
      session.refresh()
      await waitUntil { session.cloudDownloadStatuses[fixture.item.url] == state }
    }
    #expect(session.cloudDownloadStatuses[fixture.item.url]?.indicatorLabel == nil)
    #expect(session.cloudTransferPreparationNotice == nil)
  }

  @Test("クラウド元の公開転送はOS取得の限界を案内し、取消は通常キューへ伝わる")
  func explainsCloudPreparationAndCancelsThroughQueue() async throws {
    let fixture = makeFixture(
      directory: FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/CloudStorage/Fixture"))
    let target = FileLocation(
      remotePath: "/destination", providerID: fixture.location.providerID)
    let copyStarted = Mutex(false)
    let copyAttempts = Mutex(0)
    let provider = CloudStatusSessionProvider(
      id: fixture.location.providerID, itemsByLocation: [fixture.location: [fixture.item]],
      statusLoader: { _ in [fixture.item.url: .downloading] },
      transferCopy: {
        copyStarted.withLock { $0 = true }
        let attempt = copyAttempts.withLock { value in
          value += 1
          return value
        }
        if attempt == 1 { try await Task.sleep(for: .seconds(30)) }
      })
    let queue = TransferQueue.isolatedForTesting()
    let source = FileBrowserSession(
      provider: provider, initialLocation: fixture.location, transferQueue: queue)
    let destination = FileBrowserSession(
      provider: provider, initialLocation: target, transferQueue: queue)
    defer {
      source.invalidate()
      destination.invalidate()
    }
    source.load()
    await waitUntil { source.cloudDownloadStatuses[fixture.item.url] == .downloading }
    source.copy(source.items, to: destination)
    await waitUntil { copyStarted.withLock { $0 } }
    #expect(
      source.cloudTransferPreparationNotice == CloudDownloadStatus.transferPreparationGuidance)
    source.cancelTransfer()
    await waitUntil { !source.isTransferring }
    let jobs = await queue.allJobs()
    #expect(try #require(jobs.first).state == .cancelled)
    #expect(source.cloudTransferPreparationNotice == nil)
    // PKPaneの取消でOSが取得終了したという状態を捏造しない。
    #expect(source.cloudDownloadStatuses[fixture.item.url] == .downloading)
    source.retryLastTransfer()
    await waitUntil {
      (await queue.allJobs()).first?.state == .completed && !source.isTransferring
    }
    #expect(copyAttempts.withLock { $0 } == 2)
    #expect(source.cloudTransferPreparationNotice == nil)
    #expect(source.cloudDownloadStatuses[fixture.item.url] == .downloading)
  }

  @Test("クラウド外フォルダではクラウド状態Providerを一度も呼ばない")
  func nonCloudFolderHasZeroProviderCalls() async {
    let fixture = makeFixture(
      directory: URL(filePath: "/virtual/Downloads", directoryHint: .isDirectory))
    let statusProvider = RecordingCloudStatusProvider()
    let provider = CloudStatusSessionProvider(
      id: fixture.location.providerID,
      itemsByLocation: [fixture.location: [fixture.item]],
      statusLoader: { locations in
        await statusProvider.cloudDownloadStatuses(itemLocations: locations)
      })
    let session = FileBrowserSession(
      provider: provider, initialLocation: fixture.location, transferQueue: .isolatedForTesting())

    session.load()
    await waitUntil { !session.isLoading }

    #expect(session.cloudDownloadStatuses.isEmpty)
    #expect(await statusProvider.callCount == 0)
  }

  @Test("クラウド配下では一覧ロード後にクラウド状態を反映する")
  func cloudFolderLoadsStatusesThroughSessionRoute() async {
    let fixture = makeFixture(
      directory: FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Mobile Documents/com.example.app", directoryHint: .isDirectory))
    let statusProvider = RecordingCloudStatusProvider(statuses: [fixture.item.url: .notDownloaded])
    let provider = CloudStatusSessionProvider(
      id: fixture.location.providerID,
      itemsByLocation: [fixture.location: [fixture.item]],
      statusLoader: { locations in
        await statusProvider.cloudDownloadStatuses(itemLocations: locations)
      })
    let session = FileBrowserSession(
      provider: provider, initialLocation: fixture.location, transferQueue: .isolatedForTesting())

    session.load()
    await waitUntil { session.cloudDownloadStatuses[fixture.item.url] == .notDownloaded }

    #expect(await statusProvider.callCount == 1)
  }

  @Test("フォルダ退出時にクラウド状態を消す")
  func navigationClearsCloudStatuses() async {
    let fixture = makeFixture(
      directory: FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Mobile Documents/com.example.app", directoryHint: .isDirectory))
    let destinationURL = URL(filePath: "/virtual/Downloads", directoryHint: .isDirectory)
    let destination = FileLocation(
      directoryURL: destinationURL, providerID: fixture.location.providerID)
    let statusProvider = RecordingCloudStatusProvider(statuses: [fixture.item.url: .notDownloaded])
    let provider = CloudStatusSessionProvider(
      id: fixture.location.providerID,
      itemsByLocation: [fixture.location: [fixture.item], destination: []],
      statusLoader: { locations in
        await statusProvider.cloudDownloadStatuses(itemLocations: locations)
      })
    let session = FileBrowserSession(
      provider: provider, initialLocation: fixture.location, transferQueue: .isolatedForTesting())

    session.load()
    await waitUntil { session.cloudDownloadStatuses[fixture.item.url] == .notDownloaded }
    session.load(location: destination)
    await waitUntil { !session.isLoading }

    #expect(session.cloudDownloadStatuses.isEmpty)
  }

  @Test("遅延した旧フォルダの結果は移動先を汚さない")
  func delayedOldFolderResultDoesNotPolluteNewFolder() async {
    let fixture = makeFixture(
      directory: FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Mobile Documents/com.example.app", directoryHint: .isDirectory))
    let destinationURL = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "Library/Mobile Documents/com.example.other", directoryHint: .isDirectory)
    let destination = FileLocation(
      directoryURL: destinationURL, providerID: fixture.location.providerID)
    let destinationItem = FileItem(
      url: destinationURL.appending(path: "next.txt"), providerID: fixture.location.providerID,
      isDirectory: false)
    let statusProvider = DeferredCloudStatusProvider()
    let provider = CloudStatusSessionProvider(
      id: fixture.location.providerID,
      itemsByLocation: [fixture.location: [fixture.item], destination: [destinationItem]],
      statusLoader: { locations in
        await statusProvider.cloudDownloadStatuses(itemLocations: locations)
      })
    let session = FileBrowserSession(
      provider: provider, initialLocation: fixture.location, transferQueue: .isolatedForTesting())

    session.load()
    await waitUntil { await statusProvider.callCount == 1 }
    session.load(location: destination)
    await waitUntil { await statusProvider.callCount == 2 }
    await statusProvider.releaseNext([fixture.item.url: .notDownloaded])
    await statusProvider.releaseNext([destinationItem.url: .notDownloaded])
    await waitUntil { session.cloudDownloadStatuses[destinationItem.url] == .notDownloaded }

    #expect(session.cloudDownloadStatuses[fixture.item.url] == nil)
  }

  @Test("カラムのドリルダウンで新しい列のクラウド状態をロードする")
  func columnDrillDownLoadsCloudStatusesForNewDirectory() async {
    let providerID = FileProviderID(rawValue: "cloud-status-column-\(UUID().uuidString)")
    let rootURL = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "Library/Mobile Documents/com.example.root", directoryHint: .isDirectory)
    let childURL = rootURL.appending(path: "child", directoryHint: .isDirectory)
    let root = FileLocation(directoryURL: rootURL, providerID: providerID)
    let childFolder = FileItem(url: childURL, providerID: providerID, isDirectory: true)
    let child = childFolder.location
    let rootItem = FileItem(
      url: rootURL.appending(path: "root.txt"), providerID: providerID, isDirectory: false)
    let childItem = FileItem(
      url: childURL.appending(path: "child.txt"), providerID: providerID, isDirectory: false)
    let statusesByItemLocation: [FileLocation: (URL, CloudDownloadStatus)] = [
      rootItem.location: (rootItem.url, .notDownloaded),
      childItem.location: (childItem.url, .notDownloaded),
    ]
    let provider = CloudStatusSessionProvider(
      id: providerID,
      itemsByLocation: [root: [childFolder, rootItem], child: [childItem]],
      statusLoader: { itemLocations in
        Dictionary(uniqueKeysWithValues: itemLocations.compactMap { statusesByItemLocation[$0] })
      })
    let session = FileBrowserSession(
      provider: provider, initialLocation: root, transferQueue: .isolatedForTesting())

    session.load()
    await waitUntil { session.cloudDownloadStatuses[rootItem.url] == .notDownloaded }
    session.beginColumnBrowsing()
    session.selectColumnItem(childFolder, inColumnAt: root)
    await waitUntil { session.cloudDownloadStatuses[childItem.url] == .notDownloaded }

    #expect(session.cloudDownloadStatuses[rootItem.url] == .notDownloaded)
    #expect(session.cloudDownloadStatuses[childItem.url] == .notDownloaded)
  }

  @Test("ツリー展開で子フォルダのクラウド状態をロードする")
  func treeExpansionLoadsCloudStatusesForExpandedDirectory() async {
    let providerID = FileProviderID(rawValue: "cloud-status-tree-\(UUID().uuidString)")
    let rootURL = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "Library/Mobile Documents/com.example.root", directoryHint: .isDirectory)
    let childURL = rootURL.appending(path: "child", directoryHint: .isDirectory)
    let root = FileLocation(directoryURL: rootURL, providerID: providerID)
    let childFolder = FileItem(url: childURL, providerID: providerID, isDirectory: true)
    let child = childFolder.location
    let childItem = FileItem(
      url: childURL.appending(path: "child.txt"), providerID: providerID, isDirectory: false)
    let provider = CloudStatusSessionProvider(
      id: providerID,
      itemsByLocation: [root: [childFolder], child: [childItem]],
      statusLoader: { itemLocations in
        itemLocations.contains(childItem.location) ? [childItem.url: .notDownloaded] : [:]
      })
    let session = FileBrowserSession(
      provider: provider, initialLocation: root, transferQueue: .isolatedForTesting())

    session.load()
    await waitUntil { !session.isLoading }
    session.toggleExpansion(of: childFolder)
    await waitUntil { session.cloudDownloadStatuses[childItem.url] == .notDownloaded }

    #expect(session.treeState.isExpanded(child))
    #expect(session.cloudDownloadStatuses[childItem.url] == .notDownloaded)
  }

  @Test("場所移動後に破棄された遅延クラウド状態タスクを解放する")
  func discardedDelayedCloudStatusTaskDoesNotKeepBrowsingResourcesActive() async {
    let fixture = makeFixture(
      directory: FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Mobile Documents/com.example.app", directoryHint: .isDirectory))
    let destination = FileLocation(
      directoryURL: URL(filePath: "/virtual/Downloads", directoryHint: .isDirectory),
      providerID: fixture.location.providerID)
    let statusProvider = DeferredCloudStatusProvider()
    let provider = CloudStatusSessionProvider(
      id: fixture.location.providerID,
      itemsByLocation: [fixture.location: [fixture.item], destination: []],
      statusLoader: { locations in
        await statusProvider.cloudDownloadStatuses(itemLocations: locations)
      })
    let session = FileBrowserSession(
      provider: provider, initialLocation: fixture.location, transferQueue: .isolatedForTesting())

    session.load()
    await waitUntil { await statusProvider.callCount == 1 }
    session.load(location: destination)
    await waitUntil { !session.isLoading }
    await statusProvider.releaseNext([fixture.item.url: .notDownloaded])
    await waitUntil { session.cloudStatusActiveTaskCount == 0 }

    #expect(session.cloudStatusActiveTaskCount == 0)
  }

  @Test("ツリーから退出したディレクトリだけクラウド状態を消す")
  func collapsingTreeDirectoryRetainsOtherDirectoryCloudStatuses() async {
    let providerID = FileProviderID(rawValue: "cloud-status-exit-\(UUID().uuidString)")
    let rootURL = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "Library/Mobile Documents/com.example.root", directoryHint: .isDirectory)
    let childURL = rootURL.appending(path: "child", directoryHint: .isDirectory)
    let root = FileLocation(directoryURL: rootURL, providerID: providerID)
    let childFolder = FileItem(url: childURL, providerID: providerID, isDirectory: true)
    let child = childFolder.location
    let rootItem = FileItem(
      url: rootURL.appending(path: "root.txt"), providerID: providerID, isDirectory: false)
    let childItem = FileItem(
      url: childURL.appending(path: "child.txt"), providerID: providerID, isDirectory: false)
    let statusesByItemLocation: [FileLocation: (URL, CloudDownloadStatus)] = [
      rootItem.location: (rootItem.url, .notDownloaded),
      childItem.location: (childItem.url, .notDownloaded),
    ]
    let provider = CloudStatusSessionProvider(
      id: providerID,
      itemsByLocation: [root: [childFolder, rootItem], child: [childItem]],
      statusLoader: { itemLocations in
        Dictionary(uniqueKeysWithValues: itemLocations.compactMap { statusesByItemLocation[$0] })
      })
    let session = FileBrowserSession(
      provider: provider, initialLocation: root, transferQueue: .isolatedForTesting())

    session.load()
    await waitUntil { session.cloudDownloadStatuses[rootItem.url] == .notDownloaded }
    session.toggleExpansion(of: childFolder)
    await waitUntil { session.cloudDownloadStatuses[childItem.url] == .notDownloaded }
    session.toggleExpansion(of: childFolder)

    #expect(!session.treeState.isExpanded(child))
    #expect(session.cloudDownloadStatuses[rootItem.url] == .notDownloaded)
    #expect(session.cloudDownloadStatuses[childItem.url] == nil)
    #expect(session.cloudStatusTrackedDirectoryCount == 1)
  }

  @Test("C2(i): クラウド外パスでもProviderがクラウド管理下と答えれば状態を反映する")
  func providerDeclaredCloudManagedDirectoryLoadsStatuses() async {
    let fixture = makeFixture(
      directory: FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory))
    let statusProvider = RecordingCloudStatusProvider(statuses: [fixture.item.url: .notDownloaded])
    let provider = CloudStatusSessionProvider(
      id: fixture.location.providerID,
      itemsByLocation: [fixture.location: [fixture.item]],
      statusLoader: { locations in
        await statusProvider.cloudDownloadStatuses(itemLocations: locations)
      },
      cloudManaged: { _ in true })
    let session = FileBrowserSession(
      provider: provider, initialLocation: fixture.location, transferQueue: .isolatedForTesting())

    session.load()
    await waitUntil { session.cloudDownloadStatuses[fixture.item.url] == .notDownloaded }

    #expect(await statusProvider.callCount == 1)
  }

  @Test("C2(ii): Providerがクラウド管理下でないと答えれば状態を問い合わせない")
  func providerDeclaredNonCloudDirectoryNeverLoadsStatuses() async throws {
    let fixture = makeFixture(
      directory: FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory))
    let statusProvider = RecordingCloudStatusProvider(statuses: [fixture.item.url: .notDownloaded])
    let provider = CloudStatusSessionProvider(
      id: fixture.location.providerID,
      itemsByLocation: [fixture.location: [fixture.item]],
      statusLoader: { locations in
        await statusProvider.cloudDownloadStatuses(itemLocations: locations)
      },
      cloudManaged: { _ in false })
    let session = FileBrowserSession(
      provider: provider, initialLocation: fixture.location, transferQueue: .isolatedForTesting())

    session.load()
    await waitUntil { !session.isLoading }
    session.refresh()
    await waitUntil { !session.isLoading }
    // 問い合わせが起きないことの確認なので、条件待ちではなく短い固定待ちを置く。
    try await Task.sleep(for: .milliseconds(300))

    #expect(session.cloudDownloadStatuses.isEmpty)
    #expect(await statusProvider.callCount == 0)
  }

  private func makeFixture(directory: URL) -> (location: FileLocation, item: FileItem) {
    let providerID = FileProviderID(rawValue: "cloud-status-\(UUID().uuidString)")
    let location = FileLocation(directoryURL: directory, providerID: providerID)
    let item = FileItem(
      url: directory.appending(path: "file.txt"), providerID: providerID, isDirectory: false)
    return (location, item)
  }

  private func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: @escaping @MainActor () async -> Bool
  ) async {
    await PKPaneTests.waitUntil(timeout: timeout, "クラウドステータスの状態が期限内に条件を満たさなかった") {
      await condition()
    }
  }
}

private struct CloudStatusSessionProvider: FileBrowserCloudStatusMetadataProvider,
  FileBrowserTransferProvider
{
  let id: FileProviderID
  let connectionID: FileProviderConnectionID? = nil
  var capabilities: FileProviderCapabilities {
    transferCopy == nil ? [.read, .cloudDownloadStatus] : [.read, .write, .cloudDownloadStatus]
  }
  let transferCopy: (@Sendable () async throws -> Void)?
  let itemsByLocation: [FileLocation: [FileItem]]
  let statusLoader: @Sendable ([FileLocation]) async -> [URL: CloudDownloadStatus]

  /// nilのときはプロトコル拡張の既定実装と同じパス判定のみで答える。
  let cloudManaged: (@Sendable (FileLocation) async -> Bool)?

  init(
    id: FileProviderID, itemsByLocation: [FileLocation: [FileItem]],
    statusLoader: @escaping @Sendable ([FileLocation]) async -> [URL: CloudDownloadStatus],
    transferCopy: (@Sendable () async throws -> Void)? = nil,
    cloudManaged: (@Sendable (FileLocation) async -> Bool)? = nil
  ) {
    self.id = id
    self.itemsByLocation = itemsByLocation
    self.statusLoader = statusLoader
    self.transferCopy = transferCopy
    self.cloudManaged = cloudManaged
  }

  func isCloudManagedDirectory(_ location: FileLocation) async -> Bool {
    if let cloudManaged { return await cloudManaged(location) }
    guard let url = location.localURL else { return false }
    return isCloudManagedFolder(url, isUbiquitousItem: { _ in false })
  }
  func createDirectory(named _: String, in _: FileLocation) async throws {}
  func rename(_: FileItem, to _: String) async throws {}
  func delete(_: FileItem) async throws {}
  func move(_: FileItem, to _: FileLocation, replacingExisting _: Bool) async throws {}
  func copy(_: FileItem, to _: FileLocation, replacingExisting _: Bool) async throws {
    try await transferCopy?()
  }
  func removeAfterCrossProviderMove(_: FileItem) async throws {}

  func contents(of location: FileLocation) async throws -> [FileItem] {
    itemsByLocation[location] ?? []
  }

  func contents(of location: FileLocation, includingHidden _: Bool) async throws -> [FileItem] {
    itemsByLocation[location] ?? []
  }

  func parent(of _: FileLocation) -> FileLocation? { nil }

  func breadcrumbs(
    for location: FileLocation,
    constrainedTo _: FileLocation?
  ) -> [FileBrowserBreadcrumb] {
    [FileBrowserBreadcrumb(location: location, name: location.localURL?.lastPathComponent ?? "")]
  }

  func cloudDownloadStatuses(
    itemLocations: [FileLocation]
  ) async -> [URL: CloudDownloadStatus] {
    await statusLoader(itemLocations)
  }
}

private actor RecordingCloudStatusProvider {
  private(set) var callCount = 0
  let statuses: [URL: CloudDownloadStatus]

  init(statuses: [URL: CloudDownloadStatus] = [:]) {
    self.statuses = statuses
  }

  func cloudDownloadStatuses(itemLocations _: [FileLocation]) -> [URL: CloudDownloadStatus] {
    callCount += 1
    return statuses
  }
}

private actor DeferredCloudStatusProvider {
  private(set) var callCount = 0
  private var continuations: [CheckedContinuation<[URL: CloudDownloadStatus], Never>] = []

  func cloudDownloadStatuses(itemLocations _: [FileLocation]) async -> [URL: CloudDownloadStatus] {
    // callCountの増分はcontinuation追加と同一同期ブロックで行う。
    // 先に増分するとawait境界のinterleaveで「callCount到達済み・continuation未追加」の
    // 瞬間が生まれ、releaseNextのremoveFirstが空配列トラップでプロセスごと落ちる。
    await withCheckedContinuation { continuation in
      continuations.append(continuation)
      callCount += 1
    }
  }

  func releaseNext(_ statuses: [URL: CloudDownloadStatus]) {
    // waitUntilは期限切れでも黙って戻るため、高負荷で要求が届く前にここへ到達しうる。
    // 空配列のremoveFirstはプロセスごと落として全並走テストを巻き添えにするので、
    // trapせずIssue記録の単一テスト失敗へ封じ込める。
    guard !continuations.isEmpty else {
      Issue.record("解放対象のcontinuationがありません(cloudDownloadStatuses要求が期限内に未到達)")
      return
    }
    continuations.removeFirst().resume(returning: statuses)
  }
}
