import Foundation
import Synchronization
import Testing

@testable import PKPane

struct SFTPStallGuardTests {
  @Test("ストール時はonAbortが発火しストールエラーになる")
  func firesAbortOnStall() async {
    let aborted = Mutex(false)
    let guardUnderTest = SFTPStallGuard(timeout: .milliseconds(200)) {
      aborted.withLock { $0 = true }
    }
    let clock = ContinuousClock()
    let start = clock.now
    await #expect(throws: SFTPTransferStallError.self) {
      try await guardUnderTest.run {
        try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<Void, Error>) in
          // 応答が永遠に来ないsendRequestを模す。abort時にguardが解放する想定はなく、
          // 実環境ではclient.close()がpromiseを失敗させる。テストでは代わりに
          // onAbort後にguard側がストールエラーを投げることを検証する。
          _ = continuation
        }
      }
    }
    #expect(aborted.withLock { $0 })
    #expect(clock.now - start < .seconds(2))
  }

  @Test("キャンセル時はonAbortが発火しCancellationErrorになる")
  func firesAbortOnCancellation() async {
    let aborted = Mutex(false)
    let guardUnderTest = SFTPStallGuard(timeout: .seconds(30)) {
      aborted.withLock { $0 = true }
    }
    let task = Task {
      try await guardUnderTest.run {
        try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<Void, Error>) in
          _ = continuation
        }
      }
    }
    try? await Task.sleep(for: .milliseconds(100))
    task.cancel()
    let result = await task.result
    #expect(aborted.withLock { $0 })
    guard case .failure(let error) = result else {
      Issue.record("キャンセルが伝播していない")
      return
    }
    #expect(error is CancellationError)
  }

  @Test("abort後にoperationが独自のエラーを投げてもCancellationErrorへ変換される")
  func mapsOperationErrorAfterAbortToCancellation() async {
    struct DummyError: Error {}
    let (abortSignalStream, abortSignalContinuation) = AsyncStream<Void>.makeStream()
    let guardUnderTest = SFTPStallGuard(timeout: .seconds(30)) {
      // 実環境のonAbort(=client.close)を模し、operation側の待機をここで解放する。
      // operationはwatchdogより先にこのエラーでresumeBoxを埋めようとする経路がある。
      abortSignalContinuation.yield(())
    }
    let task = Task {
      try await guardUnderTest.run {
        var iterator = abortSignalStream.makeAsyncIterator()
        _ = await iterator.next()
        throw DummyError()
      }
    }
    try? await Task.sleep(for: .milliseconds(100))
    task.cancel()
    let result = await task.result
    guard case .failure(let error) = result else {
      Issue.record("エラーが伝播していない")
      return
    }
    #expect(error is CancellationError)
    #expect(!(error is DummyError))
  }

  @Test("進捗があればタイムアウトしない")
  func activityPreventsTimeout() async throws {
    let guardUnderTest = SFTPStallGuard(timeout: .milliseconds(300)) {}
    let value = try await guardUnderTest.run {
      for _ in 0..<5 {
        try await Task.sleep(for: .milliseconds(100))
        guardUnderTest.recordActivity()
      }
      return 42
    }
    #expect(value == 42)
  }
}
