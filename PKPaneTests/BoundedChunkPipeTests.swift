import Foundation
import Synchronization
import Testing

@testable import PKPane

struct BoundedChunkPipeTests {
  @Test("次pull前の取消は呼出側で確認し保持中streamのproducerも終了する")
  func cancelsProducerBeforeNextPullWhileStreamIsRetained() async throws {
    let state = Mutex((produced: 0, finished: false))
    let gate = WorkingCopyConsumerGate()
    let cancellation = ChunkPipeCancellation()
    let stream = BoundedChunkPipe.stream(
      limit: 2, rateLimiter: nil, cancellation: cancellation
    ) { yield in
      defer { state.withLock { $0.finished = true } }
      for _ in 0..<16 {
        state.withLock { $0.produced += 1 }
        try await yield(Data([0x42]))
      }
    }
    let consumer = Task {
      var iterator = stream.makeAsyncIterator()
      _ = try #require(try await iterator.next())
      // 読取待機の外で取り消し、次のpull開始前へ取消位置を固定する。
      await gate.suspend()
      _ = try await iterator.next()
      // 取消済みIteratorはnilを返せる。確定側も同じ確認を行う。
      try Task.checkCancellation()
    }
    await waitUntil { await gate.isSuspended }
    await waitUntil { state.withLock { $0.produced >= 3 } }
    consumer.cancel()
    await gate.resume()
    await #expect(throws: CancellationError.self) { try await consumer.value }
    await waitUntil("取消済み次pullの前段でproducerが停止しなかった") {
      state.withLock { $0.finished }
    }
    // RED時にもproducerを残さず、保持したstreamの寿命には依存しない。
    cancellation.cancel()
    await cancellation.waitForCompletion()
    withExtendedLifetime(stream) {}
  }

  @Test("外部編集の作業コピーはバイト上限内で先読みし末尾まで一致する")
  func boundsWorkingCopyReadAhead() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let data = Data((0..<(2 * 1_024 * 1_024 + 3)).map { UInt8($0 % 251) })
    try data.write(to: url)
    let bytes = Mutex((read: 0, consumed: 0, maximumPending: 0))
    let chunkSize = 64 * 1_024
    let limit = 256 * 1_024
    let stream = BoundedChunkPipe.fileStream(
      at: url, chunkSize: chunkSize, maximumBufferedBytes: limit
    ) { count in
      bytes.withLock {
        $0.read += count
        $0.maximumPending = max($0.maximumPending, $0.read - $0.consumed)
      }
    }
    var received = Data()
    for try await chunk in stream {
      try await Task.sleep(for: .milliseconds(2))
      received.append(chunk)
      bytes.withLock { $0.consumed += chunk.count }
    }
    #expect(received == data)
    // キュー上限に加え、消費中のチャンクと生産側の読取境界を各1つ許容する。
    #expect(bytes.withLock { $0.maximumPending } <= limit + 2 * chunkSize)
    #expect(try Data(contentsOf: url) == data)
  }

  @Test("作業コピーの消費取消後は読取が停止し未送信のローカル変更を保持する")
  func preservesWorkingCopyAfterCancellation() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let data = Data(repeating: 0x42, count: 2 * 1_024 * 1_024)
    try data.write(to: url)
    let readBytes = Mutex(0)
    let gate = WorkingCopyConsumerGate()
    let cancellation = ChunkPipeCancellation()
    let task = Task {
      defer { cancellation.cancel() }
      let stream = BoundedChunkPipe.fileStream(
        at: url, chunkSize: 64 * 1_024, maximumBufferedBytes: 256 * 1_024,
        cancellation: cancellation
      ) { count in readBytes.withLock { $0 += count } }
      var firstChunk = true
      for try await _ in stream {
        if firstChunk {
          firstChunk = false
          await gate.suspend()
        }
      }
      // AsyncThrowingStreamが取消をEOFとして返しても、送信側は確定前に取消を再確認する。
      try Task.checkCancellation()
    }
    await waitUntil { await gate.isSuspended }
    #expect(readBytes.withLock { $0 } < data.count)
    task.cancel()
    await gate.resume()
    await #expect(throws: CancellationError.self) { try await task.value }
    await cancellation.waitForCompletion()
    let stoppedAt = readBytes.withLock { $0 }
    try await Task.sleep(for: .milliseconds(50))
    #expect(readBytes.withLock { $0 } == stoppedAt)
    #expect(stoppedAt < data.count)
    #expect(try Data(contentsOf: url) == data)
  }

  @Test("送信失敗後もstreamを保持したままproducer終了と作業コピー保持を確認する")
  func cancelsProducerWhileStreamIsRetained() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: url) }
    let data = Data(repeating: 0x42, count: 2 * 1_024 * 1_024)
    try data.write(to: url)
    let cancellation = ChunkPipeCancellation()
    let readBytes = Mutex(0)
    let stream = BoundedChunkPipe.fileStream(
      at: url, chunkSize: 64 * 1_024, maximumBufferedBytes: 256 * 1_024,
      cancellation: cancellation
    ) { count in readBytes.withLock { $0 += count } }
    var iterator = stream.makeAsyncIterator()
    _ = try #require(try await iterator.next())
    await waitUntil { readBytes.withLock { $0 } >= 256 * 1_024 }
    // consumerがthrowして後始末をawaitする間も、streamとiteratorは生存している。
    cancellation.cancel()
    await cancellation.waitForCompletion()
    let stoppedAt = readBytes.withLock { $0 }
    try await Task.sleep(for: .milliseconds(20))
    #expect(readBytes.withLock { $0 } == stoppedAt)
    #expect(stoppedAt < data.count)
    #expect(try Data(contentsOf: url) == data)
    withExtendedLifetime(stream) {}
  }

  @Test("全チャンクが順序どおり届く")
  func deliversAllChunksInOrder() async throws {
    let stream = BoundedChunkPipe.stream(limit: 4) { yield in
      for index in 0..<20 {
        try await yield(Data([UInt8(index)]))
      }
    }
    var received: [UInt8] = []
    for try await chunk in stream {
      received.append(chunk[0])
    }
    #expect(received == (0..<20).map(UInt8.init))
  }

  @Test("同期producerも全チャンクを上限つきで順序どおり届ける")
  func deliversSynchronousChunksInOrder() async throws {
    let stream = BoundedChunkPipe.synchronousStream(limit: 4, rateLimiter: nil) { yield in
      for index in 0..<20 {
        try yield(Data([UInt8(index)]))
      }
    }
    var received: [UInt8] = []
    for try await chunk in stream {
      received.append(chunk[0])
      try await Task.sleep(for: .milliseconds(2))
    }

    #expect(received == (0..<20).map(UInt8.init))
  }

  @Test("消費が遅いとき生産の先行は上限に収まる")
  func boundsProducerReadAhead() async throws {
    let maxBacklog = Mutex(0)
    let counters = Mutex<(produced: Int, consumed: Int)>((0, 0))
    let stream = BoundedChunkPipe.stream(limit: 4) { yield in
      for _ in 0..<20 {
        try await yield(Data([0]))
        counters.withLock { shared in
          shared.produced += 1
        }
        let backlog = counters.withLock { $0.produced - $0.consumed }
        maxBacklog.withLock { $0 = max($0, backlog) }
      }
    }
    for try await _ in stream {
      try await Task.sleep(for: .milliseconds(20))
      counters.withLock { $0.consumed += 1 }
    }
    // 上限4+境界の揺らぎ2を許容
    #expect(maxBacklog.withLock { $0 } <= 6)
  }

  @Test("消費側が早期breakしてもproducerは孤児化せず停止する")
  func stopsProducerAfterConsumerBreaksEarly() async throws {
    let producedCount = Mutex(0)
    do {
      let stream = BoundedChunkPipe.stream(limit: 4) { yield in
        for index in 0..<10_000 {
          try await yield(Data([UInt8(index % 256)]))
          producedCount.withLock { $0 += 1 }
        }
      }
      var received = 0
      for try await _ in stream {
        received += 1
        if received >= 3 { break }
      }
    }
    // ストリームへの参照がスコープを抜けるとinnerが終端し、producerTaskが
    // 打ち切られるはず。打ち切り後は生産が進まないことを、間隔を空けた
    // 2回の観測が一致することで確認する(固定回数の一致に依存しない)。
    try await Task.sleep(for: .milliseconds(100))
    let first = producedCount.withLock { $0 }
    try await Task.sleep(for: .milliseconds(200))
    let second = producedCount.withLock { $0 }
    #expect(first == second)
  }

  @Test("消費タスクのキャンセルがproducerへ伝播して停止する")
  func cancelPropagatesToProducer() async throws {
    let producedCount = Mutex(0)
    let stream = BoundedChunkPipe.stream(limit: 4) { yield in
      for index in 0..<10_000 {
        try await yield(Data([UInt8(index % 256)]))
        producedCount.withLock { $0 += 1 }
      }
    }
    let consumerTask = Task<Void, Never> {
      do {
        for try await _ in stream {
          try await Task.sleep(for: .milliseconds(20))
        }
      } catch {
        // タスクキャンセルによる終了を期待する。
      }
    }
    try await Task.sleep(for: .milliseconds(100))
    consumerTask.cancel()

    let finished = await raceAgainstTimeout(.seconds(2)) {
      await consumerTask.value
    }
    #expect(finished, "consumerTaskがキャンセル後に完了しなかった(ハング)")

    try await Task.sleep(for: .milliseconds(100))
    let first = producedCount.withLock { $0 }
    try await Task.sleep(for: .milliseconds(200))
    let second = producedCount.withLock { $0 }
    #expect(first == second)
  }

  @Test("producerのthrowは消費側までエラーとして届く")
  func propagatesProducerErrorToConsumer() async throws {
    struct BoomError: Error, Equatable {}

    let stream = BoundedChunkPipe.stream(limit: 4) { yield in
      try await yield(Data([0]))
      throw BoomError()
    }
    var received = 0
    do {
      for try await _ in stream {
        received += 1
      }
      Issue.record("BoomErrorがthrowされるはずだった")
    } catch is BoomError {
      // 期待どおり。
    }
    #expect(received == 1)
  }

  @Test("消費側のチャンク受け渡しを仮想時間の帯域上限へ収める")
  func limitsConsumerThroughput() async throws {
    let clock = VirtualTransferClock()
    let limiter = TransferRateLimiter(
      bytesPerSecond: 100,
      now: { clock.now },
      sleep: { duration in try await clock.sleep(for: duration) })
    let stream = BoundedChunkPipe.stream(limit: 4, rateLimiter: limiter) { yield in
      for _ in 0..<3 {
        try await yield(Data(repeating: 0, count: 100))
      }
    }

    for try await _ in stream {}

    #expect(clock.elapsedSeconds == 3)
  }

  @Test("複数ストリームも共有リミッタの合計上限を超えない")
  func limitsAggregateThroughputAcrossStreams() async throws {
    let clock = VirtualTransferClock()
    let limiter = TransferRateLimiter(
      bytesPerSecond: 100,
      now: { clock.now },
      sleep: { duration in try await clock.sleep(for: duration) })

    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<2 {
        group.addTask {
          let stream = BoundedChunkPipe.stream(limit: 2, rateLimiter: limiter) { yield in
            try await yield(Data(repeating: 0, count: 50))
            try await yield(Data(repeating: 0, count: 50))
          }
          for try await _ in stream {}
        }
      }
      try await group.waitForAll()
    }

    #expect(clock.elapsedSeconds == 2)

    let independentClocks = [VirtualTransferClock(), VirtualTransferClock()]
    let independentLimiters = independentClocks.map { clock in
      TransferRateLimiter(
        bytesPerSecond: 100,
        now: { clock.now },
        sleep: { duration in try await clock.sleep(for: duration) })
    }
    try await withThrowingTaskGroup(of: Void.self) { group in
      for limiter in independentLimiters {
        group.addTask {
          let stream = BoundedChunkPipe.stream(limit: 2, rateLimiter: limiter) { yield in
            try await yield(Data(repeating: 0, count: 50))
            try await yield(Data(repeating: 0, count: 50))
          }
          for try await _ in stream {}
        }
      }
      try await group.waitForAll()
    }

    #expect(independentClocks.map(\.elapsedSeconds) == [1, 1])
  }

  /// operationが期限内に完了すればtrue、タイムアウトすればfalseを返す。
  /// ハングしうる検証をテストごとタイムアウトさせるためのヘルパー。
  private func raceAgainstTimeout(
    _ timeout: Duration,
    _ operation: @escaping @Sendable () async -> Void
  ) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        await operation()
        return true
      }
      group.addTask {
        try? await Task.sleep(for: timeout)
        return false
      }
      let result = await group.next() ?? false
      group.cancelAll()
      return result
    }
  }
}

private actor WorkingCopyConsumerGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private(set) var isSuspended = false

  func suspend() async {
    isSuspended = true
    await withCheckedContinuation { continuation = $0 }
  }

  func resume() {
    continuation?.resume()
    continuation = nil
  }
}
