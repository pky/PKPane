import Foundation
import Synchronization
import Testing

@testable import PKPane

struct TransferRateLimiterTests {
  @Test("仮想時間で設定レートを超えずにバイトを通す")
  func limitsBytesUsingVirtualTime() async throws {
    let clock = VirtualTransferClock()
    let limiter = makeLimiter(bytesPerSecond: 100, clock: clock)

    try await limiter.acquire(bytes: 300)

    #expect(clock.elapsedSeconds == 3)
  }

  @Test("実行中のレート変更は次の取得へ即時反映する")
  func appliesRateChangesImmediately() async throws {
    let clock = VirtualTransferClock()
    let limiter = makeLimiter(bytesPerSecond: 100, clock: clock)
    try await limiter.acquire(bytes: 100)

    await limiter.setBytesPerSecond(200)
    try await limiter.acquire(bytes: 200)

    #expect(clock.elapsedSeconds == 2)
    #expect(limiter.currentBytesPerSecond() == 200)
  }

  @Test("0またはnilの上限は待機せず無制限として扱う")
  func unlimitedValuesPassThroughWithoutSleeping() async throws {
    let clock = VirtualTransferClock()
    let limiter = makeLimiter(bytesPerSecond: 0, clock: clock)

    try await limiter.acquire(bytes: 10_000)
    await limiter.setBytesPerSecond(nil)
    try await limiter.acquire(bytes: 10_000)

    #expect(clock.elapsedSeconds == 0)
    #expect(clock.sleepCount == 0)
    #expect(limiter.currentBytesPerSecond() == nil)
  }

  @Test("リミッタ待機中のタスクキャンセルはCancellationErrorで終了する")
  func cancellationStopsPendingAcquire() async throws {
    let sleepStarted = AsyncStream<Void>.makeStream()
    let limiter = TransferRateLimiter(
      bytesPerSecond: 1,
      now: { .zero },
      sleep: { _ in
        sleepStarted.continuation.yield()
        try await Task.sleep(for: .seconds(10))
      })
    let task = Task {
      try await limiter.acquire(bytes: 100)
    }

    for await _ in sleepStarted.stream { break }
    task.cancel()
    do {
      try await task.value
      Issue.record("キャンセルした帯域待機が完了してしまいました")
    } catch is CancellationError {
      // 期待どおり。
    }
    sleepStarted.continuation.finish()
    #expect(await limiter.cancelledBeforeEnqueueCount == 0)
  }

  @Test("待機中のレート変更は新レートで完了時刻を再計算する")
  func recalculatesPendingWaitAfterRateChange() async throws {
    let clock = ManualTransferClock()
    let limiter = TransferRateLimiter(
      bytesPerSecond: 100,
      now: { clock.now },
      sleep: { duration in try await clock.sleep(for: duration) })
    let completed = Mutex(false)
    let task = Task {
      try await limiter.acquire(bytes: 100)
      completed.withLock { $0 = true }
    }

    try await waitForPendingSleep(.seconds(1), in: clock)
    await limiter.setBytesPerSecond(200)
    try await waitForPendingSleep(.milliseconds(500), in: clock)

    clock.advance(by: .milliseconds(499))
    await Task.yield()
    #expect(!completed.withLock { $0 })
    clock.advance(by: .milliseconds(1))
    try await task.value

    #expect(completed.withLock { $0 })
    #expect(clock.elapsedSeconds == 0.5)
  }

  private func makeLimiter(
    bytesPerSecond: Int64?,
    clock: VirtualTransferClock
  ) -> TransferRateLimiter {
    TransferRateLimiter(
      bytesPerSecond: bytesPerSecond,
      now: { clock.now },
      sleep: { duration in try await clock.sleep(for: duration) })
  }

  private func waitForPendingSleep(
    _ expectedDuration: Duration,
    in clock: ManualTransferClock
  ) async throws {
    let continuousClock = ContinuousClock()
    let deadline = continuousClock.now.advanced(by: .seconds(2))
    while continuousClock.now < deadline {
      if clock.pendingSleepDurations.contains(expectedDuration) { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("期待する仮想sleepが予約されませんでした: \(expectedDuration)")
    throw CocoaError(.fileReadUnknown)
  }
}

/// 実時間を一切待たず、要求されたsleep分だけ単調時刻を進めるテスト用クロック。
final class VirtualTransferClock: Sendable {
  private let state = Mutex<(now: Duration, sleepCount: Int)>((.zero, 0))

  var now: Duration {
    state.withLock(\.now)
  }

  var elapsedSeconds: Double {
    let components = now.components
    return Double(components.seconds) + Double(components.attoseconds) / 1e18
  }

  var sleepCount: Int {
    state.withLock(\.sleepCount)
  }

  func sleep(for duration: Duration) async throws {
    try Task.checkCancellation()
    state.withLock { value in
      value.now += duration
      value.sleepCount += 1
    }
    await Task.yield()
    try Task.checkCancellation()
  }
}

/// sleepを手動advanceまで保留し、キャンセルされた予約も除去する仮想クロック。
private final class ManualTransferClock: @unchecked Sendable {
  private struct Sleeper {
    let deadline: Duration
    let continuation: CheckedContinuation<Void, any Error>
  }

  private let lock = NSLock()
  private var currentTime: Duration = .zero
  private var sleepers: [UUID: Sleeper] = [:]
  private var cancelledBeforeRegistration: Set<UUID> = []

  var now: Duration {
    lock.withLock { currentTime }
  }

  var elapsedSeconds: Double {
    let components = now.components
    return Double(components.seconds) + Double(components.attoseconds) / 1e18
  }

  var pendingSleepDurations: [Duration] {
    lock.withLock { sleepers.values.map { $0.deadline - currentTime } }
  }

  func sleep(for duration: Duration) async throws {
    let id = UUID()
    try Task.checkCancellation()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let shouldCancel = lock.withLock { () -> Bool in
          if cancelledBeforeRegistration.remove(id) != nil { return true }
          sleepers[id] = Sleeper(deadline: currentTime + duration, continuation: continuation)
          return false
        }
        if shouldCancel {
          continuation.resume(throwing: CancellationError())
        }
      }
    } onCancel: {
      let continuation = self.lock.withLock { () -> CheckedContinuation<Void, any Error>? in
        if let sleeper = self.sleepers.removeValue(forKey: id) {
          return sleeper.continuation
        }
        self.cancelledBeforeRegistration.insert(id)
        return nil
      }
      continuation?.resume(throwing: CancellationError())
    }
  }

  func advance(by duration: Duration) {
    let ready = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
      currentTime += duration
      let readyIDs = sleepers.compactMap { id, sleeper in
        sleeper.deadline <= currentTime ? id : nil
      }
      return readyIDs.compactMap { sleepers.removeValue(forKey: $0)?.continuation }
    }
    for continuation in ready {
      continuation.resume()
    }
  }
}
