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
    let delay: Duration = .seconds(2)
    let model = makeDelayedModel(transferQueue: queue, minimumDisplayDelay: delay)
    let job = makeJob()

    _ = await queue.enqueue(job) { _, _ in throw CocoaError(.fileWriteUnknown) }
    try await waitUntil(timeout: .seconds(1)) {
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

  @Test("同一ボリューム移動の記録をキューの購読者へ通知し、未知のIDは無視する")
  func queuePublishesLocalSameVolumeMoveFlagForExistingJob() async throws {
    let store = InMemoryTransferJobStore()
    var job = makeLocalTransferJob(
      .move, items: [FileItem(url: URL(filePath: "/source/report.txt"), isDirectory: false)],
      destination: FileLocation(localURL: URL(filePath: "/destination")))
    job.state = .completed
    try store.save([job])
    let queue = TransferQueue(store: store)
    let updates = await queue.updates()
    var snapshots: [[TransferJob]] = []
    let observation = Task { @MainActor in
      for await snapshot in updates {
        snapshots.append(snapshot)
        if snapshots.count == 2 { break }
      }
    }
    defer { observation.cancel() }

    await queue.markLocalSameVolumeMove(UUID())
    #expect(await queue.allJobs() == [job])

    await queue.markLocalSameVolumeMove(job.id)
    let markedJob = try #require(await queue.allJobs().first)
    #expect(markedJob.id == job.id)
    #expect(markedJob.isLocalSameVolumeMove)
    #expect(markedJob.state == .completed)
    try await waitUntil { snapshots.count == 2 }
    #expect(snapshots.first == [job])
    // 未知のIDで通知した場合、実際にフラグを立てる前の一覧が2件目に届く。
    #expect(snapshots.dropFirst().first == [markedJob])
  }

  @Test("記録が表示遅延より前なら移動を隠し、表示後なら一覧から消す", arguments: [true, false])
  func hidesRunningMoveWhenFlagArrivesBeforeOrAfterDisplay(markBeforeDelay: Bool) async throws {
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let delay: Duration = .milliseconds(300)
    let model = makeDelayedModel(
      transferQueue: queue, minimumDisplayDelay: delay, isQuietJob: { $0.isLocalSameVolumeMove })
    let gate = AsyncStream<Void>.makeStream()
    defer { gate.continuation.finish() }
    let job = makeLocalTransferJob(
      .move, items: [FileItem(url: URL(filePath: "/source/report.txt"), isDirectory: false)],
      destination: FileLocation(localURL: URL(filePath: "/destination")))

    _ = await queue.enqueue(job) { _, _ in
      for await _ in gate.stream { break }
    }
    let earlyObservation: Duration = .milliseconds(100)
    if markBeforeDelay {
      try await expectJobToStayHidden(job, in: model, for: earlyObservation)
    } else {
      try await waitUntil {
        model.activeJobs.contains { $0.id == job.id && $0.state == .running }
      }
    }

    let runningJob = try #require(await queue.allJobs().first)
    #expect(runningJob.state == .running)
    #expect(!runningJob.isLocalSameVolumeMove)
    if markBeforeDelay {
      #expect(Duration.seconds(Date.now.timeIntervalSince(job.createdAt)) < delay)
    }
    await queue.markLocalSameVolumeMove(job.id)

    if markBeforeDelay {
      try await expectJobToStayHidden(
        job, in: model, for: delay + .milliseconds(150) - earlyObservation)
    } else {
      try await waitUntil { !model.activeJobs.contains { $0.id == job.id } }
    }
    #expect(await queue.allJobs().first?.state == .running)
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

  @Test("移動元ファイルが移動済みでも同一ボリューム内のローカル移動と判定する")
  func quietPolicyRecognizesLocalMoveAfterSourceHasMoved() async throws {
    try await withLocalTransferFiles { item, destination in
      let sourceURL = try #require(item.location.localURL)
      let destinationURL = try #require(destination.localURL)
      try FileManager.default.moveItem(
        at: sourceURL, to: destinationURL.appendingPathComponent(item.name))
      let move = makeLocalTransferJob(.move, items: [item], destination: destination)

      #expect(TransferQuietJobPolicy.isLocalSameVolumeMove(move))
    }
  }

  @Test("同じ親フォルダからの2万件のローカル移動を0.1秒未満で判定する")
  func quietPolicyRecognizesTwentyThousandItemsFromOneDirectoryWithinBudget() async throws {
    try await withLocalTransferFiles { item, destination in
      let sourceURL = try #require(item.location.localURL)
      let sourceDirectory = sourceURL.deletingLastPathComponent()
      let items = (0..<20_000).map { index in
        FileItem(
          url: sourceDirectory.appendingPathComponent("item-\(index).txt"), isDirectory: false)
      }
      let move = makeLocalTransferJob(.move, items: items, destination: destination)

      let clock = ContinuousClock()
      let startedAt = clock.now
      let isLocalMove = TransferQuietJobPolicy.isLocalSameVolumeMove(move)
      let elapsed = startedAt.duration(to: clock.now)

      #expect(isLocalMove)
      #expect(elapsed < Duration.milliseconds(100))
    }
  }

  @Test("マウントポイントは自身、通常ファイルは親フォルダのボリュームで判定する")
  func quietPolicyQueriesMountPointAndRegularFileParent() {
    let destination = FileLocation(localURL: URL(filePath: "/destination"))
    let mountPoint = FileItem(url: URL(filePath: "/Volumes/External"), isDirectory: true)
    let regularFile = FileItem(url: URL(filePath: "/Volumes/report.txt"), isDirectory: false)
    let volumeIdentifiers = [
      "/destination": "internal",
      "/Volumes": "internal",
      "/Volumes/External": "external",
    ]
    var queriedPaths: Set<String> = []
    let volumeIdentifier: (URL) -> String? = { url in
      queriedPaths.insert(url.path)
      return volumeIdentifiers[url.path]
    }

    let directoryMove = makeLocalTransferJob(.move, items: [mountPoint], destination: destination)
    #expect(
      !TransferQuietJobPolicy.isLocalSameVolumeMove(
        directoryMove, volumeIdentifier: volumeIdentifier))
    #expect(queriedPaths.contains("/Volumes/External"))

    queriedPaths.removeAll()
    let fileMove = makeLocalTransferJob(.move, items: [regularFile], destination: destination)
    #expect(
      TransferQuietJobPolicy.isLocalSameVolumeMove(
        fileMove, volumeIdentifier: volumeIdentifier))
    #expect(queriedPaths == ["/destination", "/Volumes"])
  }

  @Test("同一ボリューム移動の記録はJSONに保存され、旧形式ではfalseになる")
  func roundTripsLocalSameVolumeMoveFlagAndDefaultsLegacyJSONToFalse() throws {
    var job = makeLocalTransferJob(
      .move, items: [FileItem(url: URL(filePath: "/source/report.txt"), isDirectory: false)],
      destination: FileLocation(localURL: URL(filePath: "/destination")))
    #expect(!job.isLocalSameVolumeMove)
    job.isLocalSameVolumeMove = true

    let encoded = try JSONEncoder().encode(job)
    let decoded = try JSONDecoder().decode(TransferJob.self, from: encoded)
    #expect(decoded.isLocalSameVolumeMove)

    let json = try JSONSerialization.jsonObject(with: encoded)
    var legacy = try #require(json as? [String: Any])
    legacy.removeValue(forKey: "isLocalSameVolumeMove")
    let legacyData = try JSONSerialization.data(withJSONObject: legacy)
    let legacyJob = try JSONDecoder().decode(TransferJob.self, from: legacyData)
    #expect(!legacyJob.isLocalSameVolumeMove)
  }

  @Test("ブラウザ用モデルは同一ボリューム移動と記録されたジョブを隠し、コピーを1秒後に表示する")
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
      // 記録後に宛先を参照できなくなっても、モデルはフラグで表示を判断する。
      let missingDestination = try #require(destination.appending(pathComponent: "missing"))
      var move = makeLocalTransferJob(.move, items: [item], destination: missingDestination)
      move.isLocalSameVolumeMove = true
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

  @Test("既定のモデルでは同一ボリューム移動と記録されたジョブも表示する")
  func defaultModelShowsFlaggedLocalSameVolumeMove() async throws {
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let model = makeModel(transferQueue: queue)
    let gate = AsyncStream<Void>.makeStream()
    defer { gate.continuation.finish() }

    try await withLocalTransferFiles { item, destination in
      var move = makeLocalTransferJob(.move, items: [item], destination: destination)
      move.isLocalSameVolumeMove = true
      _ = await queue.enqueue(move) { _, _ in
        for await _ in gate.stream { break }
      }
      try await waitUntil {
        model.activeJobs.contains { $0.id == move.id && $0.state == .running }
      }
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
