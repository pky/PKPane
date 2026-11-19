import Foundation
import Testing

@testable import PKPane

struct FTPConnectionTargetTests {
  @Test("FTPS接続先を正規化する")
  func normalizesTarget() throws {
    let target = try FTPConnectionTarget(
      host: " ftp.example.com ",
      username: " tester ",
      initialDirectory: " /incoming ")

    #expect(target.host == "ftp.example.com")
    #expect(target.port == 21)
    #expect(target.username == "tester")
    #expect(target.initialDirectory == "/incoming")
    #expect(target.security == .explicitTLS)
  }

  @Test("不正な接続先とコマンド注入文字を拒否する")
  func rejectsInvalidTarget() {
    #expect(throws: FTPConnectionTargetError.invalidHost) {
      try FTPConnectionTarget(host: "ftp://example.com", username: "tester")
    }
    #expect(throws: FTPConnectionTargetError.invalidPort) {
      try FTPConnectionTarget(host: "example.com", port: 0, username: "tester")
    }
    #expect(throws: FTPConnectionTargetError.invalidUsername) {
      try FTPConnectionTarget(host: "example.com", username: "tester\r\nPASS injected")
    }
    #expect(throws: FTPConnectionTargetError.invalidInitialDirectory) {
      try FTPConnectionTarget(
        host: "example.com", username: "tester", initialDirectory: "/safe\r\nDELE /other")
    }
  }

  @Test("平文FTPとFTPSを別プロフィールとして扱う")
  func distinguishesSecurityModes() throws {
    let plain = try FTPConnectionTarget(
      host: "example.com", username: "tester", security: .plain)
    let secure = try FTPConnectionTarget(
      host: "example.com", username: "tester", security: .explicitTLS)

    #expect(plain != secure)
    #expect(plain.security.displayName == "FTP（暗号化なし）")
    #expect(plain.security.warningMessage != nil)
    #expect(secure.security.displayName == "FTPS（明示的TLS）")
    #expect(secure.security.warningMessage == nil)
  }
}
