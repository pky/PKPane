import Foundation
import Synchronization
import Testing

@testable import PKPane

struct TransferQueueTests {
  @Test("失敗ジョブは秘密情報を除去して永続化する")
  func persistsMaskedFailureDescription() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "TransferQueueMaskTests-\(UUID().uuidString)",
      directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = JSONTransferJobStore(url: directory.appending(path: "transfer-jobs.json"))
    let queue = TransferQueue(store: store, maximumConcurrentTransfers: 1)
    let job = makeJob()
    let homePath = NSHomeDirectory()

    _ = await queue.enqueue(job) { _, _ in
      throw NSError(
        domain: "TransferFixture",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "失敗: \(homePath)/Documents/秘密.txt"])
    }
    _ = try await waitForState(.failed, jobID: job.id, in: queue)
    let restored = try #require(try store.load().first)

    #expect(restored.errorDescription?.contains("~/Documents/秘密.txt") == true)
    #expect(restored.errorDescription?.contains(homePath) == false)
  }

  @Test("レガシーJSONの生エラー文字列を読込時にマスクする")
  func masksLegacyFailureDescriptionWhenLoading() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "TransferQueueLegacyMaskTests-\(UUID().uuidString)",
      directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "transfer-jobs.json")
    let homePath = NSHomeDirectory()
    var job = makeJob()
    job.state = .failed
    job.errorDescription = "書き込み失敗: \(homePath)/Downloads/report.txt"
    try JSONEncoder().encode([job]).write(to: url)

    let restored = try #require(try JSONTransferJobStore(url: url).load().first)

    #expect(restored.errorDescription == "書き込み失敗: ~/Downloads/report.txt")
    #expect(!restored.errorDescription!.contains(homePath))
  }

  @Test("転送ジョブを永続化し、実行中だったジョブを中断として復元する")
  func restoresRunningJobAsInterrupted() async throws {
    let store = InMemoryTransferJobStore()
    let queue = TransferQueue(store: store, maximumConcurrentTransfers: 1)
    let job = makeJob()

    _ = await queue.enqueue(job) { _, _ in
      try await Task.sleep(for: .seconds(10))
    }
    await Task.yield()

    let restoredQueue = TransferQueue(store: store, maximumConcurrentTransfers: 1)
    let restored = try #require(await restoredQueue.allJobs().first)

    #expect(restored.state == .interrupted)
    #expect(restored.errorDescription?.contains("中断") == true)
  }

  @Test("失敗した転送を先頭から再試行し、進捗と完了状態を保存する")
  func retriesFailedJobFromBeginning() async throws {
    let store = InMemoryTransferJobStore()
    let queue = TransferQueue(store: store, maximumConcurrentTransfers: 1)
    let job = makeJob()
    _ = await queue.enqueue(job) { _, _ in throw CocoaError(.fileWriteUnknown) }
    let failed = try await waitForState(.failed, jobID: job.id, in: queue)
    #expect(failed.completedBytes == 0)

    await queue.retry(job.id) { report, _ in
      await report(FileTransferProgress(completedBytes: 4, totalBytes: 4))
    }
    let completed = try await waitForState(.completed, jobID: job.id, in: queue)

    #expect(completed.completedBytes == 4)
    #expect(completed.totalBytes == 4)
  }

  @Test("cancel()後にProviderがCancellationError以外の生エラーでfinishしても構造的に.cancelledへ確定する")
  func forcesCancelledStateEvenWhenExecutionThrowsPlainErrorAfterCancel() async throws {
    // 自動再接続(P1-3) Fix C: キャンセル判定を型(CancellationError)だけに頼ると、
    // Providerの実装がキャンセルを正しく伝播できずプレーンなエラーを投げた場合に
    // .failedとして扱われ、誤って自動リトライされてしまう恐れがある。cancel()が
    // 呼ばれたという構造的な事実(cancelledJobIDs)を優先することで、これを防ぐ。
    let store = InMemoryTransferJobStore()
    let queue = TransferQueue(store: store, maximumConcurrentTransfers: 1)
    let job = makeJob()
    let gate = TransferGate()

    _ = await queue.enqueue(job) { _, _ in
      await gate.wait()
      // cancel()経由でTask.cancel()されても、Providerの実装が反応できず
      // CancellationError以外の生エラーを投げてしまった状況を模す。
      throw CocoaError(.fileWriteUnknown)
    }
    await Task.yield()

    await queue.cancel(job.id)
    await gate.open()

    let cancelled = try await waitForState(.cancelled, jobID: job.id, in: queue)
    #expect(cancelled.errorDescription?.contains("キャンセル") == true)
  }

  @Test("自動リトライのバックオフ待ち中でもcancel()が効き.cancelledで確定する")
  func cancelDuringAutomaticRetryBackoffStopsTheJob() async throws {
    // 自動再接続(P1-3) Fix A: バックオフ待ちの間もjobのstateを.runningのまま維持する
    // (activity barへ新しい状態・文言を見せないため)。この設計だと、バックオフ中に
    // 既存のcancel()操作が正しく効くことを別途保証する必要がある。
    let store = InMemoryTransferJobStore()
    let queue = TransferQueue(store: store, maximumConcurrentTransfers: 1)
    let job = makeJob()
    let failedItem = try #require(job.items.first)
    let attemptCount = Mutex<Int>(0)
    let makeFailure: @Sendable () -> TransferJobPartialFailure = {
      TransferJobPartialFailure(
        failedItems: [failedItem], underlyingErrorDescription: "書き込みに失敗しました。")
    }

    _ = await queue.enqueue(
      job,
      execution: { _, _ in
        attemptCount.withLock { $0 += 1 }
        throw makeFailure()
      },
      autoRetryPlanner: { isReconnectFutile in
        guard !isReconnectFutile else { return nil }
        return (
          .seconds(10),
          { _, _ in
            attemptCount.withLock { $0 += 1 }
            throw makeFailure()
          }
        )
      })

    // 最初の実行が失敗し、10秒のバックオフへ入るまで待つ(この間attemptCountは1のまま)。
    for _ in 0..<200 {
      if attemptCount.withLock({ $0 }) >= 1 { break }
      await Task.yield()
    }
    // バックオフ中はstateが.runningのまま維持され、activity barには進行中に見える。
    let duringBackoff = try #require(await queue.allJobs().first)
    #expect(duringBackoff.state == .running)

    await queue.cancel(job.id)

    let cancelled = try await waitForState(.cancelled, jobID: job.id, in: queue)
    #expect(cancelled.errorDescription?.contains("キャンセル") == true)
    // バックオフが明けての2回目の実行(2回目のattemptCount加算)には至っていないはず。
    #expect(attemptCount.withLock { $0 } == 1)
  }

  @Test("自動リトライplannerのawait中にcancel()が届いても取りこぼさず.cancelledで確定する")
  func cancelDuringAutoRetryPlannerAwaitStopsTheJob() async throws {
    // 自動再接続(P1-3) Fix C': autoRetryPlannerは宛先stat並列8+列挙などを伴い秒単位の
    // await窓を持つ。この間にcancel()が届くと、自動リトライ用のバックオフTaskは
    // まだ作られておらずrunningTasks[id]?.cancel()が届かない。cancelledJobIDsへの
    // 記録だけが残るケースをplannerのawaitをgateで意図的に遅延させて再現し、
    // planner完了後に自動リトライへ進まず正しく.cancelledへ確定することを証明する。
    let store = InMemoryTransferJobStore()
    let queue = TransferQueue(store: store, maximumConcurrentTransfers: 1)
    let job = makeJob()
    let failedItem = try #require(job.items.first)
    let attemptCount = Mutex<Int>(0)
    let plannerEntered = TransferGate()
    let plannerGate = TransferGate()
    let makeFailure: @Sendable () -> TransferJobPartialFailure = {
      TransferJobPartialFailure(
        failedItems: [failedItem], underlyingErrorDescription: "書き込みに失敗しました。")
    }

    _ = await queue.enqueue(
      job,
      execution: { _, _ in
        attemptCount.withLock { $0 += 1 }
        throw makeFailure()
      },
      autoRetryPlanner: { isReconnectFutile in
        guard !isReconnectFutile else { return nil }
        await plannerEntered.open()
        await plannerGate.wait()
        return (
          .milliseconds(1),
          { _, _ in
            attemptCount.withLock { $0 += 1 }
            throw makeFailure()
          }
        )
      })

    // plannerがawait中(plannerGateで止まっている)に到達するまで待つ。
    await plannerEntered.wait()
    // この時点でrunningTasks[id]はまだ自動リトライ用のTaskに差し替わっていない
    // (handleAttemptFailureがawait中のため)。cancel()はcancelledJobIDsへの記録
    // として残るはず。
    await queue.cancel(job.id)
    await plannerGate.open()

    let cancelled = try await waitForState(.cancelled, jobID: job.id, in: queue)
    #expect(cancelled.errorDescription?.contains("キャンセル") == true)
    // plannerが返した実行(2回目のattemptCount加算)には至っていないはず。
    #expect(attemptCount.withLock { $0 } == 1)
  }

  @Test("nilを返すplannerのawait中にpauseしても.failedへ落ちず.pausedで確定する")
  func pauseDuringNilAutoRetryPlannerAwaitStopsTheJob() async throws {
    let queue = TransferQueue(store: InMemoryTransferJobStore(), maximumConcurrentTransfers: 1)
    let job = makeJob()
    let failedItem = try #require(job.items.first)
    let plannerEntered = TransferGate()
    let plannerGate = TransferGate()

    _ = await queue.enqueue(
      job,
      execution: { _, _ in
        throw TransferJobPartialFailure(
          failedItems: [failedItem], underlyingErrorDescription: "接続に失敗しました。")
      },
      autoRetryPlanner: { _ in
        await plannerEntered.open()
        await plannerGate.wait()
        return nil
      })

    await plannerEntered.wait()
    await queue.pause(job.id)
    await plannerGate.open()

    let paused = try await waitForState(.paused, jobID: job.id, in: queue)
    #expect(paused.errorDescription == nil)
  }

  @Test("terminalなジョブへのcancel()が残したcancelledJobIDsは手動retryの入口でクリアされる")
  func manualRetryClearsStaleCancelledJobIDFromPriorTerminalCancel() async throws {
    // 自動再接続(P1-3) Fix C'': terminal状態(ここでは.failed)のジョブへcancel()を
    // 呼ぶと、runningTasks[id]が存在せずfinishが呼ばれないため、cancelledJobIDsへ
    // 記録だけが残り続ける。この状態のまま同じidで手動retry()すると、次の失敗時に
    // 誤って「キャンセルしました」と表示される(実際はユーザーはキャンセルしていない)。
    // retry()の入口でクリアすることで、この誤表示を防ぐ。
    let store = InMemoryTransferJobStore()
    let queue = TransferQueue(store: store, maximumConcurrentTransfers: 1)
    let job = makeJob()

    _ = await queue.enqueue(job) { _, _ in throw CocoaError(.fileWriteUnknown) }
    let failed = try await waitForState(.failed, jobID: job.id, in: queue)
    #expect(failed.state == .failed)

    // すでにterminal(.failed)なジョブへcancel()を呼ぶ。runningTasksが存在しないため
    // 何も起きないように見えるが、Fix C''前はcancelledJobIDsへゴミが残っていた。
    await queue.cancel(job.id)

    await queue.retry(job.id) { _, _ in throw CocoaError(.fileWriteUnknown) }

    let refailed = try await waitForState(.failed, jobID: job.id, in: queue)
    // ユーザーはキャンセルしていないため、誤って「キャンセルしました」にならず
    // 通常の失敗として確定するはず。
    #expect(refailed.state == .failed)
    #expect(refailed.errorDescription?.contains("キャンセル") != true)
  }

  @Test("待機中ジョブを一時停止すると実行対象から外れる")
  func pausesQueuedJobAndSkipsItWhenStartingAvailableJobs() async throws {
    let store = InMemoryTransferJobStore()
    let queue = TransferQueue(store: store, maximumConcurrentTransfers: 1)
    let running = makeJob()
    let paused = makeJob()
    let gate = TransferGate()
    let pausedExecutionCount = Mutex<Int>(0)

    _ = await queue.enqueue(running) { _, _ in await gate.wait() }
    _ = await queue.enqueue(paused) { _, _ in
      pausedExecutionCount.withLock { $0 += 1 }
    }
    await queue.pause(paused.id)
    await gate.open()
    _ = try await waitForState(.completed, jobID: running.id, in: queue)
    let pausedJob = try await waitForState(.paused, jobID: paused.id, in: queue)

    #expect(pausedJob.state == .paused)
    #expect(pausedExecutionCount.withLock { $0 } == 0)
  }

  @Test("実行中ジョブの一時停止は完了項目とその進捗を温存する")
  func pausesRunningJobWithoutTurningItIntoCancelled() async throws {
    let store = InMemoryTransferJobStore()
    let queue = TransferQueue(store: store, maximumConcurrentTransfers: 1)
    let job = makeJob()
    let completedItem = try #require(job.items.first)
    let gate = TransferGate()

    _ = await queue.enqueue(job) { report, itemCompleted in
      await itemCompleted(completedItem)
      await report(FileTransferProgress(completedBytes: 6, totalBytes: 8))
      await gate.wait()
      throw CocoaError(.fileWriteUnknown)
    }
    await Task.yield()
    await queue.pause(job.id)
    await gate.open()

    let paused = try await waitForState(.paused, jobID: job.id, in: queue)
    #expect(paused.completedItems == [completedItem])
    #expect(paused.completedBytes == completedItem.totalBytes)
    #expect(paused.state != .cancelled)
  }

  @Test("自動リトライのバックオフ待ち中でも一時停止できる")
  func pausesDuringAutomaticRetryBackoff() async throws {
    let store = InMemoryTransferJobStore()
    let queue = TransferQueue(store: store, maximumConcurrentTransfers: 1)
    let job = makeJob()
    let failedItem = try #require(job.items.first)
    let attemptCount = Mutex<Int>(0)
    let makeFailure: @Sendable () -> TransferJobPartialFailure = {
      TransferJobPartialFailure(
        failedItems: [failedItem], underlyingErrorDescription: "書き込みに失敗しました。")
    }

    _ = await queue.enqueue(
      job,
      execution: { _, _ in
        attemptCount.withLock { $0 += 1 }
        throw makeFailure()
      },
      autoRetryPlanner: { _ in
        (
          .seconds(10),
          { _, _ in
            attemptCount.withLock { $0 += 1 }
            throw makeFailure()
          }
        )
      })
    await waitUntil("自動リトライが期限内に1回実行されなかった") {
      attemptCount.withLock { $0 } != 0
    }
    #expect(attemptCount.withLock { $0 } == 1)

    await queue.pause(job.id)

    _ = try await waitForState(.paused, jobID: job.id, in: queue)
    #expect(attemptCount.withLock { $0 } == 1)
  }

  @Test("一時停止ジョブの再開は待機列の末尾へ戻して実行する")
  func resumesPausedJobAtEndOfQueuedJobs() async throws {
    let store = InMemoryTransferJobStore()
    let queue = TransferQueue(store: store, maximumConcurrentTransfers: 1)
    let running = makeJob()
    let paused = makeJob()
    let earlier = makeJob()
    let gate = TransferGate()
    let completionOrder = Mutex<[UUID]>([])

    _ = await queue.enqueue(running) { _, _ in await gate.wait() }
    _ = await queue.enqueue(paused) { _, _ in }
    await queue.pause(paused.id)
    _ = await queue.enqueue(earlier) { _, _ in
      completionOrder.withLock { $0.append(earlier.id) }
    }
    await queue.resume(paused.id) { _, _ in
      completionOrder.withLock { $0.append(paused.id) }
    }

    #expect(await queue.allJobs().first(where: { $0.id == paused.id })?.state == .queued)
    await gate.open()
    _ = try await waitForState(.completed, jobID: paused.id, in: queue)
    #expect(completionOrder.withLock { $0 } == [earlier.id, paused.id])
  }

  @Test("一時停止中のジョブはキャンセルできる")
  func cancelsPausedJob() async throws {
    let store = InMemoryTransferJobStore()
    let queue = TransferQueue(store: store, maximumConcurrentTransfers: 1)
    let running = makeJob()
    let paused = makeJob()
    let gate = TransferGate()

    _ = await queue.enqueue(running) { _, _ in await gate.wait() }
    _ = await queue.enqueue(paused) { _, _ in }
    await queue.pause(paused.id)
    await queue.cancel(paused.id)

    _ = try await waitForState(.cancelled, jobID: paused.id, in: queue)
    await gate.open()
  }

  @Test("実行中ジョブの一時停止で空いたスロットは次の待機ジョブへ渡る")
  func startsNextQueuedJobAfterRunningJobPauses() async throws {
    let store = InMemoryTransferJobStore()
    let queue = TransferQueue(store: store, maximumConcurrentTransfers: 1)
    let running = makeJob()
    let next = makeJob()
    let runningGate = TransferGate()
    let nextGate = TransferGate()

    _ = await queue.enqueue(running) { _, _ in
      await runningGate.wait()
      throw CancellationError()
    }
    _ = await queue.enqueue(next) { _, _ in await nextGate.wait() }
    await queue.pause(running.id)
    await runningGate.open()

    _ = try await waitForState(.paused, jobID: running.id, in: queue)
    _ = try await waitForState(.running, jobID: next.id, in: queue)
    await nextGate.open()
  }

  @Test("一時停止状態は永続化と復元をまたいで維持される")
  func persistsAndRestoresPausedJob() async throws {
    let store = InMemoryTransferJobStore()
    let queue = TransferQueue(store: store, maximumConcurrentTransfers: 1)
    let job = makeJob()
    let gate = TransferGate()

    _ = await queue.enqueue(job) { _, _ in
      await gate.wait()
      throw CancellationError()
    }
    await queue.pause(job.id)
    await gate.open()
    _ = try await waitForState(.paused, jobID: job.id, in: queue)

    let restoredQueue = TransferQueue(store: store, maximumConcurrentTransfers: 1)
    let restored = try #require(await restoredQueue.allJobs().first)
    #expect(restored.state == .paused)
  }

  @Test("一時停止ジョブは終了履歴の上限超過でも刈り込まれない")
  func keepsPausedJobWhenTrimmingTerminalHistory() async throws {
    let store = InMemoryTransferJobStore()
    var paused = makeJob()
    paused.state = .paused
    let terminalJobs = (0...TransferJobHistoryPolicy.terminalLimit).map { index in
      var job = makeJob()
      job.state = .completed
      job.updatedAt = Date(timeIntervalSince1970: Double(index))
      return job
    }
    try store.save(terminalJobs + [paused])

    let queue = TransferQueue(store: store, maximumConcurrentTransfers: 1)

    #expect(await queue.allJobs().count == TransferJobHistoryPolicy.terminalLimit + 1)
    #expect(await queue.allJobs().contains(where: { $0.id == paused.id && $0.state == .paused }))
  }

  @Test("正常完了後に届くpauseより.completedが勝つ")
  func completedStateWinsOverLatePause() async throws {
    let queue = TransferQueue(store: InMemoryTransferJobStore(), maximumConcurrentTransfers: 1)
    let job = makeJob()
    let gate = TransferGate()

    _ = await queue.enqueue(job) { _, _ in await gate.wait() }
    _ = try await waitForState(.running, jobID: job.id, in: queue)
    await gate.open()
    _ = try await waitForState(.completed, jobID: job.id, in: queue)
    await queue.pause(job.id)

    #expect(await queue.allJobs().first(where: { $0.id == job.id })?.state == .completed)
  }

  @Test("cancelの後にpauseが届いても.cancelledが勝つ")
  func cancelWinsWhenPauseArrivesLater() async throws {
    let queue = TransferQueue(store: InMemoryTransferJobStore(), maximumConcurrentTransfers: 1)
    let job = makeJob()
    let gate = TransferGate()

    _ = await queue.enqueue(job) { _, _ in
      await gate.wait()
      throw CocoaError(.fileWriteUnknown)
    }
    _ = try await waitForState(.running, jobID: job.id, in: queue)
    await queue.cancel(job.id)
    await queue.pause(job.id)
    await gate.open()

    _ = try await waitForState(.cancelled, jobID: job.id, in: queue)
  }

  @Test("pauseの後にcancelが届くと.cancelledが勝つ")
  func cancelWinsWhenPauseArrivesFirst() async throws {
    let queue = TransferQueue(store: InMemoryTransferJobStore(), maximumConcurrentTransfers: 1)
    let job = makeJob()
    let gate = TransferGate()

    _ = await queue.enqueue(job) { _, _ in
      await gate.wait()
      throw CocoaError(.fileWriteUnknown)
    }
    _ = try await waitForState(.running, jobID: job.id, in: queue)
    await queue.pause(job.id)
    await queue.cancel(job.id)
    await gate.open()

    _ = try await waitForState(.cancelled, jobID: job.id, in: queue)
  }

  @Test("二重resumeは先着だけを受理しexecutionを二重登録しない")
  func duplicateResumeRunsOnlyTheFirstExecution() async throws {
    let queue = TransferQueue(store: InMemoryTransferJobStore(), maximumConcurrentTransfers: 1)
    let blocker = makeJob()
    let job = makeJob()
    let blockerGate = TransferGate()
    let firstCount = Mutex<Int>(0)
    let secondCount = Mutex<Int>(0)

    _ = await queue.enqueue(blocker) { _, _ in await blockerGate.wait() }
    _ = await queue.enqueue(job) { _, _ in }
    await queue.pause(job.id)

    let firstAccepted = await queue.resume(job.id) { _, _ in
      firstCount.withLock { $0 += 1 }
    }
    let secondAccepted = await queue.resume(job.id) { _, _ in
      secondCount.withLock { $0 += 1 }
    }
    await blockerGate.open()

    #expect(firstAccepted)
    #expect(!secondAccepted)
    _ = try await waitForState(.completed, jobID: job.id, in: queue)
    #expect(firstCount.withLock { $0 } == 1)
    #expect(secondCount.withLock { $0 } == 0)
  }

  @Test("キューは同時実行数を制限し、待機中のジョブを順に開始する")
  func limitsConcurrentTransfers() async throws {
    let store = InMemoryTransferJobStore()
    let queue = TransferQueue(store: store, maximumConcurrentTransfers: 1)
    let first = makeJob()
    let second = makeJob()
    let gate = TransferGate()

    _ = await queue.enqueue(first) { _, _ in await gate.wait() }
    _ = await queue.enqueue(second) { _, _ in await gate.wait() }
    await Task.yield()

    let queued = await queue.allJobs()
    #expect(queued.first(where: { $0.id == first.id })?.state == .running)
    #expect(queued.first(where: { $0.id == second.id })?.state == .queued)

    await gate.open()
    _ = try await waitForState(.completed, jobID: first.id, in: queue)
    _ = try await waitForState(.completed, jobID: second.id, in: queue)
  }

  @Test("待機中ジョブを前後へ移動すると変更後の順で実行する")
  func movesQueuedJobsEarlierAndLater() async throws {
    let store = InMemoryTransferJobStore()
    let queue = TransferQueue(store: store, maximumConcurrentTransfers: 1)
    let running = makeJob()
    let first = makeJob()
    let second = makeJob()
    let third = makeJob()
    let gate = TransferGate()
    let completionOrder = Mutex<[UUID]>([])

    _ = await queue.enqueue(running) { _, _ in await gate.wait() }
    for job in [first, second, third] {
      _ = await queue.enqueue(job) { _, _ in
        completionOrder.withLock { $0.append(job.id) }
      }
    }

    await queue.moveQueuedJobEarlier(second.id)
    await queue.moveQueuedJobLater(first.id)
    await gate.open()

    _ = try await waitForState(.completed, jobID: first.id, in: queue)
    #expect(completionOrder.withLock { $0 } == [second.id, third.id, first.id])
  }

  @Test("端・実行中・終了済みジョブの順序変更は何もしない")
  func ignoresInvalidQueuedJobMoves() async throws {
    let store = InMemoryTransferJobStore()
    let queue = TransferQueue(store: store, maximumConcurrentTransfers: 1)
    let terminal = makeJob()
    _ = await queue.enqueue(terminal) { _, _ in }
    _ = try await waitForState(.completed, jobID: terminal.id, in: queue)

    let running = makeJob()
    let first = makeJob()
    let last = makeJob()
    let gate = TransferGate()
    _ = await queue.enqueue(running) { _, _ in await gate.wait() }
    _ = await queue.enqueue(first) { _, _ in }
    _ = await queue.enqueue(last) { _, _ in }
    let originalIDs = store.snapshot().map(\.id)

    await queue.moveQueuedJobEarlier(first.id)
    await queue.moveQueuedJobLater(last.id)
    await queue.moveQueuedJobEarlier(running.id)
    await queue.moveQueuedJobLater(terminal.id)

    #expect(store.snapshot().map(\.id) == originalIDs)
    await gate.open()
  }

  @Test("実行中ジョブを挟む待機中ジョブの入れ替えを永続化する")
  func persistsQueuedMoveAcrossRunningJob() async throws {
    let store = InMemoryTransferJobStore()
    let queue = TransferQueue(store: store, maximumConcurrentTransfers: 1)
    let earlier = makeJob()
    _ = await queue.enqueue(earlier) { _, _ in }
    _ = try await waitForState(.completed, jobID: earlier.id, in: queue)

    let running = makeJob()
    let later = makeJob()
    let gate = TransferGate()
    _ = await queue.enqueue(running) { _, _ in await gate.wait() }
    _ = await queue.enqueue(later) { _, _ in }
    await queue.retry(earlier.id) { _, _ in }

    await queue.moveQueuedJobEarlier(later.id)

    #expect(store.snapshot().map(\.id) == [later.id, running.id, earlier.id])
    await gate.open()
  }

  @Test("部分失敗したジョブは失敗項目だけを再試行対象として保存する")
  func retainsOnlyFailedItems() async throws {
    let store = InMemoryTransferJobStore()
    let queue = TransferQueue(store: store, maximumConcurrentTransfers: 1)
    let job = makeJob()
    let failedItem = try #require(job.items.first)

    _ = await queue.enqueue(job) { _, _ in
      throw TransferJobPartialFailure(
        failedItems: [failedItem],
        underlyingErrorDescription: "書き込みに失敗しました。")
    }
    let failed = try await waitForState(.failed, jobID: job.id, in: queue)

    #expect(failed.items == [failedItem])
  }

  @Test("完了報告した項目はcompletedItemsへ蓄積される")
  func accumulatesReportedItemsIntoCompletedItems() async throws {
    let store = InMemoryTransferJobStore()
    let queue = TransferQueue(store: store, maximumConcurrentTransfers: 1)
    let job = makeJob()
    let completedItem = try #require(job.items.first)

    _ = await queue.enqueue(job) { _, itemCompleted in
      await itemCompleted(completedItem)
      throw CocoaError(.fileWriteUnknown)
    }
    let failed = try await waitForState(.failed, jobID: job.id, in: queue)

    #expect(failed.completedItems == [completedItem])
  }

  @Test("ジョブが完了したらcompletedItemsをクリアする")
  func clearsCompletedItemsWhenJobCompletes() async throws {
    let store = InMemoryTransferJobStore()
    let queue = TransferQueue(store: store, maximumConcurrentTransfers: 1)
    let job = makeJob()
    let completedItem = try #require(job.items.first)

    _ = await queue.enqueue(job) { _, itemCompleted in
      await itemCompleted(completedItem)
    }
    let completed = try await waitForState(.completed, jobID: job.id, in: queue)

    #expect(completed.completedItems.isEmpty)
  }

  @Test("1万件の重複完了通知は順序を保って合流し、一時停止まで永続化をまとめる")
  func debouncesPersistenceForTenThousandCompletedLeaves() async throws {
    let store = CountingTransferJobStore()
    let queue = TransferQueue(
      store: store,
      maximumConcurrentTransfers: 1,
      itemCompletionPersistDebounce: .milliseconds(50),
      maximumPersistDelay: .seconds(30))
    let job = makeJob(itemCount: 10_000)
    let gate = TransferGate()

    _ = await queue.enqueue(job) { _, itemCompleted in
      for item in job.items {
        await itemCompleted(item)
        await itemCompleted(item)
      }
      await gate.wait()
      try Task.checkCancellation()
    }
    await waitUntil(timeout: .seconds(5), "完了アイテム数が期限内に全件に達しなかった") {
      (await queue.allJobs().first?.completedItems.count ?? 0) >= job.items.count
    }
    let running = await queue.allJobs().first
    #expect(running?.state == .running)
    #expect(running?.completedItems == job.items)
    try? await Task.sleep(for: .milliseconds(100))

    await queue.pause(job.id)
    await gate.open()
    let paused = try await waitForState(.paused, jobID: job.id, in: queue)

    #expect(paused.completedItems.count == 10_000)
    #expect(paused.completedItems == job.items)
    // 初期化・enqueue・running・デバウンス・pause確定の定数回だけstore.saveされる。
    // maximumPersistDelayはテスト中の並走負荷で強制flushが混ざらないよう十分長くしている。
    #expect(store.saveCount() <= 6)
  }

  @Test("完了項目の永続化は短時間にデバウンスされ、ジョブ終了時は必ず即時反映する")
  func debouncesItemCompletionPersistenceButFlushesImmediatelyOnFinish() async throws {
    let store = CountingTransferJobStore()
    let queue = TransferQueue(
      store: store, maximumConcurrentTransfers: 1, itemCompletionPersistDebounce: .milliseconds(60))
    let job = makeJob(itemCount: 5)
    let items = job.items
    let gate = AsyncStream<Void>.makeStream()

    _ = await queue.enqueue(job) { _, itemCompleted in
      for item in items { await itemCompleted(item) }
      for await _ in gate.stream { break }
    }
    await Task.yield()
    let baselineSaveCount = store.saveCount()

    // デバウンス窓より十分長く待つ。ジョブはまだrunning中(finishのflushはまだ走っていない)
    // なので、5件のitemCompletedが合流して1回の書き込みになっているはず。
    try? await Task.sleep(for: .milliseconds(180))
    #expect(await queue.allJobs().first?.state == .running)
    let saveCountWhileRunning = store.saveCount()
    #expect(saveCountWhileRunning - baselineSaveCount == 1)

    gate.continuation.yield()
    gate.continuation.finish()
    let completed = try await waitForState(.completed, jobID: job.id, in: queue)

    #expect(completed.completedItems.isEmpty)
    #expect(store.saveCount() == saveCountWhileRunning + 1)
  }

  @Test("高頻度の完了が続いてもデバウンスの最大遅延を超えたら強制的にフラッシュする")
  func flushesPersistPeriodicallyUnderContinuousHighFrequencyCompletions() async throws {
    let store = CountingTransferJobStore()
    let queue = TransferQueue(
      store: store,
      maximumConcurrentTransfers: 1,
      itemCompletionPersistDebounce: .milliseconds(30),
      maximumPersistDelay: .milliseconds(150))
    let job = makeJob(itemCount: 200)
    let items = job.items
    let gate = AsyncStream<Void>.makeStream()
    let stopProducing = Mutex(false)
    defer {
      stopProducing.withLock { $0 = true }
      gate.continuation.finish()
    }

    _ = await queue.enqueue(job) { _, itemCompleted in
      for item in items {
        if stopProducing.withLock({ $0 }) { break }
        await itemCompleted(item)
        // デバウンス幅(30ms)より短い間隔で完了させ続け、純粋なデバウンスなら
        // 毎回張り直されて一度もflushされない状況を再現する。
        try? await Task.sleep(for: .milliseconds(10))
      }
      for await _ in gate.stream { break }
    }
    await Task.yield()
    let baseline = store.saveCount()

    // 900ms分(高頻度完了が続く間)。150msの上限が無ければデバウンスが張り直され続けて
    // flushが0回のはずだが、上限があるため複数回flushされているはず。
    try? await Task.sleep(for: .milliseconds(900))
    #expect(await queue.allJobs().first?.state == .running)
    let saveCountDuringHighFrequency = store.saveCount()
    #expect(saveCountDuringHighFrequency - baseline >= 4)

    stopProducing.withLock { $0 = true }
    gate.continuation.yield()
    gate.continuation.finish()
    _ = try await waitForState(.completed, jobID: job.id, in: queue)
  }

  @Test("completedItemsキーの無い旧形式jsonも空配列として復元できる")
  func decodesLegacyJobJSONWithoutCompletedItemsKey() throws {
    let legacyJSON = """
      {
        "id": "8C8B7B7D-9C0A-4B0E-9A0A-1F1D9E9A0B10",
        "kind": "copy",
        "items": [],
        "sourceProviderID": "source",
        "destinationProviderID": "destination",
        "destination": { "providerID": "destination", "path": { "remote": { "_0": "." } } },
        "createdAt": 780000000,
        "state": "completed",
        "completedBytes": 0,
        "updatedAt": 780000000
      }
      """
    let job = try JSONDecoder().decode(TransferJob.self, from: Data(legacyJSON.utf8))

    #expect(job.completedItems.isEmpty)
  }

  @Test("TransferJob.ItemはisSymbolicLinkを保持しfileItemへの復元でも失われない")
  func itemPreservesIsSymbolicLinkThroughFileItemRoundTrip() throws {
    let providerID = FileProviderID(rawValue: "source")
    let symlink = FileItem(
      remotePath: "./link",
      url: URL(string: "test://source/link")!,
      providerID: providerID,
      isDirectory: false,
      isSymbolicLink: true,
      size: 999)

    let item = TransferJob.Item(symlink)

    #expect(item.isSymbolicLink)
    #expect(item.fileItem.isSymbolicLink)
  }

  @Test("isSymbolicLinkキーの無い旧形式のItem jsonはfalseとして復元できる")
  func decodesLegacyItemJSONWithoutIsSymbolicLinkKey() throws {
    let legacyJSON = """
      {
        "location": { "providerID": "source", "path": { "remote": { "_0": "./report.txt" } } },
        "name": "report.txt",
        "isDirectory": false,
        "totalBytes": 4
      }
      """
    let item = try JSONDecoder().decode(TransferJob.Item.self, from: Data(legacyJSON.utf8))

    #expect(!item.isSymbolicLink)
  }

  @Test("allJobsは新しい順で返す")
  func allJobsReturnsNewestFirst() async {
    let store = InMemoryTransferJobStore()
    let queue = TransferQueue(store: store, maximumConcurrentTransfers: 1)
    let first = makeJob()
    let second = makeJob()
    _ = await queue.enqueue(first) { _, _ in }
    _ = await queue.enqueue(second) { _, _ in }
    let jobs = await queue.allJobs()
    #expect(jobs.map(\.id) == [second.id, first.id])
  }

  @Test("保存時に終了済み履歴の最古を除いて新しい1000件を保持する")
  func trimsOldestPersistedTerminalHistory() async throws {
    let store = InMemoryTransferJobStore()
    let terminalJobs = (0...TransferJobHistoryPolicy.terminalLimit).map { index in
      var job = makeJob()
      job.state = [.completed, .failed, .cancelled][index % 3]
      job.updatedAt = Date(timeIntervalSince1970: Double(index))
      return job
    }
    let oldestID = try #require(terminalJobs.first?.id)
    try store.save(terminalJobs)

    let queue = TransferQueue(store: store, maximumConcurrentTransfers: 1)

    #expect(await queue.allJobs().count == TransferJobHistoryPolicy.terminalLimit)
    #expect(!store.snapshot().contains(where: { $0.id == oldestID }))
    let restoredQueue = TransferQueue(store: store, maximumConcurrentTransfers: 1)
    #expect(await restoredQueue.allJobs().count == TransferJobHistoryPolicy.terminalLimit)
    #expect(!(await restoredQueue.allJobs().contains(where: { $0.id == oldestID })))
  }

  @Test("待機中と中断ジョブは1000件を超えても保存時に削除しない")
  func keepsNonPrunableJobsAboveTerminalLimit() async throws {
    let store = InMemoryTransferJobStore()
    var jobs = (0...TransferJobHistoryPolicy.terminalLimit).map { _ in
      var job = makeJob()
      job.state = .queued
      return job
    }
    var interrupted = makeJob()
    interrupted.state = .interrupted
    jobs.append(interrupted)
    try store.save(jobs)

    let queue = TransferQueue(store: store, maximumConcurrentTransfers: 1)

    #expect(await queue.allJobs().count == TransferJobHistoryPolicy.terminalLimit + 2)
    #expect(store.snapshot().count == TransferJobHistoryPolicy.terminalLimit + 2)
    #expect(store.snapshot().contains(where: { $0.id == interrupted.id }))
  }

  @Test("単票削除は終了済みジョブだけを削除して永続化する")
  func removesOnlyTerminalJobAndPersistsTheResult() async throws {
    let store = InMemoryTransferJobStore()
    var completed = makeJob()
    completed.state = .completed
    var failed = makeJob()
    failed.state = .failed
    var queued = makeJob()
    queued.state = .queued
    try store.save([completed, failed, queued])
    let queue = TransferQueue(store: store, maximumConcurrentTransfers: 1)

    #expect(await queue.removeTerminalJob(failed.id))
    #expect(!(await queue.removeTerminalJob(queued.id)))
    #expect(!(await queue.removeTerminalJob(UUID())))

    let remainingIDs = Set(await queue.allJobs().map(\.id))
    #expect(remainingIDs == [completed.id, queued.id])
    #expect(Set(store.snapshot().map(\.id)) == remainingIDs)
  }

  @Test("一括削除は全terminal状態を消し実行中・待機中を残す")
  func removesAllTerminalJobsWithoutRemovingActiveJobs() async throws {
    let store = InMemoryTransferJobStore()
    var completed = makeJob()
    completed.state = .completed
    var failed = makeJob()
    failed.state = .failed
    var cancelled = makeJob()
    cancelled.state = .cancelled
    var interrupted = makeJob()
    interrupted.state = .interrupted
    try store.save([completed, failed, cancelled, interrupted])
    let queue = TransferQueue(store: store, maximumConcurrentTransfers: 1)
    let running = makeJob()
    let queued = makeJob()
    let gate = TransferGate()
    _ = await queue.enqueue(running) { _, _ in await gate.wait() }
    _ = await queue.enqueue(queued) { _, _ in }

    let removedCount = await queue.removeTerminalJobs()

    #expect(removedCount == 4)
    let remaining = await queue.allJobs()
    #expect(Set(remaining.map(\.id)) == [queued.id, running.id])
    #expect(Set(remaining.map(\.state)) == [.queued, .running])
    #expect(Set(store.snapshot().map(\.id)) == [queued.id, running.id])
    await queue.cancel(running.id)
    await gate.open()
  }

  private func makeJob() -> TransferJob {
    let providerID = FileProviderID(rawValue: "source")
    let item = FileItem(
      remotePath: "./report.txt",
      url: URL(string: "test://source/report.txt")!,
      providerID: providerID,
      isDirectory: false,
      size: 4)
    return TransferJob(
      kind: .copy,
      items: [item],
      sourceProviderID: providerID,
      destinationProviderID: FileProviderID(rawValue: "destination"),
      destination: FileLocation(
        remotePath: ".",
        providerID: FileProviderID(rawValue: "destination")))
  }

  private func makeJob(itemCount: Int) -> TransferJob {
    let providerID = FileProviderID(rawValue: "source")
    let items = (0..<itemCount).map { index in
      FileItem(
        remotePath: "./file-\(index).bin",
        url: URL(string: "test://source/file-\(index).bin")!,
        providerID: providerID,
        isDirectory: false,
        size: 4)
    }
    return TransferJob(
      kind: .copy,
      items: items,
      sourceProviderID: providerID,
      destinationProviderID: FileProviderID(rawValue: "destination"),
      destination: FileLocation(
        remotePath: ".",
        providerID: FileProviderID(rawValue: "destination")))
  }

  private func waitForState(
    _ state: TransferJob.State,
    jobID: UUID,
    in queue: TransferQueue
  ) async throws -> TransferJob {
    var result: TransferJob?
    await waitUntil("ジョブが期限内に指定状態にならなかった") {
      guard let job = await queue.allJobs().first(where: { $0.id == jobID }), job.state == state
      else {
        return false
      }
      result = job
      return true
    }
    guard let result else { throw CocoaError(.fileReadUnknown) }
    return result
  }
}

/// save呼び出し回数を数えられるストア。完了項目の永続化デバウンス(Fix B)が
/// 実際に書き込み回数を合流させていることを証明するために使う。
private final class CountingTransferJobStore: TransferJobStore, @unchecked Sendable {
  private let lock = NSLock()
  private var jobs: [TransferJob] = []
  private var count = 0

  func load() throws -> [TransferJob] {
    lock.withLock { jobs }
  }

  func save(_ jobs: [TransferJob]) throws {
    lock.withLock {
      self.jobs = jobs
      count += 1
    }
  }

  func saveCount() -> Int {
    lock.withLock { count }
  }
}

private actor TransferGate {
  private var isOpen = false

  func wait() async {
    await waitUntil(timeout: .seconds(5), "転送ゲートが期限内に開かなかった") {
      isOpen
    }
  }

  func open() {
    isOpen = true
  }
}
