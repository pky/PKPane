import Foundation
import Testing

@testable import PKPane

struct ProviderFileTransferServiceTests {
  @Test("異なるProvider間でチャンク転送と進捗通知を共通実行する")
  func copiesAcrossProvidersWithProgress() async throws {
    let source = StreamTransferProvider(
      id: FileProviderID(rawValue: "source"),
      chunks: [Data("abc".utf8), Data("def".utf8)])
    let destination = StreamTransferProvider(id: FileProviderID(rawValue: "destination"))
    let item = FileItem(
      remotePath: "/source/report.txt",
      url: URL(string: "test://source/report.txt")!,
      providerID: source.id,
      isDirectory: false,
      size: 6)
    let location = FileLocation(remotePath: "/target", providerID: destination.id)
    let progress = ProgressRecorder()

    try await ProviderFileTransferService().copy(
      item: item,
      from: source,
      to: location,
      using: destination,
      progress: { progress.append($0) })

    #expect(destination.writtenData() == Data("abcdef".utf8))
    let expectedProgress = [
      FileTransferProgress(completedBytes: 3, totalBytes: 6),
      FileTransferProgress(completedBytes: 6, totalBytes: 6),
    ]
    #expect(progress.values() == expectedProgress)
  }

  @Test("異なるProvider間でフォルダと配下ファイルを共通転送する")
  func copiesDirectoryTreeAcrossProviders() async throws {
    let sourceID = FileProviderID(rawValue: "source")
    let destinationID = FileProviderID(rawValue: "destination")
    let sourceDirectory = FileLocation(remotePath: "/source/Reports", providerID: sourceID)
    let child = FileItem(
      remotePath: "/source/Reports/monthly.txt",
      url: URL(string: "test://source/Reports/monthly.txt")!,
      providerID: sourceID,
      isDirectory: false,
      size: 6)
    let directory = FileItem(
      remotePath: "/source/Reports",
      url: URL(string: "test://source/Reports")!,
      providerID: sourceID,
      isDirectory: true)
    let source = StreamTransferProvider(
      id: sourceID,
      chunks: [Data("abc".utf8), Data("def".utf8)],
      children: [sourceDirectory: [child]])
    let destination = StreamTransferProvider(id: destinationID)
    let destinationDirectory = FileLocation(remotePath: "/target", providerID: destinationID)

    try await ProviderFileTransferService().copyTree(
      item: directory,
      from: source,
      toDirectory: destinationDirectory,
      using: destination)

    #expect(destination.createdDirectoryNames() == ["Reports"])
    #expect(destination.writtenData() == Data("abcdef".utf8))
    #expect(
      destination.writtenDestinations() == [
        FileLocation(remotePath: "/target/Reports/monthly.txt", providerID: destinationID)
      ])
  }

  @Test("ローカルの隠しファイルと隠しフォルダも内容ごと転送する")
  func copiesHiddenLocalTreeContents() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let sourceURL = root.appending(path: "Payload", directoryHint: .isDirectory)
    let hiddenDirectory = sourceURL.appending(path: ".hiddenDir", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: hiddenDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let contents = [
      "normal.txt": Data("normal".utf8),
      ".hidden": Data("hidden file".utf8),
      "._Photo.jpg": Data("AppleDouble sidecar".utf8),
      ".hiddenDir/child.txt": Data("hidden directory child".utf8),
    ]
    for (name, data) in contents {
      try data.write(to: sourceURL.appending(path: name))
    }
    let source = LocalFileProvider()
    let item = try source.item(at: sourceURL)
    let destination = StreamTransferProvider(id: FileProviderID(rawValue: "destination"))
    let parent = FileLocation(remotePath: "/target", providerID: destination.id)

    try await ProviderFileTransferService().copyTree(
      item: item, from: source, toDirectory: parent, using: destination)

    #expect(Set(destination.createdDirectoryNames()) == ["Payload", ".hiddenDir"])
    for (name, data) in contents {
      let location = FileLocation(remotePath: "/target/Payload/\(name)", providerID: destination.id)
      #expect(destination.writtenData(at: location) == data)
    }
  }

  @Test("ツリーマージは既存の隠しディレクトリを同名ファイルで上書きしない")
  func rejectsHiddenDirectoryAtExistingFileLeaf() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let sourceURL = root.appending(path: "Payload", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("new data".utf8).write(to: sourceURL.appending(path: ".secret"))
    let source = LocalFileProvider()
    let item = try source.item(at: sourceURL)
    let destinationID = FileProviderID(rawValue: "destination")
    let parent = FileLocation(remotePath: "/target", providerID: destinationID)
    let payload = FileLocation(remotePath: "/target/Payload", providerID: destinationID)
    let destination = StreamTransferProvider(
      id: destinationID,
      children: [
        parent: [
          FileItem(
            remotePath: "/target/Payload", url: URL(string: "test://destination/Payload")!,
            providerID: destinationID, isDirectory: true)
        ],
        payload: [
          FileItem(
            remotePath: "/target/Payload/.secret", url: URL(string: "test://destination/.secret")!,
            providerID: destinationID, isDirectory: true)
        ],
      ])

    await #expect {
      try await ProviderFileTransferService().copyTree(
        item: item, from: source, toDirectory: parent, using: destination,
        mergingExistingDirectory: true)
    } throws: { error in
      (error as? CocoaError)?.code == .fileWriteFileExists
    }
    #expect(destination.writtenDestinations().isEmpty)
  }

  @Test("ツリー転送は検証済みの通常リーフだけを完了報告する")
  func reportsVerifiedRegularLeavesWithoutReportingDirectoriesOrSymbolicLinks() async throws {
    let sourceID = FileProviderID(rawValue: "source")
    let destinationID = FileProviderID(rawValue: "destination")
    let sourceDirectory = FileLocation(remotePath: "/source/Reports", providerID: sourceID)
    let regularFile = FileItem(
      remotePath: "/source/Reports/monthly.txt",
      url: URL(string: "test://source/Reports/monthly.txt")!,
      providerID: sourceID,
      isDirectory: false,
      size: 6)
    let symbolicLink = FileItem(
      remotePath: "/source/Reports/latest",
      url: URL(string: "test://source/Reports/latest")!,
      providerID: sourceID,
      isDirectory: false,
      isSymbolicLink: true,
      size: 6)
    let sizeUnknownFile = FileItem(
      remotePath: "/source/Reports/unknown.txt",
      url: URL(string: "test://source/Reports/unknown.txt")!,
      providerID: sourceID,
      isDirectory: false)
    let directory = FileItem(
      remotePath: "/source/Reports",
      url: URL(string: "test://source/Reports")!,
      providerID: sourceID,
      isDirectory: true)
    let source = StreamTransferProvider(
      id: sourceID,
      chunks: [Data("abcdef".utf8)],
      children: [sourceDirectory: [regularFile, symbolicLink, sizeUnknownFile]])
    let destination = StreamTransferProvider(id: destinationID)
    let reportedItems = ItemCompletionRecorder()

    try await ProviderFileTransferService().copyTree(
      item: directory,
      from: source,
      toDirectory: FileLocation(remotePath: "/target", providerID: destinationID),
      using: destination,
      itemCompleted: { reportedItems.append($0) })

    #expect(reportedItems.values() == [TransferJob.Item(regularFile)])
  }

  @Test("ツリーマージで既存同サイズのリーフをスキップしても完了報告する")
  func reportsSkippedVerifiedLeafWhenMergingExistingTree() async throws {
    let sourceID = FileProviderID(rawValue: "source")
    let destinationID = FileProviderID(rawValue: "destination")
    let sourceDirectory = FileLocation(remotePath: "/source/Reports", providerID: sourceID)
    let destinationDirectory = FileLocation(remotePath: "/target", providerID: destinationID)
    let destinationReports = FileLocation(remotePath: "/target/Reports", providerID: destinationID)
    let report = FileItem(
      remotePath: "/source/Reports/monthly.txt",
      url: URL(string: "test://source/Reports/monthly.txt")!,
      providerID: sourceID,
      isDirectory: false,
      size: 6)
    let reports = FileItem(
      remotePath: "/source/Reports",
      url: URL(string: "test://source/Reports")!,
      providerID: sourceID,
      isDirectory: true)
    let existingReports = FileItem(
      remotePath: "/target/Reports",
      url: URL(string: "test://destination/Reports")!,
      providerID: destinationID,
      isDirectory: true)
    let existingReport = FileItem(
      remotePath: "/target/Reports/monthly.txt",
      url: URL(string: "test://destination/Reports/monthly.txt")!,
      providerID: destinationID,
      isDirectory: false,
      size: 6)
    let source = StreamTransferProvider(id: sourceID, children: [sourceDirectory: [report]])
    let destination = StreamTransferProvider(
      id: destinationID,
      children: [
        destinationDirectory: [existingReports],
        destinationReports: [existingReport],
      ])
    let reportedItems = ItemCompletionRecorder()

    try await ProviderFileTransferService().copyTree(
      item: reports,
      from: source,
      toDirectory: destinationDirectory,
      using: destination,
      mergingExistingDirectory: true,
      itemCompleted: { reportedItems.append($0) })

    #expect(reportedItems.values() == [TransferJob.Item(report)])
  }

  @Test("ツリーマージはサイズ不明のリーフを完了報告しない")
  func doesNotReportSizeUnknownLeafWhenMergingExistingTree() async throws {
    let sourceID = FileProviderID(rawValue: "source")
    let destinationID = FileProviderID(rawValue: "destination")
    let sourceDirectory = FileLocation(remotePath: "/source/Reports", providerID: sourceID)
    let unknownSizeFile = FileItem(
      remotePath: "/source/Reports/unknown.txt",
      url: URL(string: "test://source/Reports/unknown.txt")!,
      providerID: sourceID,
      isDirectory: false)
    let reports = FileItem(
      remotePath: "/source/Reports",
      url: URL(string: "test://source/Reports")!,
      providerID: sourceID,
      isDirectory: true)
    let source = StreamTransferProvider(
      id: sourceID,
      chunks: [Data("unknown".utf8)],
      children: [sourceDirectory: [unknownSizeFile]])
    let destination = StreamTransferProvider(id: destinationID)
    let reportedItems = ItemCompletionRecorder()

    try await ProviderFileTransferService().copyTree(
      item: reports,
      from: source,
      toDirectory: FileLocation(remotePath: "/target", providerID: destinationID),
      using: destination,
      mergingExistingDirectory: true,
      itemCompleted: { reportedItems.append($0) })

    #expect(reportedItems.values().isEmpty)
  }

  @Test("ツリーマージで既存の同名ディレクトリをファイルとして置換しない")
  func rejectsDirectoryAtExistingFileLeaf() async throws {
    let sourceID = FileProviderID(rawValue: "source")
    let destinationID = FileProviderID(rawValue: "destination")
    let sourceDirectory = FileLocation(remotePath: "/source/Reports", providerID: sourceID)
    let destinationDirectory = FileLocation(remotePath: "/target", providerID: destinationID)
    let destinationReports = FileLocation(remotePath: "/target/Reports", providerID: destinationID)
    let report = FileItem(
      remotePath: "/source/Reports/monthly.txt",
      url: URL(string: "test://source/Reports/monthly.txt")!,
      providerID: sourceID,
      isDirectory: false,
      size: 6)
    let reports = FileItem(
      remotePath: "/source/Reports",
      url: URL(string: "test://source/Reports")!,
      providerID: sourceID,
      isDirectory: true)
    let existingDirectory = FileItem(
      remotePath: "/target/Reports",
      url: URL(string: "test://destination/Reports")!,
      providerID: destinationID,
      isDirectory: true)
    let existingDirectoryAtLeaf = FileItem(
      remotePath: "/target/Reports/monthly.txt",
      url: URL(string: "test://destination/Reports/monthly.txt")!,
      providerID: destinationID,
      isDirectory: true)
    let source = StreamTransferProvider(
      id: sourceID,
      children: [sourceDirectory: [report]])
    let destination = StreamTransferProvider(
      id: destinationID,
      children: [
        destinationDirectory: [existingDirectory],
        destinationReports: [existingDirectoryAtLeaf],
      ])

    await #expect {
      try await ProviderFileTransferService().copyTree(
        item: reports,
        from: source,
        toDirectory: destinationDirectory,
        using: destination,
        mergingExistingDirectory: true)
    } throws: { error in
      (error as? CocoaError)?.code == .fileWriteFileExists
    }
  }

  @Test("ツリーマージで既存の同名ファイルをディレクトリとして再利用しない")
  func rejectsFileAtExistingDirectory() async throws {
    let sourceID = FileProviderID(rawValue: "source")
    let destinationID = FileProviderID(rawValue: "destination")
    let destinationDirectory = FileLocation(remotePath: "/target", providerID: destinationID)
    let reports = FileItem(
      remotePath: "/source/Reports",
      url: URL(string: "test://source/Reports")!,
      providerID: sourceID,
      isDirectory: true)
    let existingFile = FileItem(
      remotePath: "/target/Reports",
      url: URL(string: "test://destination/Reports")!,
      providerID: destinationID,
      isDirectory: false,
      size: 6)
    let source = StreamTransferProvider(id: sourceID)
    let destination = StreamTransferProvider(
      id: destinationID,
      children: [destinationDirectory: [existingFile]])

    await #expect {
      try await ProviderFileTransferService().copyTree(
        item: reports,
        from: source,
        toDirectory: destinationDirectory,
        using: destination,
        mergingExistingDirectory: true)
    } throws: { error in
      (error as? CocoaError)?.code == .fileWriteFileExists
    }
  }

  @Test("一時ファイルの専用サイズ検証をProvider共通経路より優先する")
  func prefersStagedFileSizeForVerification() async throws {
    let source = StreamTransferProvider(
      id: FileProviderID(rawValue: "source"),
      chunks: [Data("abcdef".utf8)])
    let destination = StreamTransferProvider(
      id: FileProviderID(rawValue: "destination"),
      stagedFileSize: 5,
      itemSize: 6)
    let item = FileItem(
      remotePath: "/source/report.txt",
      url: URL(string: "test://source/report.txt")!,
      providerID: source.id,
      isDirectory: false,
      size: 6)
    let location = FileLocation(remotePath: "/target/report.txt", providerID: destination.id)

    await #expect(throws: TransferVerificationError.self) {
      try await ProviderFileTransferService().copy(
        item: item,
        from: source,
        to: location,
        using: destination)
    }

    #expect(destination.stagedFileSizeRequestCount() == 1)
    #expect(destination.itemSizeRequestCount() == 0)
  }
}

private final class StreamTransferProvider:
  FileStreamTransferProvider,
  FileBrowserOperationProvider,
  FileBrowserItemSizeProvider,
  FileTransferCommitProvider,
  @unchecked Sendable
{
  let id: FileProviderID
  let connectionID: FileProviderConnectionID? = nil
  let capabilities: FileProviderCapabilities = [.read, .write]
  private let chunks: [Data]
  private let children: [FileLocation: [FileItem]]
  private var written = Data()
  private var createdDirectories: [String] = []
  private var destinations: [FileLocation] = []
  private var writesByLocation: [FileLocation: Data] = [:]
  private let stagedFileSizeValue: Int64?
  private let itemSizeValue: Int64?
  private var stagedSizeRequests = 0
  private var itemSizeRequests = 0
  private let lock = NSLock()

  init(
    id: FileProviderID,
    chunks: [Data] = [],
    children: [FileLocation: [FileItem]] = [:],
    stagedFileSize: Int64? = nil,
    itemSize: Int64? = nil
  ) {
    self.id = id
    self.chunks = chunks
    self.children = children
    stagedFileSizeValue = stagedFileSize
    itemSizeValue = itemSize
  }

  func contents(of location: FileLocation) async throws -> [FileItem] {
    (children[location] ?? []).filter { !$0.name.hasPrefix(".") }
  }

  func contents(of location: FileLocation, includingHidden: Bool) async throws -> [FileItem] {
    includingHidden ? children[location] ?? [] : try await contents(of: location)
  }

  func parent(of _: FileLocation) -> FileLocation? { nil }

  func breadcrumbs(
    for _: FileLocation,
    constrainedTo _: FileLocation?
  ) -> [FileBrowserBreadcrumb] { [] }

  func createDirectory(named name: String, in _: FileLocation) async throws {
    lock.withLock { createdDirectories.append(name) }
  }

  func rename(_: FileItem, to _: String) async throws {}

  func delete(_: FileItem) async throws {}

  func fileChunks(
    for _: FileItem,
    chunkSize _: Int
  ) -> AsyncThrowingStream<Data, Error> {
    return AsyncThrowingStream { continuation in
      for chunk in chunks { continuation.yield(chunk) }
      continuation.finish()
    }
  }

  func writeFileChunks(
    _ chunks: AsyncThrowingStream<Data, Error>,
    to destination: FileLocation,
    replacingExisting _: Bool,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws {
    lock.withLock { destinations.append(destination) }
    for try await chunk in chunks {
      let writtenCount = lock.withLock { () -> Int in
        written.append(chunk)
        writesByLocation[destination, default: Data()].append(chunk)
        return written.count
      }
      progress(Int64(writtenCount))
    }
  }

  func commitTransferFile(
    from temporaryLocation: FileLocation,
    to destination: FileLocation,
    replacingExisting _: Bool
  ) async throws {
    lock.withLock {
      if let index = destinations.firstIndex(of: temporaryLocation) {
        destinations[index] = destination
      }
      if let data = writesByLocation.removeValue(forKey: temporaryLocation) {
        writesByLocation[destination] = data
      }
    }
  }

  func stagedFileSize(at _: FileLocation) async throws -> Int64? {
    lock.withLock { stagedSizeRequests += 1 }
    return stagedFileSizeValue
  }

  func itemSize(at _: FileLocation) async throws -> Int64? {
    lock.withLock { itemSizeRequests += 1 }
    return itemSizeValue
  }

  func discardTransferFile(at _: FileLocation) async {}

  func writtenData() -> Data { lock.withLock { written } }

  func writtenData(at location: FileLocation) -> Data? {
    lock.withLock { writesByLocation[location] }
  }

  func createdDirectoryNames() -> [String] { lock.withLock { createdDirectories } }

  func writtenDestinations() -> [FileLocation] { lock.withLock { destinations } }

  func stagedFileSizeRequestCount() -> Int { lock.withLock { stagedSizeRequests } }

  func itemSizeRequestCount() -> Int { lock.withLock { itemSizeRequests } }
}

private final class ProgressRecorder: @unchecked Sendable {
  private var storage: [FileTransferProgress] = []
  private let lock = NSLock()

  func append(_ value: FileTransferProgress) {
    lock.withLock { storage.append(value) }
  }

  func values() -> [FileTransferProgress] {
    lock.withLock { storage }
  }
}

private final class ItemCompletionRecorder: @unchecked Sendable {
  private var storage: [TransferJob.Item] = []
  private let lock = NSLock()

  func append(_ item: TransferJob.Item) {
    lock.withLock { storage.append(item) }
  }

  func values() -> [TransferJob.Item] {
    lock.withLock { storage }
  }
}
