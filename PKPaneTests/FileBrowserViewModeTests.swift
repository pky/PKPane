import Testing

@testable import PKPane

struct FileBrowserViewModeTests {
  @Test("Finder互換の表示形式ショートカットを持つ")
  func hasFinderCompatibleShortcuts() {
    #expect(FileBrowserViewMode.icon.shortcutKey == "1")
    #expect(FileBrowserViewMode.list.shortcutKey == "2")
    #expect(FileBrowserViewMode.column.shortcutKey == "3")
  }

  @Test("カラム表示を選択可能な表示形式として公開する")
  func exposesColumnAsSelectableViewMode() {
    #expect(FileBrowserViewMode.selectableCases == [.icon, .list, .column])
  }
}
