import Foundation

struct FileTransferProgress: Equatable, Sendable {
  let completedBytes: Int64
  let totalBytes: Int64?
}

protocol FileStreamReadableProvider: FileBrowserProvider {
  /// このProviderからの読み出しに使う、望ましいチャンクサイズ。
  /// クロスプロバイダ転送はProviderFileTransferServiceが転送先のこの値を採用し、
  /// 読み側(fileChunks)へも同値を渡す(プロトコル・媒体ごとの最適粒度が異なるため)。
  var preferredTransferChunkSize: Int { get }
  func fileChunks(for item: FileItem, chunkSize: Int) -> AsyncThrowingStream<Data, Error>
}

protocol FileStreamTransferProvider: FileStreamReadableProvider {
  func writeFileChunks(
    _ chunks: AsyncThrowingStream<Data, Error>,
    to destination: FileLocation,
    replacingExisting: Bool,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws
}

extension FileStreamReadableProvider {
  var preferredTransferChunkSize: Int { 1_048_576 }
}

enum ProviderFileTransferServiceError: LocalizedError {
  case unsupportedSource
  case unsupportedDestination
  case invalidDestination
  case temporaryCommitUnavailable

  var errorDescription: String? {
    switch self {
    case .unsupportedSource:
      "この接続からファイルを読み出せません。"
    case .unsupportedDestination:
      "この接続へファイルを書き込めません。"
    case .invalidDestination:
      "転送先の場所が無効です。"
    case .temporaryCommitUnavailable:
      "この接続では安全な転送の確定を利用できません。"
    }
  }
}

struct ProviderFileTransferService {
  func copy(
    item: FileItem,
    from source: any FileBrowserProvider,
    to destination: FileLocation,
    using target: any FileBrowserProvider,
    replacingExisting: Bool = false,
    progress: @escaping @Sendable (FileTransferProgress) -> Void = { _ in }
  ) async throws {
    guard let source = source as? any FileStreamReadableProvider else {
      throw ProviderFileTransferServiceError.unsupportedSource
    }
    guard let target = target as? any FileStreamTransferProvider else {
      throw ProviderFileTransferServiceError.unsupportedDestination
    }
    guard let commitProvider = target as? any FileTransferCommitProvider else {
      throw ProviderFileTransferServiceError.temporaryCommitUnavailable
    }
    guard let directory = destination.deletingLastPathComponent(),
      let temporaryDestination = directory.appending(pathComponent: temporaryName(for: destination))
    else {
      throw ProviderFileTransferServiceError.invalidDestination
    }
    do {
      // 転送先が読み書きに望むチャンクサイズ(プロトコル・媒体ごとの最適粒度)を、
      // 読み側(source.fileChunks)にもそのまま使わせる。
      let chunks = source.fileChunks(for: item, chunkSize: target.preferredTransferChunkSize)
      try await target.writeFileChunks(
        chunks,
        to: temporaryDestination,
        replacingExisting: false
      ) { completedBytes in
        progress(FileTransferProgress(completedBytes: completedBytes, totalBytes: item.size))
      }
      try Task.checkCancellation()
      // コミット(確定名への公開)前に検証する。一時ファイルの段階で不一致を検出すれば、
      // 破損した内容が実際の転送先パスへ公開されることも、失敗時のdiscardTransferFileが
      // 一時ファイルを確実に消せることも両立する。
      if item.size != nil, !item.isSymbolicLink,
        let stagedFileSize = try await commitProvider.stagedFileSize(at: temporaryDestination)
      {
        try TransferSizeVerifier.verify(
          itemName: item.name,
          expectedBytes: item.size,
          isSymbolicLink: item.isSymbolicLink,
          actualBytes: stagedFileSize)
      } else {
        try await TransferSizeVerifier.verify(
          itemName: item.name,
          expectedBytes: item.size,
          isSymbolicLink: item.isSymbolicLink,
          at: temporaryDestination,
          using: target)
      }
      try await commitProvider.commitTransferFile(
        from: temporaryDestination,
        to: destination,
        replacingExisting: replacingExisting)
    } catch {
      await commitProvider.discardTransferFile(at: temporaryDestination)
      throw error
    }
  }

  func copyTree(
    item: FileItem,
    from source: any FileBrowserProvider,
    toDirectory destinationDirectory: FileLocation,
    using target: any FileBrowserProvider,
    replacingExisting: Bool = false,
    mergingExistingDirectory: Bool = false,
    progress: @escaping @Sendable (FileTransferProgress) -> Void = { _ in },
    itemCompleted: TransferQueue.ItemCompletionReporter? = nil,
    reportRootItemCompletion: Bool = true
  ) async throws {
    if mergingExistingDirectory, item.isDirectory {
      let existingItem = try await completeContents(
        of: destinationDirectory, using: target
      ).first {
        $0.name == item.name
      }
      _ = try await copyTreeMergingExistingDirectory(
        item: item,
        existingItem: existingItem,
        from: source,
        toDirectory: destinationDirectory,
        using: target,
        progress: progress,
        itemCompleted: itemCompleted,
        reportsCurrentItemCompletion: reportRootItemCompletion)
      return
    }

    // 新規転送は従来どおり、ProviderのcreateDirectoryに命名衝突解決を委ねる。
    // 既存ツリーの再利用はbuildRetryAttempt起点のmergingExistingDirectoryだけで扱う。
    try Task.checkCancellation()
    guard let destination = destinationDirectory.appending(pathComponent: item.name) else {
      throw ProviderFileTransferServiceError.invalidDestination
    }

    guard item.isDirectory else {
      try await copy(
        item: item,
        from: source,
        to: destination,
        using: target,
        replacingExisting: replacingExisting,
        progress: progress)
      if reportRootItemCompletion, !item.isSymbolicLink, item.size != nil, let itemCompleted {
        await itemCompleted(TransferJob.Item(item))
      }
      return
    }

    guard let targetOperations = target as? any FileBrowserOperationProvider else {
      throw ProviderFileTransferServiceError.unsupportedDestination
    }
    try await targetOperations.createDirectory(named: item.name, in: destinationDirectory)
    let children = try await completeContents(of: item.location, using: source)
    for child in children {
      try Task.checkCancellation()
      try await copyTree(
        item: child,
        from: source,
        toDirectory: destination,
        using: target,
        replacingExisting: replacingExisting,
        mergingExistingDirectory: false,
        progress: progress,
        itemCompleted: itemCompleted,
        reportRootItemCompletion: true)
    }
  }

  /// 再開・再試行専用のツリーマージ。既存ディレクトリはその場所を再利用し、検証可能な
  /// 同名同サイズのリーフは再送しない。サイズ不一致はcopy()の一時名ステージングを通して
  /// 確定名へ置換するため、途中書き込みを可視名へ公開しない。
  private func copyTreeMergingExistingDirectory(
    item: FileItem,
    existingItem: FileItem?,
    from source: any FileBrowserProvider,
    toDirectory destinationDirectory: FileLocation,
    using target: any FileBrowserProvider,
    progress: @escaping @Sendable (FileTransferProgress) -> Void,
    itemCompleted: TransferQueue.ItemCompletionReporter?,
    reportsCurrentItemCompletion: Bool
  ) async throws -> Int64 {
    try Task.checkCancellation()
    guard let destination = destinationDirectory.appending(pathComponent: item.name) else {
      throw ProviderFileTransferServiceError.invalidDestination
    }

    if !item.isDirectory {
      if let existingItem {
        guard !existingItem.isDirectory else { throw CocoaError(.fileWriteFileExists) }
        let actualBytes: Int64?
        if let listedSize = existingItem.size {
          actualBytes = listedSize
        } else {
          actualBytes = try? await TransferSizeVerifier.actualSize(
            at: destination, using: target)
        }
        if !item.isSymbolicLink, let expectedBytes = item.size, actualBytes == expectedBytes {
          progress(
            FileTransferProgress(completedBytes: expectedBytes, totalBytes: expectedBytes))
          if reportsCurrentItemCompletion, let itemCompleted {
            await itemCompleted(TransferJob.Item(item))
          }
          return expectedBytes
        }
      }
      try await copy(
        item: item,
        from: source,
        to: destination,
        using: target,
        replacingExisting: existingItem != nil,
        progress: progress)
      if reportsCurrentItemCompletion, !item.isSymbolicLink, item.size != nil, let itemCompleted {
        await itemCompleted(TransferJob.Item(item))
      }
      return item.size ?? 0
    }

    guard let targetOperations = target as? any FileBrowserOperationProvider else {
      throw ProviderFileTransferServiceError.unsupportedDestination
    }
    if let existingItem {
      guard existingItem.isDirectory else { throw CocoaError(.fileWriteFileExists) }
    } else {
      try await targetOperations.createDirectory(named: item.name, in: destinationDirectory)
    }

    let existingChildren = try await completeContents(of: destination, using: target)
    let existingChildrenByName = Dictionary(
      existingChildren.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    let children = try await completeContents(of: item.location, using: source)
    var completedBytes: Int64 = 0
    for child in children {
      try Task.checkCancellation()
      let childBaseline = completedBytes
      let childBytes = try await copyTreeMergingExistingDirectory(
        item: child,
        existingItem: existingChildrenByName[child.name],
        from: source,
        toDirectory: destination,
        using: target,
        progress: { childProgress in
          progress(
            FileTransferProgress(
              completedBytes: childBaseline + childProgress.completedBytes,
              totalBytes: nil))
        },
        itemCompleted: itemCompleted,
        reportsCurrentItemCompletion: true)
      completedBytes += childBytes
    }
    return completedBytes
  }

  /// 転送では非表示項目も含める。Foundationが._側車を省く実ファイルシステムProviderは
  /// POSIX列挙で欠落分だけ補い、表示用の通常列挙は変更しない。
  private func completeContents(
    of location: FileLocation, using provider: any FileBrowserProvider
  ) async throws -> [FileItem] {
    let listed = try await provider.contents(of: location, includingHidden: true)
    guard let directoryURL = location.localURL, location.providerID == provider.id,
      provider is LocalFileProvider || provider is MountedVolumeProvider
    else { return listed }

    let worker = Task.detached(priority: .userInitiated) { () throws -> [FileItem] in
      let known = Set(listed.map { $0.url.standardizedFileURL })
      let local = LocalFileProvider()
      let mountedRoot = (provider as? MountedVolumeProvider)?.volumeURL
      return try FileSystemDirectoryEntries.children(of: directoryURL).compactMap { url in
        try Task.checkCancellation()
        guard !known.contains(url.standardizedFileURL) else { return nil }
        if let mountedRoot,
          !url.standardizedFileURL.pathComponents.starts(with: mountedRoot.pathComponents)
        {
          throw MountedVolumeProviderError.outsideVolume
        }
        return try local.item(
          at: url, providerID: provider.id, includingDetailMetadata: false)
      }
    }
    let missing = try await withTaskCancellationHandler {
      try await worker.value
    } onCancel: {
      worker.cancel()
    }
    return (listed + missing).sorted {
      $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }

  private func temporaryName(for destination: FileLocation) -> String {
    let name: String
    switch destination.path {
    case .local(let url): name = url.lastPathComponent
    case .remote(let path): name = path.split(separator: "/").last.map(String.init) ?? "transfer"
    }
    return ".\(name).pkpane-transfer-\(UUID().uuidString)"
  }
}
