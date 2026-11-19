import Foundation
import Synchronization

/// 全転送で共有するトークンバケット式の帯域制限です。
/// 待機要求はFIFOで処理し、複数転送の合計バイト数を1つの上限へ収めます。
actor TransferRateLimiter {
  typealias Now = @Sendable () -> Duration
  typealias Sleep = @Sendable (Duration) async throws -> Void

  static let shared = TransferRateLimiter()

  private struct Waiter {
    let id: UUID
    var remainingBytes: Double
    let continuation: CheckedContinuation<Void, any Error>
  }

  private let now: Now
  private let sleep: Sleep
  nonisolated private let configuredBytesPerSecond: Mutex<Int64?>
  private var bytesPerSecond: Int64?
  private var availableTokens: Double = 0
  private var lastRefillTime: Duration
  private var waiters: [Waiter] = []
  private var cancelledBeforeEnqueue: Set<UUID> = []
  private var activeWaiterIDs: Set<UUID> = []
  private var wakeTask: Task<Void, Never>?
  private var wakeGeneration = 0

  init(bytesPerSecond: Int64? = nil) {
    let normalizedValue = Self.normalized(bytesPerSecond)
    let clock = ContinuousClock()
    let origin = clock.now
    now = { origin.duration(to: clock.now) }
    sleep = { duration in try await clock.sleep(for: duration) }
    configuredBytesPerSecond = Mutex(normalizedValue)
    self.bytesPerSecond = normalizedValue
    lastRefillTime = .zero
  }

  init(
    bytesPerSecond: Int64? = nil,
    now: @escaping Now,
    sleep: @escaping Sleep
  ) {
    let normalizedValue = Self.normalized(bytesPerSecond)
    self.now = now
    self.sleep = sleep
    configuredBytesPerSecond = Mutex(normalizedValue)
    self.bytesPerSecond = normalizedValue
    lastRefillTime = now()
  }

  func acquire(bytes byteCount: Int) async throws {
    guard byteCount > 0, bytesPerSecond != nil else {
      try Task.checkCancellation()
      return
    }
    let waiterID = UUID()
    activeWaiterIDs.insert(waiterID)
    defer {
      activeWaiterIDs.remove(waiterID)
      cancelledBeforeEnqueue.remove(waiterID)
    }
    try Task.checkCancellation()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        enqueue(
          Waiter(
            id: waiterID,
            remainingBytes: Double(byteCount),
            continuation: continuation))
      }
    } onCancel: {
      Task { await self.cancelWaiter(waiterID) }
    }
  }

  func setBytesPerSecond(_ newValue: Int64?) {
    refillTokens()
    let normalizedValue = Self.normalized(newValue)
    let wasUnlimited = bytesPerSecond == nil
    bytesPerSecond = normalizedValue
    configuredBytesPerSecond.withLock { $0 = normalizedValue }
    if let normalizedValue {
      availableTokens = wasUnlimited ? 0 : min(availableTokens, Double(normalizedValue))
    } else {
      availableTokens = 0
    }
    lastRefillTime = now()
    cancelWakeTask()
    processWaiters()
  }

  nonisolated func currentBytesPerSecond() -> Int64? {
    configuredBytesPerSecond.withLock { $0 }
  }

  var cancelledBeforeEnqueueCount: Int {
    cancelledBeforeEnqueue.count
  }

  private static func normalized(_ value: Int64?) -> Int64? {
    guard let value, value > 0 else { return nil }
    return value
  }

  private func enqueue(_ waiter: Waiter) {
    if cancelledBeforeEnqueue.remove(waiter.id) != nil {
      waiter.continuation.resume(throwing: CancellationError())
      return
    }
    waiters.append(waiter)
    processWaiters()
  }

  private func cancelWaiter(_ waiterID: UUID) {
    guard let index = waiters.firstIndex(where: { $0.id == waiterID }) else {
      if activeWaiterIDs.contains(waiterID) {
        cancelledBeforeEnqueue.insert(waiterID)
      }
      return
    }
    let waiter = waiters.remove(at: index)
    waiter.continuation.resume(throwing: CancellationError())
    cancelWakeTask()
    processWaiters()
  }

  private func processWaiters() {
    guard !waiters.isEmpty else {
      cancelWakeTask()
      return
    }
    guard let bytesPerSecond else {
      let ready = waiters
      waiters.removeAll()
      for waiter in ready {
        waiter.continuation.resume()
      }
      return
    }

    refillTokens()
    while !waiters.isEmpty, availableTokens > 0 {
      let granted = min(waiters[0].remainingBytes, availableTokens)
      waiters[0].remainingBytes -= granted
      availableTokens -= granted
      if waiters[0].remainingBytes <= 0 {
        let completed = waiters.removeFirst()
        completed.continuation.resume()
      }
    }
    guard let first = waiters.first, wakeTask == nil else { return }
    // バケット容量は1秒分。要求がそれを超える場合も1秒単位で補充して前進させる。
    let requiredTokens = min(first.remainingBytes, Double(bytesPerSecond))
    let missingTokens = max(requiredTokens - availableTokens, 0)
    scheduleWake(after: duration(seconds: missingTokens / Double(bytesPerSecond)))
  }

  private func refillTokens() {
    let currentTime = now()
    defer { lastRefillTime = currentTime }
    guard let bytesPerSecond else { return }
    let elapsed = max(seconds(in: currentTime - lastRefillTime), 0)
    availableTokens = min(
      Double(bytesPerSecond),
      availableTokens + elapsed * Double(bytesPerSecond))
  }

  private func scheduleWake(after duration: Duration) {
    wakeGeneration += 1
    let generation = wakeGeneration
    let sleep = self.sleep
    wakeTask = Task { [weak self] in
      do {
        try await sleep(duration)
        await self?.wake(generation: generation)
      } catch {
        // 上限変更・待機要求のキャンセル時は、新しい世代が再予約する。
      }
    }
  }

  private func wake(generation: Int) {
    guard generation == wakeGeneration else { return }
    wakeTask = nil
    processWaiters()
  }

  private func cancelWakeTask() {
    wakeGeneration += 1
    wakeTask?.cancel()
    wakeTask = nil
  }

  private func seconds(in duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) + Double(components.attoseconds) / 1e18
  }

  private func duration(seconds: Double) -> Duration {
    .nanoseconds(Int64((seconds * 1_000_000_000).rounded(.up)))
  }
}
