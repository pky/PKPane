import Foundation
import Testing

@testable import PKPane

struct SFTPChunkedTransferTests {
  @Test("SFTPコピーは固定サイズのチャンクで全内容を転送する")
  func copiesInBoundedChunks() async throws {
    let source = ChunkSource(data: Data(repeating: 0x61, count: 150_000))
    let destination = ChunkDestination()

    let copiedBytes = try await SFTPChunkedTransfer.copy(
      read: { offset, maximumLength in
        await source.read(offset: offset, maximumLength: maximumLength)
      },
      write: { data, offset in
        await destination.write(data, at: offset)
      })

    #expect(copiedBytes == 150_000)
    #expect(await source.maximumRequestedLength() == SFTPChunkedTransfer.defaultChunkSize)
    #expect(await destination.data() == Data(repeating: 0x61, count: 150_000))
  }

  @Test("SFTPコピーはキャンセル後に次の読み取りを開始しない")
  func stopsAfterCancellation() async throws {
    let source = WaitingChunkSource()
    let task = Task {
      try await SFTPChunkedTransfer.copy(
        read: { offset, maximumLength in
          try await source.read(offset: offset, maximumLength: maximumLength)
        },
        write: { _, _ in })
    }

    await source.waitUntilReadStarted()
    task.cancel()

    await #expect(throws: CancellationError.self) {
      try await task.value
    }
  }
}

private actor ChunkSource {
  private let data: Data
  private var requestedLengths: [Int] = []

  init(data: Data) {
    self.data = data
  }

  func read(offset: UInt64, maximumLength: Int) -> Data {
    requestedLengths.append(maximumLength)
    let start = Int(offset)
    guard start < data.count else { return Data() }
    let end = min(start + maximumLength, data.count)
    return data.subdata(in: start..<end)
  }

  func maximumRequestedLength() -> Int {
    requestedLengths.max() ?? 0
  }
}

private actor ChunkDestination {
  private var storage = Data()

  func write(_ data: Data, at offset: UInt64) {
    guard offset == storage.count else {
      Issue.record("チャンク書き込みオフセットが不整合です: 期待\(storage.count) 実際\(offset)")
      return
    }
    storage.append(data)
  }

  func data() -> Data {
    storage
  }
}

private actor WaitingChunkSource {
  private var didStartRead = false

  func read(offset _: UInt64, maximumLength _: Int) async throws -> Data {
    didStartRead = true
    try await Task.sleep(for: .seconds(10))
    return Data()
  }

  func waitUntilReadStarted() async {
    await waitUntil(timeout: .seconds(5), "チャンク読み込みが期限内に開始されなかった") {
      didStartRead
    }
  }
}
