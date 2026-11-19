import Foundation
import Testing

@testable import PKPane

struct FileBrowserDisplayOptionsStoreTests {
  @Test("旧形式の保存データ(columnWidthsなし)もデコードできる")
  func decodesLegacyDataWithoutColumnWidths() throws {
    let legacyJSON = """
      {"showsKindColumn":true,"showsSizeColumn":true,"showsModifiedAtColumn":false,"showsLocationColumn":false}
      """
    let suiteName = "test-display-options-legacy.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(Data(legacyJSON.utf8), forKey: "file-browser-display-options")
    let store = FileBrowserDisplayOptionsStore(defaults: defaults)
    let options = store.load()
    #expect(options.showsKindColumn)
    #expect(!options.showsModifiedAtColumn)
    #expect(options.viewMode == .list)
    #expect(options.columnWidth == 240)
  }

  @Test("columnWidthsキーを含む旧バージョンの保存データもデコードできる(キーは無視される)")
  func decodesLegacyDataWithColumnWidthsKeyIgnoringIt() throws {
    let legacyJSON = """
      {"showsKindColumn":true,"showsSizeColumn":false,"showsModifiedAtColumn":true,"showsLocationColumn":true,"columnWidths":{"name":420.5,"size":96}}
      """
    let suiteName = "test-display-options-legacy-widths.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(Data(legacyJSON.utf8), forKey: "file-browser-display-options")
    let store = FileBrowserDisplayOptionsStore(defaults: defaults)
    let options = store.load()
    #expect(options.showsKindColumn)
    #expect(!options.showsSizeColumn)
    #expect(options.showsModifiedAtColumn)
    #expect(options.showsLocationColumn)
    #expect(options.columnWidth == 240)
  }

  @Test("iconSizeキーがない旧バージョンの保存データは中(medium)として復元される")
  func decodesLegacyDataWithoutIconSizeAsMedium() throws {
    let legacyJSON = """
      {"showsKindColumn":false,"showsSizeColumn":true,"showsModifiedAtColumn":true,"showsLocationColumn":false}
      """
    let suiteName = "test-display-options-legacy-icon-size.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(Data(legacyJSON.utf8), forKey: "file-browser-display-options")
    let store = FileBrowserDisplayOptionsStore(defaults: defaults)
    let options = store.load()
    #expect(options.iconSize == .medium)
    #expect(options.viewMode == .list)
  }
}
