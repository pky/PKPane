import Foundation
import Synchronization
import Testing

@testable import PKPane

@MainActor
struct FTPNamedTransferTests {
  @Test("公開別名保持はFTP/FTPSの実名を保存し、元と旧宛先を保持する", arguments: FTPConnectionSecurity.allCases)
  func copiesUsingServerAssignedName(security: FTPConnectionSecurity) async throws {
    let fixture = try await NamedFTPFixture.make(security: security)
    defer { fixture.cleanup() }
    try fixture.startKeepingBoth()
    let job = try await fixture.finishedJob()
    #expect(job.state == .completed)
    let options = try #require(job.items.first?.transferOptions)
    #expect(options.destinationName == "ftp-generated.txt")
    #expect(options.destinationNameWasReserved)
    #expect(await fixture.session.data(at: "/destination/report.txt") == Data("old".utf8))
    #expect(await fixture.session.data(at: "/destination/ftp-generated.txt") == fixture.payload)
    #expect(try Data(contentsOf: fixture.sourceURL) == fixture.payload)
    #expect(fixture.source.lastCompletedTransfer?.itemOptions[fixture.item.location] == options)
    #expect(try fixture.store.load().first?.items.first?.transferOptions == options)
    #expect(await fixture.session.ordinaryWriteCount == 0)
    #expect(await fixture.session.renameCount == 0)
  }

  @Test("予約実名の保存失敗は送信前に失敗し、所有した空ファイルだけ掃除する")
  func stopsBeforeSendingWhenReservationCannotBeSaved() async throws {
    let store = NamedFTPJobStore(rejectReservations: true)
    let observed = ObservedFTPSource()
    let fixture = try await NamedFTPFixture.make(store: store, sourceProvider: observed)
    defer { fixture.cleanup() }
    try fixture.startKeepingBoth()
    #expect(try await fixture.finishedJob().state == .failed)
    #expect(await fixture.session.sentBytes == 0)
    #expect(observed.readCalls == 0)
    #expect(await fixture.session.data(at: "/destination/ftp-generated.txt") == nil)
    #expect(await fixture.session.removedPaths == ["/destination/ftp-generated.txt"])
    #expect(try Data(contentsOf: fixture.sourceURL) == fixture.payload)
    #expect(await fixture.session.data(at: "/destination/report.txt") == Data("old".utf8))
  }

  @Test("送信途中の失敗は読み元producerも終了し、元の内容を保持する")
  func stopsSourceProducerAfterSendingFails() async throws {
    let observed = ObservedFTPSource()
    let fixture = try await NamedFTPFixture.make(
      mode: .partialFailure, sourceProvider: observed,
      payload: Data(repeating: 0x42, count: 32 * 1_024 * 1_024))
    defer { fixture.cleanup() }
    try fixture.startKeepingBoth()
    #expect(try await fixture.finishedJob().state == .failed)
    #expect(observed.readCalls == 1)
    await waitUntil("送信失敗後に読み元producerが終了しなかった") { observed.didFinishReading }
    #expect(observed.producedBytes < fixture.payload.count)
    #expect(try Data(contentsOf: fixture.sourceURL) == fixture.payload)
    #expect(await fixture.session.data(at: "/destination/report.txt") == Data("old".utf8))
  }

  @Test("SFTP同様のsourceだけ再接続適格でも、不明な別名作成を自動再発行しない", arguments: [false, true])
  func doesNotAutoRetryUnknownCreationFromReconnectableSource(directory: Bool) async throws {
    let fixture = try await NamedFTPFixture.make(
      isDirectory: directory, mode: directory ? .unknownDirectoryCreation : .unknownCreation)
    defer { fixture.cleanup() }
    let provider = ReconnectableNamedFTPSource(isDirectory: directory)
    let source = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: "/source", providerID: provider.id),
      transferQueue: fixture.queue,
      autoReconnectBackoff: [.milliseconds(1), .milliseconds(1), .milliseconds(1)])
    defer { source.invalidate() }
    source.load()
    await waitUntil { !source.isLoading && source.items.count == 1 }
    source.copy(source.items, to: fixture.destination)
    _ = try #require(source.pendingTransferConflict?.canKeepBoth == true)
    source.resolvePendingTransferConflict(.keepBoth)
    await waitUntil { !source.isTransferring }
    let jobs = await fixture.queue.allJobs()
    let job = try #require(jobs.first)
    #expect(job.state == .failed)
    #expect(job.isReconnectFutile)
    #expect(await fixture.session.uniqueWriteCount == (directory ? 0 : 1))
    #expect(await fixture.session.exclusiveCreateCount == (directory ? 1 : 0))
    #expect(provider.readCalls == 0)
    #expect(await fixture.session.removedPaths.isEmpty)
  }

  @Test(
    "FTP/FTPS同endpointのalias元またはルートから自己配下へはMKD前に拒否する",
    arguments: [false, true], FTPConnectionSecurity.allCases)
  func rejectsCanonicalDescendantBeforeCreatingDirectory(
    sourceIsRoot: Bool, sourceSecurity: FTPConnectionSecurity
  ) async throws {
    let session = NamedFTPSession(isDirectory: true, mode: .normal)
    await session.addDirectory("/destination/tree/inside")
    await session.addDirectory("/destination/tree/inside/tree")
    let target = try FTPConnectionTarget(
      host: "EXAMPLE.invalid", username: "fixture", security: sourceSecurity)
    let provider = FTPFileProvider(target: target, session: session, sessionFactory: { session })
    let destinationTarget = try FTPConnectionTarget(host: "example.invalid", username: "fixture")
    let destinationProvider = FTPFileProvider(
      target: destinationTarget, session: session, sessionFactory: { session })
    let queue = TransferQueue.isolatedForTesting()
    let source = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: "/alias", providerID: provider.id),
      transferQueue: queue)
    let destination = FileBrowserSession(
      provider: destinationProvider,
      initialLocation: FileLocation(
        remotePath: "/destination/tree/inside", providerID: destinationProvider.id),
      transferQueue: queue)
    defer {
      source.invalidate()
      destination.invalidate()
    }
    source.load()
    destination.load()
    await waitUntil { !source.isLoading && !destination.isLoading && source.items.count == 1 }
    let items =
      sourceIsRoot
      ? [
        FileItem(
          remotePath: "/", url: URL(filePath: "/tree"), providerID: provider.id, isDirectory: true)
      ]
      : source.items
    source.copy(items, to: destination)
    _ = try #require(source.pendingTransferConflict?.canKeepBoth == true)
    source.resolvePendingTransferConflict(.keepBoth)
    await waitUntil { !source.isTransferring }
    #expect(await queue.allJobs().first?.state == .failed)
    #expect(await session.exclusiveCreateCount == 0)
    #expect(await session.uniqueWriteCount == 0)
    #expect(await session.data(at: "/destination/tree/old.txt") == Data("old".utf8))
  }

  @Test("予約実名は最初のデータ送信前に永続化され、取消しても元を保持する")
  func persistsReservationBeforeSendingAndCancelsSafely() async throws {
    let fixture = try await NamedFTPFixture.make(mode: .holdAfterReservation)
    defer { fixture.cleanup() }
    try fixture.startKeepingBoth(isMove: true)
    await waitUntil { await fixture.session.isHoldingAfterReservation }
    let saved = try #require(try fixture.store.load().first)
    #expect(saved.items.first?.transferOptions.destinationName == "ftp-generated.txt")
    #expect(saved.items.first?.transferOptions.destinationNameWasReserved == true)
    #expect(await fixture.session.sentBytes == 0)
    await fixture.queue.cancel(saved.id)
    #expect(try await fixture.finishedJob().state == .cancelled)
    #expect(try Data(contentsOf: fixture.sourceURL) == fixture.payload)
    #expect(await fixture.session.data(at: "/destination/ftp-generated.txt") == nil)
    #expect(await fixture.session.data(at: "/destination/report.txt") == Data("old".utf8))
  }

  @Test("通常失敗は所有ファイルだけ除去し、命名不明の副作用は削除せず案内する")
  func separatesOwnedFailureAndUnknownCreation() async throws {
    for mode in [NamedFTPSession.Mode.partialFailure, .unknownCreation] {
      let fixture = try await NamedFTPFixture.make(mode: mode)
      defer { fixture.cleanup() }
      try fixture.startKeepingBoth(isMove: true)
      let job = try await fixture.finishedJob()
      #expect(job.state == .failed)
      #expect(try Data(contentsOf: fixture.sourceURL) == fixture.payload)
      #expect(await fixture.session.data(at: "/destination/report.txt") == Data("old".utf8))
      if mode == .partialFailure {
        #expect(await fixture.session.data(at: "/destination/ftp-generated.txt") == nil)
        #expect(job.items.first?.transferOptions.destinationName == "ftp-generated.txt")
      } else {
        #expect(await fixture.session.data(at: "/destination/unidentified.bin") != nil)
        #expect(await fixture.session.removedPaths.isEmpty)
        #expect(job.errorDescription?.contains("/destination") == true)
      }
    }
  }

  @Test("予約後の通信断取消は複数件でも実名を救済案内へ残し、新接続から削除しない", arguments: [1, 2])
  func preservesReservationWhenCancellationClosesTheSession(itemCount: Int) async throws {
    let fixture = try await NamedFTPFixture.make(mode: .disconnectedAfterReservation)
    defer { fixture.cleanup() }
    if itemCount == 2 {
      try fixture.payload.write(to: fixture.root.appending(path: "second.txt"))
      await fixture.session.put(Data("old second".utf8), at: "/destination/second.txt")
      fixture.source.refresh()
      fixture.destination.refresh()
      await waitUntil { fixture.source.items.count == 2 && fixture.destination.items.count == 2 }
      fixture.source.move(fixture.source.items, to: fixture.destination)
      _ = try #require(fixture.source.pendingTransferConflict?.canKeepBoth == true)
      fixture.source.resolvePendingTransferConflict(.keepBoth, applyToRemaining: true)
    } else {
      try fixture.startKeepingBoth(isMove: true)
    }
    await waitUntil { await fixture.session.isHoldingAfterReservation }
    let jobs = await fixture.queue.allJobs()
    let running = try #require(jobs.first)
    await fixture.queue.cancel(running.id)
    let job = try await fixture.finishedJob()
    #expect(job.state == .cancelled)
    #expect(job.items.first?.transferOptions.destinationName == "ftp-generated.txt")
    #expect(job.errorDescription?.contains("ftp-generated.txt") == true)
    #expect(await fixture.session.data(at: "/destination/ftp-generated.txt") != nil)
    #expect(await fixture.session.removedPaths.isEmpty)
    #expect(await fixture.session.createdTransferSessions == 1)
    #expect(try Data(contentsOf: fixture.sourceURL) == fixture.payload)
    if itemCount == 2 {
      #expect(try Data(contentsOf: fixture.root.appending(path: "second.txt")) == fixture.payload)
      #expect(await fixture.session.uniqueWriteCount == 1)
    }
  }

  @Test("MKDの作成応答喪失では作成済みか推測して削除せず、元を保持する")
  func preservesDirectoryWhenMKDOutcomeIsUnknown() async throws {
    let fixture = try await NamedFTPFixture.make(isDirectory: true, mode: .unknownDirectoryCreation)
    defer { fixture.cleanup() }
    try fixture.startKeepingBoth(isMove: true)
    let job = try await fixture.finishedJob()
    #expect(job.state == .failed)
    #expect(job.errorDescription?.contains("/destination") == true)
    #expect(await fixture.session.hasDirectory("/destination/treeのコピー"))
    #expect(await fixture.session.removedPaths.isEmpty)
    #expect(
      try Data(contentsOf: fixture.sourceURL.appending(path: "report.txt")) == fixture.payload)
  }

  @Test("FTP別名copy/moveのUndoはサーバー実名を使い、元名へ戻す", arguments: [false, true])
  func undoUsesActualName(isMove: Bool) async throws {
    let fixture = try await NamedFTPFixture.make()
    defer { fixture.cleanup() }
    let workspace = FileWorkspaceModel(initialBrowser: fixture.source)
    workspace.activatePane(.secondary)
    workspace.replaceActiveBrowser(with: fixture.destination)
    workspace.activatePane(.primary)
    workspace.selectItems([fixture.item.url], in: .primary)
    workspace.transferSelectedItems(to: fixture.destination, wasMove: isMove)
    _ = try #require(fixture.source.pendingTransferConflict?.canKeepBoth == true)
    fixture.source.resolvePendingTransferConflict(.keepBoth)
    await waitUntil { workspace.canUndoLastTransfer }
    workspace.undoLastTransfer()
    await waitUntil {
      await fixture.session.data(at: "/destination/ftp-generated.txt") == nil
        && !fixture.destination.isTransferring
    }
    #expect(try Data(contentsOf: fixture.sourceURL) == fixture.payload)
    #expect(await fixture.session.data(at: "/destination/report.txt") == Data("old".utf8))
    #expect(await fixture.session.renameCount == 0)
  }

  @Test("フォルダの別名保持は各子名を維持し、旧フォルダを変更しない")
  func keepsDirectoryNamesAndContents() async throws {
    let fixture = try await NamedFTPFixture.make(isDirectory: true)
    defer { fixture.cleanup() }
    try fixture.startKeepingBoth(isMove: true)
    #expect(try await fixture.finishedJob().state == .completed)
    #expect(await fixture.session.data(at: "/destination/tree/old.txt") == Data("old".utf8))
    #expect(await fixture.session.data(at: "/destination/treeのコピー/report.txt") == fixture.payload)
    #expect(!FileManager.default.fileExists(atPath: fixture.sourceURL.path))
    #expect(await fixture.session.ordinaryWriteCount == 0)
    #expect(await fixture.session.renameCount == 0)
  }

  @Test("フォルダ配下の外部同名作成は上書きせず、外部追加を掃除に巻き込まない")
  func refusesChangedChildNameWithoutRemovingExternalContents() async throws {
    let fixture = try await NamedFTPFixture.make(isDirectory: true, mode: .childCollision)
    defer { fixture.cleanup() }
    try fixture.startKeepingBoth(isMove: true)
    let job = try await fixture.finishedJob()
    #expect(job.state == .failed)
    #expect(
      await fixture.session.data(at: "/destination/treeのコピー/report.txt") == Data("external".utf8))
    #expect(await fixture.session.data(at: "/destination/treeのコピー/report.txt.unique") == nil)
    #expect(await fixture.session.data(at: "/destination/tree/old.txt") == Data("old".utf8))
    #expect(
      try Data(contentsOf: fixture.sourceURL.appending(path: "report.txt")) == fixture.payload)
    #expect(await fixture.session.sentBytes == 0)
    #expect(job.errorDescription?.contains("treeのコピー") == true)
  }

  @Test("保存済み実名が現存する再試行は他の名前へ増殖せず、復元後も旧宛先を保持する")
  func refusesExistingReservedNameAfterRestore() async throws {
    let fixture = try await NamedFTPFixture.make()
    defer { fixture.cleanup() }
    await fixture.session.put(Data("finished".utf8), at: "/destination/ftp-generated.txt")
    var job = TransferJob(
      kind: .move, items: [fixture.item], sourceProviderID: .local,
      destinationProviderID: fixture.destination.currentLocation.providerID,
      destination: fixture.destination.currentLocation)
    job.items = [
      TransferJob.Item(
        fixture.item,
        options: TransferItemOptions(
          destinationName: "ftp-generated.txt", destinationNameWasReserved: true))
    ]
    job.state = .interrupted
    let store = NamedFTPJobStore()
    try store.save([try JSONDecoder().decode(TransferJob.self, from: JSONEncoder().encode(job))])
    let queue = TransferQueue(store: store)
    let source = FileBrowserSession(
      provider: LocalFileProvider(), initialLocation: fixture.source.currentLocation,
      transferQueue: queue)
    let destination = fixture.destination.makePeerSession(at: fixture.destination.currentLocation)
    defer {
      source.invalidate()
      destination.invalidate()
    }
    #expect(source.prepareTransferRetry(job, to: destination))
    source.retryLastTransfer()
    await waitUntil { !source.isTransferring }
    #expect(await queue.allJobs().first?.state == .failed)
    #expect(await fixture.session.uniqueWriteCount == 0)
    #expect(
      await fixture.session.data(at: "/destination/ftp-generated.txt") == Data("finished".utf8))
    #expect(try Data(contentsOf: fixture.sourceURL) == fixture.payload)
  }

  @Test("成功folderと後続file失敗の実名を残し、手動retryは失敗fileだけを再送する")
  func retriesOnlyFailedItemAfterKeepingDirectory() async throws {
    let fixture = try await NamedFTPFixture.make(isDirectory: true, mode: .failsTopLevelOnce)
    defer { fixture.cleanup() }
    await fixture.session.put(Data("old".utf8), at: "/destination/z-failure.txt")
    fixture.destination.refresh()
    await waitUntil { fixture.destination.items.count == 2 }
    let provider = ReconnectableNamedFTPSource(isDirectory: true, includesFailureFile: true)
    let source = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: "/source", providerID: provider.id),
      transferQueue: fixture.queue,
      autoReconnectBackoff: [.milliseconds(1), .milliseconds(1), .milliseconds(1)])
    defer { source.invalidate() }
    source.load()
    await waitUntil { !source.isLoading && source.items.count == 2 }
    source.copy(source.items, to: fixture.destination)
    source.resolvePendingTransferConflict(.keepBoth, applyToRemaining: true)
    await waitUntil { !source.isTransferring }
    let jobs = await fixture.queue.allJobs()
    let job = try #require(jobs.first)
    #expect(job.state == .failed)
    #expect(job.items.map(\.name) == ["z-failure.txt"])
    #expect(job.completedItems.count == 1)
    #expect(job.completedItems.first?.isDirectory == true)
    #expect(job.completedItems.first?.transferOptions.destinationName == "treeのコピー")
    let displayed = TransferDestinationNamesProjection.items(for: job)
    #expect(Set(displayed.map(\.name)) == ["tree", "z-failure.txt"])
    #expect(await fixture.session.exclusiveCreateCount == 1)
    #expect(await fixture.session.uniqueWriteCount == 2)
    source.retryLastTransfer()
    await waitUntil { !source.isTransferring }
    #expect(await fixture.queue.allJobs().first?.state == .completed)
    #expect(await fixture.session.exclusiveCreateCount == 1)
    #expect(await fixture.session.uniqueWriteCount == 3)
    #expect(
      await fixture.session.data(at: "/destination/treeのコピー/report.txt")
        == Data("new contents".utf8))
    #expect(await fixture.session.data(at: "/destination/tree/old.txt") == Data("old".utf8))
    let encoded = try JSONEncoder().encode(job)
    let restored = try JSONDecoder().decode(TransferJob.self, from: encoded)
    #expect(TransferDestinationNamesProjection.items(for: restored) == displayed)
  }

  @Test("FTP同士のUndoは要求した元名を維持し、不一致なら送信・元削除前に拒否する", arguments: [false, true])
  func undoRequiresOriginalNameBetweenFTPDirectories(changesHint: Bool) async throws {
    let fixture = try await NamedFTPFixture.make(mode: changesHint ? .changesHints : .normal)
    defer { fixture.cleanup() }
    await fixture.session.addDirectory("/source")
    await fixture.session.put(fixture.payload, at: "/source/report.txt")
    let source = fixture.destination.makePeerSession(
      at: FileLocation(
        remotePath: "/source", providerID: fixture.destination.currentLocation.providerID))
    defer { source.invalidate() }
    source.load()
    await waitUntil { !source.isLoading && source.items.count == 1 }
    let workspace = FileWorkspaceModel(initialBrowser: source)
    workspace.activatePane(.secondary)
    workspace.replaceActiveBrowser(with: fixture.destination)
    workspace.activatePane(.primary)
    workspace.selectItems(Set(source.items.map(\.url)), in: .primary)
    workspace.transferSelectedItems(to: fixture.destination, wasMove: true)
    source.resolvePendingTransferConflict(.keepBoth)
    await waitUntil { workspace.canUndoLastTransfer }
    #expect(await fixture.session.data(at: "/source/report.txt") == nil)
    let initialJobs = await fixture.queue.allJobs()
    let initialID = try #require(initialJobs.first).id
    workspace.undoLastTransfer()
    await waitUntil {
      let jobs = await fixture.queue.allJobs()
      return jobs.count == 2 && jobs.first(where: { $0.id != initialID })?.state.isTerminal == true
        && !fixture.destination.isTransferring
    }
    let jobs = await fixture.queue.allJobs()
    let undo = try #require(jobs.first(where: { $0.id != initialID }))
    #expect(undo.items.first?.transferOptions.requiredDestinationName == "report.txt")
    if changesHint {
      #expect(undo.state == .failed)
      #expect(await fixture.session.data(at: "/source/report.txt") == nil)
      #expect(await fixture.session.data(at: "/destination/ftp-generated.txt") == fixture.payload)
      #expect(undo.items.first?.transferOptions.destinationName == "report.txt.server")
    } else {
      #expect(undo.state == .completed)
      #expect(await fixture.session.data(at: "/source/report.txt") == fixture.payload)
      #expect(await fixture.session.data(at: "/destination/ftp-generated.txt") == nil)
    }
    #expect(await fixture.session.renameCount == 0)
    #expect(await fixture.session.data(at: "/destination/report.txt") == Data("old".utf8))
  }

  @Test("旧項目オプションは予約フラグなしでも無予約として復元する")
  func decodesOlderOptionsWithoutReservationKey() throws {
    let json = Data(#"{"destinationName":"copy.txt","replacingExisting":false}"#.utf8)
    let options = try JSONDecoder().decode(TransferItemOptions.self, from: json)
    #expect(options.destinationName == "copy.txt")
    #expect(!options.destinationNameWasReserved)
    #expect(options.requiredDestinationName == "copy.txt")
    let serverAssigned = TransferItemOptions(destinationName: "generated")
    #expect(
      try JSONDecoder().decode(
        TransferItemOptions.self, from: JSONEncoder().encode(serverAssigned)
      ).requiredDestinationName == nil)
  }

  @Test("moveの元削除失敗でも完成コピーを残し、実名を再試行へ引き継ぐ")
  func retainsSuccessfulCopyAfterSourceRemovalFails() async throws {
    let fixture = try await NamedFTPFixture.make(sourceProvider: RemovalFailingFTPSource())
    defer { fixture.cleanup() }
    try fixture.startKeepingBoth(isMove: true)
    let job = try await fixture.finishedJob()
    #expect(job.state == .failed)
    #expect(job.items.first?.transferOptions.destinationName == "ftp-generated.txt")
    #expect(job.items.first?.transferOptions.destinationNameWasReserved == true)
    #expect(await fixture.session.data(at: "/destination/ftp-generated.txt") == fixture.payload)
    #expect(try Data(contentsOf: fixture.sourceURL) == fixture.payload)
    fixture.source.retryLastTransfer()
    await waitUntil { !fixture.source.isTransferring }
    #expect(await fixture.session.uniqueWriteCount == 1)
    #expect(await fixture.session.removedPaths.isEmpty)
    #expect(await fixture.session.data(at: "/destination/ftp-generated.txt") == fixture.payload)
  }
}

@MainActor
private struct NamedFTPFixture {
  let root: URL
  let sourceURL: URL
  let payload: Data
  let item: FileItem
  let session: NamedFTPSession
  let store: NamedFTPJobStore
  let queue: TransferQueue
  let source: FileBrowserSession
  let destination: FileBrowserSession

  static func make(
    isDirectory: Bool = false, mode: NamedFTPSession.Mode = .normal,
    security: FTPConnectionSecurity = .explicitTLS, store: NamedFTPJobStore = NamedFTPJobStore(),
    sourceProvider: any FileBrowserProvider = LocalFileProvider(),
    payload: Data = Data("new contents".utf8)
  ) async throws -> Self {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let sourceURL = root.appending(path: isDirectory ? "tree" : "report.txt")
    if isDirectory {
      try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
      try payload.write(to: sourceURL.appending(path: "report.txt"))
    } else {
      try payload.write(to: sourceURL)
    }
    let session = NamedFTPSession(isDirectory: isDirectory, mode: mode)
    let target = try FTPConnectionTarget(
      host: "example.invalid", username: "fixture", security: security)
    let provider = FTPFileProvider(
      target: target, session: session,
      sessionFactory: {
        await session.createdTransferSession()
        return session
      })
    let queue = TransferQueue(store: store)
    let source = FileBrowserSession(
      provider: sourceProvider, initialLocation: FileLocation(localURL: root),
      transferQueue: queue)
    let destination = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: "/destination", providerID: provider.id),
      transferQueue: queue)
    source.load()
    destination.load()
    await waitUntil { !source.isLoading && !destination.isLoading && source.items.count == 1 }
    return Self(
      root: root, sourceURL: sourceURL, payload: payload, item: try #require(source.items.first),
      session: session, store: store, queue: queue, source: source, destination: destination)
  }

  func startKeepingBoth(isMove: Bool = false) throws {
    if isMove { source.move([item], to: destination) } else { source.copy([item], to: destination) }
    #expect(source.pendingTransferConflict != nil)
    _ = try #require(source.pendingTransferConflict?.canKeepBoth == true)
    source.resolvePendingTransferConflict(.keepBoth)
  }

  func finishedJob() async throws -> TransferJob {
    await waitUntil {
      let jobs = await queue.allJobs()
      return jobs.first?.state.isTerminal == true && !source.isTransferring
    }
    let jobs = await queue.allJobs()
    let job = try #require(jobs.first)
    if job.state == .completed {
      await waitUntil { source.lastCompletedTransfer != nil }
    }
    return job
  }

  func cleanup() {
    source.invalidate()
    destination.invalidate()
    try? FileManager.default.removeItem(at: root)
  }
}

private final class NamedFTPJobStore: TransferJobStore, @unchecked Sendable {
  private let state = Mutex<[TransferJob]>([])
  private let rejectReservations: Bool
  init(rejectReservations: Bool = false) { self.rejectReservations = rejectReservations }
  func load() throws -> [TransferJob] { state.withLock { $0 } }
  func save(_ jobs: [TransferJob]) throws {
    if rejectReservations,
      jobs.contains(where: { $0.items.contains { $0.transferOptions.destinationNameWasReserved } })
    {
      throw CocoaError(.fileWriteNoPermission)
    }
    state.withLock { $0 = jobs }
  }
}

private struct RemovalFailingFTPSource: FileBrowserTransferProvider, FileStreamReadableProvider {
  let local = LocalFileProvider()
  var id: FileProviderID { local.id }
  var connectionID: FileProviderConnectionID? { nil }
  var capabilities: FileProviderCapabilities { local.capabilities }
  func contents(of location: FileLocation) async throws -> [FileItem] {
    try await local.contents(of: location)
  }
  func parent(of location: FileLocation) -> FileLocation? { local.parent(of: location) }
  func breadcrumbs(for location: FileLocation, constrainedTo root: FileLocation?)
    -> [FileBrowserBreadcrumb]
  {
    local.breadcrumbs(for: location, constrainedTo: root)
  }
  func createDirectory(named name: String, in location: FileLocation) async throws {
    try await local.createDirectory(named: name, in: location)
  }
  func rename(_ item: FileItem, to name: String) async throws {
    try await local.rename(item, to: name)
  }
  func delete(_ item: FileItem) async throws { try await local.delete(item) }
  func move(_ item: FileItem, to directory: FileLocation, replacingExisting: Bool) async throws {
    try await local.move(item, to: directory, replacingExisting: replacingExisting)
  }
  func copy(_ item: FileItem, to directory: FileLocation, replacingExisting: Bool) async throws {
    try await local.copy(item, to: directory, replacingExisting: replacingExisting)
  }
  func removeAfterCrossProviderMove(_: FileItem) async throws {
    throw CocoaError(.fileWriteNoPermission)
  }
  func fileChunks(for item: FileItem, chunkSize: Int) -> AsyncThrowingStream<Data, Error> {
    local.fileChunks(for: item, chunkSize: chunkSize)
  }
}

private final class ObservedFTPSource: FileStreamReadableProvider, @unchecked Sendable {
  private let local = LocalFileProvider()
  private let state = Mutex((calls: 0, finished: false, producedBytes: 0))
  var id: FileProviderID { local.id }
  var connectionID: FileProviderConnectionID? { nil }
  var capabilities: FileProviderCapabilities { local.capabilities }
  var readCalls: Int { state.withLock { $0.calls } }
  var didFinishReading: Bool { state.withLock { $0.finished } }
  var producedBytes: Int { state.withLock { $0.producedBytes } }
  func contents(of location: FileLocation) async throws -> [FileItem] {
    try await local.contents(of: location)
  }
  func parent(of location: FileLocation) -> FileLocation? { local.parent(of: location) }
  func breadcrumbs(for location: FileLocation, constrainedTo root: FileLocation?)
    -> [FileBrowserBreadcrumb]
  {
    local.breadcrumbs(for: location, constrainedTo: root)
  }
  func fileChunks(for item: FileItem, chunkSize: Int) -> AsyncThrowingStream<Data, Error> {
    state.withLock { $0.calls += 1 }
    return BoundedChunkPipe.stream(limit: 2) { [self] yield in
      defer { state.withLock { $0.finished = true } }
      for try await chunk in local.fileChunks(for: item, chunkSize: chunkSize) {
        state.withLock { $0.producedBytes += chunk.count }
        try await yield(chunk)
      }
      try Task.checkCancellation()
    }
  }
}

/// SFTPと同じ再接続マーカーをsourceだけへ付け、別名作成の反復を公開経路で検出する。
private final class ReconnectableNamedFTPSource: FileStreamReadableProvider,
  AutoReconnectEligibleProvider, @unchecked Sendable
{
  let id = FileProviderID(rawValue: "sftp-source-fixture")
  let isDirectory: Bool
  let includesFailureFile: Bool
  private let reads = Mutex(0)
  var readCalls: Int { reads.withLock { $0 } }
  var connectionID: FileProviderConnectionID? { nil }
  var capabilities: FileProviderCapabilities { [.read] }
  init(isDirectory: Bool, includesFailureFile: Bool = false) {
    self.isDirectory = isDirectory
    self.includesFailureFile = includesFailureFile
  }
  func contents(of location: FileLocation) async throws -> [FileItem] {
    if location.remotePath == "/source" {
      let name = isDirectory ? "tree" : "report.txt"
      var items = [
        FileItem(
          remotePath: "/source/" + name, url: URL(filePath: "/" + name), providerID: id,
          isDirectory: isDirectory, size: isDirectory ? nil : 12)
      ]
      if includesFailureFile {
        items.append(
          FileItem(
            remotePath: "/source/z-failure.txt", url: URL(filePath: "/z-failure.txt"),
            providerID: id, isDirectory: false, size: 12))
      }
      return items
    }
    if isDirectory, location.remotePath == "/source/tree" {
      return [
        FileItem(
          remotePath: "/source/tree/report.txt", url: URL(filePath: "/report.txt"),
          providerID: id, isDirectory: false, size: 12)
      ]
    }
    return []
  }
  func parent(of location: FileLocation) -> FileLocation? { location.deletingLastPathComponent() }
  func breadcrumbs(for location: FileLocation, constrainedTo _: FileLocation?)
    -> [FileBrowserBreadcrumb]
  {
    [FileBrowserBreadcrumb(location: location, name: "source")]
  }
  func fileChunks(for _: FileItem, chunkSize _: Int) -> AsyncThrowingStream<Data, Error> {
    reads.withLock { $0 += 1 }
    return AsyncThrowingStream { continuation in
      continuation.yield(Data("new contents".utf8))
      continuation.finish()
    }
  }
}

private actor NamedFTPSession: FTPClientSession {
  enum Mode {
    case normal, partialFailure, unknownCreation, holdAfterReservation, childCollision
    case disconnectedAfterReservation, unknownDirectoryCreation
    case failsTopLevelOnce, changesHints
  }
  let mode: Mode
  private var files: [String: Data]
  private var directories: Set<String>
  private(set) var uniqueWriteCount = 0
  private(set) var exclusiveCreateCount = 0
  private(set) var ordinaryWriteCount = 0
  private(set) var renameCount = 0
  private(set) var sentBytes = 0
  private(set) var removedPaths: [String] = []
  private(set) var isHoldingAfterReservation = false
  private(set) var createdTransferSessions = 0
  private var active = true
  private var topLevelFailuresRemaining = 1
  private var continuation: CheckedContinuation<Void, Error>?

  init(isDirectory: Bool, mode: Mode) {
    self.mode = mode
    directories = isDirectory ? ["/destination", "/destination/tree"] : ["/destination"]
    files =
      isDirectory
      ? ["/destination/tree/old.txt": Data("old".utf8)]
      : ["/destination/report.txt": Data("old".utf8)]
  }

  func data(at path: String) -> Data? { files[path] }
  func hasDirectory(_ path: String) -> Bool { directories.contains(path) }
  func addDirectory(_ path: String) { directories.insert(path) }
  func put(_ data: Data, at path: String) { files[path] = data }
  func createdTransferSession() {
    createdTransferSessions += 1
    active = true
  }

  func canonicalDirectoryPath(at path: String) async throws -> String {
    path.hasPrefix("/alias") ? path.replacingOccurrences(of: "/alias", with: "/destination") : path
  }

  func contents(of requestedPath: String) async throws -> [FTPDirectoryEntry] {
    let path = try await canonicalDirectoryPath(at: requestedPath)
    let prefix = path == "/" ? "/" : path + "/"
    return (Array(directories) + Array(files.keys)).compactMap { name in
      guard name.hasPrefix(prefix) else { return nil }
      let component = String(name.dropFirst(prefix.count))
      guard !component.isEmpty, !component.contains("/") else { return nil }
      return FTPDirectoryEntry(
        name: component, isDirectory: directories.contains(name), isSymbolicLink: false,
        size: files[name].map { Int64($0.count) }, modifiedAt: nil, posixPermissions: nil,
        source: .mlsd)
    }
  }

  func createDirectory(at path: String) async throws {
    guard !directories.contains(path), files[path] == nil else {
      throw CocoaError(.fileWriteFileExists)
    }
    directories.insert(path)
  }

  func createExclusiveDirectory(at path: String) async throws -> String {
    exclusiveCreateCount += 1
    try await createDirectory(at: path)
    if mode == .unknownDirectoryCreation {
      active = false
      throw FTPUniqueCreationError.creationOutcomeUnknown(directoryPath: "/destination")
    }
    return path
  }

  func writeUniqueFileContents(
    in directoryPath: String, suggestedName: String?,
    chunks: @escaping @Sendable () -> AsyncThrowingStream<Data, Error>,
    reserved: @escaping @Sendable (String) async throws -> Void,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws -> String {
    uniqueWriteCount += 1
    if mode == .unknownCreation {
      files[directoryPath + "/unidentified.bin"] = Data()
      throw FTPUniqueCreationError.creationOutcomeUnknown(directoryPath: directoryPath)
    }
    let name = suggestedName ?? "ftp-generated.txt"
    let expected = directoryPath + "/" + name
    if mode == .childCollision, suggestedName != nil { files[expected] = Data("external".utf8) }
    var actual = mode == .changesHints && suggestedName != nil ? expected + ".server" : expected
    var suffix = 1
    while files[actual] != nil || directories.contains(actual) {
      actual = expected + (suffix == 1 ? ".unique" : ".unique\(suffix)")
      suffix += 1
    }
    files[actual] = Data()
    try await reserved(actual)
    // 通常失敗は同期回復済み。同じsessionだけで所有物を掃除できる契約とする。
    if mode == .holdAfterReservation || mode == .disconnectedAfterReservation {
      isHoldingAfterReservation = true
      do {
        try await withTaskCancellationHandler {
          try await withCheckedThrowingContinuation { (value: CheckedContinuation<Void, Error>) in
            if Task.isCancelled {
              value.resume(throwing: CancellationError())
            } else {
              continuation = value
            }
          }
        } onCancel: {
          Task { await self.cancelHeldTransfer() }
        }
      } catch {
        if mode == .disconnectedAfterReservation {
          active = false
          throw FTPUniqueCreationError.creationOutcomeUnknown(directoryPath: directoryPath)
        }
        throw error
      }
    }
    for try await chunk in chunks() {
      files[actual]?.append(chunk)
      sentBytes += chunk.count
      progress(Int64(files[actual]?.count ?? 0))
      if mode == .partialFailure { throw CocoaError(.fileWriteUnknown) }
      if mode == .failsTopLevelOnce, suggestedName == nil, topLevelFailuresRemaining > 0 {
        topLevelFailuresRemaining -= 1
        throw CocoaError(.fileWriteUnknown)
      }
    }
    try Task.checkCancellation()
    return actual
  }

  private func cancelHeldTransfer() {
    continuation?.resume(throwing: CancellationError())
    continuation = nil
    isHoldingAfterReservation = false
  }

  func remove(at path: String, isDirectory: Bool) async throws {
    if isDirectory {
      guard !files.keys.contains(where: { $0.hasPrefix(path + "/") }),
        !directories.contains(where: { $0.hasPrefix(path + "/") })
      else { throw CocoaError(.fileWriteUnknown) }
      directories.remove(path)
    } else {
      files[path] = nil
    }
    removedPaths.append(path)
  }

  func rename(at _: String, to _: String) async throws {
    renameCount += 1
    throw CocoaError(.fileWriteUnknown)
  }
  func streamFileContents(of path: String, receive: @escaping @Sendable (Data) async throws -> Void)
    async throws
  {
    guard let data = files[path] else { throw CocoaError(.fileReadNoSuchFile) }
    try await receive(data)
  }
  func writeFileContents(
    to _: String, chunks _: AsyncThrowingStream<Data, Error>,
    progress _: @escaping @Sendable (Int64) -> Void
  ) async throws {
    ordinaryWriteCount += 1
    throw CocoaError(.fileWriteUnknown)
  }
  func fileSize(at path: String) async throws -> Int64? { files[path].map { Int64($0.count) } }
  func setPosixPermissions(_: Int, at _: String) async throws {}
  func isActive() async -> Bool { active }
  func close() async { active = false }
}
