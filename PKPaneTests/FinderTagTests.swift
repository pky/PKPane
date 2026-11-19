import Foundation
import Testing

@testable import PKPane

struct FinderTagTests {
  private let labels = ["None", "Gray", "Green", "Purple", "Blue", "Yellow", "Red", "Orange"]

  @Test("標準7色と無色をFinderのラベル順から対応付ける")
  func mapsStandardColorsAndColorlessTag() {
    let tags = FinderTagPalette.tags(
      from: ["Gray", "Green", "Purple", "Blue", "Yellow", "Red", "Orange", "None"],
      standardLabelNames: labels)

    #expect(tags.map(\.color) == [.gray, .green, .purple, .blue, .yellow, .red, .orange, .none])
  }

  @Test("未知名は無色とし拡張属性の色番号は名前より優先する")
  func mapsUnknownNameAndEncodedColor() {
    let tags = FinderTagPalette.tags(
      from: ["独自", "重要\n6"],
      standardLabelNames: labels)

    #expect(
      tags == [
        FinderTag(name: "独自", color: .none),
        FinderTag(name: "重要", color: .red),
      ])
  }

  @Test("表示用要約は先頭3件だけを残し超過数を返す")
  func summarizesAtMostThreeTags() {
    let tags = (0..<5).map { FinderTag(name: "tag-\($0)", color: .blue) }

    let summary = FinderTagDisplaySummary.make(from: tags)

    #expect(summary.visibleTags == Array(tags.prefix(3)))
    #expect(summary.omittedCount == 2)
  }

  @Test("複数選択では全項目に共通するタグだけを先頭項目順で返す")
  func findsCommonNamesForMultipleSelection() {
    let first = FileItem(
      url: URL(filePath: "/tmp/first"), isDirectory: false,
      tags: ["共通", "先頭のみ", "共有"])
    let second = FileItem(
      url: URL(filePath: "/tmp/second"), isDirectory: false,
      tags: ["共有", "共通", "2件目のみ"])

    #expect(FinderTagEditing.commonNames(in: [first, second]) == ["共通", "共有"])
  }

  @Test("共通タグの追加と削除を項目固有タグを保ったまま適用する")
  func appliesAdditionsAndRemovalsPreservingItemSpecificNames() {
    let mutation = FinderTagEditing.mutation(
      from: ["共通", "削除"],
      to: ["共通", "追加"])

    #expect(mutation.additions == ["追加"])
    #expect(mutation.removals == ["削除"])
    #expect(mutation.applying(to: ["共通", "削除", "固有"]) == ["共通", "固有", "追加"])
  }

  @Test("ローカルとマウント済みNASはFinderタグ能力を持つ")
  func localProviderCapabilitiesIncludeFinderTags() {
    #expect(LocalFileProvider().capabilities.contains(.finderTags))
    #expect(
      MountedVolumeProvider(volumeURL: URL(fileURLWithPath: "/Volumes/Test"))
        .capabilities.contains(.finderTags))
  }
}
