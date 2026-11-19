/// 仮想一覧の背後に残る実フォルダを、現在表示中の場所として操作しない。
enum SidebarCurrentLocationActionPolicy {
  static func canTargetCurrentFolder(isRecentFilesActive: Bool) -> Bool {
    !isRecentFilesActive
  }

  static func performFavoriteToggle(
    isRecentFilesActive: Bool,
    action: () -> Void
  ) {
    guard canTargetCurrentFolder(isRecentFilesActive: isRecentFilesActive) else { return }
    action()
  }
}
