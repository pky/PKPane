import Darwin
import Foundation
import Synchronization
import Testing

@testable import PKPane

struct LocalFileProviderTests {
  @Test("コピーと別volume moveは双方の包含をstaging前に拒否して原本を保持する")
  func rejectsOverlappingCopyAndFallbackMoveBeforeStaging() throws {
    for isCopy in [true, false] {
      for toAncestor in [true, false] {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let outer = root.appending(path: "A")
        let middle = outer.appending(path: "B")
        let inner = middle.appending(path: "A")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let leaf = inner.appending(path: "leaf.txt")
        try Data("preserved".utf8).write(to: leaf)
        let stagingCalls = Mutex(0)
        let provider = LocalFileProvider(
          isOnSameVolumeOverride: { _, _ in false },
          crossVolumeMoveCopy: { _, _, _ in stagingCalls.withLock { $0 += 1 } },
          cancellableCopy: { _, _, _, _ in stagingCalls.withLock { $0 += 1 } })
        let source = toAncestor ? inner : outer
        let destination = toAncestor ? root : middle
        #expect(throws: ProviderFileTransferServiceError.self) {
          if isCopy {
            _ = try provider.copy(source, to: destination, replacingExisting: true)
          } else {
            _ = try provider.move(source, to: destination, replacingExisting: true)
          }
        }
        #expect(stagingCalls.withLock { $0 } == 0)
        #expect(try Data(contentsOf: leaf) == Data("preserved".utf8))
      }
    }
  }

  @Test("クラウド外の項目にクラウド状態を問い合わせても空の結果を返す")
  func cloudDownloadStatusesAreEmptyOutsideCloudStorage() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let itemURL = root.appending(path: "report.txt")
    try Data().write(to: itemURL)
    let provider = LocalFileProvider()

    let statuses = await provider.cloudDownloadStatuses(
      itemLocations: [FileLocation(localURL: itemURL)])

    #expect(statuses.isEmpty)
  }

  @Test("存在しない項目のクラウド状態問い合わせは失敗しない")
  func cloudDownloadStatusesIgnoreMissingItems() async {
    let missingURL = FileManager.default.temporaryDirectory
      .appending(path: "missing-\(UUID().uuidString)")
    let provider = LocalFileProvider()

    let statuses = await provider.cloudDownloadStatuses(
      itemLocations: [FileLocation(localURL: missingURL)])

    #expect(statuses.isEmpty)
  }

  @Test("B1: 注入したreaderが未ダウンロードと返した項目はnotDownloadedになる")
  func cloudDownloadStatusesUseInjectedReader() async {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let childURL = root.appending(path: "doc.txt")
    let childPath = childURL.path
    let probe = CloudReadProbe { _, url in
      url.path == childPath ? .notDownloadedFixture : nil
    }
    let provider = LocalFileProvider(cloudStatusReader: CloudStatusResourceReader(read: probe.read))

    let statuses = await provider.cloudDownloadStatuses(
      itemLocations: [FileLocation(localURL: childURL)])

    #expect(statuses == [childURL: .notDownloaded])
  }

  @Test("B2: 親がクラウド管理下なら属性が取れない子はunknownになる")
  func cloudDownloadStatusesTreatChildOfCloudParentAsUnknown() async {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let childURL = root.appending(path: "doc.txt")
    let rootPath = root.path
    let probe = CloudReadProbe { _, url in
      guard url.path == rootPath else { return nil }
      return CloudStatusResourceValues(
        isUbiquitousItem: true, downloadingStatus: nil, isDownloading: nil,
        hasDownloadingError: false)
    }
    let provider = LocalFileProvider(cloudStatusReader: CloudStatusResourceReader(read: probe.read))

    let statuses = await provider.cloudDownloadStatuses(
      itemLocations: [FileLocation(localURL: childURL)])

    #expect(statuses == [childURL: .unknown])
  }

  @Test("B3: readerがdegradedなら問い合わせずに空を返す")
  func cloudDownloadStatusesSkipQueriesWhileReaderIsDegraded() async {
    let gate = DispatchSemaphore(value: 0)
    let probe = CloudReadProbe { _, _ in
      gate.wait()
      return .notDownloadedFixture
    }
    let reader = CloudStatusResourceReader(
      maxConcurrentReads: 2, timeout: .milliseconds(50), read: probe.read)
    defer { gate.signal() }
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    _ = await reader.values(for: root.appending(path: "trigger.txt"))
    #expect(reader.isDegraded)
    let callsBefore = probe.calls
    let provider = LocalFileProvider(cloudStatusReader: reader)

    let statuses = await provider.cloudDownloadStatuses(
      itemLocations: [FileLocation(localURL: root.appending(path: "doc.txt"))])

    #expect(statuses.isEmpty)
    #expect(probe.calls == callsBefore)
  }

  @Test("C1(a): readerがubiquitousと答えたクラウド外ディレクトリはクラウド管理下になる")
  func cloudManagedDirectoryUsesReaderForNonCloudPath() async {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let directoryPath = directory.path
    let probe = CloudReadProbe { _, url in
      url.path == directoryPath ? .notDownloadedFixture : nil
    }
    let provider = LocalFileProvider(cloudStatusReader: CloudStatusResourceReader(read: probe.read))

    let managed = await provider.isCloudManagedDirectory(FileLocation(localURL: directory))

    #expect(managed)
  }

  @Test("C1(b): readerがdegradedならクラウド外ディレクトリはクラウド管理下にしない")
  func cloudManagedDirectoryIsFalseWhileReaderIsDegraded() async {
    let gate = DispatchSemaphore(value: 0)
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let directoryPath = directory.path
    let probe = CloudReadProbe { index, url in
      if index == 1 {
        gate.wait()
        return nil
      }
      return url.path == directoryPath ? .notDownloadedFixture : nil
    }
    let reader = CloudStatusResourceReader(
      maxConcurrentReads: 2, timeout: .milliseconds(50), read: probe.read)
    defer { gate.signal() }
    _ = await reader.values(for: directory.appending(path: "trigger.txt"))
    #expect(reader.isDegraded)
    let provider = LocalFileProvider(cloudStatusReader: reader)

    let managed = await provider.isCloudManagedDirectory(FileLocation(localURL: directory))

    #expect(!managed)
  }

  @Test("C1(c): クラウドルート配下はパス判定だけで真になりreaderを呼ばない")
  func cloudManagedDirectoryUnderCloudRootSkipsReader() async {
    let directory = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "Library/Mobile Documents/com.example.app", directoryHint: .isDirectory)
    let probe = CloudReadProbe { _, _ in nil }
    let provider = LocalFileProvider(cloudStatusReader: CloudStatusResourceReader(read: probe.read))

    let managed = await provider.isCloudManagedDirectory(FileLocation(localURL: directory))

    #expect(managed)
    #expect(probe.calls == 0)
  }

  @Test("新規フォルダを作成する")
  func createsDirectory() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let folder = try LocalFileProvider().createDirectory(named: "新規フォルダ", in: root)
    #expect(FileManager.default.fileExists(atPath: folder.path))
  }

  @Test("項目をリネームする")
  func renamesItem() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appending(path: "before.txt")
    FileManager.default.createFile(atPath: source.path, contents: Data())
    let renamed = try LocalFileProvider().rename(source, to: "after.txt")
    #expect(FileManager.default.fileExists(atPath: renamed.path))
  }

  @Test("項目を別フォルダへコピーして移動する")
  func copiesAndMovesItem() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appending(path: "destination", directoryHint: .isDirectory)
    let moved = root.appending(path: "moved", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
    let source = root.appending(path: "source.txt")
    FileManager.default.createFile(atPath: source.path, contents: Data())
    let provider = LocalFileProvider()
    try provider.copy(source, to: destination)
    #expect(FileManager.default.fileExists(atPath: destination.appending(path: "source.txt").path))
    try provider.move(source, to: moved)
    #expect(FileManager.default.fileExists(atPath: moved.appending(path: "source.txt").path))
  }

  @Test("異ボリューム移動でコピーが破損した場合は元を消さず検証失敗にする")
  func failsRetryablyAndKeepsSourceWhenCrossVolumeMoveCopyIsTruncated() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let source = root.appending(path: "report.txt")
    let content = Data(repeating: 0x41, count: 1_000)
    try content.write(to: source)

    let provider = LocalFileProvider(
      isOnSameVolumeOverride: { _, _ in false },
      crossVolumeMoveCopy: { sourceURL, destinationURL, _ in
        // 実際のコピーバイト数より少なく永続化することで、破損(切り詰め)を再現する。
        let truncated = try Data(contentsOf: sourceURL).prefix(900)
        try Data(truncated).write(to: destinationURL)
      })

    #expect(throws: TransferVerificationError.self) {
      try provider.move(source, to: destination)
    }
    #expect(FileManager.default.fileExists(atPath: source.path))
    #expect(!FileManager.default.fileExists(atPath: destination.appending(path: "report.txt").path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
  }

  @Test("上書きコピー失敗時は既存宛先をコピー中も完了後も保持する")
  func replacingCopyFailureKeepsExistingDestination() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let destinationDirectory = root.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: destinationDirectory, withIntermediateDirectories: true)
    let source = root.appending(path: "report.txt")
    let destination = destinationDirectory.appending(path: "report.txt")
    try Data("新しい内容".utf8).write(to: source)
    try Data("既存内容".utf8).write(to: destination)
    let keptDuringCopy = Mutex(false)
    let provider = LocalFileProvider(
      cancellableCopy: { _, temporaryURL, _, _ in
        keptDuringCopy.withLock {
          $0 = (try? Data(contentsOf: destination)) == Data("既存内容".utf8)
        }
        try Data("途中内容".utf8).write(to: temporaryURL)
        throw CocoaError(.fileWriteUnknown)
      })

    #expect(throws: CocoaError.self) {
      try provider.copy(source, to: destinationDirectory, replacingExisting: true)
    }

    #expect(keptDuringCopy.withLock { $0 })
    #expect(try Data(contentsOf: destination) == Data("既存内容".utf8))
    #expect(try Data(contentsOf: source) == Data("新しい内容".utf8))
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: destinationDirectory.path)
        == ["report.txt"])
  }

  @Test("異ボリューム上書き移動のキャンセル時は既存宛先と移動元を保持する")
  func replacingCrossVolumeMoveCancellationKeepsExistingDestinationAndSource() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let destinationDirectory = root.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: destinationDirectory, withIntermediateDirectories: true)
    let source = root.appending(path: "report.txt")
    let destination = destinationDirectory.appending(path: "report.txt")
    try Data("新しい内容".utf8).write(to: source)
    try Data("既存内容".utf8).write(to: destination)
    let keptDuringCopy = Mutex(false)
    let provider = LocalFileProvider(
      isOnSameVolumeOverride: { _, _ in false },
      crossVolumeMoveCopy: { _, temporaryURL, _ in
        keptDuringCopy.withLock {
          $0 = (try? Data(contentsOf: destination)) == Data("既存内容".utf8)
        }
        try Data("途中内容".utf8).write(to: temporaryURL)
        throw CancellationError()
      })

    #expect(throws: CancellationError.self) {
      try provider.move(source, to: destinationDirectory, replacingExisting: true)
    }

    #expect(keptDuringCopy.withLock { $0 })
    #expect(try Data(contentsOf: destination) == Data("既存内容".utf8))
    #expect(try Data(contentsOf: source) == Data("新しい内容".utf8))
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: destinationDirectory.path)
        == ["report.txt"])
  }

  @Test("本物のLocalFileProviderは転送中キャンセルでファイル途中に停止する")
  func realProviderStopsFileCopyMidwayWhenCancelled() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let destinationDirectory = root.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: destinationDirectory, withIntermediateDirectories: true)
    let source = root.appending(path: "source.bin")
    let totalBytes = 8 * 1_024 * 1_024
    try Data(repeating: 0x6A, count: totalBytes).write(to: source)
    let limiter = TransferRateLimiter(bytesPerSecond: 4 * 1_024 * 1_024)
    let provider = LocalFileProvider(
      cancellableCopy: { sourceURL, destinationURL, isCancelled, progress in
        try CancellableFileCopier.copy(
          from: sourceURL,
          to: destinationURL,
          isCancelled: isCancelled,
          progress: progress,
          cloneAttempt: { _, _ in false },
          copyfileAttempt: { _, _ in false },
          rateLimiter: limiter)
      })
    let item = try provider.item(at: source)
    let completedBytes = Mutex<Int64>(0)
    let task = Task {
      try await (provider as any FileBrowserProgressTransferProvider).copy(
        item,
        to: FileLocation(localURL: destinationDirectory)
      ) { value in
        completedBytes.withLock { $0 = value }
      }
    }

    await waitUntil("転送の進捗が期限内に検出できなかった") {
      completedBytes.withLock { $0 } != 0
    }
    #expect(completedBytes.withLock { $0 } > 0)
    task.cancel()
    do {
      try await task.value
      Issue.record("キャンセルしたコピーが完了してしまいました")
    } catch is CancellationError {
      // 期待どおり。
    }

    #expect(completedBytes.withLock { $0 } < Int64(totalBytes))
    #expect(
      !FileManager.default.fileExists(
        atPath: destinationDirectory.appending(path: "source.bin").path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: destinationDirectory.path).isEmpty)
  }

  @MainActor
  @Test("実LocalFileProviderの転送を一時停止して一時名を残さず再開できる")
  func realProviderPausesAndResumesMultipleFileTransfer() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceDirectory = root.appending(path: "source", directoryHint: .isDirectory)
    let destinationDirectory = root.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: sourceDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: destinationDirectory, withIntermediateDirectories: true)
    let contents: [(name: String, data: Data)] = [
      ("a.bin", Data(repeating: 0x61, count: 64 * 1_024)),
      ("b.bin", Data(repeating: 0x62, count: 2 * 1_024 * 1_024)),
      ("c.bin", Data(repeating: 0x63, count: 64 * 1_024)),
    ]
    for content in contents {
      try content.data.write(to: sourceDirectory.appending(path: content.name))
    }

    let pauseGate = LocalTransferPauseGate()
    defer { pauseGate.release() }
    let limiter = TransferRateLimiter()
    let provider = LocalFileProvider(
      cancellableCopy: { sourceURL, destinationURL, isCancelled, progress in
        try CancellableFileCopier.copy(
          from: sourceURL,
          to: destinationURL,
          isCancelled: isCancelled,
          progress: { completedBytes in
            progress?(completedBytes)
            if sourceURL.lastPathComponent == "b.bin", completedBytes == 1_024 * 1_024 {
              // コピー専用GCDスレッドだけを止め、主タスクの停止要求を待つ。
              pauseGate.waitOnFirstProgress()
            }
          },
          cloneAttempt: { _, _ in false },
          copyfileAttempt: { _, _ in false },
          rateLimiter: limiter)
      })
    let queue = TransferQueue(store: InMemoryTransferJobStore(), maximumConcurrentTransfers: 1)
    let source = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: sourceDirectory, providerID: provider.id),
      transferQueue: queue)
    let destination = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: destinationDirectory, providerID: provider.id),
      transferQueue: queue)
    source.load()
    destination.load()
    await waitForLoading(source)
    await waitForLoading(destination)

    source.copy(source.items, to: destination)
    let jobID = try #require(await waitForFirstJob(in: queue)?.id)
    let partialCopyObserved = await waitForPartialStagingFile(
      in: destinationDirectory,
      fileName: contents[1].name,
      expectedFileBytes: Int64(contents[1].data.count))
    #expect(partialCopyObserved)
    #expect(
      FileManager.default.fileExists(
        atPath: destinationDirectory.appending(path: "a.bin").path))

    await queue.pause(jobID)
    pauseGate.release()
    let paused = try #require(await waitForJobState(.paused, jobID: jobID, in: queue))
    let namesAfterPause = try FileManager.default.contentsOfDirectory(
      at: destinationDirectory,
      includingPropertiesForKeys: nil
    ).map(\.lastPathComponent)

    #expect(paused.completedItems.map(\.name) == ["a.bin"])
    #expect(namesAfterPause == ["a.bin"])
    #expect(!namesAfterPause.contains(where: isTransferStagingName))

    #expect(source.resumeTransfer(jobID))
    let completed = try #require(await waitForJobState(.completed, jobID: jobID, in: queue))
    let finalNames = try FileManager.default.contentsOfDirectory(
      at: destinationDirectory,
      includingPropertiesForKeys: nil
    ).map(\.lastPathComponent).sorted()

    #expect(finalNames == contents.map(\.name))
    #expect(!finalNames.contains(where: isTransferStagingName))
    #expect(completed.completedBytes == Int64(contents.reduce(0) { $0 + $1.data.count }))
    for content in contents {
      #expect(
        try Data(contentsOf: destinationDirectory.appending(path: content.name)) == content.data)
    }
  }

  @MainActor
  private func waitForLoading(_ session: FileBrowserSession) async {
    await waitUntil("isLoadingが期限内にfalseにならなかった") {
      !session.isLoading
    }
  }

  private func waitForFirstJob(in queue: TransferQueue) async -> TransferJob? {
    var result: TransferJob?
    await waitUntil("最初のジョブが期限内にキューに現れなかった") {
      result = await queue.allJobs().first
      return result != nil
    }
    return result
  }

  private func waitForJobState(
    _ state: TransferJob.State,
    jobID: UUID,
    in queue: TransferQueue
  ) async -> TransferJob? {
    var result: TransferJob?
    await waitUntil(timeout: .seconds(10), "ジョブが期限内に指定状態にならなかった") {
      guard let job = await queue.allJobs().first(where: { $0.id == jobID }), job.state == state
      else {
        return false
      }
      result = job
      return true
    }
    return result
  }

  private func waitForPartialStagingFile(
    in directory: URL,
    fileName: String,
    expectedFileBytes: Int64
  ) async -> Bool {
    await waitUntil(timeout: .seconds(5), "部分ステージングファイルが期限内に検出できなかった") {
      let stagingURLs =
        (try? FileManager.default.contentsOfDirectory(
          at: directory,
          includingPropertiesForKeys: [.fileSizeKey]))?.filter {
          $0.lastPathComponent.hasPrefix(".\(fileName).")
            && isTransferStagingName($0.lastPathComponent)
        } ?? []
      for url in stagingURLs {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        if let fileSize = values?.fileSize.map(Int64.init), fileSize > 0,
          fileSize < expectedFileBytes
        {
          return true
        }
      }
      return false
    }
  }

  private func isTransferStagingName(_ name: String) -> Bool {
    name.contains(".pkpane-copy-") || name.contains(".pkpane-transfer-")
  }

  @Test("複製した項目は「(名前)のコピー」になる")
  func duplicatesItemUsingCopySuffix() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appending(path: "report.txt")
    FileManager.default.createFile(atPath: source.path, contents: Data("内容".utf8))

    let duplicated = try LocalFileProvider().duplicate(source)

    #expect(duplicated.lastPathComponent == "reportのコピー.txt")
    #expect(try Data(contentsOf: duplicated) == Data("内容".utf8))
    #expect(FileManager.default.fileExists(atPath: source.path))
  }

  @Test("同じフォルダ内に重複しない名前で複製する(命名衝突は連番で解決)")
  func duplicatesItemWithAvailableNameOnCollision() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appending(path: "report.txt")
    FileManager.default.createFile(atPath: source.path, contents: Data("内容".utf8))
    FileManager.default.createFile(
      atPath: root.appending(path: "reportのコピー.txt").path,
      contents: Data())
    FileManager.default.createFile(
      atPath: root.appending(path: "reportのコピー2.txt").path,
      contents: Data())

    let duplicated = try LocalFileProvider().duplicate(source)

    #expect(duplicated.lastPathComponent == "reportのコピー3.txt")
    #expect(try Data(contentsOf: duplicated) == Data("内容".utf8))
  }

  @Test("拡張子のない項目も「のコピー」で複製できる")
  func duplicatesExtensionlessItem() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appending(path: "README")
    FileManager.default.createFile(atPath: source.path, contents: Data())

    let duplicated = try LocalFileProvider().duplicate(source)

    #expect(duplicated.lastPathComponent == "READMEのコピー")
  }

  @Test("FileBrowserDuplicateProvider経由でもFileItemを複製できる")
  func duplicatesFileItemThroughProviderProtocol() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appending(path: "report.txt")
    FileManager.default.createFile(atPath: source.path, contents: Data())
    let provider = LocalFileProvider()
    let item = try provider.item(at: source)

    try await (provider as any FileBrowserDuplicateProvider).duplicate(item)

    #expect(FileManager.default.fileExists(atPath: root.appending(path: "reportのコピー.txt").path))
  }

  @Test("隠しファイルの表示を切り替える")
  func includesHiddenFilesOnRequest() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    FileManager.default.createFile(
      atPath: root.appending(path: ".hidden.txt").path,
      contents: Data())
    FileManager.default.createFile(
      atPath: root.appending(path: "visible.txt").path,
      contents: Data())

    let provider = LocalFileProvider()

    #expect(try provider.contents(of: root).map(\.name) == ["visible.txt"])
    #expect(
      try provider.contents(of: root, includingHidden: true).map(\.name) == [
        ".hidden.txt", "visible.txt",
      ])
  }

  @Test("シンボリックリンクを識別して相対リンク先を解決する")
  func identifiesAndResolvesSymbolicLink() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let destination = root.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    let link = root.appending(path: "destination-link", directoryHint: .notDirectory)
    try FileManager.default.createSymbolicLink(
      atPath: link.path,
      withDestinationPath: "destination")

    let provider = LocalFileProvider()
    let item = try provider.item(at: link)

    #expect(item.isSymbolicLink)
    #expect(!item.isAliasFile)
    #expect(item.kindDisplayName == "シンボリックリンク")
    #expect(try provider.originalURL(for: link) == destination.standardizedFileURL)
  }

  @Test("項目詳細に必要な作成日とPOSIX権限を取得する")
  func readsDetailMetadata() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appending(path: "report.txt")
    FileManager.default.createFile(atPath: file.path, contents: Data())
    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)

    let item = try LocalFileProvider().item(at: file)

    #expect(item.createdAt != nil)
    #expect(item.displayPermissions == "0640")
    #expect(item.ownerName != nil)
    #expect(item.groupName != nil)
  }

  @Test("POSIX権限を変更して対象1件の詳細へ反映する")
  func setsPosixPermissions() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appending(path: "permissions.txt")
    FileManager.default.createFile(atPath: file.path, contents: Data())
    let provider = LocalFileProvider()
    let location = FileLocation(localURL: file, providerID: provider.id)

    try await provider.setPosixPermissions(0o640, at: location)
    let item = try await provider.detailedItem(at: location)

    #expect(item.posixPermissions.map(PosixPermissions.normalizedMode(_:)) == 0o640)
  }

  @Test("Finderタグ名をURLResourceValuesへ書き込む")
  func setsFinderTagNames() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appending(path: "tags.txt")
    FileManager.default.createFile(atPath: file.path, contents: Data())
    let provider = LocalFileProvider()
    let location = FileLocation(localURL: file, providerID: provider.id)

    try await provider.setFinderTagNames(["Red", "確認"], at: location)
    let item = try await provider.detailedItem(at: location)

    #expect(Set(item.tags ?? []) == ["Red", "確認"])
  }

  @Test(".contentHash検証強度のフックが正しいSHA-256を返す")
  func computesCorrectContentHash() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appending(path: "report.txt")
    try Data("hello".utf8).write(to: file)
    // "hello"の既知のSHA-256値(https://en.wikipedia.org/wiki/SHA-2 等で検証可能)。
    let expectedHex =
      "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"

    let hash = try await LocalFileProvider().contentHash(
      at: FileLocation(localURL: file))

    #expect(hash.map { String(format: "%02x", $0) }.joined() == expectedHex)
  }

  @Test("一覧取得では詳細メタデータを読まない")
  func omitsDetailMetadataWhenListing() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appending(path: "report.txt")
    FileManager.default.createFile(atPath: file.path, contents: Data())

    let item = try #require(LocalFileProvider().contents(of: root).first)

    #expect(item.createdAt == nil)
    #expect(item.tags == nil)
    #expect(item.posixPermissions == nil)
  }

  @Test("隠し項目を含む一覧を小さな単位で列挙する")
  func streamsHiddenItemsInBatches() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for index in 0..<5 {
      FileManager.default.createFile(
        atPath: root.appending(path: ".hidden-\(index).txt").path,
        contents: Data())
    }

    let provider = LocalFileProvider()
    let location = FileLocation(localURL: root, providerID: provider.id)
    var batches = [[FileItem]]()
    for try await batch in provider.contentsStream(
      of: location,
      includingHidden: true,
      batchSize: 2)
    {
      batches.append(batch)
    }

    #expect(batches.map(\.count) == [2, 2, 1])
    #expect(batches.flatMap { $0 }.map(\.name).count == 5)
    #expect(batches.flatMap { $0 }.allSatisfy { $0.name.hasPrefix(".") })
    // getattrlistbulk化により、ローカルボリュームではsize/modifiedAtも列挙と同時に取得される。
    #expect(batches.flatMap { $0 }.allSatisfy { $0.size == 0 && $0.modifiedAt != nil })
  }

  @Test("隠し項目の高速列挙でもフォルダ種別を保持する")
  func preservesDirectoryTypeWhenStreamingHiddenItems() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let folder = root.appending(path: ".hidden-folder", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    let provider = LocalFileProvider()
    let location = FileLocation(localURL: root, providerID: provider.id)
    var items = [FileItem]()

    for try await batch in provider.contentsStream(
      of: location,
      includingHidden: true,
      batchSize: 256)
    {
      items.append(contentsOf: batch)
    }

    #expect(items.count == 1)
    #expect(items.first?.name == ".hidden-folder")
    #expect(items.first?.isDirectory == true)
  }

  @Test("通常表示も高速列挙を使い隠し項目だけ除外する")
  func streamsVisibleItemsWithoutHiddenItems() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    FileManager.default.createFile(
      atPath: root.appending(path: ".hidden.txt").path,
      contents: Data())
    FileManager.default.createFile(
      atPath: root.appending(path: "visible.txt").path,
      contents: Data())
    let provider = LocalFileProvider()
    let location = FileLocation(localURL: root, providerID: provider.id)
    var items = [FileItem]()

    for try await batch in provider.contentsStream(
      of: location,
      includingHidden: false,
      batchSize: 256)
    {
      items.append(contentsOf: batch)
    }

    #expect(items.map(\.name) == ["visible.txt"])
  }

  @Test("高速列挙(getattrlistbulk)で実サイズと更新日時が一致する")
  func streamingListingReportsAccurateSizeAndModifiedDate() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appending(path: "report.txt")
    FileManager.default.createFile(atPath: file.path, contents: Data("12345".utf8))
    let expectedModifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
    try FileManager.default.setAttributes(
      [.modificationDate: expectedModifiedAt], ofItemAtPath: file.path)
    let folder = root.appending(path: "subfolder", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)

    let provider = LocalFileProvider()
    let location = FileLocation(localURL: root, providerID: provider.id)
    var items = [FileItem]()
    for try await batch in provider.contentsStream(
      of: location, includingHidden: false, batchSize: 256)
    {
      items.append(contentsOf: batch)
    }

    let fileItem = try #require(items.first { $0.name == "report.txt" })
    #expect(fileItem.isDirectory == false)
    #expect(fileItem.size == 5)
    #expect(
      try #require(fileItem.modifiedAt).timeIntervalSince1970
        == expectedModifiedAt
        .timeIntervalSince1970)

    let folderItem = try #require(items.first { $0.name == "subfolder" })
    #expect(folderItem.isDirectory)
  }

  @Test("getattrlistbulkのERRORエントリでも以降のフィールドを正しい位置から読む")
  func parsesEntryWithAttributeErrorWithoutOffsetCorruption() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let name = "sample.txt"
    // ATTR_CMN_ERROR発生時にOBJTYPEを信用せずresourceValuesへフォールバックすることを
    // 検証するため、合成バッファ側は実体(通常ファイル)と矛盾するディレクトリを騙る
    // OBJTYPEにしておく。
    FileManager.default.createFile(atPath: root.appending(path: name).path, contents: Data())

    // オフセット計算はLocalFileProvider.parseGetattrlistbulkEntriesの実装(ERROR→NAME→
    // OBJTYPE→MODTIME→DATALENGTHの順、man getattrlistbulk(2)どおりERRORがattribute_set_t
    // の直後)と一致させる。
    let attributeSetStart = 4
    let errorOffset = attributeSetStart + 20
    let nameReferenceOffset = errorOffset + 4
    let objectTypeOffset = nameReferenceOffset + 8
    let modifiedAtOffset = objectTypeOffset + 4
    let sizeOffset = modifiedAtOffset + MemoryLayout<timespec>.size
    let nameBytesStart = sizeOffset + 8

    let nameBytes = Array(name.utf8) + [0]  // 終端NUL込み
    let unpaddedLength = nameBytesStart + nameBytes.count
    let entryLength = (unpaddedLength + 3) & ~3  // 4byte境界へパディング

    // ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME | ATTR_CMN_ERROR
    let commonAttr: UInt32 = 0x8000_0000 | 0x0000_0001 | 0x0000_0008 | 0x0000_0400 | 0x2000_0000
    let fileAttr: UInt32 = 0x0000_0200  // ATTR_FILE_DATALENGTH

    var buffer = [UInt8](repeating: 0, count: entryLength)
    buffer.withUnsafeMutableBytes { raw in
      raw.storeBytes(of: UInt32(entryLength), toByteOffset: 0, as: UInt32.self)
      raw.storeBytes(of: commonAttr, toByteOffset: attributeSetStart, as: UInt32.self)
      raw.storeBytes(of: fileAttr, toByteOffset: attributeSetStart + 12, as: UInt32.self)
      raw.storeBytes(of: Int32(1), toByteOffset: errorOffset, as: Int32.self)  // 非ゼロのエラーコード
      raw.storeBytes(
        of: Int32(nameBytesStart - nameReferenceOffset), toByteOffset: nameReferenceOffset,
        as: Int32.self)
      raw.storeBytes(
        of: UInt32(nameBytes.count), toByteOffset: nameReferenceOffset + 4, as: UInt32.self)
      raw.storeBytes(of: UInt32(2), toByteOffset: objectTypeOffset, as: UInt32.self)  // VDIR(偽の値)
      raw.storeBytes(
        of: timespec(tv_sec: 0, tv_nsec: 0), toByteOffset: modifiedAtOffset, as: timespec.self)
      raw.storeBytes(of: UInt64(999), toByteOffset: sizeOffset, as: UInt64.self)  // 未使用の偽の値
      for (index, byte) in nameBytes.enumerated() {
        raw.storeBytes(of: byte, toByteOffset: nameBytesStart + index, as: UInt8.self)
      }
    }

    let items = try buffer.withUnsafeBytes { raw in
      try LocalFileProvider.parseGetattrlistbulkEntries(
        raw, entryCount: 1, directoryURL: root, includingHidden: false)
    }

    let item = try #require(items.first)
    // ERRORフィールド混入による4byteずれで名前が文字化けしていないことを確認する。
    #expect(item.name == name)
    // OBJTYPEがディレクトリを騙っていても、ATTR_CMN_ERROR発生エントリはresourceValues
    // フォールバックへ確実に倒され、実体(通常ファイル)どおりisDirectory=falseになる。
    #expect(item.isDirectory == false)
  }

  @Test("非ローカルボリューム判定ではreaddir経路にフォールバックする")
  func fallsBackToReaddirForNonLocalVolume() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    FileManager.default.createFile(
      atPath: root.appending(path: "report.txt").path,
      contents: Data("12345".utf8))

    let provider = LocalFileProvider(isLocalVolume: { _ in false })
    let location = FileLocation(localURL: root, providerID: provider.id)
    var items = [FileItem]()
    for try await batch in provider.contentsStream(
      of: location, includingHidden: false, batchSize: 256)
    {
      items.append(contentsOf: batch)
    }

    let item = try #require(items.first { $0.name == "report.txt" })
    // readdir経路は属性を同時取得しないため、size/modifiedAtは取得できない。
    #expect(item.size == nil)
    #expect(item.modifiedAt == nil)
  }

  @Test("確認済みの場合だけ同名項目を置換してコピーする")
  func copiesReplacingExistingItemWhenAllowed() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let source = root.appending(path: "report.txt")
    FileManager.default.createFile(atPath: source.path, contents: Data("新しい内容".utf8))
    let existing = destination.appending(path: "report.txt")
    FileManager.default.createFile(atPath: existing.path, contents: Data("古い内容".utf8))

    try LocalFileProvider().copy(source, to: destination, replacingExisting: true)

    #expect(try Data(contentsOf: existing) == Data("新しい内容".utf8))
  }

  @Test("Local Provider移動は置換ありで既存ファイルを上書きする")
  func moveWithReplacingOverwritesExistingFile() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceDirectory = root.appending(path: "source", directoryHint: .isDirectory)
    let destinationDirectory = root.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: sourceDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: destinationDirectory, withIntermediateDirectories: true)
    let sourceURL = sourceDirectory.appending(path: "report.txt")
    let destinationURL = destinationDirectory.appending(path: "report.txt")
    try Data("新しい内容".utf8).write(to: sourceURL)
    try Data("既存内容".utf8).write(to: destinationURL)
    let provider = LocalFileProvider()
    let item = FileItem(
      url: sourceURL,
      providerID: provider.id,
      isDirectory: false)

    try await provider.move(
      item,
      to: FileLocation(localURL: destinationDirectory, providerID: provider.id),
      replacingExisting: true)

    #expect(!FileManager.default.fileExists(atPath: sourceURL.path))
    #expect(try Data(contentsOf: destinationURL) == Data("新しい内容".utf8))
  }

  @Test("Local Provider移動は置換なしで既存ファイルを拒否する")
  func moveWithoutReplacingRejectsExistingFile() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceDirectory = root.appending(path: "source", directoryHint: .isDirectory)
    let destinationDirectory = root.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: sourceDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: destinationDirectory, withIntermediateDirectories: true)
    let sourceURL = sourceDirectory.appending(path: "report.txt")
    let destinationURL = destinationDirectory.appending(path: "report.txt")
    try Data("新しい内容".utf8).write(to: sourceURL)
    try Data("既存内容".utf8).write(to: destinationURL)
    let provider = LocalFileProvider()
    let item = FileItem(
      url: sourceURL,
      providerID: provider.id,
      isDirectory: false)
    var thrownError: (any Error)?

    do {
      try await provider.move(
        item,
        to: FileLocation(localURL: destinationDirectory, providerID: provider.id),
        replacingExisting: false)
    } catch {
      thrownError = error
    }

    #expect((thrownError as? CocoaError)?.code == .fileWriteFileExists)
    #expect(try Data(contentsOf: sourceURL) == Data("新しい内容".utf8))
    #expect(try Data(contentsOf: destinationURL) == Data("既存内容".utf8))
  }

  @Test("同名フォルダがある場合は別名で作成する")
  func createsDirectoryWithAvailableName() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: root.appending(path: "新規フォルダ", directoryHint: .isDirectory),
      withIntermediateDirectories: false)

    let created = try LocalFileProvider().createDirectory(named: "新規フォルダ", in: root)

    #expect(created.lastPathComponent == "新規フォルダ 2")
  }

  @Test("確認済みの場合だけ同名項目を置換してリネームする")
  func renamesReplacingExistingItemWhenAllowed() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appending(path: "before.txt")
    FileManager.default.createFile(atPath: source.path, contents: Data("新しい内容".utf8))
    let existing = root.appending(path: "after.txt")
    FileManager.default.createFile(atPath: existing.path, contents: Data("古い内容".utf8))

    let renamed = try LocalFileProvider().rename(source, to: "after.txt", replacingExisting: true)

    #expect(renamed == existing)
    #expect(try Data(contentsOf: existing) == Data("新しい内容".utf8))
  }

  @Test("コピーは一時名を残さず最終名だけを作る")
  func copyLeavesNoTemporaryArtifacts() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let destinationDirectory = root.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: destinationDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = root.appending(path: "report.txt")
    FileManager.default.createFile(atPath: sourceURL.path, contents: Data("abc".utf8))

    _ = try LocalFileProvider().copy(sourceURL, to: destinationDirectory)

    let contents = try FileManager.default.contentsOfDirectory(atPath: destinationDirectory.path)
    #expect(contents == ["report.txt"])
    #expect(!contents.contains { $0.contains("pkpane-copy") })
  }

  @Test("コピー失敗時は一時ファイルも最終名も残さない")
  func failedCopyCleansUpTemporaryFile() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let destinationDirectory = root.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: destinationDirectory, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: destinationDirectory.path)
      try? FileManager.default.removeItem(at: root)
    }
    let sourceURL = root.appending(path: "report.txt")
    FileManager.default.createFile(atPath: sourceURL.path, contents: Data("abc".utf8))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o500], ofItemAtPath: destinationDirectory.path)

    #expect(throws: Error.self) {
      _ = try LocalFileProvider().copy(sourceURL, to: destinationDirectory)
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: destinationDirectory.path)
    let contents = try FileManager.default.contentsOfDirectory(atPath: destinationDirectory.path)
    #expect(contents.isEmpty)
  }

  @Test("/Applicationsと/Applications/Utilitiesだけがシステム側とのマージ対象と判定される")
  func identifiesApplicationsMergeOverlay() {
    #expect(
      LocalFileProvider.applicationsMergeOverlay(
        for: URL(fileURLWithPath: "/Applications", isDirectory: true))
        == URL(fileURLWithPath: "/System/Applications", isDirectory: true).standardizedFileURL)
    #expect(
      LocalFileProvider.applicationsMergeOverlay(
        for: URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true))
        == URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true)
        .standardizedFileURL)
    #expect(
      LocalFileProvider.applicationsMergeOverlay(
        for: URL(fileURLWithPath: "/Applications/Xcode.app", isDirectory: true)) == nil)
    #expect(
      LocalFileProvider.applicationsMergeOverlay(
        for: URL(fileURLWithPath: "/Users/tester/Documents", isDirectory: true)) == nil)
  }

  @Test("マージは重複名をローカル側優先で除き名前順にする")
  func mergesApplicationsPreferringLocalOnNameConflict() {
    let primary = [
      FileItem(url: URL(filePath: "/Applications/Xcode.app"), isDirectory: true),
      FileItem(url: URL(filePath: "/Applications/Safari.app"), isDirectory: true),
    ]
    let overlay = [
      FileItem(url: URL(filePath: "/System/Applications/App Store.app"), isDirectory: true),
      // ローカル側と同名。ローカル側(primary)が優先され、overlay側は捨てられる。
      FileItem(url: URL(filePath: "/System/Applications/Safari.app"), isDirectory: true),
    ]

    let merged = LocalFileProvider.mergingApplications(primary: primary, overlay: overlay)

    #expect(merged.map(\.name) == ["App Store.app", "Safari.app", "Xcode.app"])
    #expect(merged.first { $0.name == "Safari.app" }?.url == primary[1].url)
  }

  @Test("/Applicationsの列挙にはSystem/Applications由来の項目が含まれる")
  func mergesSystemApplicationsIntoApplicationsListing() async throws {
    let provider = LocalFileProvider()
    let location = FileLocation(
      localURL: URL(fileURLWithPath: "/Applications", isDirectory: true), providerID: provider.id)
    var items = [FileItem]()
    for try await batch in provider.contentsStream(
      of: location, includingHidden: false, batchSize: 256)
    {
      items.append(contentsOf: batch)
    }

    // App Store.appは/System/Applications配下にのみ実体があり安定して存在するため、
    // /Applicationsの列挙結果に含まれていればマージが機能している証拠になる。
    #expect(items.contains { $0.name == "App Store.app" })
  }
}

/// 最初の途中進捗だけでコピー専用スレッドを待たせる。再開時の進捗は止めない。
private final class LocalTransferPauseGate: @unchecked Sendable {
  private let condition = NSCondition()
  private var hasWaited = false
  private var isReleased = false

  func waitOnFirstProgress() {
    condition.lock()
    defer { condition.unlock() }
    guard !hasWaited else { return }
    hasWaited = true
    while !isReleased {
      condition.wait()
    }
  }

  func release() {
    condition.lock()
    isReleased = true
    condition.broadcast()
    condition.unlock()
  }
}
