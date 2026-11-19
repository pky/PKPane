import Foundation
import Testing

@testable import PKPane

struct FileBrowserDisplayOptionsTests {
  @Test("初期状態では名前・サイズ・更新日時だけを表示する")
  func defaultsToNameSizeAndModifiedAt() {
    let options = FileBrowserDisplayOptions()

    #expect(!options.showsKindColumn)
    #expect(options.showsSizeColumn)
    #expect(options.showsModifiedAtColumn)
    #expect(!options.showsLocationColumn)
    #expect(!options.showsTagsColumn)
    #expect(options.iconSize == .medium)
    #expect(options.viewMode == .list)
    #expect(options.columnWidth == 240)
  }

  @Test("表示列の設定を保存して復元する")
  func savesAndLoadsOptions() {
    let suiteName = "FileBrowserDisplayOptionsTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = FileBrowserDisplayOptionsStore(defaults: defaults)
    let saved = FileBrowserDisplayOptions(
      showsKindColumn: true,
      showsSizeColumn: false,
      showsModifiedAtColumn: true,
      showsLocationColumn: true,
      showsTagsColumn: true,
      iconSize: .large,
      viewMode: .icon,
      columnWidth: 318)

    store.save(saved)

    #expect(store.load() == saved)
    #expect(store.load().iconSize == .large)
    #expect(store.load().viewMode == .icon)
    #expect(store.load().columnWidth == 318)
  }

  @Test("保存したカラム表示モードを読み込み時に復元する")
  func restoresColumnViewMode() {
    let suiteName = "FileBrowserDisplayOptionsTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = FileBrowserDisplayOptionsStore(defaults: defaults)
    store.save(FileBrowserDisplayOptions(viewMode: .column))

    #expect(store.load().viewMode == .column)
  }

  @Test("カラム幅は許容範囲へ丸める")
  func clampsColumnWidth() {
    #expect(FileBrowserColumnWidth.clamped(100) == FileBrowserColumnWidth.minimum)
    #expect(FileBrowserColumnWidth.clamped(320) == 320)
    #expect(FileBrowserColumnWidth.clamped(800) == FileBrowserColumnWidth.maximum)
  }
}
