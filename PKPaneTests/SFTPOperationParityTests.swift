import Foundation
import Testing

@testable import PKPane

@MainActor
struct SFTPOperationParityTests {
  @Test("SFTP v3の既存宛先rename拒否でも外部編集の再送を確定する")
  func replacesWorkingCopyOnNoReplaceRenameServer() async throws {
    let localURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: localURL) }
    let edited = Data("編集後".utf8)
    try edited.write(to: localURL)
    let state = InMemorySFTPParitySession(
      files: [
        "/root/report.txt": .init(
          data: Data("編集前".utf8), modifiedAt: .now, permissions: 0o640)
      ],
      rejectsExistingRename: true)
    let target = try SFTPConnectionTarget(host: "fixture.invalid", port: 22, username: "fixture")
    let provider = SFTPFileProvider(target: target, directoryListing: state)
    let destination = FileLocation(remotePath: "/root/report.txt", providerID: provider.id)
    try await provider.uploadWorkingCopySafely(from: localURL, to: destination)
    #expect(await state.data(at: "/root/report.txt") == edited)
    #expect(await state.filePaths == ["/root/report.txt"])
    #expect(try Data(contentsOf: localURL) == edited)
  }

  @Test("SFTP再送の実取消と通信断は旧宛先と作業コピーを保持し再試行できる", arguments: [false, true])
  func preservesAndRetriesWorkingCopyAfterUploadFailure(cancelled: Bool) async throws {
    let localURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: localURL) }
    let edited = Data(repeating: 0x42, count: 2 * 1_024 * 1_024 + 3)
    try edited.write(to: localURL)
    let original = Data("変更前".utf8)
    let state = InMemorySFTPParitySession(files: [
      "/root/report.txt": .init(data: original, modifiedAt: .now, permissions: 0o640)
    ])
    await state.configureUploadFailure(cancelled: cancelled)
    let target = try SFTPConnectionTarget(host: "fixture.invalid", port: 22, username: "fixture")
    let provider = SFTPFileProvider(target: target, directoryListing: state)
    let destination = FileLocation(remotePath: "/root/report.txt", providerID: provider.id)
    if cancelled {
      let upload = Task {
        try await provider.uploadWorkingCopySafely(from: localURL, to: destination)
      }
      await waitUntil { await state.writingDidStart }
      upload.cancel()
      await state.resumeWriting()
      await #expect(throws: CancellationError.self) { try await upload.value }
    } else {
      await #expect(throws: CocoaError(.fileReadUnknown)) {
        try await provider.uploadWorkingCopySafely(from: localURL, to: destination)
      }
    }
    #expect(await state.data(at: "/root/report.txt") == original)
    #expect(await state.filePaths == ["/root/report.txt"])
    #expect(try Data(contentsOf: localURL) == edited)

    await state.clearUploadFailure()
    try await provider.uploadWorkingCopySafely(from: localURL, to: destination)
    #expect(await state.data(at: "/root/report.txt") == edited)
    #expect(await state.filePaths == ["/root/report.txt"])
    #expect(try Data(contentsOf: localURL) == edited)
  }

  @Test("SFTPのプレビュー・情報・権限・検索・外部編集を共通ブラウザ経路から実行する")
  func browserRoutesRemoteFileOperations() async throws {
    let state = InMemorySFTPParitySession(files: [
      "/root/report.txt": .init(
        data: Data("編集前".utf8), modifiedAt: Date(timeIntervalSince1970: 10), permissions: 0o640),
      "/root/other.txt": .init(
        data: Data("対象外".utf8), modifiedAt: Date(timeIntervalSince1970: 10), permissions: 0o600),
    ])
    let previewRoot = FileManager.default.temporaryDirectory.appending(
      path: "sftp-parity-preview-\(UUID().uuidString)", directoryHint: .isDirectory)
    let editRoot = FileManager.default.temporaryDirectory.appending(
      path: "sftp-parity-edit-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer {
      try? FileManager.default.removeItem(at: previewRoot)
      try? FileManager.default.removeItem(at: editRoot)
    }
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let provider = SFTPFileProvider(
      target: target,
      directoryListing: state,
      previewCache: RemotePreviewCache(
        rootURL: previewRoot,
        legacyRootURL: previewRoot.appending(path: "legacy")))
    let browser = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: "/root", providerID: provider.id),
      transferQueue: .isolatedForTesting(),
      searchDebounceDuration: .zero)
    browser.load()
    await waitUntil("SFTP一覧を読み込めなかった") { !browser.isLoading }
    let item = try #require(browser.items.first { $0.name == "report.txt" })

    browser.preview(item)
    await waitUntil("SFTPプレビューを取得できなかった") { browser.previewURL != nil }
    #expect(try Data(contentsOf: #require(browser.previewURL)) == Data("編集前".utf8))

    let detailedItem = await browser.detailedItem(for: item)
    #expect(detailedItem.posixPermissions == 0o640)
    let permissionUpdated = try await browser.setPosixPermissions(0o660, for: item)
    #expect(permissionUpdated.posixPermissions == 0o660)

    browser.setSearchText("report")
    await waitUntil("SFTP検索が完了しなかった") { !browser.isSearching }
    #expect(browser.searchResults.map(\.item.name) == ["report.txt"])

    let controller = RemoteEditController(rootURL: editRoot, openWorkingCopy: { _ in })
    browser.editExternally(item, using: controller)
    await waitUntil("SFTP外部編集の作業コピーを作成できなかった") {
      controller.sessions.count == 1
    }
    let editSession = try #require(controller.sessions.first)
    try Data("編集後".utf8).write(to: editSession.workingCopyURL, options: .atomic)
    await controller.synchronizeNow(for: editSession.id)

    #expect(await state.data(at: "/root/report.txt") == Data("編集後".utf8))
    #expect(controller.sessions.first?.state == .synced)
  }

  @Test("SFTPの2ペイン比較から必須プレビューを経て同期する")
  func folderComparisonAndSyncUseSFTPProviderRoutes() async throws {
    let state = InMemorySFTPParitySession(files: [
      "/left/new.txt": .init(
        data: Data("新規".utf8), modifiedAt: Date(timeIntervalSince1970: 30), permissions: 0o640),
      "/left/report.txt": .init(
        data: Data("更新後".utf8), modifiedAt: Date(timeIntervalSince1970: 30), permissions: 0o640),
      "/right/report.txt": .init(
        data: Data("更新前".utf8), modifiedAt: Date(timeIntervalSince1970: 10), permissions: 0o640),
    ])
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let provider = SFTPFileProvider(target: target, directoryListing: state)
    let queue = TransferQueue.isolatedForTesting()
    let workspace = FileWorkspaceModel(
      initialBrowser: FileBrowserSession(
        provider: provider,
        initialLocation: FileLocation(remotePath: "/left", providerID: provider.id),
        transferQueue: queue))
    workspace.activatePane(.secondary)
    workspace.replaceActiveBrowser(
      with: FileBrowserSession(
        provider: provider,
        initialLocation: FileLocation(remotePath: "/right", providerID: provider.id),
        transferQueue: queue))
    let presentation = FolderComparisonPresentationState()

    #expect(presentation.handle(.executeFolderSync, workspace: workspace))
    let model = try #require(presentation.model)
    await waitUntil("SFTP比較と同期プレビューが完了しなかった") {
      model.isPresentingSyncPreview
    }
    #expect(model.snapshot?.entries.map(\.relativePath) == ["new.txt", "report.txt"])
    #expect(model.syncPlan?.summary.copyCount == 1)
    #expect(model.syncPlan?.summary.overwriteCount == 1)
    #expect(model.executeSyncPlan())
    await waitUntil(timeout: .seconds(5), "SFTP同期が完了しなかった") {
      !model.isSyncExecuting && model.syncExecutionSummary != nil
    }

    #expect(await state.data(at: "/right/new.txt") == Data("新規".utf8))
    #expect(await state.data(at: "/right/report.txt") == Data("更新後".utf8))
    #expect(model.syncExecutionSummary?.failureCount == 0)
  }
}

private actor InMemorySFTPParitySession: SFTPClientSession {
  struct FileState: Sendable {
    let data: Data
    let modifiedAt: Date
    let permissions: Int
  }

  private var files: [String: FileState]
  private var directories: Set<String>
  private let rejectsExistingRename: Bool
  private var failsWriting = false
  private var suspendsWriting = false
  private var writingContinuation: CheckedContinuation<Void, Never>?
  private(set) var writingDidStart = false
  var filePaths: [String] { files.keys.sorted() }

  func configureUploadFailure(cancelled: Bool) {
    failsWriting = !cancelled
    suspendsWriting = cancelled
  }

  func clearUploadFailure() {
    failsWriting = false
    suspendsWriting = false
  }

  func resumeWriting() {
    suspendsWriting = false
    writingContinuation?.resume()
    writingContinuation = nil
  }

  init(files: [String: FileState], rejectsExistingRename: Bool = true) {
    self.rejectsExistingRename = rejectsExistingRename
    self.files = files
    var directories: Set<String> = ["/"]
    for path in files.keys {
      var current = Self.parentPath(of: path)
      while current != "/" {
        directories.insert(current)
        current = Self.parentPath(of: current)
      }
    }
    self.directories = directories
  }

  func contents(of remotePath: String) async throws -> [SFTPDirectoryEntry] {
    let directory = Self.normalized(remotePath)
    let directoryEntries = directories.compactMap { path -> SFTPDirectoryEntry? in
      guard path != directory, Self.parentPath(of: path) == directory else { return nil }
      return SFTPDirectoryEntry(name: Self.name(of: path), isDirectory: true)
    }
    let fileEntries = files.compactMap { path, file -> SFTPDirectoryEntry? in
      guard Self.parentPath(of: path) == directory else { return nil }
      return SFTPDirectoryEntry(
        name: Self.name(of: path),
        isDirectory: false,
        size: Int64(file.data.count),
        modifiedAt: file.modifiedAt,
        posixPermissions: file.permissions)
    }
    return (directoryEntries + fileEntries).sorted { $0.name < $1.name }
  }

  func createDirectory(at remotePath: String) async throws {
    directories.insert(Self.normalized(remotePath))
  }

  func remove(at remotePath: String, isDirectory: Bool) async throws {
    let path = Self.normalized(remotePath)
    if isDirectory {
      directories.remove(path)
    } else {
      files[path] = nil
    }
  }

  func rename(at remotePath: String, to destinationPath: String) async throws {
    let source = Self.normalized(remotePath)
    let destination = Self.normalized(destinationPath)
    if rejectsExistingRename, files[destination] != nil || directories.contains(destination) {
      throw CocoaError(.fileWriteFileExists)
    }
    if let file = files.removeValue(forKey: source) {
      files[destination] = file
      return
    }
    if directories.remove(source) != nil {
      directories.insert(destination)
    }
  }

  func copy(
    at remotePath: String,
    to destinationPath: String,
    replacingExisting: Bool
  ) async throws {
    let source = Self.normalized(remotePath)
    let destination = Self.normalized(destinationPath)
    guard let file = files[source] else { throw CocoaError(.fileNoSuchFile) }
    if files[destination] != nil, !replacingExisting {
      throw CocoaError(.fileWriteFileExists)
    }
    files[destination] = file
  }

  func streamFileContents(
    of remotePath: String,
    chunkSize _: Int,
    receive: @escaping @Sendable (Data) async throws -> Void
  ) async throws {
    guard let file = files[Self.normalized(remotePath)] else {
      throw CocoaError(.fileNoSuchFile)
    }
    try await receive(file.data)
  }

  func writeFileContents(
    to remotePath: String,
    chunks: AsyncThrowingStream<Data, Error>,
    replacingExisting: Bool,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws {
    let path = Self.normalized(remotePath)
    if files[path] != nil, !replacingExisting {
      throw CocoaError(.fileWriteFileExists)
    }
    var data = Data()
    for try await chunk in chunks {
      data.append(chunk)
      if failsWriting {
        files[path] = FileState(data: data, modifiedAt: .now, permissions: 0o640)
        throw CocoaError(.fileReadUnknown)
      }
      if suspendsWriting {
        writingDidStart = true
        await withCheckedContinuation { writingContinuation = $0 }
      }
      progress(Int64(data.count))
    }
    files[path] = FileState(data: data, modifiedAt: .now, permissions: 0o640)
  }

  func fileContents(of remotePath: String) async throws -> Data {
    guard let file = files[Self.normalized(remotePath)] else {
      throw CocoaError(.fileNoSuchFile)
    }
    return file.data
  }

  func setPosixPermissions(_ permissions: Int, at remotePath: String) async throws {
    let path = Self.normalized(remotePath)
    guard let file = files[path] else { throw CocoaError(.fileNoSuchFile) }
    files[path] = FileState(
      data: file.data,
      modifiedAt: file.modifiedAt,
      permissions: permissions)
  }

  func close() async throws {}

  func data(at path: String) -> Data? {
    files[Self.normalized(path)]?.data
  }

  private static func normalized(_ path: String) -> String {
    guard path.count > 1, path.hasSuffix("/") else { return path }
    return String(path.dropLast())
  }

  private static func parentPath(of path: String) -> String {
    let normalizedPath = normalized(path)
    let components = normalizedPath.split(separator: "/")
    guard components.count > 1 else { return "/" }
    return "/" + components.dropLast().joined(separator: "/")
  }

  private static func name(of path: String) -> String {
    normalized(path).split(separator: "/").last.map(String.init) ?? "/"
  }
}
