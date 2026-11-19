import Testing

@testable import PKPane

struct NameMatcherTests {
  @Test("正規表現は部分一致しアンカーを尊重する")
  func matchesSubstringAndAnchors() {
    let substring = NameMatcher(pattern: "report-[0-9]+", mode: .regex)
    let anchored = NameMatcher(pattern: "^report-[0-9]+$", mode: .regex)

    #expect(substring.matches("old-report-42.txt"))
    #expect(!anchored.matches("old-report-42.txt"))
    #expect(anchored.matches("report-42"))
  }

  @Test("日本語と絵文字をUTF-16レンジで照合する")
  func matchesJapaneseAndEmoji() {
    let matcher = NameMatcher(pattern: "請求書-😀+\\.pdf", mode: .regex)

    #expect(matcher.matches("旧_請求書-😀😀.pdf"))
    #expect(!matcher.matches("請求書-😃.pdf"))
  }

  @Test("正規表現は既定で大文字小文字を区別しない")
  func ignoresCaseByDefault() {
    #expect(NameMatcher(pattern: "REPORT", mode: .regex).matches("report.txt"))
    #expect(
      !NameMatcher(
        pattern: "REPORT",
        mode: .regex,
        isCaseSensitive: true
      ).matches("report.txt"))
  }

  @Test("無効な正規表現は不正状態を公開し何にも一致しない")
  func rejectsInvalidExpression() {
    let matcher = NameMatcher(pattern: "(", mode: .regex)

    #expect(!matcher.isValid)
    #expect(!matcher.matches("file.txt"))
  }
}
