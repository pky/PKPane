import SwiftUI
import Testing

@testable import PKPane

struct SearchToolbarTests {
  @Test("検索フィールドはツールバーへ常設する")
  func searchFieldUsesToolbarPlacement() {
    #expect(ProviderBrowserSearchToolbarConfiguration.placement == .toolbar)
    #expect(
      String(describing: ProviderBrowserSearchToolbarConfiguration.swiftUIPlacement)
        == String(describing: SearchFieldPlacement.toolbar))
  }

  @Test("検索の表示名とアクセシビリティ名を共通化する")
  func searchPromptIsShared() {
    #expect(ProviderBrowserSearchToolbarConfiguration.prompt == "ファイルを検索")
  }

  @Test("検索コマンドは常設フィールドへフォーカスする")
  func focusCommandRequestsSearchFocus() {
    #expect(
      ProviderBrowserSearchToolbarConfiguration.focusRequest(for: .focusSearch) == true)
    #expect(
      ProviderBrowserSearchToolbarConfiguration.focusRequest(for: .endSearch) == false)
    #expect(
      ProviderBrowserSearchToolbarConfiguration.focusRequest(for: .refresh) == nil)
  }
}
