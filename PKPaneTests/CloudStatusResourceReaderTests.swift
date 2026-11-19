import Dispatch
import Foundation
import Testing

@testable import PKPane

/// readのフェイク。呼び出し回数、同時実行数の最大、呼び出しスレッドの性質を記録する。
/// `handler`には1始まりの呼び出し番号を渡し、ブロックや待機はここで行う。
final class CloudReadProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var callCount = 0
  private var activeCount = 0
  private var maxActiveCount = 0
  private var queueFlags: [Bool] = []
  private var mainThreadFlags: [Bool] = []
  private let handler: @Sendable (Int, URL) -> CloudStatusResourceValues?

  init(handler: @escaping @Sendable (Int, URL) -> CloudStatusResourceValues?) {
    self.handler = handler
  }

  var read: @Sendable (URL) -> CloudStatusResourceValues? {
    { [self] url in
      let index = enter()
      defer { leave() }
      return handler(index, url)
    }
  }

  var calls: Int { lock.withLock { callCount } }
  var maxActive: Int { lock.withLock { maxActiveCount } }
  var ranOnDedicatedQueue: [Bool] { lock.withLock { queueFlags } }
  var ranOnMainThread: [Bool] { lock.withLock { mainThreadFlags } }

  private func enter() -> Int {
    let onQueue =
      DispatchQueue.getSpecific(key: CloudStatusResourceReader.queueSpecificKey) == true
    let onMain = Thread.isMainThread
    return lock.withLock {
      callCount += 1
      activeCount += 1
      maxActiveCount = max(maxActiveCount, activeCount)
      queueFlags.append(onQueue)
      mainThreadFlags.append(onMain)
      return callCount
    }
  }

  private func leave() {
    lock.withLock { activeCount -= 1 }
  }
}

extension CloudStatusResourceValues {
  /// テスト用の「未ダウンロード」値。
  static let notDownloadedFixture = CloudStatusResourceValues(
    isUbiquitousItem: true,
    downloadingStatus: .notDownloaded,
    isDownloading: false,
    hasDownloadingError: false)
}

struct CloudStatusResourceReaderTests {
  private let url = URL(filePath: "/tmp/cloud-reader-a")
  private let otherURL = URL(filePath: "/tmp/cloud-reader-b")

  @Test("A1: readの値をそのまま返し、readは1回だけ呼ぶ")
  func returnsReadValue() async {
    let probe = CloudReadProbe { _, _ in .notDownloadedFixture }
    let reader = CloudStatusResourceReader(read: probe.read)

    let values = await reader.values(for: url)

    #expect(values == .notDownloadedFixture)
    #expect(probe.calls == 1)
  }

  @Test("A2: readは専用キュー上で呼ばれメインスレッドでは呼ばれない")
  func readsOnDedicatedQueue() async {
    let probe = CloudReadProbe { _, _ in .notDownloadedFixture }
    let reader = CloudStatusResourceReader(read: probe.read)

    _ = await reader.values(for: url)

    #expect(probe.ranOnDedicatedQueue == [true])
    #expect(probe.ranOnMainThread == [false])
  }

  @Test("A3: 期限を超えたらnilで先へ進みdegradedになる。遅れて戻っても落ちない")
  func timesOutAndDegradesWithoutDoubleResume() async throws {
    let gate = DispatchSemaphore(value: 0)
    let probe = CloudReadProbe { _, _ in
      gate.wait()
      return .notDownloadedFixture
    }
    let reader = CloudStatusResourceReader(
      maxConcurrentReads: 2, timeout: .milliseconds(200), read: probe.read)
    defer { gate.signal() }
    let clock = ContinuousClock()
    let start = clock.now

    let values = await reader.values(for: url)
    let elapsed = start.duration(to: clock.now)

    #expect(values == nil)
    #expect(elapsed >= .milliseconds(200))
    #expect(elapsed < .seconds(1))
    #expect(reader.isDegraded)

    // 期限後にブロックを解放し、遅れた結果が捨てられて再開が二重にならないことを確かめる。
    gate.signal()
    try await Task.sleep(for: .milliseconds(150))
    #expect(reader.isDegraded)
    #expect(probe.calls == 1)
  }

  @Test("A4: degraded中はreadを呼ばず、間隔が過ぎると再び呼ぶ")
  func skipsReadWhileDegradedThenRecovers() async throws {
    let gate = DispatchSemaphore(value: 0)
    let probe = CloudReadProbe { index, _ in
      if index == 1 {
        gate.wait()
        return nil
      }
      return .notDownloadedFixture
    }
    let reader = CloudStatusResourceReader(
      maxConcurrentReads: 2,
      timeout: .milliseconds(100),
      degradedInterval: .milliseconds(100),
      read: probe.read)
    defer { gate.signal() }

    #expect(await reader.values(for: url) == nil)
    #expect(reader.isDegraded)
    #expect(probe.calls == 1)

    #expect(await reader.values(for: otherURL) == nil)
    #expect(probe.calls == 1)

    try await Task.sleep(for: .milliseconds(150))
    #expect(!reader.isDegraded)
    #expect(await reader.values(for: otherURL) == .notDownloadedFixture)
    #expect(probe.calls == 2)
  }

  @Test("A5: 同時に走るreadはmaxConcurrentReadsまでに制限される")
  func limitsConcurrentReads() async {
    let probe = CloudReadProbe { _, _ in
      Thread.sleep(forTimeInterval: 0.1)
      return .notDownloadedFixture
    }
    let reader = CloudStatusResourceReader(
      maxConcurrentReads: 2, timeout: .seconds(1), read: probe.read)
    let urls = (0..<3).map { URL(filePath: "/tmp/cloud-reader-\($0)") }

    let results = await withTaskGroup(of: CloudStatusResourceValues?.self) { group in
      for url in urls {
        group.addTask { await reader.values(for: url) }
      }
      var collected: [CloudStatusResourceValues?] = []
      for await value in group { collected.append(value) }
      return collected
    }

    #expect(results.count == 3)
    #expect(results.allSatisfy { $0 == .notDownloadedFixture })
    #expect(probe.calls == 3)
    #expect(probe.maxActive == 2)
  }

  @Test("A6: readがブロックしても協調スレッドは塞がれない")
  func blockedReadDoesNotStarveCooperativePool() async {
    let gate = DispatchSemaphore(value: 0)
    let probe = CloudReadProbe { _, _ in
      _ = gate.wait(timeout: .now() + 0.5)
      return .notDownloadedFixture
    }
    let reader = CloudStatusResourceReader(
      maxConcurrentReads: 4, timeout: .milliseconds(200), read: probe.read)
    defer { gate.signal() }
    let blockedURL = url
    let pending = Task { await reader.values(for: blockedURL) }
    let clock = ContinuousClock()
    let start = clock.now

    let total = await withTaskGroup(of: Int.self) { group in
      for _ in 0..<10 {
        group.addTask { await Task.detached { 1 }.value }
      }
      var sum = 0
      for await value in group { sum += value }
      return sum
    }
    let elapsed = start.duration(to: clock.now)

    #expect(total == 10)
    #expect(elapsed < .milliseconds(300))
    #expect(await pending.value == nil)
  }

  @Test("A7: 待ち行列で待った時間は期限に数えずdegradedにならない")
  func queueWaitingTimeDoesNotCountTowardTimeout() async {
    let probe = CloudReadProbe { _, _ in
      Thread.sleep(forTimeInterval: 0.15)
      return .notDownloadedFixture
    }
    // 3本目は着手300ms・完了450ms。期限は着手起点なので、300msなら高負荷でも余裕が残る。
    let reader = CloudStatusResourceReader(
      maxConcurrentReads: 1, timeout: .milliseconds(300), read: probe.read)
    let urls = (0..<3).map { URL(filePath: "/tmp/cloud-reader-q\($0)") }

    let results = await withTaskGroup(of: CloudStatusResourceValues?.self) { group in
      for url in urls {
        group.addTask { await reader.values(for: url) }
      }
      var collected: [CloudStatusResourceValues?] = []
      for await value in group { collected.append(value) }
      return collected
    }

    #expect(results.count == 3)
    #expect(results.allSatisfy { $0 == .notDownloadedFixture })
    #expect(!reader.isDegraded)
  }

  @Test("A9: degraded解除後も着手できない読み出しは待ち上限でnilになり再びdegradedになる")
  func queueWaitLimitDegradesAgainWhenSlotStaysBlocked() async throws {
    let gate = DispatchSemaphore(value: 0)
    let probe = CloudReadProbe { _, _ in
      gate.wait()
      return .notDownloadedFixture
    }
    // 高負荷で再開が遅れても最初のisDegraded確認が失効後にならないよう、間隔は余裕を取る。
    let reader = CloudStatusResourceReader(
      maxConcurrentReads: 1,
      timeout: .milliseconds(100),
      degradedInterval: .milliseconds(200),
      queueWaitLimit: .milliseconds(300),
      read: probe.read)
    defer { gate.signal() }

    #expect(await reader.values(for: url) == nil)
    #expect(reader.isDegraded)

    try await Task.sleep(for: .milliseconds(250))
    #expect(!reader.isDegraded)

    let clock = ContinuousClock()
    let start = clock.now
    let second = await reader.values(for: otherURL)
    let elapsed = start.duration(to: clock.now)

    #expect(second == nil)
    #expect(elapsed < .seconds(1))
    #expect(reader.isDegraded)

    gate.signal()
    try await Task.sleep(for: .milliseconds(150))
    #expect(probe.calls == 1)
  }

  @Test("A8: 期限切れ後に待っていた読み出しは空振りで終わりreadを呼ばない")
  func staleQueuedReadIsSkippedAfterDegrading() async throws {
    let gate = DispatchSemaphore(value: 0)
    let probe = CloudReadProbe { _, _ in
      gate.wait()
      return .notDownloadedFixture
    }
    let reader = CloudStatusResourceReader(
      maxConcurrentReads: 1,
      timeout: .milliseconds(100),
      degradedInterval: .seconds(10),
      read: probe.read)
    defer { gate.signal() }
    let firstURL = url
    let secondURL = otherURL
    let clock = ContinuousClock()
    let start = clock.now

    let first = Task { await reader.values(for: firstURL) }
    let second = Task { await reader.values(for: secondURL) }
    let secondValue = await second.value
    let elapsed = start.duration(to: clock.now)
    let firstValue = await first.value

    #expect(secondValue == nil)
    #expect(firstValue == nil)
    #expect(elapsed < .seconds(1))
    #expect(reader.isDegraded)

    gate.signal()
    try await Task.sleep(for: .milliseconds(150))
    #expect(probe.calls == 1)
  }
}
