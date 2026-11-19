/// 保存済み接続のうち、場所に現在表示する対象を保存順のまま選ぶ。
enum SidebarActiveConnectionProjection {
  static func activeTargets<T: Hashable>(
    ordered: [T],
    additionalOrder: [T] = [],
    activeRemainder: [T] = [],
    connected: Set<T>,
    connecting: Set<T>,
    actionRequired: Set<T> = []
  ) -> [T] {
    var seen = Set<T>()
    return (ordered + additionalOrder + activeRemainder).filter {
      seen.insert($0).inserted
        && (connected.contains($0) || connecting.contains($0) || actionRequired.contains($0))
    }
  }
}
