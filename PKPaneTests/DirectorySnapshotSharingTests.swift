import Foundation
import Testing

@testable import PKPane

@MainActor
struct DirectorySnapshotSharingTests {
  @Test("キャッシュ命中で戻った場所は無音再検証を1回だけ行う")
  func cacheHitNavigationRevalidatesOnce() async throws {
    let fixture = try DirectorySnapshotFixture()
    defer { fixture.remove() }
    let provider = DirectorySnapshotCountingProvider()
    let root = FileLocation(directoryURL: fixture.rootURL, providerID: provider.id)
    let child = FileLocation(directoryURL: fixture.childURL, providerID: provider.id)
    let browser = FileBrowserSession(
      provider: provider,
      initialLocation: root,
      transferQueue: .isolatedForTesting())
    defer { browser.invalidate() }

    browser.load()
    await waitForListing(browser)
    let childItem = try #require(browser.items.first { $0.location == child })
    browser.open(childItem)
    await waitForListing(browser)

    browser.goBack()
    await waitForListing(browser, includingBackgroundRevalidation: true)
    // 監視武装は非同期で、製品側にテスト用フックを持たない。既存の監視競合テストと
    // 同じく、ローカルfdの武装に十分な短い実時間を確保してから回数を観測する。
    try await Task.sleep(for: .milliseconds(100))
    let rootCountAfterCacheHit = provider.contentsCallCount(at: root)

    // FileBrowserSessionDirectoryWatchTestsと同じく、実ファイルの追加が一覧へ反映される
    // ことを待ち、テスト用フックなしで監視が武装済みだったことを確認する。意図的な
    // 監視イベントによる列挙は契約値に含めないため、追加前の回数を保持して検証する。
    let watcherProbeURL = fixture.rootURL.appending(path: "watcher-probe.txt")
    try Data("監視".utf8).write(to: watcherProbeURL)
    await waitUntil("監視確認用ファイルが一覧へ反映されなかった") {
      browser.items.contains(where: { $0.name == watcherProbeURL.lastPathComponent })
    }

    #expect(rootCountAfterCacheHit == 2)
  }

  @Test("再検証中の監視武装チェックはmtime変更時だけ完了後に再検証する")
  func deferredArmCheckRevalidatesWhenDirectoryChangedDuringRevalidation() async throws {
    let fixture = try DirectorySnapshotFixture()
    defer { fixture.remove() }
    let root = FileLocation(directoryURL: fixture.rootURL)
    let gate = DirectorySnapshotEnumerationGate()
    let provider = DirectorySnapshotCountingProvider(
      gate: gate,
      gatedLocation: root,
      gatedFromCallCount: 2)
    let providerRoot = FileLocation(directoryURL: fixture.rootURL, providerID: provider.id)
    let child = FileLocation(directoryURL: fixture.childURL, providerID: provider.id)
    let browser = FileBrowserSession(
      provider: provider,
      initialLocation: providerRoot,
      transferQueue: .isolatedForTesting())
    defer {
      Task { await gate.release() }
      browser.invalidate()
    }

    browser.load()
    await waitForListing(browser)
    let childItem = try #require(browser.items.first { $0.location == child })
    browser.open(childItem)
    await waitForListing(browser)
    let modifiedAtBeforeReturn = try #require(directoryModifiedAt(fixture.rootURL))

    browser.goBack()
    let didBlockRevalidation = await waitUntil(
      "rootの2回目の列挙がゲートで停止しなかった"
    ) {
      await gate.hasBlockedEnumeration
    }
    try #require(didBlockRevalidation)

    let addedFileURL = fixture.rootURL.appending(path: "added-during-revalidation.txt")
    try Data("追加".utf8).write(to: addedFileURL)
    let didChangeModificationDate = await waitUntil(
      timeout: .seconds(2),
      "ファイル追加後もrootのmtimeが変化しなかった"
    ) {
      directoryModifiedAt(fixture.rootURL) != modifiedAtBeforeReturn
    }
    try #require(didChangeModificationDate)

    // LocalDirectoryWatcherの武装完了を待つ既存テストと同じ短い実時間を確保する。
    // 実イベント側のdebounce(250ms)より前に確認し、武装完了チェックだけを観測する。
    try await Task.sleep(for: .milliseconds(100))
    #expect(provider.contentsCallCount(at: providerRoot) == 2)

    await gate.release()
    await waitUntil(
      timeout: .milliseconds(100),
      "ゲート解放後にmtime変更分の再検証が完了しなかった"
    ) {
      provider.contentsCallCount(at: providerRoot) >= 3
        && !browser.isRevalidatingInBackground
        && browser.items.contains(where: { $0.name == addedFileURL.lastPathComponent })
    }

    #expect(provider.contentsCallCount(at: providerRoot) == 3)
    #expect(browser.items.contains(where: { $0.name == addedFileURL.lastPathComponent }))
  }

  @Test("同じ場所のタブ複製は複製元と複製先でそれぞれ列挙する")
  func duplicatedTabListsSameDirectoryTwice() async throws {
    let fixture = try DirectorySnapshotFixture()
    defer { fixture.remove() }
    let provider = DirectorySnapshotCountingProvider()
    let root = FileLocation(directoryURL: fixture.rootURL, providerID: provider.id)
    let original = FileBrowserSession(
      provider: provider,
      initialLocation: root,
      transferQueue: .isolatedForTesting())
    let originalTab = FileWorkspaceTab(browser: original)
    let duplicate = originalTab.duplicated()
    defer {
      original.invalidate()
      duplicate.browser.invalidate()
    }

    original.load()
    await waitForListing(original)
    duplicate.browser.load()
    await waitForListing(duplicate.browser)

    #expect(provider.contentsCallCount(at: root) == 2)
  }

  @Test("左右ペインが同じ場所ならペインごとに列挙する")
  func twoPanesListSameDirectoryTwice() async throws {
    let fixture = try DirectorySnapshotFixture()
    defer { fixture.remove() }
    let provider = DirectorySnapshotCountingProvider()
    let root = FileLocation(directoryURL: fixture.rootURL, providerID: provider.id)
    let primary = FileBrowserSession(
      provider: provider,
      initialLocation: root,
      transferQueue: .isolatedForTesting())
    let workspace = FileWorkspaceModel(initialBrowser: primary)
    let initialSecondaryID = try #require(workspace.tab(for: .secondary)?.id)
    workspace.closeTab(id: initialSecondaryID)
    defer {
      for tab in workspace.tabs {
        tab.browser.invalidate()
      }
    }

    primary.load()
    await waitForListing(primary)
    workspace.setShowsSecondaryPane(true)
    let secondary = try #require(workspace.tab(for: .secondary)?.browser)
    secondary.load()
    await waitForListing(secondary)

    #expect(provider.contentsCallCount(at: root) == 2)
  }

  @Test("直前に開いた子フォルダへの行ドロップも転送先を再列挙する")
  func folderRowDropRelistsRecentlyOpenedDestination() async throws {
    let fixture = try DirectorySnapshotFixture(makesDestinationConflict: true)
    defer { fixture.remove() }
    let provider = DirectorySnapshotCountingProvider()
    let root = FileLocation(directoryURL: fixture.rootURL, providerID: provider.id)
    let child = FileLocation(directoryURL: fixture.childURL, providerID: provider.id)
    let browser = FileBrowserSession(
      provider: provider,
      initialLocation: root,
      transferQueue: .isolatedForTesting())
    let workspace = FileWorkspaceModel(initialBrowser: browser)
    defer {
      for tab in workspace.tabs {
        tab.browser.invalidate()
      }
    }

    browser.load()
    await waitForListing(browser)
    let childItem = try #require(browser.items.first { $0.location == child })
    let sourceItem = try #require(browser.items.first { $0.name == "report.txt" })
    browser.open(childItem)
    await waitForListing(browser)
    browser.goBack()
    // 二重起動一本化(2026-09-10)で3→2
    await waitUntil("戻る操作後の無音再検証が期限内に完了しなかった") {
      provider.contentsCallCount(at: root) == 2
        && !browser.isRevalidatingInBackground
    }

    #expect(
      workspace.transferDroppedItems(
        [sourceItem.url],
        into: childItem,
        in: .primary,
        copyForced: true))
    await waitUntil("転送先目録の列挙と同名衝突判定が期限内に完了しなかった") {
      browser.pendingTransferConflict != nil
    }

    #expect(provider.contentsCallCount(at: root) == 2)
    #expect(provider.contentsCallCount(at: child) == 2)
    #expect(FileManager.default.fileExists(atPath: fixture.sourceFileURL.path))
    #expect(FileManager.default.fileExists(atPath: fixture.destinationFileURL.path))
  }

  @Test("履歴の戻ると進むはキャッシュから復元し前景列挙を増やさない")
  func historyNavigationRestoresCachedDirectoriesWithoutForegroundListing() async throws {
    let fixture = try DirectorySnapshotFixture()
    defer { fixture.remove() }
    let provider = DirectorySnapshotCountingProvider()
    let root = FileLocation(directoryURL: fixture.rootURL, providerID: provider.id)
    let child = FileLocation(directoryURL: fixture.childURL, providerID: provider.id)
    let browser = FileBrowserSession(
      provider: provider,
      initialLocation: root,
      transferQueue: .isolatedForTesting())
    defer { browser.invalidate() }

    browser.load()
    await waitForListing(browser)
    let childItem = try #require(browser.items.first { $0.location == child })
    browser.open(childItem)
    await waitForListing(browser)
    let rootCountBeforeHistory = provider.contentsCallCount(at: root)
    let childCountBeforeHistory = provider.contentsCallCount(at: child)

    browser.goBack()
    await waitForListing(browser)
    browser.goForward()
    await waitForListing(browser)

    #expect(provider.contentsCallCount(at: root) == 1)
    #expect(provider.contentsCallCount(at: child) == 1)
    #expect(provider.contentsCallCount(at: root) - rootCountBeforeHistory == 0)
    #expect(provider.contentsCallCount(at: child) - childCountBeforeHistory == 0)
  }

  private func waitForListing(
    _ browser: FileBrowserSession,
    includingBackgroundRevalidation: Bool = false
  ) async {
    await waitUntil("一覧の読み込みが期限内に完了しなかった") {
      !(browser.isLoading || browser.isRefreshing)
        && (!includingBackgroundRevalidation || !browser.isRevalidatingInBackground)
    }
  }

  private func directoryModifiedAt(_ directoryURL: URL) -> Date? {
    try? directoryURL.resourceValues(forKeys: [.contentModificationDateKey])
      .contentModificationDate
  }
}

private final class DirectorySnapshotCountingProvider: FileBrowserStreamingProvider,
  FileBrowserTransferProvider, @unchecked Sendable
{
  private let wrapped = LocalFileProvider()
  private let lock = NSLock()
  private var callCountByLocation: [FileLocation: Int] = [:]
  private let gate: DirectorySnapshotEnumerationGate?
  private let gatedLocation: FileLocation?
  private let gatedFromCallCount: Int

  init(
    gate: DirectorySnapshotEnumerationGate? = nil,
    gatedLocation: FileLocation? = nil,
    gatedFromCallCount: Int = .max
  ) {
    self.gate = gate
    self.gatedLocation = gatedLocation
    self.gatedFromCallCount = gatedFromCallCount
  }

  var id: FileProviderID { wrapped.id }
  var connectionID: FileProviderConnectionID? { wrapped.connectionID }
  var capabilities: FileProviderCapabilities { wrapped.capabilities }

  func contentsCallCount(at location: FileLocation) -> Int {
    lock.withLock { callCountByLocation[location, default: 0] }
  }

  func contents(of location: FileLocation) async throws -> [FileItem] {
    recordContentsCall(at: location)
    return try await wrapped.contents(of: location)
  }

  func contents(of location: FileLocation, includingHidden: Bool) async throws -> [FileItem] {
    recordContentsCall(at: location)
    return try await wrapped.contents(of: location, includingHidden: includingHidden)
  }

  func contentsStream(
    of location: FileLocation,
    includingHidden: Bool,
    batchSize: Int
  ) -> AsyncThrowingStream<[FileItem], Error> {
    let callCount = recordContentsCall(at: location)
    guard location == gatedLocation, callCount >= gatedFromCallCount, let gate else {
      return wrapped.contentsStream(
        of: location,
        includingHidden: includingHidden,
        batchSize: batchSize)
    }
    return AsyncThrowingStream { continuation in
      let task = Task {
        await gate.wait()
        do {
          let stream = wrapped.contentsStream(
            of: location,
            includingHidden: includingHidden,
            batchSize: batchSize)
          for try await batch in stream {
            try Task.checkCancellation()
            continuation.yield(batch)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { @Sendable _ in
        task.cancel()
      }
    }
  }

  func parent(of location: FileLocation) -> FileLocation? {
    wrapped.parent(of: location)
  }

  func breadcrumbs(
    for location: FileLocation,
    constrainedTo root: FileLocation?
  ) -> [FileBrowserBreadcrumb] {
    wrapped.breadcrumbs(for: location, constrainedTo: root)
  }

  func createDirectory(named name: String, in location: FileLocation) async throws {
    try await wrapped.createDirectory(named: name, in: location)
  }

  func rename(_ item: FileItem, to name: String) async throws {
    try await wrapped.rename(item, to: name)
  }

  func delete(_ item: FileItem) async throws {
    try await wrapped.delete(item)
  }

  func move(
    _ item: FileItem,
    to directory: FileLocation,
    replacingExisting _: Bool
  ) async throws {
    try await wrapped.move(item, to: directory)
  }

  func copy(
    _ item: FileItem,
    to directory: FileLocation,
    replacingExisting: Bool
  ) async throws {
    try await wrapped.copy(item, to: directory, replacingExisting: replacingExisting)
  }

  func removeAfterCrossProviderMove(_ item: FileItem) async throws {
    try await wrapped.removeAfterCrossProviderMove(item)
  }

  @discardableResult
  private func recordContentsCall(at location: FileLocation) -> Int {
    lock.withLock {
      callCountByLocation[location, default: 0] += 1
      return callCountByLocation[location, default: 0]
    }
  }
}

private actor DirectorySnapshotEnumerationGate {
  private var isReleased = false
  private var blockedEnumerationCount = 0
  private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

  var hasBlockedEnumeration: Bool {
    blockedEnumerationCount > 0
  }

  func wait() async {
    let waiterID = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard !isReleased, !Task.isCancelled else {
          continuation.resume()
          return
        }
        blockedEnumerationCount += 1
        waiters[waiterID] = continuation
      }
    } onCancel: {
      Task { await self.cancel(waiterID) }
    }
  }

  func release() {
    guard !isReleased else { return }
    isReleased = true
    let continuations = waiters.values
    waiters.removeAll()
    for continuation in continuations {
      continuation.resume()
    }
  }

  private func cancel(_ waiterID: UUID) {
    waiters.removeValue(forKey: waiterID)?.resume()
  }
}

private struct DirectorySnapshotFixture {
  let rootURL: URL
  let childURL: URL
  let sourceFileURL: URL
  let destinationFileURL: URL

  init(makesDestinationConflict: Bool = false) throws {
    rootURL = FileManager.default.temporaryDirectory
      .appending(path: "pkpane-snapshot-sharing-\(UUID().uuidString)", directoryHint: .isDirectory)
    childURL = rootURL.appending(path: "child", directoryHint: .isDirectory)
    sourceFileURL = rootURL.appending(path: "report.txt")
    destinationFileURL = childURL.appending(path: "report.txt")
    try FileManager.default.createDirectory(at: childURL, withIntermediateDirectories: true)
    try Data("転送元".utf8).write(to: sourceFileURL)
    if makesDestinationConflict {
      try Data("既存転送先".utf8).write(to: destinationFileURL)
    }
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootURL)
  }
}
