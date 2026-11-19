import Foundation
import Testing

@testable import PKPane

@MainActor
struct SFTPCommitSafetyTests {
  @Test("外部編集の確定失敗と退避後取消でもコピーを保持し再送できる", arguments: [false, true])
  func retriesWorkingCopyAfterCommitFailure(cancelled: Bool) async throws {
    let localURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: localURL) }
    let edited = Data(repeating: 0x42, count: 2 * 1_024 * 1_024 + 3)
    try edited.write(to: localURL)
    let fixture = SFTPCommitFixture(failure: cancelled ? .cancel : .publish)
    let (provider, _, destination) = try makeProvider(fixture)
    if cancelled {
      let upload = Task {
        try await provider.uploadWorkingCopySafely(from: localURL, to: destination)
      }
      await waitUntil { await fixture.backupDidFinish }
      upload.cancel()
      await fixture.resumeBackup()
      await #expect(throws: CancellationError.self) { try await upload.value }
    } else {
      await #expect(throws: CocoaError(.fileWriteUnknown)) {
        try await provider.uploadWorkingCopySafely(from: localURL, to: destination)
      }
    }
    #expect(await fixture.files == SFTPCommitFixture.initialFiles)
    #expect(try Data(contentsOf: localURL) == edited)
    await fixture.clearFailure()
    try await provider.uploadWorkingCopySafely(from: localURL, to: destination)
    #expect(await fixture.files["/root/report.txt"] == edited)
    #expect(await fixture.files.count == 2)
    #expect(try Data(contentsOf: localURL) == edited)
  }

  @Test("確定失敗では旧宛先を復元し一時ファイルを保持する")
  func restoresOriginalOnPublishFailure() async throws {
    let fixture = SFTPCommitFixture(failure: .publish)
    let (provider, temporary, destination) = try makeProvider(fixture)
    await #expect(throws: CocoaError(.fileWriteUnknown)) {
      try await provider.commitTransferFile(
        from: temporary, to: destination, replacingExisting: true)
    }
    #expect(await fixture.files == SFTPCommitFixture.initialFiles)
    #expect(await fixture.removedPaths.isEmpty)
  }

  @Test("復元失敗と外部宛先作成は退避内容を救済可能なまま残す", arguments: [false, true])
  func retainsBackupWhenRestorationFails(externalDestination: Bool) async throws {
    let fixture = SFTPCommitFixture(failure: externalDestination ? .externalDestination : .restore)
    let (provider, temporary, destination) = try makeProvider(fixture)
    do {
      try await provider.commitTransferFile(
        from: temporary, to: destination, replacingExisting: true)
      Issue.record("確定・復元の二重失敗が成功扱いになった")
    } catch let error as SFTPCommitRecoveryError {
      #expect(error.operation == .restore)
      #expect(!error.backupFileName.contains("/"))
      #expect(!error.localizedDescription.contains("fixture.invalid"))
      let backupPath = "/root/" + error.backupFileName
      #expect(await fixture.files[backupPath] == Data("旧内容".utf8))
    }
    #expect(await fixture.files["/root/temporary.txt"] == Data("新内容".utf8))
    let expected = externalDestination ? Data("外部内容".utf8) : nil
    #expect(await fixture.files["/root/report.txt"] == expected)
    #expect(await fixture.removedPaths.isEmpty)
  }

  @Test("退避名競合は旧宛先も外部項目も変更しない")
  func refusesBackupNameCollision() async throws {
    let fixture = SFTPCommitFixture(failure: .backupCollision)
    let (provider, temporary, destination) = try makeProvider(fixture)
    await #expect(throws: CocoaError(.fileWriteFileExists)) {
      try await provider.commitTransferFile(
        from: temporary, to: destination, replacingExisting: true)
    }
    #expect(await fixture.files["/root/report.txt"] == Data("旧内容".utf8))
    #expect(await fixture.files["/root/temporary.txt"] == Data("新内容".utf8))
    #expect(await fixture.files.values.contains(Data("外部内容".utf8)))
    #expect(await fixture.removedPaths.isEmpty)
  }

  @Test("退避後の取消も取消されていないタスクで旧宛先を復元する")
  func restoresOriginalAfterCancellation() async throws {
    let fixture = SFTPCommitFixture(failure: .cancel)
    let (provider, temporary, destination) = try makeProvider(fixture)
    let task = Task {
      try await provider.commitTransferFile(
        from: temporary, to: destination, replacingExisting: true)
    }
    await waitUntil { await fixture.backupDidFinish }
    task.cancel()
    await fixture.resumeBackup()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await fixture.files == SFTPCommitFixture.initialFiles)
    #expect(await fixture.restorationWasCancelled == false)
  }

  @Test("確定後の退避削除失敗は完成宛先と旧内容を保持し退避名を通知する")
  func reportsBackupCleanupFailure() async throws {
    let fixture = SFTPCommitFixture(failure: .cleanup)
    let (provider, temporary, destination) = try makeProvider(fixture)
    do {
      try await provider.commitTransferFile(
        from: temporary, to: destination, replacingExisting: true)
      Issue.record("退避削除失敗が無通知になった")
    } catch let error as SFTPCommitRecoveryError {
      #expect(error.operation == .cleanup)
      #expect(await fixture.files["/root/" + error.backupFileName] == Data("旧内容".utf8))
    }
    #expect(await fixture.files["/root/report.txt"] == Data("新内容".utf8))
    #expect(await fixture.files["/root/temporary.txt"] == nil)
  }

  @Test("同一表記と同じ実体の確定は退避前に拒否する", arguments: [false, true])
  func rejectsSameDestination(alias: Bool) async throws {
    let fixture = SFTPCommitFixture(aliasesSource: alias)
    let (provider, temporary, destination) = try makeProvider(fixture)
    await #expect(throws: SFTPFileProviderError.invalidLocation) {
      try await provider.commitTransferFile(
        from: alias ? temporary : destination, to: destination, replacingExisting: true)
    }
    #expect(await fixture.files == SFTPCommitFixture.initialFiles)
    #expect(await fixture.renameCount == 0)
  }

  @Test("既存フォルダの確定は退避も再帰削除もしない")
  func refusesReplacingDirectory() async throws {
    let fixture = SFTPCommitFixture(destinationIsDirectory: true)
    let (provider, temporary, destination) = try makeProvider(fixture)
    await #expect(throws: CocoaError(.fileWriteFileExists)) {
      try await provider.commitTransferFile(
        from: temporary, to: destination, replacingExisting: true)
    }
    #expect(await fixture.renameCount == 0)
    #expect(await fixture.removedPaths.isEmpty)
  }

  @Test("リンクの置換後掃除はリンク先を変更しない")
  func replacesLinkWithoutDeletingItsTarget() async throws {
    let fixture = SFTPCommitFixture(destinationIsLink: true)
    let (provider, temporary, destination) = try makeProvider(fixture)
    try await provider.commitTransferFile(
      from: temporary, to: destination, replacingExisting: true)
    #expect(await fixture.files["/root/report.txt"] == Data("新内容".utf8))
    #expect(await fixture.files["/root/link-target.txt"] == Data("リンク先".utf8))
    #expect(await fixture.files.count == 2)
    #expect(await fixture.removedPaths.allSatisfy { $0.contains(".pkpane-replaced-") })
  }

  @Test("退避renameの応答喪失は退避名を通知し所有不明の項目を操作しない")
  func reportsUncertainBackupAfterResponseLoss() async throws {
    let fixture = SFTPCommitFixture(failure: .backupResponseLost)
    let (provider, temporary, destination) = try makeProvider(fixture)
    do {
      try await provider.commitTransferFile(
        from: temporary, to: destination, replacingExisting: true)
      Issue.record("退避の応答喪失が成功扱いになった")
    } catch let error as SFTPCommitRecoveryError {
      #expect(error.operation == .backup)
      #expect(error.originalFileName == "report.txt")
      #expect(!error.backupFileName.contains("/"))
      #expect(await fixture.files["/root/" + error.backupFileName] == Data("旧内容".utf8))
    }
    #expect(await fixture.files["/root/report.txt"] == nil)
    #expect(await fixture.files["/root/temporary.txt"] == Data("新内容".utf8))
    #expect(await fixture.renameCount == 1)
    #expect(await fixture.removedPaths.isEmpty)
  }

  @Test("確定renameの応答喪失は新宛先と旧退避を保持する")
  func preservesBothVersionsAfterPublishResponseLoss() async throws {
    let fixture = SFTPCommitFixture(failure: .publishResponseLost)
    let (provider, temporary, destination) = try makeProvider(fixture)
    do {
      try await provider.commitTransferFile(
        from: temporary, to: destination, replacingExisting: true)
      Issue.record("確定の応答喪失が成功扱いになった")
    } catch let error as SFTPCommitRecoveryError {
      #expect(error.operation == .restore)
      #expect(await fixture.files["/root/" + error.backupFileName] == Data("旧内容".utf8))
    }
    #expect(await fixture.files["/root/report.txt"] == Data("新内容".utf8))
    #expect(await fixture.files["/root/temporary.txt"] == nil)
    #expect(await fixture.removedPaths.isEmpty)
  }

  @Test("退避削除の応答喪失は結果未確認を通知し完成宛先を保持する")
  func reportsUncertainCleanupAfterResponseLoss() async throws {
    let fixture = SFTPCommitFixture(failure: .cleanupResponseLost)
    let (provider, temporary, destination) = try makeProvider(fixture)
    do {
      try await provider.commitTransferFile(
        from: temporary, to: destination, replacingExisting: true)
      Issue.record("削除の応答喪失が無通知になった")
    } catch let error as SFTPCommitRecoveryError {
      #expect(error.operation == .cleanup)
      #expect(error.localizedDescription.contains("除去結果を確認できません"))
      #expect(await fixture.files["/root/" + error.backupFileName] == nil)
    }
    #expect(await fixture.files["/root/report.txt"] == Data("新内容".utf8))
    #expect(await fixture.files.count == 1)
  }

  private func makeProvider(_ fixture: SFTPCommitFixture) throws
    -> (SFTPFileProvider, FileLocation, FileLocation)
  {
    let target = try SFTPConnectionTarget(host: "fixture.invalid", port: 22, username: "fixture")
    let provider = SFTPFileProvider(target: target, directoryListing: fixture)
    return (
      provider,
      FileLocation(remotePath: "/root/temporary.txt", providerID: provider.id),
      FileLocation(remotePath: "/root/report.txt", providerID: provider.id)
    )
  }
}

private actor SFTPCommitFixture: SFTPClientSession {
  enum Failure: Sendable, Equatable {
    case publish, restore, externalDestination, backupCollision, cleanup, cancel
    case backupResponseLost, publishResponseLost, cleanupResponseLost
  }
  static let initialFiles = [
    "/root/report.txt": Data("旧内容".utf8),
    "/root/temporary.txt": Data("新内容".utf8),
  ]
  private var failure: Failure?
  private let aliasesSource: Bool
  private let destinationIsDirectory: Bool
  private let destinationIsLink: Bool
  private var backupContinuation: CheckedContinuation<Void, Never>?
  private(set) var files = SFTPCommitFixture.initialFiles
  private(set) var removedPaths: [String] = []
  private(set) var renameCount = 0
  private(set) var backupDidFinish = false
  private(set) var restorationWasCancelled = false

  init(
    failure: Failure? = nil,
    aliasesSource: Bool = false,
    destinationIsDirectory: Bool = false,
    destinationIsLink: Bool = false
  ) {
    self.failure = failure
    self.aliasesSource = aliasesSource
    self.destinationIsDirectory = destinationIsDirectory
    self.destinationIsLink = destinationIsLink
    if destinationIsLink { files["/root/link-target.txt"] = Data("リンク先".utf8) }
  }

  func contents(of _: String) async throws -> [SFTPDirectoryEntry] {
    files.keys.map { path in
      SFTPDirectoryEntry(
        name: path.split(separator: "/").last.map(String.init) ?? "",
        isDirectory: destinationIsDirectory && path == "/root/report.txt",
        isSymbolicLink: destinationIsLink && path == "/root/report.txt")
    }
  }

  func realPath(of path: String) async throws -> String {
    if destinationIsLink, path == "/root/report.txt" { return "/root/link-target.txt" }
    return aliasesSource && path == "/root/temporary.txt" ? "/root/report.txt" : path
  }

  func rename(at source: String, to destination: String) async throws {
    renameCount += 1
    if destination.contains(".pkpane-replaced-"), failure == .backupCollision {
      files[destination] = Data("外部内容".utf8)
    }
    let isTemporary = source == "/root/temporary.txt" || source.contains(".pkpane-edit-")
    if isTemporary, failure == .publish || failure == .restore {
      throw CocoaError(.fileWriteUnknown)
    }
    if isTemporary, failure == .externalDestination {
      files[destination] = Data("外部内容".utf8)
      throw CocoaError(.fileWriteUnknown)
    }
    if source.contains(".pkpane-replaced-"), destination == "/root/report.txt" {
      restorationWasCancelled = Task.isCancelled
      try Task.checkCancellation()
      if failure == .restore { throw CocoaError(.fileWriteUnknown) }
    }
    guard files[destination] == nil else { throw CocoaError(.fileWriteFileExists) }
    guard let data = files.removeValue(forKey: source) else { throw CocoaError(.fileNoSuchFile) }
    files[destination] = data
    if destination.contains(".pkpane-replaced-"), failure == .backupResponseLost {
      throw CocoaError(.fileReadUnknown)
    }
    if isTemporary, failure == .publishResponseLost { throw CocoaError(.fileReadUnknown) }
    if destination.contains(".pkpane-replaced-"), failure == .cancel {
      backupDidFinish = true
      await withCheckedContinuation { backupContinuation = $0 }
    }
  }

  func clearFailure() { failure = nil }

  func writeFileContents(
    to path: String,
    chunks: AsyncThrowingStream<Data, Error>,
    replacingExisting: Bool,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws {
    if !replacingExisting, files[path] != nil { throw CocoaError(.fileWriteFileExists) }
    var data = Data()
    for try await chunk in chunks {
      data.append(chunk)
      progress(Int64(data.count))
    }
    files[path] = data
  }

  func resumeBackup() {
    backupContinuation?.resume()
    backupContinuation = nil
  }

  func remove(at path: String, isDirectory: Bool) async throws {
    #expect(!isDirectory)
    if failure == .cleanup { throw CocoaError(.fileWriteUnknown) }
    removedPaths.append(path)
    files[path] = nil
    if failure == .cleanupResponseLost { throw CocoaError(.fileReadUnknown) }
  }

  func createDirectory(at _: String) async throws {}
  func close() async throws {}
}
