import Testing

@testable import PKPane

struct ConnectionTestResultFormatterTests {
  @Test("経過時間をミリ秒へ丸めて「応答 Nms」の形式にする")
  func formatsMilliseconds() {
    #expect(ConnectionTestResultFormatter.successMessage(elapsed: .milliseconds(12)) == "応答 12ms")
    #expect(ConnectionTestResultFormatter.successMessage(elapsed: .seconds(1)) == "応答 1000ms")
  }

  @Test("端数のミリ秒は四捨五入する")
  func roundsFractionalMilliseconds() {
    #expect(ConnectionTestResultFormatter.milliseconds(.microseconds(12_600)) == 13)
    #expect(ConnectionTestResultFormatter.milliseconds(.microseconds(12_400)) == 12)
  }

  @Test("負の経過時間は0msにクランプする")
  func clampsNegativeDurationToZero() {
    #expect(ConnectionTestResultFormatter.milliseconds(.milliseconds(-5)) == 0)
  }

  @Test("ホップごとの応答時間を矢印で連結する")
  func hopMessageJoinsWithArrow() {
    let hops: [(name: String, elapsed: Duration)] = [
      ("gateway", .milliseconds(120)),
      ("files.example", .milliseconds(350)),
    ]

    #expect(
      ConnectionTestResultFormatter.hopSuccessMessage(hops)
        == "gateway 120ms → files.example 350ms")
  }

  @Test("1ホップの応答時間は既存の成功メッセージと同じ形式にする")
  func singleHopMessageMatchesSuccessMessage() {
    let elapsed = Duration.milliseconds(120)

    #expect(
      ConnectionTestResultFormatter.hopSuccessMessage([("files.example", elapsed)])
        == ConnectionTestResultFormatter.successMessage(elapsed: elapsed))
  }
}
