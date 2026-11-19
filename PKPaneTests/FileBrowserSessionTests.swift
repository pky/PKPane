import Foundation
import Synchronization
import Testing

@testable import PKPane

@MainActor
struct FileBrowserSessionTests {
  @Test("presentErrorは外部エラーのホームパスをマスクする")
  func presentErrorMasksHomeDirectory() {
    let provider = LocalFileProvider()
    let session = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(
        localURL: URL(filePath: NSHomeDirectory()),
        providerID: provider.id),
      transferQueue: .isolatedForTesting())
    let error = NSError(
      domain: "PresentationFixture",
      code: 1,
      userInfo: [
        NSLocalizedDescriptionKey: "読み込み失敗: \(NSHomeDirectory())/Documents/秘密.txt"
      ])

    session.presentError(error)

    #expect(session.errorMessage?.contains("~/Documents/秘密.txt") == true)
    #expect(session.errorMessage?.contains(NSHomeDirectory()) == false)
  }

  @Test("リンク先と実体が同じフォルダなら転送を拒否する")
  func rejectsTransferToSameDirectoryThroughSymlink() throws {
    let transferQueue = TransferQueue.isolatedForTesting()
    let root = FileManager.default.temporaryDirectory
      .appending(
        path: "FileBrowserSessionTests-\(UUID().uuidString)",
        directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    let actualDirectory = root.appending(path: "actual", directoryHint: .isDirectory)
    let linkedDirectory = root.appending(path: "linked", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: actualDirectory, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: linkedDirectory, withDestinationURL: actualDirectory)

    let provider = LocalFileProvider()
    let source = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: linkedDirectory, providerID: provider.id),
      transferQueue: transferQueue)
    let destination = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: actualDirectory, providerID: provider.id),
      transferQueue: transferQueue)
    let item = FileItem(
      url: linkedDirectory.appending(path: "report.txt"),
      providerID: provider.id,
      isDirectory: false)

    source.copy([item], to: destination)

    #expect(source.errorMessage == "同じフォルダへは転送できません。")
  }

  @Test("異なるProviderのペイン間でもファイルをコピーできる")
  func copiesFileAcrossProviderSessions() async throws {
    let sourceProvider = MemoryStreamProvider(
      id: FileProviderID(rawValue: "source"),
      files: ["./report.txt": Data("共通転送".utf8)])
    let destinationProvider = MemoryStreamProvider(
      id: FileProviderID(rawValue: "destination"))
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let source = FileBrowserSession(
      provider: sourceProvider,
      initialLocation: FileLocation(remotePath: ".", providerID: sourceProvider.id),
      transferQueue: queue)
    let destination = FileBrowserSession(
      provider: destinationProvider,
      initialLocation: FileLocation(remotePath: ".", providerID: destinationProvider.id),
      transferQueue: queue)

    source.load()
    destination.load()
    await waitForLoading(source)
    await waitForLoading(destination)
    let item = try #require(source.items.first)

    source.copy([item], to: destination)
    await waitForTransfer(source)

    #expect(destinationProvider.data(at: "./report.txt") == Data("共通転送".utf8))
    #expect(destination.items.map(\.name) == ["report.txt"])
  }

  @Test("異なるProviderへの移動は転送完了後にだけ元ファイルを削除する")
  func movesFileAcrossProviderSessions() async throws {
    let sourceProvider = MemoryStreamProvider(
      id: FileProviderID(rawValue: "source"),
      files: ["./report.txt": Data("共通移動".utf8)])
    let destinationProvider = MemoryStreamProvider(
      id: FileProviderID(rawValue: "destination"))
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let source = FileBrowserSession(
      provider: sourceProvider,
      initialLocation: FileLocation(remotePath: ".", providerID: sourceProvider.id),
      transferQueue: queue)
    let destination = FileBrowserSession(
      provider: destinationProvider,
      initialLocation: FileLocation(remotePath: ".", providerID: destinationProvider.id),
      transferQueue: queue)

    source.load()
    destination.load()
    await waitForLoading(source)
    await waitForLoading(destination)
    let item = try #require(source.items.first)

    source.move([item], to: destination)
    await waitForTransfer(source)

    #expect(sourceProvider.data(at: "./report.txt") == nil)
    #expect(destinationProvider.data(at: "./report.txt") == Data("共通移動".utf8))
  }

  @Test("Provider間転送の同名項目は置換確認後にだけ削除する")
  func resolvesCrossProviderTransferConflict() async throws {
    let sourceProvider = MemoryStreamProvider(
      id: FileProviderID(rawValue: "source"),
      files: ["./report.txt": Data("新しい内容".utf8)])
    let destinationProvider = MemoryStreamProvider(
      id: FileProviderID(rawValue: "destination"),
      files: ["./report.txt": Data("既存内容".utf8)])
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let source = FileBrowserSession(
      provider: sourceProvider,
      initialLocation: FileLocation(remotePath: ".", providerID: sourceProvider.id),
      transferQueue: queue)
    let destination = FileBrowserSession(
      provider: destinationProvider,
      initialLocation: FileLocation(remotePath: ".", providerID: destinationProvider.id),
      transferQueue: queue)

    source.load()
    destination.load()
    await waitForLoading(source)
    await waitForLoading(destination)
    let item = try #require(source.items.first)

    source.copy([item], to: destination)

    #expect(source.pendingTransferConflict?.sourceName == "report.txt")
    #expect(destinationProvider.data(at: "./report.txt") == Data("既存内容".utf8))

    source.resolvePendingTransferConflict(replaceExisting: true)
    await waitForTransfer(source)

    #expect(source.pendingTransferConflict == nil)
    #expect(destinationProvider.data(at: "./report.txt") == Data("新しい内容".utf8))
  }

  @Test("同一Providerの置換確認後コピーは既存ファイルを上書きする")
  func resolvesSameProviderTransferConflict() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "FileBrowserSessionSameProviderConflict-\(UUID().uuidString)",
      directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceRoot = root.appending(path: "source", directoryHint: .isDirectory)
    let destinationRoot = root.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
    let sourceURL = sourceRoot.appending(path: "report.txt")
    let destinationURL = destinationRoot.appending(path: "report.txt")
    let replacementData = Data("置換後の内容".utf8)
    try replacementData.write(to: sourceURL)
    try Data("既存内容".utf8).write(to: destinationURL)

    let provider = LocalFileProvider()
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let source = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: sourceRoot, providerID: provider.id),
      transferQueue: queue)
    let destination = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: destinationRoot, providerID: provider.id),
      transferQueue: queue)
    source.load()
    destination.load()
    await waitForLoading(source)
    await waitForLoading(destination)
    let item = try #require(source.items.first)

    source.copy([item], to: destination)
    #expect(source.pendingTransferConflict?.sourceName == "report.txt")

    source.resolvePendingTransferConflict(replaceExisting: true)
    await waitForTransfer(source)

    #expect(try Data(contentsOf: destinationURL) == replacementData)
    #expect(await queue.allJobs().first?.state == .completed)
  }

  @Test("同一Provider内moveの置換確認結果をProviderへ渡す")
  func resolvingConflictWithReplaceForwardsReplacingExistingToProviderMove() async throws {
    let provider = MoveReplacingExistingSpyProvider(
      id: FileProviderID(rawValue: "same-provider-move-spy"),
      files: [
        "/source/report.txt": Data("新しい内容".utf8),
        "/destination/report.txt": Data("既存内容".utf8),
      ])
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let source = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: "/source", providerID: provider.id),
      transferQueue: queue)
    let destination = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: "/destination", providerID: provider.id),
      transferQueue: queue)
    source.load()
    destination.load()
    await waitForLoading(source)
    await waitForLoading(destination)
    let item = try #require(source.items.first)

    source.move([item], to: destination)
    #expect(source.pendingTransferConflict?.sourceName == "report.txt")

    source.resolvePendingTransferConflict(replaceExisting: true)
    await waitForTransfer(source)

    #expect(provider.moveReplacingExistingValues() == [true])
  }

  @Test("衝突なしの同一Provider内moveは置換なしをProviderへ渡す")
  func moveWithoutConflictForwardsReplacingExistingFalseToProviderMove() async throws {
    let provider = MoveReplacingExistingSpyProvider(
      id: FileProviderID(rawValue: "same-provider-move-without-conflict-spy"),
      files: ["/source/report.txt": Data("内容".utf8)])
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let source = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: "/source", providerID: provider.id),
      transferQueue: queue)
    let destination = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: "/destination", providerID: provider.id),
      transferQueue: queue)
    source.load()
    destination.load()
    await waitForLoading(source)
    await waitForLoading(destination)
    let item = try #require(source.items.first)

    source.move([item], to: destination)
    await waitForTransfer(source)

    #expect(provider.moveReplacingExistingValues() == [false])
  }

  @Test("失敗したProvider間転送を送信元ペインから再試行できる")
  func retriesFailedCrossProviderTransfer() async throws {
    // MemoryStreamProviderはAutoReconnectEligibleProviderに適合しない(SFTP限定の
    // スコープ決定)ため、自動再接続(P1-3)は発火せず即座にfailed+手動リトライ可能になる。
    let sourceProvider = MemoryStreamProvider(
      id: FileProviderID(rawValue: "source"),
      files: ["./report.txt": Data("再試行内容".utf8)])
    let destinationProvider = MemoryStreamProvider(
      id: FileProviderID(rawValue: "destination"),
      failsNextWrite: true)
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let source = FileBrowserSession(
      provider: sourceProvider,
      initialLocation: FileLocation(remotePath: ".", providerID: sourceProvider.id),
      transferQueue: queue)
    let destination = FileBrowserSession(
      provider: destinationProvider,
      initialLocation: FileLocation(remotePath: ".", providerID: destinationProvider.id),
      transferQueue: queue)

    source.load()
    destination.load()
    await waitForLoading(source)
    await waitForLoading(destination)
    let item = try #require(source.items.first)

    source.copy([item], to: destination)
    await waitForTransfer(source)

    #expect(source.canRetryLastTransfer)
    #expect(destinationProvider.data(at: "./report.txt") == nil)

    source.retryLastTransfer()
    await waitForTransfer(source)

    #expect(!source.canRetryLastTransfer)
    #expect(destinationProvider.data(at: "./report.txt") == Data("再試行内容".utf8))
  }

  @Test("転送バーの再試行準備はerrorMessageを書き換えない")
  func prepareTransferRetryDoesNotSetErrorMessage() async throws {
    let transferQueue = TransferQueue.isolatedForTesting()
    let sourceProvider = MemoryStreamProvider(
      id: FileProviderID(rawValue: "source"),
      files: ["./report.txt": Data("バー再試行".utf8)])
    let destinationProvider = MemoryStreamProvider(id: FileProviderID(rawValue: "destination"))
    let source = FileBrowserSession(
      provider: sourceProvider,
      initialLocation: FileLocation(remotePath: ".", providerID: sourceProvider.id),
      transferQueue: transferQueue)
    let destination = FileBrowserSession(
      provider: destinationProvider,
      initialLocation: FileLocation(remotePath: ".", providerID: destinationProvider.id),
      transferQueue: transferQueue)
    source.load()
    destination.load()
    await waitForLoading(source)
    await waitForLoading(destination)
    let item = try #require(source.items.first)

    var job = TransferJob(
      kind: .copy,
      items: [item],
      sourceProviderID: sourceProvider.id,
      destinationProviderID: destinationProvider.id,
      destination: destination.currentLocation)
    job.state = .failed
    job.errorDescription = "テスト用の失敗理由"

    let matched = source.prepareTransferRetry(job, to: destination)

    #expect(matched)
    #expect(source.canRetryLastTransfer)
    #expect(source.errorMessage == nil)
  }

  @Test("再起動復元のrestoreInterruptedTransferは引き続き一覧エラーとして通知する")
  func restoreInterruptedTransferStillSetsErrorMessage() async throws {
    let transferQueue = TransferQueue.isolatedForTesting()
    let sourceProvider = MemoryStreamProvider(
      id: FileProviderID(rawValue: "source"),
      files: ["./report.txt": Data("再起動復元".utf8)])
    let destinationProvider = MemoryStreamProvider(id: FileProviderID(rawValue: "destination"))
    let source = FileBrowserSession(
      provider: sourceProvider,
      initialLocation: FileLocation(remotePath: ".", providerID: sourceProvider.id),
      transferQueue: transferQueue)
    let destination = FileBrowserSession(
      provider: destinationProvider,
      initialLocation: FileLocation(remotePath: ".", providerID: destinationProvider.id),
      transferQueue: transferQueue)
    source.load()
    destination.load()
    await waitForLoading(source)
    await waitForLoading(destination)
    let item = try #require(source.items.first)

    var job = TransferJob(
      kind: .copy,
      items: [item],
      sourceProviderID: sourceProvider.id,
      destinationProviderID: destinationProvider.id,
      destination: destination.currentLocation)
    job.state = .interrupted
    job.errorDescription = "テスト用の中断理由"

    source.restoreInterruptedTransfer(job, to: destination)

    #expect(source.canRetryLastTransfer)
    #expect(source.errorMessage == "テスト用の中断理由")
  }

  @Test("pausedの復元と再開は既存interruptedジョブの手動再試行状態を破壊しない")
  func pausedResumePreservesInterruptedRetryState() async throws {
    let provider = ResumeTrackingProvider(
      id: FileProviderID(rawValue: "separate-resume-state"),
      files: [
        "./src/interrupted.bin": Data(repeating: 0x69, count: 100),
        "./src/paused.bin": Data(repeating: 0x70, count: 200),
      ])
    let destinationLocation = FileLocation(remotePath: "./dst", providerID: provider.id)
    let interruptedItem = FileItem(
      remotePath: "./src/interrupted.bin",
      url: URL(fileURLWithPath: "/interrupted.bin"),
      providerID: provider.id,
      isDirectory: false,
      size: 100)
    let pausedItem = FileItem(
      remotePath: "./src/paused.bin",
      url: URL(fileURLWithPath: "/paused.bin"),
      providerID: provider.id,
      isDirectory: false,
      size: 200)
    var interrupted = TransferJob(
      kind: .copy,
      items: [interruptedItem],
      sourceProviderID: provider.id,
      destinationProviderID: provider.id,
      destination: destinationLocation)
    interrupted.state = .interrupted
    var paused = TransferJob(
      kind: .copy,
      items: [pausedItem],
      sourceProviderID: provider.id,
      destinationProviderID: provider.id,
      destination: destinationLocation)
    paused.state = .paused
    let store = InMemoryTransferJobStore()
    try store.save([interrupted, paused])
    let queue = TransferQueue(store: store)
    let source = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: "./src", providerID: provider.id),
      transferQueue: queue)
    let destination = FileBrowserSession(
      provider: provider,
      initialLocation: destinationLocation,
      transferQueue: queue)
    source.load()
    destination.load()
    await waitForLoading(source)
    await waitForLoading(destination)

    #expect(source.prepareTransferRetry(interrupted, to: destination))
    #expect(source.prepareTransferResume(paused, to: destination))
    #expect(source.canRetryLastTransfer)

    #expect(source.resumeTransfer(paused.id))
    _ = try #require(await waitForJobState(.completed, jobID: paused.id, in: queue))
    await waitForTransfer(source)
    #expect(source.canRetryLastTransfer)
    #expect(provider.copyCallCount(for: "paused.bin") == 1)
    #expect(provider.copyCallCount(for: "interrupted.bin") == 0)

    source.retryLastTransfer()
    _ = try #require(await waitForJobState(.completed, jobID: interrupted.id, in: queue))
    await waitForTransfer(source)
    #expect(provider.copyCallCount(for: "interrupted.bin") == 1)
  }

  @Test("大きな転送の開始はMainActorを待たせない")
  func startsTransferWithoutBlockingMainActor() async throws {
    let transferQueue = TransferQueue.isolatedForTesting()
    let sourceProvider = MemoryStreamProvider(
      id: FileProviderID(rawValue: "source"),
      files: ["./large.bin": Data(repeating: 0x61, count: 8 * 1_024 * 1_024)])
    let destinationProvider = MemoryStreamProvider(
      id: FileProviderID(rawValue: "destination"),
      writeDelay: .milliseconds(100))
    let source = FileBrowserSession(
      provider: sourceProvider,
      initialLocation: FileLocation(remotePath: ".", providerID: sourceProvider.id),
      transferQueue: transferQueue)
    let destination = FileBrowserSession(
      provider: destinationProvider,
      initialLocation: FileLocation(remotePath: ".", providerID: destinationProvider.id),
      transferQueue: transferQueue)
    source.load()
    destination.load()
    await waitForLoading(source)
    await waitForLoading(destination)
    let item = try #require(source.items.first)

    let clock = ContinuousClock()
    let duration = clock.measure {
      source.copy([item], to: destination)
    }

    #expect(duration < .milliseconds(100))
    #expect(source.isTransferring)
    source.cancelTransfer()
    await waitForTransfer(source)
  }

  @Test("同じペインから複数の転送を待機列へ追加できる")
  func enqueuesConcurrentTransfersFromSamePane() async throws {
    let sourceProvider = MemoryStreamProvider(
      id: FileProviderID(rawValue: "source"),
      files: [
        "./a.txt": Data("A".utf8),
        "./b.txt": Data("B".utf8),
      ])
    let destinationProvider = MemoryStreamProvider(
      id: FileProviderID(rawValue: "destination"),
      writeDelay: .milliseconds(200))
    let queue = TransferQueue(store: InMemoryTransferJobStore(), maximumConcurrentTransfers: 1)
    let source = FileBrowserSession(
      provider: sourceProvider,
      initialLocation: FileLocation(remotePath: ".", providerID: sourceProvider.id),
      transferQueue: queue)
    let destination = FileBrowserSession(
      provider: destinationProvider,
      initialLocation: FileLocation(remotePath: ".", providerID: destinationProvider.id),
      transferQueue: queue)
    source.load()
    destination.load()
    await waitForLoading(source)
    await waitForLoading(destination)
    let first = try #require(source.items.first(where: { $0.name == "a.txt" }))
    let second = try #require(source.items.first(where: { $0.name == "b.txt" }))

    source.copy([first], to: destination)
    source.copy([second], to: destination)

    for _ in 0..<100 {
      if await queue.allJobs().count == 2 { break }
      await Task.yield()
    }
    let queuedJobs = await queue.allJobs()
    #expect(queuedJobs.count == 2)
    #expect(queuedJobs.contains(where: { $0.state == .running }))
    #expect(queuedJobs.contains(where: { $0.state == .queued }))

    let transferClock = ContinuousClock()
    let transferDeadline = transferClock.now.advanced(by: .seconds(2))
    while source.isTransferring, transferClock.now < transferDeadline {
      try? await Task.sleep(for: .milliseconds(10))
    }

    let completedJobs = await queue.allJobs()
    #expect(completedJobs.allSatisfy { $0.state == .completed })
    #expect(completedJobs.allSatisfy { $0.completedBytes == $0.totalBytes })
    #expect(destinationProvider.data(at: "./a.txt") == Data("A".utf8))
    #expect(destinationProvider.data(at: "./b.txt") == Data("B".utf8))
  }

  @Test("キャンセル後に両ペインの一覧が再列挙される")
  func refreshesListingsAfterCancellation() async throws {
    let transferQueue = TransferQueue.isolatedForTesting()
    let sourceProvider = MemoryStreamProvider(
      id: FileProviderID(rawValue: "source"),
      files: ["./report.txt": Data(repeating: 0x61, count: 8 * 1_024 * 1_024)])
    let destinationProvider = MemoryStreamProvider(
      id: FileProviderID(rawValue: "destination"),
      writeDelay: .milliseconds(200))
    let source = FileBrowserSession(
      provider: sourceProvider,
      initialLocation: FileLocation(remotePath: ".", providerID: sourceProvider.id),
      transferQueue: transferQueue)
    let destination = FileBrowserSession(
      provider: destinationProvider,
      initialLocation: FileLocation(remotePath: ".", providerID: destinationProvider.id),
      transferQueue: transferQueue)
    source.load()
    destination.load()
    await waitForLoading(source)
    await waitForLoading(destination)
    let item = try #require(source.items.first)

    source.copy([item], to: destination)
    #expect(source.isTransferring)
    // 転送とは無関係に、destination側で外部から内容が変わった状況を模す。
    destinationProvider.addFile("./external.txt", data: Data())
    source.cancelTransfer()
    await waitForTransfer(source)

    let refreshClock = ContinuousClock()
    let refreshDeadline = refreshClock.now.advanced(by: .seconds(2))
    while !destination.items.contains(where: { $0.name == "external.txt" }),
      refreshClock.now < refreshDeadline
    {
      try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(destination.items.map(\.name).contains("external.txt"))
  }

  @Test("複数ファイル転送の進捗はジョブ全体で単調増加し最終値が合計に一致する")
  func reportsMonotonicCumulativeProgressAcrossMultipleFiles() async throws {
    let sourceProvider = MemoryStreamProvider(
      id: FileProviderID(rawValue: "source"),
      files: [
        "./a.bin": Data(repeating: 0x61, count: 2 * 1_024 * 1_024),
        "./b.bin": Data(repeating: 0x62, count: 2 * 1_024 * 1_024),
      ])
    let destinationProvider = MemoryStreamProvider(
      id: FileProviderID(rawValue: "destination"),
      writeDelay: .milliseconds(2))
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let source = FileBrowserSession(
      provider: sourceProvider,
      initialLocation: FileLocation(remotePath: ".", providerID: sourceProvider.id),
      transferQueue: queue)
    let destination = FileBrowserSession(
      provider: destinationProvider,
      initialLocation: FileLocation(remotePath: ".", providerID: destinationProvider.id),
      transferQueue: queue)
    source.load()
    destination.load()
    await waitForLoading(source)
    await waitForLoading(destination)
    #expect(source.items.count == 2)

    source.copy(source.items, to: destination)

    var completedByteSamples: [Int64] = []
    let progressClock = ContinuousClock()
    let progressDeadline = progressClock.now.advanced(by: .seconds(2))
    while progressClock.now < progressDeadline {
      guard let job = await queue.allJobs().first else {
        try? await Task.sleep(for: .milliseconds(10))
        continue
      }
      completedByteSamples.append(job.completedBytes)
      if job.state.isTerminal { break }
      try? await Task.sleep(for: .milliseconds(10))
    }

    #expect(completedByteSamples == completedByteSamples.sorted())
    let finalJob = try #require(await queue.allJobs().first)
    // #expectはマクロ展開時に失敗メッセージ生成のため式を再評価することがあり、
    // プロパティアクセスを直接式に書くと表示上は両辺同値なのに失敗と報告される
    // ことがある(既知のTOCTOU症状)。実際の値をローカル定数へ固定してから
    // 比較することで、この二重評価による表示ずれの経路自体を排除する。
    let isTerminal = finalJob.state.isTerminal
    let totalBytes = finalJob.totalBytes
    let completedBytes = finalJob.completedBytes
    let expectedTotalBytes = Int64(4 * 1_024 * 1_024)
    #expect(isTerminal)
    #expect(totalBytes == expectedTotalBytes)
    #expect(completedBytes == totalBytes)
  }

  @Test("単一大容量ファイルは完了前に途中進捗を報告する")
  func reportsIntermediateProgressForSingleLargeFile() async throws {
    // 既定の転送チャンク1MiBを4回分通し、30msの遅延中に10ms間隔で途中進捗を観測する。
    let totalBytes = 4 * 1_024 * 1_024
    let sourceProvider = MemoryStreamProvider(
      id: FileProviderID(rawValue: "source"),
      files: ["./large.bin": Data(repeating: 0x61, count: totalBytes)])
    let destinationProvider = MemoryStreamProvider(
      id: FileProviderID(rawValue: "destination"),
      writeDelay: .milliseconds(30))
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let source = FileBrowserSession(
      provider: sourceProvider,
      initialLocation: FileLocation(remotePath: ".", providerID: sourceProvider.id),
      transferQueue: queue)
    let destination = FileBrowserSession(
      provider: destinationProvider,
      initialLocation: FileLocation(remotePath: ".", providerID: destinationProvider.id),
      transferQueue: queue)
    source.load()
    destination.load()
    await waitForLoading(source)
    await waitForLoading(destination)
    let item = try #require(source.items.first)

    source.copy([item], to: destination)

    var samples: [Int64] = []
    let progressClock = ContinuousClock()
    let progressDeadline = progressClock.now.advanced(by: .seconds(2))
    while progressClock.now < progressDeadline {
      if let job = await queue.allJobs().first {
        samples.append(job.completedBytes)
        if job.state.isTerminal { break }
      }
      try? await Task.sleep(for: .milliseconds(10))
    }

    #expect(samples.contains { $0 > 0 && $0 < totalBytes })
    #expect(try #require(await queue.allJobs().first).completedBytes == totalBytes)
  }

  @Test("失敗確定後に届くfire-and-forget進捗報告は破棄され次アイテムの進捗を汚染しない")
  func discardsStaleFireAndForgetProgressAfterItemFailure() async throws {
    // 1件目(big.bin)は進捗を1回報告した直後に書き込み失敗する。この報告はfire-and-forget
    // (Task{})で発火するため、テストはscheduleProgressReportを差し替えて発火タイミングを
    // 手動制御し、ループが2件目へ進んだ後に意図的に遅延配送することで、失敗確定後に
    // stale報告が届く状況を決定的に再現する。
    let sourceProvider = MemoryStreamProvider(
      id: FileProviderID(rawValue: "source"),
      files: [
        "./big.bin": Data(repeating: 0x62, count: 4 * 1_024 * 1_024),
        "./small.bin": Data(repeating: 0x73, count: 1 * 1_024 * 1_024),
      ])
    let destinationProvider = MemoryStreamProvider(
      id: FileProviderID(rawValue: "destination"),
      failsAfterFirstProgress: true)
    let bigItem = FileItem(
      remotePath: "./big.bin", url: URL(fileURLWithPath: "./big.bin"),
      providerID: sourceProvider.id, isDirectory: false, size: 4 * 1_024 * 1_024)
    let smallItem = FileItem(
      remotePath: "./small.bin", url: URL(fileURLWithPath: "./small.bin"),
      providerID: sourceProvider.id, isDirectory: false, size: 1 * 1_024 * 1_024)

    let pendingReports = Mutex<[@Sendable () async -> Void]>([])
    let scheduleProgressReport: @Sendable (@escaping @Sendable () async -> Void) -> Void = { work in
      pendingReports.withLock { $0.append(work) }
    }

    let execution = FileBrowserSession.makeTransferExecution(
      items: [bigItem, smallItem],
      itemSizes: [bigItem.size, smallItem.size],
      totalBytes: (bigItem.size ?? 0) + (smallItem.size ?? 0),
      sourceProvider: sourceProvider,
      destinationProvider: destinationProvider,
      destinationLocation: FileLocation(remotePath: ".", providerID: destinationProvider.id),
      removesSourceAfterCopy: false,
      replacingExisting: false,
      scheduleProgressReport: scheduleProgressReport)

    let recordedProgress = Mutex<[FileTransferProgress]>([])
    do {
      try await execution(
        { progress in recordedProgress.withLock { $0.append(progress) } },
        { _ in })
      Issue.record("big.binの書き込み失敗で部分失敗になるはずが成功した")
    } catch is TransferJobPartialFailure {
      // 想定どおりの部分失敗
    }

    // big.binの失敗直前に発火した進捗報告(4MB分)が1件、未配送のまま残っているはず。
    let stalePending = pendingReports.withLock { $0 }
    #expect(stalePending.count == 1)
    #expect(recordedProgress.withLock(\.last)?.completedBytes == smallItem.size)

    // ループが既に2件目を終えた後に、意図的に遅らせてこの報告を配送する。
    for stale in stalePending {
      await stale()
    }

    let finalProgress = recordedProgress.withLock { $0 }
    #expect(!finalProgress.contains { $0.completedBytes == bigItem.size })
    #expect(finalProgress.last?.completedBytes == smallItem.size)
  }

  @Test("クロスProvider移動で移動元削除に失敗した最上位ファイルは完了記録しない")
  func doesNotRecordCrossProviderMoveRootBeforeSourceRemovalSucceeds() async throws {
    let sourceID = FileProviderID(rawValue: "move-source")
    let destinationID = FileProviderID(rawValue: "move-destination")
    let item = FileItem(
      remotePath: "/source/report.txt",
      url: URL(string: "test://source/report.txt")!,
      providerID: sourceID,
      isDirectory: false,
      size: 6)
    let source = MemoryStreamProvider(
      id: sourceID,
      files: ["/source/report.txt": Data("report".utf8)],
      failsRemoval: true)
    let destination = MemoryStreamProvider(id: destinationID)
    let queue = TransferQueue(store: InMemoryTransferJobStore(), maximumConcurrentTransfers: 1)
    let job = TransferJob(
      kind: .move,
      items: [item],
      sourceProviderID: sourceID,
      destinationProviderID: destinationID,
      destination: FileLocation(remotePath: "/target", providerID: destinationID))
    let execution = FileBrowserSession.makeTransferExecution(
      items: [item],
      itemSizes: [item.size],
      totalBytes: item.size,
      sourceProvider: source,
      destinationProvider: destination,
      destinationLocation: job.destination,
      removesSourceAfterCopy: true,
      replacingExisting: false)

    _ = await queue.enqueue(job, execution: execution)
    let failed = try #require(await waitForJobState(.failed, jobID: job.id, in: queue))

    #expect(failed.completedItems.isEmpty)
    #expect(failed.items == [TransferJob.Item(item)])
    #expect(source.data(at: "/source/report.txt") == Data("report".utf8))
    #expect(destination.data(at: "/target/report.txt") == Data("report".utf8))
  }

  @Test("フォルダを含む転送は事前サイズ集計で決定的なtotalBytesを持つ")
  func computesDeterministicTotalBytesForDirectoryTransfer() async throws {
    let sourceRoot = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let destinationRoot = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer {
      try? FileManager.default.removeItem(at: sourceRoot)
      try? FileManager.default.removeItem(at: destinationRoot)
    }
    let subdirectory = sourceRoot.appending(path: "folder", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
    try Data(repeating: 0x41, count: 1_000).write(to: subdirectory.appending(path: "one.bin"))
    try Data(repeating: 0x42, count: 2_000).write(to: subdirectory.appending(path: "two.bin"))
    try FileManager.default.createDirectory(
      at: destinationRoot, withIntermediateDirectories: true)

    let provider = LocalFileProvider()
    let queue = TransferQueue(store: InMemoryTransferJobStore(), maximumConcurrentTransfers: 1)
    let source = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: sourceRoot, providerID: provider.id),
      transferQueue: queue)
    let destination = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: destinationRoot, providerID: provider.id),
      transferQueue: queue)
    source.load()
    destination.load()
    await waitForLoading(source)
    await waitForLoading(destination)
    let item = try #require(source.items.first)
    #expect(item.isDirectory)

    source.copy([item], to: destination)

    var job: TransferJob?
    for _ in 0..<2_000 {
      job = await queue.allJobs().first
      if job?.totalBytes != nil { break }
      await Task.yield()
    }

    #expect(job?.totalBytes == 3_000)
  }

  @Test("同一プロバイダのコピーも進捗更新を待たずにキャンセルできる")
  func cancelsSameProviderCopyBeforeFirstProgressUpdate() async throws {
    // clonefileが効く同一ボリューム同士だと単一syscallで即時完了し中断の余地がないため、
    // cloneAttemptを常に失敗させるProviderでCancellableFileCopierのチャンクフォールバック
    // 経路を強制し、キャンセルが実際にコピーへ届くことを決定的に検証する。
    let sourceRoot = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let destinationRoot = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer {
      try? FileManager.default.removeItem(at: sourceRoot)
      try? FileManager.default.removeItem(at: destinationRoot)
    }
    let bigDirectory = sourceRoot.appending(path: "bigdir", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: bigDirectory, withIntermediateDirectories: true)
    for index in 0..<200 {
      let file = bigDirectory.appending(path: "file-\(index).bin")
      try Data(repeating: 0x65, count: 256 * 1_024).write(to: file)
    }
    try FileManager.default.createDirectory(
      at: destinationRoot, withIntermediateDirectories: true)

    let provider = FallbackOnlyLocalFileProvider()
    let queue = TransferQueue(store: InMemoryTransferJobStore(), maximumConcurrentTransfers: 1)
    let source = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: sourceRoot, providerID: provider.id),
      transferQueue: queue)
    let destination = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: destinationRoot, providerID: provider.id),
      transferQueue: queue)
    source.load()
    destination.load()
    await waitForLoading(source)
    await waitForLoading(destination)
    let item = try #require(source.items.first)

    source.copy([item], to: destination)
    for _ in 0..<2_000 {
      source.cancelTransfer()
      if !source.isTransferring { break }
      await Task.yield()
    }
    await waitForTransfer(source)

    let jobs = await queue.allJobs()
    #expect(jobs.first?.state == .cancelled)
    #expect(!FileManager.default.fileExists(atPath: destinationRoot.appending(path: "bigdir").path))
  }

  @Test("即時完了する転送でも完了通知を取り逃がさない")
  func completesImmediateTransferWithoutStallingSession() async throws {
    let sourceProvider = MemoryStreamProvider(
      id: FileProviderID(rawValue: "source"),
      files: ["./report.txt": Data("即時完了".utf8)])
    let destinationProvider = MemoryStreamProvider(id: FileProviderID(rawValue: "destination"))
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let source = FileBrowserSession(
      provider: sourceProvider,
      initialLocation: FileLocation(remotePath: ".", providerID: sourceProvider.id),
      transferQueue: queue)
    let destination = FileBrowserSession(
      provider: destinationProvider,
      initialLocation: FileLocation(remotePath: ".", providerID: destinationProvider.id),
      transferQueue: queue)

    source.load()
    destination.load()
    await waitForLoading(source)
    await waitForLoading(destination)
    let item = try #require(source.items.first)

    source.copy([item], to: destination)
    await waitForTransfer(source)

    #expect(!source.isTransferring)
    #expect(!destination.isTransferring)
    #expect(source.errorMessage == nil)
    #expect(destinationProvider.data(at: "./report.txt") == Data("即時完了".utf8))
  }

  @Test("同一Provider内コピーの検証失敗は転送先の破損ファイルを残さず再試行できる")
  func removesCorruptedDestinationFileWhenSameProviderCopyFailsVerification() async throws {
    let provider = TruncatingSameProviderProvider(
      id: FileProviderID(rawValue: "same-provider-truncation"),
      files: ["./src/report.txt": Data(repeating: 0x41, count: 1_000)],
      truncatesCopiedBytesBy: 100)
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let source = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: "./src", providerID: provider.id),
      transferQueue: queue)
    let destination = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: "./dst", providerID: provider.id),
      transferQueue: queue)
    source.load()
    destination.load()
    await waitForLoading(source)
    await waitForLoading(destination)
    let item = try #require(source.items.first)

    source.copy([item], to: destination)
    await waitForTransfer(source)

    let job = try #require(await queue.allJobs().first)
    #expect(job.state == .failed)
    #expect(source.canRetryLastTransfer)
    #expect(provider.data(at: "./dst/report.txt") == nil)
    #expect(provider.removedPaths().contains("./dst/report.txt"))

    // 破損ファイルが残っていれば次のretryはreplacingExisting: falseで「既に存在する」
    // 失敗に固定されてしまう。除去済みなら同じサイズ検証失敗に戻ることを確認する。
    source.retryLastTransfer()
    await waitForTransfer(source)
    let retriedJob = try #require(await queue.allJobs().first)
    #expect(retriedJob.state == .failed)
    #expect(retriedJob.errorDescription?.contains("900") == true)
  }

  @Test("宛先への書き込みが切り詰められた転送は検証失敗として再試行可能になる")
  func failsRetryableWhenDestinationWriteIsTruncated() async throws {
    let content = Data(repeating: 0x63, count: 1_000)
    let sourceProvider = MemoryStreamProvider(
      id: FileProviderID(rawValue: "source-truncation"),
      files: ["./report.txt": content])
    let destinationProvider = MemoryStreamProvider(
      id: FileProviderID(rawValue: "destination-truncation"),
      truncatesPersistedBytesBy: 100)
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let source = FileBrowserSession(
      provider: sourceProvider,
      initialLocation: FileLocation(remotePath: ".", providerID: sourceProvider.id),
      transferQueue: queue)
    let destination = FileBrowserSession(
      provider: destinationProvider,
      initialLocation: FileLocation(remotePath: ".", providerID: destinationProvider.id),
      transferQueue: queue)
    source.load()
    destination.load()
    await waitForLoading(source)
    await waitForLoading(destination)
    let item = try #require(source.items.first)

    source.copy([item], to: destination)
    await waitForTransfer(source)

    let job = try #require(await queue.allJobs().first)
    #expect(job.state == .failed)
    #expect(job.errorDescription?.contains("900") == true)
    #expect(job.errorDescription?.contains("1000") == true)
    #expect(source.canRetryLastTransfer)
  }

  @Test("2番目の項目で中断しても、リトライで完了済みの1番目は再送されず未着手の2・3番目だけが転送される")
  func resumeSkipsOnlyConfirmedCompletedItemsAfterInterruption() async throws {
    let provider = ResumeTrackingProvider(
      id: FileProviderID(rawValue: "resume-provider"),
      files: [
        "./src/a.bin": Data(repeating: 0x61, count: 100),
        "./src/b.bin": Data(repeating: 0x62, count: 200),
        "./src/c.bin": Data(repeating: 0x63, count: 300),
      ],
      cancelsOnItemNamed: "b.bin")
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let source = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: "./src", providerID: provider.id),
      transferQueue: queue)
    let destination = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: "./dst", providerID: provider.id),
      transferQueue: queue)
    source.load()
    destination.load()
    await waitForLoading(source)
    await waitForLoading(destination)
    #expect(source.items.map(\.name) == ["a.bin", "b.bin", "c.bin"])

    source.copy(source.items, to: destination)
    await waitForTransfer(source)

    // b.binでCancellationErrorが飛ぶとmakeTransferExecutionのループ自体が即座に
    // 中断されるため、c.binには一度も手を付けていないはず(実際のstall guard/
    // app crash相当の中断を模す)。
    #expect(await queue.allJobs().first?.state == .cancelled)
    #expect(provider.copyCallCount(for: "a.bin") == 1)
    #expect(provider.copyCallCount(for: "b.bin") == 1)
    #expect(provider.copyCallCount(for: "c.bin") == 0)
    #expect(provider.data(at: "./dst/a.bin") != nil)
    #expect(source.canRetryLastTransfer)

    source.retryLastTransfer()
    await waitForTransfer(source)

    let retriedJob = try #require(await queue.allJobs().first)
    #expect(retriedJob.state == .completed)
    #expect(provider.copyCallCount(for: "a.bin") == 1)  // 検証済みなので再送されない
    #expect(provider.copyCallCount(for: "b.bin") == 2)  // 未完了だったので再試行される
    #expect(provider.copyCallCount(for: "c.bin") == 1)  // 未着手だったので今回転送される
    #expect(provider.data(at: "./dst/b.bin") != nil)
    #expect(provider.data(at: "./dst/c.bin") != nil)
    // 進捗の単調性・二重加算なし: 完了時点の完了バイト数は3ファイル合計と一致する。
    #expect(retriedJob.completedBytes == 600)
    #expect(retriedJob.totalBytes == 600)
  }

  @Test("3項目中1項目の完了後に一時停止すると再開時は残り2項目だけを転送する")
  func resumePausedTransferSkipsConfirmedCompletedItem() async throws {
    let provider = ResumeTrackingProvider(
      id: FileProviderID(rawValue: "pause-resume-provider"),
      files: [
        "./src/a.bin": Data(repeating: 0x61, count: 100),
        "./src/b.bin": Data(repeating: 0x62, count: 200),
        "./src/c.bin": Data(repeating: 0x63, count: 300),
      ],
      delaysCopyForItemNamed: "b.bin")
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let source = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: "./src", providerID: provider.id),
      transferQueue: queue)
    let destination = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: "./dst", providerID: provider.id),
      transferQueue: queue)
    source.load()
    destination.load()
    await waitForLoading(source)
    await waitForLoading(destination)

    source.copy(source.items, to: destination)
    await waitForCopyCall(named: "b.bin", count: 1, provider: provider)
    #expect(provider.copyCallCount(for: "b.bin") == 1)
    let jobID = try #require(await queue.allJobs().first?.id)
    await queue.pause(jobID)
    let paused = try #require(await waitForJobState(.paused, jobID: jobID, in: queue))

    #expect(paused.completedItems.map(\.name) == ["a.bin"])
    #expect(provider.copyCallCount(for: "a.bin") == 1)
    #expect(provider.copyCallCount(for: "b.bin") == 1)
    #expect(provider.copyCallCount(for: "c.bin") == 0)

    provider.allowDelayedCopiesToProceed()
    #expect(source.resumeTransfer(jobID))
    await waitForTransfer(source)

    let completed = try #require(await queue.allJobs().first)
    #expect(completed.state == .completed)
    #expect(provider.copyCallCount(for: "a.bin") == 1)
    #expect(provider.copyCallCount(for: "b.bin") == 2)
    #expect(provider.copyCallCount(for: "c.bin") == 1)
    #expect(provider.data(at: "./dst/a.bin") == Data(repeating: 0x61, count: 100))
    #expect(provider.data(at: "./dst/b.bin") == Data(repeating: 0x62, count: 200))
    #expect(provider.data(at: "./dst/c.bin") == Data(repeating: 0x63, count: 300))
  }

  @Test("一時停止中に宛先が変わった場合は完了記録を使わず全項目を再転送する")
  func resumePausedTransferRetransfersEverythingWhenDestinationChanged() async throws {
    let provider = ResumeTrackingProvider(
      id: FileProviderID(rawValue: "pause-resume-destination-changed"),
      files: [
        "./src/a.bin": Data(repeating: 0x61, count: 100),
        "./src/b.bin": Data(repeating: 0x62, count: 200),
        "./src/c.bin": Data(repeating: 0x63, count: 300),
        "./dst2/a.bin": Data(repeating: 0x00, count: 100),
      ],
      delaysCopyForItemNamed: "b.bin")
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let source = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: "./src", providerID: provider.id),
      transferQueue: queue)
    let destination = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: "./dst", providerID: provider.id),
      transferQueue: queue)
    source.load()
    destination.load()
    await waitForLoading(source)
    await waitForLoading(destination)

    source.copy(source.items, to: destination)
    await waitForCopyCall(named: "b.bin", count: 1, provider: provider)
    #expect(provider.copyCallCount(for: "b.bin") == 1)
    let jobID = try #require(await queue.allJobs().first?.id)
    await queue.pause(jobID)
    _ = try #require(await waitForJobState(.paused, jobID: jobID, in: queue))
    destination.load(location: FileLocation(remotePath: "./dst2", providerID: provider.id))
    await waitForLoading(destination)

    provider.allowDelayedCopiesToProceed()
    #expect(source.resumeTransfer(jobID))
    await waitForTransfer(source)

    #expect(provider.copyCallCount(for: "a.bin") == 2)
    #expect(provider.copyCallCount(for: "b.bin") == 2)
    #expect(provider.copyCallCount(for: "c.bin") == 1)
    #expect(provider.data(at: "./dst2/a.bin") == Data(repeating: 0x61, count: 100))
    #expect(await queue.allJobs().first?.state == .completed)
  }

  @Test("クロスProviderのフォルダ再開は既存ツリーを再利用し完了済みリーフを再送しない")
  func resumesCrossProviderDirectoryWithoutCreatingDuplicateDirectory() async throws {
    let sourceProvider = CrossProviderResumeTreeProvider(
      id: FileProviderID(rawValue: "tree-resume-source"),
      directories: ["/source", "/source/myfolder"],
      files: [
        "/source/myfolder/a.bin": Data(repeating: 0x61, count: 100),
        "/source/myfolder/b.bin": Data(repeating: 0x62, count: 200),
      ])
    let destinationProvider = CrossProviderResumeTreeProvider(
      id: FileProviderID(rawValue: "tree-resume-destination"),
      directories: ["/target"],
      delayedWriteName: "b.bin")
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let source = FileBrowserSession(
      provider: sourceProvider,
      initialLocation: FileLocation(remotePath: "/source", providerID: sourceProvider.id),
      transferQueue: queue)
    let destination = FileBrowserSession(
      provider: destinationProvider,
      initialLocation: FileLocation(
        remotePath: "/target", providerID: destinationProvider.id),
      transferQueue: queue)
    source.load()
    destination.load()
    await waitForLoading(source)
    await waitForLoading(destination)
    let folder = try #require(source.items.first(where: { $0.name == "myfolder" }))

    source.copy([folder], to: destination)
    await waitUntil {
      destinationProvider.writeAttemptCount(for: "b.bin") == 1
    }
    let jobID = try #require(await queue.allJobs().first?.id)
    await queue.pause(jobID)
    let paused = try #require(await waitForJobState(.paused, jobID: jobID, in: queue))

    #expect(!source.isTransferring)
    #expect(!destination.isTransferring)
    #expect(
      paused.completedItems.map(\.location) == [
        FileLocation(remotePath: "/source/myfolder/a.bin", providerID: sourceProvider.id)
      ])
    #expect(paused.completedBytes == 100)
    #expect(
      destinationProvider.data(at: "/target/myfolder/a.bin")
        == Data(repeating: 0x61, count: 100))
    #expect(destinationProvider.data(at: "/target/myfolder/b.bin") == nil)
    destinationProvider.putFile(
      at: "/target/myfolder/b.bin", data: Data(repeating: 0x00, count: 7))
    var unrelatedFailure = TransferJob(
      kind: .copy,
      items: [folder],
      sourceProviderID: sourceProvider.id,
      destinationProviderID: destinationProvider.id,
      destination: destination.currentLocation)
    unrelatedFailure.state = .failed
    #expect(source.prepareTransferRetry(unrelatedFailure, to: destination))
    #expect(source.canRetryLastTransfer)

    destinationProvider.allowDelayedWritesToProceed()
    #expect(source.resumeTransfer(jobID))
    await waitForTransfer(source)

    let completed = try #require(await queue.allJobs().first(where: { $0.id == jobID }))
    #expect(completed.state == .completed)
    #expect(completed.completedBytes == 300)
    #expect(completed.totalBytes == 300)
    #expect(sourceProvider.readCount(for: "a.bin") == 1)
    #expect(sourceProvider.readCount(for: "b.bin") == 2)
    #expect(destinationProvider.createdDirectoryPaths() == ["/target/myfolder"])
    #expect(!destinationProvider.containsDirectory(at: "/target/myfolder 2"))
    #expect(destinationProvider.replacementCommitCount() == 1)
    #expect(source.canRetryLastTransfer)
    #expect(
      destinationProvider.data(at: "/target/myfolder/b.bin")
        == Data(repeating: 0x62, count: 200))
  }

  @Test("スキップ判定は安全側: 完了記録があっても宛先ファイルが消えていれば再転送する")
  func retransfersWhenDestinationFileIsMissingDespiteCompletionRecord() async throws {
    let provider = ResumeTrackingProvider(
      id: FileProviderID(rawValue: "resume-missing-destination"),
      files: [
        "./src/a.bin": Data(repeating: 0x61, count: 100),
        "./src/b.bin": Data(repeating: 0x62, count: 200),
      ],
      cancelsOnItemNamed: "b.bin")
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let source = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: "./src", providerID: provider.id),
      transferQueue: queue)
    let destination = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: "./dst", providerID: provider.id),
      transferQueue: queue)
    source.load()
    destination.load()
    await waitForLoading(source)
    await waitForLoading(destination)

    source.copy(source.items, to: destination)
    await waitForTransfer(source)
    #expect(await queue.allJobs().first?.state == .cancelled)
    #expect(provider.data(at: "./dst/a.bin") != nil)

    // 外部要因で転送先の完了ファイルが消えた状況を模す。
    provider.removeFile(at: "./dst/a.bin")

    source.retryLastTransfer()
    await waitForTransfer(source)

    #expect(provider.copyCallCount(for: "a.bin") == 2)  // 安全側に倒して再転送する
    #expect(provider.data(at: "./dst/a.bin") != nil)
    #expect(await queue.allJobs().first?.state == .completed)
  }

  @Test("中断後に宛先ペインを別フォルダへ移動してからリトライすると完了記録を無視して全件転送する")
  func retransfersEverythingWhenDestinationChangedBeforeRetry() async throws {
    let provider = ResumeTrackingProvider(
      id: FileProviderID(rawValue: "resume-destination-changed"),
      files: [
        "./src/a.bin": Data(repeating: 0x61, count: 100),
        "./src/b.bin": Data(repeating: 0x62, count: 200),
        // 別フォルダにたまたま同名同サイズのファイルがある状況を模す。
        "./dst2/a.bin": Data(repeating: 0x00, count: 100),
      ],
      cancelsOnItemNamed: "b.bin")
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let source = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: "./src", providerID: provider.id),
      transferQueue: queue)
    let destination = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: "./dst", providerID: provider.id),
      transferQueue: queue)
    source.load()
    destination.load()
    await waitForLoading(source)
    await waitForLoading(destination)

    source.copy(source.items, to: destination)
    await waitForTransfer(source)
    #expect(await queue.allJobs().first?.state == .cancelled)
    #expect(provider.copyCallCount(for: "a.bin") == 1)

    // 宛先ペインを、たまたま同名同サイズのファイルがある別フォルダへ移動してからリトライする。
    destination.load(location: FileLocation(remotePath: "./dst2", providerID: provider.id))
    await waitForLoading(destination)

    source.retryLastTransfer()
    await waitForTransfer(source)

    // 旧宛先(./dst)でのa.bin完了記録は今回の宛先(./dst2)にとって無意味なので無視され、
    // a.binも再転送されるはず。
    #expect(provider.copyCallCount(for: "a.bin") == 2)
    #expect(provider.copyCallCount(for: "b.bin") == 2)
    #expect(await queue.allJobs().first?.state == .completed)
  }

  @Test("再起動で復元したジョブのシンボリックリンク項目も、リトライでサイズ検証をスキップする")
  func resumedSymbolicLinkItemSkipsSizeVerificationAfterRestore() async throws {
    let provider = ResumeTrackingProvider(
      id: FileProviderID(rawValue: "resume-symlink"),
      files: ["./src/link": Data(count: 5)])
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let source = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: "./src", providerID: provider.id),
      transferQueue: queue)
    let destination = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: "./dst", providerID: provider.id),
      transferQueue: queue)
    destination.load()
    await waitForLoading(destination)

    // sourceの申告サイズ(999)は実際のコピー結果(5バイト)とわざと食い違わせている。
    // シンボリックリンクとして正しくスキップされなければ、この不一致で検証失敗するはず。
    let symlinkItem = FileItem(
      remotePath: "./src/link",
      url: URL(fileURLWithPath: "./src/link"),
      providerID: provider.id,
      isDirectory: false,
      isSymbolicLink: true,
      size: 999)
    let job = TransferJob(
      kind: .copy,
      items: [symlinkItem],
      sourceProviderID: provider.id,
      destinationProviderID: provider.id,
      destination: FileLocation(remotePath: "./dst", providerID: provider.id))
    #expect(job.items.first?.isSymbolicLink == true)

    _ = await queue.enqueue(job) { _, _ in throw CocoaError(.fileWriteUnknown) }
    // yieldのみのポーリングはフルスイート実行時のCPU逼迫下で実時間をほぼ稼げず、状態遷移
    // 未完了のままタイムアウトしてしまうことがあるため、短いsleepを挟んで実時間を確保する
    // (他の転送系テストと同型のwaitForState方式)。
    var failedJob: TransferJob?
    for _ in 0..<20 {
      failedJob = await queue.allJobs().first(where: { $0.id == job.id })
      if failedJob?.state == .failed { break }
      await Task.yield()
    }
    if failedJob?.state != .failed {
      let failureClock = ContinuousClock()
      let failureDeadline = failureClock.now.advanced(by: .seconds(2))
      while failureClock.now < failureDeadline {
        failedJob = await queue.allJobs().first(where: { $0.id == job.id })
        if failedJob?.state == .failed { break }
        try? await Task.sleep(for: .milliseconds(10))
      }
    }
    let requiredFailedJob = try #require(failedJob)
    #expect(requiredFailedJob.state == .failed)

    // prepareTransferRetryがjob.items.map(\.fileItem)でFileItemを再構成する経路を通す。
    #expect(source.prepareTransferRetry(requiredFailedJob, to: destination))
    source.retryLastTransfer()
    let retryState = await waitForStableJobState(in: queue)

    #expect(retryState == .completed)
    #expect(provider.data(at: "./dst/link") != nil)
  }

  @Test("接続断相当のエラーでジョブが失敗しても自動リトライで完走する(P1-2の完了済みスキップ併用)")
  func autoReconnectCompletesTransferAfterSimulatedConnectionDrop() async throws {
    let provider = ResumeTrackingProvider(
      id: FileProviderID(rawValue: "auto-reconnect-success"),
      files: [
        "./src/a.bin": Data(repeating: 0x61, count: 100),
        "./src/b.bin": Data(repeating: 0x62, count: 200),
        "./src/c.bin": Data(repeating: 0x63, count: 300),
      ],
      // b.bin/c.binは1回目の呼び出しだけ接続断相当のエラーで失敗し、2回目は成功する
      // (自動リトライで接続が回復した状況を模す)。
      connectionDropItemsNamed: ["b.bin", "c.bin"],
      connectionDropFailureLimit: 1)
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let source = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: "./src", providerID: provider.id),
      transferQueue: queue,
      autoReconnectBackoff: [.milliseconds(1), .milliseconds(1), .milliseconds(1)])
    let destination = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: "./dst", providerID: provider.id),
      transferQueue: queue,
      autoReconnectBackoff: [.milliseconds(1), .milliseconds(1), .milliseconds(1)])
    source.load()
    destination.load()
    await waitForLoading(source)
    await waitForLoading(destination)

    // ユーザー操作は最初のcopy呼び出しのみ。以降は何もしない。
    source.copy(source.items, to: destination)
    let state = await waitForStableJobState(in: queue)

    #expect(state == .completed)
    #expect(provider.copyCallCount(for: "a.bin") == 1)
    #expect(provider.copyCallCount(for: "b.bin") == 2)
    #expect(provider.copyCallCount(for: "c.bin") == 2)
    #expect(provider.data(at: "./dst/a.bin") != nil)
    #expect(provider.data(at: "./dst/b.bin") != nil)
    #expect(provider.data(at: "./dst/c.bin") != nil)
  }

  @Test("自動リトライを3回使い切ってもfailedのまま留まり、手動リトライは引き続き可能")
  func fallsBackToManualRetryAfterExhaustingAutomaticAttempts() async throws {
    let provider = ResumeTrackingProvider(
      id: FileProviderID(rawValue: "auto-reconnect-exhaust"),
      files: ["./src/a.bin": Data(repeating: 0x61, count: 100)],
      // 上限を大きく超える回数まで失敗させ続け、「回復しない接続断」を模す。
      connectionDropItemsNamed: ["a.bin"],
      connectionDropFailureLimit: 100)
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let source = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: "./src", providerID: provider.id),
      transferQueue: queue,
      autoReconnectBackoff: [.milliseconds(1), .milliseconds(1), .milliseconds(1)])
    let destination = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: "./dst", providerID: provider.id),
      transferQueue: queue,
      autoReconnectBackoff: [.milliseconds(1), .milliseconds(1), .milliseconds(1)])
    source.load()
    destination.load()
    await waitForLoading(source)
    await waitForLoading(destination)

    source.copy(source.items, to: destination)
    let state = await waitForStableJobState(in: queue)

    #expect(state == .failed)
    // 最初の実行1回 + 自動リトライ既定3回 = 4回試行されているはず。
    #expect(provider.copyCallCount(for: "a.bin") == 4)
    #expect(source.canRetryLastTransfer)

    // 自動分を使い切った後も、手動retryLastTransferは従来どおり呼べて実際に試行する。
    // 手動リトライも自動再接続の母体(makeAutoRetryPlanner)を再登録するため、これも
    // 失敗すればまた自動で3回分バックオフ・再試行してから最終的にfailedへ確定する
    // (5回目の手動分+自動3回=合計8回)。isTransferringはこの間trueのままなので、
    // waitForTransferではなくwaitForStableJobStateで終端状態の確定を待つ。
    source.retryLastTransfer()
    let retriedState = await waitForStableJobState(in: queue)
    #expect(retriedState == .failed)
    #expect(provider.copyCallCount(for: "a.bin") == 8)
  }

  @Test("ユーザーが明示キャンセルすると自動リトライは走らず、進行中の転送も即座に止まる")
  func cancellationStopsAutomaticReconnect() async throws {
    let provider = ResumeTrackingProvider(
      id: FileProviderID(rawValue: "auto-reconnect-cancel"),
      files: ["./src/a.bin": Data(repeating: 0x61, count: 100)],
      delaysCopyForItemNamed: "a.bin")
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let source = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: "./src", providerID: provider.id),
      transferQueue: queue,
      autoReconnectBackoff: [.milliseconds(1), .milliseconds(1), .milliseconds(1)])
    let destination = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: "./dst", providerID: provider.id),
      transferQueue: queue,
      autoReconnectBackoff: [.milliseconds(1), .milliseconds(1), .milliseconds(1)])
    source.load()
    destination.load()
    await waitForLoading(source)
    await waitForLoading(destination)

    source.copy(source.items, to: destination)
    // a.binのTask.sleep(30秒)内で止まっている間にキャンセルする。job.state==.runningへの
    // 遷移はcopy()呼び出しより先にpublishされうるため、実際にcopy()へ到達した
    // (=呼び出し回数が増えた)ことを確認してからキャンセルする。
    for _ in 0..<200 {
      if provider.copyCallCount(for: "a.bin") >= 1 { break }
      await Task.yield()
    }
    source.cancelTransfer()

    let state = await waitForStableJobState(in: queue)

    #expect(state == .cancelled)
    // CancellationErrorはTransferQueueが必ず.cancelledとして扱うため、自動リトライの
    // .failed分岐自体に到達しない。1回だけ試行され、それ以上は増えない。
    #expect(provider.copyCallCount(for: "a.bin") == 1)
  }

  @Test("NASのゴミ箱が使えない削除は完全削除の確認待ちにする")
  func asksForConfirmationBeforePermanentlyDeletingWithoutTrash() async throws {
    let provider = TrashUnavailableProvider()
    let session = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: ".", providerID: provider.id),
      transferQueue: .isolatedForTesting())

    session.load()
    await waitForLoading(session)
    let item = try #require(session.items.first)

    session.delete(item)
    await waitForLoading(session)

    #expect(session.pendingPermanentDeleteItems.map(\.name) == ["report.txt"])
    #expect(!provider.wasPermanentlyDeleted)

    session.confirmPermanentDelete()
    session.confirmPermanentDelete()
    await waitForLoading(session)

    #expect(session.pendingPermanentDeleteItems.isEmpty)
    #expect(provider.wasPermanentlyDeleted)
    #expect(provider.permanentDeleteCount == 1)
    #expect(session.items.isEmpty)
  }

  @Test("選択項目を同一フォルダへ複製し一覧へ反映する")
  func duplicatesSelectedItemsAndRefreshesListing() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let sourceURL = root.appending(path: "report.txt")
    FileManager.default.createFile(atPath: sourceURL.path, contents: Data("内容".utf8))
    let provider = LocalFileProvider()
    let session = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: root),
      transferQueue: .isolatedForTesting())

    session.load()
    // 実I/Oを伴う操作なのでyieldのみのwaitForLoadingではなく、実時間を確保する
    // waitUntilで完了を待つ(waitForTransferと同じ理由。上のコメント参照)。
    await waitUntil { !session.isLoading }
    let item = try #require(session.items.first { $0.name == "report.txt" })

    session.duplicate([item])
    await waitUntil { !session.isLoading }

    let duplicatedURL = root.appending(path: "reportのコピー.txt")
    #expect(FileManager.default.fileExists(atPath: duplicatedURL.path))
    #expect(session.items.map(\.name).sorted() == ["report.txt", "reportのコピー.txt"])
    #expect(session.errorMessage == nil)
  }

  @Test("複製をサポートしないProviderではエラーを表示する")
  func duplicateReportsErrorWhenProviderDoesNotSupportIt() async throws {
    let provider = TrashUnavailableProvider()
    let session = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: ".", providerID: provider.id),
      transferQueue: .isolatedForTesting())

    session.load()
    await waitForLoading(session)
    let item = try #require(session.items.first)

    session.duplicate([item])
    await waitUntil { session.errorMessage != nil }

    #expect(session.errorMessage == "この接続では複製を利用できません。")
  }

  @Test("逐次一覧は最初の項目を受け取った時点で操作可能にする")
  func makesIncrementalListingInteractiveAfterFirstBatch() async throws {
    let provider = PartialListingProvider()
    let session = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: ".", providerID: provider.id),
      transferQueue: .isolatedForTesting())

    session.load()
    for _ in 0..<50 where session.items.isEmpty {
      await Task.yield()
    }

    #expect(session.items.map(\.name) == ["first.txt"])
    #expect(!session.isLoading)
    #expect(session.isRefreshing)
    session.invalidate()
  }

  @Test("一覧の欠落メタデータを詳細取得で後追い補完する")
  func enrichesMissingListingMetadata() async throws {
    let provider = MetadataEnrichmentProvider(
      id: FileProviderID(rawValue: "metadata-enrichment"),
      initialItems: [
        ".": [
          MetadataEnrichmentProvider.Item(path: "./report.txt", size: nil, modifiedAt: nil),
          MetadataEnrichmentProvider.Item(
            path: "./folder",
            isDirectory: true,
            size: nil,
            modifiedAt: nil),
        ]
      ])
    let session = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: ".", providerID: provider.id),
      transferQueue: .isolatedForTesting())

    session.load()
    await waitForLoading(session)
    await waitUntil {
      session.items.allSatisfy { $0.modifiedAt != nil && ($0.isDirectory || $0.size != nil) }
    }

    #expect(session.items.first(where: { $0.name == "report.txt" })?.size == 1_024)
    #expect(session.items.first(where: { $0.name == "folder" })?.modifiedAt != nil)
    #expect(provider.detailedItemCallCount == 2)
  }

  @Test("場所移動後に古い一覧のメタデータ補完を反映しない")
  func discardsMetadataEnrichmentAfterNavigating() async throws {
    let provider = MetadataEnrichmentProvider(
      id: FileProviderID(rawValue: "metadata-navigation"),
      initialItems: [
        ".": [MetadataEnrichmentProvider.Item(path: "./old.txt", size: nil, modifiedAt: nil)],
        "./next": [
          MetadataEnrichmentProvider.Item(path: "./next/current.txt", size: 512, modifiedAt: .now)
        ],
      ],
      detailDelay: .seconds(1))
    let root = FileLocation(remotePath: ".", providerID: provider.id)
    let next = FileLocation(remotePath: "./next", providerID: provider.id)
    let session = FileBrowserSession(
      provider: provider, initialLocation: root, transferQueue: .isolatedForTesting())

    session.load()
    await waitForLoading(session)
    await waitUntil { provider.detailedItemCallCount == 1 }
    session.open(location: next)
    await waitForLoading(session)
    try? await Task.sleep(for: .milliseconds(50))

    #expect(session.currentLocation == next)
    #expect(session.items.map(\.name) == ["current.txt"])
    #expect(session.items.allSatisfy { $0.size != nil && $0.modifiedAt != nil })
  }

  @Test("一覧が最初から完全なら詳細メタデータを取得しない")
  func skipsMetadataEnrichmentForCompleteListing() async throws {
    let provider = MetadataEnrichmentProvider(
      id: FileProviderID(rawValue: "complete-metadata"),
      initialItems: [
        ".": [MetadataEnrichmentProvider.Item(path: "./report.txt", size: 42, modifiedAt: .now)]
      ])
    let session = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: ".", providerID: provider.id),
      transferQueue: .isolatedForTesting())

    session.load()
    await waitForLoading(session)
    await Task.yield()

    #expect(provider.detailedItemCallCount == 0)
  }

  @Test("大量一覧のメタデータ補完は初期表示を待たせず並行数を制限する")
  func enrichesLargeListingWithoutBlockingInitialDisplay() async throws {
    let items = (0..<1_000).map {
      MetadataEnrichmentProvider.Item(path: "./item-\($0).txt", size: nil, modifiedAt: nil)
    }
    let provider = MetadataEnrichmentProvider(
      id: FileProviderID(rawValue: "large-metadata"),
      initialItems: [".": items],
      detailDelay: .seconds(1))
    let session = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: ".", providerID: provider.id),
      transferQueue: .isolatedForTesting())

    session.load()
    await waitUntil(timeout: .seconds(10)) {
      session.items.count == 1_000 && !session.isLoading
    }
    #expect(session.items.count == 1_000)
    #expect(!session.isLoading)
    await waitUntil(timeout: .seconds(10)) {
      provider.maximumConcurrentDetailRequests > 0
    }

    #expect(provider.maximumConcurrentDetailRequests <= 6)
    session.invalidate()
  }

  private func waitForLoading(_ session: FileBrowserSession) async {
    await PKPaneTests.waitUntil("isLoadingが期限内にfalseにならなかった") {
      !session.isLoading
    }
  }

  private func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: @escaping @MainActor () -> Bool
  ) async {
    await PKPaneTests.waitUntil(timeout: timeout, "セッションの状態が期限内に条件を満たさなかった") {
      condition()
    }
  }

  /// 転送UI一元化(Task 3)でstartTransferがisLoadingを立てなくなったため、転送の完了/
  /// キャンセル待ちにはisTransferringを見る専用のヘルパーを使う。
  /// yieldだけのポーリングはフルスイート実行時のCPU逼迫下で実時間をほぼ稼げず、
  /// 転送未完了のままアサーションへ進んでしまうため、短いsleepを挟んで実時間を確保する。
  private func waitForTransfer(_ session: FileBrowserSession) async {
    for _ in 0..<20 {
      if !session.isTransferring { break }
      await Task.yield()
    }
    if session.isTransferring {
      await PKPaneTests.waitUntil("転送(isTransferring)が期限内に完了しなかった") {
        !session.isTransferring
      }
    }
    // isTransferringはreceiveTransferUpdates内でfinishActiveTransfer(即時)により
    // falseになるが、その後に起動される後処理Task(refreshContents等)の完了は待たない
    // 設計のため、isTransferring==false直後はまだ後処理が終わっていないことがある。
    // 後処理が実際に走る猶予を与えるため、短いsleepを1回挟む。
    try? await Task.sleep(for: .milliseconds(20))
  }

  private func waitForJobState(
    _ state: TransferJob.State,
    jobID: UUID,
    in queue: TransferQueue
  ) async -> TransferJob? {
    var result: TransferJob?
    await PKPaneTests.waitUntil("ジョブが期限内に指定状態にならなかった") {
      guard let job = await queue.allJobs().first(where: { $0.id == jobID }), job.state == state
      else {
        return false
      }
      result = job
      return true
    }
    return result
  }

  private func waitForCopyCall(
    named name: String,
    count: Int,
    provider: ResumeTrackingProvider
  ) async {
    await PKPaneTests.waitUntil("コピー呼び出し回数が期限内に期待値に達しなかった") {
      provider.copyCallCount(for: name) >= count
    }
  }

  /// 自動再接続(P1-3)はfailed→(バックオフ)→running→...と状態を行き来しうるため、
  /// isTransferringの単純な監視だけでは「自動リトライの合間で一瞬falseに戻った」
  /// タイミングを最終状態と誤認しうる。終端状態(isTerminal)が一定回数連続するまで
  /// 待つことで、自動リトライが完全に収束するのを確実に待つ。
  private func waitForStableJobState(in queue: TransferQueue) async -> TransferJob.State? {
    var lastState: TransferJob.State?
    var stableCount = 0
    await PKPaneTests.waitUntil("ジョブ状態が期限内に安定しなかった") {
      let state = await queue.allJobs().first?.state
      if state == lastState, state?.isTerminal == true {
        stableCount += 1
        if stableCount >= 10 { return true }
      } else {
        stableCount = 0
      }
      lastState = state
      return false
    }
    return lastState
  }

}

private final class PartialListingProvider: FileBrowserStreamingProvider, @unchecked Sendable {
  let id = FileProviderID(rawValue: "partial-listing")
  let connectionID: FileProviderConnectionID? = nil
  let capabilities: FileProviderCapabilities = [.read]

  func contents(of _: FileLocation) async throws -> [FileItem] { [] }

  func parent(of _: FileLocation) -> FileLocation? { nil }

  func breadcrumbs(
    for _: FileLocation,
    constrainedTo _: FileLocation?
  ) -> [FileBrowserBreadcrumb] { [] }

  func contentsStream(
    of _: FileLocation,
    includingHidden _: Bool,
    batchSize _: Int
  ) -> AsyncThrowingStream<[FileItem], Error> {
    let item = FileItem(
      remotePath: "./first.txt",
      url: URL(fileURLWithPath: "/first.txt"),
      providerID: id,
      isDirectory: false)
    return AsyncThrowingStream { continuation in
      let task = Task {
        continuation.yield([item])
        try? await Task.sleep(for: .seconds(10))
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

private final class MetadataEnrichmentProvider: FileBrowserStreamingProvider,
  FileBrowserItemDetailProvider,
  @unchecked Sendable
{
  struct Item: Sendable {
    let path: String
    let isDirectory: Bool
    let size: Int64?
    let modifiedAt: Date?

    init(path: String, isDirectory: Bool = false, size: Int64?, modifiedAt: Date?) {
      self.path = path
      self.isDirectory = isDirectory
      self.size = size
      self.modifiedAt = modifiedAt
    }
  }

  let id: FileProviderID
  let connectionID: FileProviderConnectionID? = nil
  let capabilities: FileProviderCapabilities = [.read]

  private let itemsByDirectory: [String: [Item]]
  private let detailDelay: Duration?
  private let lock = NSLock()
  private var detailCallCount = 0
  private var activeDetailRequests = 0
  private var observedMaximumConcurrentDetailRequests = 0

  init(id: FileProviderID, initialItems: [String: [Item]], detailDelay: Duration? = nil) {
    self.id = id
    itemsByDirectory = initialItems
    self.detailDelay = detailDelay
  }

  var detailedItemCallCount: Int {
    lock.withLock { detailCallCount }
  }

  var maximumConcurrentDetailRequests: Int {
    lock.withLock { observedMaximumConcurrentDetailRequests }
  }

  func contents(of location: FileLocation) async throws -> [FileItem] {
    items(at: location, fillsMetadata: false)
  }

  func parent(of _: FileLocation) -> FileLocation? { nil }

  func breadcrumbs(
    for _: FileLocation,
    constrainedTo _: FileLocation?
  ) -> [FileBrowserBreadcrumb] { [] }

  func contentsStream(
    of location: FileLocation,
    includingHidden _: Bool,
    batchSize _: Int
  ) -> AsyncThrowingStream<[FileItem], Error> {
    let items = items(at: location, fillsMetadata: false)
    return AsyncThrowingStream { continuation in
      continuation.yield(items)
      continuation.finish()
    }
  }

  func detailedItem(at location: FileLocation) async throws -> FileItem {
    lock.withLock {
      detailCallCount += 1
      activeDetailRequests += 1
      observedMaximumConcurrentDetailRequests = max(
        observedMaximumConcurrentDetailRequests,
        activeDetailRequests)
    }
    defer {
      lock.withLock { activeDetailRequests -= 1 }
    }
    if let detailDelay {
      try await Task.sleep(for: detailDelay)
    }
    let allItems = itemsByDirectory.values.lazy.flatMap { $0 }
    guard let item = allItems.first(where: { $0.path == location.remotePath })
    else {
      throw CocoaError(.fileNoSuchFile)
    }
    return fileItem(for: item, fillsMetadata: true)
  }

  private func items(at location: FileLocation, fillsMetadata: Bool) -> [FileItem] {
    guard location.providerID == id, let path = location.remotePath else { return [] }
    return (itemsByDirectory[path] ?? []).map {
      fileItem(for: $0, fillsMetadata: fillsMetadata)
    }
  }

  private func fileItem(for item: Item, fillsMetadata: Bool) -> FileItem {
    FileItem(
      remotePath: item.path,
      url: URL(fileURLWithPath: item.path),
      providerID: id,
      isDirectory: item.isDirectory,
      size: fillsMetadata ? (item.size ?? 1_024) : item.size,
      modifiedAt: fillsMetadata
        ? (item.modifiedAt ?? Date(timeIntervalSince1970: 1))
        : item.modifiedAt)
  }
}

private final class TrashUnavailableProvider: FileBrowserPermanentDeleteProvider,
  @unchecked Sendable
{
  let id = FileProviderID(rawValue: "mounted-volume-without-trash")
  let connectionID: FileProviderConnectionID? = nil
  let capabilities: FileProviderCapabilities = [.read, .write, .trash]
  private var exists = true
  private(set) var wasPermanentlyDeleted = false
  private(set) var permanentDeleteCount = 0

  func contents(of location: FileLocation) async throws -> [FileItem] {
    guard location.providerID == id, exists else { return [] }
    return [
      FileItem(
        remotePath: "./report.txt",
        url: URL(fileURLWithPath: "/report.txt"),
        providerID: id,
        isDirectory: false)
    ]
  }

  func parent(of _: FileLocation) -> FileLocation? { nil }

  func breadcrumbs(
    for _: FileLocation,
    constrainedTo _: FileLocation?
  ) -> [FileBrowserBreadcrumb] { [] }

  func createDirectory(named _: String, in _: FileLocation) async throws {}

  func rename(_: FileItem, to _: String) async throws {}

  func delete(_: FileItem) async throws {
    throw FileBrowserOperationError.trashUnavailable
  }

  func permanentlyDelete(_: FileItem) async throws {
    exists = false
    wasPermanentlyDeleted = true
    permanentDeleteCount += 1
  }
}

private final class MemoryStreamProvider: FileStreamTransferProvider, FileBrowserTransferProvider,
  FileTransferCommitProvider,
  @unchecked Sendable
{
  let id: FileProviderID
  let connectionID: FileProviderConnectionID? = nil
  let capabilities: FileProviderCapabilities = [.read, .write]

  private let lock = NSLock()
  private var files: [String: Data]
  private var failsNextWrite: Bool
  private var failsAfterFirstProgress: Bool
  private let failsRemoval: Bool
  private let writeDelay: Duration?
  /// 書き込み検証テスト用: 実際に受け取ったバイト数より少なく永続化することで、
  /// 「進捗としては満額を報告するが、実体は切り詰められている」破損を再現する。
  private let truncatesPersistedBytesBy: Int

  init(
    id: FileProviderID,
    files: [String: Data] = [:],
    failsNextWrite: Bool = false,
    failsAfterFirstProgress: Bool = false,
    writeDelay: Duration? = nil,
    truncatesPersistedBytesBy: Int = 0,
    failsRemoval: Bool = false
  ) {
    self.id = id
    self.files = files
    self.failsNextWrite = failsNextWrite
    self.failsAfterFirstProgress = failsAfterFirstProgress
    self.writeDelay = writeDelay
    self.truncatesPersistedBytesBy = truncatesPersistedBytesBy
    self.failsRemoval = failsRemoval
  }

  func contents(of location: FileLocation) async throws -> [FileItem] {
    guard location.providerID == id, location.remotePath == "." else { return [] }
    let items = lock.withLock {
      files.map { path, data in
        FileItem(
          remotePath: path,
          url: URL(fileURLWithPath: path),
          providerID: id,
          isDirectory: false,
          size: Int64(data.count))
      }
    }
    return items.sorted { $0.name < $1.name }
  }

  func parent(of _: FileLocation) -> FileLocation? { nil }

  func breadcrumbs(
    for _: FileLocation,
    constrainedTo _: FileLocation?
  ) -> [FileBrowserBreadcrumb] { [] }

  func createDirectory(named _: String, in _: FileLocation) async throws {}

  func rename(_ item: FileItem, to name: String) async throws {
    let root = FileLocation(remotePath: ".", providerID: id)
    guard let sourcePath = item.location.remotePath,
      let destination = root.appending(pathComponent: name)?.remotePath
    else {
      throw CocoaError(.fileNoSuchFile)
    }
    lock.withLock {
      files[destination] = files.removeValue(forKey: sourcePath)
    }
  }

  func delete(_ item: FileItem) async throws {
    try await removeAfterCrossProviderMove(item)
  }

  func move(
    _ item: FileItem,
    to directory: FileLocation,
    replacingExisting _: Bool
  ) async throws {
    try await copy(item, to: directory)
    try await removeAfterCrossProviderMove(item)
  }

  func copy(
    _ item: FileItem,
    to directory: FileLocation,
    replacingExisting _: Bool
  ) async throws {
    guard let data = data(at: item.location.remotePath ?? ""),
      let destination = directory.appending(pathComponent: item.name)?.remotePath
    else {
      throw CocoaError(.fileNoSuchFile)
    }
    lock.withLock { files[destination] = data }
  }

  func removeAfterCrossProviderMove(_ item: FileItem) async throws {
    if failsRemoval { throw CocoaError(.fileWriteNoPermission) }
    guard let path = item.location.remotePath else { throw CocoaError(.fileNoSuchFile) }
    _ = lock.withLock {
      files.removeValue(forKey: path)
    }
  }

  func fileChunks(for item: FileItem, chunkSize: Int) -> AsyncThrowingStream<Data, Error> {
    lock.lock()
    let data = files[item.location.remotePath ?? ""]
    lock.unlock()
    return AsyncThrowingStream { continuation in
      if let data {
        var offset = 0
        while offset < data.count {
          let end = min(offset + chunkSize, data.count)
          continuation.yield(data[offset..<end])
          offset = end
        }
        continuation.finish()
      } else {
        continuation.finish(throwing: CocoaError(.fileNoSuchFile))
      }
    }
  }

  func writeFileChunks(
    _ chunks: AsyncThrowingStream<Data, Error>,
    to destination: FileLocation,
    replacingExisting _: Bool,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws {
    guard destination.providerID == id, let path = destination.remotePath else {
      throw CocoaError(.fileNoSuchFile)
    }
    let shouldFail = lock.withLock { () -> Bool in
      defer { failsNextWrite = false }
      return failsNextWrite
    }
    if shouldFail {
      throw CocoaError(.fileWriteUnknown)
    }
    let shouldFailAfterProgress = lock.withLock { () -> Bool in
      defer { failsAfterFirstProgress = false }
      return failsAfterFirstProgress
    }
    var data = Data()
    for try await chunk in chunks {
      if let writeDelay {
        try await Task.sleep(for: writeDelay)
      }
      data.append(chunk)
      progress(Int64(data.count))
      if shouldFailAfterProgress {
        throw CocoaError(.fileWriteUnknown)
      }
    }
    lock.withLock {
      let persistedCount = max(0, data.count - truncatesPersistedBytesBy)
      files[path] = data.prefix(persistedCount)
    }
  }

  func commitTransferFile(
    from temporaryLocation: FileLocation,
    to destination: FileLocation,
    replacingExisting _: Bool
  ) async throws {
    guard let temporaryPath = temporaryLocation.remotePath,
      let destinationPath = destination.remotePath
    else {
      throw CocoaError(.fileNoSuchFile)
    }
    lock.withLock {
      files[destinationPath] = files.removeValue(forKey: temporaryPath)
    }
  }

  func discardTransferFile(at temporaryLocation: FileLocation) async {
    guard let path = temporaryLocation.remotePath else { return }
    lock.withLock { _ = files.removeValue(forKey: path) }
  }

  func data(at path: String) -> Data? {
    lock.withLock { files[path] }
  }

  /// セッションを経由せず直接ファイルを追加する。転送とは無関係に外部で内容が
  /// 変わった状況を模し、refreshContents()が呼ばれたかをitemsの反映で検証するために使う。
  func addFile(_ path: String, data: Data) {
    lock.withLock { files[path] = data }
  }
}

extension MemoryStreamProvider: FileBrowserItemDetailProvider {
  func detailedItem(at location: FileLocation) async throws -> FileItem {
    guard let path = location.remotePath, let data = data(at: path) else {
      throw CocoaError(.fileNoSuchFile)
    }
    return FileItem(
      remotePath: path,
      url: URL(fileURLWithPath: path),
      providerID: id,
      isDirectory: false,
      size: Int64(data.count))
  }
}

/// 同一Provider内moveが受け取った置換指定だけを記録するスパイ。
private final class MoveReplacingExistingSpyProvider: FileBrowserTransferProvider,
  @unchecked Sendable
{
  let id: FileProviderID
  let connectionID: FileProviderConnectionID? = nil
  let capabilities: FileProviderCapabilities = [.read, .write]

  private let lock = NSLock()
  private let files: [String: Data]
  private var recordedMoveReplacingExistingValues: [Bool] = []

  init(id: FileProviderID, files: [String: Data]) {
    self.id = id
    self.files = files
  }

  func contents(of location: FileLocation) async throws -> [FileItem] {
    guard location.providerID == id, let parentPath = location.remotePath else { return [] }
    return files.compactMap { path, data -> FileItem? in
      guard
        FileLocation(remotePath: path, providerID: id).deletingLastPathComponent()?
          .remotePath == parentPath
      else { return nil }
      return FileItem(
        remotePath: path,
        url: URL(fileURLWithPath: path),
        providerID: id,
        isDirectory: false,
        size: Int64(data.count))
    }
    .sorted { $0.name < $1.name }
  }

  func parent(of _: FileLocation) -> FileLocation? { nil }

  func breadcrumbs(
    for _: FileLocation,
    constrainedTo _: FileLocation?
  ) -> [FileBrowserBreadcrumb] { [] }

  func createDirectory(named _: String, in _: FileLocation) async throws {}
  func rename(_: FileItem, to _: String) async throws {}
  func delete(_: FileItem) async throws {}

  func move(
    _: FileItem,
    to _: FileLocation,
    replacingExisting: Bool
  ) async throws {
    lock.withLock { recordedMoveReplacingExistingValues.append(replacingExisting) }
  }

  func copy(
    _: FileItem,
    to _: FileLocation,
    replacingExisting _: Bool
  ) async throws {}

  func removeAfterCrossProviderMove(_: FileItem) async throws {}

  func moveReplacingExistingValues() -> [Bool] {
    lock.withLock { recordedMoveReplacingExistingValues }
  }
}

/// 同一Provider内コピー(makeTransferExecutionのsourceProvider.id == destinationProvider.id
/// 分岐)の検証失敗経路を再現するフェイク。source/destinationの両セッションが同一インスタンス
/// を共有する点がMemoryStreamProvider(異なるProvider同士)との違い。
private final class TruncatingSameProviderProvider: FileBrowserTransferProvider, @unchecked Sendable
{
  let id: FileProviderID
  let connectionID: FileProviderConnectionID? = nil
  let capabilities: FileProviderCapabilities = [.read, .write]

  private let lock = NSLock()
  private var files: [String: Data]
  private let truncatesCopiedBytesBy: Int
  private var removed: [String] = []

  init(id: FileProviderID, files: [String: Data] = [:], truncatesCopiedBytesBy: Int = 0) {
    self.id = id
    self.files = files
    self.truncatesCopiedBytesBy = truncatesCopiedBytesBy
  }

  func contents(of location: FileLocation) async throws -> [FileItem] {
    guard location.providerID == id, let parentPath = location.remotePath else { return [] }
    let items = lock.withLock { () -> [FileItem] in
      files.compactMap { path, data -> FileItem? in
        guard
          FileLocation(remotePath: path, providerID: id).deletingLastPathComponent()?
            .remotePath == parentPath
        else { return nil }
        return FileItem(
          remotePath: path,
          url: URL(fileURLWithPath: path),
          providerID: id,
          isDirectory: false,
          size: Int64(data.count))
      }
    }
    return items.sorted { $0.name < $1.name }
  }

  func parent(of _: FileLocation) -> FileLocation? { nil }

  func breadcrumbs(
    for _: FileLocation,
    constrainedTo _: FileLocation?
  ) -> [FileBrowserBreadcrumb] { [] }

  func createDirectory(named _: String, in _: FileLocation) async throws {}

  func rename(_ item: FileItem, to name: String) async throws {
    guard let sourcePath = item.location.remotePath,
      let parent = item.location.deletingLastPathComponent(),
      let destination = parent.appending(pathComponent: name)?.remotePath
    else {
      throw CocoaError(.fileNoSuchFile)
    }
    lock.withLock { files[destination] = files.removeValue(forKey: sourcePath) }
  }

  func delete(_ item: FileItem) async throws {
    try await removeAfterCrossProviderMove(item)
  }

  func move(
    _ item: FileItem,
    to directory: FileLocation,
    replacingExisting _: Bool
  ) async throws {
    try await copy(item, to: directory)
    try await removeAfterCrossProviderMove(item)
  }

  func copy(
    _ item: FileItem,
    to directory: FileLocation,
    replacingExisting _: Bool
  ) async throws {
    guard let data = lock.withLock({ files[item.location.remotePath ?? ""] }),
      let destinationPath = directory.appending(pathComponent: item.name)?.remotePath
    else {
      throw CocoaError(.fileNoSuchFile)
    }
    let persistedCount = max(0, data.count - truncatesCopiedBytesBy)
    lock.withLock { files[destinationPath] = Data(data.prefix(persistedCount)) }
  }

  func removeAfterCrossProviderMove(_ item: FileItem) async throws {
    guard let path = item.location.remotePath else { throw CocoaError(.fileNoSuchFile) }
    lock.withLock {
      files.removeValue(forKey: path)
      removed.append(path)
    }
  }

  func data(at path: String) -> Data? {
    lock.withLock { files[path] }
  }

  func removedPaths() -> [String] {
    lock.withLock { removed }
  }
}

extension TruncatingSameProviderProvider: FileBrowserItemDetailProvider {
  func detailedItem(at location: FileLocation) async throws -> FileItem {
    guard let path = location.remotePath, let data = data(at: path) else {
      throw CocoaError(.fileNoSuchFile)
    }
    return FileItem(
      remotePath: path,
      url: URL(fileURLWithPath: path),
      providerID: id,
      isDirectory: false,
      size: Int64(data.count))
  }
}

/// 転送レジューム(P1-2)の検証用フェイク。TruncatingSameProviderProviderと同じく
/// source/destinationの両セッションで同一インスタンスを共有する。copy呼び出し回数を
/// 項目名ごとに記録し、指定した項目名でCancellationErrorを投げて「進行中の項目までは
/// 完了済みだが、以降は一切手を付けていない」中断(app crash/stall guard相当)を
/// 決定的に再現できる。
private final class ResumeTrackingProvider: FileBrowserTransferProvider, @unchecked Sendable {
  let id: FileProviderID
  let connectionID: FileProviderConnectionID? = nil
  let capabilities: FileProviderCapabilities = [.read, .write]

  private let lock = NSLock()
  private var files: [String: Data]
  private var callCounts: [String: Int] = [:]
  private var delaysCopies = true
  private let cancelsOnItemNamed: String?
  /// 自動再接続(P1-3)検証用: これらの名前の項目は、呼び出し回数が
  /// connectionDropFailureLimit以下の間、接続断相当の汎用エラー(CancellationError/
  /// ReconnectFutileErrorのどちらでもない)を投げる。limitを超えたら通常どおり成功する。
  private let connectionDropItemsNamed: Set<String>
  private let connectionDropFailureLimit: Int
  /// 自動再接続(P1-3)のキャンセル検証用: この名前の項目のcopyは、実際のTask
  /// キャンセルに反応できるTask.sleepで長時間止まる(テストが進行中にcancelTransfer()を
  /// 呼べるようにするため)。
  private let delaysCopyForItemNamed: String?

  init(
    id: FileProviderID,
    files: [String: Data] = [:],
    cancelsOnItemNamed: String? = nil,
    connectionDropItemsNamed: Set<String> = [],
    connectionDropFailureLimit: Int = 0,
    delaysCopyForItemNamed: String? = nil
  ) {
    self.id = id
    self.files = files
    self.cancelsOnItemNamed = cancelsOnItemNamed
    self.connectionDropItemsNamed = connectionDropItemsNamed
    self.connectionDropFailureLimit = connectionDropFailureLimit
    self.delaysCopyForItemNamed = delaysCopyForItemNamed
  }

  func contents(of location: FileLocation) async throws -> [FileItem] {
    guard location.providerID == id, let parentPath = location.remotePath else { return [] }
    let items = lock.withLock { () -> [FileItem] in
      files.compactMap { path, data -> FileItem? in
        guard
          FileLocation(remotePath: path, providerID: id).deletingLastPathComponent()?
            .remotePath == parentPath
        else { return nil }
        return FileItem(
          remotePath: path,
          url: URL(fileURLWithPath: path),
          providerID: id,
          isDirectory: false,
          size: Int64(data.count))
      }
    }
    return items.sorted { $0.name < $1.name }
  }

  func parent(of _: FileLocation) -> FileLocation? { nil }

  func breadcrumbs(
    for _: FileLocation,
    constrainedTo _: FileLocation?
  ) -> [FileBrowserBreadcrumb] { [] }

  func createDirectory(named _: String, in _: FileLocation) async throws {}

  func rename(_ item: FileItem, to name: String) async throws {
    guard let sourcePath = item.location.remotePath,
      let parent = item.location.deletingLastPathComponent(),
      let destination = parent.appending(pathComponent: name)?.remotePath
    else {
      throw CocoaError(.fileNoSuchFile)
    }
    lock.withLock { files[destination] = files.removeValue(forKey: sourcePath) }
  }

  func delete(_ item: FileItem) async throws {
    try await removeAfterCrossProviderMove(item)
  }

  func move(
    _ item: FileItem,
    to directory: FileLocation,
    replacingExisting _: Bool
  ) async throws {
    try await copy(item, to: directory)
    try await removeAfterCrossProviderMove(item)
  }

  func copy(
    _ item: FileItem,
    to directory: FileLocation,
    replacingExisting _: Bool
  ) async throws {
    let attempt = lock.withLock { () -> Int in
      callCounts[item.name, default: 0] += 1
      return callCounts[item.name]!
    }
    // 中断(CancellationError)は「その時点まで」の一度きりの出来事を模すため、
    // 同名項目への2回目以降の呼び出し(=retry)では発生させない。
    if attempt == 1, item.name == cancelsOnItemNamed {
      throw CancellationError()
    }
    if item.name == delaysCopyForItemNamed, lock.withLock({ delaysCopies }) {
      // Task.sleepは実際のTaskキャンセルに反応して即座にCancellationErrorを投げるため、
      // テストがcancelTransfer()を呼ぶまでここで自然に「進行中」の状態を保てる。
      try await Task.sleep(for: .seconds(30))
    }
    if connectionDropItemsNamed.contains(item.name), attempt <= connectionDropFailureLimit {
      // CancellationError/ReconnectFutileErrorのどちらでもない、接続断相当の汎用エラー。
      throw CocoaError(.fileWriteUnknown)
    }
    guard let data = lock.withLock({ files[item.location.remotePath ?? ""] }),
      let destinationPath = directory.appending(pathComponent: item.name)?.remotePath
    else {
      throw CocoaError(.fileNoSuchFile)
    }
    lock.withLock { files[destinationPath] = data }
  }

  func removeAfterCrossProviderMove(_ item: FileItem) async throws {
    guard let path = item.location.remotePath else { throw CocoaError(.fileNoSuchFile) }
    lock.withLock { _ = files.removeValue(forKey: path) }
  }

  func copyCallCount(for name: String) -> Int {
    lock.withLock { callCounts[name, default: 0] }
  }

  func data(at path: String) -> Data? {
    lock.withLock { files[path] }
  }

  func removeFile(at path: String) {
    lock.withLock { _ = files.removeValue(forKey: path) }
  }

  func allowDelayedCopiesToProceed() {
    lock.withLock { delaysCopies = false }
  }
}

extension ResumeTrackingProvider: FileBrowserItemDetailProvider {
  func detailedItem(at location: FileLocation) async throws -> FileItem {
    guard let path = location.remotePath, let data = data(at: path) else {
      throw CocoaError(.fileNoSuchFile)
    }
    return FileItem(
      remotePath: path,
      url: URL(fileURLWithPath: path),
      providerID: id,
      isDirectory: false,
      size: Int64(data.count))
  }
}

/// 自動再接続(P1-3)はSFTP限定のスコープ決定のため、その検証用フェイクとして
/// AutoReconnectEligibleProviderへ適合させる(実際のSFTPFileProviderが本番で
/// 適合するのと同じ役割)。
extension ResumeTrackingProvider: AutoReconnectEligibleProvider {}

/// クロスProviderのフォルダ再開を、実際のチャンク転送・一時名コミット・既存名衝突まで
/// 通して検証するフェイク。createDirectoryはLocalFileProvider同様、既存名なら「 2」を
/// 生成するため、再開経路が誤ってcreateDirectoryを呼ぶ回帰も観測できる。
private final class CrossProviderResumeTreeProvider:
  FileStreamTransferProvider,
  FileBrowserOperationProvider,
  FileBrowserItemSizeProvider,
  FileTransferCommitProvider,
  @unchecked Sendable
{
  let id: FileProviderID
  let connectionID: FileProviderConnectionID? = nil
  let capabilities: FileProviderCapabilities = [.read, .write]

  private let lock = NSLock()
  private var directories: Set<String>
  private var files: [String: Data]
  private var createdPaths: [String] = []
  private var readCounts: [String: Int] = [:]
  private var writeAttemptCounts: [String: Int] = [:]
  private var replacementCommits = 0
  private let delayedWriteName: String?
  private var delaysWrites: Bool

  init(
    id: FileProviderID,
    directories: Set<String> = [],
    files: [String: Data] = [:],
    delayedWriteName: String? = nil
  ) {
    self.id = id
    self.directories = directories
    self.files = files
    self.delayedWriteName = delayedWriteName
    delaysWrites = delayedWriteName != nil
  }

  func contents(of location: FileLocation) async throws -> [FileItem] {
    guard location.providerID == id, let parentPath = location.remotePath else { return [] }
    return lock.withLock {
      var result: [FileItem] = directories.compactMap { path in
        guard path != parentPath,
          FileLocation(remotePath: path, providerID: id).deletingLastPathComponent()?.remotePath
            == parentPath
        else { return nil }
        return FileItem(
          remotePath: path,
          url: URL(fileURLWithPath: path),
          providerID: id,
          isDirectory: true)
      }
      result += files.compactMap { path, data in
        guard
          FileLocation(remotePath: path, providerID: id).deletingLastPathComponent()?.remotePath
            == parentPath
        else { return nil }
        return FileItem(
          remotePath: path,
          url: URL(fileURLWithPath: path),
          providerID: id,
          isDirectory: false,
          size: Int64(data.count))
      }
      return result.sorted { $0.name < $1.name }
    }
  }

  func parent(of location: FileLocation) -> FileLocation? {
    location.deletingLastPathComponent()
  }

  func breadcrumbs(
    for _: FileLocation,
    constrainedTo _: FileLocation?
  ) -> [FileBrowserBreadcrumb] { [] }

  func createDirectory(named name: String, in directory: FileLocation) async throws {
    guard let requestedPath = directory.appending(pathComponent: name)?.remotePath else {
      throw CocoaError(.fileNoSuchFile)
    }
    lock.withLock {
      var availablePath = requestedPath
      var suffix = 2
      while directories.contains(availablePath) || files[availablePath] != nil {
        availablePath = "\(requestedPath) \(suffix)"
        suffix += 1
      }
      directories.insert(availablePath)
      createdPaths.append(availablePath)
    }
  }

  func rename(_ item: FileItem, to name: String) async throws {
    guard let sourcePath = item.location.remotePath,
      let parent = item.location.deletingLastPathComponent(),
      let destinationPath = parent.appending(pathComponent: name)?.remotePath
    else { throw CocoaError(.fileNoSuchFile) }
    try lock.withLock {
      if let data = files.removeValue(forKey: sourcePath) {
        files[destinationPath] = data
      } else if directories.remove(sourcePath) != nil {
        directories.insert(destinationPath)
      } else {
        throw CocoaError(.fileNoSuchFile)
      }
    }
  }

  func delete(_ item: FileItem) async throws {
    guard let path = item.location.remotePath else { throw CocoaError(.fileNoSuchFile) }
    lock.withLock {
      files[path] = nil
      directories.remove(path)
    }
  }

  func fileChunks(
    for item: FileItem,
    chunkSize: Int
  ) -> AsyncThrowingStream<Data, Error> {
    let data = lock.withLock { () -> Data? in
      readCounts[item.name, default: 0] += 1
      return files[item.location.remotePath ?? ""]
    }
    return AsyncThrowingStream { continuation in
      guard let data else {
        continuation.finish(throwing: CocoaError(.fileNoSuchFile))
        return
      }
      var offset = 0
      while offset < data.count {
        let end = min(offset + chunkSize, data.count)
        continuation.yield(data[offset..<end])
        offset = end
      }
      continuation.finish()
    }
  }

  func writeFileChunks(
    _ chunks: AsyncThrowingStream<Data, Error>,
    to destination: FileLocation,
    replacingExisting _: Bool,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws {
    guard let path = destination.remotePath else { throw CocoaError(.fileNoSuchFile) }
    let name = logicalTransferName(for: path)
    let shouldDelay = lock.withLock { () -> Bool in
      writeAttemptCounts[name, default: 0] += 1
      return name == delayedWriteName && delaysWrites
    }
    if shouldDelay {
      try await Task.sleep(for: .seconds(30))
    }
    var data = Data()
    for try await chunk in chunks {
      data.append(chunk)
      progress(Int64(data.count))
    }
    lock.withLock { files[path] = data }
  }

  func commitTransferFile(
    from temporaryLocation: FileLocation,
    to destination: FileLocation,
    replacingExisting: Bool
  ) async throws {
    guard let temporaryPath = temporaryLocation.remotePath,
      let destinationPath = destination.remotePath
    else { throw CocoaError(.fileNoSuchFile) }
    try lock.withLock {
      guard let data = files.removeValue(forKey: temporaryPath) else {
        throw CocoaError(.fileNoSuchFile)
      }
      if files[destinationPath] != nil, !replacingExisting {
        files[temporaryPath] = data
        throw CocoaError(.fileWriteFileExists)
      }
      if files[destinationPath] != nil, replacingExisting {
        replacementCommits += 1
      }
      files[destinationPath] = data
    }
  }

  func stagedFileSize(at location: FileLocation) async throws -> Int64? {
    guard let path = location.remotePath else { return nil }
    return lock.withLock { files[path].map { Int64($0.count) } }
  }

  func itemSize(at location: FileLocation) async throws -> Int64? {
    guard let path = location.remotePath else { return nil }
    return lock.withLock { files[path].map { Int64($0.count) } }
  }

  func discardTransferFile(at location: FileLocation) async {
    guard let path = location.remotePath else { return }
    lock.withLock { files[path] = nil }
  }

  func allowDelayedWritesToProceed() {
    lock.withLock { delaysWrites = false }
  }

  func putFile(at path: String, data: Data) {
    lock.withLock { files[path] = data }
  }

  func data(at path: String) -> Data? {
    lock.withLock { files[path] }
  }

  func readCount(for name: String) -> Int {
    lock.withLock { readCounts[name, default: 0] }
  }

  func writeAttemptCount(for name: String) -> Int {
    lock.withLock { writeAttemptCounts[name, default: 0] }
  }

  func createdDirectoryPaths() -> [String] {
    lock.withLock { createdPaths }
  }

  func containsDirectory(at path: String) -> Bool {
    lock.withLock { directories.contains(path) }
  }

  func replacementCommitCount() -> Int {
    lock.withLock { replacementCommits }
  }

  private func logicalTransferName(for path: String) -> String {
    let component = path.split(separator: "/").last.map(String.init) ?? path
    guard component.hasPrefix("."),
      let marker = component.range(of: ".pkpane-transfer-")
    else { return component }
    return String(component[component.index(after: component.startIndex)..<marker.lowerBound])
  }
}

@Suite("FileBrowserSessionのローカルフォルダ監視")
struct FileBrowserSessionDirectoryWatchTests {
  @MainActor
  @Test("開いているフォルダへの外部ファイル追加が自動で一覧に反映される")
  func reflectsExternallyAddedFile() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "pkpane-watch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let provider = LocalFileProvider()
    let session = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: root, providerID: provider.id),
      transferQueue: .isolatedForTesting())
    session.load()
    await waitForLoading(session)
    #expect(session.items.isEmpty)

    try Data("x".utf8).write(to: root.appending(path: "dropped.txt"))

    // debounce(250ms)+再検証を待つ。負荷時のフレークを避けるため十分長い上限で
    // ポーリングし、反映され次第すぐ抜ける。
    let reflectionClock = ContinuousClock()
    let reflectionDeadline = reflectionClock.now.advanced(by: .seconds(2))
    while !session.items.contains(where: { $0.name == "dropped.txt" }),
      reflectionClock.now < reflectionDeadline
    {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(session.items.contains(where: { $0.name == "dropped.txt" }))
  }

  @MainActor
  @Test("削除でrefreshContentsが走った後も監視ゲートが再び開き外部変更が自動反映される")
  func reflectsExternalChangeAfterRefreshContentsCompletes() async throws {
    // dca81ab(refreshContents完了時にisRefreshingを戻す)の回帰確認。refreshContents()が
    // isRefreshingを戻し忘れると監視イベントのゲートが常にpending側へ倒れたまま固まり、
    // 以後の自動反映が死ぬ。delete/discardTransferredItems/転送完了・失敗/ZIP処理完了の
    // いずれもrefreshContents()を通るため、ここではdiscardTransferredItemsで代表させる。
    // root配下をto-remove.txt 1個だけにすると、削除後の再列挙対象が空ディレクトリになり
    // LocalFileProviderのcontentsStreamが1バッチもyieldしない(空batchはyieldされない)ため、
    // loadItemsの逐次公開分岐(isRefreshing = trueを立てる側)が一度も通らず、dca81abの
    // 戻し忘れがあってもこのテストは常にGREENになってしまう(空振り)。削除対象でない
    // keep.txtを残し、削除後も1件以上が列挙されるようにして逐次公開経路を確実に通す。
    let root = FileManager.default.temporaryDirectory
      .appending(path: "pkpane-watch-refresh-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("x".utf8).write(to: root.appending(path: "to-remove.txt"))
    try Data("k".utf8).write(to: root.appending(path: "keep.txt"))

    let provider = LocalFileProvider()
    let session = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: root, providerID: provider.id),
      transferQueue: .isolatedForTesting())
    session.load()
    await waitForLoading(session)
    let item = try #require(session.items.first(where: { $0.name == "to-remove.txt" }))

    session.discardTransferredItems([item])
    let refreshClock = ContinuousClock()
    let refreshDeadline = refreshClock.now.advanced(by: .seconds(2))
    while session.isLoading || session.items.map(\.name) != ["keep.txt"],
      refreshClock.now < refreshDeadline
    {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!session.isLoading && session.items.map(\.name) == ["keep.txt"])
    #expect(!session.isRefreshing)

    try Data("y".utf8).write(to: root.appending(path: "dropped-after-refresh.txt"))

    let reflectionClock = ContinuousClock()
    let reflectionDeadline = reflectionClock.now.advanced(by: .seconds(2))
    while !session.items.contains(where: { $0.name == "dropped-after-refresh.txt" }),
      reflectionClock.now < reflectionDeadline
    {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(session.items.contains(where: { $0.name == "dropped-after-refresh.txt" }))
  }

  @MainActor
  private func waitForLoading(_ session: FileBrowserSession) async {
    await waitUntil("isLoadingが期限内にfalseにならなかった") {
      !session.isLoading
    }
  }
}

@Suite("FileBrowserSessionのリスト表示フォルダその場展開")
struct FileBrowserSessionTreeExpansionTests {
  @MainActor
  @Test("展開子のZIP作成完了後は再列挙して表示項目を選択できる")
  func revealsCreatedArchiveAfterRefreshingExpandedChildren() async throws {
    let root = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = LocalFileProvider()
    let session = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: root, providerID: provider.id),
      transferQueue: .isolatedForTesting())
    let tab = FileWorkspaceTab(browser: session)
    session.load()
    await Self.waitForLoading(session)
    let folderItem = try #require(session.items.first(where: { $0.name == "sub" }))
    session.toggleExpansion(of: folderItem)
    try await Self.waitUntilChildrenLoaded(session, folderName: "sub")
    let sourceItem = try #require(
      session.selectableItems.first(where: { $0.name == "inner.txt" }))
    tab.selectedItemURLs = [sourceItem.url]

    session.createArchive([sourceItem])
    await waitUntil("revealRequestが期限内に設定されなかった") {
      session.revealRequest != nil
    }

    #expect(!session.isArchiving)
    #expect(session.errorMessage == nil)
    let request = try #require(session.revealRequest)
    #expect(request.directoryLocation == folderItem.location)
    let rows = session.flattenedRows(
      matching: "", sortOrder: .name, ascending: true, includesHiddenItems: false)
    let visibleURLs = Set(rows.map { $0.item.url })
    #expect(rows.contains(where: { $0.item.name == "inner.txt.zip" }))
    #expect(tab.selectRevealedItem(for: request, visibleItemURLs: visibleURLs))
    #expect(tab.selectedItemURLs == [request.itemURL])
  }

  @MainActor
  @Test("作成項目が現在の表示にない場合は既存選択を変更しない")
  func doesNotSelectRevealedItemOutsideVisibleItems() async throws {
    let root = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = LocalFileProvider()
    let session = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: root, providerID: provider.id),
      transferQueue: .isolatedForTesting())
    let tab = FileWorkspaceTab(browser: session)
    session.load()
    await Self.waitForLoading(session)
    let existingItem = try #require(session.items.first)
    tab.selectedItemURLs = [existingItem.url]
    let request = FileItemRevealRequest(
      generation: 1,
      itemURL: root.appending(path: "hidden.zip"),
      directoryLocation: session.currentLocation)

    #expect(!tab.selectRevealedItem(for: request, visibleItemURLs: []))
    #expect(tab.selectedItemURLs == [existingItem.url])
  }

  @MainActor
  @Test("兄弟項目が多数存在しても展開した子行の深さは1のまま(PKPaneUITests実フィクスチャ相当の再現)")
  func depthStaysOneWithManySiblingsPresent() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "pkpane-tree-siblings-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: root.appending(path: "Documents/caria", directoryHint: .isDirectory),
      withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      atPath: root.appending(path: "caria-link", directoryHint: .notDirectory).path,
      withDestinationPath: "Documents/caria")
    try Data("x".utf8).write(to: root.appending(path: "report.txt"))
    try Data("x".utf8).write(to: root.appending(path: "delete-me.txt"))
    try Data(repeating: 0, count: 1).write(to: root.appending(path: "a-size-small.txt"))
    try Data(repeating: 0, count: 4_096).write(to: root.appending(path: "z-size-large.txt"))
    try FileManager.default.createDirectory(
      at: root.appending(path: "MultiSelect", directoryHint: .isDirectory),
      withIntermediateDirectories: true)
    try Data("a".utf8).write(to: root.appending(path: "MultiSelect/select-a.txt"))
    try FileManager.default.createDirectory(
      at: root.appending(path: "TreeExpand", directoryHint: .isDirectory),
      withIntermediateDirectories: true)
    try Data("x".utf8).write(to: root.appending(path: "TreeExpand/inner-file.txt"))

    let provider = LocalFileProvider()
    let session = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: root, providerID: provider.id),
      transferQueue: .isolatedForTesting())
    session.load()
    await Self.waitForLoading(session)
    let folderItem = try #require(session.items.first(where: { $0.name == "TreeExpand" }))
    session.toggleExpansion(of: folderItem)
    try await Self.waitUntilChildrenLoaded(session, folderName: "TreeExpand")

    let rows = session.flattenedRows(
      matching: "", sortOrder: .name, ascending: true, includesHiddenItems: false)
    let treeExpandIndex = try #require(rows.firstIndex { $0.item.name == "TreeExpand" })
    let innerFileIndex = try #require(rows.firstIndex { $0.item.name == "inner-file.txt" })

    #expect(innerFileIndex == treeExpandIndex + 1)
    #expect(rows[treeExpandIndex].depth == 0)
    #expect(rows[innerFileIndex].depth == 1)
    #expect(rows[treeExpandIndex].isExpanded)
    #expect(!rows[treeExpandIndex].isLoadingChildren)
  }

  @MainActor
  @Test("展開すると既存Provider列挙経路で子項目が非同期にロードされflattenedRowsへ反映される")
  func expandingFolderLoadsChildrenAndFlattensRows() async throws {
    let root = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = LocalFileProvider()
    let session = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: root, providerID: provider.id),
      transferQueue: .isolatedForTesting())
    session.load()
    await Self.waitForLoading(session)
    let folderItem = try #require(session.items.first(where: { $0.name == "sub" }))

    // 展開直後: ロード完了までflattenedRowsは折りたたみ扱いの1行のまま
    // (子が未キャッシュのためisExpandedはtrueでもchildren(of:)はまだnil)。
    session.toggleExpansion(of: folderItem)

    var rowsAfterExpand: [FileTreeRow] = []
    let expansionClock = ContinuousClock()
    let expansionDeadline = expansionClock.now.advanced(by: .seconds(2))
    repeat {
      rowsAfterExpand = session.flattenedRows(
        matching: "", sortOrder: .name, ascending: true, includesHiddenItems: false)
      if rowsAfterExpand.contains(where: { $0.item.name == "inner.txt" }) { break }
      try await Task.sleep(for: .milliseconds(10))
    } while expansionClock.now < expansionDeadline

    let folderRow = try #require(rowsAfterExpand.first { $0.item.name == "sub" })
    #expect(folderRow.isExpanded)
    #expect(!folderRow.isLoadingChildren)
    let childRow = try #require(rowsAfterExpand.first { $0.item.name == "inner.txt" })
    #expect(childRow.depth == 1)
  }

  @MainActor
  @Test("折りたたんだ後の再展開はキャッシュから即座に復元され再ロードを要求しない")
  func collapsingThenReExpandingRestoresFromCacheImmediately() async throws {
    let root = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = LocalFileProvider()
    let session = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: root, providerID: provider.id),
      transferQueue: .isolatedForTesting())
    session.load()
    await Self.waitForLoading(session)
    let folderItem = try #require(session.items.first(where: { $0.name == "sub" }))
    session.toggleExpansion(of: folderItem)
    try await Self.waitUntilChildrenLoaded(session, folderName: "sub")

    session.toggleExpansion(of: folderItem)  // 折りたたみ
    let collapsedRows = session.flattenedRows(
      matching: "", sortOrder: .name, ascending: true, includesHiddenItems: false)
    #expect(!collapsedRows.contains { $0.item.name == "inner.txt" })

    session.toggleExpansion(of: folderItem)  // 再展開: キャッシュがあるため即座に復元
    let reExpandedRows = session.flattenedRows(
      matching: "", sortOrder: .name, ascending: true, includesHiddenItems: false)
    let folderRow = try #require(reExpandedRows.first { $0.item.name == "sub" })
    #expect(folderRow.isExpanded)
    #expect(!folderRow.isLoadingChildren)
    #expect(reExpandedRows.contains { $0.item.name == "inner.txt" })
  }

  @MainActor
  @Test("フォルダ移動(ナビゲート)すると展開状態がリセットされる")
  func navigatingResetsExpansionState() async throws {
    let root = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let otherRoot = FileManager.default.temporaryDirectory
      .appending(path: "pkpane-tree-other-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: otherRoot) }
    let provider = LocalFileProvider()
    let session = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: root, providerID: provider.id),
      transferQueue: .isolatedForTesting())
    session.load()
    await Self.waitForLoading(session)
    let folderItem = try #require(session.items.first(where: { $0.name == "sub" }))
    session.toggleExpansion(of: folderItem)
    try await Self.waitUntilChildrenLoaded(session, folderName: "sub")

    session.load(location: FileLocation(localURL: otherRoot, providerID: provider.id))
    await Self.waitForLoading(session)
    session.load(location: FileLocation(localURL: root, providerID: provider.id))
    await Self.waitForLoading(session)

    let rowsAfterReturning = session.flattenedRows(
      matching: "", sortOrder: .name, ascending: true, includesHiddenItems: false)
    let folderRow = try #require(rowsAfterReturning.first { $0.item.name == "sub" })
    #expect(!folderRow.isExpanded)
    #expect(!rowsAfterReturning.contains { $0.item.name == "inner.txt" })
  }

  @MainActor
  @Test("展開中フォルダへの外部ファイル追加が自動で子項目へ反映される")
  func reflectsExternallyAddedFileInExpandedFolder() async throws {
    let root = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = LocalFileProvider()
    let session = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: root, providerID: provider.id),
      transferQueue: .isolatedForTesting())
    session.load()
    await Self.waitForLoading(session)
    let folderItem = try #require(session.items.first(where: { $0.name == "sub" }))
    session.toggleExpansion(of: folderItem)
    try await Self.waitUntilChildrenLoaded(session, folderName: "sub")

    try Data("z".utf8).write(to: root.appending(path: "sub/dropped-in-sub.txt"))

    var reflected = false
    let reflectionClock = ContinuousClock()
    let reflectionDeadline = reflectionClock.now.advanced(by: .seconds(2))
    repeat {
      let rows = session.flattenedRows(
        matching: "", sortOrder: .name, ascending: true, includesHiddenItems: false)
      if rows.contains(where: { $0.item.name == "dropped-in-sub.txt" }) {
        reflected = true
        break
      }
      try await Task.sleep(for: .milliseconds(10))
    } while reflectionClock.now < reflectionDeadline
    #expect(reflected)
  }

  @MainActor
  @Test("Option相当の再帰展開で配下のフォルダもすべて展開される")
  func recursiveExpansionExpandsNestedFolders() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "pkpane-tree-recursive-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: root.appending(path: "sub/inner", directoryHint: .isDirectory),
      withIntermediateDirectories: true)
    try Data("x".utf8).write(to: root.appending(path: "sub/inner/leaf.txt"))
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = LocalFileProvider()
    let session = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: root, providerID: provider.id),
      transferQueue: .isolatedForTesting())
    session.load()
    await Self.waitForLoading(session)
    let folderItem = try #require(session.items.first(where: { $0.name == "sub" }))

    session.toggleExpansion(of: folderItem, recursively: true)

    var rows: [FileTreeRow] = []
    let expansionClock = ContinuousClock()
    let expansionDeadline = expansionClock.now.advanced(by: .seconds(2))
    repeat {
      rows = session.flattenedRows(
        matching: "", sortOrder: .name, ascending: true, includesHiddenItems: false)
      if rows.contains(where: { $0.item.name == "leaf.txt" }) { break }
      try await Task.sleep(for: .milliseconds(10))
    } while expansionClock.now < expansionDeadline

    let subRow = try #require(rows.first { $0.item.name == "sub" })
    let innerRow = try #require(rows.first { $0.item.name == "inner" })
    #expect(subRow.isExpanded)
    #expect(innerRow.isExpanded)
    #expect(innerRow.depth == 1)
    #expect(rows.first { $0.item.name == "leaf.txt" }?.depth == 2)
  }

  private static func makeFixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "pkpane-tree-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: root.appending(path: "sub", directoryHint: .isDirectory),
      withIntermediateDirectories: true)
    try Data("x".utf8).write(to: root.appending(path: "sub/inner.txt"))
    return root
  }

  @MainActor
  private static func waitForLoading(_ session: FileBrowserSession) async {
    await waitUntil("isLoadingが期限内にfalseにならなかった") {
      !session.isLoading
    }
  }

  @MainActor
  private static func waitUntilChildrenLoaded(_ session: FileBrowserSession, folderName: String)
    async
  {
    await waitUntil("子項目が期限内に読み込み完了しなかった") {
      let rows = session.flattenedRows(
        matching: "", sortOrder: .name, ascending: true, includesHiddenItems: false)
      guard let folderRow = rows.first(where: { $0.item.name == folderName }) else {
        return false
      }
      return folderRow.isExpanded && !folderRow.isLoadingChildren
    }
  }
}

@Suite("FileBrowserSessionの競合するロードの調停")
struct FileBrowserSessionLoadRaceTests {
  @MainActor
  @Test("列挙中に別フォルダへ移動すると移動前フォルダの内容へ巻き戻らない")
  func doesNotRevertToPreviousFolderAfterNavigatingAwayDuringSlowLoad() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "pkpane-load-race-\(UUID().uuidString)")
    let oldDirectoryURL = root.appending(path: "old")
    let newDirectoryURL = root.appending(path: "new")
    try FileManager.default.createDirectory(
      at: oldDirectoryURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: newDirectoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("old".utf8).write(to: oldDirectoryURL.appending(path: "old.txt"))
    try Data("new".utf8).write(to: newDirectoryURL.appending(path: "new.txt"))

    // localURLを持つロケーションでなければFileBrowserSessionはディレクトリ監視を
    // 武装しない(startWatchingCurrentLocationIfNeededが早期return)。武装完了直後の
    // 取りこぼし防止チェックと進行中のload()が競合する状況を再現するため、実
    // ディレクトリ+localURLベースのロケーションを使う。
    let provider = DelayedLocalFileProvider(
      slowDirectoryURL: oldDirectoryURL, delay: .milliseconds(300))
    let oldLocation = FileLocation(localURL: oldDirectoryURL, providerID: provider.id)
    let newLocation = FileLocation(localURL: newDirectoryURL, providerID: provider.id)
    let session = FileBrowserSession(
      provider: provider, initialLocation: oldLocation, transferQueue: .isolatedForTesting())

    session.load()
    // ディレクトリ監視の武装(open(2)によるfd取得、非同期だがms未満で完了する)を
    // 待ってから移動する。旧フォルダの列挙(300ms delay)はまだ進行中のため、
    // 「武装完了直後のチェック」が進行中のload()と競合するタイミングを作れる。
    try await Task.sleep(for: .milliseconds(100))
    session.load(location: newLocation)
    await waitForLoading(session)

    #expect(session.currentLocation == newLocation)
    #expect(session.items.map(\.name) == ["new.txt"])

    // 遅れて完了する旧フォルダの列挙(cancelされているはずのT_load)が、items/
    // currentLocationを巻き戻さないことをdelayより十分長く待って確認する。
    try await Task.sleep(for: .milliseconds(500))

    #expect(session.currentLocation == newLocation)
    #expect(session.items.map(\.name) == ["new.txt"])
  }

  @MainActor
  @Test("削除後の再列挙中に別フォルダへ移動しても移動先へ旧フォルダの内容を書き込まない")
  func doesNotLeakStaleRefreshIntoNewFolderAfterNavigatingDuringDelete() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "pkpane-refresh-race-\(UUID().uuidString)")
    let slowDirectoryURL = root.appending(path: "slow")
    let otherDirectoryURL = root.appending(path: "other")
    try FileManager.default.createDirectory(
      at: slowDirectoryURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: otherDirectoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("keep".utf8).write(to: slowDirectoryURL.appending(path: "keep.txt"))
    try Data("remove".utf8).write(to: slowDirectoryURL.appending(path: "to-remove.txt"))
    try Data("other".utf8).write(to: otherDirectoryURL.appending(path: "other.txt"))

    // 削除(discardTransferredItems)がrefreshContents()を呼ぶ側のディレクトリを遅延させ、
    // その再列挙が完了する前に別フォルダへ移動できる窓を作る。
    let provider = DelayedLocalFileProvider(
      slowDirectoryURL: slowDirectoryURL, delay: .milliseconds(300))
    let slowLocation = FileLocation(localURL: slowDirectoryURL, providerID: provider.id)
    let otherLocation = FileLocation(localURL: otherDirectoryURL, providerID: provider.id)
    let session = FileBrowserSession(
      provider: provider, initialLocation: slowLocation, transferQueue: .isolatedForTesting())

    session.load()
    // 初回列挙も遅延ディレクトリ向けのため、waitForLoading(yieldのみ)では実時間を
    // 稼げない。delayより十分長くsleepしてから完了を確認する。
    try await Task.sleep(for: .milliseconds(400))
    #expect(!session.isLoading)
    #expect(session.items.map(\.name).sorted() == ["keep.txt", "to-remove.txt"])
    let itemToRemove = try #require(session.items.first(where: { $0.name == "to-remove.txt" }))

    session.discardTransferredItems([itemToRemove])
    // refreshContents()内のprovider.contents(of: slowDirectoryURL)がまだ300ms delay中の
    // うちに、別フォルダへ移動する。
    try await Task.sleep(for: .milliseconds(100))
    session.load(location: otherLocation)
    await waitForLoading(session)

    #expect(session.currentLocation == otherLocation)
    #expect(session.items.map(\.name) == ["other.txt"])

    // 遅れて完了する旧フォルダのrefreshContents()(cancelされずに生き残っているはず)が、
    // 移動先(otherLocation)のitems/directoryCacheへ旧フォルダの結果を書き込まないことを
    // delayより十分長く待って確認する。
    try await Task.sleep(for: .milliseconds(500))

    #expect(session.currentLocation == otherLocation)
    #expect(session.items.map(\.name) == ["other.txt"])
  }

  @MainActor
  private func waitForLoading(_ session: FileBrowserSession) async {
    await waitUntil("セッションの読み込みが期限内に完了しなかった") {
      !(session.isLoading || session.isRefreshing)
    }
  }
}

/// LocalFileProviderをラップし、指定ディレクトリの列挙だけを遅延させるテスト用Provider。
/// FileBrowserSessionのローカルフォルダ監視(watcher武装)を実ディレクトリ上で動かしつつ、
/// 列挙の完了タイミングだけを制御するために使う。操作系(削除・転送)はLocalFileProviderへ
/// そのまま委譲し、削除経由のrefreshContents()レースも同じProviderで再現できるようにする。
private final class DelayedLocalFileProvider: FileBrowserProvider, FileBrowserTransferProvider,
  @unchecked Sendable
{
  let id: FileProviderID = .local
  let connectionID: FileProviderConnectionID? = nil
  let capabilities: FileProviderCapabilities = [.read, .write]
  private let localProvider = LocalFileProvider()
  private let slowDirectoryURL: URL
  private let delay: Duration

  init(slowDirectoryURL: URL, delay: Duration) {
    self.slowDirectoryURL = slowDirectoryURL.standardizedFileURL
    self.delay = delay
  }

  func contents(of location: FileLocation) async throws -> [FileItem] {
    if location.localURL?.standardizedFileURL == slowDirectoryURL {
      try await Task.sleep(for: delay)
    }
    return try await localProvider.contents(of: location)
  }

  func parent(of location: FileLocation) -> FileLocation? {
    localProvider.parent(of: location)
  }

  func breadcrumbs(
    for location: FileLocation,
    constrainedTo root: FileLocation?
  ) -> [FileBrowserBreadcrumb] {
    localProvider.breadcrumbs(for: location, constrainedTo: root)
  }

  func createDirectory(named name: String, in location: FileLocation) async throws {
    try await localProvider.createDirectory(named: name, in: location)
  }

  func rename(_ item: FileItem, to name: String) async throws {
    try await localProvider.rename(item, to: name)
  }

  func delete(_ item: FileItem) async throws {
    try await localProvider.delete(item)
  }

  func move(
    _ item: FileItem,
    to directory: FileLocation,
    replacingExisting _: Bool
  ) async throws {
    try await localProvider.move(item, to: directory)
  }

  func copy(
    _ item: FileItem,
    to directory: FileLocation,
    replacingExisting: Bool
  ) async throws {
    try await localProvider.copy(
      item,
      to: directory,
      replacingExisting: replacingExisting)
  }

  func removeAfterCrossProviderMove(_ item: FileItem) async throws {
    try await localProvider.removeAfterCrossProviderMove(item)
  }
}

@Suite("FileBrowserSessionのソート済みマージ")
struct FileBrowserSessionMergeTests {
  private func item(_ name: String) -> FileItem {
    FileItem(url: URL(filePath: "/tmp/\(name)"), isDirectory: false)
  }

  @Test("未ソートのバッチをソート済み配列へマージすると全体が名前順になる")
  func mergesUnsortedBatchIntoSortedItems() {
    let sorted = [item("apple"), item("cherry"), item("melon")]
    let batch = [item("banana"), item("orange"), item("grape")]
    let merged = FileBrowserSession.mergingSorted(sorted, with: batch)
    #expect(merged.map(\.name) == ["apple", "banana", "cherry", "grape", "melon", "orange"])
  }

  @Test("空のソート済み配列へのマージはバッチのソートと等しい")
  func mergesIntoEmptyItems() {
    let batch = [item("item-10"), item("item-2"), item("item-1")]
    let merged = FileBrowserSession.mergingSorted([], with: batch)
    #expect(merged.map(\.name) == ["item-1", "item-2", "item-10"])
  }

  @Test("空のバッチのマージは元の配列を変えない")
  func mergesEmptyBatch() {
    let sorted = [item("a"), item("b")]
    let merged = FileBrowserSession.mergingSorted(sorted, with: [])
    #expect(merged.map(\.name) == ["a", "b"])
  }
}

@Suite("FileBrowserSessionの表示項目メモ化")
struct FileBrowserSessionDisplayItemsTests {
  @MainActor
  @Test("同じ条件のdisplayItemsは再計算しない")
  func cachesDisplayItemsForSameQuery() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["alpha.txt", ".hidden.txt", "beta.txt"] {
      FileManager.default.createFile(atPath: root.appending(path: name).path, contents: Data())
    }
    let provider = LocalFileProvider()
    let session = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: root, providerID: provider.id),
      transferQueue: .isolatedForTesting())
    session.load()
    while session.isLoading || session.isRefreshing {
      await Task.yield()
    }

    let first = session.displayItems(
      matching: "", sortOrder: .name, ascending: true, includesHiddenItems: false)
    let countAfterFirst = session.displayItemsComputationCount
    let second = session.displayItems(
      matching: "", sortOrder: .name, ascending: true, includesHiddenItems: false)

    #expect(first.map(\.name) == ["alpha.txt", "beta.txt"])
    #expect(second.map(\.name) == first.map(\.name))
    #expect(session.displayItemsComputationCount == countAfterFirst)
  }

  @MainActor
  @Test("条件変更と再読込のときだけdisplayItemsを再計算する")
  func recomputesDisplayItemsOnQueryOrItemsChange() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    FileManager.default.createFile(
      atPath: root.appending(path: "alpha.txt").path, contents: Data())
    let provider = LocalFileProvider()
    let session = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: root, providerID: provider.id),
      transferQueue: .isolatedForTesting())
    session.load()
    while session.isLoading || session.isRefreshing {
      await Task.yield()
    }

    _ = session.displayItems(
      matching: "", sortOrder: .name, ascending: true, includesHiddenItems: false)
    let baseline = session.displayItemsComputationCount
    _ = session.displayItems(
      matching: "alp", sortOrder: .name, ascending: true, includesHiddenItems: false)
    #expect(session.displayItemsComputationCount == baseline + 1)

    session.refresh()
    while session.isLoading || session.isRefreshing {
      await Task.yield()
    }
    _ = session.displayItems(
      matching: "alp", sortOrder: .name, ascending: true, includesHiddenItems: false)
    #expect(session.displayItemsComputationCount == baseline + 2)
  }

  @MainActor
  @Test("displayItemsGenerationはdisplayItemsComputationCountと連動し変化がないときは増えない")
  func displayItemsGenerationTracksComputationCount() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    FileManager.default.createFile(
      atPath: root.appending(path: "alpha.txt").path, contents: Data())
    let provider = LocalFileProvider()
    let session = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: root, providerID: provider.id),
      transferQueue: .isolatedForTesting())
    session.load()
    while session.isLoading || session.isRefreshing {
      await Task.yield()
    }

    _ = session.displayItems(
      matching: "", sortOrder: .name, ascending: true, includesHiddenItems: false)
    let generationAfterFirst = session.displayItemsGeneration

    // 同一条件の再取得(キャッシュヒット)では増えない。
    _ = session.displayItems(
      matching: "", sortOrder: .name, ascending: true, includesHiddenItems: false)
    #expect(session.displayItemsGeneration == generationAfterFirst)

    // 条件変更(再計算)では増える。
    _ = session.displayItems(
      matching: "alp", sortOrder: .name, ascending: true, includesHiddenItems: false)
    #expect(session.displayItemsGeneration == generationAfterFirst + 1)
  }
}

@Suite("FileBrowserSessionの履歴移動キャッシュ")
struct FileBrowserSessionHistoryCacheTests {
  @MainActor
  @Test("変更のないフォルダへ戻ると再列挙せず確定表示になる")
  func returnsToUnchangedFolderWithoutRefreshing() async throws {
    let rootA = try makeFixtureDirectory(fileNames: ["a1.txt", "a2.txt"])
    let rootB = try makeFixtureDirectory(fileNames: ["b1.txt"])
    defer {
      try? FileManager.default.removeItem(at: rootA)
      try? FileManager.default.removeItem(at: rootB)
    }
    let provider = LocalFileProvider()
    let session = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: rootA, providerID: provider.id),
      transferQueue: .isolatedForTesting())
    session.load()
    while session.isLoading || session.isRefreshing { await Task.yield() }
    session.open(location: FileLocation(localURL: rootB, providerID: provider.id))
    while session.isLoading || session.isRefreshing { await Task.yield() }

    session.goBack()

    #expect(session.items.map(\.name) == ["a1.txt", "a2.txt"])
    #expect(session.isLoading == false)
    #expect(session.isRefreshing == false)
  }

  @MainActor
  @Test("変更されたフォルダへ戻ると再列挙して新項目を表示する")
  func returnsToChangedFolderAndRefreshes() async throws {
    let rootA = try makeFixtureDirectory(fileNames: ["a1.txt"])
    let rootB = try makeFixtureDirectory(fileNames: ["b1.txt"])
    defer {
      try? FileManager.default.removeItem(at: rootA)
      try? FileManager.default.removeItem(at: rootB)
    }
    let provider = LocalFileProvider()
    let session = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: rootA, providerID: provider.id),
      transferQueue: .isolatedForTesting())
    session.load()
    while session.isLoading || session.isRefreshing { await Task.yield() }
    session.open(location: FileLocation(localURL: rootB, providerID: provider.id))
    while session.isLoading || session.isRefreshing { await Task.yield() }

    FileManager.default.createFile(
      atPath: rootA.appending(path: "a2.txt").path, contents: Data())
    session.goBack()
    while session.isLoading || session.isRefreshing { await Task.yield() }

    #expect(session.items.map(\.name) == ["a1.txt", "a2.txt"])
  }

  @MainActor
  @Test("ディレクトリmtime不変でもファイルサイズが変わっていれば無音再検証で表示が更新される")
  func revalidatesSilentlyWhenFileContentsChangeWithoutDirectoryMtime() async throws {
    let root = try makeFixtureDirectory(fileNames: [])
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "report.txt")
    FileManager.default.createFile(atPath: file.path, contents: Data("旧".utf8))
    let provider = LocalFileProvider()
    let session = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: root, providerID: provider.id),
      transferQueue: .isolatedForTesting())
    session.load()
    while session.isLoading || session.isRefreshing { await Task.yield() }
    let originalSize = session.items.first(where: { $0.name == "report.txt" })?.size

    // FileHandleでのin-place書き換えはディレクトリエントリの置換を伴わないため、
    // ディレクトリ自体のmtimeは動かない(FileManager.createFile(atPath:contents:)は
    // 内部的にunlink+createへ倒れることがあり、ディレクトリmtimeを動かしてしまうため使わない)。
    let handle = try FileHandle(forWritingTo: file)
    try handle.truncate(atOffset: 0)
    try handle.write(contentsOf: Data("新しい内容です".utf8))
    try handle.close()
    session.load()
    #expect(session.isLoading == false)
    #expect(session.isRefreshing == false)
    while session.isRevalidatingInBackground { await Task.yield() }

    let updatedSize = session.items.first(where: { $0.name == "report.txt" })?.size
    #expect(updatedSize != originalSize)
    #expect(updatedSize == Int64(Data("新しい内容です".utf8).count))
  }

  @MainActor
  @Test("内容が完全に一致する無音再検証ではitemsを再代入しない")
  func doesNotReplaceItemsWhenSilentRevalidationFindsNoChange() async throws {
    let root = try makeFixtureDirectory(fileNames: ["a1.txt", "a2.txt"])
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = LocalFileProvider()
    let session = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: root, providerID: provider.id),
      transferQueue: .isolatedForTesting())
    session.load()
    while session.isLoading || session.isRefreshing { await Task.yield() }
    let replacementCountAfterFirstLoad = session.itemsReplacementCount

    session.load()
    while session.isRevalidatingInBackground { await Task.yield() }

    #expect(session.itemsReplacementCount == replacementCountAfterFirstLoad)
    #expect(session.items.map(\.name) == ["a1.txt", "a2.txt"])
  }

  private func makeFixtureDirectory(fileNames: [String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for name in fileNames {
      FileManager.default.createFile(atPath: root.appending(path: name).path, contents: Data())
    }
    return root
  }
}

/// LocalFileProviderのcopy/moveだけをcloneAttempt常時失敗で上書きし、
/// CancellableFileCopierのチャンクフォールバック経路を強制するテスト専用Provider。
/// clonefile(2)は同一ボリュームで即時・不可分に完了するため、キャンセルの伝播を
/// 決定的に検証するにはフォールバック経路を明示的に選ばせる必要がある。
private struct FallbackOnlyLocalFileProvider: FileBrowserProvider, FileBrowserTransferProvider {
  private let wrapped = LocalFileProvider()

  var id: FileProviderID { wrapped.id }
  var connectionID: FileProviderConnectionID? { wrapped.connectionID }
  var capabilities: FileProviderCapabilities { wrapped.capabilities }

  func contents(of location: FileLocation) async throws -> [FileItem] {
    try await wrapped.contents(of: location)
  }

  func contents(of location: FileLocation, includingHidden: Bool) async throws -> [FileItem] {
    try await wrapped.contents(of: location, includingHidden: includingHidden)
  }

  func parent(of location: FileLocation) -> FileLocation? {
    wrapped.parent(of: location)
  }

  func breadcrumbs(
    for location: FileLocation,
    constrainedTo root: FileLocation?
  ) -> [FileBrowserBreadcrumb] {
    wrapped.breadcrumbs(for: location, constrainedTo: root)
  }

  func createDirectory(named name: String, in location: FileLocation) async throws {
    try await wrapped.createDirectory(named: name, in: location)
  }

  func rename(_ item: FileItem, to name: String) async throws {
    try await wrapped.rename(item, to: name)
  }

  func delete(_ item: FileItem) async throws {
    try await wrapped.delete(item)
  }

  func removeAfterCrossProviderMove(_ item: FileItem) async throws {
    try await wrapped.removeAfterCrossProviderMove(item)
  }

  func copy(
    _ item: FileItem,
    to directory: FileLocation,
    replacingExisting: Bool
  ) async throws {
    guard item.location.providerID == id, directory.providerID == id,
      let directoryURL = directory.localURL
    else {
      throw LocalFileProviderError.invalidLocation
    }
    let destinationURL = directoryURL.appending(path: item.url.lastPathComponent)
    if replacingExisting, FileManager.default.fileExists(atPath: destinationURL.path) {
      try FileManager.default.removeItem(at: destinationURL)
    }
    let temporaryURL = directoryURL.appending(
      path: ".\(destinationURL.lastPathComponent).pkpane-copy-\(UUID().uuidString)")
    do {
      try CancellableFileCopier.copy(
        from: item.url, to: temporaryURL, isCancelled: { Task.isCancelled },
        cloneAttempt: { _, _ in false })
      try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
    } catch {
      try? FileManager.default.removeItem(at: temporaryURL)
      throw error
    }
  }

  func move(
    _ item: FileItem,
    to directory: FileLocation,
    replacingExisting _: Bool
  ) async throws {
    guard item.location.providerID == id, directory.providerID == id,
      let directoryURL = directory.localURL
    else {
      throw LocalFileProviderError.invalidLocation
    }
    let destinationURL = directoryURL.appending(path: item.url.lastPathComponent)
    do {
      try CancellableFileCopier.copy(
        from: item.url, to: destinationURL, isCancelled: { Task.isCancelled },
        cloneAttempt: { _, _ in false })
    } catch {
      try? FileManager.default.removeItem(at: destinationURL)
      throw error
    }
    try FileManager.default.removeItem(at: item.url)
  }
}

@Suite("FileBrowserSessionの.app起動判定")
struct FileBrowserSessionApplicationBundleTests {
  @Test(".appフォルダはフォルダ侵入ではなく起動対象として判定される")
  func detectsLocalApplicationBundle() {
    let item = FileItem(
      url: URL(filePath: "/Applications/Preview.app"), isDirectory: true)
    #expect(FileBrowserSession.localApplicationBundleURL(for: item) == item.url)
  }

  @Test("拡張子が.app以外の通常フォルダは起動対象にならない")
  func ignoresRegularDirectory() {
    let item = FileItem(url: URL(filePath: "/Applications/Utilities"), isDirectory: true)
    #expect(FileBrowserSession.localApplicationBundleURL(for: item) == nil)
  }

  @Test(".appという名前でもファイル(非ディレクトリ)は起動対象にならない")
  func ignoresNonDirectoryEvenWithAppExtension() {
    let item = FileItem(url: URL(filePath: "/tmp/note.app"), isDirectory: false)
    #expect(FileBrowserSession.localApplicationBundleURL(for: item) == nil)
  }

  @Test("localURLを持たないリモート項目は.app拡張子でも起動対象にならない")
  func ignoresRemoteItemWithoutLocalURL() {
    let providerID = FileProviderID(rawValue: "sftp-test")
    let item = FileItem(
      remotePath: "/remote/Preview.app",
      url: URL(filePath: "/remote/Preview.app"),
      providerID: providerID,
      isDirectory: true)
    #expect(FileBrowserSession.localApplicationBundleURL(for: item) == nil)
  }
}

@Suite("FileBrowserSessionのパッケージ内容表示")
struct FileBrowserSessionShowPackageContentsTests {
  @MainActor
  @Test("showPackageContentsは.appバンドルへフォルダとして侵入する")
  func navigatesIntoApplicationBundle() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "pkpane-package-\(UUID().uuidString)")
    let appURL = root.appending(path: "Dummy.app")
    try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let provider = LocalFileProvider()
    let session = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: root, providerID: provider.id),
      transferQueue: .isolatedForTesting())
    session.load()
    await waitForLoading(session)
    let item = try #require(session.items.first { $0.name == "Dummy.app" })

    session.showPackageContents(item)
    await waitForLoading(session)

    #expect(session.currentLocation == item.location)
  }

  @MainActor
  @Test("非ディレクトリ項目はshowPackageContentsで移動しない")
  func ignoresNonDirectoryItem() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "pkpane-package-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: root.appending(path: "note.app"))
    defer { try? FileManager.default.removeItem(at: root) }

    let provider = LocalFileProvider()
    let session = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: root, providerID: provider.id),
      transferQueue: .isolatedForTesting())
    session.load()
    await waitForLoading(session)
    let initialLocation = session.currentLocation
    let item = try #require(session.items.first { $0.name == "note.app" })

    session.showPackageContents(item)
    await waitForLoading(session)

    #expect(session.currentLocation == initialLocation)
  }

  @MainActor
  private func waitForLoading(_ session: FileBrowserSession) async {
    await waitUntil("isLoadingが期限内にfalseにならなかった") {
      !session.isLoading
    }
  }
}
