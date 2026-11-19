import Testing

@testable import PKPane

struct QuickSelectPatternTests {
  @Test("アスタリスクと疑問符をワイルドカードとして解釈する")
  func matchesWildcards() {
    let zipPattern = QuickSelectPattern("*.zip", isCaseSensitive: false)
    let numberedPattern = QuickSelectPattern("report-?.txt", isCaseSensitive: false)

    #expect(zipPattern.matches("archive.zip"))
    #expect(!zipPattern.matches("archive.zip.backup"))
    #expect(numberedPattern.matches("report-1.txt"))
    #expect(!numberedPattern.matches("report-10.txt"))
  }

  @Test("ワイルドカードなしの入力は部分一致する")
  func matchesSubstring() {
    let pattern = QuickSelectPattern("zip", isCaseSensitive: false)

    #expect(pattern.matches("archive.zip"))
    #expect(pattern.matches("zip-folder"))
    #expect(!pattern.matches("archive.txt"))
  }

  @Test("大文字小文字の区別を切り替えられる")
  func respectsCaseSensitivity() {
    #expect(QuickSelectPattern("*.ZIP", isCaseSensitive: false).matches("archive.zip"))
    #expect(!QuickSelectPattern("*.ZIP", isCaseSensitive: true).matches("archive.zip"))
    #expect(QuickSelectPattern("ZIP", isCaseSensitive: true).matches("archive.ZIP"))
  }

  @Test("日本語の名前を照合できる")
  func matchesJapaneseName() {
    let pattern = QuickSelectPattern("請求書-??.pdf", isCaseSensitive: false)

    #expect(pattern.matches("請求書-夏季.pdf"))
    #expect(!pattern.matches("見積書-夏季.pdf"))
  }

  @Test("空パターンは何にも一致しない")
  func emptyPatternMatchesNothing() {
    let pattern = QuickSelectPattern("", isCaseSensitive: false)

    #expect(!pattern.matches("file.txt"))
    #expect(!pattern.matches(""))
  }

  @Test("正規表現モードは入力を部分一致の正規表現として解釈する")
  func matchesRegularExpression() {
    let pattern = QuickSelectPattern(
      "請求書-[0-9]+\\.pdf",
      isCaseSensitive: false,
      interpretsAsRegex: true)

    #expect(pattern.isValid)
    #expect(pattern.matches("旧_請求書-42.pdf.backup"))
    #expect(!pattern.matches("請求書-夏.pdf"))
  }

  @Test("正規表現モードでも大文字小文字の設定とアンカーが効く")
  func regularExpressionRespectsCaseAndAnchors() {
    #expect(
      QuickSelectPattern(
        "^REPORT\\.TXT$", isCaseSensitive: false, interpretsAsRegex: true
      ).matches("report.txt"))
    #expect(
      !QuickSelectPattern(
        "^REPORT\\.TXT$", isCaseSensitive: true, interpretsAsRegex: true
      ).matches("report.txt"))
    #expect(
      !QuickSelectPattern(
        "^REPORT\\.TXT$", isCaseSensitive: false, interpretsAsRegex: true
      ).matches("old-report.txt"))
  }

  @Test("無効な正規表現は不正状態を公開し何にも一致しない")
  func invalidRegularExpressionMatchesNothing() {
    let pattern = QuickSelectPattern(
      "[", isCaseSensitive: false, interpretsAsRegex: true)

    #expect(!pattern.isValid)
    #expect(!pattern.matches("file.txt"))
  }
}
