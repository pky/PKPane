import Testing

@testable import PKPane

struct DiscoverabilityInventoryTests {
  @MainActor
  @Test("検索は編集メニューの直接項目として到達可能にする")
  func searchRemainsDirectMenuItem() {
    #expect(AppMenuCommands.searchMenuInventory == ["検索"])
  }

  @Test("サイドバータグセクションの目録とa11y名を固定する")
  func sidebarTagInventoryMatchesApprovedLabels() {
    #expect(SidebarTagSectionPresentation.sectionTitle == "タグ")
    #expect(
      SidebarTagSectionPresentation.accessibilityLabel(for: "仕事")
        == "仕事タグを検索")
  }
}
