import Foundation

/// 再接続では回復しないエラーであることを示すマーカーです。自動再接続(P1-3)は既定で
/// 「再接続すれば直るかもしれない」楽観側に倒すため、これに適合しない限り再試行対象に
/// 含めます。プロバイダ固有の判断(資格情報エラーなど)はこのマーカーへの適合という形で
/// 各Infrastructure層(SFTP等)側が示し、Presentation層(FileBrowserSession)はプロバイダ
/// 実装を知らずに判定できます。
protocol ReconnectFutileError: Error {}

/// このProviderが関わる転送だけが自動再接続(P1-3)の対象になることを示すマーカーです。
/// P1-3はSFTP(直接クライアント)限定のスコープ決定のため、ローカル/マウント経由NASの
/// 転送では、エラー種別に関わらず自動リトライを行わず既存の即時手動リトライ導線のみを
/// 使う。source/destinationのどちらか一方でもこれに適合すれば対象とする(クロス
/// プロバイダ転送でSFTP側が原因の失敗を取りこぼさないため)。
protocol AutoReconnectEligibleProvider: FileBrowserProvider {}

/// 転送・閲覧の自動再接続(P1-3)が「このエラーを自動リトライの対象にしてよいか」を
/// 判定する共通ロジックです。
enum TransferReconnectionPolicy {
  /// - CancellationError: ユーザー操作による中断のため対象外。呼び出し元(TransferQueue)は
  ///   通常CancellationErrorを.cancelled状態として扱い、この関数を通る前に除外される設計
  ///   だが、直接呼ばれた場合の安全のため明示的にも判定する。
  /// - ReconnectFutileError: 資格情報・ホスト鍵未承認などプロバイダが「再接続しても同じ
  ///   理由で必ず失敗する」と判断したエラーのため対象外。
  /// - それ以外: 生のネットワーク層エラーを含め、一時的な瞬断やサーバー側の過負荷など
  ///   再接続で直る可能性を否定できないため対象に含める(SFTPTransferStallErrorも含む。
  ///   ストールガードが検知した時点で接続は既にclose済みのため、素の切断と区別する
  ///   意味が無く、再接続すれば直る可能性がある点は他の切断と同じ)。
  static func isEligibleForAutoReconnect(_ error: Error) -> Bool {
    if error is CancellationError { return false }
    if error is ReconnectFutileError { return false }
    return true
  }

  /// source/destinationのどちらかがAutoReconnectEligibleProviderに適合していれば、
  /// この転送は自動再接続の対象とする。
  static func isEligible(
    sourceProvider: any FileBrowserProvider,
    destinationProvider: any FileBrowserProvider
  ) -> Bool {
    sourceProvider is any AutoReconnectEligibleProvider
      || destinationProvider is any AutoReconnectEligibleProvider
  }
}
