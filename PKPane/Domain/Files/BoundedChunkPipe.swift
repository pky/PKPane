import Foundation
import Synchronization

/// 呼び出し側がストリームを保持したまま送信失敗した場合も、生産タスクを明示的に止める。
/// ストリームの解放時期に依存せず、作業コピーのFileHandleを回収するために使う。
final class ChunkPipeCancellation: Sendable {
  private struct State {
    var cancelled = false
    var task: Task<Void, Never>?
  }
  private let state = Mutex(State())

  fileprivate func register(_ task: Task<Void, Never>) {
    let cancelled = state.withLock {
      $0.task = task
      return $0.cancelled
    }
    if cancelled { task.cancel() }
  }

  func cancel() {
    let task = state.withLock {
      $0.cancelled = true
      return $0.task
    }
    task?.cancel()
  }

  func waitForCompletion() async {
    let task = state.withLock { $0.task }
    await task?.value
  }
}

/// 生産者の先読みを上限つきにするチャンクパイプ。消費された分だけ次を生産する。
enum BoundedChunkPipe {
  /// 外部編集の作業コピーも通常転送と同じ有限パイプで読む。FileHandleは生産タスクが
  /// 所有し、正常終了・取消・受信側エラーのすべてで閉じる。元の作業コピーは保持する。
  static func fileStream(
    at url: URL,
    chunkSize: Int,
    maximumBufferedBytes: Int = 4 * 1_024 * 1_024,
    cancellation: ChunkPipeCancellation? = nil,
    readObserved: @escaping @Sendable (Int) -> Void = { _ in }
  ) -> AsyncThrowingStream<Data, Error> {
    precondition(chunkSize > 0 && maximumBufferedBytes > 0)
    let readSize = min(chunkSize, maximumBufferedBytes)
    return stream(
      limit: max(1, maximumBufferedBytes / readSize), cancellation: cancellation
    ) { yield in
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      while true {
        try Task.checkCancellation()
        guard let data = try handle.read(upToCount: readSize), !data.isEmpty else { break }
        readObserved(data.count)
        try await yield(data)
      }
    }
  }

  static func stream(
    limit: Int,
    rateLimiter: TransferRateLimiter? = .shared,
    cancellation: ChunkPipeCancellation? = nil,
    produce:
      @escaping @Sendable (
        _ yield: @escaping @Sendable (Data) async throws -> Void
      ) async throws -> Void
  ) -> AsyncThrowingStream<Data, Error> {
    let counters = ChunkBacklogCounter()

    // 生産者はcontinuationベースのストリームに乗せる。onTerminationにより、
    // 早期break・タスクキャンセルのどちらでも確実にproducerTaskを後始末できる
    // (既存のfileChunks実装と同じ土台)。
    let inner = AsyncThrowingStream<Data, Error> { continuation in
      let producerTask = Task {
        do {
          try await produce { chunk in
            continuation.yield(chunk)
            counters.recordProduced()
            // 消費の到達を待つ専用の同期プリミティブは使わず、簡潔さを優先して
            // 10ms間隔のポーリングで先読み上限を守る(ここが実装上の妥協点)。
            while counters.backlog >= limit {
              try Task.checkCancellation()
              try await Task.sleep(for: .milliseconds(10))
            }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      cancellation?.register(producerTask)
      continuation.onTermination = { _ in producerTask.cancel() }
    }

    // 返すストリームはpull駆動(unfolding)にする。外部消費者が次を要求した瞬間にのみ
    // consumedを増やすことで、produced-consumedの差が真の先読み量になる。innerの
    // next()呼び出しは外部消費者のタスクキャンセルにも反応するため、そのタスクが
    // キャンセルされればinnerも終端し、producerTaskはonTermination経由で回収される。
    // AsyncThrowingStream(unfolding:)にはonCancelがないが、上記のinner解放連鎖
    // (キャンセル/早期break→inner終端→onTermination→producerTask.cancel())に
    // 委ねているため、ここで明示的なキャンセルハンドラを持つ必要はない。
    let forwarder = ChunkForwarder(inner)
    return AsyncThrowingStream<Data, Error> {
      try Task.checkCancellation()
      let next = try await forwarder.next()
      try Task.checkCancellation()
      guard let chunk = next else { return nil }
      if let rateLimiter, rateLimiter.currentBytesPerSecond() != nil {
        try await rateLimiter.acquire(bytes: chunk.count)
      }
      counters.recordConsumed()
      return chunk
    }
  }

  /// ZIPFoundationの展開コールバックのような同期producerを、上限つきの非同期ストリームへ
  /// 変換する。バッファ満杯時はproducerを実行する専用スレッドだけを短時間待機させ、
  /// 消費速度を超えた展開データがメモリへ蓄積し続けることを防ぐ。
  static func synchronousStream(
    limit: Int,
    rateLimiter: TransferRateLimiter? = .shared,
    produce:
      @escaping @Sendable (
        _ yield: @escaping @Sendable (Data) throws -> Void
      ) throws -> Void
  ) -> AsyncThrowingStream<Data, Error> {
    precondition(limit > 0)
    let inner = AsyncThrowingStream<Data, Error>(
      bufferingPolicy: .bufferingOldest(limit)
    ) { continuation in
      let producerTask = Task.detached {
        do {
          try produce { chunk in
            while true {
              try Task.checkCancellation()
              switch continuation.yield(chunk) {
              case .enqueued:
                return
              case .dropped:
                Thread.sleep(forTimeInterval: 0.005)
              case .terminated:
                throw CancellationError()
              @unknown default:
                throw CancellationError()
              }
            }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in producerTask.cancel() }
    }
    let forwarder = ChunkForwarder(inner)
    return AsyncThrowingStream<Data, Error> {
      guard let chunk = try await forwarder.next() else { return nil }
      if let rateLimiter, rateLimiter.currentBytesPerSecond() != nil {
        try await rateLimiter.acquire(bytes: chunk.count)
      }
      return chunk
    }
  }

  /// 複数のエスケープするクロージャから共有するためMutexを参照型に包む。Mutex自体は
  /// Copyableでないため、1つのローカル変数のまま2箇所以上のクロージャへ個別に
  /// キャプチャすることはできない(Swift 6の送信チェックに抵触する)。
  private final class ChunkBacklogCounter: Sendable {
    private let counters = Mutex<(produced: Int, consumed: Int)>((0, 0))

    func recordProduced() {
      counters.withLock { $0.produced += 1 }
    }

    func recordConsumed() {
      counters.withLock { $0.consumed += 1 }
    }

    var backlog: Int {
      counters.withLock { $0.produced - $0.consumed }
    }
  }

  /// innerストリームの反復状態を保持する。AsyncIteratorProtocolの規約上、呼び出し元は
  /// 常に単一の消費者から直列にnext()を呼ぶ前提のため、@unchecked Sendableで安全に扱える。
  private final class ChunkForwarder: @unchecked Sendable {
    private var iterator: AsyncThrowingStream<Data, Error>.AsyncIterator

    init(_ stream: AsyncThrowingStream<Data, Error>) {
      iterator = stream.makeAsyncIterator()
    }

    func next() async throws -> Data? {
      try await iterator.next()
    }
  }
}
