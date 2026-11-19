import Foundation
import Testing

@testable import PKPane

struct BatchRenameTests {
  @Test("通常置換・前置・後置・連番を指定順に組み合わせる")
  func combinesPlainReplacementAffixesAndSequenceInOrder() {
    let items = [makeItem("draft-one.txt"), makeItem("draft-two.txt")]
    let rule = BatchRenameRule(
      replacementMode: .plain,
      searchText: "draft",
      replacementText: "report",
      prefix: "final-",
      suffix: "-approved",
      sequenceStart: 7,
      sequencePadding: 3
    )

    let previews = BatchRenamePreviewBuilder.make(items: items, rule: rule)

    #expect(
      previews.map(\.renamedName) == [
        "final-report-one-approved007.txt",
        "final-report-two-approved008.txt",
      ])
  }

  @Test("通常置換はファイル名全体の全出現を置き換える")
  func replacesAllPlainOccurrencesIncludingExtension() throws {
    let item = makeItem("TXT-TXT.TXT")
    let rule = BatchRenameRule(
      replacementMode: .plain,
      searchText: "TXT",
      replacementText: "txt"
    )

    let previews = BatchRenamePreviewBuilder.make(items: [item], rule: rule)
    try #require(previews.count == 1)
    let preview = previews[0]

    #expect(preview.renamedName == "txt-txt.txt")
  }

  @Test("正規表現のキャプチャグループを並べ替える")
  func reordersRegexCaptureGroups() throws {
    let item = makeItem("2026-08-請求書.pdf")
    let rule = BatchRenameRule(
      replacementMode: .regex,
      searchText: #"^(\d{4})-(\d{2})-(.+)(\.pdf)$"#,
      replacementText: "$3-$2-$1$4"
    )

    let previews = BatchRenamePreviewBuilder.make(items: [item], rule: rule)
    try #require(previews.count == 1)
    let preview = previews[0]

    #expect(preview.renamedName == "請求書-08-2026.pdf")
  }

  @Test("正規表現は日本語ファイル名の全マッチを置き換える")
  func replacesAllRegexMatchesInJapaneseName() throws {
    let item = makeItem("仮_請求書_仮.txt")
    let rule = BatchRenameRule(
      replacementMode: .regex,
      searchText: "仮",
      replacementText: "確定"
    )

    let previews = BatchRenamePreviewBuilder.make(items: [item], rule: rule)
    try #require(previews.count == 1)
    let preview = previews[0]

    #expect(preview.renamedName == "確定_請求書_確定.txt")
  }

  @Test("絵文字ファイル名を正しいUTF-16範囲で置換してキャプチャを参照する")
  func replacesEmojiNameUsingCaptureGroups() throws {
    let item = makeItem("🎉report🎉.txt")
    let rule = BatchRenameRule(
      replacementMode: .regex,
      searchText: #"^(🎉)(report)(🎉)(\.txt)$"#,
      replacementText: "$2-$1$3$4"
    )

    let previews = BatchRenamePreviewBuilder.make(items: [item], rule: rule)
    try #require(previews.count == 1)
    let preview = previews[0]

    #expect(preview.renamedName == "report-🎉🎉.txt")
  }

  @Test("正規表現の大文字小文字区別を切り替えられる")
  func respectsRegexCaseSensitivity() throws {
    let item = makeItem("Report-report.txt")
    var sensitiveRule = BatchRenameRule(
      replacementMode: .regex,
      searchText: "report",
      replacementText: "invoice"
    )
    sensitiveRule.isCaseSensitive = true
    var insensitiveRule = sensitiveRule
    insensitiveRule.isCaseSensitive = false

    let sensitivePreviews = BatchRenamePreviewBuilder.make(items: [item], rule: sensitiveRule)
    try #require(sensitivePreviews.count == 1)
    let sensitive = sensitivePreviews[0]
    let insensitivePreviews = BatchRenamePreviewBuilder.make(items: [item], rule: insensitiveRule)
    try #require(insensitivePreviews.count == 1)
    let insensitive = insensitivePreviews[0]

    #expect(sensitive.renamedName == "Report-invoice.txt")
    #expect(insensitive.renamedName == "invoice-invoice.txt")
  }

  @Test("無効な正規表現は検証エラーになり変更を生成しない")
  func rejectsInvalidRegexPattern() throws {
    let item = makeItem("report.txt")
    let rule = BatchRenameRule(
      replacementMode: .regex,
      searchText: "[",
      replacementText: "invoice"
    )
    let previews = BatchRenamePreviewBuilder.make(items: [item], rule: rule)

    let validation = BatchRenameValidator.validate(
      previews: previews,
      existingItems: [item],
      rule: rule
    )

    try #require(previews.count == 1)
    #expect(previews[0].renamedName == item.name)
    #expect(validation.issues == [.invalidPattern])
    #expect(!validation.isSafe)
  }

  @Test("空・ドット・親ドット・スラッシュ・NULを含む変更後名を拒否する")
  func rejectsAllInvalidNameForms() {
    let invalidNames = ["", ".", "..", "folder/name", "nul\0name"]
    let previews = zip(invalidNames.indices, invalidNames).map { index, name in
      BatchRenamePreview(item: makeItem("old-\(index)"), renamedName: name)
    }

    let validation = BatchRenameValidator.validate(
      previews: previews,
      existingItems: previews.map(\.item),
      rule: BatchRenameRule()
    )

    #expect(validation.issues.count == invalidNames.count)
    #expect(
      Set(validation.issues) == Set(invalidNames.map(BatchRenameValidationIssue.invalidName))
    )
  }

  @Test("変更後名のバッチ内重複を大文字小文字を無視して拒否する")
  func rejectsDuplicateNamesWithinBatch() throws {
    let previews = [
      BatchRenamePreview(item: makeItem("a.txt"), renamedName: "same.txt"),
      BatchRenamePreview(item: makeItem("b.txt"), renamedName: "SAME.txt"),
    ]

    let validation = BatchRenameValidator.validate(
      previews: previews,
      existingItems: previews.map(\.item),
      rule: BatchRenameRule()
    )

    try #require(validation.issues.count == 1)
    #expect(validation.issues[0] == .duplicateName("same.txt"))
  }

  @Test("選択外の既存項目と同じ変更後名を拒否する")
  func rejectsCollisionWithExistingUnselectedItem() {
    let selected = makeItem("old.txt")
    let occupied = makeItem("occupied.txt")
    let previews = [BatchRenamePreview(item: selected, renamedName: occupied.name)]

    let validation = BatchRenameValidator.validate(
      previews: previews,
      existingItems: [selected, occupied],
      rule: BatchRenameRule()
    )

    #expect(validation.issues == [.existingName("occupied.txt")])
  }

  @Test("選択項目同士の名前入れ替えも既存衝突として拒否する")
  func rejectsNameSwapWithinSelection() {
    let first = makeItem("first.txt")
    let second = makeItem("second.txt")
    let previews = [
      BatchRenamePreview(item: first, renamedName: second.name),
      BatchRenamePreview(item: second, renamedName: first.name),
    ]

    let validation = BatchRenameValidator.validate(
      previews: previews,
      existingItems: [first, second],
      rule: BatchRenameRule()
    )

    #expect(
      Set(validation.issues) == [
        .existingName("first.txt"),
        .existingName("second.txt"),
      ])
  }

  @Test("変更なし行は実行対象から除外できる")
  func identifiesUnchangedRows() {
    let unchanged = makeItem("keep.txt")
    let changed = makeItem("old.txt")
    let previews = [
      BatchRenamePreview(item: unchanged, renamedName: unchanged.name),
      BatchRenamePreview(item: changed, renamedName: "new.txt"),
    ]

    #expect(previews.filter(\.hasChanged).map(\.item.name) == ["old.txt"])
  }

  private func makeItem(_ name: String, isDirectory: Bool = false) -> FileItem {
    FileItem(url: URL(filePath: "/tmp/batch-rename/\(name)"), isDirectory: isDirectory)
  }
}
