import Foundation
import Synchronization
import Testing

@testable import PKPane

struct SMBDirectTransferEngineTests {
  @Test("並列読み込みでもチャンクをオフセット順に返す")
  func yieldsChunksInOffsetOrder() async throws {
    let source = Data((0..<4_096).map { UInt8($0 % 251) })
    let storage = FakeSMBTransferStorage(source: source)
    let engine = SMBDirectTransferEngine(factory: FakeSMBTransferClientFactory(storage: storage))
    let stream = await engine.fileChunks(at: "Documents/source.bin", chunkSize: 256)
    var received = Data()

    for try await chunk in stream {
      received.append(chunk)
    }

    #expect(received == source)
  }

  @Test("キャンセルを読み込み接続へ伝播する")
  func propagatesReadCancellation() async throws {
    let storage = FakeSMBTransferStorage(
      source: Data(repeating: 1, count: 8_192),
      holdsReads: true)
    let engine = SMBDirectTransferEngine(factory: FakeSMBTransferClientFactory(storage: storage))
    let stream = await engine.fileChunks(at: "Documents/source.bin", chunkSize: 256)
    let task = Task {
      for try await _ in stream {}
    }

    // metadata接続だけ閉じた状態と区別し、実読取8接続をgateで取消時点に固定する。
    await waitUntil { await storage.activeReadConnectionIDs.count == 8 }
    #expect(await storage.connectedConnectionIDs.count == 9)
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    await waitUntil("取消後にSMB読取タスクと接続が解放されなかった") {
      await storage.allConnectionsAreClosedAndReadsFinished
    }
    #expect(await storage.cancelledReadConnectionIDs.count == 8)
    #expect(await storage.closedConnectionCount == 9)
    withExtendedLifetime(stream) {}
  }

  @Test("部分書き込み応答の残りを同じオフセットから再送する")
  func continuesAfterPartialWriteResponse() async throws {
    let storage = FakeSMBTransferStorage(source: Data(), maximumWriteCount: 3)
    let engine = SMBDirectTransferEngine(factory: FakeSMBTransferClientFactory(storage: storage))
    let chunks = makeChunks([Data("abcdef".utf8), Data("ghij".utf8)])
    let progress = Mutex<[Int64]>([])

    try await engine.writeFileChunks(chunks, to: "Documents/.temporary", replacingExisting: false) {
      completedBytes in
      progress.withLock { $0.append(completedBytes) }
    }

    #expect(await storage.destinationData == Data("abcdefghij".utf8))
    #expect(progress.withLock { $0.last } == 10)
  }

  @Test("サーバーのmaxWriteSizeに合わせて書き込みを分割する")
  func splitsWritesAtMaximumWriteSize() async throws {
    let storage = FakeSMBTransferStorage(source: Data(), maximumWriteSize: 3)
    let engine = SMBDirectTransferEngine(factory: FakeSMBTransferClientFactory(storage: storage))

    try await engine.writeFileChunks(
      makeChunks([Data("abcdefgh".utf8)]),
      to: "Documents\\.temporary",
      replacingExisting: false,
      progress: { _ in })

    #expect(await storage.destinationData == Data("abcdefgh".utf8))
    #expect(await storage.writeSizes == [3, 3, 2])
  }

  @Test("接続失敗をフォールバック判定可能なエラーで返す")
  func reportsConnectionFailure() async {
    let engine = SMBDirectTransferEngine(factory: FailingSMBTransferClientFactory())
    let stream = await engine.fileChunks(at: "Documents/source.bin", chunkSize: 256)

    await #expect(throws: SMBDirectTransferError.connectionFailed) {
      for try await _ in stream {}
    }
  }

  @Test("直接SMB書き込み後に利用不可となっても検証と確定を同じエンジンで行う")
  func verifiesAndCommitsDirectWriteThroughRegisteredEngine() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = FakeSMBTransferStorage(source: Data())
    let cache = SMBDirectEngineCache()
    let provider = makeDirectProvider(root: root, storage: storage, cache: cache)
    let temporary = FileLocation(
      localURL: root.appending(path: ".report.txt.pkpane-transfer"),
      providerID: provider.id)
    let destination = FileLocation(
      localURL: root.appending(path: "report.txt"),
      providerID: provider.id)

    try await provider.writeFileChunks(
      makeChunks([Data("report".utf8)]),
      to: temporary,
      replacingExisting: false,
      progress: { _ in })
    let temporarySharePath = SMBSharePath(
      host: "nas.example.local",
      shareName: "Documents",
      relativePathComponents: [".report.txt.pkpane-transfer"])
    await cache.markUnavailable(for: temporarySharePath)
    let size = try await provider.stagedFileSize(at: temporary)
    try await provider.commitTransferFile(
      from: temporary,
      to: destination,
      replacingExisting: false)

    #expect(size == 6)
    #expect(
      await storage.metadataOperations == [
        .stat(".report.txt.pkpane-transfer"),
        .stat("report.txt"),
        .rename(from: ".report.txt.pkpane-transfer", to: "report.txt"),
      ])
    #expect(await storage.fileData(at: "report.txt") == Data("report".utf8))
    #expect(await cache.registeredDirectWrite(for: temporarySharePath) == nil)
  }

  @Test("直接SMB確定で置換するときは既存ファイルを退避してから確定する")
  func backsUpExistingFileBeforeDirectCommit() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = FakeSMBTransferStorage(source: Data())
    let provider = makeDirectProvider(root: root, storage: storage)
    let temporary = FileLocation(
      localURL: root.appending(path: ".report.txt.pkpane-transfer"),
      providerID: provider.id)
    let destination = FileLocation(
      localURL: root.appending(path: "report.txt"),
      providerID: provider.id)

    try await provider.writeFileChunks(
      makeChunks([Data("old".utf8)]),
      to: destination,
      replacingExisting: false,
      progress: { _ in })
    try await provider.writeFileChunks(
      makeChunks([Data("new".utf8)]),
      to: temporary,
      replacingExisting: false,
      progress: { _ in })
    try await provider.commitTransferFile(
      from: temporary,
      to: destination,
      replacingExisting: true)

    let operations = await storage.metadataOperations
    try #require(operations.count == 4)
    #expect(operations.first == .stat("report.txt"))
    guard case .rename(from: "report.txt", to: let backupPath) = operations[1] else {
      Issue.record("既存ファイルが退避されていません")
      return
    }
    #expect(backupPath.hasPrefix("report.txt.pkpane-replaced-"))
    #expect(
      operations[2]
        == .rename(from: ".report.txt.pkpane-transfer", to: "report.txt"))
    #expect(operations[3] == .delete(backupPath))
    #expect(await storage.fileData(at: "report.txt") == Data("new".utf8))
    #expect(await storage.fileData(at: backupPath) == nil)
  }

  @Test("直接SMB確定のrename失敗時は退避した既存ファイルを復元する")
  func restoresExistingFileAfterDirectCommitFailure() async throws {
    let storage = FakeSMBTransferStorage(
      source: Data(),
      initialFiles: [
        ".report.txt.pkpane-transfer": Data("new".utf8),
        "report.txt": Data("old".utf8),
      ],
      failingRenameSourcePaths: [".report.txt.pkpane-transfer"])
    let engine = SMBDirectTransferEngine(factory: FakeSMBTransferClientFactory(storage: storage))

    await #expect(throws: CocoaError.self) {
      try await engine.commitFile(
        temporaryPath: ".report.txt.pkpane-transfer",
        destinationPath: "report.txt",
        replacingExisting: true)
    }

    let operations = await storage.metadataOperations
    try #require(operations.count == 4)
    #expect(operations.first == .stat("report.txt"))
    guard case .rename(from: "report.txt", to: let backupPath) = operations[1] else {
      Issue.record("既存ファイルが退避されていません")
      return
    }
    #expect(
      operations[2]
        == .rename(from: ".report.txt.pkpane-transfer", to: "report.txt"))
    #expect(operations[3] == .rename(from: backupPath, to: "report.txt"))
    #expect(await storage.fileData(at: "report.txt") == Data("old".utf8))
    #expect(
      await storage.fileData(at: ".report.txt.pkpane-transfer") == Data("new".utf8))
  }

  @Test("直接SMB確定と復元の両方が失敗したときは退避名をエラーに含める")
  func reportsBackupNameAfterDirectCommitAndRestoreFailure() async throws {
    let storage = FakeSMBTransferStorage(
      source: Data(),
      initialFiles: [
        ".report.txt.pkpane-transfer": Data("new".utf8),
        "report.txt": Data("old".utf8),
      ],
      failingRenameSourcePaths: [".report.txt.pkpane-transfer"],
      failBackupRollback: true)
    let engine = SMBDirectTransferEngine(factory: FakeSMBTransferClientFactory(storage: storage))
    var caughtError: (any Error)?

    do {
      try await engine.commitFile(
        temporaryPath: ".report.txt.pkpane-transfer",
        destinationPath: "report.txt",
        replacingExisting: true)
      Issue.record("確定と復元が失敗したのにエラーが返りませんでした")
    } catch {
      caughtError = error
    }

    let operations = await storage.metadataOperations
    guard operations.count == 4,
      case .rename(from: "report.txt", to: let backupPath) = operations[1]
    else {
      Issue.record("既存ファイルの退避操作を確認できません")
      return
    }
    #expect(
      (caughtError as? SMBDirectTransferError)
        == .commitRollbackFailed(backupFileName: backupPath))
    #expect(caughtError?.localizedDescription.contains(backupPath) == true)
    #expect(await storage.fileData(at: backupPath) == Data("old".utf8))
  }

  @Test("直接SMB確定後の退避削除失敗は転送を失敗扱いにしない")
  func succeedsDirectCommitWhenBackupDeletionFails() async throws {
    let storage = FakeSMBTransferStorage(
      source: Data(),
      initialFiles: [
        ".report.txt.pkpane-transfer": Data("new".utf8),
        "report.txt": Data("old".utf8),
      ],
      failBackupDeletion: true)
    let engine = SMBDirectTransferEngine(factory: FakeSMBTransferClientFactory(storage: storage))
    let cleanupPaths = Mutex<[String]>([])

    try await engine.commitFile(
      temporaryPath: ".report.txt.pkpane-transfer",
      destinationPath: "report.txt",
      replacingExisting: true
    ) { backupPath in
      cleanupPaths.withLock { $0.append(backupPath) }
    }

    let operations = await storage.metadataOperations
    guard operations.count == 4,
      case .rename(from: "report.txt", to: let backupPath) = operations[1]
    else {
      Issue.record("既存ファイルの退避操作を確認できません")
      return
    }
    #expect(operations[3] == .delete(backupPath))
    #expect(cleanupPaths.withLock { $0 } == [backupPath])
    #expect(await storage.fileData(at: "report.txt") == Data("new".utf8))
    #expect(await storage.fileData(at: backupPath) == Data("old".utf8))
  }

  @Test("置換しない直接SMB確定は既存衝突をfileWriteFileExistsで返す")
  func rejectsExistingDestinationWithoutReplacement() async throws {
    let storage = FakeSMBTransferStorage(
      source: Data(),
      initialFiles: [
        ".report.txt.pkpane-transfer": Data("new".utf8),
        "report.txt": Data("old".utf8),
      ])
    let engine = SMBDirectTransferEngine(factory: FakeSMBTransferClientFactory(storage: storage))

    do {
      try await engine.commitFile(
        temporaryPath: ".report.txt.pkpane-transfer",
        destinationPath: "report.txt",
        replacingExisting: false)
      Issue.record("既存ファイルへの確定が成功しました")
    } catch {
      #expect((error as? CocoaError)?.code == .fileWriteFileExists)
    }

    #expect(await storage.metadataOperations == [.stat("report.txt")])
    #expect(await storage.fileData(at: "report.txt") == Data("old".utf8))
    #expect(
      await storage.fileData(at: ".report.txt.pkpane-transfer") == Data("new".utf8))
  }

  @Test("存在しない直接SMBファイルの削除は冪等に成功する")
  func ignoresMissingFileWhenDeleting() async throws {
    let storage = FakeSMBTransferStorage(source: Data())
    let engine = SMBDirectTransferEngine(factory: FakeSMBTransferClientFactory(storage: storage))

    try await engine.deleteFile(at: ".missing.pkpane-transfer")

    #expect(await storage.metadataOperations == [.delete(".missing.pkpane-transfer")])
  }

  @Test("直接SMB書き込みの破棄はエンジン経由で一時ファイルを削除する")
  func discardsDirectWriteThroughEngine() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = FakeSMBTransferStorage(source: Data())
    let provider = makeDirectProvider(root: root, storage: storage)
    let temporary = FileLocation(
      localURL: root.appending(path: ".report.txt.pkpane-transfer"),
      providerID: provider.id)

    try await provider.writeFileChunks(
      makeChunks([Data("discard".utf8)]),
      to: temporary,
      replacingExisting: false,
      progress: { _ in })
    await provider.discardTransferFile(at: temporary)

    #expect(await storage.metadataOperations == [.delete(".report.txt.pkpane-transfer")])
    #expect(await storage.fileData(at: ".report.txt.pkpane-transfer") == nil)
  }

  @Test("直接SMB破棄の削除失敗時はマウント経由でも一時ファイルを削除する")
  func fallsBackToMountedDeleteAfterDirectDiscardFailure() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = FakeSMBTransferStorage(
      source: Data(),
      failingDeletePaths: [".report.txt.pkpane-transfer"])
    let cache = SMBDirectEngineCache()
    let provider = makeDirectProvider(root: root, storage: storage, cache: cache)
    let temporaryURL = root.appending(path: ".report.txt.pkpane-transfer")
    let temporary = FileLocation(localURL: temporaryURL, providerID: provider.id)

    try await provider.writeFileChunks(
      makeChunks([Data("discard".utf8)]),
      to: temporary,
      replacingExisting: false,
      progress: { _ in })
    try Data("mounted-cache".utf8).write(to: temporaryURL)
    await provider.discardTransferFile(at: temporary)

    #expect(!FileManager.default.fileExists(atPath: temporaryURL.path))
    #expect(
      await storage.fileData(at: ".report.txt.pkpane-transfer") == Data("discard".utf8))
    #expect(await storage.metadataOperations == [.delete(".report.txt.pkpane-transfer")])
    let temporarySharePath = SMBSharePath(
      host: "nas.example.local",
      shareName: "Documents",
      relativePathComponents: [".report.txt.pkpane-transfer"])
    #expect(await cache.registeredDirectWrite(for: temporarySharePath) == nil)
  }

  @Test("直接SMB確定失敗後も書き込み登録を解除する")
  func unregistersDirectWriteAfterCommitFailure() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let storage = FakeSMBTransferStorage(
      source: Data(),
      failingRenameSourcePaths: [".report.txt.pkpane-transfer"])
    let cache = SMBDirectEngineCache()
    let provider = makeDirectProvider(root: root, storage: storage, cache: cache)
    let temporary = FileLocation(
      localURL: root.appending(path: ".report.txt.pkpane-transfer"),
      providerID: provider.id)
    let destination = FileLocation(
      localURL: root.appending(path: "report.txt"),
      providerID: provider.id)

    try await provider.writeFileChunks(
      makeChunks([Data("new".utf8)]),
      to: temporary,
      replacingExisting: false,
      progress: { _ in })
    await #expect(throws: CocoaError.self) {
      try await provider.commitTransferFile(
        from: temporary,
        to: destination,
        replacingExisting: false)
    }

    let temporarySharePath = SMBSharePath(
      host: "nas.example.local",
      shareName: "Documents",
      relativePathComponents: [".report.txt.pkpane-transfer"])
    #expect(await cache.registeredDirectWrite(for: temporarySharePath) == nil)
  }

  @Test("直接SMBエンジンがない場合はFileManagerで確定と破棄を行う")
  func commitsAndDiscardsThroughFileManagerWithoutDirectEngine() async throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = MountedVolumeProvider(
      volumeURL: root,
      sharePathResolver: { _ in nil },
      directTransferCache: SMBDirectEngineCache())
    let temporaryURL = root.appending(path: ".report.txt.pkpane-transfer")
    let destinationURL = root.appending(path: "report.txt")
    try Data("fallback".utf8).write(to: temporaryURL)
    let temporary = FileLocation(localURL: temporaryURL, providerID: provider.id)
    let destination = FileLocation(localURL: destinationURL, providerID: provider.id)

    try await provider.commitTransferFile(
      from: temporary,
      to: destination,
      replacingExisting: false)
    #expect(try Data(contentsOf: destinationURL) == Data("fallback".utf8))

    let discardedURL = root.appending(path: ".discard.pkpane-transfer")
    try Data("discard".utf8).write(to: discardedURL)
    await provider.discardTransferFile(
      at: FileLocation(localURL: discardedURL, providerID: provider.id))
    #expect(!FileManager.default.fileExists(atPath: discardedURL.path))
  }

  private func makeChunks(_ chunks: [Data]) -> AsyncThrowingStream<Data, Error> {
    AsyncThrowingStream { continuation in
      for chunk in chunks { continuation.yield(chunk) }
      continuation.finish()
    }
  }

  private func makeTemporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func makeDirectProvider(
    root: URL,
    storage: FakeSMBTransferStorage,
    cache: SMBDirectEngineCache = SMBDirectEngineCache()
  ) -> MountedVolumeProvider {
    let rootPathComponents = root.standardizedFileURL.pathComponents
    return MountedVolumeProvider(
      volumeURL: root,
      credentialResolver: FakeSMBCredentialResolver(),
      sharePathResolver: { url in
        let pathComponents = url.standardizedFileURL.pathComponents
        guard pathComponents.starts(with: rootPathComponents) else { return nil }
        return SMBSharePath(
          host: "nas.example.local",
          shareName: "Documents",
          relativePathComponents: Array(pathComponents.dropFirst(rootPathComponents.count)))
      },
      directTransferEngine: { _ in
        SMBDirectTransferEngine(factory: FakeSMBTransferClientFactory(storage: storage))
      },
      directTransferCache: cache)
  }
}

private struct FakeSMBCredentialResolver: SMBDirectCredentialResolving {
  func credentials(forServer _: String, preferredAccount _: String?) -> SMBDirectCredentials? {
    SMBDirectCredentials(account: "tester", password: "password")
  }
}

private struct FakeSMBTransferClientFactory: SMBDirectTransferClientFactory {
  let storage: FakeSMBTransferStorage

  func connect() async throws -> any SMBDirectTransferClient {
    let connectionID = await storage.registerConnection()
    return FakeSMBTransferClient(storage: storage, connectionID: connectionID)
  }
}

private struct FailingSMBTransferClientFactory: SMBDirectTransferClientFactory {
  func connect() async throws -> any SMBDirectTransferClient {
    throw SMBDirectTransferError.connectionFailed
  }
}

private actor FakeSMBTransferClient: SMBDirectTransferClient {
  let storage: FakeSMBTransferStorage
  let connectionID: UUID
  private var destinationPath: String?

  init(storage: FakeSMBTransferStorage, connectionID: UUID) {
    self.storage = storage
    self.connectionID = connectionID
  }

  func fileSize(at path: String) async throws -> UInt64 {
    try await storage.fileSize(at: path)
  }

  func fileExists(at path: String) async throws -> Bool {
    await storage.fileExists(at: path)
  }

  func read(at path: String, offset: UInt64, length: Int) async throws -> Data {
    try await storage.delayReadIfNeeded(connectionID: connectionID)
    guard let source = await storage.fileData(at: path) else {
      throw CocoaError(.fileReadNoSuchFile)
    }
    let start = Int(offset)
    guard start < source.count else { return Data() }
    let end = min(start + length, source.count)
    return source.subdata(in: start..<end)
  }

  func prepareDestination(at path: String, replacingExisting: Bool) async throws {
    try await storage.prepareDestination(at: path, replacingExisting: replacingExisting)
  }

  func openDestination(at path: String) async throws {
    destinationPath = path
  }

  func write(_ data: Data, at offset: UInt64) async throws -> Int {
    guard let destinationPath else {
      throw SMBDirectTransferError.internalConsistencyFailure
    }
    return await storage.write(data, to: destinationPath, at: offset)
  }

  func renameFile(from temporaryPath: String, to destinationPath: String) async throws {
    try await storage.renameFile(from: temporaryPath, to: destinationPath)
  }

  func deleteFile(at path: String) async throws {
    do {
      try await storage.deleteFile(at: path)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return
    }
  }

  func maximumWriteSize() async -> Int {
    storage.maximumWriteSize
  }

  func close() async {
    await storage.recordClosedConnection(connectionID)
  }
}

private actor FakeSMBTransferStorage {
  let maximumWriteCount: Int
  let maximumWriteSize: Int
  let readDelay: Duration?
  let holdsReads: Bool
  let failingRenameSourcePaths: Set<String>
  let failingDeletePaths: Set<String>
  let failBackupRollback: Bool
  let failBackupDeletion: Bool
  private(set) var closedConnectionCount = 0
  private(set) var connectedConnectionIDs: Set<UUID> = []
  private(set) var closedConnectionIDs: Set<UUID> = []
  private(set) var activeReadConnectionIDs: Set<UUID> = []
  private(set) var cancelledReadConnectionIDs: Set<UUID> = []
  private var readContinuations: [UUID: CheckedContinuation<Void, Error>] = [:]
  private(set) var writeSizes: [Int] = []
  private(set) var metadataOperations: [FakeSMBMetadataOperation] = []
  private var files: [String: Data]
  private var lastPreparedPath: String?

  var destinationData: Data {
    guard let lastPreparedPath else { return Data() }
    return files[lastPreparedPath] ?? Data()
  }

  init(
    source: Data,
    maximumWriteCount: Int = .max,
    maximumWriteSize: Int = .max,
    readDelay: Duration? = nil,
    holdsReads: Bool = false,
    initialFiles: [String: Data] = [:],
    failingRenameSourcePaths: Set<String> = [],
    failingDeletePaths: Set<String> = [],
    failBackupRollback: Bool = false,
    failBackupDeletion: Bool = false
  ) {
    self.maximumWriteCount = maximumWriteCount
    self.maximumWriteSize = maximumWriteSize
    self.readDelay = readDelay
    self.holdsReads = holdsReads
    self.failingRenameSourcePaths = failingRenameSourcePaths
    self.failingDeletePaths = failingDeletePaths
    self.failBackupRollback = failBackupRollback
    self.failBackupDeletion = failBackupDeletion
    files = ["Documents/source.bin": source]
    files.merge(initialFiles) { _, initial in initial }
  }

  var allConnectionsAreClosedAndReadsFinished: Bool {
    connectedConnectionIDs == closedConnectionIDs && activeReadConnectionIDs.isEmpty
  }

  func registerConnection() -> UUID {
    let id = UUID()
    connectedConnectionIDs.insert(id)
    return id
  }

  func delayReadIfNeeded(connectionID: UUID) async throws {
    activeReadConnectionIDs.insert(connectionID)
    defer { activeReadConnectionIDs.remove(connectionID) }
    if holdsReads {
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<Void, Error>) in
          if Task.isCancelled {
            cancelledReadConnectionIDs.insert(connectionID)
            continuation.resume(throwing: CancellationError())
          } else {
            readContinuations[connectionID] = continuation
          }
        }
      } onCancel: {
        Task { await self.cancelRead(connectionID) }
      }
    }
    if let readDelay { try await Task.sleep(for: readDelay) }
  }

  private func cancelRead(_ connectionID: UUID) {
    guard let continuation = readContinuations.removeValue(forKey: connectionID) else { return }
    cancelledReadConnectionIDs.insert(connectionID)
    continuation.resume(throwing: CancellationError())
  }

  func fileData(at path: String) -> Data? {
    files[path]
  }

  func fileSize(at path: String) throws -> UInt64 {
    metadataOperations.append(.stat(path))
    guard let data = files[path] else { throw CocoaError(.fileReadNoSuchFile) }
    return UInt64(data.count)
  }

  func fileExists(at path: String) -> Bool {
    metadataOperations.append(.stat(path))
    return files[path] != nil
  }

  func prepareDestination(at path: String, replacingExisting: Bool) throws {
    if files[path] != nil, !replacingExisting {
      throw CocoaError(.fileWriteFileExists)
    }
    files[path] = Data()
    lastPreparedPath = path
  }

  func write(_ data: Data, to path: String, at offset: UInt64) -> Int {
    writeSizes.append(data.count)
    let count = min(maximumWriteCount, data.count)
    let start = Int(offset)
    let end = start + count
    var destinationData = files[path] ?? Data()
    if destinationData.count < end {
      destinationData.append(Data(repeating: 0, count: end - destinationData.count))
    }
    destinationData.replaceSubrange(start..<end, with: data.prefix(count))
    files[path] = destinationData
    return count
  }

  func renameFile(from temporaryPath: String, to destinationPath: String) throws {
    metadataOperations.append(.rename(from: temporaryPath, to: destinationPath))
    if failingRenameSourcePaths.contains(temporaryPath)
      || (failBackupRollback && temporaryPath.contains(".pkpane-replaced-"))
    {
      throw CocoaError(.fileWriteUnknown)
    }
    guard let data = files.removeValue(forKey: temporaryPath) else {
      throw CocoaError(.fileReadNoSuchFile)
    }
    guard files[destinationPath] == nil else { throw CocoaError(.fileWriteFileExists) }
    files[destinationPath] = data
  }

  func deleteFile(at path: String) throws {
    metadataOperations.append(.delete(path))
    if failingDeletePaths.contains(path)
      || (failBackupDeletion && path.contains(".pkpane-replaced-"))
    {
      throw CocoaError(.fileWriteUnknown)
    }
    guard files[path] != nil else { throw CocoaError(.fileReadNoSuchFile) }
    files[path] = nil
  }

  func recordClosedConnection(_ connectionID: UUID) {
    closedConnectionIDs.insert(connectionID)
    closedConnectionCount = closedConnectionIDs.count
  }
}

private enum FakeSMBMetadataOperation: Equatable, Sendable {
  case stat(String)
  case rename(from: String, to: String)
  case delete(String)
}
