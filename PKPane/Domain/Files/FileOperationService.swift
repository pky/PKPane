import Foundation

/// 同一ボリューム判定のみを残したファイルシステムユーティリティ。
/// クロスプロバイダ転送の高速パス判定(LocalSameVolumeTransfer)やローカルコピー
/// (CancellableFileCopier、LocalFileProvider)が使う。旧ローカル2ペインブラウザ専用の
/// プラン実行エンジン(コピー・移動・削除・リネーム・複製・Undo)はM2のレガシー削除で削除済み。
struct SystemFileOperationFileSystem {
  func areOnSameVolume(_ sourceURL: URL, _ destinationDirectoryURL: URL) throws -> Bool {
    var uncachedSourceURL = sourceURL
    var uncachedDestinationURL = destinationDirectoryURL
    uncachedSourceURL.removeAllCachedResourceValues()
    uncachedDestinationURL.removeAllCachedResourceValues()
    let sourceIdentifier = try uncachedSourceURL.resourceValues(forKeys: [.volumeIdentifierKey])
      .volumeIdentifier
    let destinationIdentifier =
      try uncachedDestinationURL.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
    guard let sourceIdentifier, let destinationIdentifier else { return false }
    return String(reflecting: sourceIdentifier) == String(reflecting: destinationIdentifier)
  }
}
