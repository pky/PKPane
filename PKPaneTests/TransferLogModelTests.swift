import Foundation
import Testing

@testable import PKPane

@MainActor
struct TransferLogModelTests {
  @Test("履歴をフィルタし作成日時の新しい順で最大1000件に投影する")
  func projectsFilteredJobsNewestFirstWithLimit() {
    let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
    var jobs = (0..<1_002).map { index in
      makeJob(state: .completed, createdAt: baseDate.addingTimeInterval(Double(index)))
    }
    let failed = makeJob(state: .failed, createdAt: baseDate.addingTimeInterval(2_000))
    let interrupted = makeJob(
      state: .interrupted, createdAt: baseDate.addingTimeInterval(2_001))
    let cancelled = makeJob(state: .cancelled, createdAt: baseDate.addingTimeInterval(2_002))
    let running = makeJob(state: .running, createdAt: baseDate.addingTimeInterval(2_003))
    let queued = makeJob(state: .queued, createdAt: baseDate.addingTimeInterval(2_004))
    let paused = makeJob(state: .paused, createdAt: baseDate.addingTimeInterval(2_005))
    jobs += [failed, interrupted, cancelled, running, queued, paused]

    let all = TransferLogProjection.makeSnapshot(jobs, filter: .all).displayedJobs
    #expect(all.count == 1_000)
    #expect(
      Array(all.prefix(6).map(\.id)) == [
        paused.id, queued.id, running.id, cancelled.id, interrupted.id, failed.id,
      ])
    #expect(
      TransferLogProjection.makeSnapshot(jobs, filter: .failed).displayedJobs.map(\.id)
        == [interrupted.id, failed.id])
    #expect(
      TransferLogProjection.makeSnapshot(jobs, filter: .cancelled).displayedJobs.map(\.id)
        == [cancelled.id])
    #expect(
      TransferLogProjection.makeSnapshot(jobs, filter: .active).displayedJobs.map(\.id)
        == [paused.id, queued.id, running.id])
    let completedSnapshot = TransferLogProjection.makeSnapshot(jobs, filter: .completed)
    #expect(completedSnapshot.displayedJobs.count == 1_000)
    #expect(completedSnapshot.isDisplayLimited)
    #expect(completedSnapshot.hasTerminalJobs)
  }

  @Test("表示中だけ購読し高頻度publishを200ms単位の最新投影へ合流する")
  func observesOnlyWhilePresentedAndThrottlesProjectionToLatestJobs() async throws {
    let source = FakeTransferLogJobSource()
    let model = TransferLogModel(
      transferQueue: TransferQueue(store: TransferLogMemoryStore()),
      jobSource: source)
    let presentation = TransferLogPresentationState(model: model)
    let hiddenJob = makeJob(state: .completed)

    await source.publish([hiddenJob])
    try await Task.sleep(for: .milliseconds(250))
    #expect(model.projectionComputationCount == 0)
    #expect(await source.subscriberCount == 0)

    presentation.present()
    try await waitUntil { await source.subscriberCount == 1 }

    var finalJobs: [TransferJob] = []
    for index in 0..<100 {
      let state: TransferJob.State = index == 99 ? .completed : .running
      finalJobs = [
        makeJob(
          state: state,
          createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)))
      ]
      await source.publish(finalJobs)
    }
    try await waitUntil {
      model.displayedJobs.map(\.id) == finalJobs.map(\.id)
    }

    #expect(model.projectionComputationCount <= 2)
    #expect(model.hasTerminalJobs)
    #expect(!model.isDisplayLimited)

    presentation.dismiss()
    let countAfterDismiss = model.projectionComputationCount
    for _ in 0..<100 {
      await source.publish([makeJob(state: .running)])
    }
    try await Task.sleep(for: .milliseconds(250))

    #expect(!model.isObserving)
    #expect(model.projectionComputationCount == countAfterDismiss)
  }

  @Test("再試行・一時停止・再開・キャンセルは許可状態だけ既存操作ハンドラへ委譲する")
  func delegatesTransferOperationsOnlyForAllowedStates() {
    var retriedIDs: [UUID] = []
    var pausedIDs: [UUID] = []
    var resumedIDs: [UUID] = []
    var cancelledIDs: [UUID] = []
    let model = TransferLogModel(
      transferQueue: TransferQueue(store: TransferLogMemoryStore()),
      retry: { retriedIDs.append($0.id) },
      pause: { pausedIDs.append($0) },
      resume: {
        resumedIDs.append($0.id)
        return true
      },
      cancel: { cancelledIDs.append($0) })
    let failed = makeJob(state: .failed)
    let interrupted = makeJob(state: .interrupted)
    let cancelled = makeJob(state: .cancelled)
    let completed = makeJob(state: .completed)
    let running = makeJob(state: .running)
    let queued = makeJob(state: .queued)
    let paused = makeJob(state: .paused)

    for job in [failed, interrupted, cancelled, completed, running, queued, paused] {
      model.retry(job)
      model.pause(job)
      model.resume(job)
      model.cancel(job)
    }
    model.resume(paused)

    #expect(retriedIDs == [failed.id, interrupted.id, cancelled.id])
    #expect(pausedIDs == [running.id, queued.id])
    #expect(resumedIDs == [paused.id])
    #expect(cancelledIDs == [running.id, queued.id, paused.id])
    #expect(TransferLogModel.stateLabel(.paused) == "一時停止中")
    #expect(model.stateLabel(running) == "停止しています…")
    #expect(!model.canPause(running))
    #expect(!model.canResume(paused))
  }

  @Test("終了済み履歴の一括消去は確認後だけ既存削除ハンドラへ委譲する")
  func removeAllTerminalJobsRequiresConfirmation() async throws {
    let source = FakeTransferLogJobSource()
    var removalCount = 0
    let model = TransferLogModel(
      transferQueue: TransferQueue(store: TransferLogMemoryStore()),
      jobSource: source,
      projectionThrottle: .milliseconds(1),
      removeAllTerminalJobs: { removalCount += 1 })
    let presentation = TransferLogPresentationState(model: model)
    presentation.present()
    try await waitUntil { await source.subscriberCount == 1 }
    await source.publish([makeJob(state: .completed)])
    try await waitUntil { model.hasTerminalJobs }

    model.requestRemoveAllTerminalJobs()
    #expect(model.isConfirmingRemoveAllTerminalJobs)
    #expect(removalCount == 0)
    model.cancelRemoveAllTerminalJobs()
    #expect(!model.isConfirmingRemoveAllTerminalJobs)
    #expect(removalCount == 0)

    model.requestRemoveAllTerminalJobs()
    model.confirmRemoveAllTerminalJobs()
    model.confirmRemoveAllTerminalJobs()
    #expect(!model.isConfirmingRemoveAllTerminalJobs)
    #expect(removalCount == 1)
    presentation.dismiss()
  }

  @Test("表示メニューから履歴表示を経て既存操作ハンドラへ到達する")
  func menuReachesTransferLogPresentationAndOperation() {
    var retriedIDs: [UUID] = []
    let transferLogModel = TransferLogModel(
      transferQueue: TransferQueue(store: TransferLogMemoryStore()),
      retry: { retriedIDs.append($0.id) })
    let presentation = TransferLogPresentationState(model: transferLogModel)
    let menuModel = AppMenuModel()
    menuModel.registerTransferLog { presentation.present() }
    let failed = makeJob(state: .failed)

    menuModel.showTransferLog()
    #expect(presentation.isPresented)
    presentation.model.retry(failed)

    #expect(retriedIDs == [failed.id])
  }

  private func makeJob(
    state: TransferJob.State,
    createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
  ) -> TransferJob {
    let sourceID = FileProviderID(rawValue: "source")
    let destinationID = FileProviderID(rawValue: "destination")
    let item = FileItem(
      remotePath: "./report.txt",
      url: URL(string: "test://source/report.txt")!,
      providerID: sourceID,
      isDirectory: false,
      size: 4)
    var job = TransferJob(
      kind: .copy,
      items: [item],
      sourceProviderID: sourceID,
      destinationProviderID: destinationID,
      destination: FileLocation(remotePath: "/archive", providerID: destinationID),
      createdAt: createdAt)
    job.state = state
    return job
  }

  private func waitUntil(
    timeout: Duration = .seconds(2),
    condition: @escaping @MainActor () async -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("期限までに条件を満たしませんでした")
  }
}

private final class TransferLogMemoryStore: TransferJobStore, @unchecked Sendable {
  func load() throws -> [TransferJob] { [] }
  func save(_: [TransferJob]) throws {}
}

private actor FakeTransferLogJobSource: TransferLogJobSource {
  private var currentJobs: [TransferJob] = []
  private var continuations: [UUID: AsyncStream<[TransferJob]>.Continuation] = [:]

  var subscriberCount: Int { continuations.count }

  func transferLogUpdates() async -> AsyncStream<[TransferJob]> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<[TransferJob]>.makeStream()
    continuations[id] = continuation
    continuation.yield(currentJobs)
    continuation.onTermination = { [weak self] _ in
      Task { await self?.removeContinuation(id) }
    }
    return stream
  }

  func publish(_ jobs: [TransferJob]) {
    currentJobs = jobs
    for continuation in continuations.values {
      continuation.yield(jobs)
    }
  }

  private func removeContinuation(_ id: UUID) {
    continuations[id] = nil
  }
}
