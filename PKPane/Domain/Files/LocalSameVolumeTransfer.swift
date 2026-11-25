import Foundation

/// クロスプロバイダ転送でも実体がローカル同一ボリュームの移動ならrename一発で完了させる高速パス。
enum LocalSameVolumeTransfer {
  static func canMove(_ item: FileItem, toDirectory destination: FileLocation) -> Bool {
    guard let sourceURL = item.location.localURL,
      let destinationDirectoryURL = destination.localURL
    else { return false }
    let sameVolume = try? SystemFileOperationFileSystem().areOnSameVolume(
      sourceURL, destinationDirectoryURL)
    return sameVolume == true
  }

  static func move(
    _ item: FileItem, toDirectory destination: FileLocation, replacingExisting: Bool = false,
    destinationName: String? = nil
  ) throws {
    let name = destinationName ?? item.name
    guard let sourceURL = item.location.localURL,
      !name.utf8.contains(0),
      let destinationURL = destination.appending(pathComponent: name)?.localURL
    else { throw CocoaError(.fileNoSuchFile) }
    if try LocalTransferLocationValidator.validate(source: sourceURL, destination: destinationURL)
      == .sameItem
    {
      return
    }
    if FileManager.default.fileExists(atPath: destinationURL.path) {
      guard replacingExisting else { throw CocoaError(.fileWriteFileExists) }
      // 先に宛先を削除せず、移動に失敗しても既存内容を保持する。
      _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: sourceURL)
      return
    }
    try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
  }
}

enum TransferQuietJobPolicy {
  static func isLocalSameVolumeMove(_ job: TransferJob) -> Bool {
    guard job.kind == .move, !job.items.isEmpty,
      let destinationURL = job.destination.localURL,
      let destinationIdentifier = volumeIdentifier(for: destinationURL)
    else { return false }

    var checkedSourcePaths: Set<String> = []
    for item in job.items {
      guard let sourceURL = item.location.localURL else { return false }
      // 移動が完了してから判定する場合も、元の親フォルダで照会できる。
      let sourceDirectory = sourceURL.deletingLastPathComponent()
      if checkedSourcePaths.insert(sourceDirectory.path).inserted {
        guard volumeIdentifier(for: sourceDirectory) == destinationIdentifier else { return false }
      }
    }
    return true
  }

  private static func volumeIdentifier(for url: URL) -> String? {
    var uncachedURL = url
    uncachedURL.removeAllCachedResourceValues()
    let values = try? uncachedURL.resourceValues(forKeys: [.volumeIdentifierKey])
    guard let identifier = values?.volumeIdentifier else { return nil }
    return String(reflecting: identifier)
  }
}

/// stagingや削除より前に、元と宛先の実体関係をローカル全経路で確認する。
enum LocalTransferLocationValidator {
  enum Relation: Equatable {
    case sameItem
    case separate
  }

  static func validate(source: URL, destination: URL) throws -> Relation {
    let sourcePath = source.standardizedFileURL.resolvingSymlinksInPath().path
    let destinationPath = destination.standardizedFileURL.resolvingSymlinksInPath().path
    if sourcePath == destinationPath {
      guard FileManager.default.fileExists(atPath: source.path) else {
        throw CocoaError(.fileNoSuchFile)
      }
      return .sameItem
    }
    // 祖先の置換は元を巻き込み、子孫へのコピーは元のツリーへ書き込む。
    // パス要素の境界を含めて双方の包含を拒否し、通常の別名転送は維持する。
    guard !sourcePath.hasPrefix(destinationPath + "/"),
      !destinationPath.hasPrefix(sourcePath + "/")
    else { throw ProviderFileTransferServiceError.invalidDestination }
    return .separate
  }
}
