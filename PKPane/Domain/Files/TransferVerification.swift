import Foundation

/// 転送検証(sourceの期待値とdestinationの実測値の不一致)を表す、リトライ可能なエラー。
/// makeTransferExecution/ProviderFileTransferServiceの既存の失敗処理(TransferJobPartialFailure
/// への集約→ジョブfailed→canRetryLastTransfer)にそのまま乗るよう、通常のErrorとして投げる。
///
/// 自動再接続(P1-3)のReconnectFutileErrorにも適合させている。検証失敗は「書き込んだ内容が
/// 期待と一致しない」という確定した事実であり、接続断の兆候ではないため、自動リトライで
/// 何度も無言で再送するより、既存どおり手動リトライ(retryLastTransfer)へ委ねて
/// ユーザーに気づける形で留めるほうが安全と判断した。
enum TransferVerificationError: Error, LocalizedError, Sendable, ReconnectFutileError {
  case sizeMismatch(itemName: String, expectedBytes: Int64, actualBytes: Int64)

  var errorDescription: String? {
    switch self {
    case .sizeMismatch(let itemName, let expectedBytes, let actualBytes):
      "\(itemName)の転送検証に失敗しました(期待サイズ\(expectedBytes)バイト、実サイズ\(actualBytes)バイト)。"
    }
  }
}

/// 転送完了直後にsourceの期待サイズとdestinationの実サイズを比較する、常時ONの軽量検証です。
/// destination側の実サイズ取得手段を持たないProviderでは検証をスキップします。
/// 対応Providerが増えるにつれ自然にカバレッジが広がる設計です。
enum TransferSizeVerifier {
  static func verify(
    itemName: String,
    expectedBytes: Int64?,
    isSymbolicLink: Bool,
    at location: FileLocation,
    using provider: any FileBrowserProvider
  ) async throws {
    guard let expectedBytes else { return }
    // シンボリックリンクはitem.sizeがリンク自体(リンク先パス文字列長など)を指す一方、
    // 実際に複製されるのもリンクそのもの(実体は複製されない)なので、意味のある期待値・
    // 実測値の対応が取れない。誤検知を避けるため対象外にする。
    guard !isSymbolicLink else { return }
    guard let actualBytes = try await actualSize(at: location, using: provider) else { return }
    try verify(
      itemName: itemName,
      expectedBytes: expectedBytes,
      isSymbolicLink: isSymbolicLink,
      actualBytes: actualBytes)
  }

  static func verify(
    itemName: String,
    expectedBytes: Int64?,
    isSymbolicLink: Bool,
    actualBytes: Int64
  ) throws {
    guard let expectedBytes, !isSymbolicLink else { return }
    guard actualBytes == expectedBytes else {
      throw TransferVerificationError.sizeMismatch(
        itemName: itemName, expectedBytes: expectedBytes, actualBytes: actualBytes)
    }
  }

  /// destinationの実サイズを軽量経路優先で取得する。取得手段を持たないProviderではnil。
  /// verify()に加え、転送レジューム(P1-2)の「宛先が前回完了時のまま安全に一致しているか」
  /// 再確認からも共有して使う。
  static func actualSize(
    at location: FileLocation,
    using provider: any FileBrowserProvider
  ) async throws -> Int64? {
    if let sizeProvider = provider as? any FileBrowserItemSizeProvider {
      // 親ディレクトリの全列挙やフルメタデータ取得より安価な軽量経路(例: SFTPの単一stat)。
      return try await sizeProvider.itemSize(at: location)
    } else if let detailProvider = provider as? any FileBrowserItemDetailProvider {
      return try await detailProvider.detailedItem(at: location).size
    } else {
      return nil
    }
  }
}

/// .contentHash強度の計算フックです。現状はどの呼び出し元からも接続されていない基盤のみで、
/// 既定の検証フロー(TransferSizeVerifier)には接続しません。SFTPはリモート側ハッシュ計算が
/// 標準でなくダウンロード相当のコストがかかるため、この段階では実装対象をローカルに限ります。
protocol FileContentHashProvider: FileBrowserProvider {
  func contentHash(at location: FileLocation) async throws -> Data
}
