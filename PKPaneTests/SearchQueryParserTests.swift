import Testing

@testable import PKPane

struct SearchQueryParserTests {
  @Test("tag:トークンと名前語を分離する")
  func separatesTagAndNameTerms() {
    #expect(
      SearchQueryParser.parse("tag:仕事 報告書")
        == ParsedSearchQuery(nameText: "報告書", tagTerms: ["仕事"], contentTerms: []))
  }

  @Test("複数のtag:トークンと名前語を保持する")
  func preservesMultipleTerms() {
    #expect(
      SearchQueryParser.parse("四半期 tag:重要 報告書 tag:確認済み")
        == ParsedSearchQuery(
          nameText: "四半期 報告書",
          tagTerms: ["重要", "確認済み"],
          contentTerms: []))
  }

  @Test("tag:だけの検索は名前条件を空にする")
  func parsesTagOnlyQuery() {
    #expect(
      SearchQueryParser.parse("tag:赤")
        == ParsedSearchQuery(nameText: "", tagTerms: ["赤"], contentTerms: []))
  }

  @Test("tag:がなければ従来の名前文字列を保つ")
  func preservesNameOnlyQuery() {
    #expect(
      SearchQueryParser.parse("  月次   報告書  ")
        == ParsedSearchQuery(nameText: "月次 報告書", tagTerms: [], contentTerms: []))
  }

  @Test("tag:接頭辞は大文字小文字を区別しない")
  func parsesCaseInsensitivePrefix() {
    #expect(
      SearchQueryParser.parse("TAG:重要 report")
        == ParsedSearchQuery(nameText: "report", tagTerms: ["重要"], contentTerms: []))
  }

  @Test("空のtag:は名前語として扱う")
  func preservesEmptyTagTokenAsName() {
    #expect(
      SearchQueryParser.parse("tag: report")
        == ParsedSearchQuery(nameText: "tag: report", tagTerms: [], contentTerms: []))
  }

  @Test("content:トークンと名前語を分離する")
  func separatesContentAndNameTerms() {
    #expect(
      SearchQueryParser.parse("content:売上 月次報告書")
        == ParsedSearchQuery(
          nameText: "月次報告書",
          tagTerms: [],
          contentTerms: ["売上"]))
  }

  @Test("content:とtag:を同時に抽出する")
  func separatesContentTagAndNameTerms() {
    let parsed = SearchQueryParser.parse("報告書 tag:仕事 content:四半期 content:売上")

    #expect(
      parsed
        == ParsedSearchQuery(
          nameText: "報告書",
          tagTerms: ["仕事"],
          contentTerms: ["四半期", "売上"]))
    #expect(parsed.textExcludingContentTerms == "報告書 tag:仕事")
  }

  @Test("content:だけの検索は名前条件を空にする")
  func parsesContentOnlyQuery() {
    #expect(
      SearchQueryParser.parse("content:日本語")
        == ParsedSearchQuery(
          nameText: "",
          tagTerms: [],
          contentTerms: ["日本語"]))
  }

  @Test("空のcontent:は名前語として扱う")
  func preservesEmptyContentTokenAsName() {
    #expect(
      SearchQueryParser.parse("content: report")
        == ParsedSearchQuery(
          nameText: "content: report",
          tagTerms: [],
          contentTerms: []))
  }
}
