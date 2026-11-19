import Foundation
import Synchronization
import Testing

@testable import PKPane

struct FolderSyncExecutionEngineTests {
  @Test("同期転送の待機単位はTransferQueueの終了履歴上限を超えない")
  func transferBatchFitsTerminalHistory() {
    #expect(
      FolderSyncExecutionEngine.maximumTransferBatchSize
        <= TransferJobHistoryPolicy.terminalLimit)
  }

  @Test("コピーと上書きを既存TransferQueueへ積み、全転送成功後だけゴミ箱削除する")
  func enqueuesTransfersAndDeletesOnlyAfterCompletion() async throws {
    let fixture = SyncExecutionFixture(
      left: [
        syncFile("/left/new.txt", size: 3),
        syncFile("/left/replace.txt", size: 7, modifiedAt: syncDate(20)),
      ],
      right: [
        syncFile("/right/replace.txt", size: 2, modifiedAt: syncDate(2)),
        syncFile("/right/extra.txt", size: 5),
      ])
    let plan = fixture.plan(deletesExtraneousItems: true)

    let summary = await fixture.engine.execute(plan)
    let jobs = await fixture.queue.allJobs()
    let events = await fixture.state.events()
    let extraExists = await fixture.state.hasItem(at: "/right/extra.txt")

    #expect(jobs.count == 2)
    #expect(jobs.allSatisfy { $0.kind == .copy && $0.state == .completed })
    #expect(summary.successCount == 3)
    #expect(summary.failureCount == 0)
    #expect(await fixture.state.hasItem(at: "/right/new.txt"))
    #expect(await fixture.state.itemSize(at: "/right/replace.txt") == 7)
    #expect(!extraExists)
    let deleteIndex = try #require(events.firstIndex(of: .trash("/right/extra.txt")))
    let precedingCommitCount = events[..<deleteIndex].count {
      if case .commit = $0 { return true }
      return false
    }
    #expect(precedingCommitCount == 2)
  }

  @Test("一部の転送が失敗しても残りを継続し、削除は全件見送って結果へ残す")
  func continuesAfterPartialFailureAndDefersDeletion() async throws {
    let fixture = SyncExecutionFixture(
      left: [
        syncFile("/left/good.txt", size: 4),
        syncFile("/left/bad.txt", size: 6),
      ],
      right: [syncFile("/right/extra.txt", size: 2)],
      failingReadPaths: ["/left/bad.txt"])
    let plan = fixture.plan(deletesExtraneousItems: true)

    let summary = await fixture.engine.execute(plan)
    let badExists = await fixture.state.hasItem(at: "/right/bad.txt")

    #expect(await fixture.state.hasItem(at: "/right/good.txt"))
    #expect(!badExists)
    #expect(await fixture.state.hasItem(at: "/right/extra.txt"))
    #expect(summary.successCount == 1)
    #expect(summary.failureCount == 1)
    #expect(
      summary.result(for: "extra.txt")?.outcome
        == .skipped(.deletionDeferredAfterTransferFailure))
    #expect(await fixture.state.trashCalls().isEmpty)
  }

  @Test("実行直前に変化した項目はジョブを積まずスキップする")
  func skipsChangedItemBeforeEnqueue() async throws {
    let fixture = SyncExecutionFixture(
      left: [syncFile("/left/report.txt", size: 10)],
      right: [])
    let plan = fixture.plan(deletesExtraneousItems: false)
    await fixture.state.replace(
      syncFile("/left/report.txt", size: 11, modifiedAt: syncDate(30)))

    let summary = await fixture.engine.execute(plan)
    let destinationExists = await fixture.state.hasItem(at: "/right/report.txt")

    #expect(await fixture.queue.allJobs().isEmpty)
    #expect(summary.result(for: "report.txt")?.outcome == .skipped(.changedSinceComparison))
    #expect(!destinationExists)
  }

  @Test("転送後に削除候補が変化した場合は削除直前の再検証でゴミ箱移動を止める")
  func revalidatesDeletionImmediatelyBeforeTrash() async throws {
    let fixture = SyncExecutionFixture(
      left: [syncFile("/left/new.txt", size: 3)],
      right: [syncFile("/right/extra.txt", size: 5)],
      mutateBeforeFirstTrashValidation: {
        await $0.replace(syncFile("/right/extra.txt", size: 99, modifiedAt: syncDate(40)))
      })
    let plan = fixture.plan(deletesExtraneousItems: true)

    let summary = await fixture.engine.execute(plan)

    #expect(await fixture.state.hasItem(at: "/right/extra.txt"))
    #expect(summary.result(for: "extra.txt")?.outcome == .skipped(.changedSinceComparison))
    #expect(summary.result(for: "extra.txt")?.action == .delete)
    #expect(await fixture.state.trashCalls().isEmpty)
  }

  @Test("後続バッチは投入直前に鮮度を再検証する")
  func revalidatesEachTransferBatchImmediatelyBeforeEnqueue() async throws {
    let ordinaryFiles = (0..<FolderSyncExecutionEngine.maximumTransferBatchSize).map { index in
      syncFile(String(format: "/left/item-%03d.txt", index), size: 1)
    }
    let lastFile = syncFile("/left/zzzz.txt", size: 1)
    let fixture = SyncExecutionFixture(
      left: ordinaryFiles + [lastFile],
      right: [],
      mutateBeforeTransferBatchValidation: { batchIndex, state in
        guard batchIndex == 1 else { return }
        await state.replace(syncFile("/left/zzzz.txt", size: 2, modifiedAt: syncDate(40)))
      })

    let summary = await fixture.engine.execute(fixture.plan(deletesExtraneousItems: false))

    #expect(await fixture.queue.allJobs().count == ordinaryFiles.count)
    #expect(summary.result(for: "zzzz.txt")?.outcome == .skipped(.changedSinceComparison))
    #expect(!(await fixture.state.hasItem(at: "/right/zzzz.txt")))
  }

  @Test("削除OFFは実行側でも不整合な削除操作を拒否する")
  func executionGuardRejectsDeletionWhenOptionIsOff() async throws {
    let fixture = SyncExecutionFixture(
      left: [],
      right: [syncFile("/right/extra.txt", size: 5)])
    let deletionPlan = fixture.plan(deletesExtraneousItems: true)
    let inconsistentPlan = FolderSyncPlan(
      snapshot: deletionPlan.snapshot,
      direction: deletionPlan.direction,
      deletesExtraneousItems: false,
      destinationDeletionMode: deletionPlan.destinationDeletionMode,
      operations: deletionPlan.operations,
      summary: deletionPlan.summary)

    let summary = await fixture.engine.execute(inconsistentPlan)

    #expect(await fixture.state.hasItem(at: "/right/extra.txt"))
    #expect(summary.result(for: "extra.txt")?.action == .delete)
    #expect(summary.result(for: "extra.txt")?.outcome == .skipped(.deletionDisabled))
    #expect(await fixture.state.trashCalls().isEmpty)
  }

  @Test("完全削除の確認がないプランは転送を含めて一切実行しない")
  func executionGuardRejectsUnconfirmedPermanentDeletion() async {
    let fixture = SyncExecutionFixture(
      left: [syncFile("/left/new.txt", size: 3)],
      right: [syncFile("/right/extra.txt", size: 5)])
    let trashPlan = fixture.plan(deletesExtraneousItems: true)
    let permanentPlan = FolderSyncPlan(
      snapshot: trashPlan.snapshot,
      direction: trashPlan.direction,
      deletesExtraneousItems: trashPlan.deletesExtraneousItems,
      destinationDeletionMode: .permanent,
      operations: trashPlan.operations,
      summary: trashPlan.summary)

    let summary = await fixture.engine.execute(permanentPlan)

    #expect(await fixture.queue.allJobs().isEmpty)
    #expect(!(await fixture.state.hasItem(at: "/right/new.txt")))
    #expect(await fixture.state.hasItem(at: "/right/extra.txt"))
    #expect(
      summary.result(for: "new.txt")?.outcome
        == .skipped(.permanentDeletionRequiresConfirmation))
    #expect(
      summary.result(for: "extra.txt")?.outcome
        == .skipped(.permanentDeletionRequiresConfirmation))
  }

  @Test("監視中の終了ジョブが履歴から消えても待機を打ち切る")
  @MainActor
  func exitsWhenObservedTerminalJobDisappears() async throws {
    let fixture = SyncExecutionFixture(
      left: [
        syncFile("/left/first.txt", size: 1),
        syncFile("/left/second.txt", size: 1),
      ],
      right: [])
    let queue = fixture.queue
    let firstJobID = Mutex<UUID?>(nil)
    let engine = FolderSyncExecutionEngine(
      leftProvider: fixture.provider,
      rightProvider: fixture.provider,
      transferQueue: queue,
      transferEnqueuer: { operation, direction, destinationRoot in
        guard let item = operation.sourceItem,
          let destination = FolderComparisonPath.parentDirectory(
            for: operation.relativePath,
            under: destinationRoot)
        else { return nil }
        let job = TransferJob(
          kind: .copy,
          items: [item],
          sourceProviderID: item.location.providerID,
          destinationProviderID: destination.providerID,
          destination: destination)
        let execution: TransferQueue.Execution = { _, _ in
          if operation.relativePath == "second.txt" {
            try await Task.sleep(for: .seconds(30))
          }
        }
        _ = await queue.enqueue(job, execution: execution)
        if operation.relativePath == "first.txt" {
          firstJobID.withLock { $0 = job.id }
        }
        return job
      })
    let removalTask = Task {
      let succeeded = await waitUntil("対象ジョブが期限内に完了しなかった") {
        guard let jobID = firstJobID.withLock({ $0 }) else { return false }
        return await queue.allJobs().first(where: { $0.id == jobID })?.state == .completed
      }
      guard succeeded, let jobID = firstJobID.withLock({ $0 }) else { return }
      _ = await queue.removeTerminalJob(jobID)
    }

    let summary = await engine.execute(fixture.plan(deletesExtraneousItems: false))
    await removalTask.value
    for job in await queue.allJobs() where !job.state.isTerminal {
      await queue.cancel(job.id)
    }

    #expect(summary.failureCount == 2)
  }

  @Test("転送先は実行時のペイン位置ではなく比較スナップショットのルートに固定する")
  @MainActor
  func usesSnapshotDestinationRoot() async {
    let fixture = SyncExecutionFixture(
      left: [syncFile("/left/report.txt", size: 10)],
      right: [])
    let receivedRoot = Mutex<FileLocation?>(nil)
    let engine = FolderSyncExecutionEngine(
      leftProvider: fixture.provider,
      rightProvider: fixture.provider,
      transferQueue: fixture.queue,
      transferEnqueuer: { _, _, destinationRoot in
        receivedRoot.withLock { $0 = destinationRoot }
        return nil
      })

    let summary = await engine.execute(fixture.plan(deletesExtraneousItems: false))

    #expect(receivedRoot.withLock { $0 } == syncLocation("/right"))
    #expect(summary.failureCount == 1)
  }
}

private struct SyncExecutionFixture {
  let state: SyncExecutionProviderState
  let provider: SyncExecutionProvider
  let queue: TransferQueue
  let engine: FolderSyncExecutionEngine
  private let leftSnapshot: [FileItem]
  private let rightSnapshot: [FileItem]

  init(
    left: [FileItem],
    right: [FileItem],
    failingReadPaths: Set<String> = [],
    mutateBeforeTransferBatchValidation:
      (@Sendable (Int, SyncExecutionProviderState) async -> Void)? = nil,
    mutateBeforeFirstTrashValidation: (@Sendable (SyncExecutionProviderState) async -> Void)? = nil
  ) {
    let fixtureState = SyncExecutionProviderState(
      left: left,
      right: right,
      failingReadPaths: failingReadPaths)
    let fixtureProvider = SyncExecutionProvider(state: fixtureState)
    let fixtureQueue = TransferQueue(
      store: InMemoryTransferJobStore(),
      maximumConcurrentTransfers: 2)
    let batchHook: (@Sendable (Int) async -> Void)?
    if let mutation = mutateBeforeTransferBatchValidation {
      batchHook = { batchIndex in await mutation(batchIndex, fixtureState) }
    } else {
      batchHook = nil
    }
    let deletionHook: (@Sendable () async -> Void)?
    if let mutation = mutateBeforeFirstTrashValidation {
      deletionHook = { await mutation(fixtureState) }
    } else {
      deletionHook = nil
    }
    state = fixtureState
    provider = fixtureProvider
    queue = fixtureQueue
    leftSnapshot = left
    rightSnapshot = right
    engine = FolderSyncExecutionEngine(
      leftProvider: fixtureProvider,
      rightProvider: fixtureProvider,
      transferQueue: fixtureQueue,
      beforeTransferBatchValidation: batchHook,
      beforeDeletionRevalidation: deletionHook)
  }

  func plan(deletesExtraneousItems: Bool) -> FolderSyncPlan {
    let leftRecords = leftSnapshot.map {
      FolderComparisonRecord(relativePath: $0.name, item: $0)
    }
    let rightRecords = rightSnapshot.map {
      FolderComparisonRecord(relativePath: $0.name, item: $0)
    }
    let snapshot = FolderComparisonSnapshot(
      leftRoot: syncLocation("/left"),
      rightRoot: syncLocation("/right"),
      entries: FolderComparisonMatcher.compare(left: leftRecords, right: rightRecords),
      enumeratedItemCount: leftRecords.count + rightRecords.count,
      skippedSymbolicLinkCount: 0,
      partialErrorCount: 0,
      didReachItemLimit: false)
    return FolderSyncPlanner.makePlan(
      snapshot: snapshot,
      direction: .leftToRight,
      deletesExtraneousItems: deletesExtraneousItems,
      destinationDeletionMode: .trash)
  }
}

private actor SyncExecutionProviderState {
  enum Event: Equatable {
    case commit(String)
    case trash(String)
  }

  private var itemsByPath: [String: FileItem]
  private var dataByPath: [String: Data]
  private let failingReadPaths: Set<String>
  private var recordedEvents = [Event]()
  private var recordedTrashCalls = [String]()

  init(left: [FileItem], right: [FileItem], failingReadPaths: Set<String>) {
    let items = left + right
    itemsByPath = Dictionary(uniqueKeysWithValues: items.map { ($0.location.remotePath!, $0) })
    dataByPath = Dictionary(
      uniqueKeysWithValues: items.map { item in
        (item.location.remotePath!, Data(repeating: 1, count: Int(item.size ?? 0)))
      })
    self.failingReadPaths = failingReadPaths
  }

  func contents(at directory: String) -> [FileItem] {
    itemsByPath.values.filter {
      $0.location.deletingLastPathComponent()?.remotePath == directory
    }.sorted { $0.name < $1.name }
  }

  func data(at path: String) throws -> Data {
    if failingReadPaths.contains(path) { throw SyncExecutionFixtureError.readFailed }
    guard let data = dataByPath[path] else { throw SyncExecutionFixtureError.missingItem }
    return data
  }

  func write(_ data: Data, to path: String) {
    dataByPath[path] = data
    itemsByPath[path] = syncFile(path, size: Int64(data.count))
  }

  func commit(from temporaryPath: String, to destinationPath: String) throws {
    guard let data = dataByPath.removeValue(forKey: temporaryPath) else {
      throw SyncExecutionFixtureError.missingItem
    }
    itemsByPath.removeValue(forKey: temporaryPath)
    dataByPath[destinationPath] = data
    itemsByPath[destinationPath] = syncFile(destinationPath, size: Int64(data.count))
    recordedEvents.append(.commit(destinationPath))
  }

  func discard(at path: String) {
    dataByPath[path] = nil
    itemsByPath[path] = nil
  }

  func trash(_ item: FileItem) {
    let path = item.location.remotePath ?? ""
    itemsByPath[path] = nil
    dataByPath[path] = nil
    recordedTrashCalls.append(path)
    recordedEvents.append(.trash(path))
  }

  func replace(_ item: FileItem) {
    let path = item.location.remotePath ?? ""
    itemsByPath[path] = item
    dataByPath[path] = Data(repeating: 2, count: Int(item.size ?? 0))
  }

  func hasItem(at path: String) -> Bool { itemsByPath[path] != nil }
  func itemSize(at path: String) -> Int64? { itemsByPath[path]?.size }
  func events() -> [Event] { recordedEvents }
  func trashCalls() -> [String] { recordedTrashCalls }
}

private struct SyncExecutionProvider: FileStreamTransferProvider, FileTransferCommitProvider,
  FileBrowserTrashProvider
{
  let state: SyncExecutionProviderState
  let id = FileProviderID(rawValue: "sync-execution")
  let connectionID: FileProviderConnectionID? = nil
  let capabilities: FileProviderCapabilities = [
    .read, .write, .copyWithinProvider, .trash, .replaceAtomically,
  ]

  func contents(of location: FileLocation) async throws -> [FileItem] {
    await state.contents(at: location.remotePath ?? "")
  }

  func parent(of location: FileLocation) -> FileLocation? {
    location.deletingLastPathComponent()
  }

  func breadcrumbs(
    for _: FileLocation,
    constrainedTo _: FileLocation?
  ) -> [FileBrowserBreadcrumb] { [] }

  func createDirectory(named _: String, in _: FileLocation) async throws {}
  func rename(_: FileItem, to _: String) async throws {}

  func delete(_ item: FileItem) async throws {
    await state.trash(item)
  }

  func fileChunks(for item: FileItem, chunkSize _: Int) -> AsyncThrowingStream<Data, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          continuation.yield(try await state.data(at: item.location.remotePath ?? ""))
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  func writeFileChunks(
    _ chunks: AsyncThrowingStream<Data, Error>,
    to destination: FileLocation,
    replacingExisting _: Bool,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws {
    var data = Data()
    for try await chunk in chunks {
      data.append(chunk)
      progress(Int64(data.count))
    }
    await state.write(data, to: destination.remotePath ?? "")
  }

  func stagedFileSize(at temporaryLocation: FileLocation) async throws -> Int64? {
    Int64(try await state.data(at: temporaryLocation.remotePath ?? "").count)
  }

  func commitTransferFile(
    from temporaryLocation: FileLocation,
    to destination: FileLocation,
    replacingExisting _: Bool
  ) async throws {
    try await state.commit(
      from: temporaryLocation.remotePath ?? "",
      to: destination.remotePath ?? "")
  }

  func discardTransferFile(at temporaryLocation: FileLocation) async {
    await state.discard(at: temporaryLocation.remotePath ?? "")
  }
}

private enum SyncExecutionFixtureError: Error {
  case missingItem
  case readFailed
}

private func syncFile(
  _ path: String,
  size: Int64,
  modifiedAt: Date = syncDate(10)
) -> FileItem {
  FileItem(
    remotePath: path,
    url: URL(fileURLWithPath: path),
    providerID: FileProviderID(rawValue: "sync-execution"),
    isDirectory: false,
    size: size,
    modifiedAt: modifiedAt)
}

private func syncLocation(_ path: String) -> FileLocation {
  FileLocation(
    remotePath: path,
    providerID: FileProviderID(rawValue: "sync-execution"))
}

private func syncDate(_ seconds: TimeInterval) -> Date {
  Date(timeIntervalSince1970: seconds)
}

extension FolderSyncExecutionSummary {
  fileprivate func result(for relativePath: String) -> FolderSyncExecutionItemResult? {
    results.first { $0.relativePath == relativePath }
  }
}
