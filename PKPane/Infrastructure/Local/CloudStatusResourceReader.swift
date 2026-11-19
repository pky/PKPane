import Dispatch
import Foundation
import Synchronization

struct CloudStatusResourceValues: Sendable, Equatable {
  let isUbiquitousItem: Bool?
  let downloadingStatus: URLUbiquitousItemDownloadingStatus?
  let isDownloading: Bool?
  let hasDownloadingError: Bool
}

/// iCloud の属性取得は同期 XPC で、デーモンが応答しないと呼び出しスレッドが戻らない。
/// Swift 並行の協調スレッドで呼ぶと全非同期処理が止まるため、専用キューで読み、
/// 期限を過ぎたら待たずに先へ進める。応答しない間は問い合わせ自体を止める。
final class CloudStatusResourceReader: Sendable {
  static let shared = CloudStatusResourceReader()
  static let queueSpecificKey = DispatchSpecificKey<Bool>()

  private let operationQueue: OperationQueue
  private let timeout: Duration
  private let degradedInterval: Duration
  private let queueWaitLimit: Duration
  private let read: @Sendable (URL) -> CloudStatusResourceValues?
  private let degradedUntil = Mutex<ContinuousClock.Instant?>(nil)

  init(
    maxConcurrentReads: Int = 4,
    timeout: Duration = .seconds(3),
    degradedInterval: Duration = .seconds(30),
    queueWaitLimit: Duration? = nil,
    read: @escaping @Sendable (URL) -> CloudStatusResourceValues? = CloudStatusResourceReader
      .systemRead
  ) {
    // utility だとタイマーの合体猶予で読み出しの完了が遅れ、期限判定が健全な読み出しまで
    // 打ち切ってしまうため、短い読み出し向けに userInitiated にしている。
    let dispatchQueue = DispatchQueue(
      label: "com.pky.PKPane.cloud-status-reader", qos: .userInitiated, attributes: .concurrent)
    dispatchQueue.setSpecific(key: Self.queueSpecificKey, value: true)
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = maxConcurrentReads
    queue.qualityOfService = .utility
    queue.underlyingQueue = dispatchQueue
    self.operationQueue = queue
    self.timeout = timeout
    self.degradedInterval = degradedInterval
    self.queueWaitLimit = queueWaitLimit ?? timeout * 3
    self.read = read
  }

  var isDegraded: Bool {
    degradedUntil.withLock { until in
      guard let until else { return false }
      return ContinuousClock.now < until
    }
  }

  func values(for url: URL) async -> CloudStatusResourceValues? {
    if isDegraded { return nil }
    let race = Race()
    return await withCheckedContinuation { continuation in
      race.install(continuation)
      let enqueuedAt = ContinuousClock.now
      let timer = Task { [timeout, queueWaitLimit] in
        do {
          try await Task.sleep(for: timeout)
          // 待ち行列での滞留は応答なしの証拠にならないため、着手するまで期限に数えない。
          // ただし既に応答なしと判定済みなら、待たせ続けず印を付けずに終える。
          // 詰まったスロットは解放できないので、呼び出し側だけは待ち上限で必ず戻す。
          var startedAt = race.startedAt
          while startedAt == nil {
            if isDegraded {
              race.take()?.resume(returning: nil)
              return
            }
            let remaining = enqueuedAt + queueWaitLimit - ContinuousClock.now
            if remaining <= .zero {
              // 上限ちょうどに着手した健全な読み出しを打ち切らないよう、最後に再確認する。
              startedAt = race.startedAt
              break
            }
            try await Task.sleep(for: min(timeout, remaining))
            startedAt = race.startedAt
          }
          if let startedAt { try await Task.sleep(until: startedAt + timeout, clock: .continuous) }
        } catch {
          return
        }
        // 呼び出し側が再開直後に isDegraded を読むため、印を先に付ける。
        if let continuation = race.take() {
          markDegraded()
          continuation.resume(returning: nil)
        }
      }
      let read = self.read
      operationQueue.addOperation {
        // 期限で nil 返却済みの古い操作は、応答しないXPCをこれ以上呼ばずに終える。
        guard race.startIfPending() else { return }
        let values = read(url)
        // 期限で負けた読み出しの結果は捨てる。
        if let continuation = race.take() {
          timer.cancel()
          continuation.resume(returning: values)
        }
      }
    }
  }

  private func markDegraded() {
    let until = ContinuousClock.now + degradedInterval
    degradedUntil.withLock { $0 = until }
  }

  static func systemRead(_ url: URL) -> CloudStatusResourceValues? {
    guard
      let values = try? url.resourceValues(
        forKeys: [
          .ubiquitousItemDownloadingStatusKey, .isUbiquitousItemKey,
          .ubiquitousItemIsDownloadingKey, .ubiquitousItemDownloadingErrorKey,
        ])
    else { return nil }
    return CloudStatusResourceValues(
      isUbiquitousItem: values.isUbiquitousItem,
      downloadingStatus: values.ubiquitousItemDownloadingStatus,
      isDownloading: values.ubiquitousItemIsDownloading,
      hasDownloadingError: values.ubiquitousItemDownloadingError != nil)
  }
}

/// 読み出し完了と期限切れのうち先着の1回だけ継続を再開するための状態。
private final class Race: Sendable {
  private struct State {
    var continuation: CheckedContinuation<CloudStatusResourceValues?, Never>?
    var startedAt: ContinuousClock.Instant?
  }

  private let state = Mutex(State())

  func install(_ value: CheckedContinuation<CloudStatusResourceValues?, Never>) {
    state.withLock { $0.continuation = value }
  }

  /// 先着なら継続を返す。遅れた側は nil を受け取り何もしない。
  func take() -> CheckedContinuation<CloudStatusResourceValues?, Never>? {
    state.withLock { current in
      defer { current.continuation = nil }
      return current.continuation
    }
  }

  var startedAt: ContinuousClock.Instant? { state.withLock { $0.startedAt } }

  /// 継続が残っているときだけ着手を記録する。判定と記録を分けると、その隙間で期限側が
  /// 継続を取った操作が応答なしのXPCを呼んでしまう。
  func startIfPending() -> Bool {
    state.withLock { current in
      guard current.continuation != nil else { return false }
      current.startedAt = ContinuousClock.now
      return true
    }
  }
}
