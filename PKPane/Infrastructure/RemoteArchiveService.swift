import Foundation
import Synchronization

enum RemoteArchiveServiceError: LocalizedError, Equatable {
  case unsupportedProvider
  case invalidRemoteItemName(String)
  case stagingCapacityExceeded

  var errorDescription: String? {
    switch self {
    case .unsupportedProvider:
      "この接続ではリモートアーカイブ操作を利用できません。"
    case .invalidRemoteItemName(let name):
      "安全でないリモート項目名「\(name)」はアーカイブ処理に使用できません。"
    case .stagingCapacityExceeded:
      "リモートアーカイブの一時使用容量が上限に達しました。"
    }
  }
}

final class RemoteArchiveStagingBudget: @unchecked Sendable {
  static let shared = RemoteArchiveStagingBudget(
    maximumBytes: RemoteArchiveService.maximumStagingBytes)

  private let maximumBytes: UInt64
  private let state = Mutex<UInt64>(0)

  init(maximumBytes: UInt64) {
    self.maximumBytes = maximumBytes
  }

  func reserve(bytes: UInt64) throws -> RemoteArchiveStagingReservation {
    try state.withLock { usedBytes in
      guard bytes <= maximumBytes, usedBytes == 0 else {
        throw RemoteArchiveServiceError.stagingCapacityExceeded
      }
      usedBytes = bytes
    }
    return RemoteArchiveStagingReservation(bytes: bytes, budget: self)
  }

  fileprivate func release(bytes: UInt64) {
    state.withLock { usedBytes in
      usedBytes = usedBytes >= bytes ? usedBytes - bytes : 0
    }
  }
}

final class RemoteArchiveStagingReservation: @unchecked Sendable {
  private let bytes: UInt64
  private let budget: RemoteArchiveStagingBudget

  fileprivate init(bytes: UInt64, budget: RemoteArchiveStagingBudget) {
    self.bytes = bytes
    self.budget = budget
  }

  deinit {
    budget.release(bytes: bytes)
  }
}

private final class RemoteArchiveCapacityMeter: @unchecked Sendable {
  private let maximumBytes: UInt64
  private let state = Mutex<UInt64>(0)

  init(maximumBytes: UInt64) {
    self.maximumBytes = maximumBytes
  }

  var usedBytes: UInt64 {
    state.withLock { $0 }
  }

  func consume(_ byteCount: Int) throws {
    guard byteCount >= 0 else {
      throw RemoteArchiveServiceError.stagingCapacityExceeded
    }
    let bytes = UInt64(byteCount)
    try state.withLock { usedBytes in
      guard bytes <= maximumBytes, usedBytes <= maximumBytes - bytes else {
        throw RemoteArchiveServiceError.stagingCapacityExceeded
      }
      usedBytes += bytes
    }
  }
}

struct RemoteArchiveService: Sendable {
  static let maximumStagingBytes: UInt64 = 10 * 1_024 * 1_024 * 1_024

  private struct PendingRemoteCommit: Sendable {
    let temporaryItem: FileItem
    let finalName: String
  }

  private let rootURL: URL
  private let maximumBytes: UInt64
  private let budget: RemoteArchiveStagingBudget

  init(
    rootURL: URL? = nil,
    maximumBytes: UInt64 = RemoteArchiveService.maximumStagingBytes,
    budget: RemoteArchiveStagingBudget = .shared
  ) {
    self.rootURL = rootURL ?? Self.defaultRootURL()
    self.maximumBytes = maximumBytes
    self.budget = budget
  }

  static func supports(_ provider: any FileBrowserProvider) -> Bool {
    provider is any FileStreamReadableProvider
      && provider is any FileStreamTransferProvider
      && provider is any FileTransferCommitProvider
      && provider is any FileBrowserOperationProvider
      && provider is any FileBrowserPermanentDeleteProvider
  }

  func createArchive(
    from items: [FileItem],
    in destination: FileLocation,
    preferredName: String,
    format: ArchiveFormat,
    using provider: any FileBrowserProvider,
    archiveService: ArchiveService,
    progress: @escaping ArchiveService.ProgressHandler = { _ in }
  ) async throws -> String {
    guard !items.isEmpty,
      destination.providerID == provider.id,
      items.allSatisfy({ $0.location.providerID == provider.id }),
      let readableProvider = provider as? any FileStreamReadableProvider
    else {
      throw RemoteArchiveServiceError.unsupportedProvider
    }
    try requireWritableRemoteArchiveProvider(provider)
    let reservation = try budget.reserve(bytes: maximumBytes)
    defer { withExtendedLifetime(reservation) {} }
    let workspace = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: workspace) }

    let existingNames = Set(try await provider.contents(of: destination).map(\.name))
    let availableName = ArchiveAvailableName.resolving(preferredName: preferredName) {
      existingNames.contains($0)
    }
    let sourceRoot = workspace.appending(path: "Sources", directoryHint: .isDirectory)
    let outputRoot = workspace.appending(path: "Output", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)

    // 圧縮後ファイルのために同量を残す。ZIP/7zのヘッダ分は後段の実測でも検証する。
    let sourceCapacity = maximumBytes / 2
    let meter = RemoteArchiveCapacityMeter(maximumBytes: sourceCapacity)
    var stagedSourceURLs: [URL] = []
    stagedSourceURLs.reserveCapacity(items.count)
    for item in items {
      try Task.checkCancellation()
      let stagedURL = try await download(
        item,
        to: sourceRoot,
        using: provider,
        readableProvider: readableProvider,
        meter: meter)
      stagedSourceURLs.append(stagedURL)
    }

    let archiveURL = try await archiveService.createArchive(
      from: stagedSourceURLs,
      in: outputRoot,
      name: availableName,
      format: format,
      progress: progress)
    try ensureWorkspaceFitsCapacity(workspace)
    try Task.checkCancellation()
    let localProvider = LocalFileProvider()
    let archiveItem = try localProvider.item(at: archiveURL)
    guard let remoteDestination = destination.appending(pathComponent: availableName) else {
      throw RemoteArchiveServiceError.unsupportedProvider
    }
    try await ProviderFileTransferService().copy(
      item: archiveItem,
      from: localProvider,
      to: remoteDestination,
      using: provider)
    return availableName
  }

  func extractArchive(
    _ item: FileItem,
    in destination: FileLocation,
    destination extractionDestination: ArchiveExtractionDestination,
    using provider: any FileBrowserProvider,
    archiveService: ArchiveService,
    progress: @escaping ArchiveService.ProgressHandler = { _ in }
  ) async throws {
    guard item.location.providerID == provider.id,
      destination.providerID == provider.id,
      !item.isDirectory,
      ArchiveFormat(url: item.url) != nil,
      let readableProvider = provider as? any FileStreamReadableProvider,
      let operations = provider as? any FileBrowserOperationProvider,
      let permanentDelete = provider as? any FileBrowserPermanentDeleteProvider
    else {
      throw RemoteArchiveServiceError.unsupportedProvider
    }
    try requireWritableRemoteArchiveProvider(provider)
    let reservation = try budget.reserve(bytes: maximumBytes)
    defer { withExtendedLifetime(reservation) {} }
    let workspace = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: workspace) }

    let inputRoot = workspace.appending(path: "Input", directoryHint: .isDirectory)
    let outputRoot = workspace.appending(path: "Output", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: inputRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
    let meter = RemoteArchiveCapacityMeter(maximumBytes: maximumBytes)
    let archiveURL = try await download(
      item,
      to: inputRoot,
      using: provider,
      readableProvider: readableProvider,
      meter: meter)
    let remainingCapacity = maximumBytes - meter.usedBytes
    guard remainingCapacity > 0 else {
      throw RemoteArchiveServiceError.stagingCapacityExceeded
    }
    let extractedURL = try await archiveService.extractArchive(
      at: archiveURL,
      in: outputRoot,
      destination: extractionDestination,
      // バイト転送ではxattrを運べないため、macOS側車を消費せずリモートへ保持する。
      restoresZIPMetadata: false,
      maximumUncompressedBytes: remainingCapacity,
      progress: progress)
    try ensureWorkspaceFitsCapacity(workspace)
    try Task.checkCancellation()

    let outputURLs: [URL]
    switch extractionDestination {
    case .folderNamedAfterArchive:
      outputURLs = [extractedURL]
    case .currentDirectory:
      outputURLs = try FileSystemDirectoryEntries.children(of: extractedURL)
    }
    let finalNames = try await resolvedExtractionNames(
      for: outputURLs,
      archiveURL: archiveURL,
      in: destination,
      using: provider)
    let localProvider = LocalFileProvider()
    var pendingCommits: [PendingRemoteCommit] = []
    do {
      for (outputURL, finalName) in zip(outputURLs, finalNames) {
        try Task.checkCancellation()
        let temporaryName = ".pkpane-archive-\(UUID().uuidString)"
        let temporaryURL = outputURL.deletingLastPathComponent().appending(path: temporaryName)
        try FileManager.default.moveItem(at: outputURL, to: temporaryURL)
        let localItem = try localProvider.item(at: temporaryURL)
        guard let temporaryLocation = destination.appending(pathComponent: temporaryName),
          let remotePath = temporaryLocation.remotePath
        else {
          throw RemoteArchiveServiceError.unsupportedProvider
        }
        let temporaryItem = FileItem(
          remotePath: remotePath,
          url: URL(filePath: "/\(temporaryName)"),
          providerID: provider.id,
          isDirectory: localItem.isDirectory,
          size: localItem.size)
        pendingCommits.append(
          PendingRemoteCommit(temporaryItem: temporaryItem, finalName: finalName))
        try await ProviderFileTransferService().copyTree(
          item: localItem,
          from: localProvider,
          toDirectory: destination,
          using: provider)
      }
      for pending in pendingCommits {
        try Task.checkCancellation()
        try await operations.rename(pending.temporaryItem, to: pending.finalName)
      }
    } catch {
      for pending in pendingCommits {
        try? await permanentDelete.permanentlyDelete(pending.temporaryItem)
      }
      throw error
    }
  }

  static func defaultRootURL(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    if TestEnvironmentDetector.isRunningTests(environment: environment) {
      return FileManager.default.temporaryDirectory
        .appending(path: "pkpane-tests", directoryHint: .isDirectory)
        .appending(
          path: "remote-archives-\(ProcessInfo.processInfo.processIdentifier)",
          directoryHint: .isDirectory)
    }
    let cacheDirectory =
      FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return cacheDirectory.appending(path: "PKPane/RemoteArchives", directoryHint: .isDirectory)
  }

  private func requireWritableRemoteArchiveProvider(
    _ provider: any FileBrowserProvider
  ) throws {
    guard Self.supports(provider), provider.capabilities.contains(.write) else {
      throw RemoteArchiveServiceError.unsupportedProvider
    }
  }

  private func makeWorkspace() throws -> URL {
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let staleItems = try FileManager.default.contentsOfDirectory(
      at: rootURL,
      includingPropertiesForKeys: nil)
    for staleItem in staleItems {
      try? FileManager.default.removeItem(at: staleItem)
    }
    let workspace = rootURL.appending(
      path: UUID().uuidString,
      directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
    return workspace
  }

  private func download(
    _ item: FileItem,
    to directoryURL: URL,
    using provider: any FileBrowserProvider,
    readableProvider: any FileStreamReadableProvider,
    meter: RemoteArchiveCapacityMeter
  ) async throws -> URL {
    try Task.checkCancellation()
    try validateRemoteItemName(item.name)
    guard !item.isSymbolicLink else {
      throw ArchiveServiceError.unsupportedItem(item.name)
    }
    let destinationURL = directoryURL.appending(path: item.name)
    if item.isDirectory {
      try FileManager.default.createDirectory(
        at: destinationURL,
        withIntermediateDirectories: false)
      for child in try await provider.contents(of: item.location) {
        _ = try await download(
          child,
          to: destinationURL,
          using: provider,
          readableProvider: readableProvider,
          meter: meter)
      }
      return destinationURL
    }

    let temporaryURL = directoryURL.appending(path: ".download-\(UUID().uuidString)")
    guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    do {
      let handle = try FileHandle(forWritingTo: temporaryURL)
      defer { try? handle.close() }
      let chunks = readableProvider.fileChunks(
        for: item,
        chunkSize: readableProvider.preferredTransferChunkSize)
      for try await chunk in chunks {
        try Task.checkCancellation()
        try meter.consume(chunk.count)
        try handle.write(contentsOf: chunk)
      }
      try Task.checkCancellation()
      try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
      return destinationURL
    } catch {
      try? FileManager.default.removeItem(at: temporaryURL)
      throw error
    }
  }

  private func resolvedExtractionNames(
    for outputURLs: [URL],
    archiveURL: URL,
    in destination: FileLocation,
    using provider: any FileBrowserProvider
  ) async throws -> [String] {
    let existingNames = Set(try await provider.contents(of: destination).map(\.name))
    guard let format = ArchiveFormat(url: archiveURL) else {
      throw ArchiveServiceError.unsupportedFormat(archiveURL.pathExtension)
    }
    if format.isSingleFileCompression,
      outputURLs.count == 1,
      let outputURL = outputURLs.first
    {
      return [
        ArchiveAvailableName.resolving(preferredName: outputURL.lastPathComponent) {
          existingNames.contains($0)
        }
      ]
    }
    for outputURL in outputURLs where existingNames.contains(outputURL.lastPathComponent) {
      throw ArchiveServiceError.destinationExists(outputURL.lastPathComponent)
    }
    return outputURLs.map(\.lastPathComponent)
  }

  private func validateRemoteItemName(_ name: String) throws {
    guard !name.isEmpty,
      name != ".",
      name != "..",
      !name.contains("/"),
      !name.contains("\0")
    else {
      throw RemoteArchiveServiceError.invalidRemoteItemName(name)
    }
  }

  private func ensureWorkspaceFitsCapacity(_ workspace: URL) throws {
    var consumedBytes: UInt64 = 0
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
    guard
      let enumerator = FileManager.default.enumerator(
        at: workspace,
        includingPropertiesForKeys: Array(keys),
        options: [],
        errorHandler: { _, _ in false })
    else {
      throw CocoaError(.fileReadUnknown)
    }
    for case let url as URL in enumerator {
      let values = try url.resourceValues(forKeys: keys)
      guard values.isRegularFile == true else { continue }
      let fileSize = UInt64(max(values.fileSize ?? 0, 0))
      guard fileSize <= maximumBytes, consumedBytes <= maximumBytes - fileSize else {
        throw RemoteArchiveServiceError.stagingCapacityExceeded
      }
      consumedBytes += fileSize
    }
  }
}
