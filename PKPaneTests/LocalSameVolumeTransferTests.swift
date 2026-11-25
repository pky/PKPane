import Foundation
import Testing

@testable import PKPane

struct LocalSameVolumeTransferTests {
  @MainActor
  @Test(
    "ブラウザからキューに入るローカル移動だけが同一ボリューム移動と記録される",
    arguments: [TransferJob.Kind.move, .copy])
  func browserSessionRecordsLocalSameVolumeMoveFlag(kind: TransferJob.Kind) async throws {
    let queue = TransferQueue.isolatedForTesting()
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? fileManager.removeItem(at: root) }
    let source = root.appending(path: "source", directoryHint: .isDirectory)
    let destination = root.appending(path: "destination", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: source, withIntermediateDirectories: false)
    try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
    let fileURL = source.appending(path: "report.txt")
    let data = Data("転送元".utf8)
    try data.write(to: fileURL)

    let suiteName = "LocalSameVolumeTransferTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let preferences = GitStatusPreferencesStore(defaults: defaults)
    let provider = LocalFileProvider()
    let sourceSession = FileBrowserSession(
      provider: provider, initialLocation: FileLocation(localURL: source),
      transferQueue: queue, gitStatusPreferences: preferences, startsBrowsing: false)
    let destinationSession = FileBrowserSession(
      provider: provider, initialLocation: FileLocation(localURL: destination),
      transferQueue: queue, gitStatusPreferences: preferences, startsBrowsing: false)
    let item = FileItem(url: fileURL, isDirectory: false, size: Int64(data.count))

    switch kind {
    case .move: sourceSession.move([item], to: destinationSession)
    case .copy: sourceSession.copy([item], to: destinationSession)
    }

    await waitUntil("転送ジョブが期限内にキューに入らなかった") {
      !(await queue.allJobs()).isEmpty
    }
    let job = try #require(await queue.allJobs().first)
    #expect(job.kind == kind)
    #expect(job.isLocalSameVolumeMove == (kind == .move))

    await waitUntil("転送ジョブが一時フォルダの後始末前に終了しなかった") {
      await queue.allJobs().first?.state.isTerminal == true
    }
  }

  @Test("元の親に書き込めない置換移動は元と既存宛先を保持する", arguments: [false, true])
  func failedReplacementPreservesBothItemsWhenSourceParentIsReadOnly(isDirectory: Bool) throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
    let sourceDirectory = root.appending(path: "source")
    let destinationDirectory = root.appending(path: "destination")
    try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
    defer {
      try? fileManager.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: sourceDirectory.path)
      try? fileManager.removeItem(at: root)
    }
    let sourceURL = sourceDirectory.appending(path: "report")
    let destinationURL = destinationDirectory.appending(path: "report")
    if isDirectory {
      try fileManager.createDirectory(at: sourceURL, withIntermediateDirectories: false)
      try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: false)
    }
    let sourceContent = isDirectory ? sourceURL.appending(path: "new.txt") : sourceURL
    let destinationContent =
      isDirectory ? destinationURL.appending(path: "old.txt") : destinationURL
    let newBytes = Data("移動する内容".utf8)
    let oldBytes = Data("保持すべき既存内容".utf8)
    try newBytes.write(to: sourceContent)
    try oldBytes.write(to: destinationContent)
    let item = FileItem(url: sourceURL, isDirectory: isDirectory)
    let destination = FileLocation(localURL: destinationDirectory)
    try #require(LocalSameVolumeTransfer.canMove(item, toDirectory: destination))
    try fileManager.setAttributes(
      [.posixPermissions: 0o555], ofItemAtPath: sourceDirectory.path)
    try #require(!fileManager.isWritableFile(atPath: sourceDirectory.path))
    try #require(fileManager.isWritableFile(atPath: destinationDirectory.path))

    #expect(throws: (any Error).self) {
      try LocalSameVolumeTransfer.move(item, toDirectory: destination, replacingExisting: true)
    }

    #expect(try Data(contentsOf: sourceContent) == newBytes)
    #expect(try Data(contentsOf: destinationContent) == oldBytes)
    #expect(try fileManager.contentsOfDirectory(atPath: destinationDirectory.path) == ["report"])
  }

  @Test("元が消失した置換移動でも既存宛先を保持する")
  func failedReplacementPreservesDestinationWhenSourceIsMissing() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
    let destinationDirectory = root.appending(path: "destination")
    try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: root) }
    let sourceURL = root.appending(path: "report.txt")
    let destinationURL = destinationDirectory.appending(path: "report.txt")
    let bytes = Data("保持すべき既存内容".utf8)
    try bytes.write(to: destinationURL)

    #expect(throws: (any Error).self) {
      try LocalSameVolumeTransfer.move(
        FileItem(url: sourceURL, isDirectory: false),
        toDirectory: FileLocation(localURL: destinationDirectory), replacingExisting: true)
    }

    #expect(try Data(contentsOf: destinationURL) == bytes)
    #expect(
      try fileManager.contentsOfDirectory(atPath: destinationDirectory.path) == ["report.txt"])
  }

  @Test("非空フォルダの置換移動は旧内容を置き換え元のinodeを保持する")
  func replacementOfNonemptyDirectoryPreservesSourceIdentity() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appending(path: UUID().uuidString)
    let sourceURL = root.appending(path: "source/report")
    let destinationDirectory = root.appending(path: "destination")
    let destinationURL = destinationDirectory.appending(path: "report")
    try fileManager.createDirectory(at: sourceURL, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: root) }
    let newBytes = Data("新しいフォルダ内容".utf8)
    try newBytes.write(to: sourceURL.appending(path: "new.txt"))
    try Data("古いフォルダ内容".utf8).write(to: destinationURL.appending(path: "old.txt"))
    let identifierBefore = try #require(
      sourceURL.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier)

    try LocalSameVolumeTransfer.move(
      FileItem(url: sourceURL, isDirectory: true),
      toDirectory: FileLocation(localURL: destinationDirectory), replacingExisting: true)

    var movedURL = destinationURL
    movedURL.removeAllCachedResourceValues()
    let identifierAfter = try #require(
      movedURL.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier)
    #expect(identifierBefore.isEqual(identifierAfter))
    #expect(!fileManager.fileExists(atPath: sourceURL.path))
    #expect(try Data(contentsOf: movedURL.appending(path: "new.txt")) == newBytes)
    #expect(try fileManager.contentsOfDirectory(atPath: movedURL.path) == ["new.txt"])
    #expect(try fileManager.contentsOfDirectory(atPath: destinationDirectory.path) == ["report"])
  }

  @Test("祖先と子孫が重なる置換moveは削除前に拒否する", arguments: [true, false])
  func rejectsOverlappingReplacementTrees(moveToAncestor: Bool) throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let outer = root.appending(path: "A")
    let middle = outer.appending(path: "B")
    let inner = middle.appending(path: "A")
    try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
    let leaf = inner.appending(path: "leaf.txt")
    let bytes = Data("must-survive-overlap".utf8)
    try bytes.write(to: leaf)
    let item = FileItem(url: moveToAncestor ? inner : outer, isDirectory: true)
    let destination = FileLocation(localURL: moveToAncestor ? root : middle)
    #expect(throws: ProviderFileTransferServiceError.self) {
      try LocalSameVolumeTransfer.move(item, toDirectory: destination, replacingExisting: true)
    }
    #expect(try Data(contentsOf: leaf) == bytes)
  }

  @Test(
    "大文字小文字だけ異なる置換宛先も同一実体なら元を保持する",
    .enabled(
      if: (try? FileManager.default.temporaryDirectory.resourceValues(
        forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames) == false,
      "大文字小文字を区別しない試験ボリュームが必要"))
  func keepsSourceWhenDestinationDiffersOnlyInCase() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let parent = root.appending(path: "Source")
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    let sourceURL = parent.appending(path: "report.txt")
    let bytes = Data("must-survive-case-alias".utf8)
    try bytes.write(to: sourceURL)
    let differentCaseParent = root.appending(path: "source")
    let destinationURL = differentCaseParent.appending(path: "REPORT.TXT")
    try #require(FileManager.default.fileExists(atPath: destinationURL.path))
    try LocalSameVolumeTransfer.move(
      FileItem(url: sourceURL, isDirectory: false),
      toDirectory: FileLocation(localURL: differentCaseParent), replacingExisting: true,
      destinationName: "REPORT.TXT")
    #expect(try Data(contentsOf: sourceURL) == bytes)
  }

  @Test("同一実体の宛先への置換moveは自分自身を削除しない")
  func keepsSourceWhenReplacementDestinationIsSameItem() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let sourceURL = root.appending(path: "report.txt")
    let bytes = Data("must-survive".utf8)
    try bytes.write(to: sourceURL)
    let item = FileItem(url: sourceURL, isDirectory: false)
    let alias = root.appending(path: "alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
    for destination in [root, alias] {
      try LocalSameVolumeTransfer.move(
        item, toDirectory: FileLocation(localURL: destination), replacingExisting: true)
      #expect(try Data(contentsOf: sourceURL) == bytes)
    }
  }

  @Test("復元された不正な宛先名は既存削除より前に拒否し、元と宛先を保持する")
  func rejectsInvalidDestinationNamesBeforeMutation() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appending(path: "source.txt")
    let destination = root.appending(path: "destination")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try Data("source".utf8).write(to: source)
    let protected = root.appending(path: "protected.txt")
    try Data("protected".utf8).write(to: protected)
    let item = FileItem(url: source, isDirectory: false)
    for name in ["../protected.txt", "/protected.txt", ".", "..", "", "protected\0.txt"] {
      #expect(throws: (any Error).self) {
        try LocalSameVolumeTransfer.move(
          item, toDirectory: FileLocation(localURL: destination),
          replacingExisting: true, destinationName: name)
      }
      #expect(try Data(contentsOf: source) == Data("source".utf8))
      #expect(try Data(contentsOf: protected) == Data("protected".utf8))
    }
  }

  @Test("同一ボリュームのローカル項目はcanMoveがtrueになる")
  func canMoveReturnsTrueForSameVolumeLocalItems() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let sourceDirectory = root.appending(path: "source", directoryHint: .isDirectory)
    let destinationDirectory = root.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: destinationDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fileURL = sourceDirectory.appending(path: "report.txt")
    FileManager.default.createFile(atPath: fileURL.path, contents: Data("abc".utf8))
    let item = FileItem(url: fileURL, isDirectory: false)
    let destination = FileLocation(localURL: destinationDirectory)

    #expect(LocalSameVolumeTransfer.canMove(item, toDirectory: destination))
  }

  @Test("リモート宛先はcanMoveがfalseになる")
  func canMoveReturnsFalseForRemoteDestination() {
    let item = FileItem(url: URL(filePath: "/tmp/report.txt"), isDirectory: false)
    let destination = FileLocation(
      remotePath: "/upload", providerID: FileProviderID(rawValue: "sftp-test"))

    #expect(!LocalSameVolumeTransfer.canMove(item, toDirectory: destination))
  }

  @Test("moveはrenameで移動しinodeを保存する")
  func movePreservesFileIdentity() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let sourceDirectory = root.appending(path: "source", directoryHint: .isDirectory)
    let destinationDirectory = root.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: destinationDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fileURL = sourceDirectory.appending(path: "report.txt")
    FileManager.default.createFile(atPath: fileURL.path, contents: Data("abc".utf8))
    let identifierBefore = try fileURL.resourceValues(forKeys: [.fileResourceIdentifierKey])
      .fileResourceIdentifier
    let item = FileItem(url: fileURL, isDirectory: false)

    try LocalSameVolumeTransfer.move(
      item, toDirectory: FileLocation(localURL: destinationDirectory))

    let movedURL = destinationDirectory.appending(path: "report.txt")
    var uncachedMovedURL = movedURL
    uncachedMovedURL.removeAllCachedResourceValues()
    let identifierAfter = try uncachedMovedURL.resourceValues(
      forKeys: [.fileResourceIdentifierKey]
    ).fileResourceIdentifier
    #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    #expect(FileManager.default.fileExists(atPath: movedURL.path))
    #expect(
      identifierBefore != nil && identifierAfter != nil
        && identifierBefore!.isEqual(identifierAfter!))
  }

  @Test("moveはreplacingExisting指定時に既存宛先を置き換えrenameでinodeを保存する")
  func moveReplacesExistingDestinationWhenReplacingExisting() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let sourceDirectory = root.appending(path: "source", directoryHint: .isDirectory)
    let destinationDirectory = root.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: destinationDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fileURL = sourceDirectory.appending(path: "report.txt")
    FileManager.default.createFile(atPath: fileURL.path, contents: Data("新しい内容".utf8))
    let identifierBefore = try fileURL.resourceValues(forKeys: [.fileResourceIdentifierKey])
      .fileResourceIdentifier
    let existingURL = destinationDirectory.appending(path: "report.txt")
    FileManager.default.createFile(atPath: existingURL.path, contents: Data("既存内容".utf8))
    let item = FileItem(url: fileURL, isDirectory: false)

    try LocalSameVolumeTransfer.move(
      item, toDirectory: FileLocation(localURL: destinationDirectory), replacingExisting: true)

    var uncachedMovedURL = existingURL
    uncachedMovedURL.removeAllCachedResourceValues()
    let identifierAfter = try uncachedMovedURL.resourceValues(
      forKeys: [.fileResourceIdentifierKey]
    ).fileResourceIdentifier
    #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    #expect(try Data(contentsOf: existingURL) == Data("新しい内容".utf8))
    #expect(
      identifierBefore != nil && identifierAfter != nil
        && identifierBefore!.isEqual(identifierAfter!))
  }

  @Test("moveはreplacingExisting未指定で宛先が存在するとfileWriteFileExistsを投げる")
  func moveThrowsFileExistsWhenNotReplacingExisting() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let sourceDirectory = root.appending(path: "source", directoryHint: .isDirectory)
    let destinationDirectory = root.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: destinationDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fileURL = sourceDirectory.appending(path: "report.txt")
    FileManager.default.createFile(atPath: fileURL.path, contents: Data("abc".utf8))
    let existingURL = destinationDirectory.appending(path: "report.txt")
    FileManager.default.createFile(atPath: existingURL.path, contents: Data("既存内容".utf8))
    let item = FileItem(url: fileURL, isDirectory: false)

    #expect {
      try LocalSameVolumeTransfer.move(
        item, toDirectory: FileLocation(localURL: destinationDirectory))
    } throws: { error in
      (error as? CocoaError)?.code == .fileWriteFileExists
    }
    #expect(FileManager.default.fileExists(atPath: fileURL.path))
    #expect(try Data(contentsOf: existingURL) == Data("既存内容".utf8))
  }

  @MainActor
  @Test("LocalとMountedVolumeの2ペイン間でも同一ボリューム移動はinodeを保存する")
  func crossProviderMovePreservesIdentityOnSameVolume() async throws {
    let transferQueue = TransferQueue.isolatedForTesting()
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let sourceDirectory = root.appending(path: "source", directoryHint: .isDirectory)
    let destinationDirectory = root.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: destinationDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fileURL = sourceDirectory.appending(path: "report.txt")
    FileManager.default.createFile(atPath: fileURL.path, contents: Data("abc".utf8))
    let identifierBefore = try fileURL.resourceValues(forKeys: [.fileResourceIdentifierKey])
      .fileResourceIdentifier

    let sourceProvider = LocalFileProvider()
    let destinationProvider = MountedVolumeProvider(volumeURL: destinationDirectory)
    let sourceSession = FileBrowserSession(
      provider: sourceProvider,
      initialLocation: FileLocation(localURL: sourceDirectory, providerID: sourceProvider.id),
      transferQueue: transferQueue)
    let destinationSession = FileBrowserSession(
      provider: destinationProvider,
      initialLocation: FileLocation(
        localURL: destinationDirectory, providerID: destinationProvider.id),
      transferQueue: transferQueue)
    sourceSession.load()
    while sourceSession.isLoading || sourceSession.isRefreshing { await Task.yield() }
    destinationSession.load()
    while destinationSession.isLoading || destinationSession.isRefreshing { await Task.yield() }

    let item = try #require(sourceSession.items.first { $0.name == "report.txt" })
    sourceSession.move([item], to: destinationSession)
    while sourceSession.isTransferring { await Task.yield() }

    let movedURL = destinationDirectory.appending(path: "report.txt")
    var uncachedMovedURL = movedURL
    uncachedMovedURL.removeAllCachedResourceValues()
    let identifierAfter = try uncachedMovedURL.resourceValues(
      forKeys: [.fileResourceIdentifierKey]
    ).fileResourceIdentifier
    #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    #expect(
      identifierBefore != nil && identifierAfter != nil
        && identifierBefore!.isEqual(identifierAfter!))
  }

  @Test("同一ボリューム高速移動でも最上位ファイルの完了記録を残す")
  func crossProviderSameVolumeMoveRecordsCompletedRootFile() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let sourceDirectory = root.appending(path: "source", directoryHint: .isDirectory)
    let destinationDirectory = root.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: destinationDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fileURL = sourceDirectory.appending(path: "report.txt")
    let data = Data("report".utf8)
    FileManager.default.createFile(atPath: fileURL.path, contents: data)

    let sourceProvider = LocalFileProvider()
    let destinationProvider = MountedVolumeProvider(volumeURL: destinationDirectory)
    let item = FileItem(
      url: fileURL,
      providerID: sourceProvider.id,
      isDirectory: false,
      size: Int64(data.count))
    let destination = FileLocation(
      localURL: destinationDirectory, providerID: destinationProvider.id)
    let job = TransferJob(
      kind: .move,
      items: [item],
      sourceProviderID: sourceProvider.id,
      destinationProviderID: destinationProvider.id,
      destination: destination)
    let queue = TransferQueue(store: InMemoryTransferJobStore(), maximumConcurrentTransfers: 1)
    let gate = TransferGate()
    let transfer = FileBrowserSession.makeTransferExecution(
      items: [item],
      itemSizes: [item.size],
      totalBytes: item.size,
      sourceProvider: sourceProvider,
      destinationProvider: destinationProvider,
      destinationLocation: destination,
      removesSourceAfterCopy: true,
      replacingExisting: false)

    #expect(sourceProvider.id != destinationProvider.id)
    #expect(LocalSameVolumeTransfer.canMove(item, toDirectory: destination))

    _ = await queue.enqueue(job) { report, itemCompleted in
      try await transfer(report, itemCompleted)
      await gate.wait()
    }
    await waitUntil("完了アイテムが期限内に現れなかった") {
      !(await queue.allJobs().first?.completedItems ?? []).isEmpty
    }
    let running = try #require(await queue.allJobs().first)

    #expect(running.state == .running)
    #expect(running.completedItems == [TransferJob.Item(item)])
    #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    #expect(try Data(contentsOf: destinationDirectory.appending(path: "report.txt")) == data)

    await gate.open()
  }

  @MainActor
  @Test("同一ボリュームの置き換え確認後は移動元のinodeで宛先を置き換える")
  func crossProviderReplaceConflictReplacesDestinationOnSameVolume() async throws {
    let transferQueue = TransferQueue.isolatedForTesting()
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let sourceDirectory = root.appending(path: "source", directoryHint: .isDirectory)
    let destinationDirectory = root.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: destinationDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fileURL = sourceDirectory.appending(path: "report.txt")
    FileManager.default.createFile(atPath: fileURL.path, contents: Data("新しい内容".utf8))
    let identifierBefore = try fileURL.resourceValues(forKeys: [.fileResourceIdentifierKey])
      .fileResourceIdentifier
    let existingURL = destinationDirectory.appending(path: "report.txt")
    FileManager.default.createFile(atPath: existingURL.path, contents: Data("既存内容".utf8))

    let sourceProvider = LocalFileProvider()
    let destinationProvider = MountedVolumeProvider(volumeURL: destinationDirectory)
    let sourceSession = FileBrowserSession(
      provider: sourceProvider,
      initialLocation: FileLocation(localURL: sourceDirectory, providerID: sourceProvider.id),
      transferQueue: transferQueue)
    let destinationSession = FileBrowserSession(
      provider: destinationProvider,
      initialLocation: FileLocation(
        localURL: destinationDirectory, providerID: destinationProvider.id),
      transferQueue: transferQueue)
    sourceSession.load()
    while sourceSession.isLoading || sourceSession.isRefreshing { await Task.yield() }
    destinationSession.load()
    while destinationSession.isLoading || destinationSession.isRefreshing { await Task.yield() }

    let item = try #require(sourceSession.items.first { $0.name == "report.txt" })
    sourceSession.move([item], to: destinationSession)

    #expect(sourceSession.pendingTransferConflict?.sourceName == "report.txt")

    sourceSession.resolvePendingTransferConflict(replaceExisting: true)
    while sourceSession.isTransferring { await Task.yield() }

    var uncachedMovedURL = existingURL
    uncachedMovedURL.removeAllCachedResourceValues()
    let identifierAfter = try uncachedMovedURL.resourceValues(
      forKeys: [.fileResourceIdentifierKey]
    ).fileResourceIdentifier
    #expect(sourceSession.pendingTransferConflict == nil)
    #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    #expect(try Data(contentsOf: existingURL) == Data("新しい内容".utf8))
    #expect(
      identifierBefore != nil && identifierAfter != nil
        && identifierBefore!.isEqual(identifierAfter!))
  }

  @MainActor
  @Test("同一ボリューム移動は置き換え未確認のまま宛先が出現すると失敗し再試行可能になる")
  func crossProviderMoveFailsWhenDestinationConflictsWithoutReplacingExisting() async throws {
    let transferQueue = TransferQueue.isolatedForTesting()
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let sourceDirectory = root.appending(path: "source", directoryHint: .isDirectory)
    let destinationDirectory = root.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: destinationDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fileURL = sourceDirectory.appending(path: "report.txt")
    FileManager.default.createFile(atPath: fileURL.path, contents: Data("abc".utf8))

    let sourceProvider = LocalFileProvider()
    let destinationProvider = MountedVolumeProvider(volumeURL: destinationDirectory)
    let sourceSession = FileBrowserSession(
      provider: sourceProvider,
      initialLocation: FileLocation(localURL: sourceDirectory, providerID: sourceProvider.id),
      transferQueue: transferQueue)
    let destinationSession = FileBrowserSession(
      provider: destinationProvider,
      initialLocation: FileLocation(
        localURL: destinationDirectory, providerID: destinationProvider.id),
      transferQueue: transferQueue)
    sourceSession.load()
    while sourceSession.isLoading || sourceSession.isRefreshing { await Task.yield() }
    destinationSession.load()
    while destinationSession.isLoading || destinationSession.isRefreshing { await Task.yield() }
    // destinationSession.itemsが空のままローカル側に同名ファイルが後から出現するケース
    // (キャッシュとディスクの乖離)を模し、事前確認なしでreplacingExisting: falseの
    // 実行パスに到達させる。
    let existingURL = destinationDirectory.appending(path: "report.txt")
    FileManager.default.createFile(atPath: existingURL.path, contents: Data("既存内容".utf8))

    let item = try #require(sourceSession.items.first { $0.name == "report.txt" })
    sourceSession.move([item], to: destinationSession)
    #expect(sourceSession.pendingTransferConflict == nil)
    while sourceSession.isTransferring { await Task.yield() }

    #expect(sourceSession.canRetryLastTransfer)
    #expect(FileManager.default.fileExists(atPath: fileURL.path))
    #expect(try Data(contentsOf: existingURL) == Data("既存内容".utf8))
  }
}

private actor TransferGate {
  private var isOpen = false

  func wait() async {
    await waitUntil(timeout: .seconds(5), "転送ゲートが期限内に開かなかった") {
      isOpen
    }
  }

  func open() {
    isOpen = true
  }
}
