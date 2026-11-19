import Foundation
import Testing

@testable import PKPane

struct QuickSelectSelectionTests {
  private let rootURL = URL(filePath: "/tmp/quick-select-tests", directoryHint: .isDirectory)

  @Test("新規・追加・解除の3モードを適用する")
  func appliesEverySelectionMode() {
    let text = item("notes.txt")
    let image = item("photo.png")
    let archive = item("backup.zip")
    let items = [text, image, archive]
    let pattern = QuickSelectPattern("*.txt", isCaseSensitive: false)

    #expect(
      QuickSelectSelection.applying(
        pattern: pattern, mode: .replace, to: items, currentSelection: [image.url])
        == [text.url])
    #expect(
      QuickSelectSelection.applying(
        pattern: pattern, mode: .add, to: items, currentSelection: [image.url])
        == [text.url, image.url])
    #expect(
      QuickSelectSelection.applying(
        pattern: pattern, mode: .remove, to: items,
        currentSelection: [text.url, image.url, archive.url])
        == [image.url, archive.url])
  }

  @Test("0件一致なら新規選択でも現在の選択を維持する")
  func preservesSelectionWhenNothingMatches() {
    let text = item("notes.txt")
    let currentSelection: Set<URL> = [text.url]

    let result = QuickSelectSelection.applying(
      pattern: QuickSelectPattern("*.zip", isCaseSensitive: false),
      mode: .replace,
      to: [text],
      currentSelection: currentSelection)

    #expect(result == currentSelection)
  }

  @Test("フォルダも照合対象に含める")
  func includesDirectories() {
    let folder = item("Archive-2026", isDirectory: true)
    let file = item("Archive-2026.zip")

    let result = QuickSelectSelection.applying(
      pattern: QuickSelectPattern("Archive-*", isCaseSensitive: false),
      mode: .replace,
      to: [folder, file],
      currentSelection: [])

    #expect(result == [folder.url, file.url])
  }

  @Test("隠し設定適用後の表示一覧にない項目は選択しない")
  func onlySelectsItemsInVisibleProjection() {
    let visible = item("report.txt")
    let hidden = item(".secret.txt")

    let result = QuickSelectSelection.applying(
      pattern: QuickSelectPattern("*.txt", isCaseSensitive: false),
      mode: .replace,
      to: [visible],
      currentSelection: [hidden.url])

    #expect(result == [visible.url])
  }

  @Test("カラムは選択中の最深カラムを対象にする")
  func targetsDeepestSelectedColumn() throws {
    let firstLocation = FileLocation(localURL: rootURL)
    let childFolder = item("Documents", isDirectory: true)
    let childLocation = childFolder.location
    let firstColumn = FileBrowserColumn(
      location: firstLocation,
      items: [childFolder],
      selectedItemURLs: [childFolder.url],
      isLoading: false)
    let childFile = FileItem(
      url: childFolder.url.appending(path: "report.txt"), isDirectory: false)
    let secondColumn = FileBrowserColumn(
      location: childLocation,
      items: [childFile],
      selectedItemURLs: [childFile.url],
      isLoading: false)

    let target = try #require(
      QuickSelectSelection.activeColumn(in: [firstColumn, secondColumn]))

    #expect(target.location == childLocation)
    #expect(target.items == [childFile])
  }

  @Test("カラムに選択がなければ左端を対象にする")
  func targetsLeftmostColumnWithoutSelection() throws {
    let first = FileBrowserColumn(
      location: FileLocation(localURL: rootURL),
      items: [item("first.txt")],
      selectedItemURLs: [],
      isLoading: false)
    let second = FileBrowserColumn(
      location: FileLocation(localURL: rootURL.appending(path: "child")),
      items: [item("second.txt")],
      selectedItemURLs: [],
      isLoading: false)

    let target = try #require(QuickSelectSelection.activeColumn(in: [first, second]))

    #expect(target.location == first.location)
  }

  private func item(_ name: String, isDirectory: Bool = false) -> FileItem {
    FileItem(url: rootURL.appending(path: name), isDirectory: isDirectory)
  }
}
