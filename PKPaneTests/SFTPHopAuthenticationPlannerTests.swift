import Foundation
import Testing

@testable import PKPane

struct SFTPHopAuthenticationPlannerTests {
  @Test("認証候補は鍵と保存パスワードと入力要求の順に並ぶ")
  func planOrdersKeyThenStoredPasswordThenPrompt() {
    let url = URL(fileURLWithPath: "/k")

    #expect(
      SFTPHopAuthenticationPlanner.plan(
        privateKeyURL: url, storedPassword: "s", intent: .userInitiated)
        == [.privateKey(url), .storedPassword("s"), .promptPassword])
  }

  @Test("バックグラウンド接続ではパスワード入力を要求しない")
  func backgroundIntentNeverPrompts() {
    #expect(
      SFTPHopAuthenticationPlanner.plan(
        privateKeyURL: nil, storedPassword: nil, intent: .background) == [])
    #expect(
      SFTPHopAuthenticationPlanner.plan(
        privateKeyURL: nil, storedPassword: "s", intent: .background) == [.storedPassword("s")])
  }
}
