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

  @Test("表示遅延より早く完了したジョブは一度も表示しない")
  func neverShowsJobCompletedBeforeDelay() async throws {
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let delay: Duration = .milliseconds(300)
    let model = makeDelayedModel(transferQueue: queue, minimumDisplayDelay: delay)
    let gate = AsyncStream<Void>.makeStream()
    defer { gate.continuation.finish() }
    let job = makeJob()

    _ = await queue.enqueue(job) { _, _ in
      for await _ in gate.stream { break }
    }
    let runningObservation: Duration = .milliseconds(100)
    try await expectJobToStayHidden(job, in: model, for: runningObservation)
    gate.continuation.finish()
    try await expectJobToStayHidden(
      job, in: model, for: delay + .milliseconds(150) - runningObservation)

    let jobs = await queue.allJobs()
    let completed = try #require(jobs.first(where: { $0.id == job.id }))
    #expect(completed.state == .completed)
    #expect(Duration.seconds(completed.updatedAt.timeIntervalSince(completed.createdAt)) < delay)
  }

  @Test("実行中のジョブは表示遅延を過ぎるとキューの追加更新なしで表示する")
  func showsRunningJobAfterDelayWithoutQueueUpdate() async throws {
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let delay: Duration = .milliseconds(300)
    let model = makeDelayedModel(transferQueue: queue, minimumDisplayDelay: delay)
    let gate = AsyncStream<Void>.makeStream()
    defer { gate.continuation.finish() }
    let clock = ContinuousClock()
    let startedAt = clock.now
    let job = makeJob()

    _ = await queue.enqueue(job) { _, _ in
      for await _ in gate.stream { break }
    }
    try await expectJobToStayHidden(job, in: model, for: delay / 2)
    try await waitUntil(timeout: .milliseconds(650)) {
      model.activeJobs.contains { $0.id == job.id && $0.state == .running }
    }
    #expect(startedAt.duration(to: clock.now) >= delay)
  }

  @Test("表示済みのジョブは完了後も猶予期間内に表示する")
  func keepsDisplayedJobAfterCompletion() async throws {
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let model = makeDelayedModel(transferQueue: queue, minimumDisplayDelay: .milliseconds(300))
    let gate = AsyncStream<Void>.makeStream()
    defer { gate.continuation.finish() }
    let job = makeJob()

    _ = await queue.enqueue(job) { _, _ in
      for await _ in gate.stream { break }
    }
    try await waitUntil {
      model.activeJobs.contains { $0.id == job.id && $0.state == .running }
    }
    gate.continuation.finish()
    try await waitUntil {
      model.activeJobs.contains { $0.id == job.id && $0.state == .completed }
    }
  }

  @Test("表示遅延内に失敗したジョブは遅延を待たずに表示する")
  func showsFailedJobBeforeDelay() async throws {
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let delay: Duration = .milliseconds(300)
    let model = makeDelayedModel(transferQueue: queue, minimumDisplayDelay: delay)
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: delay / 2)
    let job = makeJob()

    _ = await queue.enqueue(job) { _, _ in throw CocoaError(.fileWriteUnknown) }
    try await waitUntil(timeout: clock.now.duration(to: deadline)) {
      model.activeJobs.contains { $0.id == job.id && $0.state == .failed }
    }
  }

  @Test("静かなジョブは表示遅延を過ぎても隠し、失敗したら表示する")
  func hidesQuietRunningJobAndShowsItsFailure() async throws {
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let delay: Duration = .milliseconds(300)
    let quietJob = makeJob()
    let model = makeDelayedModel(
      transferQueue: queue, minimumDisplayDelay: delay, isQuietJob: { $0.id == quietJob.id })
    let gate = AsyncStream<Void>.makeStream()
    defer { gate.continuation.finish() }

    _ = await queue.enqueue(quietJob) { _, _ in
      for await _ in gate.stream { break }
      throw CocoaError(.fileWriteUnknown)
    }
    try await expectJobToStayHidden(quietJob, in: model, for: delay + .milliseconds(150))
    let jobs = await queue.allJobs()
    #expect(jobs.first(where: { $0.id == quietJob.id })?.state == .running)

    gate.continuation.finish()
    try await waitUntil {
      model.activeJobs.contains { $0.id == quietJob.id && $0.state == .failed }
    }
  }

  @Test("進捗が複数回更新されても静かなジョブの判定は同じIDで一度だけ行う")
  func evaluatesQuietPolicyOnceAcrossProgressUpdates() async throws {
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    var evaluations: [UUID: Int] = [:]
    let delay: Duration = .milliseconds(300)
    let model = makeDelayedModel(transferQueue: queue, minimumDisplayDelay: delay) { job in
      evaluations[job.id, default: 0] += 1
      return false
    }
    let reports = AsyncStream<Int64>.makeStream()
    defer { reports.continuation.finish() }
    let job = makeJob()

    _ = await queue.enqueue(job) { reportProgress, _ in
      for await completedBytes in reports.stream {
        await reportProgress(FileTransferProgress(completedBytes: completedBytes, totalBytes: 100))
      }
    }
    try await waitUntil {
      model.activeJobs.contains { $0.id == job.id && $0.state == .running }
    }
    let progressValues: [Int64] = [10, 20, 30]
    for completedBytes in progressValues {
      reports.continuation.yield(completedBytes)
      try await waitUntil {
        model.activeJobs.contains { $0.id == job.id && $0.completedBytes == completedBytes }
      }
    }
    #expect(evaluations[job.id] == 1)
  }

  @Test("静かなジョブの判定は項目のある同一ボリューム内のローカル移動に限る")
  func quietPolicyRequiresNonemptyAllLocalSameVolumeMove() async throws {
    try await withLocalTransferFiles { item, destination in
      let remote = FileItem(
        remotePath: "/source/remote.txt", url: URL(filePath: "/remote.txt"),
        providerID: FileProviderID(rawValue: "test-remote"), isDirectory: false)
      let move = makeLocalTransferJob(.move, items: [item], destination: destination)
      let copy = makeLocalTransferJob(.copy, items: [item], destination: destination)
      let mixedMove = makeLocalTransferJob(.move, items: [item, remote], destination: destination)
      let emptyMove = makeLocalTransferJob(.move, items: [], destination: destination)

      #expect(TransferQuietJobPolicy.isLocalSameVolumeMove(move))
      #expect(!TransferQuietJobPolicy.isLocalSameVolumeMove(copy))
      #expect(!TransferQuietJobPolicy.isLocalSameVolumeMove(mixedMove))
      #expect(!TransferQuietJobPolicy.isLocalSameVolumeMove(emptyMove))
    }
  }

  @Test("ブラウザ用モデルは1秒遅延し、同一ボリューム内の移動を隠してコピーを表示する")
  func browserFactoryDelaysCopyAndHidesLocalMove() async throws {
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let suiteName = "TransferActivityModelTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let model = TransferActivityModel.forBrowser(
      transferQueue: queue,
      rateLimiter: TransferRateLimiter(),
      preferencesStore: TransferPreferencesStore(defaults: defaults),
      resume: { _ in false })

    #expect(model.minimumDisplayDelay == Duration.seconds(1))
    #expect(TransferActivityModel.browserMinimumDisplayDelay == Duration.seconds(1))

    try await withLocalTransferFiles { item, destination in
      let moveGate = AsyncStream<Void>.makeStream()
      let copyGate = AsyncStream<Void>.makeStream()
      defer {
        moveGate.continuation.finish()
        copyGate.continuation.finish()
      }
      let move = makeLocalTransferJob(.move, items: [item], destination: destination)
      _ = await queue.enqueue(move) { _, _ in
        for await _ in moveGate.stream { break }
      }
      try await expectJobToStayHidden(move, in: model, for: .milliseconds(1_300))
      let jobs = await queue.allJobs()
      #expect(jobs.first(where: { $0.id == move.id })?.state == .running)

      let clock = ContinuousClock()
      let startedAt = clock.now
      let deadline = startedAt.advanced(by: .milliseconds(1_300))
      let copy = makeLocalTransferJob(.copy, items: [item], destination: destination)
      _ = await queue.enqueue(copy) { _, _ in
        for await _ in copyGate.stream { break }
      }
      try await waitUntil(timeout: clock.now.duration(to: deadline)) {
        model.activeJobs.contains { $0.id == copy.id && $0.state == .running }
      }
      #expect(startedAt.duration(to: clock.now) >= .seconds(1))
      #expect(!model.activeJobs.contains { $0.id == move.id })
    }
  }

  private func makeDelayedModel(
    transferQueue: TransferQueue,
    minimumDisplayDelay: Duration,
    isQuietJob: @escaping @MainActor (TransferJob) -> Bool = { _ in false }
  ) -> TransferActivityModel {
    let defaults = UserDefaults(suiteName: "TransferActivityModelTests-\(UUID().uuidString)")!
    return TransferActivityModel(
      transferQueue: transferQueue,
      rateLimiter: TransferRateLimiter(),
      preferencesStore: TransferPreferencesStore(defaults: defaults),
      minimumDisplayDelay: minimumDisplayDelay,
      isQuietJob: isQuietJob)
  }

  private func expectJobToStayHidden(
    _ job: TransferJob, in model: TransferActivityModel, for duration: Duration
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: duration)
    var sampledAt: ContinuousClock.Instant
    repeat {
      sampledAt = clock.now
      if let visibleJob = model.activeJobs.first(where: { $0.id == job.id }) {
        Issue.record("非表示のはずのジョブが \(visibleJob.state) で表示されました")
        return
      }
      if sampledAt < deadline {
        try await clock.sleep(until: min(deadline, sampledAt.advanced(by: .milliseconds(5))))
      }
    } while sampledAt < deadline
  }

  private func withLocalTransferFiles(
    _ body: (FileItem, FileLocation) async throws -> Void
  ) async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? fileManager.removeItem(at: root) }
    let source = root.appendingPathComponent("source.txt")
    try Data("転送元".utf8).write(to: source)
    let destination = root.appendingPathComponent("destination", isDirectory: true)
    try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
    try await body(FileItem(url: source, isDirectory: false), FileLocation(localURL: destination))
  }

  private func makeLocalTransferJob(
    _ kind: TransferJob.Kind, items: [FileItem], destination: FileLocation
  ) -> TransferJob {
    TransferJob(
      kind: kind, items: items, sourceProviderID: .local, destinationProviderID: .local,
      destination: destination)
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
