import Foundation
import Testing

@testable import PKPane

@MainActor
struct FTPFileProviderTests {
  @Test("外部編集再送の切断と取消では旧宛先と未送信の作業コピーを保持する", arguments: [false, true])
  func preservesWorkingCopyWhenUploadFails(cancelled: Bool) async throws {
    let localURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: localURL) }
    let edited = Data(repeating: 0x42, count: 2 * 1_024 * 1_024)
    try edited.write(to: localURL)
    let original = Data("変更前".utf8)
    let session = FTPProviderSession(
      directories: ["/": [file("target.txt")]], files: ["/target.txt": original],
      failsWriting: true, writeFailureIsCancellation: cancelled)
    let provider = try makeProvider(session: session)
    let destination = FileLocation(remotePath: "/target.txt", providerID: provider.id)
    if cancelled {
      await #expect(throws: CancellationError.self) {
        try await provider.uploadWorkingCopySafely(from: localURL, to: destination)
      }
    } else {
      await #expect(throws: FTPTransportError.connectionClosed) {
        try await provider.uploadWorkingCopySafely(from: localURL, to: destination)
      }
    }
    #expect(await session.files == ["/target.txt": original])
    #expect(await session.renames.isEmpty)
    #expect(await session.removals.count == 1)
    #expect(try Data(contentsOf: localURL) == edited)
  }

  @Test("外部編集再送の実取消後も旧宛先を保持し同じ作業コピーから再試行できる")
  func retriesWorkingCopyAfterTaskCancellation() async throws {
    let localURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: localURL) }
    let edited = Data(repeating: 0x42, count: 2 * 1_024 * 1_024 + 3)
    try edited.write(to: localURL)
    let original = Data("変更前".utf8)
    let session = FTPProviderSession(
      directories: ["/": [file("target.txt")]], files: ["/target.txt": original],
      suspendsWriting: true)
    let provider = try makeProvider(session: session)
    let destination = FileLocation(remotePath: "/target.txt", providerID: provider.id)
    let upload = Task {
      try await provider.uploadWorkingCopySafely(from: localURL, to: destination)
    }
    await waitUntil { await session.writingDidStart }
    upload.cancel()
    await session.resumeWriting()
    await #expect(throws: CancellationError.self) { try await upload.value }
    #expect(await session.files == ["/target.txt": original])
    #expect(await session.renames.isEmpty)
    #expect(try Data(contentsOf: localURL) == edited)
    try await provider.uploadWorkingCopySafely(from: localURL, to: destination)
    #expect(await session.files == ["/target.txt": edited])
    #expect(try Data(contentsOf: localURL) == edited)
  }

  @Test(
    "FTP上書き転送は自己・祖先・子孫への破壊を削除前に拒否する",
    arguments: [0, 1, 2, 3])
  func replacingTransferRejectsDestructiveDestination(scenario: Int) async throws {
    let source =
      scenario == 0
      ? "/root/report.txt"
      : scenario == 2 ? "/root/A" : "/root/A/B/A"
    let destination = scenario == 2 ? "/root/A/Sub" : "/root"
    let isDirectory = scenario != 0
    let name = (source as NSString).lastPathComponent
    let entry = isDirectory ? directory(name) : file(name)
    let original = Data("移動元内容".utf8)
    let payloadPath = isDirectory ? source + "/keep.txt" : source
    var listings = [destination: [entry]]
    if scenario == 1 || scenario == 3 {
      listings["/root/A"] = [directory("B")]
      listings["/root/A/B"] = [directory("A")]
      listings[source] = [file("keep.txt")]
    }
    let session = FTPProviderSession(
      directories: listings, files: [payloadPath: original])
    let provider = try makeProvider(session: session)
    let item = remoteItem(path: source, providerID: provider.id, isDirectory: isDirectory)
    let location = FileLocation(remotePath: destination, providerID: provider.id)
    await #expect(throws: FTPFileProviderError.invalidLocation) {
      if scenario == 3 {
        try await provider.move(item, to: location, replacingExisting: true)
      } else {
        try await provider.copy(item, to: location, replacingExisting: true)
      }
    }
    #expect(await session.removals.isEmpty)
    #expect(await session.renames.isEmpty)
    #expect(await session.writtenPaths.isEmpty)
    #expect(await session.files[payloadPath] == original)
  }

  @Test("一覧、作成、改名、権限変更を共通Provider境界から実行する")
  func executesBasicProviderOperations() async throws {
    let session = FTPProviderSession(
      directories: [
        "/": [
          FTPDirectoryEntry(
            name: "folder", isDirectory: true, isSymbolicLink: false, size: nil,
            modifiedAt: nil, posixPermissions: 0o755, source: .mlsd),
          FTPDirectoryEntry(
            name: "file.txt", isDirectory: false, isSymbolicLink: false, size: 12,
            modifiedAt: nil, posixPermissions: 0o644, source: .mlsd),
        ]
      ])
    let provider = try makeProvider(session: session)
    let root = FileLocation(remotePath: "/", providerID: provider.id)

    let items = try await provider.contents(of: root)
    try await provider.createDirectory(named: "new", in: root)
    try await provider.rename(
      try #require(items.first { $0.name == "file.txt" }), to: "renamed.txt")
    try await provider.setPosixPermissions(0o600, at: items[1].location)

    #expect(items.map(\.name) == ["file.txt", "folder"])
    #expect(await session.createdDirectories == ["/new"])
    #expect(
      await session.renames == [FTPProviderRename(source: "/file.txt", destination: "/renamed.txt")]
    )
    #expect(await session.permissions == ["/folder": 0o600])
    #expect(provider.executableCapabilities.contains(.deletePermanently))
    let erasedProvider: any FileBrowserProvider = provider
    #expect(erasedProvider is any FileStreamTransferProvider)
  }

  @Test("非空フォルダを事前列挙後にリンクを辿らず子から親へ削除する")
  func recursivelyDeletesDirectoryWithoutFollowingSymlink() async throws {
    let session = FTPProviderSession(directories: [
      "/": [directory("folder")],
      "/folder": [file("a.txt"), directory("child"), symbolicLink("link")],
      "/folder/child": [file("deep.txt")],
    ])
    let provider = try makeProvider(session: session)
    let item = remoteItem(
      path: "/folder", providerID: provider.id, isDirectory: true)

    try await provider.permanentlyDelete(item)

    #expect(
      await session.removals == [
        FTPProviderRemoval(path: "/folder/a.txt", isDirectory: false),
        FTPProviderRemoval(path: "/folder/child/deep.txt", isDirectory: false),
        FTPProviderRemoval(path: "/folder/child", isDirectory: true),
        FTPProviderRemoval(path: "/folder/link", isDirectory: false),
        FTPProviderRemoval(path: "/folder", isDirectory: true),
      ])
    #expect(await session.listedPaths == ["/folder", "/folder/child"])
  }

  @Test("不正な列挙名があれば1件も削除しない")
  func rejectsUnsafeRemovalPlanBeforeDeleting() async throws {
    let session = FTPProviderSession(directories: [
      "/folder": [file("ok.txt"), file("../escape")]
    ])
    let provider = try makeProvider(session: session)
    let item = remoteItem(path: "/folder", providerID: provider.id, isDirectory: true)

    await #expect(throws: FTPFileProviderError.invalidLocation) {
      try await provider.permanentlyDelete(item)
    }
    #expect(await session.removals.isEmpty)
  }

  @Test("同一FTP内複製はRETRからSTORへストリーミングし連番名を使う")
  func duplicatesFileByStreaming() async throws {
    let session = FTPProviderSession(
      directories: [
        "/": [file("report.txt"), file("reportのコピー.txt")]
      ],
      files: ["/report.txt": Data("payload".utf8)])
    let provider = try makeProvider(session: session)
    let item = remoteItem(path: "/report.txt", providerID: provider.id, isDirectory: false)

    try await provider.duplicate(item)

    #expect(await session.files["/reportのコピー2.txt"] == Data("payload".utf8))
    #expect(await session.streamedPaths == ["/report.txt"])
    #expect(await session.writtenPaths == ["/reportのコピー2.txt"])
  }

  @Test("一時名のSIZE確認後に既存宛先を削除してrename確定する")
  func commitsStagedTransfer() async throws {
    let session = FTPProviderSession(
      directories: ["/": [file("target.txt")]],
      files: ["/.temporary": Data("new".utf8), "/target.txt": Data("old".utf8)])
    let provider = try makeProvider(session: session)
    let temporary = FileLocation(remotePath: "/.temporary", providerID: provider.id)
    let destination = FileLocation(remotePath: "/target.txt", providerID: provider.id)

    #expect(try await provider.stagedFileSize(at: temporary) == 3)
    try await provider.commitTransferFile(
      from: temporary,
      to: destination,
      replacingExisting: true)

    #expect(
      await session.removals == [
        FTPProviderRemoval(path: "/target.txt", isDirectory: false)
      ])
    #expect(
      await session.renames.last
        == FTPProviderRename(
          source: "/.temporary", destination: "/target.txt"))
  }

  @Test("FTPとローカルの間を共通転送キューで往復できる")
  func transfersFilesBetweenFTPAndLocalProviders() async throws {
    let localRoot = FileManager.default.temporaryDirectory.appending(
      path: "FTPFileProviderTransfers-\(UUID().uuidString)",
      directoryHint: .isDirectory)
    let localSource = localRoot.appending(path: "source", directoryHint: .isDirectory)
    let localDestination = localRoot.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: localSource, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: localDestination, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: localRoot) }

    let downloadData = Data("FTPから取得".utf8)
    let uploadData = Data("FTPへ移動".utf8)
    let uploadURL = localSource.appending(path: "upload.txt")
    try uploadData.write(to: uploadURL)
    let ftpSession = FTPProviderSession(
      directories: [
        "/": [
          FTPDirectoryEntry(
            name: "download.txt", isDirectory: false, isSymbolicLink: false,
            size: Int64(downloadData.count), modifiedAt: nil,
            posixPermissions: 0o644, source: .mlsd)
        ]
      ],
      files: ["/download.txt": downloadData])
    let ftpProvider = try makeProvider(session: ftpSession)
    let localProvider = LocalFileProvider()
    let queue = TransferQueue.isolatedForTesting()
    let ftpBrowser = FileBrowserSession(
      provider: ftpProvider,
      initialLocation: FileLocation(remotePath: "/", providerID: ftpProvider.id),
      transferQueue: queue)
    let localDestinationBrowser = FileBrowserSession(
      provider: localProvider,
      initialLocation: FileLocation(localURL: localDestination, providerID: localProvider.id),
      transferQueue: queue)
    let localSourceBrowser = FileBrowserSession(
      provider: localProvider,
      initialLocation: FileLocation(localURL: localSource, providerID: localProvider.id),
      transferQueue: queue)
    ftpBrowser.load()
    localDestinationBrowser.load()
    localSourceBrowser.load()
    await waitForLoading(ftpBrowser)
    await waitForLoading(localDestinationBrowser)
    await waitForLoading(localSourceBrowser)

    ftpBrowser.copy(
      [try #require(ftpBrowser.items.first { $0.name == "download.txt" })],
      to: localDestinationBrowser)
    await waitForTransfer(ftpBrowser)
    #expect(
      try Data(contentsOf: localDestination.appending(path: "download.txt")) == downloadData)

    localSourceBrowser.move(
      [try #require(localSourceBrowser.items.first { $0.name == "upload.txt" })],
      to: ftpBrowser)
    await waitForTransfer(localSourceBrowser)
    #expect(!FileManager.default.fileExists(atPath: uploadURL.path))
    #expect(await ftpSession.files["/upload.txt"] == uploadData)
  }

  @Test("FTP一覧待ち中も別のローカルペインを読み込める")
  func ftpListingWaitDoesNotBlockAnotherPane() async throws {
    let localRoot = FileManager.default.temporaryDirectory.appending(
      path: "FTPListingResponsiveness-\(UUID().uuidString)",
      directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
    try Data("local".utf8).write(to: localRoot.appending(path: "local.txt"))
    defer { try? FileManager.default.removeItem(at: localRoot) }

    let ftpSession = FTPProviderSession(directories: ["/": []], suspendsListing: true)
    let ftpProvider = try makeProvider(session: ftpSession)
    let localProvider = LocalFileProvider()
    let queue = TransferQueue.isolatedForTesting()
    let ftpBrowser = FileBrowserSession(
      provider: ftpProvider,
      initialLocation: FileLocation(remotePath: "/", providerID: ftpProvider.id),
      transferQueue: queue)
    let localBrowser = FileBrowserSession(
      provider: localProvider,
      initialLocation: FileLocation(localURL: localRoot, providerID: localProvider.id),
      transferQueue: queue)

    ftpBrowser.load()
    await waitUntil("FTP一覧待ちへ到達しなかった") { await ftpSession.listingDidStart }
    #expect(ftpBrowser.isLoading)
    localBrowser.load()
    await waitForLoading(localBrowser)
    #expect(localBrowser.items.map(\.name) == ["local.txt"])
    #expect(ftpBrowser.isLoading)

    await ftpSession.resumeListing()
    await waitForLoading(ftpBrowser)
  }

  @Test("FTP転送待ち中も別のローカルペインを操作できる")
  func ftpTransferWaitDoesNotBlockAnotherPane() async throws {
    let localRoot = FileManager.default.temporaryDirectory.appending(
      path: "FTPTransferResponsiveness-\(UUID().uuidString)",
      directoryHint: .isDirectory)
    let destinationRoot = localRoot.appending(path: "destination", directoryHint: .isDirectory)
    let otherRoot = localRoot.appending(path: "other", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
    try Data("other".utf8).write(to: otherRoot.appending(path: "other.txt"))
    defer { try? FileManager.default.removeItem(at: localRoot) }

    let payload = Data(repeating: 0x61, count: 8 * 1_024 * 1_024)
    let ftpSession = FTPProviderSession(
      directories: [
        "/": [
          FTPDirectoryEntry(
            name: "large.bin", isDirectory: false, isSymbolicLink: false,
            size: Int64(payload.count), modifiedAt: nil,
            posixPermissions: 0o644, source: .mlsd)
        ]
      ],
      files: ["/large.bin": payload],
      suspendsStreaming: true)
    let ftpProvider = try makeProvider(session: ftpSession)
    let localProvider = LocalFileProvider()
    let queue = TransferQueue.isolatedForTesting()
    let ftpBrowser = FileBrowserSession(
      provider: ftpProvider,
      initialLocation: FileLocation(remotePath: "/", providerID: ftpProvider.id),
      transferQueue: queue)
    let destinationBrowser = FileBrowserSession(
      provider: localProvider,
      initialLocation: FileLocation(localURL: destinationRoot, providerID: localProvider.id),
      transferQueue: queue)
    let otherBrowser = FileBrowserSession(
      provider: localProvider,
      initialLocation: FileLocation(localURL: otherRoot, providerID: localProvider.id),
      transferQueue: queue)
    ftpBrowser.load()
    destinationBrowser.load()
    await waitForLoading(ftpBrowser)
    await waitForLoading(destinationBrowser)

    ftpBrowser.copy([try #require(ftpBrowser.items.first)], to: destinationBrowser)
    await waitUntil("FTP転送待ちへ到達しなかった") { await ftpSession.streamingDidStart }
    #expect(ftpBrowser.isTransferring)
    otherBrowser.load()
    await waitForLoading(otherBrowser)
    #expect(otherBrowser.items.map(\.name) == ["other.txt"])
    #expect(ftpBrowser.isTransferring)

    await ftpSession.resumeStreaming()
    await waitForTransfer(ftpBrowser)
    #expect(try Data(contentsOf: destinationRoot.appending(path: "large.bin")) == payload)
  }

  private func waitForLoading(_ browser: FileBrowserSession) async {
    await waitUntil("一覧読み込みが完了しなかった") { !browser.isLoading }
  }

  private func waitForTransfer(_ browser: FileBrowserSession) async {
    await waitUntil("転送が完了しなかった") { !browser.isTransferring }
    try? await Task.sleep(for: .milliseconds(20))
  }

  private func makeProvider(session: FTPProviderSession) throws -> FTPFileProvider {
    let target = try FTPConnectionTarget(
      host: "example.com", username: "tester", security: .plain)
    return FTPFileProvider(
      target: target,
      session: session,
      sessionFactory: { session })
  }

  private func remoteItem(
    path: String,
    providerID: FileProviderID,
    isDirectory: Bool
  ) -> FileItem {
    FileItem(
      remotePath: path,
      url: URL(string: "ftp://example.com\(path)")!,
      providerID: providerID,
      isDirectory: isDirectory)
  }

  private func file(_ name: String) -> FTPDirectoryEntry {
    FTPDirectoryEntry(
      name: name, isDirectory: false, isSymbolicLink: false, size: nil,
      modifiedAt: nil, posixPermissions: nil, source: .mlsd)
  }

  private func directory(_ name: String) -> FTPDirectoryEntry {
    FTPDirectoryEntry(
      name: name, isDirectory: true, isSymbolicLink: false, size: nil,
      modifiedAt: nil, posixPermissions: nil, source: .mlsd)
  }

  private func symbolicLink(_ name: String) -> FTPDirectoryEntry {
    FTPDirectoryEntry(
      name: name, isDirectory: true, isSymbolicLink: true, size: nil,
      modifiedAt: nil, posixPermissions: nil, source: .mlsd)
  }
}

private struct FTPProviderRemoval: Equatable, Sendable {
  let path: String
  let isDirectory: Bool
}

private struct FTPProviderRename: Equatable, Sendable {
  let source: String
  let destination: String
}

private actor FTPProviderSession: FTPClientSession {
  private var directories: [String: [FTPDirectoryEntry]]
  private(set) var files: [String: Data]
  private(set) var listedPaths: [String] = []
  private(set) var createdDirectories: [String] = []
  private(set) var removals: [FTPProviderRemoval] = []
  private(set) var renames: [FTPProviderRename] = []
  private(set) var permissions: [String: Int] = [:]
  private(set) var streamedPaths: [String] = []
  private(set) var writtenPaths: [String] = []
  private(set) var listingDidStart = false
  private(set) var streamingDidStart = false
  private var suspendsListing: Bool
  private var suspendsStreaming: Bool
  private var listingContinuation: CheckedContinuation<Void, Never>?
  private var streamingContinuation: CheckedContinuation<Void, Never>?
  private var suspendsWriting: Bool
  private var writingContinuation: CheckedContinuation<Void, Never>?
  private(set) var writingDidStart = false
  private let failsWriting: Bool
  private let writeFailureIsCancellation: Bool

  init(
    directories: [String: [FTPDirectoryEntry]],
    files: [String: Data] = [:],
    suspendsListing: Bool = false,
    suspendsStreaming: Bool = false,
    failsWriting: Bool = false,
    writeFailureIsCancellation: Bool = false,
    suspendsWriting: Bool = false
  ) {
    self.directories = directories
    self.files = files
    self.suspendsListing = suspendsListing
    self.suspendsStreaming = suspendsStreaming
    self.suspendsWriting = suspendsWriting
    self.failsWriting = failsWriting
    self.writeFailureIsCancellation = writeFailureIsCancellation
  }

  func contents(of remotePath: String) async throws -> [FTPDirectoryEntry] {
    listedPaths.append(remotePath)
    if suspendsListing {
      listingDidStart = true
      await withCheckedContinuation { listingContinuation = $0 }
    }
    return directories[remotePath] ?? []
  }

  func createDirectory(at remotePath: String) async throws {
    createdDirectories.append(remotePath)
    directories[remotePath] = []
  }

  func remove(at remotePath: String, isDirectory: Bool) async throws {
    removals.append(FTPProviderRemoval(path: remotePath, isDirectory: isDirectory))
    directories.removeValue(forKey: remotePath)
    files.removeValue(forKey: remotePath)
  }

  func rename(at remotePath: String, to destinationPath: String) async throws {
    renames.append(FTPProviderRename(source: remotePath, destination: destinationPath))
    if let data = files.removeValue(forKey: remotePath) {
      files[destinationPath] = data
    }
  }

  func streamFileContents(
    of remotePath: String,
    receive: @escaping @Sendable (Data) async throws -> Void
  ) async throws {
    streamedPaths.append(remotePath)
    if suspendsStreaming {
      streamingDidStart = true
      await withCheckedContinuation { streamingContinuation = $0 }
    }
    try await receive(files[remotePath] ?? Data())
  }

  func writeFileContents(
    to remotePath: String,
    chunks: AsyncThrowingStream<Data, Error>,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws {
    writtenPaths.append(remotePath)
    var result = Data()
    for try await chunk in chunks {
      result.append(chunk)
      if suspendsWriting {
        files[remotePath] = result
        writingDidStart = true
        await withCheckedContinuation { writingContinuation = $0 }
      }
      if failsWriting {
        files[remotePath] = result
        if writeFailureIsCancellation { throw CancellationError() }
        throw FTPTransportError.connectionClosed
      }
      progress(Int64(result.count))
    }
    files[remotePath] = result
  }

  func fileSize(at remotePath: String) async throws -> Int64? {
    files[remotePath].map { Int64($0.count) }
  }

  func setPosixPermissions(_ permissions: Int, at remotePath: String) async throws {
    self.permissions[remotePath] = permissions
  }

  func resumeWriting() {
    suspendsWriting = false
    writingContinuation?.resume()
    writingContinuation = nil
  }

  func resumeListing() {
    suspendsListing = false
    listingContinuation?.resume()
    listingContinuation = nil
  }

  func resumeStreaming() {
    suspendsStreaming = false
    streamingContinuation?.resume()
    streamingContinuation = nil
  }

  func isActive() async -> Bool { true }
  func close() async {}
}
