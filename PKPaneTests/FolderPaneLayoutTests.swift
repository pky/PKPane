import Foundation
import Testing

@testable import PKPane

struct FolderPaneLayoutTests {
  @Test("2ペインを表示して左右の操作対象を切り替える")
  func togglesAndActivatesPanes() throws {
    let leftTabID = UUID()
    let rightTabID = UUID()
    var layout = FolderPaneLayout()

    layout.registerInitialTab(id: leftTabID)
    #expect(layout.visiblePanes == [.primary])
    #expect(layout.activeTabID == leftTabID)

    layout.showSecondaryPane(tabID: rightTabID)
    #expect(layout.visiblePanes == [.primary, .secondary])
    #expect(layout.tabID(for: .secondary) == rightTabID)

    layout.activate(.secondary)
    #expect(layout.activePane == .secondary)
    #expect(layout.activeTabID == rightTabID)

    layout.hideSecondaryPane()
    #expect(layout.visiblePanes == [.secondary])
    #expect(layout.activeTabID == rightTabID)
  }

  @Test("反対側で表示中のタブを割り当てると左右を入れ替える")
  func swapsDisplayedTabs() {
    let leftTabID = UUID()
    let rightTabID = UUID()
    var layout = FolderPaneLayout()
    layout.registerInitialTab(id: leftTabID)
    layout.showSecondaryPane(tabID: rightTabID)

    layout.assignTab(id: rightTabID, to: .primary)

    #expect(layout.tabID(for: .primary) == rightTabID)
    #expect(layout.tabID(for: .secondary) == leftTabID)
  }

  @Test("表示中のタブ削除時に反対側と重複しない代替を選ぶ")
  func replacesRemovedTab() {
    let leftTabID = UUID()
    let rightTabID = UUID()
    let replacementTabID = UUID()
    var layout = FolderPaneLayout()
    layout.registerInitialTab(id: leftTabID)
    layout.showSecondaryPane(tabID: rightTabID)

    layout.removeTab(
      id: leftTabID,
      remainingTabIDs: [rightTabID, replacementTabID])

    #expect(layout.tabID(for: .primary) == replacementTabID)
    #expect(layout.tabID(for: .secondary) == rightTabID)
  }

  @Test("切断した場所を閉じるためにレイアウトを初期化する")
  func resetsLayout() {
    var layout = FolderPaneLayout()
    layout.registerInitialTab(id: UUID())
    layout.showSecondaryPane(tabID: UUID())
    layout.activate(.secondary)

    layout.reset()

    #expect(layout.visiblePanes == [.primary])
    #expect(layout.activePane == .primary)
    #expect(layout.activeTabID == nil)
  }

  @Test("アクティブペイン切替は大量反復でも定数時間で完了する")
  func switchesActivePaneQuickly() {
    var layout = FolderPaneLayout()
    layout.registerInitialTab(id: UUID())
    layout.showSecondaryPane(tabID: UUID())
    let clock = ContinuousClock()

    let duration = clock.measure {
      for index in 0..<100_000 {
        layout.activate(index.isMultiple(of: 2) ? .primary : .secondary)
      }
    }

    #expect(duration < .seconds(1))
  }
}
