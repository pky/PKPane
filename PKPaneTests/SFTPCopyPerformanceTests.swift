import Foundation
import Synchronization
import Testing

@testable import PKPane

struct SFTPCopyPerformanceTests {
  @Test(
    "SFTP同接続コピーを小大ファイルと1ms・5msの往復遅延で10回計測する",
    .enabled(
      if: ProcessInfo.processInfo.environment["PKPANE_RV26_MEASUREMENTS"] == "1",
      "RV26前後計測時だけ10回の遅延フィクスチャを実行する"),
    arguments: [
      (chunks: 1, milliseconds: 1), (chunks: 1, milliseconds: 5),
      (chunks: 64, milliseconds: 1), (chunks: 64, milliseconds: 5),
    ])
  func measuresCopyPipeline(scenario: (chunks: Int, milliseconds: Int)) async throws {
    let chunkSize = SFTPChunkedTransfer.defaultChunkSize
    let data = Data((0..<(scenario.chunks * chunkSize + 3)).map { UInt8($0 % 251) })
    var samples: [Double] = []
    var readPeaks: [Int] = []
    var writePeaks: [Int] = []
    var requestCounts: [Int] = []
    for _ in 0..<10 {
      let fixture = SFTPCopyMeasurementFixture(
        data: data, delay: .milliseconds(scenario.milliseconds))
      let clock = ContinuousClock()
      let start = clock.now
      let copied = try await SFTPChunkedTransfer.copy(
        read: { offset, length in try await fixture.read(offset: offset, length: length) },
        write: { data, offset in try await fixture.write(data, offset: offset) })
      let duration = start.duration(to: clock.now).components
      samples.append(Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15)
      #expect(copied == Int64(data.count))
      #expect(fixture.copiedData == data)
      let counts = fixture.snapshot
      readPeaks.append(counts.maximumReads)
      writePeaks.append(counts.maximumWrites)
      requestCounts.append(counts.readRequests)
    }
    let sorted = samples.sorted()
    let lower = try #require(sorted.prefix(sorted.count / 2).last)
    let upper = try #require(sorted.dropFirst(sorted.count / 2).first)
    try writeRV26Measurement(
      name: "rv26-08-copy",
      values: [
        "bytes": data.count,
        "responseDelayMilliseconds": scenario.milliseconds,
        "samplesMilliseconds": samples,
        "medianMilliseconds": (lower + upper) / 2,
        "maximumMilliseconds": try #require(sorted.last),
        "readPeaks": readPeaks,
        "writePeaks": writePeaks,
        "readRequests": requestCounts,
      ])
  }
}

private final class SFTPCopyMeasurementFixture: Sendable {
  struct Snapshot: Sendable {
    var activeReads = 0
    var maximumReads = 0
    var activeWrites = 0
    var maximumWrites = 0
    var readRequests = 0
    var written: [UInt64: Data] = [:]
  }
  private let state = Mutex(Snapshot())
  private let data: Data
  private let delay: Duration

  init(data: Data, delay: Duration) {
    self.data = data
    self.delay = delay
  }

  var snapshot: Snapshot { state.withLock { $0 } }
  var copiedData: Data {
    state.withLock { value in
      value.written.sorted { $0.key < $1.key }.reduce(into: Data()) { $0.append($1.value) }
    }
  }

  func read(offset: UInt64, length: Int) async throws -> Data {
    state.withLock {
      $0.activeReads += 1
      $0.maximumReads = max($0.maximumReads, $0.activeReads)
      $0.readRequests += 1
    }
    defer { state.withLock { $0.activeReads -= 1 } }
    try await Task.sleep(for: delay)
    let start = Int(offset)
    guard start < data.count else { return Data() }
    return data.subdata(in: start..<min(start + length, data.count))
  }

  func write(_ chunk: Data, offset: UInt64) async throws {
    state.withLock {
      $0.activeWrites += 1
      $0.maximumWrites = max($0.maximumWrites, $0.activeWrites)
    }
    defer { state.withLock { $0.activeWrites -= 1 } }
    try await Task.sleep(for: delay)
    state.withLock { $0.written[offset] = chunk }
  }
}
