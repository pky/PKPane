import Foundation

/// リスト表示のフォルダその場展開(開閉三角)を支える純粋なツリー状態。展開中フォルダの
/// 集合(expandedLocations)と、展開済みフォルダの子項目キャッシュ(childrenByLocation)だけを
/// 持つ。Provider呼び出し・NSTableView等のUIには一切触れない(doc/plans/2026-08-16-
/// list-tree-expansion.mdの設計方針: NSOutlineViewへは移行せず、この状態をフラット化した
/// 行配列をActivatingTableViewへ流す)。
///
/// 折りたたんでも子孫の展開状態(expandedLocationsのエントリ)とキャッシュ済み子項目は
/// 保持したままにする。再展開時にそのまま復元でき、キャッシュがあれば読み直しも不要になる
/// (Finder同等の仕様)。
struct FileTreeState: Equatable, Sendable {
  private(set) var expandedLocations: Set<FileLocation> = []
  private(set) var childrenByLocation: [FileLocation: [FileItem]] = [:]
  /// フォルダごとの子ロード世代。expand(_:)・beginLoad(_:)で1つ進む。非同期ロードの
  /// 結果を反映する直前にこの値と比較し、古い世代の結果(折りたたんで開き直した後に
  /// 前のロードが遅延して届いた等)を破棄できるようにする。
  private(set) var loadGenerations: [FileLocation: Int] = [:]
  /// 子ロードの結果がまだchildrenByLocationへ反映されていない展開中フォルダの集合。
  /// UI側のスピナー表示にそのまま使える。
  private(set) var pendingLoadLocations: Set<FileLocation> = []

  var isEmpty: Bool { expandedLocations.isEmpty }

  func isExpanded(_ location: FileLocation) -> Bool {
    expandedLocations.contains(location)
  }

  func isLoadingChildren(of location: FileLocation) -> Bool {
    pendingLoadLocations.contains(location)
  }

  func children(of location: FileLocation) -> [FileItem]? {
    childrenByLocation[location]
  }

  func currentGeneration(for location: FileLocation) -> Int {
    loadGenerations[location] ?? 0
  }

  /// locationを展開状態にする。既に展開済みなら何もせずnilを返す(呼び出し側は
  /// 二重ロードを起こさない)。子項目キャッシュが既にあればロード不要のためnilを返す。
  /// キャッシュがなければ新しい世代を発行してpendingLoadLocationsへ加え、呼び出し側が
  /// その世代でProviderへ問い合わせを開始できるよう、発行した世代番号を返す。
  @discardableResult
  mutating func expand(_ location: FileLocation) -> Int? {
    guard !expandedLocations.contains(location) else { return nil }
    expandedLocations.insert(location)
    guard childrenByLocation[location] == nil else { return nil }
    return beginLoad(location)
  }

  /// 展開済みフォルダの子を明示的に再読み込みしたい場合(外部変更の反映等)に世代を
  /// 1つ進めて呼び出し側へロード要求する。展開自体はこのメソッドの責務ではない
  /// (呼び出し側がisExpanded(location)を確認してから呼ぶ想定)。
  @discardableResult
  mutating func beginLoad(_ location: FileLocation) -> Int {
    let next = (loadGenerations[location] ?? 0) + 1
    loadGenerations[location] = next
    pendingLoadLocations.insert(location)
    return next
  }

  /// locationを折りたたむ。子孫の展開状態・キャッシュ済み子項目は保持する
  /// (再展開時に復元される。永続化はしない=セッション内のみの仕様)。
  mutating func collapse(_ location: FileLocation) {
    expandedLocations.remove(location)
  }

  /// 非同期ロードの結果を反映する。generationが現在の世代と一致する場合だけ採用し
  /// (=最新のロード要求由来の結果)、一致しなければ古い結果として破棄する。
  /// 採用できたかどうかを返す(呼び出し側が破棄をログ等に使いたい場合のため)。
  @discardableResult
  mutating func setChildren(
    _ items: [FileItem], for location: FileLocation, generation: Int,
    skipsUnchangedItems: Bool = false
  ) -> Bool {
    guard loadGenerations[location] == generation else { return false }
    if !skipsUnchangedItems || childrenByLocation[location] != items {
      childrenByLocation[location] = items
    }
    pendingLoadLocations.remove(location)
    return true
  }

  /// ロード失敗時、generationが現在の世代と一致する場合だけpendingLoadLocationsを
  /// 解除する(スピナーを止める)。古い世代からの失敗報告は無視する。
  mutating func failedLoad(for location: FileLocation, generation: Int) {
    guard loadGenerations[location] == generation else { return }
    pendingLoadLocations.remove(location)
  }

  @discardableResult
  mutating func replaceItem(_ item: FileItem) -> Bool {
    var replaced = false
    for location in Array(childrenByLocation.keys) {
      guard var children = childrenByLocation[location],
        let index = children.firstIndex(where: { $0.location == item.location })
      else { continue }
      children[index] = item
      childrenByLocation[location] = children
      replaced = true
    }
    return replaced
  }

  /// フォルダ移動(ナビゲート)時に呼び、展開状態を全リセットする(計画どおり展開は
  /// セッション内のみで永続化しない。currentLocationが変わったら意味を持たない)。
  mutating func reset() {
    self = FileTreeState()
  }
}

/// フラット化済みの1行。展開状態を反映した深さ付きの表示行。
/// ActivatingTableViewはこの配列をそのままitemsとして受け取り、深さでインデントし、
/// isExpandable(フォルダ)な行にだけ開閉三角を描く想定(Step 2で配線)。
struct FileTreeRow: Equatable, Identifiable, Sendable {
  let item: FileItem
  let depth: Int
  let isExpanded: Bool
  let isLoadingChildren: Bool

  var id: URL { item.url }
  var isExpandable: Bool { item.isDirectory }
}

/// FileTreeState(展開状態)とルート項目配列から、深さ付きの行配列を組み立てる純関数群。
/// UIにもProviderにも触れない。
enum FileTreeFlattening {
  /// rootItemsとツリー状態から、展開状態を反映した深さ付き行配列を組み立てる。各階層は
  /// 独立にsortOrder/ascendingでソートする(親がどの並び順で表示されていても、展開した
  /// 子は常に同じソート順で並ぶ。doc/plans/2026-08-16-list-tree-expansion.md「ソートは
  /// 各階層に同じソート順を独立適用」)。
  static func flatten(
    rootItems: [FileItem],
    treeState: FileTreeState,
    sortOrder: FileItemSortOrder,
    ascending: Bool
  ) -> [FileTreeRow] {
    var rows: [FileTreeRow] = []
    rows.reserveCapacity(rootItems.count)
    appendRows(
      rootItems, depth: 0, treeState: treeState, sortOrder: sortOrder, ascending: ascending,
      into: &rows)
    return rows
  }

  private static func appendRows(
    _ items: [FileItem],
    depth: Int,
    treeState: FileTreeState,
    sortOrder: FileItemSortOrder,
    ascending: Bool,
    into rows: inout [FileTreeRow]
  ) {
    let sortedItems = items.sorted {
      sortOrder.areInIncreasingOrder($0, $1, ascending: ascending)
    }
    for item in sortedItems {
      let isExpanded = item.isDirectory && treeState.isExpanded(item.location)
      let isLoadingChildren = isExpanded && treeState.isLoadingChildren(of: item.location)
      rows.append(
        FileTreeRow(
          item: item, depth: depth, isExpanded: isExpanded,
          isLoadingChildren: isLoadingChildren))
      guard isExpanded, let children = treeState.children(of: item.location) else { continue }
      appendRows(
        children, depth: depth + 1, treeState: treeState, sortOrder: sortOrder,
        ascending: ascending, into: &rows)
    }
  }

  /// 折りたたみ・フィルタ変更等で見えなくなった行の選択を除去する
  /// (計画:「展開/折りたたみで消えた行の選択は自動で除去」)。
  static func selection(_ selection: Set<URL>, visibleIn rows: [FileTreeRow]) -> Set<URL> {
    let visibleURLs = Set(rows.map(\.item.url))
    return selection.intersection(visibleURLs)
  }
}
