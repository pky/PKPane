import Citadel
import Darwin
import Foundation
import Testing

@testable import PKPane

// NIOConnectionError(SFTP接続の到達不能・タイムアウト時に実際にスローされる型)は
// fileprivate initのためテストから直接組み立てられない。到達不能分類はNASの
// ConnectionReachabilityErrorとSMBMountErrorのPOSIXコードで検証する。分類器側の
// `error is NIOConnectionError`分岐は実接続でのみ経路が通る。
struct ConnectionErrorClassifierTests {
  @Test("到達不能・タイムアウトはunreachableへ分類する")
  func classifiesUnreachable() {
    #expect(
      ConnectionErrorClassifier.classify(ConnectionReachabilityError.timedOut) == .unreachable)
    #expect(
      ConnectionErrorClassifier.classify(ConnectionReachabilityError.unreachable("nas.invalid"))
        == .unreachable)
    #expect(
      ConnectionErrorClassifier.classify(SMBMountError.connectionFailed(ETIMEDOUT)) == .unreachable)
    #expect(
      ConnectionErrorClassifier.classify(SMBMountError.connectionFailed(EHOSTUNREACH))
        == .unreachable)
  }

  @Test("認証失敗はauthenticationFailedへ分類する")
  func classifiesAuthenticationFailure() {
    #expect(
      ConnectionErrorClassifier.classify(SSHClientError.allAuthenticationOptionsFailed)
        == .authenticationFailed)
    #expect(
      ConnectionErrorClassifier.classify(SFTPConnectionServiceError.passwordNotFound)
        == .authenticationFailed)
    #expect(
      ConnectionErrorClassifier.classify(SMBMountError.connectionFailed(EAUTH))
        == .authenticationFailed)
  }

  @Test("候補が尽きたホップの認証エラーは認証失敗に分類する")
  func hopAuthenticationFailedIsClassifiedAsAuthenticationFailure() {
    let hop = SFTPHopIdentity(host: "bastion", port: 2222, username: "ops")
    let error = SFTPConnectionServiceError.hopAuthenticationFailed(hop, reason: nil)

    #expect(ConnectionErrorClassifier.classify(error) == .authenticationFailed)
    #expect(!TransferReconnectionPolicy.isEligibleForAutoReconnect(error))
  }

  @Test("B1: ホップ認証失敗は両方の原因を伝える文言を返す")
  func hopAuthenticationFailedGuidesWithBothCauses() {
    let hop = SFTPHopIdentity(host: "bastion", port: 2222, username: "ops")
    let error = SFTPConnectionServiceError.hopAuthenticationFailed(hop, reason: nil)

    #expect(ConnectionErrorClassifier.classify(error) == .authenticationFailed)
    let message = ConnectionErrorClassifier.guidanceMessage(for: error)
    #expect(message.contains("password 認証を受け付けていません"))
    #expect(message.contains(hop.host))
    #expect(!message.contains("ユーザー名とパスワードを確認"))
  }

  @Test("B2: ホップ通信エラーで包まれた認証失敗も同じ案内になる")
  func wrappedHopAuthenticationFailedGuidesWithBothCauses() {
    let hop = SFTPHopIdentity(host: "bastion", port: 2222, username: "ops")
    let error = SFTPHopConnectionError(
      hop: hop,
      underlying: SFTPConnectionServiceError.hopAuthenticationFailed(hop, reason: nil))

    let message = ConnectionErrorClassifier.guidanceMessage(for: error)
    #expect(message.contains("password 認証を受け付けていません"))
    #expect(message.contains(hop.host))
    #expect(!message.contains("ユーザー名とパスワードを確認"))
  }

  @Test("B3: パスワード未保存の案内は従来の定型文のまま")
  func passwordNotFoundKeepsFixedGuidance() {
    #expect(
      ConnectionErrorClassifier.guidanceMessage(
        for: SFTPConnectionServiceError.passwordNotFound)
        == "認証に失敗しました。ユーザー名とパスワードを確認してください。")
  }

  @Test("ホスト鍵不一致はhostKeyMismatchへ分類し既存の文言を維持する")
  func classifiesHostKeyMismatch() {
    let requiresApproval = SFTPConnectionServiceError.hostKeyRequiresApproval("ssh-ed25519 AAAA")
    let changed = SFTPConnectionServiceError.hostKeyChanged("ssh-ed25519 AAAA")

    #expect(ConnectionErrorClassifier.classify(requiresApproval) == .hostKeyMismatch)
    #expect(ConnectionErrorClassifier.classify(changed) == .hostKeyMismatch)
    #expect(
      ConnectionErrorClassifier.guidanceMessage(for: requiresApproval)
        == requiresApproval.localizedDescription)
    #expect(
      ConnectionErrorClassifier.guidanceMessage(for: changed) == changed.localizedDescription)
  }

  @Test("共有が見つからないエラーはshareNotFoundへ分類する")
  func classifiesShareNotFound() {
    #expect(
      ConnectionErrorClassifier.classify(SMBMountError.connectionFailed(ENOENT)) == .shareNotFound)
    #expect(
      ConnectionErrorClassifier.guidanceMessage(for: SMBMountError.connectionFailed(ENOENT))
        == "共有が見つかりません。共有名を確認してください。")
  }

  @Test("分類できないエラーはotherへ分類し再試行の案内を付け足す")
  func classifiesOtherAndAppendsRetryGuidance() {
    let error = SMBMountError.disconnectionFailed
    #expect(ConnectionErrorClassifier.classify(error) == .other)
    #expect(
      ConnectionErrorClassifier.guidanceMessage(for: error)
        == "\(error.localizedDescription)時間をおいて再試行してください。")
  }

  @Test("到達不能・認証失敗の案内文言は固定の1行になる")
  func guidanceMessagesMatchFixedCopy() {
    #expect(
      ConnectionErrorClassifier.guidanceMessage(for: ConnectionReachabilityError.timedOut)
        == "サーバーに到達できません。ホスト名とネットワーク接続を確認してください。")
    #expect(
      ConnectionErrorClassifier.guidanceMessage(
        for: SFTPConnectionServiceError.passwordNotFound)
        == "認証に失敗しました。ユーザー名とパスワードを確認してください。")
  }

  @Test("分類不能エラーの案内から秘密情報を除去する")
  func masksOtherErrorGuidance() {
    let error = NSError(
      domain: "ConnectionFixture",
      code: 1,
      userInfo: [
        NSLocalizedDescriptionKey:
          "sftp://alice:secret@example.com/Users/alice/Documents への接続に失敗しました。"
      ])

    let message = ConnectionErrorClassifier.guidanceMessage(for: error)

    #expect(
      message
        == "sftp://example.com/~/Documents への接続に失敗しました。時間をおいて再試行してください。")
    #expect(!message.contains("alice"))
    #expect(!message.contains("secret"))
  }
}
