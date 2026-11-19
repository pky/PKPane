import Foundation
import Testing

@testable import PKPane

struct AppLogTests {
  @Test("ログ出力前にホームパスとURL資格情報と接続先をマスクする")
  func sanitizesMessages() {
    let message =
      "\(NSHomeDirectory())/Documents から sftp://alice:secret@example.com/path へ接続 alice@example.com"

    let sanitized = AppLog.sanitizedMessage(message)

    #expect(sanitized.contains("~/Documents"))
    #expect(sanitized.contains("sftp://example.com/path"))
    #expect(sanitized.contains("***@***"))
    #expect(!sanitized.contains("alice"))
    #expect(!sanitized.contains("secret"))
  }
}
