import Foundation
import Synchronization
import Testing

@testable import PKPane

struct SFTPPipelinedTransferTests {
  private func makeChunks(_ chunks: [Data]) -> AsyncThrowingStream<Data, Error> {
    AsyncThrowingStream { continuation in
      for chunk in chunks { continuation.yield(chunk) }
      continuation.finish()
    }
  }

  @Test("全チャンクが正しいオフセットへちょうど1回書かれる")
  func writesEveryChunkExactlyOnceAtCorrectOffset() async throws {
    let chunks = (0..<32).map { index in Data(repeating: UInt8(index), count: 100) }
    let written = Mutex<[UInt64: Data]>([:])
    let writer = SFTPPipelinedWriter(maxInFlight: 8)

    try await writer.write(chunks: makeChunks(chunks)) { data, offset in
      try await Task.sleep(for: .milliseconds(10))
      written.withLock { $0[offset] = data }
    } progress: { _ in
    }

    let result = written.withLock { $0 }
    #expect(result.count == 32)
    for index in 0..<32 {
      #expect(result[UInt64(index * 100)] == chunks[index])
    }
  }

  @Test("並行発行により直列よりも大幅に速い")
  func overlapsWritesForThroughput() async throws {
    let chunks = (0..<32).map { _ in Data(repeating: 0, count: 100) }
    let writer = SFTPPipelinedWriter(maxInFlight: 8)
    let clock = ContinuousClock()
    let start = clock.now

    try await writer.write(chunks: makeChunks(chunks)) { _, _ in
      try await Task.sleep(for: .milliseconds(10))
    } progress: { _ in
    }

    let elapsed = clock.now - start
    // 直列なら32×10ms=320ms。8並行なら約40ms+オーバーヘッド。150ms未満を合格とする
    #expect(elapsed < .milliseconds(150))
  }

  @Test("進捗は単調増加し合計に到達する")
  func progressIsMonotonicAndReachesTotal() async throws {
    let chunks = (0..<16).map { _ in Data(repeating: 0, count: 100) }
    let reports = Mutex<[Int64]>([])
    let writer = SFTPPipelinedWriter(maxInFlight: 4)

    try await writer.write(chunks: makeChunks(chunks)) { _, _ in
      try await Task.sleep(for: .milliseconds(5))
    } progress: { completed in
      reports.withLock { $0.append(completed) }
    }

    let values = reports.withLock { $0 }
    #expect(values == values.sorted())
    #expect(values.last == 1600)
  }

  @Test("書き込み失敗はエラーとして伝播する")
  func propagatesWriteFailure() async {
    struct WriteFailure: Error {}
    let chunks = (0..<8).map { _ in Data(repeating: 0, count: 100) }
    let writer = SFTPPipelinedWriter(maxInFlight: 4)

    await #expect(throws: WriteFailure.self) {
      try await writer.write(chunks: makeChunks(chunks)) { _, offset in
        if offset >= 300 { throw WriteFailure() }
        try await Task.sleep(for: .milliseconds(5))
      } progress: { _ in
      }
    }
  }

  @Test("読み出しは完了順に依らずオフセット順で受信される")
  func deliversChunksInOffsetOrder() async throws {
    let sourceData = Data((0..<3_250).map { UInt8($0 % 251) })
    let received = Mutex(Data())
    let reader = SFTPPipelinedReader(maxInFlight: 8, chunkSize: 100)

    try await reader.read { offset, length in
      // 完了順をわざと乱すため、オフセットに応じて遅延を変える
      let delayMilliseconds = (offset / 100) % 3 * 5
      try await Task.sleep(for: .milliseconds(Int(delayMilliseconds)))
      let start = Int(offset)
      guard start < sourceData.count else { return Data() }
      let end = min(start + length, sourceData.count)
      return sourceData.subdata(in: start..<end)
    } receive: { chunk in
      received.withLock { $0.append(chunk) }
    }

    #expect(received.withLock { $0 } == sourceData)
  }

  @Test("読み出しの並行発行により直列よりも速い")
  func overlapsReadsForThroughput() async throws {
    let reader = SFTPPipelinedReader(maxInFlight: 8, chunkSize: 100)
    let clock = ContinuousClock()
    let start = clock.now

    try await reader.read { offset, _ in
      try await Task.sleep(for: .milliseconds(10))
      return offset < 3_200 ? Data(repeating: 0, count: 100) : Data()
    } receive: { _ in
    }

    // 直列なら33×10ms=330ms。150ms未満を合格とする
    #expect(clock.now - start < .milliseconds(150))
  }

  @Test("EOFでない短い読みでもデータが欠落せず再組み立てされる")
  func handlesMidStreamShortReadWithoutTreatingItAsEOF() async throws {
    let sourceData = Data((0..<2_000).map { UInt8($0 % 251) })
    let received = Mutex(Data())
    let reader = SFTPPipelinedReader(maxInFlight: 8, chunkSize: 100)

    try await reader.read { offset, length in
      let start = Int(offset)
      guard start < sourceData.count else { return Data() }
      // オフセット400への読みだけ、EOFではないのに要求量より少なく返す
      // (SFTPサーバーが中間で短く返す実際の挙動を模す)
      let effectiveLength = offset == 400 ? min(length, 30) : length
      let end = min(start + effectiveLength, sourceData.count)
      return sourceData.subdata(in: start..<end)
    } receive: { chunk in
      received.withLock { $0.append(chunk) }
    }

    #expect(received.withLock { $0 } == sourceData)
  }

  @Test("chunkSizeちょうどの境界で終わるファイルは末尾の空読みでEOF判定される")
  func detectsEOFAtExactChunkBoundaryViaEmptyReadOnly() async throws {
    let sourceData = Data((0..<3_000).map { UInt8($0 % 251) })
    let received = Mutex(Data())
    let reader = SFTPPipelinedReader(maxInFlight: 8, chunkSize: 100)

    try await reader.read { offset, length in
      let start = Int(offset)
      guard start < sourceData.count else { return Data() }
      let end = min(start + length, sourceData.count)
      return sourceData.subdata(in: start..<end)
    } receive: { chunk in
      received.withLock { $0.append(chunk) }
    }

    #expect(received.withLock { $0 } == sourceData)
  }

  @Test("常に半分しか返さないサーバーでもinFlightがmaxInFlightを超えない")
  func shortReadsNeverExceedMaxInFlight() async throws {
    let maxInFlight = 4
    let sourceData = Data((0..<5_000).map { UInt8($0 % 251) })
    let received = Mutex(Data())
    let reader = SFTPPipelinedReader(maxInFlight: maxInFlight, chunkSize: 100)
    let inFlightState = Mutex((current: 0, peak: 0))

    try await reader.read { offset, length in
      inFlightState.withLock { state in
        state.current += 1
        state.peak = max(state.peak, state.current)
      }
      defer {
        inFlightState.withLock { state in
          state.current -= 1
        }
      }
      let start = Int(offset)
      guard start < sourceData.count else { return Data() }
      // EOFではないのに常に要求量の半分しか返さないサーバーを模す
      let effectiveLength = max(1, length / 2)
      let end = min(start + effectiveLength, sourceData.count)
      return sourceData.subdata(in: start..<end)
    } receive: { chunk in
      received.withLock { $0.append(chunk) }
    }

    let peak = inFlightState.withLock { $0.peak }
    #expect(peak <= maxInFlight)
    #expect(received.withLock { $0 } == sourceData)
  }
}
