import Foundation
import Testing

@testable import PKPane

struct DetailsInspectorSelectionTests {
  private func makeItems(count: Int) -> [FileItem] {
    (0..<count).map { index in
      FileItem(url: URL(filePath: "/tmp/item-\(index).txt"), isDirectory: false, size: Int64(index))
    }
  }

  @Test("単一選択はその1件をそのまま返す")
  func singleSelectionReturnsThatItem() throws {
    let items = makeItems(count: 5)
    try #require(items.count == 5)
    let selected = Set([items[2].url])

    let result = DetailsInspectorSelection.resolveItems(
      allItems: items, selectedURLs: selected, currentFolderItem: nil)

    #expect(result == [items[2]])
  }

  @Test("複数選択は選択されたすべての項目を一覧の順序で返す")
  func multipleSelectionReturnsAllSelectedItems() throws {
    let items = makeItems(count: 5)
    try #require(items.count == 5)
    let selected = Set([items[0].url, items[3].url])

    let result = DetailsInspectorSelection.resolveItems(
      allItems: items, selectedURLs: selected, currentFolderItem: nil)

    #expect(Set(result.map(\.url)) == selected)
    #expect(result.count == 2)
  }

  @Test("選択なしで現在フォルダが渡されればそれを1件として返す")
  func noSelectionFallsBackToCurrentFolderItem() {
    let items = makeItems(count: 5)
    let folderItem = FileItem(url: URL(filePath: "/tmp/current"), isDirectory: true)

    let result = DetailsInspectorSelection.resolveItems(
      allItems: items, selectedURLs: [], currentFolderItem: folderItem)

    #expect(result == [folderItem])
  }

  @Test("選択なしかつ現在フォルダも不明なら空配列を返す")
  func noSelectionAndNoCurrentFolderReturnsEmpty() {
    let items = makeItems(count: 5)

    let result = DetailsInspectorSelection.resolveItems(
      allItems: items, selectedURLs: [], currentFolderItem: nil)

    #expect(result.isEmpty)
  }

  /// 1000件フォルダで選択を連続変更する状況を模し、選択解決(フィルタリング)自体が
  /// 一覧操作を引っかけない軽さであることを計測する。
  @Test("1000件から1回の選択解決を高速に完了する")
  func resolvesSelectionAmongThousandItemsQuickly() {
    let items = makeItems(count: 1000)
    let folderItem = FileItem(url: URL(filePath: "/tmp/current"), isDirectory: true)
    let clock = ContinuousClock()

    let duration = clock.measure {
      for index in 0..<200 {
        let selected: Set<URL> = index.isMultiple(of: 7) ? [] : [items[index % items.count].url]
        let result = DetailsInspectorSelection.resolveItems(
          allItems: items, selectedURLs: selected, currentFolderItem: folderItem)
        #expect(!result.isEmpty)
      }
    }

    #expect(duration < .milliseconds(200))
    let milliseconds =
      Double(duration.components.seconds) * 1_000
      + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    print(
      "PKPane性能計測: 詳細ペイン選択解決 1000件×200回連続変更 \(String(format: "%.2f", milliseconds))ms")
  }
}
