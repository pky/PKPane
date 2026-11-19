import Foundation
import Synchronization
import Testing

@testable import PKPane

@MainActor
struct TransferConflictResolutionTests {
  @Test("公開copy/moveの祖先宛先の個別置換は元と祖先の内容を削除しない", arguments: [true, false])
  func rejectsAncestorReplacementThroughQueue(isMove: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let outer = root.appending(path: "A")
    let parent = outer.appending(path: "B")
    let inner = parent.appending(path: "A")
    try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
    let leaf = inner.appending(path: "leaf.txt")
    try Data("source".utf8).write(to: leaf)
    let old = outer.appending(path: "old.txt")
    try Data("destination".utf8).write(to: old)
    let queue = TransferQueue.isolatedForTesting()
    let source = FileBrowserSession(
      provider: LocalFileProvider(), initialLocation: FileLocation(localURL: parent),
      transferQueue: queue)
    let destination = FileBrowserSession(
      provider: LocalFileProvider(), initialLocation: FileLocation(localURL: root),
      transferQueue: queue)
    defer {
      source.invalidate()
      destination.invalidate()
    }
    source.load()
    destination.load()
    await waitUntil { !source.isLoading && !destination.isLoading && source.items.count == 1 }
    if isMove {
      source.move(source.items, to: destination)
    } else {
      source.copy(source.items, to: destination)
    }
    #expect(source.pendingTransferConflict != nil)
    source.resolvePendingTransferConflict(.replace)
    await waitUntil { !source.isTransferring }
    let jobs = await queue.allJobs()
    #expect(try #require(jobs.first).state == .failed)
    #expect(try Data(contentsOf: leaf) == Data("source".utf8))
    #expect(try Data(contentsOf: old) == Data("destination".utf8))
  }

  @Test("展開項目を自身の親へ公開moveして置換しても元を保持し、復元後も削除しない")
  func keepsExpandedItemAndRestoredReplacementAtItsOwnParent() async throws {
    let fixture = try await ConflictFixture.make(
      sourceNames: [], destinationNames: [], sourceDirectories: ["tree"])
    defer { fixture.cleanup() }
    let parent = FileLocation(localURL: fixture.sourceRoot.appending(path: "tree"))
    let fileURL = fixture.sourceRoot.appending(path: "tree/new-only.txt")
    let child = FileItem(url: fileURL, isDirectory: false)
    let destination = FileBrowserSession(
      provider: LocalFileProvider(), initialLocation: parent, transferQueue: fixture.queue)
    defer { destination.invalidate() }
    destination.load()
    await waitUntil { !destination.isLoading && destination.items.count == 1 }
    fixture.source.move([child], to: destination)
    #expect(fixture.source.pendingTransferConflict != nil)
    fixture.source.resolvePendingTransferConflict(.replace)
    #expect(try await fixture.finishedJob().state == .completed)
    #expect(try Data(contentsOf: fileURL) == Data("new".utf8))

    var stored = TransferJob(
      kind: .move, items: [child], sourceProviderID: .local,
      destinationProviderID: .local, destination: parent)
    stored.items = [TransferJob.Item(child, options: TransferItemOptions(replacingExisting: true))]
    stored.state = .interrupted
    let store = InMemoryTransferJobStore()
    try store.save([stored])
    let queue = TransferQueue(store: store)
    let restored = FileBrowserSession(
      provider: LocalFileProvider(), initialLocation: fixture.source.currentLocation,
      transferQueue: queue)
    let restoredDestination = FileBrowserSession(
      provider: LocalFileProvider(), initialLocation: parent, transferQueue: queue)
    defer {
      restored.invalidate()
      restoredDestination.invalidate()
    }
    #expect(restored.prepareTransferRetry(stored, to: restoredDestination))
    restored.retryLastTransfer()
    await waitUntil { !restored.isTransferring }
    let jobs = await queue.allJobs()
    #expect(try #require(jobs.first).state == .completed)
    #expect(try Data(contentsOf: fileURL) == Data("new".utf8))
  }

  @Test("本番衝突探索は多数の衝突と非衝突の混在を線形照合し、個別判断を維持する")
  func checksLargeMixedInventoryThroughPublicCopy() async throws {
    let provider = LargeConflictInventoryProvider()
    let queue = TransferQueue.isolatedForTesting()
    let source = FileBrowserSession(
      provider: provider, initialLocation: provider.source, transferQueue: queue)
    let destination = FileBrowserSession(
      provider: provider, initialLocation: provider.destination, transferQueue: queue)
    defer {
      source.invalidate()
      destination.invalidate()
    }
    source.load()
    destination.load()
    await waitUntil { source.items.count == 10_000 && destination.items.count == 10_000 }
    source.copy(source.items, to: destination)
    #expect(source.pendingTransferConflict?.totalCount == 5_000)
    #expect(source.pendingTransferConflict?.remainingNames.count == 3)
    let inventory = FileBrowserSession.firstTransferConflict(
      in: source.items, destinationItems: destination.items)
    #expect(inventory.nameLookupCount == 20_000)
    source.resolvePendingTransferConflict(.replace)
    #expect(source.pendingTransferConflict?.remainingCount == 4_999)
    #expect(await queue.allJobs().isEmpty)
    source.resolvePendingTransferConflict(.skip)
    #expect(source.pendingTransferConflict?.remainingCount == 4_998)
    source.resolvePendingTransferConflict(.cancel)
    #expect(await queue.allJobs().isEmpty)
  }

  @Test("多数の衝突説明は前方3件に限定し、全件数は別に保持する")
  func boundsPresentedNames() async throws {
    let names = (0..<10).map { "item-\($0).txt" }
    let fixture = try await ConflictFixture.make(sourceNames: names, destinationNames: names)
    defer { fixture.cleanup() }
    fixture.source.copy(fixture.source.items, to: fixture.destination)
    let conflict = try #require(fixture.source.pendingTransferConflict)
    #expect(conflict.totalCount == 10)
    #expect(conflict.remainingCount == 10)
    #expect(conflict.remainingNames.count == 3)
    fixture.source.resolvePendingTransferConflict(.cancel)
  }

  @Test("フォルダ置換の警告は個別と全件の範囲を区別し、別名のフォルダは旧内容を保持する")
  func scopesDirectoryWarningsAndKeepsBothTrees() async throws {
    let fixture = try await ConflictFixture.make(
      sourceNames: ["a.txt"], destinationNames: ["a.txt"],
      sourceDirectories: ["z"], destinationDirectories: ["z"])
    defer { fixture.cleanup() }
    fixture.source.copy(fixture.source.items, to: fixture.destination)
    let first = try #require(fixture.source.pendingTransferConflict)
    #expect(!first.replacesDirectory)
    #expect(first.remainingReplacesDirectory)
    #expect(first.replacementWarning(applyToRemaining: false).isEmpty)
    #expect(!first.replacementWarning(applyToRemaining: true).isEmpty)
    fixture.source.resolvePendingTransferConflict(.replace)
    let folder = try #require(fixture.source.pendingTransferConflict)
    #expect(folder.replacesDirectory)
    #expect(!folder.replacementWarning(applyToRemaining: false).isEmpty)
    fixture.source.resolvePendingTransferConflict(.keepBoth)
    #expect(try await fixture.finishedJob().state == .completed)
    #expect(try fixture.data("z/old-only.txt") == Data("old".utf8))
    #expect(try fixture.data("zのコピー/new-only.txt") == Data("new".utf8))
    #expect(try fixture.temporaryNames().isEmpty)
  }

  @Test("上書きは旧内容を保存しないためUndoを提供しない")
  func disablesUndoAfterReplacement() async throws {
    let fixture = try await ConflictFixture.make(
      sourceNames: ["report.txt"], destinationNames: ["report.txt"])
    defer { fixture.cleanup() }
    let workspace = FileWorkspaceModel(initialBrowser: fixture.source)
    workspace.activatePane(.secondary)
    workspace.replaceActiveBrowser(with: fixture.destination)
    workspace.activatePane(.primary)
    workspace.selectItems(Set(fixture.source.items.map(\.url)), in: .primary)
    workspace.transferSelectedItems(to: fixture.destination, wasMove: false)
    fixture.source.resolvePendingTransferConflict(.replace)
    await waitUntil { fixture.source.lastCompletedTransfer != nil }
    #expect(!workspace.canUndoLastTransfer)
    #expect(try fixture.data("report.txt") == Data("new-report.txt".utf8))
  }

  @Test("FTPの未対応STOUは公開経路と復元後実行の両方で安全拒否し、通常書込へ戻らない")
  func rejectsUnsafeFTPNamedCommit() async throws {
    let fixture = try await ConflictFixture.make(sourceNames: ["report.txt"], destinationNames: [])
    defer { fixture.cleanup() }
    let session = NonReplacingFTPSession()
    let target = try FTPConnectionTarget(host: "example.invalid", username: "fixture")
    let provider = FTPFileProvider(target: target, session: session, sessionFactory: { session })
    let store = InMemoryTransferJobStore()
    let destination = FileBrowserSession(
      provider: provider, initialLocation: FileLocation(remotePath: "/", providerID: provider.id),
      transferQueue: fixture.queue)
    destination.load()
    await waitUntil { !destination.isLoading && destination.items.count == 1 }
    fixture.source.copy(fixture.source.items, to: destination)
    #expect(fixture.source.pendingTransferConflict?.canKeepBoth == true)
    fixture.source.resolvePendingTransferConflict(.keepBoth)
    #expect(try await fixture.finishedJob().state == .failed)
    #expect(fixture.source.pendingTransferConflict == nil)

    var job = TransferJob(
      kind: .copy, items: fixture.source.items, sourceProviderID: .local,
      destinationProviderID: provider.id, destination: destination.currentLocation)
    job.items = fixture.source.items.map {
      TransferJob.Item($0, options: TransferItemOptions(destinationName: "reportのコピー.txt"))
    }
    job.state = .interrupted
    try store.save([job])
    let queue = TransferQueue(store: store)
    let source = FileBrowserSession(
      provider: LocalFileProvider(), initialLocation: fixture.source.currentLocation,
      transferQueue: queue)
    let restoredDestination = FileBrowserSession(
      provider: provider, initialLocation: destination.currentLocation, transferQueue: queue)
    #expect(source.prepareTransferRetry(job, to: restoredDestination))
    source.retryLastTransfer()
    await waitUntil { (await queue.allJobs()).first?.state == .failed && !source.isTransferring }
    #expect(session.mutationCount.withLock { $0 } == 0)
    #expect(
      await queue.allJobs().first?.items.first?.transferOptions.destinationName == "reportのコピー.txt")
    destination.invalidate()
    restoredDestination.invalidate()
    source.invalidate()
  }

  @Test("最初の置換確認は次の衝突を許可せず、個別スキップと新規項目を単一ジョブへ渡す")
  func resolvesOnlyTheCurrentCollision() async throws {
    let fixture = try await ConflictFixture.make(
      sourceNames: ["a.txt", "b.txt", "c.txt"], destinationNames: ["a.txt", "b.txt"])
    defer { fixture.cleanup() }
    fixture.source.copy(fixture.source.items, to: fixture.destination)
    #expect(fixture.source.pendingTransferConflict?.totalCount == 2)
    fixture.source.resolvePendingTransferConflict(.replace)
    #expect(fixture.source.pendingTransferConflict?.destinationName == "b.txt")
    #expect(await fixture.queue.allJobs().isEmpty)
    fixture.source.resolvePendingTransferConflict(.skip)
    let job = try await fixture.finishedJob()
    #expect(job.state == .completed)
    #expect(job.skippedItemCount == 1)
    #expect(job.items.map(\.name) == ["a.txt", "c.txt"])
    #expect(try fixture.data("a.txt") == Data("new-a.txt".utf8))
    #expect(try fixture.data("b.txt") == Data("old-b.txt".utf8))
    #expect(try fixture.data("c.txt") == Data("new-c.txt".utf8))
    #expect(await fixture.queue.allJobs().count == 1)
  }

  @Test("全件置換は残りすべてへの明示指定がある場合だけ適用する")
  func explicitlyReplacesRemainingCollisions() async throws {
    let fixture = try await ConflictFixture.make(
      sourceNames: ["a.txt", "b.txt"], destinationNames: ["a.txt", "b.txt"])
    defer { fixture.cleanup() }
    fixture.source.copy(fixture.source.items, to: fixture.destination)
    fixture.source.resolvePendingTransferConflict(.replace, applyToRemaining: true)
    let job = try await fixture.finishedJob()
    #expect(job.state == .completed)
    #expect(job.items.allSatisfy { $0.transferOptions.replacingExisting })
    #expect(try fixture.data("b.txt") == Data("new-b.txt".utf8))
  }

  @Test("未解決の衝突で取消すると、それまでに選んだ置換も実行しない")
  func cancelsAllPendingChoices() async throws {
    let fixture = try await ConflictFixture.make(
      sourceNames: ["a.txt", "b.txt"], destinationNames: ["a.txt", "b.txt"])
    defer { fixture.cleanup() }
    fixture.source.copy(fixture.source.items, to: fixture.destination)
    fixture.source.resolvePendingTransferConflict(.replace)
    fixture.source.resolvePendingTransferConflict(.cancel)
    #expect(fixture.source.pendingTransferConflict == nil)
    #expect(await fixture.queue.allJobs().isEmpty)
    #expect(try fixture.data("a.txt") == Data("old-a.txt".utf8))
  }

  @Test("全件スキップは空ジョブを作らず結果を通知する")
  func skipsEveryItemWithoutEmptyJob() async throws {
    let fixture = try await ConflictFixture.make(
      sourceNames: ["a.txt"], destinationNames: ["a.txt"])
    defer { fixture.cleanup() }
    fixture.source.copy(fixture.source.items, to: fixture.destination)
    fixture.source.resolvePendingTransferConflict(.skip, applyToRemaining: true)
    #expect(await fixture.queue.allJobs().isEmpty)
    #expect(fixture.source.transferResolutionNotice != nil)
    #expect(try fixture.data("a.txt") == Data("old-a.txt".utf8))
  }

  @Test("別名保持は本番キュー経由で元と旧宛先を保持し、一時フォルダを掃除する")
  func keepsBothFilesThroughTheQueue() async throws {
    let fixture = try await ConflictFixture.make(
      sourceNames: ["report.txt"], destinationNames: ["report.txt"])
    defer { fixture.cleanup() }
    fixture.source.copy(fixture.source.items, to: fixture.destination)
    #expect(fixture.source.pendingTransferConflict?.canKeepBoth == true)
    fixture.source.resolvePendingTransferConflict(.keepBoth)
    let job = try await fixture.finishedJob()
    #expect(job.state == .completed)
    #expect(job.items.first?.transferOptions.destinationName == "reportのコピー.txt")
    #expect(try fixture.data("report.txt") == Data("old-report.txt".utf8))
    #expect(try fixture.data("reportのコピー.txt") == Data("new-report.txt".utf8))
    #expect(
      FileManager.default.fileExists(atPath: fixture.sourceRoot.appending(path: "report.txt").path))
    #expect(try fixture.temporaryNames().isEmpty)
  }

  @Test("別名候補への外部追加は既存を消さず失敗し、再試行でも元の名前へ戻らない")
  func rejectsCollisionAtCommitAndPreservesRetryName() async throws {
    let provider = ConflictLocalProvider(addCollisionAtCommit: true)
    let fixture = try await ConflictFixture.make(
      sourceNames: ["report.txt"], destinationNames: ["report.txt"], provider: provider)
    defer { fixture.cleanup() }
    fixture.source.copy(fixture.source.items, to: fixture.destination)
    fixture.source.resolvePendingTransferConflict(.keepBoth)
    let failed = try await fixture.finishedJob()
    #expect(failed.state == .failed)
    #expect(failed.items.first?.transferOptions.destinationName == "reportのコピー.txt")
    #expect(try fixture.data("reportのコピー.txt") == Data("external".utf8))
    #expect(try fixture.temporaryNames().isEmpty)
    fixture.source.retryLastTransfer()
    await waitUntil {
      !(await fixture.queue.allJobs()).contains { !$0.state.isTerminal }
        && !fixture.source.isTransferring
    }
    #expect(try fixture.data("report.txt") == Data("old-report.txt".utf8))
    #expect(try fixture.data("reportのコピー.txt") == Data("external".utf8))
  }

  @Test("別名コピー待ち中の取消は元と旧宛先を保持し、取消されたタスクでも一時領域を掃除する")
  func cancellationCleansStagingDirectory() async throws {
    let provider = ConflictLocalProvider(holdsCopy: true)
    let fixture = try await ConflictFixture.make(
      sourceNames: ["report.txt"], destinationNames: ["report.txt"], provider: provider)
    defer { fixture.cleanup() }
    fixture.source.copy(fixture.source.items, to: fixture.destination)
    fixture.source.resolvePendingTransferConflict(.keepBoth)
    await waitUntil { provider.copyStarted.withLock { $0 } }
    fixture.source.cancelTransfer()
    let job = try await fixture.finishedJob()
    #expect(job.state == .cancelled)
    #expect(try fixture.data("report.txt") == Data("old-report.txt".utf8))
    #expect(try fixture.temporaryNames().isEmpty)
    #expect(
      FileManager.default.fileExists(atPath: fixture.sourceRoot.appending(path: "report.txt").path))
  }

  @Test("別名と項目別置換許可は永続化・再起動復元後も本番キューへ届く")
  func restoresTargetNamesAndReplacementPermission() async throws {
    let store = InMemoryTransferJobStore()
    let fixture = try await ConflictFixture.make(
      sourceNames: ["report.txt", "replace.txt"], destinationNames: ["report.txt", "replace.txt"])
    defer { fixture.cleanup() }
    var job = TransferJob(
      kind: .copy, items: fixture.source.items, sourceProviderID: .local,
      destinationProviderID: .local, destination: fixture.destination.currentLocation)
    job.items = fixture.source.items.map {
      TransferJob.Item(
        $0,
        options: $0.name == "report.txt"
          ? TransferItemOptions(destinationName: "reportのコピー.txt")
          : TransferItemOptions(replacingExisting: true))
    }
    job.state = .interrupted
    let restored = try JSONDecoder().decode(TransferJob.self, from: JSONEncoder().encode(job))
    try store.save([restored])
    let queue = TransferQueue(store: store)
    let source = FileBrowserSession(
      provider: LocalFileProvider(), initialLocation: fixture.source.currentLocation,
      transferQueue: queue)
    let destination = FileBrowserSession(
      provider: LocalFileProvider(), initialLocation: fixture.destination.currentLocation,
      transferQueue: queue)
    #expect(source.prepareTransferRetry(restored, to: destination))
    source.retryLastTransfer()
    await waitUntil {
      (await queue.allJobs()).first?.state.isTerminal == true && !source.isTransferring
    }
    #expect(await queue.allJobs().first?.state == .completed)
    #expect(try fixture.data("report.txt") == Data("old-report.txt".utf8))
    #expect(try fixture.data("reportのコピー.txt") == Data("new-report.txt".utf8))
    #expect(try fixture.data("replace.txt") == Data("new-replace.txt".utf8))
  }

  @Test("旧保存データに選択キーがなくても無置換とスキップ0で復元する")
  func decodesLegacyJobsSafely() throws {
    let item = FileItem(url: URL(filePath: "/fixture/report.txt"), isDirectory: false)
    let job = TransferJob(
      kind: .copy, items: [item], sourceProviderID: .local,
      destinationProviderID: .local,
      destination: FileLocation(localURL: URL(filePath: "/fixture/destination")))
    var object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any])
    object.removeValue(forKey: "skippedItemCount")
    var items = try #require(object["items"] as? [[String: Any]])
    items = items.map { value in
      var legacy = value
      legacy.removeValue(forKey: "transferOptions")
      return legacy
    }
    object["items"] = items
    let restored = try JSONDecoder().decode(
      TransferJob.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(restored.skippedItemCount == 0)
    #expect(restored.items.first?.transferOptions == TransferItemOptions())
  }

  @Test("別名移動のUndoは全表示モードで元名へ戻し、スキップ項目を変更しない")
  func undoRestoresOriginalNamesAcrossViewModes() async throws {
    for mode in FileBrowserViewMode.selectableCases {
      let fixture = try await ConflictFixture.make(
        sourceNames: ["report.txt", "skip.txt"], destinationNames: ["report.txt", "skip.txt"])
      defer { fixture.cleanup() }
      let workspace = FileWorkspaceModel(initialBrowser: fixture.source)
      workspace.activatePane(.secondary)
      workspace.replaceActiveBrowser(with: fixture.destination)
      workspace.activatePane(.primary)
      workspace.setViewMode(mode)
      workspace.selectItems(Set(fixture.source.items.map(\.url)), in: .primary)
      workspace.transferSelectedItems(to: fixture.destination, wasMove: true)
      fixture.source.resolvePendingTransferConflict(.keepBoth)
      fixture.source.resolvePendingTransferConflict(.skip)
      await waitUntil { workspace.canUndoLastTransfer }
      #expect(try fixture.data("report.txt") == Data("old-report.txt".utf8))
      workspace.undoLastTransfer()
      await waitUntil {
        FileManager.default.fileExists(
          atPath: fixture.sourceRoot.appending(path: "report.txt").path)
          && !fixture.destination.isTransferring
      }
      #expect(
        try Data(contentsOf: fixture.sourceRoot.appending(path: "report.txt"))
          == Data("new-report.txt".utf8))
      #expect(try fixture.data("skip.txt") == Data("old-skip.txt".utf8))
    }
  }
}

@MainActor
private struct ConflictFixture {
  let root: URL
  let sourceRoot: URL
  let destinationRoot: URL
  let source: FileBrowserSession
  let destination: FileBrowserSession
  let queue: TransferQueue

  static func make(
    sourceNames: [String], destinationNames: [String],
    sourceDirectories: [String] = [], destinationDirectories: [String] = [],
    provider: any FileBrowserProvider = LocalFileProvider()
  ) async throws -> Self {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "ConflictResolution-\(UUID().uuidString)")
    let sourceRoot = root.appending(path: "source")
    let destinationRoot = root.appending(path: "destination")
    try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
    for name in sourceNames {
      try Data("new-\(name)".utf8).write(to: sourceRoot.appending(path: name))
    }
    for name in destinationNames {
      try Data("old-\(name)".utf8).write(to: destinationRoot.appending(path: name))
    }
    for name in sourceDirectories {
      let directory = sourceRoot.appending(path: name)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
      try Data("new".utf8).write(to: directory.appending(path: "new-only.txt"))
    }
    for name in destinationDirectories {
      let directory = destinationRoot.appending(path: name)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
      try Data("old".utf8).write(to: directory.appending(path: "old-only.txt"))
    }
    let queue = TransferQueue.isolatedForTesting()
    let source = FileBrowserSession(
      provider: provider, initialLocation: FileLocation(localURL: sourceRoot), transferQueue: queue)
    let destination = FileBrowserSession(
      provider: provider, initialLocation: FileLocation(localURL: destinationRoot),
      transferQueue: queue)
    source.load()
    destination.load()
    await waitUntil {
      !source.isLoading && !destination.isLoading
        && source.items.count == sourceNames.count + sourceDirectories.count
        && destination.items.count == destinationNames.count + destinationDirectories.count
    }
    return Self(
      root: root, sourceRoot: sourceRoot, destinationRoot: destinationRoot, source: source,
      destination: destination, queue: queue)
  }

  func finishedJob() async throws -> TransferJob {
    await waitUntil {
      let jobs = await queue.allJobs()
      return !jobs.isEmpty && jobs.allSatisfy { $0.state.isTerminal } && !source.isTransferring
    }
    let jobs = await queue.allJobs()
    return try #require(jobs.first)
  }

  func data(_ name: String) throws -> Data {
    try Data(contentsOf: destinationRoot.appending(path: name))
  }
  func temporaryNames() throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: destinationRoot.path).filter {
      $0.hasPrefix(".pkpane-keep-both-")
    }
  }
  func cleanup() {
    source.invalidate()
    destination.invalidate()
    try? FileManager.default.removeItem(at: root)
  }
}

private final class NonReplacingFTPSession: FTPClientSession, @unchecked Sendable {
  let mutationCount = Mutex(0)
  func contents(of _: String) async throws -> [FTPDirectoryEntry] {
    [
      FTPDirectoryEntry(
        name: "report.txt", isDirectory: false, isSymbolicLink: false,
        size: 3, modifiedAt: nil, posixPermissions: nil, source: .mlsd)
    ]
  }
  func createDirectory(at _: String) async throws { mutationCount.withLock { $0 += 1 } }
  func remove(at _: String, isDirectory _: Bool) async throws { mutationCount.withLock { $0 += 1 } }
  func rename(at _: String, to _: String) async throws { mutationCount.withLock { $0 += 1 } }
  func streamFileContents(of _: String, receive _: @escaping @Sendable (Data) async throws -> Void)
    async throws
  {}
  func writeFileContents(
    to _: String, chunks _: AsyncThrowingStream<Data, Error>,
    progress _: @escaping @Sendable (Int64) -> Void
  ) async throws {
    mutationCount.withLock { $0 += 1 }
  }
  func fileSize(at _: String) async throws -> Int64? { 3 }
  func setPosixPermissions(_: Int, at _: String) async throws { mutationCount.withLock { $0 += 1 } }
  func isActive() async -> Bool { true }
  func close() async {}
}

private final class ConflictLocalProvider: FileBrowserTransferProvider, FileTransferCommitProvider,
  FileBrowserPermanentDeleteProvider, FileBrowserItemSizeProvider, @unchecked Sendable
{
  let local = LocalFileProvider()
  var id: FileProviderID { .local }
  var connectionID: FileProviderConnectionID? { nil }
  var capabilities: FileProviderCapabilities { local.capabilities }
  let addCollisionAtCommit: Bool
  let holdsCopy: Bool
  let copyStarted = Mutex(false)

  init(addCollisionAtCommit: Bool = false, holdsCopy: Bool = false) {
    self.addCollisionAtCommit = addCollisionAtCommit
    self.holdsCopy = holdsCopy
  }
  func contents(of location: FileLocation) async throws -> [FileItem] {
    try await local.contents(of: location)
  }
  func parent(of location: FileLocation) -> FileLocation? { local.parent(of: location) }
  func breadcrumbs(for location: FileLocation, constrainedTo root: FileLocation?)
    -> [FileBrowserBreadcrumb]
  {
    local.breadcrumbs(for: location, constrainedTo: root)
  }
  func createDirectory(named name: String, in location: FileLocation) async throws {
    try await local.createDirectory(named: name, in: location)
  }
  func rename(_ item: FileItem, to name: String) async throws {
    try await local.rename(item, to: name)
  }
  func delete(_ item: FileItem) async throws { try await local.delete(item) }
  func permanentlyDelete(_ item: FileItem) async throws {
    try await local.removeAfterCrossProviderMove(item)
  }
  func move(_ item: FileItem, to directory: FileLocation, replacingExisting: Bool) async throws {
    try await local.move(item, to: directory, replacingExisting: replacingExisting)
  }
  func copy(_ item: FileItem, to directory: FileLocation, replacingExisting: Bool) async throws {
    copyStarted.withLock { $0 = true }
    if holdsCopy {
      while true { try await Task.sleep(for: .milliseconds(10)) }
    }
    try await local.copy(item, to: directory, replacingExisting: replacingExisting)
  }
  func removeAfterCrossProviderMove(_ item: FileItem) async throws {
    try await local.removeAfterCrossProviderMove(item)
  }
  func itemSize(at location: FileLocation) async throws -> Int64? {
    try await local.detailedItem(at: location).size
  }
  func stagedFileSize(at location: FileLocation) async throws -> Int64? {
    try await local.stagedFileSize(at: location)
  }
  func commitTransferFile(
    from temporaryLocation: FileLocation, to destination: FileLocation, replacingExisting: Bool
  ) async throws {
    if addCollisionAtCommit, let url = destination.localURL,
      !FileManager.default.fileExists(atPath: url.path)
    {
      try Data("external".utf8).write(to: url)
    }
    try await local.commitTransferFile(
      from: temporaryLocation, to: destination, replacingExisting: replacingExisting)
  }
  func discardTransferFile(at location: FileLocation) async {
    await local.discardTransferFile(at: location)
  }
}

private struct LargeConflictInventoryProvider: FileBrowserProvider {
  let id = FileProviderID(rawValue: "large-conflict-fixture")
  let connectionID: FileProviderConnectionID? = nil
  let capabilities: FileProviderCapabilities = [.read]
  var source: FileLocation { FileLocation(remotePath: "/src", providerID: id) }
  var destination: FileLocation { FileLocation(remotePath: "/dst", providerID: id) }
  func contents(of location: FileLocation) async throws -> [FileItem] {
    (0..<10_000).map { index in
      let name =
        index < 5_000
        ? "shared-\(index).txt"
        : "\(location == source ? "new" : "old")-\(index).txt"
      let path = "\(location.remotePath ?? "")/\(name)"
      return FileItem(
        remotePath: path, url: URL(filePath: path), providerID: id,
        isDirectory: false, size: 1)
    }
  }
  func parent(of _: FileLocation) -> FileLocation? { nil }
  func breadcrumbs(for _: FileLocation, constrainedTo _: FileLocation?) -> [FileBrowserBreadcrumb] {
    []
  }
}
