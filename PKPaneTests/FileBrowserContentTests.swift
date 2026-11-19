import Foundation
import Testing

@testable import PKPane

/// アイコン表示(.icon)のCommand/Shiftクリック複数選択の計算はIconGridSelection(純粋関数)に
/// 分離しているため、SwiftUIやNSEvent.modifierFlagsを介さずここで直接検証できる。
struct IconGridSelectionTests {
  private func makeItems(names: [String]) -> [FileItem] {
    names.map { name in
      FileItem(url: URL(filePath: "/tmp/\(name)"), isDirectory: false)
    }
  }

  @Test("通常クリックは単独選択になりアンカーがクリック対象へ更新される")
  func selectingSingleReplacesSelectionAndSetsAnchor() {
    let url = URL(filePath: "/tmp/a.txt")

    let result = IconGridSelection.selectingSingle(url)

    #expect(result.selectedURLs == [url])
    #expect(result.anchorURL == url)
  }

  @Test("Command+クリックは未選択の項目を選択へ追加する")
  func togglingCommandClickAddsUnselectedItem() {
    let itemA = URL(filePath: "/tmp/a.txt")
    let itemB = URL(filePath: "/tmp/b.txt")

    let result = IconGridSelection.togglingCommandClick(itemB, currentSelection: [itemA])

    #expect(result.selectedURLs == [itemA, itemB])
    #expect(result.anchorURL == itemB)
  }

  @Test("Command+クリックは選択済みの項目を選択から外す")
  func togglingCommandClickRemovesSelectedItem() {
    let itemA = URL(filePath: "/tmp/a.txt")
    let itemB = URL(filePath: "/tmp/b.txt")

    let result = IconGridSelection.togglingCommandClick(
      itemB, currentSelection: [itemA, itemB])

    #expect(result.selectedURLs == [itemA])
    #expect(result.anchorURL == itemB)
  }

  @Test("Shift+クリックはアンカーから対象までの表示順範囲を選択する(昇順)")
  func selectingRangeSelectsForwardRange() {
    let items = makeItems(names: ["a.txt", "b.txt", "c.txt", "d.txt"])

    let result = IconGridSelection.selectingRange(
      to: items[2].url, anchorURL: items[0].url, items: items)

    #expect(result.selectedURLs == Set(items[0...2].map(\.url)))
    // Finder同様、アンカー自体はShift+クリックで動かない。
    #expect(result.anchorURL == items[0].url)
  }

  @Test("Shift+クリックはアンカーより手前の対象でも表示順範囲を選択する(降順)")
  func selectingRangeSelectsBackwardRange() {
    let items = makeItems(names: ["a.txt", "b.txt", "c.txt", "d.txt"])

    let result = IconGridSelection.selectingRange(
      to: items[0].url, anchorURL: items[2].url, items: items)

    #expect(result.selectedURLs == Set(items[0...2].map(\.url)))
    #expect(result.anchorURL == items[2].url)
  }

  @Test("アンカー未設定のShift+クリックは単独選択にフォールバックする")
  func selectingRangeFallsBackToSingleWhenAnchorMissing() {
    let items = makeItems(names: ["a.txt", "b.txt"])

    let result = IconGridSelection.selectingRange(
      to: items[1].url, anchorURL: nil, items: items)

    #expect(result.selectedURLs == [items[1].url])
    #expect(result.anchorURL == items[1].url)
  }

  @Test("アンカーが現在のitems配列に存在しないShift+クリックは単独選択にフォールバックする")
  func selectingRangeFallsBackToSingleWhenAnchorNotFound() {
    let items = makeItems(names: ["a.txt", "b.txt"])
    let staleAnchor = URL(filePath: "/tmp/removed.txt")

    let result = IconGridSelection.selectingRange(
      to: items[1].url, anchorURL: staleAnchor, items: items)

    #expect(result.selectedURLs == [items[1].url])
    #expect(result.anchorURL == items[1].url)
  }

  @Test("アイコン表示のGit状態ラベルは同居するFinderタグ名と結合する")
  @MainActor
  func iconIndicatorCombinesGitStatusAndFinderTagAccessibilityLabels() {
    let tags = FinderTagPalette.systemTags(from: ["重要\n6"])

    #expect(
      FileItemIndicatorAccessibility.label(gitStatus: .modified, tags: tags)
        == "Git変更あり、重要")
  }

  @Test("アイコン表示のクラウド状態ラベルは先頭に結合する")
  @MainActor
  func iconIndicatorPlacesCloudStatusBeforeGitStatusAndFinderTags() {
    let tags = FinderTagPalette.systemTags(from: ["重要\n6"])

    #expect(
      FileItemIndicatorAccessibility.label(
        cloudStatus: .notDownloaded,
        gitStatus: .modified,
        tags: tags)
        == "未ダウンロード、Git変更あり、重要")
  }
}
