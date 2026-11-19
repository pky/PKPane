import Foundation
import Synchronization
import Testing

@testable import PKPane

struct CancellableFileCopierTests {
  @Test("clonefileでの高速パスはファイル内容を保ったまま完了する")
  func copiesFileUsingCloneFastPath() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "source.bin")
    let content = Data(repeating: 0x61, count: 4 * 1_024 * 1_024)
    try content.write(to: source)
    let destination = root.appending(path: "destination.bin")

    let reportedProgress = Mutex<[Int64]>([])
    try CancellableFileCopier.copy(
      from: source, to: destination,
      isCancelled: { false },
      progress: { value in reportedProgress.withLock { $0.append(value) } })

    let finalProgress = reportedProgress.withLock(\.last)
    #expect(try Data(contentsOf: destination) == content)
    #expect(finalProgress == Int64(content.count))
  }

  @Test("フォールバックコピーはファイル内容と最終進捗値を一致させる")
  func copiesFileUsingFallbackWithProgress() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "source.bin")
    let content = Data(repeating: 0x62, count: 8 * 1_024 * 1_024)
    try content.write(to: source)
    let destination = root.appending(path: "destination.bin")

    let reportedProgress = Mutex<[Int64]>([])
    try CancellableFileCopier.copy(
      from: source, to: destination,
      isCancelled: { false },
      progress: { value in reportedProgress.withLock { $0.append(value) } },
      cloneAttempt: { _, _ in false },
      copyfileAttempt: { _, _ in false })

    let isEmpty = reportedProgress.withLock(\.isEmpty)
    let finalProgress = reportedProgress.withLock(\.last)
    #expect(try Data(contentsOf: destination) == content)
    #expect(!isEmpty)
    #expect(finalProgress == Int64(content.count))
  }

  @Test("フォールバックコピー中のキャンセルは中断してエラーを投げる")
  func cancelsFallbackCopyMidway() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "source.bin")
    let content = Data(repeating: 0x63, count: 8 * 1_024 * 1_024)
    try content.write(to: source)
    let destination = root.appending(path: "destination.bin")

    let checkCount = Mutex<Int>(0)
    #expect(throws: Error.self) {
      try CancellableFileCopier.copy(
        from: source, to: destination,
        isCancelled: {
          checkCount.withLock { count in
            count += 1
            return count > 2
          }
        },
        cloneAttempt: { _, _ in false },
        copyfileAttempt: { _, _ in false })
    }

    if FileManager.default.fileExists(atPath: destination.path) {
      let partialSize =
        try FileManager.default.attributesOfItem(atPath: destination.path)[.size]
        as? Int64
      #expect((partialSize ?? 0) < Int64(content.count))
    }
  }

  @Test("ディレクトリ再帰フォールバックのキャンセルは全ファイルコピー前に打ち切る")
  func cancelsRecursiveDirectoryFallbackMidway() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceDirectory = root.appending(path: "source", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: sourceDirectory, withIntermediateDirectories: true)
    let fileCount = 200
    for index in 0..<fileCount {
      let file = sourceDirectory.appending(path: "file-\(index).bin")
      try Data(repeating: 0x64, count: 256 * 1_024).write(to: file)
    }
    let destinationDirectory = root.appending(path: "destination", directoryHint: .isDirectory)

    let copiedFileCallbacks = Mutex<Int>(0)
    #expect(throws: Error.self) {
      try CancellableFileCopier.copy(
        from: sourceDirectory, to: destinationDirectory,
        isCancelled: {
          copiedFileCallbacks.withLock { count in
            count += 1
            return count > 5
          }
        },
        cloneAttempt: { _, _ in false },
        copyfileAttempt: { _, _ in false })
    }

    let copiedCount =
      (try? FileManager.default.contentsOfDirectory(atPath: destinationDirectory.path).count)
      ?? 0
    #expect(copiedCount < fileCount)
  }

  @Test("フォールバックコピーはPOSIX権限とxattrを引き継ぐ")
  func fallbackCopyPreservesPermissionsAndExtendedAttributes() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "source.bin")
    try Data("内容".utf8).write(to: source)
    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: source.path)
    let attributeName = "com.pkpane.test"
    let attributeValue = Data("value".utf8)
    let setResult = attributeValue.withUnsafeBytes { bytes in
      setxattr(source.path, attributeName, bytes.baseAddress, bytes.count, 0, 0)
    }
    #expect(setResult == 0)
    let destination = root.appending(path: "destination.bin")

    try CancellableFileCopier.copy(
      from: source, to: destination,
      isCancelled: { false },
      cloneAttempt: { _, _ in false },
      copyfileAttempt: { _, _ in false })

    let permissions =
      try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions]
      as? Int
    #expect(permissions == 0o640)
    var readBuffer = [UInt8](repeating: 0, count: 16)
    let readLength = getxattr(
      destination.path, attributeName, &readBuffer, readBuffer.count, 0, 0)
    #expect(readLength == attributeValue.count)
  }

  @Test("同一ボリュームではcopyfileサーバーサイドコピーがチャンクループをスキップする")
  func copiesFileUsingCopyfileServerSideFastPath() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "source.bin")
    let content = Data(repeating: 0x65, count: 4 * 1_024 * 1_024)
    try content.write(to: source)
    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: source.path)
    let destination = root.appending(path: "destination.bin")

    let copyfileAttemptCallCount = Mutex<Int>(0)
    let reportedProgress = Mutex<[Int64]>([])
    try CancellableFileCopier.copy(
      from: source, to: destination,
      isCancelled: { false },
      progress: { value in reportedProgress.withLock { $0.append(value) } },
      cloneAttempt: { _, _ in false },
      copyfileAttempt: { sourceURL, destinationURL in
        copyfileAttemptCallCount.withLock { $0 += 1 }
        return CancellableFileCopier.defaultCopyfileAttempt(sourceURL, destinationURL)
      })

    let callCount = copyfileAttemptCallCount.withLock { $0 }
    let progressSamples = reportedProgress.withLock { $0 }
    let permissions =
      try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions]
      as? Int
    #expect(callCount == 1)
    #expect(try Data(contentsOf: destination) == content)
    // サーバーサイドコピーはチャンクループを経由しないため、進捗は完了時の1回のみ報告される。
    #expect(progressSamples == [Int64(content.count)])
    #expect(permissions == 0o640)
  }

  @Test("無制限ならネットワークボリュームでも従来の高速パスを維持する")
  func unlimitedNetworkCopyKeepsKernelFastPath() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "source.bin")
    let contents = Data("network-fast-path".utf8)
    try contents.write(to: source)
    let destination = root.appending(path: "destination.bin")
    let cloneCalls = Mutex(0)

    try CancellableFileCopier.copy(
      from: source,
      to: destination,
      isCancelled: { false },
      cloneAttempt: { sourceURL, destinationURL in
        cloneCalls.withLock { $0 += 1 }
        try? FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return true
      },
      copyfileAttempt: { _, _ in false },
      rateLimiter: TransferRateLimiter(),
      volumeIsLocal: { _ in false })

    #expect(cloneCalls.withLock { $0 } == 1)
    #expect(try Data(contentsOf: destination) == contents)
  }

  @Test("copyfile失敗時はチャンクコピーへフォールバックする")
  func fallsBackToChunkCopyWhenCopyfileAttemptFails() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "source.bin")
    let content = Data(repeating: 0x66, count: 2 * 1_024 * 1_024)
    try content.write(to: source)
    let destination = root.appending(path: "destination.bin")

    try CancellableFileCopier.copy(
      from: source, to: destination,
      isCancelled: { false },
      cloneAttempt: { _, _ in false },
      copyfileAttempt: { _, _ in false })

    #expect(try Data(contentsOf: destination) == content)
  }

  @Test("フォールバックのチャンクコピーへ帯域制限を適用する")
  func limitsFallbackChunkCopyThroughput() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "source.bin")
    let chunkSize = 1_024 * 1_024
    let content = Data(repeating: 0x68, count: chunkSize * 2)
    try content.write(to: source)
    let destination = root.appending(path: "destination.bin")
    let clock = VirtualTransferClock()
    let limiter = TransferRateLimiter(
      bytesPerSecond: Int64(chunkSize),
      now: { clock.now },
      sleep: { duration in try await clock.sleep(for: duration) })

    try await CancellableFileCopier.performOnDedicatedThread { isCancelled in
      try CancellableFileCopier.copy(
        from: source,
        to: destination,
        isCancelled: isCancelled,
        cloneAttempt: { _, _ in false },
        copyfileAttempt: { _, _ in false },
        rateLimiter: limiter)
    }

    #expect(try Data(contentsOf: destination) == content)
    #expect(clock.elapsedSeconds == 2)
  }

  @Test("同期帯域待機はキャンセル判定後すみやかに抜ける")
  func blockingRateLimitWaiterStopsPromptlyWhenCancelled() throws {
    let waiter = BlockingRateLimitWaiter()
    let clock = ContinuousClock()
    let startedAt = clock.now

    #expect(throws: CancellationError.self) {
      try waiter.wait(isCancelled: { true })
    }
    #expect(clock.now - startedAt < .milliseconds(500))
  }

  @Test("ディレクトリ再帰でcopyfileサーバーサイドコピーが成功してもファイル単位のキャンセル粒度は保たれる")
  func cancelsRecursiveDirectoryMidwayEvenWithCopyfileFastPath() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceDirectory = root.appending(path: "source", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: sourceDirectory, withIntermediateDirectories: true)
    let fileCount = 50
    for index in 0..<fileCount {
      let file = sourceDirectory.appending(path: "file-\(index).bin")
      try Data(repeating: 0x67, count: 1_024).write(to: file)
    }
    let destinationDirectory = root.appending(path: "destination", directoryHint: .isDirectory)

    let checkCount = Mutex<Int>(0)
    #expect(throws: Error.self) {
      try CancellableFileCopier.copy(
        from: sourceDirectory, to: destinationDirectory,
        isCancelled: {
          checkCount.withLock { count in
            count += 1
            return count > 5
          }
        },
        cloneAttempt: { _, _ in false })
    }

    let copiedCount =
      (try? FileManager.default.contentsOfDirectory(atPath: destinationDirectory.path).count)
      ?? 0
    #expect(copiedCount > 0)
    #expect(copiedCount < fileCount)
  }

  private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}
