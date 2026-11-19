import Foundation
import Synchronization
import Testing
import ZIPFoundation

@testable import PKPane

struct ArchiveFileProviderTests {
  @Test("ZIPの暗黙フォルダ階層と日本語名を一覧できる")
  func listsHierarchyAndUnicodeNames() async throws {
    let fixture = try ArchiveProviderFixture()
    defer { fixture.remove() }
    try fixture.addFile(path: "書類/内側/報告.txt", contents: "本文")
    try fixture.addFile(path: "直下.txt", contents: "root")
    let provider = try ArchiveFileProvider(archiveURL: fixture.archiveURL)

    let rootItems = try await provider.contents(of: provider.rootLocation)
    let documentFolder = try #require(rootItems.first { $0.name == "書類" })
    #expect(documentFolder.isDirectory)
    #expect(rootItems.contains { $0.name == "直下.txt" })

    let documentItems = try await provider.contents(of: documentFolder.location)
    let innerFolder = try #require(documentItems.first { $0.name == "内側" })
    let innerItems = try await provider.contents(of: innerFolder.location)
    #expect(innerItems.map(\.name) == ["報告.txt"])
    #expect(innerItems.first?.size == Int64(Data("本文".utf8).count))
    #expect(provider.parent(of: innerFolder.location) == documentFolder.location)
    #expect(
      provider.breadcrumbs(for: innerFolder.location, constrainedTo: nil).map(\.name) == [
        "fixture.zip", "書類", "内側",
      ])
  }

  @Test("危険なEntryを一覧から除外して件数を報告する")
  func excludesUnsafeEntriesAndCountsPartialErrors() async throws {
    let fixture = try ArchiveProviderFixture()
    defer { fixture.remove() }
    try fixture.addFile(path: "safe.txt", contents: "safe")
    try fixture.addFile(path: "../outside.txt", contents: "unsafe")
    try fixture.addFile(path: "/absolute.txt", contents: "unsafe")
    try fixture.addFile(path: "folder\\escape.txt", contents: "unsafe")
    let provider = try ArchiveFileProvider(archiveURL: fixture.archiveURL)

    let rootItems = try await provider.contents(of: provider.rootLocation)

    #expect(rootItems.map(\.name) == ["safe.txt"])
    #expect(provider.invalidEntryCount == 3)
  }

  @Test("同一パスのファイルとディレクトリは両立させない")
  func rejectsFileDirectoryCollisionAtSamePath() {
    let file = indexedEntry(path: "/collision", isDirectory: false)
    let directory = indexedEntry(path: "/collision", isDirectory: true)

    #expect(
      !ArchiveIndexBuilder.canInsert(
        path: "/collision", isDirectory: true, into: [file.path: file]))
    #expect(
      !ArchiveIndexBuilder.canInsert(
        path: "/collision", isDirectory: false, into: [directory.path: directory]))
  }

  @Test("非ディレクトリの祖先配下にはEntryを挿入しない")
  func rejectsEntryBelowFileAncestor() {
    let file = indexedEntry(path: "/ancestor", isDirectory: false)
    let records = [file.path: file]

    #expect(
      !ArchiveIndexBuilder.canInsert(
        path: "/ancestor/child.txt", isDirectory: false, into: records))
    #expect(
      !ArchiveIndexBuilder.canInsert(
        path: "/ancestor/child", isDirectory: true, into: records))
  }

  @Test("Provider能力は3表示モード共通で読み取り専用になる")
  func exposesReadOnlyCapabilitiesForEveryViewMode() throws {
    let fixture = try ArchiveProviderFixture()
    defer { fixture.remove() }
    try fixture.addFile(path: "inside.txt", contents: "inside")
    let provider = try ArchiveFileProvider(archiveURL: fixture.archiveURL)
    let writeCapabilities: FileProviderCapabilities = [
      .write, .rename, .moveWithinProvider, .copyWithinProvider, .trash,
      .deletePermanently, .replaceAtomically, .observeChanges, .resumeTransfer,
      .finderTags,
    ]

    #expect(provider.capabilities == [.read, .readSymbolicLink])
    #expect(provider.capabilities.intersection(writeCapabilities).isEmpty)
    for mode in FileBrowserViewMode.allCases {
      #expect(FileBrowserCapability.supports(.contextMenu, for: mode))
      #expect(FileBrowserCapability.supports(.keyboardNavigation, for: mode))
    }
  }

  @Test("Quick Look用の一時展開を同一Entryで再利用する")
  func reusesCachedPreviewForSameEntry() async throws {
    let fixture = try ArchiveProviderFixture()
    defer { fixture.remove() }
    try fixture.addFile(path: "preview.txt", contents: "preview")
    let cacheRoot = fixture.rootURL.appending(path: "cache", directoryHint: .isDirectory)
    let cache = ArchiveExtractionCache(rootURL: cacheRoot, maximumBytes: 64)
    let provider = try ArchiveFileProvider(
      archiveURL: fixture.archiveURL,
      extractionCache: cache)
    let item = try #require(try await provider.contents(of: provider.rootLocation).first)

    let firstURL = try await provider.previewURL(for: item)
    let secondURL = try await provider.previewURL(for: item)

    #expect(firstURL == secondURL)
    #expect(try Data(contentsOf: firstURL) == Data("preview".utf8))
  }

  @Test("同一Entryの並行要求は展開処理を1回だけ実行する")
  func coalescesConcurrentExtractionForSameEntry() async throws {
    let fixture = try ArchiveProviderFixture()
    defer { fixture.remove() }
    let cache = ArchiveExtractionCache(
      rootURL: fixture.rootURL.appending(path: "coalesced", directoryHint: .isDirectory),
      maximumBytes: 64)
    let key = ArchiveExtractionCache.Key(
      providerID: .init(rawValue: "archive:coalesced"), entryPath: "/same")
    let extractionCount = Mutex(0)
    let extractionStarted = Mutex(false)
    let releaseExtraction = DispatchSemaphore(value: 0)
    let first = Task.detached { @Sendable in
      try await cache.cachedURL(for: key, fileName: "same.txt", expectedSize: 4) { url in
        extractionCount.withLock { $0 += 1 }
        extractionStarted.withLock { $0 = true }
        releaseExtraction.wait()
        try Data("same".utf8).write(to: url)
      }
    }
    await waitUntil { extractionStarted.withLock { $0 } }
    let second = Task.detached { @Sendable in
      try await cache.cachedURL(for: key, fileName: "same.txt", expectedSize: 4) { url in
        extractionCount.withLock { $0 += 1 }
        try Data("same".utf8).write(to: url)
      }
    }
    try await Task.sleep(for: .milliseconds(50))
    releaseExtraction.signal()

    let firstURL = try await first.value
    let secondURL = try await second.value
    #expect(firstURL == secondURL)
    #expect(extractionCount.withLock { $0 } == 1)
  }

  @Test("遅いEntryの展開中も別Entryのキャッシュ要求を処理できる")
  func doesNotBlockActorDuringExtraction() async throws {
    let fixture = try ArchiveProviderFixture()
    defer { fixture.remove() }
    let cache = ArchiveExtractionCache(
      rootURL: fixture.rootURL.appending(path: "nonblocking", directoryHint: .isDirectory),
      maximumBytes: 64)
    let slowKey = ArchiveExtractionCache.Key(
      providerID: .init(rawValue: "archive:nonblocking"), entryPath: "/slow")
    let fastKey = ArchiveExtractionCache.Key(
      providerID: .init(rawValue: "archive:nonblocking"), entryPath: "/fast")
    let slowStarted = Mutex(false)
    let releaseSlowExtraction = DispatchSemaphore(value: 0)
    let slow = Task.detached { @Sendable in
      try await cache.cachedURL(for: slowKey, fileName: "slow.txt", expectedSize: 4) { url in
        slowStarted.withLock { $0 = true }
        releaseSlowExtraction.wait()
        try Data("slow".utf8).write(to: url)
      }
    }
    await waitUntil { slowStarted.withLock { $0 } }
    let timeoutRelease = Task.detached { @Sendable in
      try? await Task.sleep(for: .seconds(2))
      releaseSlowExtraction.signal()
    }
    let clock = ContinuousClock()
    let startedAt = clock.now
    let fastURL = try await cache.cachedURL(
      for: fastKey,
      fileName: "fast.txt",
      expectedSize: 4
    ) { url in
      try Data("fast".utf8).write(to: url)
    }
    let elapsed = startedAt.duration(to: clock.now)
    releaseSlowExtraction.signal()
    timeoutRelease.cancel()

    _ = try await slow.value
    #expect(elapsed < .seconds(1))
    #expect(try Data(contentsOf: fastURL) == Data("fast".utf8))
  }

  @Test("LRUキャッシュは上限超過前に最古Entryを削除する")
  func evictsLeastRecentlyUsedEntry() async throws {
    let fixture = try ArchiveProviderFixture()
    defer { fixture.remove() }
    let cache = ArchiveExtractionCache(
      rootURL: fixture.rootURL.appending(path: "lru", directoryHint: .isDirectory),
      maximumBytes: 8)
    let firstKey = ArchiveExtractionCache.Key(
      providerID: .init(rawValue: "archive:test"), entryPath: "/first")
    let secondKey = ArchiveExtractionCache.Key(
      providerID: .init(rawValue: "archive:test"), entryPath: "/second")
    let thirdKey = ArchiveExtractionCache.Key(
      providerID: .init(rawValue: "archive:test"), entryPath: "/third")
    let firstURL = try await cache.cachedURL(
      for: firstKey, fileName: "first.txt", expectedSize: 4
    ) { url in
      try Data("1111".utf8).write(to: url)
    }
    let secondURL = try await cache.cachedURL(
      for: secondKey, fileName: "second.txt", expectedSize: 4
    ) { url in
      try Data("2222".utf8).write(to: url)
    }

    let reusedURL = try await cache.cachedURL(
      for: firstKey, fileName: "first.txt", expectedSize: 4
    ) { _ in
      throw ArchiveCacheTestError.unexpectedExtraction
    }
    let thirdURL = try await cache.cachedURL(
      for: thirdKey, fileName: "third.txt", expectedSize: 4
    ) { url in
      try Data("3333".utf8).write(to: url)
    }

    #expect(ArchiveExtractionCache.maximumBytes == 512 * 1_024 * 1_024)
    #expect(reusedURL == firstURL)
    #expect(FileManager.default.fileExists(atPath: firstURL.path))
    #expect(!FileManager.default.fileExists(atPath: secondURL.path))
    #expect(FileManager.default.fileExists(atPath: thirdURL.path))
  }

  @Test("単一Entryがキャッシュ上限を超える場合は展開しない")
  func rejectsEntryLargerThanCacheLimit() async throws {
    let fixture = try ArchiveProviderFixture()
    defer { fixture.remove() }
    let cache = ArchiveExtractionCache(
      rootURL: fixture.rootURL.appending(path: "small-cache", directoryHint: .isDirectory),
      maximumBytes: 3)
    let key = ArchiveExtractionCache.Key(
      providerID: .init(rawValue: "archive:test"), entryPath: "/large")

    await #expect(throws: ArchiveFileProviderError.self) {
      try await cache.cachedURL(for: key, fileName: "large.txt", expectedSize: 4) { _ in
        throw ArchiveCacheTestError.unexpectedExtraction
      }
    }
  }

  @Test("fileChunks経由のコピーアウトを既存転送基盤で完了する")
  func copiesOutThroughProviderTransferService() async throws {
    let fixture = try ArchiveProviderFixture()
    defer { fixture.remove() }
    try fixture.addFile(path: "inside.txt", contents: "copied")
    let source = try ArchiveFileProvider(archiveURL: fixture.archiveURL)
    let item = try #require(try await source.contents(of: source.rootLocation).first)
    let destinationRoot = fixture.rootURL.appending(
      path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
    let target = LocalFileProvider()
    let destination = FileLocation(
      localURL: destinationRoot.appending(path: item.name),
      providerID: target.id)

    try await ProviderFileTransferService().copy(
      item: item,
      from: source,
      to: destination,
      using: target)

    #expect(try Data(contentsOf: destinationRoot.appending(path: item.name)) == Data("copied".utf8))
  }

  private func indexedEntry(path: String, isDirectory: Bool) -> ArchiveIndexedEntry {
    let providerID = FileProviderID(rawValue: "archive:index-collision-test")
    return ArchiveIndexedEntry(
      path: path,
      providerID: providerID,
      providerToken: providerID.rawValue,
      isDirectory: isDirectory,
      isSyntheticDirectory: false,
      size: isDirectory ? nil : 0,
      modifiedAt: nil,
      archivePath: String(path.dropFirst()),
      compressedSize: 0,
      checksum: 0,
      format: .zip)
  }

  @Test("圧縮率上限を超えるアーカイブは閲覧開始と直接展開の両方で拒否する")
  func rejectsArchiveBombForBrowsingAndDirectExtraction() async throws {
    let fixture = try ArchiveProviderFixture()
    defer { fixture.remove() }
    try fixture.addData(
      path: "bomb.txt",
      data: Data(repeating: 0x41, count: 128 * 1_024))
    let limits = ArchiveSafetyLimits(
      maximumEntryCount: 10,
      maximumUncompressedBytes: 1_024 * 1_024,
      maximumCompressionRatio: 2)
    #expect(throws: ArchiveServiceError.self) {
      try ArchiveFileProvider(archiveURL: fixture.archiveURL, limits: limits)
    }
    let archive = try Archive(url: fixture.archiveURL, accessMode: .read)
    let entry = try #require(archive["bomb.txt"])
    let identity = ArchiveEntryIdentity(
      archivePath: entry.path,
      uncompressedSize: entry.uncompressedSize,
      compressedSize: entry.compressedSize,
      checksum: entry.checksum)

    #expect(throws: ArchiveServiceError.self) {
      try ArchiveEntryReader.extractFile(
        at: fixture.archiveURL,
        entry: identity,
        to: fixture.rootURL.appending(path: "bomb-output.txt"),
        limits: limits)
    }
  }

  @Test("申告サイズを超えたチャンクで直ちに停止する")
  func stopsAtFirstChunkBeyondDeclaredSize() {
    let identity = ArchiveEntryIdentity(
      archivePath: "forged.bin",
      uncompressedSize: 4,
      compressedSize: 1,
      checksum: 0)
    var producedChunks = 0
    var consumedBytes = 0

    #expect(throws: ArchiveFileProviderError.self) {
      try ArchiveEntryReader.validateAndConsume(
        entry: identity,
        extract: { consumer in
          for chunk in [Data(repeating: 1, count: 4), Data(repeating: 2, count: 4), Data([3])] {
            producedChunks += 1
            try consumer(chunk)
          }
          return 0
        },
        consume: { consumedBytes += $0.count })
    }
    #expect(producedChunks == 2)
    #expect(consumedBytes == 4)
  }

  @Test("偽装申告サイズのQuick Look展開は残骸もキャッシュ記録も残さない")
  func rejectsForgedUncompressedSizeWithoutCacheResidue() async throws {
    let fixture = try ArchiveProviderFixture()
    defer { fixture.remove() }
    try fixture.addData(
      path: "forged.bin",
      data: Data(repeating: 0x41, count: 256 * 1_024))
    try fixture.forgeCentralDirectoryUncompressedSize(4)
    let cacheRoot = fixture.rootURL.appending(path: "forged-cache", directoryHint: .isDirectory)
    let cache = ArchiveExtractionCache(rootURL: cacheRoot, maximumBytes: 1_024)
    let provider = try ArchiveFileProvider(
      archiveURL: fixture.archiveURL,
      extractionCache: cache)
    let item = try #require(try await provider.contents(of: provider.rootLocation).first)
    let forgedArchive = try Archive(url: fixture.archiveURL, accessMode: .read)
    let forgedEntry = try #require(forgedArchive["forged.bin"])
    let identity = ArchiveEntryIdentity(
      archivePath: forgedEntry.path,
      uncompressedSize: forgedEntry.uncompressedSize,
      compressedSize: forgedEntry.compressedSize,
      checksum: forgedEntry.checksum)
    let directOutput = fixture.rootURL.appending(path: "forged-output.bin")

    #expect(throws: ArchiveFileProviderError.self) {
      try ArchiveEntryReader.extractFile(
        at: fixture.archiveURL,
        entry: identity,
        to: directOutput,
        limits: .default)
    }
    #expect(!FileManager.default.fileExists(atPath: directOutput.path))
    await #expect(throws: ArchiveFileProviderError.self) {
      try await provider.previewURL(for: item)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: cacheRoot.path).isEmpty)

    let key = ArchiveExtractionCache.Key(
      providerID: provider.id,
      entryPath: try #require(item.location.remotePath))
    let recoveryExtractionCount = Mutex(0)
    _ = try await cache.cachedURL(
      for: key,
      fileName: item.name,
      expectedSize: item.size.map(UInt64.init) ?? 0
    ) { url in
      recoveryExtractionCount.withLock { $0 += 1 }
      try Data(repeating: 0, count: Int(item.size ?? 0)).write(to: url)
    }
    #expect(recoveryExtractionCount.withLock { $0 } == 1)
  }

  @Test("7zの階層を一覧しpreviewとfileChunksで内容を取得できる")
  func browsesSevenZipHierarchyAndExtractsFiles() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appending(
      path: "pkpane-sevenzip-provider-\(UUID().uuidString)",
      directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let readmeURL = rootURL.appending(path: "readme-source.txt")
    let sampleURL = rootURL.appending(path: "sample-source.txt")
    let readmeData = Data("seven zip readme".utf8)
    let sampleData = Data("7zの本文".utf8)
    try readmeData.write(to: readmeURL)
    try sampleData.write(to: sampleURL)
    let archiveURL = rootURL.appending(path: "fixture.7z")
    try ArchiveTestFixtures.makeSevenZipArchive(
      entries: [
        (readmeURL, "docs/readme.txt"),
        (sampleURL, "日本語/サンプル.txt"),
      ],
      at: archiveURL)

    let provider = try ArchiveFileProvider(
      archiveURL: archiveURL,
      extractionCache: ArchiveExtractionCache(
        rootURL: rootURL.appending(path: "cache", directoryHint: .isDirectory)))
    let rootItems = try await provider.contents(of: provider.rootLocation)
    let docsFolder = try #require(rootItems.first { $0.name == "docs" })
    let japaneseFolder = try #require(rootItems.first { $0.name == "日本語" })
    let readme = try #require(
      try await provider.contents(of: docsFolder.location).first { $0.name == "readme.txt" })
    let sample = try #require(
      try await provider.contents(of: japaneseFolder.location).first { $0.name == "サンプル.txt" })

    #expect(docsFolder.isDirectory)
    #expect(japaneseFolder.isDirectory)
    let previewURL = try await provider.previewURL(for: readme)
    #expect(try Data(contentsOf: previewURL) == readmeData)
    var copiedData = Data()
    for try await chunk in provider.fileChunks(for: sample, chunkSize: 3) {
      copiedData.append(chunk)
    }
    #expect(copiedData == sampleData)
  }

  @Test("solid 7zはエントリ単位で高圧縮でも全件を一覧しpreviewできる")
  func browsesSolidSevenZipUsingAggregateCompressionRatio() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appending(
      path: "pkpane-solid-sevenzip-provider-\(UUID().uuidString)",
      directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let repeatedData = Data(repeating: 0x41, count: 200 * 1_024)
    let repeatedURL = rootURL.appending(path: "repeated-source.txt")
    let randomURL = rootURL.appending(path: "random-source.bin")
    try repeatedData.write(to: repeatedURL)
    try incompressibleData(byteCount: 8 * 1_024).write(to: randomURL)
    let archiveURL = rootURL.appending(path: "aggregate.7z")
    try ArchiveTestFixtures.makeSevenZipArchive(
      entries: [
        (repeatedURL, "repeated.txt"),
        (randomURL, "random.bin"),
      ],
      at: archiveURL,
      solid: true)

    let provider = try ArchiveFileProvider(archiveURL: archiveURL)
    let items = try await provider.contents(of: provider.rootLocation)
    let repeatedItem = try #require(items.first { $0.name == "repeated.txt" })
    let previewURL = try await provider.previewURL(for: repeatedItem)

    #expect(Set(items.map(\.name)) == ["random.bin", "repeated.txt"])
    #expect(try Data(contentsOf: previewURL) == repeatedData)
  }

  @Test("ZIPはエントリ単位で高圧縮でも全件を一覧しpreviewできる")
  func browsesZIPUsingAggregateCompressionRatio() async throws {
    let fixture = try ArchiveProviderFixture()
    defer { fixture.remove() }
    let repeatedData = Data(repeating: 0x41, count: 200 * 1_024)
    try fixture.addData(path: "repeated.txt", data: repeatedData)
    try fixture.addData(path: "random.bin", data: incompressibleData(byteCount: 8 * 1_024))

    let provider = try ArchiveFileProvider(archiveURL: fixture.archiveURL)
    let items = try await provider.contents(of: provider.rootLocation)
    let repeatedItem = try #require(items.first { $0.name == "repeated.txt" })
    let previewURL = try await provider.previewURL(for: repeatedItem)

    #expect(Set(items.map(\.name)) == ["random.bin", "repeated.txt"])
    #expect(try Data(contentsOf: previewURL) == repeatedData)
  }

  @Test("合計サイズ上限で除外があっても採用済みZIP Entryをpreviewできる")
  func previewsAcceptedZIPEntryWhenArchiveTotalExceedsLimit() async throws {
    let fixture = try ArchiveProviderFixture()
    defer { fixture.remove() }
    let acceptedData = Data([0, 1, 2, 3, 4, 5, 6, 7])
    try fixture.addData(path: "accepted.bin", data: acceptedData)
    try fixture.addData(path: "excluded.bin", data: Data([8, 9, 10, 11, 12, 13, 14, 15]))
    let limits = ArchiveSafetyLimits(
      maximumEntryCount: 10,
      maximumUncompressedBytes: 8,
      maximumCompressionRatio: 100)

    let provider = try ArchiveFileProvider(archiveURL: fixture.archiveURL, limits: limits)
    let items = try await provider.contents(of: provider.rootLocation)
    let acceptedItem = try #require(items.first { $0.name == "accepted.bin" })
    let previewURL = try await provider.previewURL(for: acceptedItem)

    #expect(items.map(\.name) == ["accepted.bin"])
    #expect(try Data(contentsOf: previewURL) == acceptedData)
  }

  @Test("RAR4のWindows式階層を一覧しpreviewで内容を取得できる")
  func browsesRAR4WithNormalizedBackslashPaths() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appending(
      path: "pkpane-rar4-provider-\(UUID().uuidString)",
      directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let archiveURL = rootURL.appending(path: "fixture.rar")
    try ArchiveTestFixtures.windowsBackslashRAR4Data.write(to: archiveURL)

    let provider = try ArchiveFileProvider(archiveURL: archiveURL)
    let archiveFolder = try #require(
      try await provider.contents(of: provider.rootLocation).first { $0.name == "アーカイブ" })
    let sample = try #require(
      try await provider.contents(of: archiveFolder.location).first { $0.name == "サンプル.txt" })
    let previewURL = try await provider.previewURL(for: sample)

    #expect(archiveFolder.isDirectory)
    #expect(try String(contentsOf: previewURL, encoding: .utf8) == "こんにちは")
  }

  @Test("RAR5を一覧しpreviewで内容を取得できる")
  func browsesRAR5AndExtractsPreview() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appending(
      path: "pkpane-rar5-provider-\(UUID().uuidString)",
      directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let archiveURL = rootURL.appending(path: "fixture.rar")
    try ArchiveTestFixtures.rar5Data.write(to: archiveURL)

    let provider = try ArchiveFileProvider(archiveURL: archiveURL)
    let readme = try #require(
      try await provider.contents(of: provider.rootLocation).first { $0.name == "README.md" })
    let previewURL = try await provider.previewURL(for: readme)

    #expect(
      try String(contentsOf: previewURL, encoding: .utf8)
        == "# Unrar\n\nA description of this package.\n")
  }

  @Test("tarの階層を一覧しpreviewで内容を取得できる")
  func browsesTarHierarchyAndExtractsPreview() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appending(
      path: "pkpane-tar-provider-\(UUID().uuidString)",
      directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let content = Data("tar本文".utf8)
    let archiveURL = rootURL.appending(path: "fixture.tar")
    try ArchiveTestFixtures.makeTarArchive(entries: [("documents/report.txt", content)]).write(
      to: archiveURL)

    let provider = try ArchiveFileProvider(archiveURL: archiveURL)
    let documents = try #require(
      try await provider.contents(of: provider.rootLocation).first { $0.name == "documents" })
    let report = try #require(
      try await provider.contents(of: documents.location).first { $0.name == "report.txt" })
    let previewURL = try await provider.previewURL(for: report)

    #expect(documents.isDirectory)
    #expect(try Data(contentsOf: previewURL) == content)
  }

  @Test("tar.gzとtar.bz2を一覧しpreviewで内容を取得できる")
  func browsesCompressedTarArchives() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appending(
      path: "pkpane-compressed-tar-provider-\(UUID().uuidString)",
      directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let content = Data("圧縮tar本文".utf8)
    let tarData = ArchiveTestFixtures.makeTarArchive(entries: [("folder/sample.txt", content)])
    let archives: [(name: String, data: Data)] = [
      ("fixture.tar.gz", try ArchiveTestFixtures.gzip(tarData)),
      ("fixture.tar.bz2", ArchiveTestFixtures.bzip2(tarData)),
    ]

    for archive in archives {
      let archiveURL = rootURL.appending(path: archive.name)
      try archive.data.write(to: archiveURL)
      let provider = try ArchiveFileProvider(archiveURL: archiveURL)
      let folder = try #require(
        try await provider.contents(of: provider.rootLocation).first { $0.name == "folder" })
      let sample = try #require(
        try await provider.contents(of: folder.location).first { $0.name == "sample.txt" })
      let previewURL = try await provider.previewURL(for: sample)
      #expect(try Data(contentsOf: previewURL) == content)
    }
  }

  @Test("圧縮tarの一時展開容量をブラウザ間で合算し解放後に再利用できる")
  func limitsCombinedCompressedTarStagingBytes() throws {
    let rootURL = FileManager.default.temporaryDirectory.appending(
      path: "pkpane-compressed-tar-budget-\(UUID().uuidString)",
      directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let tarData = ArchiveTestFixtures.makeTarArchive(
      entries: [("folder/sample.txt", Data("圧縮tar本文".utf8))])
    let archiveURL = rootURL.appending(path: "fixture.tar.gz")
    try ArchiveTestFixtures.gzip(tarData).write(to: archiveURL)
    let budget = ArchiveStagingBudget(maximumBytes: UInt64(tarData.count))
    var firstProvider: ArchiveFileProvider? = try ArchiveFileProvider(
      archiveURL: archiveURL,
      stagingBudget: budget)

    #expect(firstProvider != nil)
    #expect(budget.usedBytes == UInt64(tarData.count))
    #expect(throws: ArchiveFileProviderError.self) {
      try ArchiveFileProvider(archiveURL: archiveURL, stagingBudget: budget)
    }

    firstProvider = nil
    #expect(budget.usedBytes == 0)
    _ = try ArchiveFileProvider(archiveURL: archiveURL, stagingBudget: budget)
  }

  @Test("tar.xzを一覧しpreviewで内容を取得できる")
  func browsesTarXzArchive() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appending(
      path: "pkpane-tar-xz-provider-\(UUID().uuidString)",
      directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let archiveURL = rootURL.appending(path: "fixture.tar.xz")
    try ArchiveTestFixtures.tarXzData.write(to: archiveURL)

    let provider = try ArchiveFileProvider(archiveURL: archiveURL)
    let report = try #require(
      try await provider.contents(of: provider.rootLocation).first { $0.name == "report.txt" })
    let previewURL = try await provider.previewURL(for: report)

    #expect(try String(contentsOf: previewURL, encoding: .utf8) == "hello xz")
  }

  @Test("単一gzipを論理1エントリとして一覧しpreviewで内容を取得できる")
  func browsesSingleFileGzipArchive() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appending(
      path: "pkpane-single-gzip-provider-\(UUID().uuidString)",
      directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let content = Data("単一gzip本文".utf8)
    let archiveURL = rootURL.appending(path: "report.txt.gz")
    try ArchiveTestFixtures.gzip(content).write(to: archiveURL)

    let provider = try ArchiveFileProvider(archiveURL: archiveURL)
    let items = try await provider.contents(of: provider.rootLocation)
    let report = try #require(items.first)
    let previewURL = try await provider.previewURL(for: report)

    #expect(items.count == 1)
    #expect(report.name == "report.txt")
    #expect(try Data(contentsOf: previewURL) == content)
  }

  private func incompressibleData(byteCount: Int) -> Data {
    var state: UInt64 = 0xC0FFEE
    var bytes = [UInt8](repeating: 0, count: byteCount)
    for index in bytes.indices {
      state = 6_364_136_223_846_793_005 &* state &+ 1
      bytes[index] = UInt8(truncatingIfNeeded: state >> 24)
    }
    return Data(bytes)
  }
}

private enum ArchiveCacheTestError: Error {
  case unexpectedExtraction
}

private final class ArchiveProviderFixture {
  let rootURL: URL
  let archiveURL: URL
  private let sourceURL: URL
  private var archive: Archive?

  init() throws {
    rootURL = FileManager.default.temporaryDirectory.appending(
      path: "pkpane-archive-provider-\(UUID().uuidString)",
      directoryHint: .isDirectory)
    sourceURL = rootURL.appending(path: "source.bin")
    archiveURL = rootURL.appending(path: "fixture.zip")
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let createdArchive: Archive = try Archive(url: archiveURL, accessMode: .create)
    archive = createdArchive
  }

  func addFile(path: String, contents: String) throws {
    try addData(path: path, data: Data(contents.utf8))
  }

  func addData(path: String, data: Data) throws {
    try data.write(to: sourceURL)
    guard let archive else { throw CocoaError(.fileNoSuchFile) }
    try archive.addEntry(with: path, fileURL: sourceURL, compressionMethod: .deflate)
  }

  func forgeCentralDirectoryUncompressedSize(_ size: UInt32) throws {
    archive = nil
    var data = try Data(contentsOf: archiveURL)
    let signature = Data([0x50, 0x4b, 0x01, 0x02])
    let centralDirectoryOffset = try #require(data.range(of: signature)?.lowerBound)
    var littleEndianSize = size.littleEndian
    withUnsafeBytes(of: &littleEndianSize) { bytes in
      data.replaceSubrange(
        (centralDirectoryOffset + 24)..<(centralDirectoryOffset + 28),
        with: bytes)
    }
    try data.write(to: archiveURL)
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootURL)
  }
}

private func waitUntil(_ condition: @Sendable () -> Bool) async {
  await PKPaneTests.waitUntil(timeout: .seconds(5), "条件が期限内に真にならなかった") {
    condition()
  }
}
