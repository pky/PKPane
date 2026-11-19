import Testing

@testable import PKPane

@Suite("場所に表示する接続")
struct SidebarActiveConnectionProjectionTests {
  @Test("接続済み・接続処理中・確認待ちだけを保存順で表示する")
  func includesActiveConnectionsInSavedOrder() {
    let targets = ["idle", "approval", "connected", "connecting", "changed-key"]

    let displayed = SidebarActiveConnectionProjection.activeTargets(
      ordered: targets,
      connected: ["connected"],
      connecting: ["connecting"],
      actionRequired: ["approval", "changed-key"])

    #expect(displayed == ["approval", "connected", "connecting", "changed-key"])
  }

  @Test("保存済み未接続先は場所に表示しない")
  func excludesDisconnectedTargets() {
    let displayed = SidebarActiveConnectionProjection.activeTargets(
      ordered: ["saved-sftp", "saved-ftp"],
      connected: [],
      connecting: [])

    #expect(displayed.isEmpty)
  }

  @Test("プロフィール削除後もお気に入りから接続した接続先を表示する")
  func includesActiveFavoriteWithoutSavedProfile() {
    let displayed = SidebarActiveConnectionProjection.activeTargets(
      ordered: ["saved"],
      additionalOrder: ["favorite", "saved", "recent", "idle-favorite"],
      connected: ["favorite"],
      connecting: ["saved"],
      actionRequired: ["recent"])

    #expect(displayed == ["saved", "favorite", "recent"])
  }

  @Test("接続開始中にプロフィールを削除しても接続先と鍵確認待ちを表示する")
  func includesActiveTargetsMissingFromAllSavedLists() {
    let displayed = SidebarActiveConnectionProjection.activeTargets(
      ordered: ["saved-idle"],
      additionalOrder: ["favorite-idle"],
      activeRemainder: ["connecting-after-delete", "host-key-after-delete"],
      connected: [],
      connecting: ["connecting-after-delete"],
      actionRequired: ["host-key-after-delete"])

    #expect(displayed == ["connecting-after-delete", "host-key-after-delete"])
  }
}
