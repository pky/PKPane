import Foundation
import Testing
import ZIPFoundation

@testable import PKPane

struct RemoteArchiveServiceTests {
  @MainActor
  @Test("SFTPセッションで既存の圧縮導線が有効になり作成結果を再表示する")
  func fileBrowserSessionEnablesRemoteArchiveCreation() async throws {
    let fixture = try RemoteArchiveFixture(
      files: ["/note.txt": Data("note".utf8)])
    defer { fixture.removeStagingRoot() }
    let browser = FileBrowserSession(
      provider: fixture.provider,
      initialLocation: fixture.rootLocation,
      transferQueue: .isolatedForTesting(),
      remoteArchiveService: fixture.service)
    browser.load()
    await waitUntil { !browser.isLoading }
    let item = try #require(browser.items.first)

    #expect(browser.canArchive)
    #expect(browser.canCreateArchive(from: [item]))
    browser.createArchive([item])
    #expect(browser.isArchiving)
    await waitUntil { !browser.isArchiving }

    #expect(browser.errorMessage == nil)
    #expect(browser.items.contains(where: { $0.name == "note.txt.zip" }))
    #expect(
      browser.revealRequest?.itemURL
        == browser.items.first {
          $0.name == "note.txt.zip"
        }?.url)
  }

  @Test("SFTP項目を一時領域でZIP化し一時名から確定する")
  func createsRemoteZIPAndCommitsIt() async throws {
    let fixture = try RemoteArchiveFixture(
      files: [
        "/report.txt": Data("remote report".utf8),
        "/report.txt.zip": Data("existing".utf8),
      ])
    defer { fixture.removeStagingRoot() }
    let items = try await fixture.provider.contents(of: fixture.rootLocation)
    let item = try #require(
      items.first {
        $0.name == "report.txt"
      })

    let createdName = try await fixture.service.createArchive(
      from: [item],
      in: fixture.rootLocation,
      preferredName: "report.txt.zip",
      format: .zip,
      using: fixture.provider,
      archiveService: ArchiveService())

    #expect(createdName == "report.txt2.zip")
    let archiveData = try #require(await fixture.session.fileData(at: "/report.txt2.zip"))
    let archiveURL = fixture.stagingRoot.deletingLastPathComponent().appending(
      path: "created-\(UUID().uuidString).zip")
    defer { try? FileManager.default.removeItem(at: archiveURL) }
    try archiveData.write(to: archiveURL)
    let archive = try Archive(url: archiveURL, accessMode: .read)
    #expect(Array(archive).map(\.path) == ["report.txt"])
    #expect(await fixture.session.hiddenArchivePaths().isEmpty)
    #expect(fixture.stagingDirectoryIsEmpty)
  }

  @Test("SFTPフォルダを再帰取得して7zとして確定する")
  func createsRemoteSevenZipFromDirectoryTree() async throws {
    let fixture = try RemoteArchiveFixture(
      files: ["/Folder/inside.txt": Data("nested".utf8)])
    defer { fixture.removeStagingRoot() }
    let item = try #require(try await fixture.provider.contents(of: fixture.rootLocation).first)

    let createdName = try await fixture.service.createArchive(
      from: [item],
      in: fixture.rootLocation,
      preferredName: "Folder.7z",
      format: .sevenZip,
      using: fixture.provider,
      archiveService: ArchiveService())

    #expect(createdName == "Folder.7z")
    let archiveData = try #require(await fixture.session.fileData(at: "/Folder.7z"))
    #expect(archiveData.starts(with: [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]))
    #expect(await fixture.session.hiddenArchivePaths().isEmpty)
    #expect(fixture.stagingDirectoryIsEmpty)
  }

  @Test("SFTP上のZIPを安全検査後に展開し隠し一時名を残さない")
  func extractsRemoteZIPAndCommitsTopLevelItems() async throws {
    let fixture = try RemoteArchiveFixture(
      files: [
        "/sample.zip": try makeZIPData(
          entryPath: "inside.txt",
          contents: Data("expanded".utf8))
      ])
    defer { fixture.removeStagingRoot() }
    let item = try #require(try await fixture.provider.contents(of: fixture.rootLocation).first)

    try await fixture.service.extractArchive(
      item,
      in: fixture.rootLocation,
      destination: .currentDirectory,
      using: fixture.provider,
      archiveService: ArchiveService())

    #expect(await fixture.session.fileData(at: "/inside.txt") == Data("expanded".utf8))
    #expect(await fixture.session.hiddenArchivePaths().isEmpty)
    #expect(fixture.stagingDirectoryIsEmpty)
  }

  @Test("リモートZIP展開はmacOS側車を本体とともにbyte保全する", arguments: [false, true])
  func preservesAppleDoubleMetadataDuringRemoteExtraction(inFolder: Bool) async throws {
    let metadata = makeResourceForkAppleDouble()
    let original = Data("photo contents".utf8)
    let archiveData = try makeZIPData(entries: [
      ("Photo.jpg", original), ("__MACOSX/._Photo.jpg", metadata),
    ])
    let fixture = try RemoteArchiveFixture(files: ["/sample.zip": archiveData])
    defer { fixture.removeStagingRoot() }
    let item = try #require(try await fixture.provider.contents(of: fixture.rootLocation).first)
    try await fixture.service.extractArchive(
      item, in: fixture.rootLocation,
      destination: inFolder ? .folderNamedAfterArchive : .currentDirectory,
      using: fixture.provider, archiveService: ArchiveService())
    let prefix = inFolder ? "/sample" : ""
    #expect(await fixture.session.fileData(at: prefix + "/Photo.jpg") == original)
    #expect(await fixture.session.fileData(at: prefix + "/__MACOSX/._Photo.jpg") == metadata)
    #expect(await fixture.session.fileData(at: "/sample.zip") == archiveData)
    #expect(await fixture.session.hiddenArchivePaths().isEmpty)
    #expect(fixture.stagingDirectoryIsEmpty)
  }

  @Test("リモートZIP直下の._項目も単独と混在の両方で保持する", arguments: [false, true], [false, true])
  func preservesRootDotUnderscoreFiles(inFolder: Bool, single: Bool) async throws {
    let original = Data("user data".utf8)
    var entries = [("._user", original)]
    if !single { entries.append(("normal", Data("normal".utf8))) }
    let archiveData = try makeZIPData(entries: entries)
    let fixture = try RemoteArchiveFixture(files: ["/sample.zip": archiveData])
    defer { fixture.removeStagingRoot() }
    let item = try #require(try await fixture.provider.contents(of: fixture.rootLocation).first)
    try await fixture.service.extractArchive(
      item, in: fixture.rootLocation,
      destination: inFolder ? .folderNamedAfterArchive : .currentDirectory,
      using: fixture.provider, archiveService: ArchiveService())
    let prefix = inFolder ? "/sample" : ""
    #expect(await fixture.session.fileData(at: prefix + "/._user") == original)
    if !single {
      #expect(await fixture.session.fileData(at: prefix + "/normal") == Data("normal".utf8))
    }
    #expect(await fixture.session.fileData(at: "/sample.zip") == archiveData)
    #expect(await fixture.session.hiddenArchivePaths().isEmpty)
    #expect(fixture.stagingDirectoryIsEmpty)
  }

  @Test("SFTPアーカイブ展開は一時容量の残量を安全上限として適用する")
  func extractionRespectsRemainingStagingCapacity() async throws {
    let archiveData = try makeZIPData(
      entryPath: "large.txt",
      contents: Data(repeating: 0, count: 1_024))
    let fixture = try RemoteArchiveFixture(
      files: ["/large.zip": archiveData],
      maximumBytes: UInt64(archiveData.count + 100))
    defer { fixture.removeStagingRoot() }
    let item = try #require(try await fixture.provider.contents(of: fixture.rootLocation).first)

    await #expect(throws: ArchiveServiceError.self) {
      try await fixture.service.extractArchive(
        item,
        in: fixture.rootLocation,
        destination: .currentDirectory,
        using: fixture.provider,
        archiveService: ArchiveService())
    }

    #expect(await fixture.session.fileData(at: "/large.txt") == nil)
    #expect(await fixture.session.hiddenArchivePaths().isEmpty)
    #expect(fixture.stagingDirectoryIsEmpty)
  }

  @Test("SFTPアーカイブ作成が容量上限を超えると成果物と一時領域を残さない")
  func rejectsCreationOverStagingCapacityAndCleansUp() async throws {
    let fixture = try RemoteArchiveFixture(
      files: ["/large.bin": Data(repeating: 1, count: 64)],
      maximumBytes: 64)
    defer { fixture.removeStagingRoot() }
    let item = try #require(try await fixture.provider.contents(of: fixture.rootLocation).first)

    await #expect(throws: RemoteArchiveServiceError.self) {
      _ = try await fixture.service.createArchive(
        from: [item],
        in: fixture.rootLocation,
        preferredName: "large.bin.zip",
        format: .zip,
        using: fixture.provider,
        archiveService: ArchiveService())
    }

    #expect(await fixture.session.fileData(at: "/large.bin.zip") == nil)
    #expect(await fixture.session.hiddenArchivePaths().isEmpty)
    #expect(fixture.stagingDirectoryIsEmpty)
  }

  @Test("SFTPアーカイブ作成のキャンセルで成果物と一時領域を残さない")
  func cancellationCleansUpCreationArtifacts() async throws {
    let fixture = try RemoteArchiveFixture(
      files: ["/waiting.bin": Data(repeating: 1, count: 64)],
      blocksStreaming: true)
    defer { fixture.removeStagingRoot() }
    let item = try #require(try await fixture.provider.contents(of: fixture.rootLocation).first)
    let task = Task {
      try await fixture.service.createArchive(
        from: [item],
        in: fixture.rootLocation,
        preferredName: "waiting.bin.zip",
        format: .zip,
        using: fixture.provider,
        archiveService: ArchiveService())
    }
    await waitUntil { await fixture.session.didStartStreaming }

    task.cancel()

    await #expect(throws: CancellationError.self) {
      _ = try await task.value
    }
    #expect(await fixture.session.fileData(at: "/waiting.bin.zip") == nil)
    #expect(await fixture.session.hiddenArchivePaths().isEmpty)
    #expect(fixture.stagingDirectoryIsEmpty)
  }
}

private func makeZIPData(entryPath: String, contents: Data) throws -> Data {
  let root = FileManager.default.temporaryDirectory.appending(
    path: "remote-archive-zip-\(UUID().uuidString)",
    directoryHint: .isDirectory)
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let sourceURL = root.appending(path: "source")
  let archiveURL = root.appending(path: "archive.zip")
  try contents.write(to: sourceURL)
  let archive = try Archive(url: archiveURL, accessMode: .create)
  try archive.addEntry(with: entryPath, fileURL: sourceURL, compressionMethod: .deflate)
  return try Data(contentsOf: archiveURL)
}

private func makeZIPData(entries: [(String, Data)]) throws -> Data {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let url = root.appending(path: "archive.zip")
  let archive = try Archive(url: url, accessMode: .create)
  for (path, data) in entries {
    try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) {
      offset, size in
      data.subdata(in: Int(offset)..<min(Int(offset) + size, data.count))
    }
  }
  return try Data(contentsOf: url)
}

private func makeResourceForkAppleDouble() -> Data {
  // AppleDouble v2のFinderInfo(32bytes)とResourceForkの2エントリ。
  let fork = Data("resource fork".utf8)
  var data = Data()
  for (value, width) in [(0x0005_1607, 4), (0x0002_0000, 4)] {
    for shift in (0..<width).reversed() {
      data.append(UInt8(truncatingIfNeeded: value >> (shift * 8)))
    }
  }
  data.append(Data(repeating: 0, count: 16))
  data.append(contentsOf: [0, 2])
  for value in [9, 50, 32, 2, 82, fork.count] {
    for shift in (0..<4).reversed() { data.append(UInt8(truncatingIfNeeded: value >> (shift * 8))) }
  }
  data.append(Data(repeating: 0, count: 32))
  data.append(fork)
  return data
}

private struct RemoteArchiveFixture {
  let stagingRoot: URL
  let session: InMemoryArchiveSFTPClientSession
  let provider: SFTPFileProvider
  let service: RemoteArchiveService

  init(
    files: [String: Data],
    maximumBytes: UInt64 = 4 * 1_024 * 1_024,
    blocksStreaming: Bool = false
  ) throws {
    stagingRoot = FileManager.default.temporaryDirectory.appending(
      path: "remote-archive-staging-\(UUID().uuidString)",
      directoryHint: .isDirectory)
    session = InMemoryArchiveSFTPClientSession(
      files: files,
      blocksStreaming: blocksStreaming)
    let target = try SFTPConnectionTarget(
      host: "archive.example.com",
      port: 22,
      username: "tester")
    provider = SFTPFileProvider(target: target, directoryListing: session)
    service = RemoteArchiveService(
      rootURL: stagingRoot,
      maximumBytes: maximumBytes,
      budget: RemoteArchiveStagingBudget(maximumBytes: maximumBytes))
  }

  var rootLocation: FileLocation {
    FileLocation(remotePath: "/", providerID: provider.id)
  }

  var stagingDirectoryIsEmpty: Bool {
    guard FileManager.default.fileExists(atPath: stagingRoot.path) else { return true }
    return (try? FileManager.default.contentsOfDirectory(atPath: stagingRoot.path).isEmpty) == true
  }

  func removeStagingRoot() {
    try? FileManager.default.removeItem(at: stagingRoot)
  }
}

private actor InMemoryArchiveSFTPClientSession: SFTPClientSession {
  private var directories: Set<String> = ["/"]
  private var files: [String: Data]
  private let blocksStreaming: Bool
  private(set) var didStartStreaming = false

  init(files: [String: Data], blocksStreaming: Bool = false) {
    self.files = files
    self.blocksStreaming = blocksStreaming
    for path in files.keys {
      let components = path.split(separator: "/", omittingEmptySubsequences: true).dropLast()
      var directory = ""
      for component in components {
        directory += "/\(component)"
        directories.insert(directory)
      }
    }
  }

  func contents(of remotePath: String) async throws -> [SFTPDirectoryEntry] {
    let directory = normalized(remotePath)
    guard directories.contains(directory) else {
      throw SFTPDirectoryListingError.directoryNotFound
    }
    let childDirectories = directories.compactMap { path -> SFTPDirectoryEntry? in
      guard path != directory, parent(of: path) == directory else { return nil }
      return SFTPDirectoryEntry(name: name(of: path), isDirectory: true)
    }
    let childFiles = files.compactMap { path, data -> SFTPDirectoryEntry? in
      guard parent(of: path) == directory else { return nil }
      return SFTPDirectoryEntry(
        name: name(of: path),
        isDirectory: false,
        size: Int64(data.count))
    }
    return (childDirectories + childFiles).sorted { $0.name < $1.name }
  }

  func createDirectory(at remotePath: String) async throws {
    let path = normalized(remotePath)
    guard directories.contains(parent(of: path)),
      !directories.contains(path),
      files[path] == nil
    else {
      throw CocoaError(.fileWriteFileExists)
    }
    directories.insert(path)
  }

  func remove(at remotePath: String, isDirectory: Bool) async throws {
    let path = normalized(remotePath)
    if isDirectory {
      guard !directories.contains(where: { $0 != path && parent(of: $0) == path }),
        !files.keys.contains(where: { parent(of: $0) == path })
      else {
        throw CocoaError(.fileWriteUnknown)
      }
      directories.remove(path)
    } else {
      files[path] = nil
    }
  }

  func rename(at remotePath: String, to destinationPath: String) async throws {
    let source = normalized(remotePath)
    let destination = normalized(destinationPath)
    guard files[destination] == nil, !directories.contains(destination) else {
      throw CocoaError(.fileWriteFileExists)
    }
    if let data = files.removeValue(forKey: source) {
      files[destination] = data
      return
    }
    guard directories.contains(source) else { throw CocoaError(.fileNoSuchFile) }
    let sourcePrefix = source == "/" ? "/" : "\(source)/"
    let movedDirectories = directories.filter { $0 == source || $0.hasPrefix(sourcePrefix) }
    let movedFiles = files.filter { $0.key.hasPrefix(sourcePrefix) }
    for path in movedDirectories { directories.remove(path) }
    for path in movedFiles.keys { files[path] = nil }
    for path in movedDirectories {
      directories.insert(destination + path.dropFirst(source.count))
    }
    for (path, data) in movedFiles {
      files[destination + path.dropFirst(source.count)] = data
    }
  }

  func copy(
    at remotePath: String,
    to destinationPath: String,
    replacingExisting: Bool
  ) async throws {
    let source = normalized(remotePath)
    let destination = normalized(destinationPath)
    guard let data = files[source] else { throw CocoaError(.fileNoSuchFile) }
    if !replacingExisting, files[destination] != nil {
      throw CocoaError(.fileWriteFileExists)
    }
    files[destination] = data
  }

  func streamFileContents(
    of remotePath: String,
    chunkSize: Int,
    receive: @escaping @Sendable (Data) async throws -> Void
  ) async throws {
    guard let data = files[normalized(remotePath)] else { throw CocoaError(.fileNoSuchFile) }
    didStartStreaming = true
    if blocksStreaming {
      while true {
        try Task.checkCancellation()
        await Task.yield()
      }
    }
    var offset = 0
    while offset < data.count {
      try Task.checkCancellation()
      let end = min(offset + chunkSize, data.count)
      try await receive(data.subdata(in: offset..<end))
      offset = end
    }
  }

  func writeFileContents(
    to remotePath: String,
    chunks: AsyncThrowingStream<Data, Error>,
    replacingExisting: Bool,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws {
    let path = normalized(remotePath)
    if !replacingExisting, files[path] != nil {
      throw CocoaError(.fileWriteFileExists)
    }
    var data = Data()
    for try await chunk in chunks {
      try Task.checkCancellation()
      data.append(chunk)
      progress(Int64(data.count))
    }
    files[path] = data
  }

  func fileContents(of remotePath: String) async throws -> Data {
    guard let data = files[normalized(remotePath)] else { throw CocoaError(.fileNoSuchFile) }
    return data
  }

  func fileSize(at remotePath: String) async throws -> Int64? {
    files[normalized(remotePath)].map { Int64($0.count) }
  }

  func isActive() async -> Bool { true }
  func close() async throws {}

  func fileData(at path: String) -> Data? {
    files[normalized(path)]
  }

  func hiddenArchivePaths() -> [String] {
    let paths = Array(files.keys) + Array(directories)
    return paths.filter {
      $0.contains(".pkpane-archive-") || $0.contains(".pkpane-transfer-")
    }
  }

  private func normalized(_ path: String) -> String {
    guard path != "/" else { return "/" }
    return "/" + path.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
  }

  private func parent(of path: String) -> String {
    let normalizedPath = normalized(path)
    let components = normalizedPath.split(separator: "/", omittingEmptySubsequences: true)
    guard components.count > 1 else { return "/" }
    return "/" + components.dropLast().joined(separator: "/")
  }

  private func name(of path: String) -> String {
    normalized(path).split(separator: "/", omittingEmptySubsequences: true).last.map(String.init)
      ?? "/"
  }
}
