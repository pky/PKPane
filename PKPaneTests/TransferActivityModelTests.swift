import Foundation
import Testing

@testable import PKPane

@MainActor
struct TransferActivityModelTests {
  @Test("実行中ジョブはactiveJobsに現れ、完了後も猶予期間内は表示され続ける")
  func tracksRunningJobsAndKeepsCompletedBriefly() async throws {
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let model = makeModel(transferQueue: queue, recentTerminalDuration: .seconds(30))
    let gate = AsyncStream<Void>.makeStream()
    let job = makeJob()

    _ = await queue.enqueue(job) { _, _ in
      for await _ in gate.stream { break }
    }
    while model.activeJobs.isEmpty { await Task.yield() }
    #expect(model.activeJobs.map(\.id) == [job.id])

    gate.continuation.yield()
    gate.continuation.finish()
    while model.activeJobs.first?.state != .completed { await Task.yield() }

    // 猶予期間(30秒)が長いため、完了直後もまだ表示され続けている。
    #expect(model.activeJobs.map(\.id) == [job.id])
  }

  @Test("終了ジョブは猶予期間が過ぎると自動的に消える")
  func removesTerminalJobAfterGracePeriod() async throws {
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let model = makeModel(
      transferQueue: queue, recentTerminalDuration: .milliseconds(20))
    let job = makeJob()

    _ = await queue.enqueue(job) { _, _ in }
    while model.activeJobs.isEmpty { await Task.yield() }

    await PKPaneTests.waitUntil("終了ジョブが期限内に一覧から消えなかった") {
      model.activeJobs.isEmpty
    }
    #expect(model.activeJobs.isEmpty)
  }

  @Test("dismiss()は猶予期間を待たずに終了ジョブを即座に消す")
  func dismissRemovesJobImmediately() async throws {
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let model = makeModel(transferQueue: queue, recentTerminalDuration: .seconds(30))
    let job = makeJob()

    _ = await queue.enqueue(job) { _, _ in }
    while model.activeJobs.isEmpty { await Task.yield() }

    model.dismiss(job.id)

    #expect(model.activeJobs.isEmpty)
  }

  @Test("再試行後にジョブが更新されていれば、古い猶予期限は誤って消さない")
  func retriedJobSurvivesStaleExpiry() async throws {
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let model = makeModel(
      transferQueue: queue, recentTerminalDuration: .milliseconds(20))
    let gate = AsyncStream<Void>.makeStream()
    let job = makeJob()

    _ = await queue.enqueue(job) { _, _ in throw CocoaError(.fileWriteUnknown) }
    while model.activeJobs.first?.state != .failed { await Task.yield() }

    // 猶予期限が切れるより先に再試行し、実行中状態へ戻す。
    await queue.retry(job.id) { _, _ in
      for await _ in gate.stream { break }
    }
    while model.activeJobs.first?.state != .running { await Task.yield() }

    // 元の失敗時点を起点にした期限が経過してもrunningのままなら消えない。
    try? await Task.sleep(for: .milliseconds(60))
    #expect(model.activeJobs.map(\.id) == [job.id])

    gate.continuation.yield()
    gate.continuation.finish()
  }

  @Test("起動時に読み込んだ古い終了ジョブは表示しない")
  func excludesStaleTerminalJobsLoadedAtStartup() async throws {
    let store = InMemoryTransferJobStore()
    var oldJob = makeJob(state: .completed)
    oldJob.updatedAt = Date.now.addingTimeInterval(-3_600)
    try store.save([oldJob])

    let queue = TransferQueue(store: store)
    let model = makeModel(transferQueue: queue, recentTerminalDuration: .seconds(10))

    // updates()の初回スナップショットが購読タスクへ届くのを待つ。
    for _ in 0..<200 { await Task.yield() }

    #expect(model.activeJobs.isEmpty)
  }

  @Test("失敗・キャンセル・中断ジョブのみ再試行可能と判定する")
  func canRetryReflectsFailureStates() {
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let model = makeModel(transferQueue: queue)

    #expect(model.canRetry(makeJob(state: .failed)))
    #expect(model.canRetry(makeJob(state: .cancelled)))
    #expect(model.canRetry(makeJob(state: .interrupted)))
    #expect(!model.canRetry(makeJob(state: .completed)))
    #expect(!model.canRetry(makeJob(state: .running)))
    #expect(!model.canRetry(makeJob(state: .queued)))
    #expect(!model.canRetry(makeJob(state: .paused)))
  }

  @Test("一時停止はキューへ転送し、再開はpausedジョブだけ既存ワークスペース経路へ委譲する")
  func forwardsPauseAndResumeForAllowedStates() async throws {
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    var resumedIDs: [UUID] = []
    let model = makeModel(transferQueue: queue) {
      resumedIDs.append($0.id)
      return true
    }
    let job = makeJob()

    _ = await queue.enqueue(job) { _, _ in
      try await Task.sleep(for: .seconds(30))
    }
    try await waitUntil { model.activeJobs.first?.state == .running }

    model.pause(job.id)
    await PKPaneTests.waitUntil("ジョブが期限内に一時停止状態にならなかった") {
      model.activeJobs.first?.state == .paused
    }
    let paused = try #require(model.activeJobs.first)

    model.resume(makeJob(state: .running))
    model.resume(paused)
    model.resume(paused)

    #expect(paused.state == .paused)
    #expect(resumedIDs == [job.id])
    #expect(TransferActivityModel.stateLabel(.paused) == "一時停止中")
  }

  @Test("実行中のpause要求を即時表示し、確定までは一時停止ボタンを無効化する")
  func showsPausingFeedbackBeforeProviderCleanupFinishes() async throws {
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let model = makeModel(transferQueue: queue)
    let cleanupGate = PauseCleanupGate()
    let job = makeJob()

    _ = await queue.enqueue(job) { _, _ in
      do {
        try await Task.sleep(for: .seconds(30))
      } catch {
        await cleanupGate.wait()
        throw CocoaError(.fileWriteUnknown)
      }
    }
    try await waitUntil { model.activeJobs.first?.state == .running }

    model.pause(job.id)
    try await waitUntil {
      guard let displayedJob = model.activeJobs.first else { return false }
      return model.isPausing(displayedJob)
    }
    let pausing = try #require(model.activeJobs.first)

    #expect(model.stateLabel(pausing) == "停止しています…")
    #expect(!model.canPause(pausing))

    await cleanupGate.open()
    try await waitUntil { model.activeJobs.first?.state == .paused }
  }

  @Test("進捗テキストはtotalBytes既知ならパーセントとバイト数、不明なら転送済みのみを返す")
  func formatsProgressText() {
    let completed = ByteCountFormatter.string(fromByteCount: 450_000_000, countStyle: .file)
    let total = ByteCountFormatter.string(fromByteCount: 1_000_000_000, countStyle: .file)

    #expect(
      TransferActivityModel.progressText(completedBytes: 450_000_000, totalBytes: 1_000_000_000)
        == "45% (\(completed) / \(total))")
    #expect(
      TransferActivityModel.progressText(completedBytes: 450_000_000, totalBytes: nil)
        == completed)
  }

  @Test("表示順は実行中、待機中の実行順、直近の終了ジョブの順になる")
  func ordersJobsForDisplay() {
    let oldestTerminal = makeJob(state: .completed, updatedAt: Date(timeIntervalSince1970: 10))
    let queuedEarlier = makeJob(state: .queued)
    let running = makeJob(state: .running)
    let queuedLater = makeJob(state: .queued)
    let paused = makeJob(state: .paused)
    let newestTerminal = makeJob(state: .failed, updatedAt: Date(timeIntervalSince1970: 20))

    let ordered = TransferActivityModel.displayOrdered([
      newestTerminal, paused, queuedLater, running, queuedEarlier, oldestTerminal,
    ])

    #expect(
      ordered.map(\.id)
        == [
          running.id, queuedEarlier.id, queuedLater.id, paused.id, newestTerminal.id,
          oldestTerminal.id,
        ])
  }

  @Test("帯域制限の選択を即時反映して永続化する")
  func updatesAndPersistsBandwidthLimit() async throws {
    let suiteName = "TransferActivityModelTests-bandwidth"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = TransferPreferencesStore(defaults: defaults)
    let limiter = TransferRateLimiter()
    let model = TransferActivityModel(
      transferQueue: TransferQueue(store: InMemoryTransferJobStore()),
      rateLimiter: limiter,
      preferencesStore: store)

    model.setBandwidthLimitBytesPerSecond(25_000_000)
    for _ in 0..<100 {
      if limiter.currentBytesPerSecond() == 25_000_000 { break }
      await Task.yield()
    }

    #expect(model.bandwidthLimitBytesPerSecond == 25_000_000)
    #expect(limiter.currentBytesPerSecond() == 25_000_000)
    #expect(
      store.load() == TransferPreferences(bandwidthLimitBytesPerSecond: 25_000_000))
  }

  private func makeJob(state: TransferJob.State? = nil, updatedAt: Date? = nil) -> TransferJob {
    var job = TransferJob(
      kind: .copy, items: [], sourceProviderID: .local, destinationProviderID: .local,
      destination: FileLocation(localURL: URL(filePath: "/tmp")))
    if let state {
      job.state = state
    }
    if let updatedAt {
      job.updatedAt = updatedAt
    }
    return job
  }

  private func makeModel(
    transferQueue: TransferQueue,
    recentTerminalDuration: Duration = .seconds(10),
    resume: @escaping @MainActor (TransferJob) -> Bool = { _ in false }
  ) -> TransferActivityModel {
    let defaults = UserDefaults(
      suiteName: "TransferActivityModelTests-\(UUID().uuidString)")!
    return TransferActivityModel(
      transferQueue: transferQueue,
      recentTerminalDuration: recentTerminalDuration,
      rateLimiter: TransferRateLimiter(),
      preferencesStore: TransferPreferencesStore(defaults: defaults),
      resume: resume)
  }

  private func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: @escaping @MainActor () -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("期限までに条件を満たしませんでした")
  }
}

private actor PauseCleanupGate {
  private var isOpen = false

  func wait() async {
    await waitUntil("クリーンアップゲートが期限内に開かなかった") {
      isOpen
    }
  }

  func open() {
    isOpen = true
  }
}
