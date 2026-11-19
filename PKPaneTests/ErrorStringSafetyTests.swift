import Foundation
import Testing

@testable import PKPane

struct ErrorStringSafetyTests {
  @Test("SFTP接続エラーの文字列化でホスト鍵を伏せる")
  func sftpConnectionErrorDescriptionHidesHostKey() {
    let publicKey = "ssh-ed25519 SECRET-HOST-KEY"
    let approval = SFTPConnectionServiceError.hostKeyRequiresApproval(publicKey)
    let changed = SFTPConnectionServiceError.hostKeyChanged(publicKey)

    #expect(String(describing: approval) == "hostKeyRequiresApproval")
    #expect(String(describing: changed) == "hostKeyChanged")
    #expect(String(reflecting: approval) == "hostKeyRequiresApproval")
    #expect(String(reflecting: changed) == "hostKeyChanged")
    #expect(!"\(approval)".contains(publicKey))
    #expect(!"\(changed)".contains(publicKey))
    #expect(!String(reflecting: approval).contains(publicKey))
    #expect(!String(reflecting: changed).contains(publicKey))
  }

  @Test("内部実行エラーは日本語の定型文を返す")
  func internalErrorsHaveLocalizedDescriptions() {
    #expect(
      SFTPPipelineInvariantError().localizedDescription
        == "SFTP転送の内部状態が不整合です。")
  }
}
