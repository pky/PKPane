import Citadel
import Foundation
import NIO

/// 接続失敗の原因分類。NASのマウント失敗・SFTPの接続失敗・接続テストの失敗のいずれにも
/// 同じ分類を適用し、原因と次のアクションを1行で提示する。
enum ConnectionFailureCategory: Equatable {
  case unreachable
  case authenticationFailed
  case hostKeyMismatch
  case shareNotFound
  case other
}

/// NSError/POSIX/NetFS/Citadel/NIOなど各層のエラー型を原因分類へ写像する純関数群。
/// Errorを直接組み立てるだけで検証できるため実ネットワークに依存せず単体テストできる。
enum ConnectionErrorClassifier {
  /// エラーを分類する。
  static func classify(_ error: Error) -> ConnectionFailureCategory {
    if let hopError = error as? SFTPHopConnectionError {
      return classify(hopError.underlying)
    }
    if let sftpError = error as? SFTPConnectionServiceError {
      switch sftpError {
      case .hostKeyRequiresApproval, .hostKeyChanged:
        return .hostKeyMismatch
      case .passwordNotFound, .hopAuthenticationFailed, .authenticationCancelled:
        return .authenticationFailed
      case .privateKeyNotFound, .unsupportedPrivateKey:
        return .other
      }
    }
    if case SSHClientError.allAuthenticationOptionsFailed = error {
      return .authenticationFailed
    }
    if error is NIOConnectionError {
      return .unreachable
    }
    if error is ConnectionReachabilityError {
      return .unreachable
    }
    if let mountError = error as? SMBMountError {
      switch mountError {
      case .connectionFailed(let status):
        return classify(posixStatus: status)
      case .disconnectionFailed:
        return .other
      }
    }
    if let posixError = error as? POSIXError {
      return classify(posixStatus: posixError.code.rawValue)
    }
    let nsError = error as NSError
    if nsError.domain == NSPOSIXErrorDomain {
      return classify(posixStatus: Int32(nsError.code))
    }
    return .other
  }

  /// 分類結果から表示する1行の案内文言を組み立てる。ホスト鍵不一致は既存のホスト鍵UIへの
  /// 誘導文言(SFTPConnectionServiceErrorのerrorDescription)をそのまま使い、既存フローを
  /// 変えない。それ以外は分類済みの定型文、otherは元のエラーメッセージへ再試行の案内を付け足す。
  static func guidanceMessage(for error: Error) -> String {
    if isHopAuthenticationFailed(error) {
      return SecretMasker.maskForDisplay(error.localizedDescription)
    }
    return switch classify(error) {
    case .unreachable:
      "サーバーに到達できません。ホスト名とネットワーク接続を確認してください。"
    case .authenticationFailed:
      "認証に失敗しました。ユーザー名とパスワードを確認してください。"
    case .hostKeyMismatch:
      SecretMasker.maskForDisplay(error.localizedDescription)
    case .shareNotFound:
      "共有が見つかりません。共有名を確認してください。"
    case .other:
      "\(SecretMasker.maskForDisplay(error.localizedDescription))時間をおいて再試行してください。"
    }
  }

  private static func isHopAuthenticationFailed(_ error: Error) -> Bool {
    let underlying = (error as? SFTPHopConnectionError)?.underlying ?? error
    if case SFTPConnectionServiceError.hopAuthenticationFailed = underlying { return true }
    return false
  }

  private static func classify(posixStatus status: Int32) -> ConnectionFailureCategory {
    guard let code = POSIXErrorCode(rawValue: status) else { return .other }
    switch code {
    case .ETIMEDOUT, .ECONNREFUSED, .EHOSTUNREACH, .ENETUNREACH, .EHOSTDOWN:
      return .unreachable
    case .EAUTH, .EACCES, .EPERM:
      return .authenticationFailed
    case .ENOENT:
      return .shareNotFound
    default:
      return .other
    }
  }
}
