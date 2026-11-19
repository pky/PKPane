import Foundation

private final class FTPPreviewDataAccumulator: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = Data()

  func append(_ data: Data, maximumBytes: UInt64) throws {
    try lock.withLock {
      let incomingCount = UInt64(data.count)
      guard incomingCount <= maximumBytes,
        UInt64(storage.count) <= maximumBytes - incomingCount
      else {
        throw FTPFileProviderError.previewTooLarge
      }
      storage.append(data)
    }
  }

  var data: Data { lock.withLock { storage } }
}

enum FTPFileProviderError: LocalizedError, Equatable {
  case invalidLocation
  case invalidName
  case previewTooLarge

  var errorDescription: String? {
    switch self {
    case .invalidLocation:
      "FTP上の場所を解釈できません。"
    case .invalidName:
      "FTP上で使用できない名前です。"
    case .previewTooLarge:
      "プレビューできるファイルサイズの上限を超えています。"
    }
  }
}

struct FTPFileProvider: Sendable {
  typealias SessionFactory = @Sendable () async throws -> any FTPClientSession

  private struct TreeEntry: Sendable {
    let sourcePath: String
    let destinationPath: String
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let expanded: Bool
  }

  private struct RemovalTarget: Sendable {
    let path: String
    let isDirectory: Bool
  }

  let target: FTPConnectionTarget
  let id: FileProviderID
  let connectionID: FileProviderConnectionID?
  let capabilities: FileProviderCapabilities = [
    .read, .write, .rename, .moveWithinProvider, .copyWithinProvider,
    .deletePermanently, .readSymbolicLink,
  ]

  private let browsingSession: any FTPClientSession
  private let sessionFactory: SessionFactory
  private let previewCache: RemotePreviewCache

  init(
    target: FTPConnectionTarget,
    session: any FTPClientSession,
    sessionFactory: @escaping SessionFactory,
    previewCache: RemotePreviewCache = .shared
  ) {
    self.target = target
    browsingSession = session
    self.sessionFactory = sessionFactory
    self.previewCache = previewCache
    let connectionID = Self.connectionID(for: target)
    self.connectionID = connectionID
    id = FileProviderID(rawValue: connectionID.rawValue)
  }

  static func connect(
    to target: FTPConnectionTarget,
    service: FTPConnectionService = FTPConnectionService(),
    previewCache: RemotePreviewCache = .shared
  ) async throws -> FTPFileProvider {
    let session = try await service.connect(to: target)
    return FTPFileProvider(
      target: target,
      session: session,
      sessionFactory: { try await service.connect(to: target) },
      previewCache: previewCache)
  }

  static func connectionID(for target: FTPConnectionTarget) -> FileProviderConnectionID {
    FileProviderConnectionID(
      rawValue:
        "ftp-\(target.security.rawValue)-\(target.host.lowercased()):\(target.port):\(target.username)"
    )
  }

  func contents(of remotePath: String) async throws -> [FileItem] {
    let directory = normalized(remotePath)
    return try await browsingSession.contents(of: directory).map { entry in
      let path = childPath(named: entry.name, in: directory)
      return fileItem(entry: entry, path: path)
    }
    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  private func fileItem(entry: FTPDirectoryEntry, path: String) -> FileItem {
    FileItem(
      remotePath: path,
      url: url(for: path),
      providerID: id,
      isDirectory: entry.isDirectory,
      isSymbolicLink: entry.isSymbolicLink,
      size: entry.size,
      modifiedAt: entry.modifiedAt,
      posixPermissions: entry.posixPermissions)
  }

  private func withNewSession<Result: Sendable>(
    _ operation: @Sendable (any FTPClientSession) async throws -> Result
  ) async throws -> Result {
    let session = try await sessionFactory()
    do {
      let result = try await operation(session)
      await session.close()
      return result
    } catch {
      await session.close()
      throw error
    }
  }

  /// RNTOを使わず、サーバーが予約した新規項目だけへ転送する。
  func copyKeepingBoth(
    item: FileItem, from source: any FileBrowserProvider,
    to directory: FileLocation, destinationName: String,
    requiredDestinationName: String? = nil,
    reserved: @escaping @Sendable (FileLocation) async throws -> Void,
    progress: @escaping @Sendable (FileTransferProgress) -> Void
  ) async throws -> FileLocation {
    try await withNewSession { session in
      try await FTPKeepBothTransfer(
        session: session, source: source, targetID: id, target: target,
        chunkSize: preferredTransferChunkSize
      ).copy(
        item: item, to: directory, destinationName: destinationName,
        requiredDestinationName: requiredDestinationName,
        reserved: reserved, progress: progress)
    }
  }

  private func safeEntries(
    at remotePath: String,
    using session: any FTPClientSession
  ) async throws -> [FTPDirectoryEntry] {
    let entries = try await session.contents(of: remotePath)
    var names = Set<String>()
    for entry in entries {
      guard isSafeName(entry.name), names.insert(entry.name).inserted else {
        throw FTPFileProviderError.invalidLocation
      }
    }
    return entries
  }

  private func existingEntry(named name: String, in directory: String) async throws
    -> FTPDirectoryEntry?
  {
    try await safeEntries(at: directory, using: browsingSession).first { $0.name == name }
  }

  private func permanentlyDeleteItem(_ item: FileItem) async throws {
    guard item.location.providerID == id, let path = item.location.remotePath else {
      throw FTPFileProviderError.invalidLocation
    }
    if item.isDirectory, !item.isSymbolicLink {
      try await removeDirectoryTree(at: path, using: browsingSession)
    } else {
      try Task.checkCancellation()
      try await browsingSession.remove(at: path, isDirectory: false)
    }
  }

  private func removeDirectoryTree(
    at remotePath: String,
    using session: any FTPClientSession
  ) async throws {
    let plan = try await makeRemovalPlan(at: remotePath, using: session)
    for target in plan {
      try Task.checkCancellation()
      try await session.remove(at: target.path, isDirectory: target.isDirectory)
    }
  }

  private func makeRemovalPlan(
    at remotePath: String,
    using session: any FTPClientSession
  ) async throws -> [RemovalTarget] {
    let root = normalized(remotePath)
    guard root != "/" else { throw FTPFileProviderError.invalidLocation }
    var result: [RemovalTarget] = []
    var pending = [
      TreeEntry(
        sourcePath: root,
        destinationPath: "",
        isDirectory: true,
        isSymbolicLink: false,
        expanded: false)
    ]
    while let current = pending.popLast() {
      try Task.checkCancellation()
      if !current.isDirectory || current.isSymbolicLink {
        result.append(RemovalTarget(path: current.sourcePath, isDirectory: false))
      } else if current.expanded {
        result.append(RemovalTarget(path: current.sourcePath, isDirectory: true))
      } else {
        let entries = try await safeEntries(at: current.sourcePath, using: session)
        pending.append(
          TreeEntry(
            sourcePath: current.sourcePath,
            destinationPath: "",
            isDirectory: true,
            isSymbolicLink: false,
            expanded: true))
        for entry in entries.reversed() {
          pending.append(
            TreeEntry(
              sourcePath: childPath(named: entry.name, in: current.sourcePath),
              destinationPath: "",
              isDirectory: entry.isDirectory,
              isSymbolicLink: entry.isSymbolicLink,
              expanded: false))
        }
      }
    }
    return result
  }

  private func copyItem(_ item: FileItem, to destinationPath: String) async throws {
    guard let sourcePath = item.location.remotePath else {
      throw FTPFileProviderError.invalidLocation
    }
    if item.isDirectory, !item.isSymbolicLink {
      try validateCopyDestination(sourcePath: sourcePath, destinationPath: destinationPath)
      let plan = try await makeCopyPlan(from: sourcePath, to: destinationPath)
      try await withCopySessions { sourceSession, destinationSession in
        var createdRoot = false
        do {
          for (index, entry) in plan.enumerated() {
            try Task.checkCancellation()
            if entry.isDirectory, !entry.isSymbolicLink {
              try await destinationSession.createDirectory(at: entry.destinationPath)
              if index == 0 { createdRoot = true }
            } else {
              try await copyFile(
                from: entry.sourcePath,
                to: entry.destinationPath,
                sourceSession: sourceSession,
                destinationSession: destinationSession)
            }
          }
        } catch {
          if createdRoot {
            try? await removeDirectoryTree(at: destinationPath, using: destinationSession)
          }
          throw error
        }
      }
      return
    }
    try await withCopySessions { sourceSession, destinationSession in
      try await copyFile(
        from: sourcePath,
        to: destinationPath,
        sourceSession: sourceSession,
        destinationSession: destinationSession)
    }
  }

  private func withCopySessions(
    _ operation:
      @Sendable (
        any FTPClientSession,
        any FTPClientSession
      ) async throws -> Void
  ) async throws {
    let sourceSession = try await sessionFactory()
    do {
      let destinationSession = try await sessionFactory()
      do {
        try await operation(sourceSession, destinationSession)
        await destinationSession.close()
        await sourceSession.close()
      } catch {
        await destinationSession.close()
        await sourceSession.close()
        throw error
      }
    } catch {
      await sourceSession.close()
      throw error
    }
  }

  private func copyFile(
    from sourcePath: String,
    to destinationPath: String,
    sourceSession: any FTPClientSession,
    destinationSession: any FTPClientSession
  ) async throws {
    let chunks = BoundedChunkPipe.stream(limit: 16) { yield in
      try await sourceSession.streamFileContents(of: sourcePath) { chunk in
        try await yield(chunk)
      }
    }
    try await destinationSession.writeFileContents(
      to: destinationPath,
      chunks: chunks,
      progress: { _ in })
  }

  private func makeCopyPlan(from sourcePath: String, to destinationPath: String) async throws
    -> [TreeEntry]
  {
    var result: [TreeEntry] = []
    var pending = [
      TreeEntry(
        sourcePath: normalized(sourcePath),
        destinationPath: normalized(destinationPath),
        isDirectory: true,
        isSymbolicLink: false,
        expanded: false)
    ]
    while let current = pending.popLast() {
      try Task.checkCancellation()
      result.append(current)
      guard current.isDirectory, !current.isSymbolicLink else { continue }
      let entries = try await safeEntries(at: current.sourcePath, using: browsingSession)
      for entry in entries.reversed() {
        pending.append(
          TreeEntry(
            sourcePath: childPath(named: entry.name, in: current.sourcePath),
            destinationPath: childPath(named: entry.name, in: current.destinationPath),
            isDirectory: entry.isDirectory,
            isSymbolicLink: entry.isSymbolicLink,
            expanded: false))
      }
    }
    return result
  }

  private func validateCopyDestination(sourcePath: String, destinationPath: String) throws {
    let source = normalized(sourcePath)
    let destination = normalized(destinationPath)
    guard destination != source,
      !destination.hasPrefix("\(source)/"),
      !source.hasPrefix("\(destination)/")
    else {
      throw FTPFileProviderError.invalidLocation
    }
  }

  private func duplicateName(for name: String, existingNames: Set<String>) -> String {
    let path = name as NSString
    let fileExtension = path.pathExtension
    let baseName = path.deletingPathExtension
    var number = 1
    while true {
      let suffix = number == 1 ? "のコピー" : "のコピー\(number)"
      let candidate =
        fileExtension.isEmpty
        ? baseName + suffix : baseName + suffix + "." + fileExtension
      if !existingNames.contains(candidate) { return candidate }
      number += 1
    }
  }

  private func normalized(_ path: String) -> String {
    guard !path.isEmpty else { return "/" }
    var result = path.hasPrefix("/") ? path : "/\(path)"
    while result.count > 1, result.hasSuffix("/") { result.removeLast() }
    return result
  }

  private func parentPath(of path: String) -> String {
    let components = normalized(path).split(separator: "/")
    guard components.count > 1 else { return "/" }
    return "/" + components.dropLast().joined(separator: "/")
  }

  private func childPath(named name: String, in directory: String) -> String {
    normalized(directory) == "/" ? "/\(name)" : "\(normalized(directory))/\(name)"
  }

  private func validatedName(_ name: String) throws -> String {
    let result = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard isSafeName(result) else { throw FTPFileProviderError.invalidName }
    return result
  }

  private func isSafeName(_ name: String) -> Bool {
    !name.isEmpty && name != "." && name != ".." && !name.contains("/")
      && !name.utf8.contains(where: { $0 == 0 || $0 == 10 || $0 == 13 })
  }

  private func url(for path: String) -> URL {
    var components = URLComponents()
    components.scheme = target.security == .plain ? "ftp" : "ftps"
    components.user = target.username
    components.host = target.host
    components.port = target.port
    components.path = path
    return components.url ?? URL(fileURLWithPath: path)
  }
}

extension FTPFileProvider: FileBrowserOperationProvider {
  func contents(of location: FileLocation) async throws -> [FileItem] {
    guard location.providerID == id, let path = location.remotePath else {
      throw FTPFileProviderError.invalidLocation
    }
    return try await contents(of: path)
  }

  func parent(of location: FileLocation) -> FileLocation? {
    guard location.providerID == id, let path = location.remotePath, normalized(path) != "/" else {
      return nil
    }
    return FileLocation(remotePath: parentPath(of: path), providerID: id)
  }

  func breadcrumbs(
    for location: FileLocation,
    constrainedTo _: FileLocation?
  ) -> [FileBrowserBreadcrumb] {
    guard location.providerID == id, let path = location.remotePath else { return [] }
    var current = ""
    var result = [
      FileBrowserBreadcrumb(
        location: FileLocation(remotePath: "/", providerID: id),
        name: "/")
    ]
    for component in normalized(path).split(separator: "/") {
      current += "/\(component)"
      result.append(
        FileBrowserBreadcrumb(
          location: FileLocation(remotePath: current, providerID: id),
          name: String(component)))
    }
    return result
  }

  func createDirectory(named name: String, in location: FileLocation) async throws {
    guard location.providerID == id, let directory = location.remotePath else {
      throw FTPFileProviderError.invalidLocation
    }
    try await browsingSession.createDirectory(
      at: childPath(named: try validatedName(name), in: directory))
  }

  func rename(_ item: FileItem, to name: String) async throws {
    guard item.location.providerID == id, let source = item.location.remotePath else {
      throw FTPFileProviderError.invalidLocation
    }
    try await browsingSession.rename(
      at: source,
      to: childPath(named: try validatedName(name), in: parentPath(of: source)))
  }

  func delete(_ item: FileItem) async throws {
    guard item.location.providerID == id else { throw FTPFileProviderError.invalidLocation }
    throw FileBrowserOperationError.trashUnavailable
  }
}

extension FTPFileProvider: FileBrowserPermanentDeleteProvider {
  func permanentlyDelete(_ item: FileItem) async throws {
    try await permanentlyDeleteItem(item)
  }
}

extension FTPFileProvider: FileBrowserDuplicateProvider {
  func duplicate(_ item: FileItem) async throws {
    guard item.location.providerID == id, let source = item.location.remotePath else {
      throw FTPFileProviderError.invalidLocation
    }
    let directory = parentPath(of: source)
    let entries = try await safeEntries(at: directory, using: browsingSession)
    let destinationName = duplicateName(
      for: item.name,
      existingNames: Set(entries.map(\.name)))
    try await copyItem(
      item,
      to: childPath(named: destinationName, in: directory))
  }
}

extension FTPFileProvider: FileBrowserTransferProvider {
  func move(
    _ item: FileItem,
    to directory: FileLocation,
    replacingExisting: Bool
  ) async throws {
    guard item.location.providerID == id,
      directory.providerID == id,
      let source = item.location.remotePath,
      let destinationDirectory = directory.remotePath
    else { throw FTPFileProviderError.invalidLocation }
    let destination = childPath(named: item.name, in: destinationDirectory)
    if normalized(source) == destination { return }
    if replacingExisting, normalized(source).hasPrefix("\(destination)/") {
      throw FTPFileProviderError.invalidLocation
    }
    if item.isDirectory {
      try validateCopyDestination(sourcePath: source, destinationPath: destination)
    }
    if let existing = try await existingEntry(named: item.name, in: destinationDirectory) {
      guard replacingExisting else { throw CocoaError(.fileWriteFileExists) }
      try await permanentlyDeleteItem(fileItem(entry: existing, path: destination))
    }
    try await browsingSession.rename(at: source, to: destination)
  }

  func copy(
    _ item: FileItem,
    to directory: FileLocation,
    replacingExisting: Bool
  ) async throws {
    guard item.location.providerID == id,
      directory.providerID == id,
      let source = item.location.remotePath,
      let destinationDirectory = directory.remotePath
    else { throw FTPFileProviderError.invalidLocation }
    let destination = childPath(named: item.name, in: destinationDirectory)
    // 同一・包含関係は既存宛先を削除する前に検証する。
    try validateCopyDestination(sourcePath: source, destinationPath: destination)
    if let existing = try await existingEntry(named: item.name, in: destinationDirectory) {
      guard replacingExisting else { throw CocoaError(.fileWriteFileExists) }
      try await permanentlyDeleteItem(fileItem(entry: existing, path: destination))
    }
    try await copyItem(item, to: destination)
  }

  func removeAfterCrossProviderMove(_ item: FileItem) async throws {
    try await permanentlyDeleteItem(item)
  }
}

extension FTPFileProvider: FileStreamTransferProvider {
  var preferredTransferChunkSize: Int { 256 * 1_024 }

  func fileChunks(for item: FileItem, chunkSize _: Int) -> AsyncThrowingStream<Data, Error> {
    BoundedChunkPipe.stream(limit: 16) { yield in
      guard item.location.providerID == id, let path = item.location.remotePath else {
        throw FTPFileProviderError.invalidLocation
      }
      try await withNewSession { session in
        try await session.streamFileContents(of: path) { chunk in
          try await yield(chunk)
        }
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
      let path = destination.remotePath,
      let parent = destination.deletingLastPathComponent(),
      let parentPath = parent.remotePath
    else { throw FTPFileProviderError.invalidLocation }
    if !replacingExisting,
      try await existingEntry(named: URL(fileURLWithPath: path).lastPathComponent, in: parentPath)
        != nil
    {
      throw CocoaError(.fileWriteFileExists)
    }
    try await withNewSession { session in
      try await session.writeFileContents(to: path, chunks: chunks, progress: progress)
    }
  }
}

extension FTPFileProvider: FileTransferCommitProvider {
  func stagedFileSize(at temporaryLocation: FileLocation) async throws -> Int64? {
    guard temporaryLocation.providerID == id, let path = temporaryLocation.remotePath else {
      throw FTPFileProviderError.invalidLocation
    }
    return try await browsingSession.fileSize(at: path)
  }

  func commitTransferFile(
    from temporaryLocation: FileLocation,
    to destination: FileLocation,
    replacingExisting: Bool
  ) async throws {
    guard temporaryLocation.providerID == id,
      destination.providerID == id,
      let temporaryPath = temporaryLocation.remotePath,
      let destinationPath = destination.remotePath,
      let parent = destination.deletingLastPathComponent(),
      let parentPath = parent.remotePath
    else { throw FTPFileProviderError.invalidLocation }
    let name = destinationPath.split(separator: "/").last.map(String.init) ?? ""
    if let existing = try await existingEntry(named: name, in: parentPath) {
      guard replacingExisting else { throw CocoaError(.fileWriteFileExists) }
      try await permanentlyDeleteItem(fileItem(entry: existing, path: destinationPath))
    }
    try await browsingSession.rename(at: temporaryPath, to: destinationPath)
  }

  func discardTransferFile(at temporaryLocation: FileLocation) async {
    guard temporaryLocation.providerID == id, let path = temporaryLocation.remotePath else {
      return
    }
    try? await browsingSession.remove(at: path, isDirectory: false)
  }
}

extension FTPFileProvider: FileBrowserPreviewProvider {
  func previewURL(for item: FileItem) async throws -> URL {
    guard item.location.providerID == id,
      let path = item.location.remotePath,
      !item.isDirectory,
      let connectionID
    else { throw FTPFileProviderError.invalidLocation }
    if let size = item.size, size > Int64(RemotePreviewCache.maximumFileBytes) {
      throw FTPFileProviderError.previewTooLarge
    }
    let key = RemotePreviewCache.Key(
      connectionID: connectionID,
      remotePath: path,
      modifiedAt: item.modifiedAt,
      size: item.size)
    return try await previewCache.cachedURL(for: key, fileName: item.name) {
      try await withNewSession { session in
        let accumulator = FTPPreviewDataAccumulator()
        try await session.streamFileContents(of: path) { chunk in
          try accumulator.append(chunk, maximumBytes: RemotePreviewCache.maximumFileBytes)
        }
        return accumulator.data
      }
    }
  }

  func detailThumbnailURL(for item: FileItem) async throws -> URL? {
    guard item.location.providerID == id,
      let path = item.location.remotePath,
      let connectionID
    else { return nil }
    return await previewCache.cachedURLIfPresent(
      for: RemotePreviewCache.Key(
        connectionID: connectionID,
        remotePath: path,
        modifiedAt: item.modifiedAt,
        size: item.size))
  }
}

extension FTPFileProvider: FileBrowserItemDetailProvider, FileBrowserItemSizeProvider {
  func detailedItem(at location: FileLocation) async throws -> FileItem {
    guard let parent = location.deletingLastPathComponent(),
      let item = try await contents(of: parent).first(where: { $0.location == location })
    else { throw FTPFileProviderError.invalidLocation }
    return item
  }

  func itemSize(at location: FileLocation) async throws -> Int64? {
    guard location.providerID == id, let path = location.remotePath else {
      throw FTPFileProviderError.invalidLocation
    }
    return try await browsingSession.fileSize(at: path)
  }
}

extension FTPFileProvider: FileBrowserPosixPermissionsProvider {
  func setPosixPermissions(_ permissions: Int, at location: FileLocation) async throws {
    guard location.providerID == id, let path = location.remotePath else {
      throw FTPFileProviderError.invalidLocation
    }
    try await browsingSession.setPosixPermissions(permissions, at: path)
  }
}

extension FTPFileProvider: RemoteEditProvider {
  func downloadWorkingCopy(for item: FileItem, to localURL: URL) async throws {
    guard item.location.providerID == id, let path = item.location.remotePath, !item.isDirectory
    else { throw FTPFileProviderError.invalidLocation }
    try FileManager.default.createDirectory(
      at: localURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: localURL.path, contents: nil)
    let handle = try FileHandle(forWritingTo: localURL)
    defer { try? handle.close() }
    try await withNewSession { session in
      try await session.streamFileContents(of: path) { chunk in
        try handle.write(contentsOf: chunk)
      }
    }
  }

  func item(at location: FileLocation) async throws -> FileItem? {
    guard let parent = location.deletingLastPathComponent() else { return nil }
    return try await contents(of: parent).first { $0.location == location }
  }

  func uploadWorkingCopySafely(from localURL: URL, to location: FileLocation) async throws {
    guard location.providerID == id,
      let parent = location.deletingLastPathComponent(),
      let temporary = parent.appending(
        pathComponent: ".\(localURL.lastPathComponent).pkpane-edit-\(UUID().uuidString)")
    else { throw FTPFileProviderError.invalidLocation }
    let cancellation = ChunkPipeCancellation()
    defer { cancellation.cancel() }
    let chunks = BoundedChunkPipe.fileStream(
      at: localURL, chunkSize: preferredTransferChunkSize, cancellation: cancellation)
    do {
      try await writeFileChunks(chunks, to: temporary, replacingExisting: false) { _ in }
      try Task.checkCancellation()
      let expected = try localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init)
      if let expected, try await stagedFileSize(at: temporary) != expected {
        throw CocoaError(.fileWriteUnknown)
      }
      try Task.checkCancellation()
      try await commitTransferFile(from: temporary, to: location, replacingExisting: true)
    } catch {
      cancellation.cancel()
      await cancellation.waitForCompletion()
      await discardTransferFile(at: temporary)
      throw error
    }
  }
}
