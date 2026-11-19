import Foundation

typealias SMBDirectTransferEngineMaking =
  @Sendable (SMBDirectTransferTarget) -> SMBDirectTransferEngine

enum MountedVolumeProviderError: LocalizedError, Equatable {
  case unavailable
  case outsideVolume

  var errorDescription: String? {
    switch self {
    case .unavailable:
      "NAS共有に接続できません。再接続してからやり直してください。"
    case .outsideVolume:
      "NAS共有の外にある項目は操作できません。"
    }
  }
}

struct MountedVolumeProvider {
  let profile: NASConnectionProfile?
  let volumeURL: URL
  let id: FileProviderID
  var connectionID: FileProviderConnectionID? {
    .smb(volumeURL: volumeURL)
  }
  let capabilities: FileProviderCapabilities = [
    .read, .write, .rename, .moveWithinProvider, .copyWithinProvider,
    .trash, .deletePermanently, .observeChanges, .readSymbolicLink, .finderTags,
  ]

  private let localProvider: LocalFileProvider
  private let moveToTrash: @Sendable (URL) throws -> Void
  private let credentialResolver: any SMBDirectCredentialResolving
  private let sharePathResolver: @Sendable (URL) -> SMBSharePath?
  private let directTransferEngine: SMBDirectTransferEngineMaking
  private let directTransferCache: SMBDirectEngineCache

  init(
    profile: NASConnectionProfile,
    volumeURL: URL,
    moveToTrash: @escaping @Sendable (URL) throws -> Void = { url in
      try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    },
    credentialResolver: any SMBDirectCredentialResolving = SMBDirectCredentialResolver(),
    sharePathResolver: @escaping @Sendable (URL) -> SMBSharePath? = { SMBSharePath(folderURL: $0) },
    directTransferEngine: @escaping SMBDirectTransferEngineMaking = {
      SMBDirectTransferEngine(target: $0)
    },
    directTransferCache: SMBDirectEngineCache = .shared,
    localProvider: LocalFileProvider = LocalFileProvider()
  ) {
    self.profile = profile
    self.volumeURL = volumeURL.standardizedFileURL
    id = FileProviderID(rawValue: "mounted-volume-\(profile.id.uuidString)")
    self.moveToTrash = moveToTrash
    self.credentialResolver = credentialResolver
    self.sharePathResolver = sharePathResolver
    self.directTransferEngine = directTransferEngine
    self.directTransferCache = directTransferCache
    self.localProvider = localProvider
  }

  init(
    volumeURL: URL,
    moveToTrash: @escaping @Sendable (URL) throws -> Void = { url in
      try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    },
    credentialResolver: any SMBDirectCredentialResolving = SMBDirectCredentialResolver(),
    sharePathResolver: @escaping @Sendable (URL) -> SMBSharePath? = { SMBSharePath(folderURL: $0) },
    directTransferEngine: @escaping SMBDirectTransferEngineMaking = {
      SMBDirectTransferEngine(target: $0)
    },
    directTransferCache: SMBDirectEngineCache = .shared,
    localProvider: LocalFileProvider = LocalFileProvider()
  ) {
    profile = nil
    let standardizedVolumeURL = volumeURL.standardizedFileURL
    self.volumeURL = standardizedVolumeURL
    id = FileProviderID(rawValue: "mounted-volume-\(standardizedVolumeURL.path)")
    self.moveToTrash = moveToTrash
    self.credentialResolver = credentialResolver
    self.sharePathResolver = sharePathResolver
    self.directTransferEngine = directTransferEngine
    self.directTransferCache = directTransferCache
    self.localProvider = localProvider
  }

  var isAvailable: Bool {
    FileManager.default.fileExists(atPath: volumeURL.path)
  }

  var workspaceConnectionID: String {
    profile?.id.uuidString ?? connectionID?.rawValue ?? id.rawValue
  }

  func workspaceRelativePath(for location: FileLocation) -> String? {
    guard location.providerID == id,
      let url = location.localURL,
      url.standardizedFileURL.pathComponents.starts(with: volumeURL.pathComponents)
    else {
      return nil
    }
    return url.standardizedFileURL.pathComponents
      .dropFirst(volumeURL.pathComponents.count)
      .joined(separator: "/")
  }

  func item(at url: URL) throws -> FileItem {
    try requireAvailable(url)
    return try localProvider.item(at: url, providerID: id)
  }

  func contents(of directoryURL: URL, includingHidden: Bool = false) throws -> [FileItem] {
    try requireAvailable(directoryURL)
    return try localProvider.contents(
      of: directoryURL,
      includingHidden: includingHidden,
      providerID: id)
  }

  func createDirectory(named name: String, in directoryURL: URL) throws -> URL {
    try requireAvailable(directoryURL)
    return try localProvider.createDirectory(named: name, in: directoryURL)
  }

  func rename(_ url: URL, to name: String, replacingExisting: Bool = false) throws -> URL {
    try requireAvailable(url)
    return try localProvider.rename(url, to: name, replacingExisting: replacingExisting)
  }

  func copy(
    _ url: URL,
    to directoryURL: URL,
    replacingExisting: Bool = false,
    progress: (@Sendable (Int64) -> Void)? = nil,
    isCancelled: @escaping @Sendable () -> Bool = { false }
  ) throws -> URL {
    try requireAvailable(url)
    try requireAvailable(directoryURL)
    return try localProvider.copy(
      url,
      to: directoryURL,
      replacingExisting: replacingExisting,
      progress: progress,
      isCancelled: isCancelled)
  }

  func move(
    _ url: URL,
    to directoryURL: URL,
    replacingExisting: Bool = false,
    isCancelled: @escaping @Sendable () -> Bool = { false }
  ) throws -> URL {
    try requireAvailable(url)
    try requireAvailable(directoryURL)
    return try localProvider.move(
      url,
      to: directoryURL,
      replacingExisting: replacingExisting,
      isCancelled: isCancelled)
  }

  func duplicate(_ url: URL) throws -> URL {
    try requireAvailable(url)
    return try localProvider.duplicate(url)
  }

  private func requireAvailable(_ url: URL) throws {
    guard isAvailable else {
      throw MountedVolumeProviderError.unavailable
    }
    let volumePath = volumeURL.pathComponents
    guard url.standardizedFileURL.pathComponents.starts(with: volumePath) else {
      throw MountedVolumeProviderError.outsideVolume
    }
  }
}

extension MountedVolumeProvider: FileBrowserTransferProvider, FileBrowserPreviewProvider,
  FileBrowserPermanentDeleteProvider, FileBrowserTrashProvider
{
  func contents(of location: FileLocation) async throws -> [FileItem] {
    guard location.providerID == id,
      let directoryURL = location.localURL
    else {
      throw MountedVolumeProviderError.outsideVolume
    }
    return try await Task.detached(priority: .userInitiated) {
      try self.contents(of: directoryURL)
    }.value
  }

  func contents(of location: FileLocation, includingHidden: Bool) async throws -> [FileItem] {
    guard location.providerID == id,
      let directoryURL = location.localURL
    else {
      throw MountedVolumeProviderError.outsideVolume
    }
    return try await Task.detached(priority: .userInitiated) {
      try self.contents(of: directoryURL, includingHidden: includingHidden)
    }.value
  }

  func parent(of location: FileLocation) -> FileLocation? {
    guard location.providerID == id,
      let directoryURL = location.localURL,
      directoryURL.standardizedFileURL != volumeURL
    else {
      return nil
    }
    let parentURL = directoryURL.deletingLastPathComponent()
    guard parentURL.standardizedFileURL.pathComponents.starts(with: volumeURL.pathComponents) else {
      return nil
    }
    return FileLocation(localURL: parentURL, providerID: id)
  }

  func breadcrumbs(
    for location: FileLocation,
    constrainedTo root: FileLocation?
  ) -> [FileBrowserBreadcrumb] {
    guard location.providerID == id,
      let currentURL = location.localURL
    else {
      return []
    }
    let rootURL = root?.localURL ?? volumeURL
    return FolderBreadcrumb.make(root: rootURL, current: currentURL).map {
      FileBrowserBreadcrumb(
        location: FileLocation(localURL: $0.url, providerID: id),
        name: $0.name)
    }
  }

  func createDirectory(named name: String, in location: FileLocation) async throws {
    guard location.providerID == id,
      let directoryURL = location.localURL
    else {
      throw MountedVolumeProviderError.outsideVolume
    }
    _ = try createDirectory(named: name, in: directoryURL)
  }

  func rename(_ item: FileItem, to name: String) async throws {
    guard item.location.providerID == id else {
      throw MountedVolumeProviderError.outsideVolume
    }
    _ = try rename(item.url, to: name)
  }

  func delete(_ item: FileItem) async throws {
    guard item.location.providerID == id else {
      throw MountedVolumeProviderError.outsideVolume
    }
    try requireAvailable(item.url)
    do {
      try moveToTrash(item.url)
    } catch {
      throw FileBrowserOperationError.trashUnavailable
    }
  }

  func permanentlyDelete(_ item: FileItem) async throws {
    guard item.location.providerID == id else {
      throw MountedVolumeProviderError.outsideVolume
    }
    try requireAvailable(item.url)
    try FileManager.default.removeItem(at: item.url)
  }

  func move(
    _ item: FileItem,
    to directory: FileLocation,
    replacingExisting: Bool
  ) async throws {
    guard item.location.providerID == id,
      directory.providerID == id,
      let directoryURL = directory.localURL
    else {
      throw MountedVolumeProviderError.outsideVolume
    }
    _ = try await CancellableFileCopier.performOnDedicatedThread { isCancelled in
      try self.move(
        item.url,
        to: directoryURL,
        replacingExisting: replacingExisting,
        isCancelled: isCancelled)
    }
  }

  func copy(
    _ item: FileItem,
    to directory: FileLocation,
    replacingExisting: Bool
  ) async throws {
    guard item.location.providerID == id,
      directory.providerID == id,
      let directoryURL = directory.localURL
    else {
      throw MountedVolumeProviderError.outsideVolume
    }
    _ = try await CancellableFileCopier.performOnDedicatedThread { isCancelled in
      try self.copy(
        item.url,
        to: directoryURL,
        replacingExisting: replacingExisting,
        isCancelled: isCancelled)
    }
  }

  func removeAfterCrossProviderMove(_ item: FileItem) async throws {
    guard item.location.providerID == id else {
      throw MountedVolumeProviderError.outsideVolume
    }
    try requireAvailable(item.url)
    try FileManager.default.removeItem(at: item.url)
  }

  func previewURL(for item: FileItem) async throws -> URL {
    guard item.location.providerID == id else {
      throw MountedVolumeProviderError.outsideVolume
    }
    try requireAvailable(item.url)
    return item.url
  }
}

extension MountedVolumeProvider: FileBrowserDuplicateProvider {
  func duplicate(_ item: FileItem) async throws {
    guard item.location.providerID == id else {
      throw MountedVolumeProviderError.outsideVolume
    }
    _ = try duplicate(item.url)
  }
}

extension MountedVolumeProvider: FileBrowserItemDetailProvider {
  func detailedItem(at location: FileLocation) async throws -> FileItem {
    guard location.providerID == id, let url = location.localURL else {
      throw MountedVolumeProviderError.outsideVolume
    }
    return try await Task.detached(priority: .userInitiated) {
      try self.item(at: url)
    }.value
  }
}

extension MountedVolumeProvider: FileBrowserPosixPermissionsProvider {
  func setPosixPermissions(_ permissions: Int, at location: FileLocation) async throws {
    guard location.providerID == id, let url = location.localURL else {
      throw MountedVolumeProviderError.outsideVolume
    }
    let normalizedPermissions = PosixPermissions.normalizedMode(permissions)
    try await Task.detached(priority: .userInitiated) {
      try self.requireAvailable(url)
      try FileManager.default.setAttributes(
        [.posixPermissions: normalizedPermissions],
        ofItemAtPath: url.path)
    }.value
  }
}

extension MountedVolumeProvider: FileBrowserFinderTagProvider {
  func setFinderTagNames(_ tagNames: [String], at location: FileLocation) async throws {
    guard location.providerID == id, let url = location.localURL else {
      throw MountedVolumeProviderError.outsideVolume
    }
    try await Task.detached(priority: .userInitiated) {
      try self.requireAvailable(url)
      try FinderTagResourceWriter.setTagNames(tagNames, at: url)
    }.value
  }
}

extension MountedVolumeProvider: FileBrowserFinderTagMetadataProvider {
  func finderTagNames(at location: FileLocation) async throws -> [String] {
    guard location.providerID == id, let url = location.localURL else {
      throw MountedVolumeProviderError.outsideVolume
    }
    return try await Task.detached(priority: .utility) {
      try self.requireAvailable(url)
      // 書込前のURLに残るリソース値キャッシュを引き継がず、現在のタグを読み直す。
      let freshURL = URL(fileURLWithPath: url.path)
      return try freshURL.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
    }.value
  }
}

extension MountedVolumeProvider: FileBrowserStreamingProvider {
  func contentsStream(
    of location: FileLocation,
    includingHidden: Bool,
    batchSize: Int
  ) -> AsyncThrowingStream<[FileItem], Error> {
    AsyncThrowingStream { continuation in
      let task = Task.detached(priority: .userInitiated) {
        do {
          guard location.providerID == self.id, let directoryURL = location.localURL else {
            throw MountedVolumeProviderError.outsideVolume
          }
          try self.requireAvailable(directoryURL)
          let localLocation = FileLocation(localURL: directoryURL)
          for try await batch in self.localProvider.contentsStream(
            of: localLocation,
            includingHidden: includingHidden,
            batchSize: batchSize)
          {
            let convertedBatch = batch.map { item in
              FileItem(
                url: item.url,
                providerID: self.id,
                isDirectory: item.isDirectory,
                isSymbolicLink: item.isSymbolicLink,
                isAliasFile: item.isAliasFile,
                size: item.size,
                modifiedAt: item.modifiedAt)
            }
            continuation.yield(convertedBatch)
          }
          continuation.finish()
        } catch is CancellationError {
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

extension MountedVolumeProvider: FileStreamTransferProvider {
  var preferredTransferChunkSize: Int { 1_048_576 }

  func fileChunks(for item: FileItem, chunkSize: Int) -> AsyncThrowingStream<Data, Error> {
    let limit = max(4, (4 * 1_048_576) / chunkSize)
    return BoundedChunkPipe.stream(limit: limit) { yield in
      guard item.location.providerID == self.id else {
        throw MountedVolumeProviderError.outsideVolume
      }
      try self.requireAvailable(item.url)
      guard let directTransfer = await self.directTransfer(for: item.url) else {
        try await self.localFileChunks(for: item, chunkSize: chunkSize, yield: yield)
        return
      }
      do {
        try await directTransfer.engine.prepareForTransfer()
      } catch SMBDirectTransferError.connectionFailed {
        await self.directTransferCache.markUnavailable(for: directTransfer.sharePath)
        try await self.localFileChunks(for: item, chunkSize: chunkSize, yield: yield)
        return
      }
      let chunks = await directTransfer.engine.fileChunks(
        at: directTransfer.path,
        chunkSize: chunkSize,
        rateLimiter: nil)
      for try await chunk in chunks {
        try await yield(chunk)
      }
    }
  }

  func writeFileChunks(
    _ chunks: AsyncThrowingStream<Data, Error>,
    to destination: FileLocation,
    replacingExisting: Bool,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws {
    guard destination.providerID == id,
      let destinationURL = destination.localURL
    else {
      throw MountedVolumeProviderError.outsideVolume
    }
    try requireAvailable(destinationURL)
    if let directTransfer = await directTransfer(for: destinationURL) {
      do {
        try await directTransfer.engine.prepareForTransfer()
      } catch SMBDirectTransferError.connectionFailed {
        await directTransferCache.markUnavailable(for: directTransfer.sharePath)
        try await localWriteFileChunks(
          chunks,
          to: destinationURL,
          replacingExisting: replacingExisting,
          progress: progress)
        return
      }
      await directTransferCache.registerDirectWrite(
        for: directTransfer.sharePath,
        engine: directTransfer.engine)
      try await directTransfer.engine.writeFileChunks(
        chunks,
        to: directTransfer.path,
        replacingExisting: replacingExisting,
        progress: progress)
      return
    }
    try await localWriteFileChunks(
      chunks,
      to: destinationURL,
      replacingExisting: replacingExisting,
      progress: progress)
  }

  private func directTransfer(
    for url: URL
  ) async -> (engine: SMBDirectTransferEngine, path: String, sharePath: SMBSharePath)? {
    guard let sharePath = sharePathResolver(url),
      let transfer = await directTransferCache.transfer(
        for: sharePath,
        preferredAccount: nil,
        credentialResolver: credentialResolver,
        engineMaking: directTransferEngine)
    else {
      return nil
    }
    return (transfer.engine, transfer.path, sharePath)
  }

  private func localFileChunks(
    for item: FileItem,
    chunkSize: Int,
    yield: @escaping @Sendable (Data) async throws -> Void
  ) async throws {
    guard item.location.providerID == self.id else {
      throw MountedVolumeProviderError.outsideVolume
    }
    try requireAvailable(item.url)
    let handle = try FileHandle(forReadingFrom: item.url)
    defer { try? handle.close() }
    while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
      try Task.checkCancellation()
      try await yield(chunk)
    }
  }

  private func localFileChunks(
    for item: FileItem,
    chunkSize: Int
  ) -> AsyncThrowingStream<Data, Error> {
    // 約4MB分をバッファする(チャンクサイズが小さいほど多くの個数を許容する)。
    let limit = max(4, (4 * 1_048_576) / chunkSize)
    return BoundedChunkPipe.stream(limit: limit) { yield in
      try await self.localFileChunks(for: item, chunkSize: chunkSize, yield: yield)
    }
  }

  private func localWriteFileChunks(
    _ chunks: AsyncThrowingStream<Data, Error>,
    to destinationURL: URL,
    replacingExisting: Bool,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws {
    if FileManager.default.fileExists(atPath: destinationURL.path) {
      guard replacingExisting else { throw CocoaError(.fileWriteFileExists) }
      try FileManager.default.removeItem(at: destinationURL)
    }
    FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
    let handle = try FileHandle(forWritingTo: destinationURL)
    defer { try? handle.close() }
    let writer = SMBTransferWriter(handle: handle)
    let clock = ContinuousClock()
    var lastSynchronizedAt = clock.now
    var progressBatcher = SMBTransferProgressBatcher()
    var completedBytes: Int64 = 0
    for try await chunk in chunks {
      try Task.checkCancellation()
      try await writer.write(chunk)
      progressBatcher.record(Int64(chunk.count))
      if progressBatcher.requiresSynchronization(after: clock.now - lastSynchronizedAt) {
        try await writer.synchronize()
        completedBytes += progressBatcher.acknowledge()
        progress(completedBytes)
        lastSynchronizedAt = clock.now
      }
    }
    if progressBatcher.hasPendingBytes {
      try await writer.synchronize()
      completedBytes += progressBatcher.acknowledge()
      progress(completedBytes)
    }
  }
}

/// SMBクライアントの書き込みキャッシュが進捗を先行させないよう、共有へ同期してから
/// 完了扱いにする。同期I/OはSwiftの協調実行器を占有しない専用キューで行う。
private final class SMBTransferWriter: @unchecked Sendable {
  private static let queue = DispatchQueue(label: "com.pky.PKPane.smb-transfer", qos: .utility)
  private let handle: FileHandle

  init(handle: FileHandle) {
    self.handle = handle
  }

  func write(_ chunk: Data) async throws {
    try await withCheckedThrowingContinuation { continuation in
      Self.queue.async { [self, chunk] in
        do {
          try handle.write(contentsOf: chunk)
          continuation.resume()
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  func synchronize() async throws {
    try await withCheckedThrowingContinuation { continuation in
      Self.queue.async { [self] in
        do {
          try handle.synchronize()
          continuation.resume()
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }
}

/// NASへの書き込みを最大8MBまたは200msまでまとめることで、進捗精度を保ちつつ
/// 同期呼び出しの往復待ちを抑える小さな状態機械です。
struct SMBTransferProgressBatcher {
  private static let maximumPendingBytes = Int64(8 * 1_024 * 1_024)
  private static let maximumSynchronizationInterval = Duration.milliseconds(200)

  private(set) var pendingBytes: Int64 = 0

  var hasPendingBytes: Bool { pendingBytes > 0 }

  mutating func record(_ bytes: Int64) {
    pendingBytes += bytes
  }

  func requiresSynchronization(after elapsed: Duration) -> Bool {
    pendingBytes >= Self.maximumPendingBytes || elapsed >= Self.maximumSynchronizationInterval
  }

  mutating func acknowledge() -> Int64 {
    defer { pendingBytes = 0 }
    return pendingBytes
  }
}

extension MountedVolumeProvider: FileBrowserProgressTransferProvider {
  func copy(
    _ item: FileItem,
    to directory: FileLocation,
    replacingExisting: Bool,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws {
    guard item.location.providerID == id,
      directory.providerID == id,
      let directoryURL = directory.localURL
    else {
      throw MountedVolumeProviderError.outsideVolume
    }
    _ = try await CancellableFileCopier.performOnDedicatedThread { isCancelled in
      try self.copy(
        item.url,
        to: directoryURL,
        replacingExisting: replacingExisting,
        progress: progress,
        isCancelled: isCancelled)
    }
  }
}

extension MountedVolumeProvider: FileTransferCommitProvider {
  func stagedFileSize(at temporaryLocation: FileLocation) async throws -> Int64? {
    guard temporaryLocation.providerID == id,
      let temporaryURL = temporaryLocation.localURL
    else {
      throw MountedVolumeProviderError.outsideVolume
    }
    try requireAvailable(temporaryURL)
    guard let sharePath = sharePathResolver(temporaryURL),
      let directWrite = await directTransferCache.registeredDirectWrite(for: sharePath)
    else {
      return nil
    }
    let size = try await directWrite.engine.statFile(at: directWrite.path)
    return Int64(clamping: size)
  }

  func commitTransferFile(
    from temporaryLocation: FileLocation,
    to destination: FileLocation,
    replacingExisting: Bool
  ) async throws {
    guard temporaryLocation.providerID == id,
      destination.providerID == id,
      let temporaryURL = temporaryLocation.localURL,
      let destinationURL = destination.localURL
    else {
      throw MountedVolumeProviderError.outsideVolume
    }
    let temporarySharePath = sharePathResolver(temporaryURL)
    let destinationSharePath = sharePathResolver(destinationURL)
    if let temporarySharePath {
      let committedDirectly = try await directTransferCache.withRegisteredDirectWrite(
        from: temporarySharePath,
        to: destinationSharePath
      ) { engine, temporaryPath, destinationPath in
        try requireAvailable(temporaryURL)
        try requireAvailable(destinationURL)
        try await engine.commitFile(
          temporaryPath: temporaryPath,
          destinationPath: destinationPath,
          replacingExisting: replacingExisting
        ) { backupPath in
          guard let backupFileName = backupPath.split(separator: "\\").last else { return }
          let backupURL = destinationURL.deletingLastPathComponent()
            .appending(path: String(backupFileName))
          try? FileManager.default.removeItem(at: backupURL)
        }
      }
      if committedDirectly { return }
    }
    try requireAvailable(temporaryURL)
    try requireAvailable(destinationURL)
    if FileManager.default.fileExists(atPath: destinationURL.path) {
      guard replacingExisting else { throw CocoaError(.fileWriteFileExists) }
      _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: temporaryURL)
    } else {
      try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
    }
  }

  func discardTransferFile(at temporaryLocation: FileLocation) async {
    guard temporaryLocation.providerID == id,
      let temporaryURL = temporaryLocation.localURL
    else { return }
    if let sharePath = sharePathResolver(temporaryURL) {
      let discardedDirectly = await directTransferCache.withRegisteredDirectWrite(
        for: sharePath
      ) { engine, path in
        do {
          try await engine.deleteFile(at: path)
        } catch {
          try? FileManager.default.removeItem(at: temporaryURL)
        }
      }
      if discardedDirectly { return }
    }
    try? FileManager.default.removeItem(at: temporaryURL)
  }
}
