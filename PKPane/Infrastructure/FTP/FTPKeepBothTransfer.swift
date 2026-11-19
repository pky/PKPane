import Foundation
import Synchronization

/// FTPの別名転送だけは、RNTOではなくサーバーの新規作成応答で所有を確立する。
/// 所有したパスの一覧を持ち、他者が追加した子を再帰削除しない。
struct FTPKeepBothTransfer: Sendable {
  private struct OwnedPath: Sendable {
    let path: String
    let isDirectory: Bool
  }

  private final class State: Sendable {
    private struct Value {
      var owned: [OwnedPath] = []
      var root: FileLocation?
      var completedBytes: Int64 = 0
    }
    private let value = Mutex(Value())
    func add(path: String, isDirectory: Bool) {
      value.withLock { $0.owned.append(OwnedPath(path: path, isDirectory: isDirectory)) }
    }
    func setRoot(_ root: FileLocation) { value.withLock { $0.root = root } }
    var root: FileLocation? { value.withLock { $0.root } }
    var owned: [OwnedPath] { value.withLock { $0.owned } }
    var completedBytes: Int64 { value.withLock { $0.completedBytes } }
    func complete(bytes: Int64) { value.withLock { $0.completedBytes += bytes } }
  }

  let session: any FTPClientSession
  let source: any FileBrowserProvider
  let targetID: FileProviderID
  let target: FTPConnectionTarget
  let chunkSize: Int

  func copy(
    item: FileItem, to directory: FileLocation, destinationName: String,
    requiredDestinationName: String?,
    reserved: @escaping @Sendable (FileLocation) async throws -> Void,
    progress: @escaping @Sendable (FileTransferProgress) -> Void
  ) async throws -> FileLocation {
    guard directory.providerID == targetID, let directoryPath = directory.remotePath,
      let candidate = directory.appending(
        pathComponent: requiredDestinationName ?? destinationName),
      let readable = source as? any FileStreamReadableProvider
    else { throw FTPFileProviderError.invalidLocation }
    let sharesEndpoint =
      source.id == targetID
      || ((source as? FTPFileProvider).map {
        $0.target.host.lowercased() == target.host.lowercased()
          && $0.target.port == target.port && $0.target.username == target.username
      } ?? false)
    if item.isDirectory, sharesEndpoint, let sourcePath = item.location.remotePath,
      let destinationPath = candidate.remotePath
    {
      let sourcePath = try await session.canonicalDirectoryPath(at: sourcePath)
      let destinationParent = try await session.canonicalDirectoryPath(at: directoryPath)
      guard destinationParent.utf8.elementsEqual(directoryPath.utf8) else {
        throw FTPUniqueCreationError.invalidDestination
      }
      let destinationPath = URL(filePath: destinationPath).standardized.path
      let sourcePrefix = sourcePath == "/" ? "/" : sourcePath + "/"
      let destinationPrefix = destinationPath == "/" ? "/" : destinationPath + "/"
      guard destinationPath != sourcePath,
        !destinationPath.hasPrefix(sourcePrefix),
        !sourcePath.hasPrefix(destinationPrefix)
      else { throw ProviderFileTransferServiceError.invalidDestination }
    }
    let state = State()
    do {
      try Task.checkCancellation()
      if item.isDirectory, !item.isSymbolicLink {
        let created = try await createDirectory(
          named: requiredDestinationName ?? destinationName, in: directory, state: state)
        state.setRoot(created)
        try await reserved(created)
        try await copyChildren(
          of: item, to: created, readable: readable, state: state,
          progress: progress)
      } else {
        let path = try await writeFile(
          item: item, readable: readable, in: directoryPath, suggestedName: requiredDestinationName,
          reserved: { path in
            let actual = try location(for: path, in: directory)
            state.add(path: path, isDirectory: false)
            state.setRoot(actual)
            try Task.checkCancellation()
            try await reserved(actual)
            if let requiredDestinationName,
              !name(in: actual).utf8.elementsEqual(requiredDestinationName.utf8)
            {
              throw FTPKeepBothTransferError.changedRequestedName(requiredDestinationName)
            }
          },
          progress: { bytes in
            progress(FileTransferProgress(completedBytes: bytes, totalBytes: item.size))
          })
        guard let actualPath = state.root?.remotePath, actualPath.utf8.elementsEqual(path.utf8)
        else {
          throw FTPUniqueCreationError.creationOutcomeUnknown(directoryPath: directoryPath)
        }
        try Task.checkCancellation()
        try await verify(item: item, at: path)
      }
      try Task.checkCancellation()
      guard let result = state.root else {
        throw FTPUniqueCreationError.creationOutcomeUnknown(directoryPath: directoryPath)
      }
      return result
    } catch {
      let paths = state.owned
      let resultIsUnknown: Bool
      if let uniqueError = error as? FTPUniqueCreationError,
        case .creationOutcomeUnknown = uniqueError
      {
        resultIsUnknown = true
      } else {
        resultIsUnknown = false
      }
      let remaining: [String]
      if !resultIsUnknown, await session.isActive() {
        remaining = await Task.detached { [session] in
          var remaining: [String] = []
          for entry in paths.reversed() {
            do {
              try await session.remove(at: entry.path, isDirectory: entry.isDirectory)
            } catch {
              remaining.append(entry.path)
            }
          }
          return remaining
        }.value
      } else {
        remaining = paths.map(\.path)
      }
      if resultIsUnknown || !remaining.isEmpty {
        throw TransferRecoveryError(
          underlyingDescription: PKPaneErrorClassifier.classify(error).displayMessage,
          recoveryDescription: String(
            localized:
              "転送先に未完成の項目が残っている可能性があります。「\(remaining.first ?? directoryPath)」を確認してください。元の項目は保持しています。"
          ))
      }
      throw error
    }
  }

  private func createDirectory(
    named name: String, in parent: FileLocation, state: State
  ) async throws -> FileLocation {
    guard let expected = parent.appending(pathComponent: name), let path = expected.remotePath
    else {
      throw FTPFileProviderError.invalidName
    }
    let pathCreated = try await session.createExclusiveDirectory(at: path)
    let actual = try location(for: pathCreated, in: parent)
    state.add(path: pathCreated, isDirectory: true)
    guard pathCreated.utf8.elementsEqual(path.utf8) else {
      throw FTPUniqueCreationError.creationOutcomeUnknown(directoryPath: parent.remotePath ?? path)
    }
    return actual
  }

  private func copyChildren(
    of directoryItem: FileItem, to directory: FileLocation,
    readable: any FileStreamReadableProvider, state: State,
    progress: @escaping @Sendable (FileTransferProgress) -> Void
  ) async throws {
    let children = try await source.contents(of: directoryItem.location)
    for child in children {
      try Task.checkCancellation()
      if child.isDirectory, !child.isSymbolicLink {
        let created = try await createDirectory(named: child.name, in: directory, state: state)
        try await copyChildren(
          of: child, to: created, readable: readable, state: state,
          progress: progress)
      } else {
        guard let path = directory.remotePath else { throw FTPFileProviderError.invalidLocation }
        let baseline = state.completedBytes
        let actualPath = try await writeFile(
          item: child, readable: readable, in: path, suggestedName: child.name,
          reserved: { actualPath in
            let actual = try location(for: actualPath, in: directory)
            state.add(path: actualPath, isDirectory: false)
            guard let expectedPath = directory.appending(pathComponent: child.name)?.remotePath,
              actualPath.utf8.elementsEqual(expectedPath.utf8)
            else {
              throw FTPKeepBothTransferError.changedChildName(child.name)
            }
            try Task.checkCancellation()
          },
          progress: { bytes in
            progress(FileTransferProgress(completedBytes: baseline + bytes, totalBytes: nil))
          })
        try Task.checkCancellation()
        try await verify(item: child, at: actualPath)
        state.complete(bytes: child.size ?? 0)
      }
    }
  }

  private func writeFile(
    item: FileItem, readable: any FileStreamReadableProvider,
    in directoryPath: String, suggestedName: String?,
    reserved: @escaping @Sendable (String) async throws -> Void,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws -> String {
    let cancellation = ChunkPipeCancellation()
    do {
      let result = try await session.writeUniqueFileContents(
        in: directoryPath, suggestedName: suggestedName,
        chunks: {
          BoundedChunkPipe.stream(limit: 16, rateLimiter: nil, cancellation: cancellation) {
            yield in
            for try await chunk in readable.fileChunks(for: item, chunkSize: chunkSize) {
              try Task.checkCancellation()
              try await yield(chunk)
            }
            try Task.checkCancellation()
          }
        }, reserved: reserved, progress: progress)
      cancellation.cancel()
      await cancellation.waitForCompletion()
      return result
    } catch {
      cancellation.cancel()
      await cancellation.waitForCompletion()
      throw error
    }
  }

  private func verify(item: FileItem, at path: String) async throws {
    guard item.size != nil, !item.isSymbolicLink else { return }
    guard let actualSize = try await session.fileSize(at: path) else {
      throw CocoaError(.fileWriteUnknown)
    }
    try TransferSizeVerifier.verify(
      itemName: item.name, expectedBytes: item.size, isSymbolicLink: item.isSymbolicLink,
      actualBytes: actualSize)
  }

  private func location(for path: String, in directory: FileLocation) throws -> FileLocation {
    let name =
      path.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
    guard !name.utf8.contains(where: { $0 == 0 || $0 == 10 || $0 == 13 }),
      let result = directory.appending(pathComponent: name),
      let expected = result.remotePath, expected.utf8.elementsEqual(path.utf8)
    else {
      throw FTPUniqueCreationError.creationOutcomeUnknown(
        directoryPath: directory.remotePath ?? "/")
    }
    return result
  }

  private func name(in location: FileLocation) -> String {
    location.remotePath?.split(separator: "/").last.map(String.init) ?? ""
  }
}

private enum FTPKeepBothTransferError: LocalizedError, ReconnectFutileError {
  case changedChildName(String)
  case changedRequestedName(String)
  var errorDescription: String? {
    switch self {
    case .changedChildName(let name):
      String(localized: "このFTPサーバーではフォルダ内の名前「\(name)」を保持した別名転送を利用できません。既存項目は変更していません。")
    case .changedRequestedName(let name):
      String(localized: "このFTPサーバーでは指定した名前「\(name)」を安全に作成できません。転送元は保持しています。")
    }
  }
}

enum FTPKeepBothRetryError: LocalizedError, ReconnectFutileError {
  case existingReservation(String)
  var errorDescription: String? {
    switch self {
    case .existingReservation(let name):
      String(localized: "予約済みの転送先「\(name)」が残っています。内容を確認してから再試行してください。別のコピーは作成していません。")
    }
  }
}
