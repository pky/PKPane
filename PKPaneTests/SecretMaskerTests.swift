import Foundation
import Testing

@testable import PKPane

struct SecretMaskerTests {
  @Test("注入したホームパスとUsers配下のパスをすべて短縮する")
  func masksHomeDirectories() {
    let input =
      "元: /Volumes/Test Home/alice/資料.txt、先: /Volumes/Test Home/alice/保存/結果.txt、別: /Users/bob/Desktop/a.txt"

    let masked = SecretMasker.maskHomeDirectory(
      input,
      homePath: "/Volumes/Test Home/alice")

    #expect(masked == "元: ~/資料.txt、先: ~/保存/結果.txt、別: ~/Desktop/a.txt")
    #expect(!masked.contains("alice"))
    #expect(!masked.contains("bob"))
  }

  @Test("URLのユーザー情報だけを除去する")
  func masksURLUserInfo() {
    #expect(
      SecretMasker.maskURLUserInfo("sftp://alice:secret@example.com/home")
        == "sftp://example.com/home")
    #expect(
      SecretMasker.maskURLUserInfo("smb://alice:p@ssw0rd@example.com/share")
        == "smb://example.com/share")
    #expect(
      SecretMasker.maskURLUserInfo("smb://alice@example.com/share")
        == "smb://example.com/share")
    #expect(
      SecretMasker.maskURLUserInfo("https://example.com/path")
        == "https://example.com/path")
    #expect(
      SecretMasker.maskURLUserInfo("sftp://example.com/foo@bar")
        == "sftp://example.com/foo@bar")
  }

  @Test("URL内のホームパスを短縮してもホストとの区切りを維持する")
  func preservesURLPathSeparatorWhenMaskingHome() {
    #expect(
      SecretMasker.maskForDisplay("sftp://alice@example.com/Users/alice/Documents")
        == "sftp://example.com/~/Documents")
  }

  @Test("ログではuser@host形式も置換する")
  func masksUserAndHostForLog() {
    #expect(
      SecretMasker.maskForLog("接続先 alice@example.com で失敗")
        == "接続先 ***@*** で失敗")
  }

  @Test("CloudStorageのサービスルート名を表示とログから除く")
  func masksCloudStorageAccountNames() {
    let homePath = NSHomeDirectory()
    let googlePath = "\(homePath)/Library/CloudStorage/GoogleDrive-user@example.com/報告.txt"
    let oneDrivePath = "\(homePath)/Library/CloudStorage/OneDrive - Alice Corp/設計.txt"

    let displayed = SecretMasker.maskForDisplay("失敗: \(googlePath)")
    let logged = SecretMasker.maskForLog("失敗: \(oneDrivePath)")

    #expect(displayed.contains("~/Library/CloudStorage/[cloud]/報告.txt"))
    #expect(logged.contains("~/Library/CloudStorage/[cloud]/設計.txt"))
    #expect(!displayed.contains("user@example.com"))
    #expect(!logged.contains("Alice Corp"))
    #expect(SecretMasker.maskForDisplay(displayed) == displayed)
  }

  @Test("秘密情報のない日本語は不変でマスクは冪等になる")
  func preservesSafeTextAndIsIdempotent() {
    let safeText = "ネットワーク接続を確認して、もう一度試してください。"
    let sensitiveText = "sftp://alice:secret@example.com/Users/alice/資料.txt"

    #expect(SecretMasker.maskForDisplay(safeText) == safeText)
    #expect(
      SecretMasker.maskForDisplay(SecretMasker.maskForDisplay(sensitiveText))
        == SecretMasker.maskForDisplay(sensitiveText))
    #expect(
      SecretMasker.maskForLog(SecretMasker.maskForLog("接続先 alice@example.com"))
        == SecretMasker.maskForLog("接続先 alice@example.com"))
  }
}
