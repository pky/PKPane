import Foundation
import Testing

@testable import PKPane

@MainActor
struct SidebarSectionExpansionModelTests {
  @Test("各セクションは既定で開いている")
  func defaultsToExpanded() {
    let (defaults, suiteName) = isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let model = SidebarSectionExpansionModel(defaults: defaults)

    #expect(
      SidebarSectionExpansionModel.SectionID.allCases.allSatisfy(model.isExpanded))
  }

  @Test("閉じたセクションを次のモデルでも復元する")
  func persistsCollapsedSections() {
    let (defaults, suiteName) = isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let model = SidebarSectionExpansionModel(defaults: defaults)

    model.setExpanded(false, for: .locations)
    model.setExpanded(false, for: .tags)

    let restored = SidebarSectionExpansionModel(defaults: defaults)
    #expect(!restored.isExpanded(.locations))
    #expect(!restored.isExpanded(.tags))
    #expect(restored.isExpanded(.favorites))
  }

  @Test("開き直した状態も永続化する")
  func persistsReopenedSection() {
    let (defaults, suiteName) = isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let model = SidebarSectionExpansionModel(defaults: defaults)
    model.setExpanded(false, for: .locations)

    model.setExpanded(true, for: .locations)

    let restored = SidebarSectionExpansionModel(defaults: defaults)
    #expect(restored.isExpanded(.locations))
    #expect(restored.collapsedSections.isEmpty)
  }

  private func isolatedDefaults() -> (UserDefaults, String) {
    let suiteName = "SidebarSectionExpansionModelTests-\(UUID())"
    return (UserDefaults(suiteName: suiteName)!, suiteName)
  }
}
