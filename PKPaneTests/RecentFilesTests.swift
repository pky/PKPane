import Foundation
import Synchronization
import Testing

@testable import PKPane

@MainActor
struct RecentFilesTests {
  @Test("リンク先が認可範囲外なら属性照会前に除外する")
  func excludesEscapingLinkBeforeFileRead() async {
    let root = URL(filePath: "/allowed", directoryHint: .isDirectory)
    let link = root.appending(path: "link.txt")
    let outside = URL(filePath: "/outside/secret.txt")
    let reads = Mutex<[URL]>([])
    let validator = RecentFilePathValidator(
      resolve: { $0 == link ? outside : $0 },
      isFile: { url in
        reads.withLock { $0.append(url) }
        return true
      })

    let result = await validator.filter(
      [RecentMetadataRecord(url: link, lastUsedAt: Date(), isDirectory: false, size: nil)],
      roots: [root])

    #expect(result.isEmpty)
    #expect(reads.withLock { $0.isEmpty })
  }

  @Test("転送ジョブの元許可ブックマークは往復し旧形式ではnilになる")
  func transferJobBookmarkCompatibility() throws {
    let root = URL(filePath: "/tmp/recent-source", directoryHint: .isDirectory)
    let item = FileItem(url: root.appending(path: "file.txt"), isDirectory: false)
    var job = TransferJob(
      kind: .copy, items: [item], sourceProviderID: .local,
      destinationProviderID: .local,
      destination: FileLocation(localURL: URL(filePath: "/tmp/destination")))
    job.sourceAccessBookmarkData = Data([1, 2, 3])

    let encoded = try JSONEncoder().encode(job)
    #expect(
      try JSONDecoder().decode(TransferJob.self, from: encoded).sourceAccessBookmarkData
        == Data([1, 2, 3]))

    var oldJSON = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    oldJSON.removeValue(forKey: "sourceAccessBookmarkData")
    let oldData = try JSONSerialization.data(withJSONObject: oldJSON)
    #expect(
      try JSONDecoder().decode(TransferJob.self, from: oldData).sourceAccessBookmarkData
        == nil)
  }

  @Test("最近の項目の転送元は実親ごとに分ける")
  func groupsRecentTransfersByActualParent() {
    let root = URL(filePath: "/tmp/recent-groups", directoryHint: .isDirectory)
    let first = FileItem(url: root.appending(path: "a/1.txt"), isDirectory: false)
    let second = FileItem(url: root.appending(path: "b/2.txt"), isDirectory: false)
    let third = FileItem(url: root.appending(path: "a/3.txt"), isDirectory: false)

    let groups = FileWorkspaceModel.recentTransferGroups([first, second, third])

    #expect(groups.count == 2)
    #expect(groups[0].parent == first.location.deletingLastPathComponent())
    #expect(groups[0].items == [first, third])
    #expect(groups[1].parent == second.location.deletingLastPathComponent())
    #expect(groups[1].items == [second])
  }

  @Test("転送元の許可を復元できた実親だけを再開元にする")
  func restoresOnlyAuthorizedActualSource() async {
    let root = URL(filePath: "/tmp/recent-authorized", directoryHint: .isDirectory)
    let parent = root.appending(path: "B", directoryHint: .isDirectory)
    let item = FileItem(url: parent.appending(path: "file.txt"), isDirectory: false)
    var job = TransferJob(
      kind: .copy, items: [item], sourceProviderID: .local,
      destinationProviderID: .local,
      destination: FileLocation(localURL: URL(filePath: "/tmp/destination")))
    job.sourceAccessBookmarkData = Data([1])
    let codec = FixedRecentBookmarkCodec(url: root)
    let deniedManager = FolderBookmarkAccessManager(
      startAccess: { _ in false }, stopAccess: { _ in },
      isSandboxed: { true }, canReadDirectory: { _ in true })
    let allowedManager = FolderBookmarkAccessManager(
      startAccess: { _ in true }, stopAccess: { _ in },
      isSandboxed: { true }, canReadDirectory: { _ in true })
    let queue = TransferQueue(store: InMemoryTransferJobStore())

    #expect(
      await FileWorkspaceModel.restoredRecentTransferSource(
        for: job, transferQueue: queue,
        bookmarkCodec: codec, accessManager: deniedManager) == nil)

    let restored = await FileWorkspaceModel.restoredRecentTransferSource(
      for: job, transferQueue: queue,
      bookmarkCodec: codec, accessManager: allowedManager)
    #expect(restored?.currentLocation == item.location.deletingLastPathComponent())

    let unrelated = FixedRecentBookmarkCodec(url: URL(filePath: "/tmp/other"))
    #expect(
      await FileWorkspaceModel.restoredRecentTransferSource(
        for: job, transferQueue: queue,
        bookmarkCodec: unrelated, accessManager: allowedManager) == nil)
  }

  @Test("再開元がリンク経由で許可rootの外なら拒否する")
  func rejectsEscapingRecentResumeSource() async throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let outside = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: outside) }
    let link = root.appending(path: "linked", directoryHint: .isDirectory)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    let item = FileItem(url: link.appending(path: "file.txt"), isDirectory: false)
    var job = TransferJob(
      kind: .copy, items: [item], sourceProviderID: .local,
      destinationProviderID: .local,
      destination: FileLocation(localURL: root))
    job.sourceAccessBookmarkData = Data([1])
    let manager = FolderBookmarkAccessManager(
      startAccess: { _ in true }, stopAccess: { _ in },
      isSandboxed: { true }, canReadDirectory: { _ in true })

    let restored = await FileWorkspaceModel.restoredRecentTransferSource(
      for: job, transferQueue: .isolatedForTesting(),
      bookmarkCodec: FixedRecentBookmarkCodec(url: root), accessManager: manager)

    #expect(restored == nil)
  }

  @Test("元の許可を復元できない中断ジョブは維持して画面にエラーを示す")
  func preservesInterruptedJobWhenBookmarkCannotResolve() async throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = root.appending(path: "B", directoryHint: .isDirectory)
    let destinationURL = root.appending(path: "C", directoryHint: .isDirectory)
    for folder in [sourceURL, destinationURL] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    let item = FileItem(url: sourceURL.appending(path: "file.txt"), isDirectory: false)
    var job = TransferJob(
      kind: .copy, items: [item], sourceProviderID: .local,
      destinationProviderID: .local,
      destination: FileLocation(localURL: destinationURL))
    job.state = .interrupted
    job.sourceAccessBookmarkData = Data([1])
    let store = InMemoryTransferJobStore()
    try store.save([job])
    let queue = TransferQueue(store: store)
    let browser = FileBrowserSession(
      provider: LocalFileProvider(), initialLocation: FileLocation(localURL: root),
      transferQueue: queue)
    let workspace = FileWorkspaceModel(initialBrowser: browser)
    workspace.activatePane(.secondary)
    let destination = FileBrowserSession(
      provider: LocalFileProvider(), initialLocation: FileLocation(localURL: destinationURL),
      transferQueue: queue)
    workspace.replaceActiveBrowser(with: destination)

    await waitUntil { destination.errorMessage != nil }

    #expect((await queue.allJobs()).first?.state == .interrupted)
    #expect(!destination.canRetryLastTransfer)
  }

  @Test("最近の項目から別親のファイルを実親ごとに転送する", arguments: [false, true])
  func transfersRecentFilesFromActualParents(wasMove: Bool) async throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let background = root.appending(path: "background", directoryHint: .isDirectory)
    let approved = root.appending(path: "approved", directoryHint: .isDirectory)
    let first = approved.appending(path: "first", directoryHint: .isDirectory)
    let second = approved.appending(path: "second", directoryHint: .isDirectory)
    let destinationURL = root.appending(path: "destination", directoryHint: .isDirectory)
    for folder in [background, first, second, destinationURL] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    let firstURL = first.appending(path: "a.txt")
    let secondURL = second.appending(path: "b.txt")
    try Data("A".utf8).write(to: firstURL)
    try Data("B".utf8).write(to: secondURL)
    let provider = LocalFileProvider()
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let firstItem = try provider.item(at: firstURL)
    let secondItem = try provider.item(at: secondURL)
    let source = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: background), transferQueue: queue,
      recentFilesService: StubRecentFileSearchService(items: [
        (firstItem, Date()), (secondItem, Date()),
      ]))
    let destination = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: destinationURL), transferQueue: queue)
    let workspace = FileWorkspaceModel(
      initialBrowser: source,
      recentSourceBookmarkReader: RecentSourceBookmarkReader(create: { _ in Data([1]) }))
    workspace.activatePane(.secondary)
    workspace.replaceActiveBrowser(with: destination)
    workspace.activatePane(.primary)
    source.startRecentFiles(
      authorizedRoots: [approved], accessLeases: [try makeLease(for: approved)])
    await waitUntil { !source.isSearching && source.searchResults.count == 2 }
    workspace.activeTab.selectedItemURLs = [firstURL, secondURL]

    workspace.transferSelectedItems(to: destination, wasMove: wasMove)
    await PKPaneTests.waitUntil(
      timeout: .seconds(5), "最近の項目からの転送が終わらなかった"
    ) {
      FileManager.default.fileExists(atPath: destinationURL.appending(path: "a.txt").path)
        && FileManager.default.fileExists(atPath: destinationURL.appending(path: "b.txt").path)
        && (!wasMove
          || (!FileManager.default.fileExists(atPath: firstURL.path)
            && !FileManager.default.fileExists(atPath: secondURL.path)))
    }

    let jobs = await queue.allJobs()
    #expect(jobs.count == 2)
    #expect(jobs.allSatisfy { $0.items.count == 1 })
  }

  @Test("別親2ファイルのrecent移動を1回のUndoで両方戻す")
  func undoesAllRecentTransferGroupsTogether() async throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = root.appending(path: "A", directoryHint: .isDirectory)
    let second = root.appending(path: "B", directoryHint: .isDirectory)
    let destinationURL = root.appending(path: "C", directoryHint: .isDirectory)
    for folder in [first, second, destinationURL] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    let firstURL = first.appending(path: "first.txt")
    let secondURL = second.appending(path: "second.txt")
    try Data("first".utf8).write(to: firstURL)
    try Data("second".utf8).write(to: secondURL)
    let provider = LocalFileProvider()
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let source = FileBrowserSession(
      provider: provider, initialLocation: FileLocation(localURL: root),
      transferQueue: queue,
      recentFilesService: StubRecentFileSearchService(items: [
        (try provider.item(at: firstURL), Date()),
        (try provider.item(at: secondURL), Date()),
      ]))
    let destination = FileBrowserSession(
      provider: provider, initialLocation: FileLocation(localURL: destinationURL),
      transferQueue: queue)
    let workspace = FileWorkspaceModel(
      initialBrowser: source,
      recentSourceBookmarkReader: RecentSourceBookmarkReader(create: { _ in Data([1]) }))
    source.startRecentFiles(authorizedRoots: [root], accessLeases: [try makeLease(for: root)])
    await waitUntil { !source.isSearching && source.searchResults.count == 2 }
    workspace.activeTab.selectedItemURLs = [firstURL, secondURL]
    workspace.transferSelectedItems(to: destination, wasMove: true)
    await PKPaneTests.waitUntil(timeout: .seconds(5), "2親の移動が終わらなかった") {
      FileManager.default.fileExists(atPath: destinationURL.appending(path: "first.txt").path)
        && FileManager.default.fileExists(
          atPath: destinationURL.appending(path: "second.txt").path)
        && !FileManager.default.fileExists(atPath: firstURL.path)
        && !FileManager.default.fileExists(atPath: secondURL.path)
    }
    await waitUntil { workspace.canUndoLastTransfer }

    workspace.undoLastTransfer()
    await PKPaneTests.waitUntil(timeout: .seconds(5), "2親のUndoが終わらなかった") {
      FileManager.default.fileExists(atPath: firstURL.path)
        && FileManager.default.fileExists(atPath: secondURL.path)
        && !FileManager.default.fileExists(
          atPath: destinationURL.appending(path: "first.txt").path)
        && !FileManager.default.fileExists(
          atPath: destinationURL.appending(path: "second.txt").path)
    }
    #expect(try Data(contentsOf: firstURL) == Data("first".utf8))
    #expect(try Data(contentsOf: secondURL) == Data("second".utf8))
  }

  @Test("別親2ファイルのrecentコピーを1回のUndoで宛先から消す")
  func undoesAllRecentCopyGroupsTogether() async throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = root.appending(path: "A", directoryHint: .isDirectory)
    let second = root.appending(path: "B", directoryHint: .isDirectory)
    let destinationURL = root.appending(path: "C", directoryHint: .isDirectory)
    for folder in [first, second, destinationURL] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    let firstURL = first.appending(path: "first.txt")
    let secondURL = second.appending(path: "second.txt")
    try Data("first".utf8).write(to: firstURL)
    try Data("second".utf8).write(to: secondURL)
    let provider = LocalFileProvider()
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let source = FileBrowserSession(
      provider: provider, initialLocation: FileLocation(localURL: root),
      transferQueue: queue,
      recentFilesService: StubRecentFileSearchService(items: [
        (try provider.item(at: firstURL), Date()),
        (try provider.item(at: secondURL), Date()),
      ]))
    let destination = FileBrowserSession(
      provider: provider, initialLocation: FileLocation(localURL: destinationURL),
      transferQueue: queue)
    let workspace = FileWorkspaceModel(
      initialBrowser: source,
      recentSourceBookmarkReader: RecentSourceBookmarkReader(create: { _ in Data([1]) }))
    source.startRecentFiles(authorizedRoots: [root], accessLeases: [try makeLease(for: root)])
    await waitUntil { !source.isSearching && source.searchResults.count == 2 }
    workspace.activeTab.selectedItemURLs = [firstURL, secondURL]
    workspace.transferSelectedItems(to: destination, wasMove: false)
    await PKPaneTests.waitUntil(timeout: .seconds(5), "2親のコピーが終わらなかった") {
      FileManager.default.fileExists(atPath: destinationURL.appending(path: "first.txt").path)
        && FileManager.default.fileExists(atPath: destinationURL.appending(path: "second.txt").path)
    }
    await waitUntil { workspace.canUndoLastTransfer }

    workspace.undoLastTransfer()
    await PKPaneTests.waitUntil(timeout: .seconds(5), "2親のコピーUndoが終わらなかった") {
      !FileManager.default.fileExists(
        atPath: destinationURL.appending(path: "first.txt").path)
        && !FileManager.default.fileExists(
          atPath: destinationURL.appending(path: "second.txt").path)
    }
    #expect(try Data(contentsOf: firstURL) == Data("first".utf8))
    #expect(try Data(contentsOf: secondURL) == Data("second".utf8))
  }

  @Test("最近の項目の転送準備中に宛先表示を移動しても受付時の場所へ送る")
  func keepsRecentTransferDestinationWhilePreparingBookmark() async throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = root.appending(path: "source", directoryHint: .isDirectory)
    let acceptedDestination = root.appending(path: "C", directoryHint: .isDirectory)
    let laterDestination = root.appending(path: "D", directoryHint: .isDirectory)
    for folder in [sourceURL, acceptedDestination, laterDestination] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    let file = sourceURL.appending(path: "file.txt")
    try Data("source".utf8).write(to: file)
    let provider = LocalFileProvider()
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let source = FileBrowserSession(
      provider: provider, initialLocation: FileLocation(localURL: root),
      transferQueue: queue,
      recentFilesService: StubRecentFileSearchService(items: [
        (try provider.item(at: file), Date())
      ]))
    let destination = FileBrowserSession(
      provider: provider, initialLocation: FileLocation(localURL: acceptedDestination),
      transferQueue: queue)
    let bookmarkStarted = Mutex(false)
    let releaseBookmark = Mutex(false)
    defer { releaseBookmark.withLock { $0 = true } }
    let reader = RecentSourceBookmarkReader(create: { _ in
      bookmarkStarted.withLock { $0 = true }
      while !releaseBookmark.withLock({ $0 }) {
        Thread.sleep(forTimeInterval: 0.005)
      }
      return Data([1])
    })
    let workspace = FileWorkspaceModel(
      initialBrowser: source, recentSourceBookmarkReader: reader)
    source.startRecentFiles(authorizedRoots: [root], accessLeases: [try makeLease(for: root)])
    await waitUntil { !source.isSearching && source.searchResults.count == 1 }
    workspace.activeTab.selectedItemURLs = [file]
    workspace.transferSelectedItems(to: destination, wasMove: false)
    await waitUntil { bookmarkStarted.withLock { $0 } }

    destination.open(location: FileLocation(localURL: laterDestination))
    #expect(destination.currentLocation == FileLocation(localURL: laterDestination))
    releaseBookmark.withLock { $0 = true }

    await PKPaneTests.waitUntil(timeout: .seconds(5), "受付時の宛先への転送が終わらなかった") {
      FileManager.default.fileExists(
        atPath: acceptedDestination.appending(path: "file.txt").path)
    }
    #expect(
      !FileManager.default.fileExists(
        atPath: laterDestination.appending(path: "file.txt").path))
    #expect(
      (await queue.allJobs()).first?.destination == FileLocation(localURL: acceptedDestination))
  }

  @Test("最近の項目の宛先目録が停止しても期限でエラーとなり遅着で転送しない")
  func timesOutStalledRecentDestinationInventory() async throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = root.appending(path: "source", directoryHint: .isDirectory)
    let destinationURL = root.appending(path: "destination", directoryHint: .isDirectory)
    for folder in [sourceURL, destinationURL] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    let file = sourceURL.appending(path: "file.txt")
    try Data("source".utf8).write(to: file)
    try Data().write(to: destinationURL.appending(path: "marker.txt"))
    let sourceProvider = LocalFileProvider()
    let destinationProvider = StalledRecentDestinationProvider()
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let source = FileBrowserSession(
      provider: sourceProvider, initialLocation: FileLocation(localURL: root),
      transferQueue: queue,
      recentFilesService: StubRecentFileSearchService(items: [
        (try sourceProvider.item(at: file), Date())
      ]))
    let destination = FileBrowserSession(
      provider: destinationProvider, initialLocation: FileLocation(localURL: destinationURL),
      transferQueue: queue)
    let workspace = FileWorkspaceModel(
      initialBrowser: source,
      recentSourceBookmarkReader: RecentSourceBookmarkReader(create: { _ in Data([1]) }),
      recentDestinationInventoryTimeout: .milliseconds(50))
    destination.load()
    await waitUntil { !destination.isLoading && !destination.items.isEmpty }
    source.startRecentFiles(authorizedRoots: [root], accessLeases: [try makeLease(for: root)])
    await waitUntil { !source.isSearching && source.searchResults.count == 1 }
    workspace.activeTab.selectedItemURLs = [file]
    destinationProvider.blockNextListing()
    workspace.transferSelectedItems(to: destination, wasMove: false)
    await waitUntil { destinationProvider.isListingBlocked }
    await waitUntil { destination.errorMessage != nil }

    #expect((await queue.allJobs()).isEmpty)
    #expect(try Data(contentsOf: file) == Data("source".utf8))
    #expect(
      !FileManager.default.fileExists(
        atPath: destinationURL.appending(path: "file.txt").path))

    destinationProvider.releaseListing()
    try await Task.sleep(for: .milliseconds(100))
    #expect((await queue.allJobs()).isEmpty)
    #expect(
      !FileManager.default.fileExists(
        atPath: destinationURL.appending(path: "file.txt").path))
  }

  @Test(
    "最近の項目をコピー/カット後に別フォルダへ移っても実親から貼り付ける",
    arguments: [false, true], [false, true])
  func pastesRecentClipboardAfterBrowserReplacement(
    wasMove: Bool, backgroundIsSource: Bool
  ) async throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let approved = root.appending(path: "approved", directoryHint: .isDirectory)
    let background =
      backgroundIsSource
      ? approved
      : root.appending(path: "background", directoryHint: .isDirectory)
    let destinationURL = root.appending(path: "destination", directoryHint: .isDirectory)
    for folder in [background, approved, destinationURL] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    let file = approved.appending(path: "source.txt")
    try Data("source".utf8).write(to: file)
    let provider = LocalFileProvider()
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let item = try provider.item(at: file)
    let source = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: background), transferQueue: queue,
      recentFilesService: StubRecentFileSearchService(items: [(item, Date())]))
    let destination = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: destinationURL), transferQueue: queue)
    let workspace = FileWorkspaceModel(
      initialBrowser: source, fileClipboard: MemoryFileClipboard(),
      recentSourceBookmarkReader: RecentSourceBookmarkReader(create: { _ in Data([1]) }))
    source.startRecentFiles(
      authorizedRoots: [approved], accessLeases: [try makeLease(for: approved)])
    await waitUntil { !source.isSearching && source.searchResults.count == 1 }
    workspace.activeTab.selectedItemURLs = [file]
    if wasMove { workspace.cutSelectedItems() } else { workspace.copySelectedItems() }

    workspace.replaceActiveBrowser(with: destination)
    destination.load()
    await waitUntil { !destination.isLoading }
    workspace.pasteItems()
    await PKPaneTests.waitUntil(
      timeout: .seconds(5), "最近の項目からの貼り付けが終わらなかった"
    ) {
      FileManager.default.fileExists(
        atPath: destinationURL.appending(path: "source.txt").path)
        && (!wasMove || !FileManager.default.fileExists(atPath: file.path))
    }
    #expect(!wasMove || !workspace.canPasteItems(to: destination))
    #expect((await queue.allJobs()).count == 1)
  }

  @Test("転送元ブックマークを保存できない場合は元ファイルを保ちジョブを作らない")
  func doesNotStartUnrestorableRecentTransfer() async throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let approved = root.appending(path: "approved", directoryHint: .isDirectory)
    let destinationURL = root.appending(path: "destination", directoryHint: .isDirectory)
    for folder in [approved, destinationURL] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    let file = approved.appending(path: "source.txt")
    try Data().write(to: file)
    let provider = LocalFileProvider()
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let source = FileBrowserSession(
      provider: provider, initialLocation: FileLocation(localURL: root),
      transferQueue: queue,
      recentFilesService: StubRecentFileSearchService(items: [
        (try provider.item(at: file), Date())
      ]))
    let destination = FileBrowserSession(
      provider: provider, initialLocation: FileLocation(localURL: destinationURL),
      transferQueue: queue)
    let workspace = FileWorkspaceModel(
      initialBrowser: source,
      recentSourceBookmarkReader: RecentSourceBookmarkReader(create: { _ in
        throw CocoaError(.fileReadNoPermission)
      }))
    source.startRecentFiles(
      authorizedRoots: [approved], accessLeases: [try makeLease(for: approved)])
    await waitUntil { !source.isSearching && source.searchResults.count == 1 }
    workspace.activeTab.selectedItemURLs = [file]

    workspace.transferSelectedItems(to: destination, wasMove: true)
    await waitUntil { source.errorMessage != nil }

    #expect((await queue.allJobs()).isEmpty)
    #expect(FileManager.default.fileExists(atPath: file.path))
    #expect(
      !FileManager.default.fileExists(
        atPath: destinationURL.appending(path: "source.txt").path))
  }

  @Test("退役した最近一覧からの貼り付け準備失敗を表示中の宛先へ知らせる")
  func reportsBookmarkFailureAtVisibleClipboardDestination() async throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let approved = root.appending(path: "approved", directoryHint: .isDirectory)
    let destinationURL = root.appending(path: "destination", directoryHint: .isDirectory)
    for folder in [approved, destinationURL] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    let file = approved.appending(path: "source.txt")
    try Data("source".utf8).write(to: file)
    let provider = LocalFileProvider()
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let source = FileBrowserSession(
      provider: provider, initialLocation: FileLocation(localURL: root),
      transferQueue: queue,
      recentFilesService: StubRecentFileSearchService(items: [
        (try provider.item(at: file), Date())
      ]))
    let destination = FileBrowserSession(
      provider: provider, initialLocation: FileLocation(localURL: destinationURL),
      transferQueue: queue)
    let workspace = FileWorkspaceModel(
      initialBrowser: source, fileClipboard: MemoryFileClipboard(),
      recentSourceBookmarkReader: RecentSourceBookmarkReader(create: { _ in
        throw CocoaError(.fileReadNoPermission)
      }))
    source.startRecentFiles(
      authorizedRoots: [approved], accessLeases: [try makeLease(for: approved)])
    await waitUntil { !source.isSearching && source.searchResults.count == 1 }
    workspace.activeTab.selectedItemURLs = [file]
    workspace.copySelectedItems()
    workspace.replaceActiveBrowser(with: destination)
    workspace.pasteItems()
    await waitUntil { destination.errorMessage != nil }

    #expect((await queue.allJobs()).isEmpty)
    #expect(try Data(contentsOf: file) == Data("source".utf8))
    #expect(
      !FileManager.default.fileExists(
        atPath: destinationURL.appending(path: "source.txt").path))
  }

  @Test("最近一覧を閉じても退役セッションが転送元の許可を保持する")
  func retainsSourceLeaseAfterRetirement() throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let stops = Mutex(0)
    let manager = FolderBookmarkAccessManager(
      startAccess: { _ in true },
      stopAccess: { _ in stops.withLock { $0 += 1 } },
      isSandboxed: { true }, canReadDirectory: { _ in true })
    var lease: WorkspaceBookmarkAccessLease? = try WorkspaceBookmarkAccessLease(
      url: root, manager: manager, requiresSecurityScope: true)
    let session = makeSession(root: root, service: StubRecentFileSearchService(items: []))

    session.startRecentFiles(authorizedRoots: [root], accessLeases: [try #require(lease)])
    lease = nil
    session.retireFromBrowsing {}

    #expect(stops.withLock { $0 == 0 })
  }

  @Test("属性照会が期限切れでも最近検索を待たせ続けない")
  func boundsBlockedPathValidation() async {
    let root = URL(filePath: "/allowed", directoryHint: .isDirectory)
    let validator = RecentFilePathValidator(
      timeout: .milliseconds(10),
      resolve: { url in
        Thread.sleep(forTimeInterval: 0.1)
        return url
      },
      isFile: { _ in true })
    let record = RecentMetadataRecord(
      url: root.appending(path: "slow.txt"), lastUsedAt: Date(),
      isDirectory: false, size: nil)

    let result = await validator.filter([record], roots: [root])
    let degraded = await validator.filter([record], roots: [root])

    #expect(result.isEmpty)
    #expect(degraded.isEmpty)
  }

  @Test("転送元ブックマーク生成が期限切れなら転送を始めない")
  func boundsBlockedBookmarkCreation() async {
    let reader = RecentSourceBookmarkReader(
      timeout: .milliseconds(10),
      create: { _ in
        Thread.sleep(forTimeInterval: 0.1)
        return Data([1])
      })
    let root = URL(filePath: "/tmp/slow-bookmark", directoryHint: .isDirectory)

    #expect(await reader.bookmark(for: root) == nil)
    #expect(await reader.bookmark(for: root) == nil)
  }

  @Test("最近ファイル検索は許可範囲外・リンク越し・フォルダを公開しない")
  func excludesUnapprovedAndDirectoryResults() async throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let outside = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: outside) }
    let safe = root.appending(path: "safe.txt")
    let secret = outside.appending(path: "secret.txt")
    let link = root.appending(path: "linked.txt")
    try Data().write(to: safe)
    try Data().write(to: secret)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
    let now = Date()
    let metadata = FakeRecentMetadataQuery(records: [
      RecentMetadataRecord(url: secret, lastUsedAt: now, isDirectory: false, size: nil),
      RecentMetadataRecord(url: link, lastUsedAt: now, isDirectory: false, size: nil),
      RecentMetadataRecord(url: root, lastUsedAt: now, isDirectory: true, size: nil),
      RecentMetadataRecord(url: safe, lastUsedAt: now, isDirectory: false, size: nil),
      RecentMetadataRecord(url: safe, lastUsedAt: now, isDirectory: false, size: nil),
    ])

    let updates = await collect(
      RecentFilesService(makeQuery: { metadata }).search(
        authorizedRoots: [root], generation: UUID()))

    #expect(resultURLs(in: updates) == [safe])
    #expect(metadata.receivedRoots == [root])
  }

  @Test("最近ファイル検索は上限で終了し、終了時にメタデータクエリを止める")
  func enforcesLimitAndStopsQuery() async throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = (0..<3).map { root.appending(path: "\($0).txt") }
    for file in files { try Data().write(to: file) }
    let metadata = FakeRecentMetadataQuery(
      records: files.map {
        RecentMetadataRecord(url: $0, lastUsedAt: Date(), isDirectory: false, size: nil)
      })
    let generation = UUID()

    let updates = await collect(
      RecentFilesService(
        makeQuery: { metadata }, resultLimit: 2, scanLimit: 3
      ).search(authorizedRoots: [root], generation: generation))

    #expect(resultURLs(in: updates).count == 2)
    #expect(updates.contains(.limitReached(.results(2), generation: generation)))
    #expect(metadata.stopCallCount > 0)
  }

  @Test("Spotlight収集中に期限が来ても蓄積済み候補を公開する")
  func publishesGatheredResultsAtTimeout() async throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "partial.txt")
    try Data().write(to: file)
    let metadata = FakeRecentMetadataQuery(
      records: [
        RecentMetadataRecord(
          url: file, lastUsedAt: Date(), isDirectory: false, size: nil)
      ],
      finishesAutomatically: false)

    let updates = await collect(
      RecentFilesService(
        makeQuery: { metadata }, gatheringTimeout: .milliseconds(20)
      ).search(authorizedRoots: [root], generation: UUID()))

    #expect(resultURLs(in: updates) == [file])
    #expect(metadata.stopCallCount > 0)
  }

  @Test("実NSMetadataQueryへ許可URL範囲と使用日時条件を設定して停止できる")
  func configuresActualMetadataQueryWithinTemporaryScope() throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let rawQuery = NSMetadataQuery()
    let adapter = RecentMetadataQueryAdapter(query: rawQuery)

    _ = adapter.gather(roots: [root], resultLimit: 2)

    #expect(rawQuery.isStarted)
    #expect((rawQuery.searchScopes as? [URL]) == [root])
    #expect(rawQuery.sortDescriptors.first?.key == "kMDItemLastUsedDate")
    #expect(
      rawQuery.predicate?.evaluate(
        with: ["kMDItemLastUsedDate": Date()]) == true)
    #expect(rawQuery.predicate?.evaluate(with: [:]) == false)
    adapter.stop()
    #expect(rawQuery.isStopped)
  }

  @Test("最近ファイル検索の取消でメタデータクエリを停止する")
  func cancelsMetadataQuery() async throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let metadata = FakeRecentMetadataQuery(records: [], finishesAutomatically: false)
    let service = RecentFilesService(makeQuery: { metadata })
    let consumer = Task {
      for await _ in service.search(authorizedRoots: [root], generation: UUID()) {}
    }
    await waitUntil { metadata.receivedRoots == [root] }

    consumer.cancel()
    _ = await consumer.result

    await waitUntil { metadata.stopCallCount > 0 }
  }

  @Test("最近の項目は使用日時順に表示し、通常の検索とは区別する")
  func presentsRecentFilesInUsageOrder() async throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let older = FileItem(url: root.appending(path: "a.txt"), isDirectory: false)
    let newer = FileItem(url: root.appending(path: "z.txt"), isDirectory: false)
    let service = StubRecentFileSearchService(items: [
      (older, Date(timeIntervalSince1970: 100)),
      (newer, Date(timeIntervalSince1970: 200)),
    ])
    let session = makeSession(root: root, service: service)

    session.startRecentFiles(authorizedRoots: [root], accessLeases: [try makeLease(for: root)])
    await waitUntil { !session.isSearching && session.searchResults.count == 2 }

    #expect(session.isRecentFilesActive)
    #expect(session.searchText.isEmpty)
    #expect(
      session.displayItems(
        matching: "", sortOrder: .name, ascending: true, includesHiddenItems: false
      ) == [newer, older])
    session.setSearchScope(.thisMac)
    session.setSearchUsesRegex(true)
    #expect(session.isRecentFilesActive)
    #expect(session.searchResults.map(\.item) == [newer, older])
  }

  @Test("最近の項目から親を開いたあと戻ると最近の項目へ戻る")
  func restoresRecentsAfterRevealingAFile() async throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appending(path: "nested", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appending(path: "note.txt")
    try Data().write(to: file)
    let item = try LocalFileProvider().item(at: file)
    let session = makeSession(
      root: root,
      service: StubRecentFileSearchService(items: [(item, Date())]))

    session.startRecentFiles(authorizedRoots: [root], accessLeases: [try makeLease(for: root)])
    await waitUntil { !session.isSearching && session.searchResults.count == 1 }
    session.revealSearchResult(item)
    await waitUntil { session.currentLocation.localURL == folder && !session.isLoading }
    #expect(session.canGoBack)

    session.goBack()
    await waitUntil { session.isRecentFilesActive && !session.isSearching }
    #expect(session.searchResults.map(\.item) == [item])
  }

  @Test("空の認可範囲では最近ファイル検索を起動しない")
  func doesNotSearchWithoutAuthorizedRoots() throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = StubRecentFileSearchService(items: [])
    let session = makeSession(root: root, service: service)

    session.startRecentFiles(authorizedRoots: [])

    #expect(!service.didStart)
    #expect(!session.isRecentFilesActive)
  }

  @Test("最近の項目を表示中は背後のフォルダを新規作成や転送先にしない")
  func preventsWritesToHiddenCurrentDirectory() throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = makeSession(root: root, service: StubRecentFileSearchService(items: []))
    let workspace = FileWorkspaceModel(initialBrowser: session)

    session.startRecentFiles(authorizedRoots: [root], accessLeases: [try makeLease(for: root)])
    session.createDirectory(named: "unexpected")

    #expect(!FileManager.default.fileExists(atPath: root.appending(path: "unexpected").path))
    #expect(!session.canTransferItems(to: session, removesSourceAfterCopy: false))
    #expect(!workspace.canPasteItems(to: session))
    #expect(!workspace.canCompareFolders)
  }

  @Test("別の親フォルダにまたがる最近の項目を一括リネームしない")
  func rejectsBatchRenameAcrossRecentParents() async throws {
    let root = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = root.appending(path: "first", directoryHint: .isDirectory)
    let second = root.appending(path: "second", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    let firstURL = first.appending(path: "a.txt")
    let secondURL = second.appending(path: "b.txt")
    try Data().write(to: firstURL)
    try Data().write(to: secondURL)
    let firstItem = try LocalFileProvider().item(at: firstURL)
    let secondItem = try LocalFileProvider().item(at: secondURL)
    let session = makeSession(
      root: root,
      service: StubRecentFileSearchService(items: [
        (firstItem, Date()), (secondItem, Date()),
      ]))
    session.startRecentFiles(authorizedRoots: [root], accessLeases: [try makeLease(for: root)])

    let result = await session.batchRename([
      (item: firstItem, newName: "renamed.txt"),
      (item: secondItem, newName: "renamed.txt"),
    ])

    #expect(result.successes.isEmpty)
    #expect(result.failures.count == 2)
    #expect(FileManager.default.fileExists(atPath: firstURL.path))
    #expect(FileManager.default.fileExists(atPath: secondURL.path))
  }

  private func makeSession(
    root: URL,
    service: StubRecentFileSearchService
  ) -> FileBrowserSession {
    let provider = LocalFileProvider()
    return FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(directoryURL: root, providerID: provider.id),
      transferQueue: .isolatedForTesting(),
      recentFilesService: service)
  }

  private func makeDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "pkpane-recent-files-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func makeLease(for root: URL) throws -> WorkspaceBookmarkAccessLease {
    let manager = FolderBookmarkAccessManager(
      startAccess: { _ in true },
      stopAccess: { _ in },
      isSandboxed: { true },
      canReadDirectory: { _ in true })
    return try WorkspaceBookmarkAccessLease(
      url: root, manager: manager, requiresSecurityScope: true)
  }

  private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
    await PKPaneTests.waitUntil(timeout: .seconds(2), "最近の項目が期限内に更新されなかった") {
      condition()
    }
  }
}

@MainActor
private final class FakeRecentMetadataQuery: RecentMetadataQuerying {
  let records: [RecentMetadataRecord]
  let finishesAutomatically: Bool
  private var continuation: AsyncStream<RecentMetadataUpdate>.Continuation?
  private(set) var receivedRoots = [URL]()
  private(set) var stopCallCount = 0

  init(records: [RecentMetadataRecord], finishesAutomatically: Bool = true) {
    self.records = records
    self.finishesAutomatically = finishesAutomatically
  }

  func gather(roots: [URL], resultLimit: Int) -> AsyncStream<RecentMetadataUpdate> {
    receivedRoots = roots
    return AsyncStream { continuation in
      self.continuation = continuation
      if finishesAutomatically {
        continuation.yield(.records(Array(records.prefix(resultLimit))))
        continuation.finish()
      }
    }
  }

  func finishWithPartialResults() async {
    continuation?.yield(.records(records))
    continuation?.finish()
    continuation = nil
  }

  func stop() {
    stopCallCount += 1
    continuation?.finish()
    continuation = nil
  }
}

private func collect(_ stream: AsyncStream<SearchUpdate>) async -> [SearchUpdate] {
  var updates = [SearchUpdate]()
  for await update in stream { updates.append(update) }
  return updates
}

private func resultURLs(in updates: [SearchUpdate]) -> [URL] {
  updates.flatMap { update in
    if case .results(let results, _) = update { return results.map(\.item.url) }
    return []
  }
}

private final class StubRecentFileSearchService: RecentFileSearching, @unchecked Sendable {
  private let items: [(FileItem, Date)]
  private let starts = Mutex(0)

  init(items: [(FileItem, Date)]) { self.items = items }

  var didStart: Bool { starts.withLock { $0 > 0 } }

  func search(authorizedRoots: [URL], generation: UUID) -> AsyncStream<SearchUpdate> {
    starts.withLock { $0 += 1 }
    return AsyncStream { continuation in
      continuation.yield(
        .results(
          items.map { item, date in
            SearchResult(
              item: item,
              parent: item.location.deletingLastPathComponent()
                ?? FileLocation(localURL: authorizedRoots[0]),
              providerID: .local,
              generation: generation,
              lastUsedAt: date)
          }, generation: generation))
      continuation.yield(.finished(generation))
      continuation.finish()
    }
  }
}

private final class StalledRecentDestinationProvider: FileBrowserProvider, @unchecked Sendable {
  private let wrapped = LocalFileProvider()
  private let blockNext = Mutex(false)
  private let blocked = Mutex(false)
  private let pending = Mutex<CheckedContinuation<Void, Never>?>(nil)

  var id: FileProviderID { wrapped.id }
  var connectionID: FileProviderConnectionID? { wrapped.connectionID }
  var capabilities: FileProviderCapabilities { wrapped.capabilities }
  var isListingBlocked: Bool { blocked.withLock { $0 } }

  func blockNextListing() { blockNext.withLock { $0 = true } }

  func releaseListing() {
    let continuation = pending.withLock { pending -> CheckedContinuation<Void, Never>? in
      defer { pending = nil }
      return pending
    }
    continuation?.resume()
  }

  func contents(of location: FileLocation) async throws -> [FileItem] {
    let shouldBlock = blockNext.withLock { next in
      defer { next = false }
      return next
    }
    if shouldBlock {
      await withCheckedContinuation { continuation in
        pending.withLock { $0 = continuation }
        blocked.withLock { $0 = true }
      }
    }
    return try await wrapped.contents(of: location)
  }

  func parent(of location: FileLocation) -> FileLocation? { wrapped.parent(of: location) }

  func breadcrumbs(
    for location: FileLocation, constrainedTo root: FileLocation?
  ) -> [FileBrowserBreadcrumb] {
    wrapped.breadcrumbs(for: location, constrainedTo: root)
  }
}

private struct FixedRecentBookmarkCodec: FolderBookmarkCoding {
  let url: URL

  func createBookmark(for _: URL) throws -> Data { Data([1]) }

  func resolveBookmark(_ data: Data) throws -> ResolvedFolderBookmark {
    ResolvedFolderBookmark(url: url, isStale: false)
  }
}
