import Testing

@testable import PKPane

@Suite("サイドバーの現在地操作")
struct SidebarCurrentLocationActionPolicyTests {
  @Test("最近の項目では背後のフォルダをお気に入り操作の対象にしない")
  func recentFilesDoNotTargetPreviousFolder() {
    #expect(
      !SidebarCurrentLocationActionPolicy.canTargetCurrentFolder(
        isRecentFilesActive: true))
    #expect(
      SidebarCurrentLocationActionPolicy.canTargetCurrentFolder(
        isRecentFilesActive: false))

    var toggles = 0
    SidebarCurrentLocationActionPolicy.performFavoriteToggle(isRecentFilesActive: true) {
      toggles += 1
    }
    #expect(toggles == 0)
    SidebarCurrentLocationActionPolicy.performFavoriteToggle(isRecentFilesActive: false) {
      toggles += 1
    }
    #expect(toggles == 1)
  }
}
