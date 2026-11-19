import Foundation

/// カラム表示の1階層分。各カラムはその場所の直下項目と選択集合を持つ。
struct FileBrowserColumn: Equatable, Identifiable, Sendable {
  let location: FileLocation
  var items: [FileItem]
  /// 項目配列そのものが変わったときだけ進む世代。選択変更では進めず、表示用の
  /// フィルタ・ソート結果を再利用できるようにする。
  var itemsRevision: Int = 0
  var selectedItemURLs: Set<URL>
  var isLoading: Bool
  /// このセッションで利用する個別幅。未指定なら永続化された既定幅を使う。
  var widthOverride: Double? = nil

  var id: FileLocation { location }
}

/// カラム表示の階層遷移だけを扱う純粋な状態モデル。Provider列挙やUIには触れない。
struct FileBrowserColumnState: Equatable, Sendable {
  struct Transition: Equatable, Sendable {
    let destination: FileLocation
  }

  private(set) var columns: [FileBrowserColumn] = []

  var isActive: Bool { !columns.isEmpty }
  var currentLocation: FileLocation? { columns.last?.location }
  var allItems: [FileItem] { columns.flatMap(\.items) }

  mutating func begin(at location: FileLocation, items: [FileItem]) {
    columns = [
      FileBrowserColumn(
        location: location, items: items, selectedItemURLs: [], isLoading: false,
        widthOverride: nil)
    ]
  }

  /// 選択元カラムより右を閉じる。単一フォルダ選択だけはその内容を表す右カラムを追加し、
  /// 複数選択・ファイル選択・選択解除では選択元カラムを右端にする。
  mutating func select(_ selectedURLs: Set<URL>, inColumnAt index: Int) -> Transition? {
    guard columns.indices.contains(index) else { return nil }
    let selectedItems = columns[index].items.filter { selectedURLs.contains($0.url) }
    guard selectedItems.count == selectedURLs.count else { return nil }
    let selectedItem = selectedItems.count == 1 ? selectedItems[0] : nil
    let keepsExistingChild =
      selectedItem?.isDirectory == true
      && columns.indices.contains(index + 1)
      && columns[index + 1].location == selectedItem?.location
    let existingChild = keepsExistingChild ? columns[index + 1] : nil
    columns = Array(columns.prefix(index + 1))
    columns[index].selectedItemURLs = selectedURLs
    if let selectedItem, selectedItem.isDirectory {
      columns.append(
        existingChild
          ?? FileBrowserColumn(
            location: selectedItem.location, items: [], selectedItemURLs: [], isLoading: true,
            widthOverride: nil))
      return Transition(destination: selectedItem.location)
    }
    return Transition(destination: columns[index].location)
  }

  mutating func select(_ item: FileItem, inColumnAt index: Int) -> Transition? {
    select([item.url], inColumnAt: index)
  }

  mutating func setItems(_ items: [FileItem], at location: FileLocation) {
    guard let index = columns.firstIndex(where: { $0.location == location }) else { return }
    guard columns[index].items != items else { return }
    columns[index].items = items
    columns[index].itemsRevision &+= 1
  }

  mutating func finishLoading(at location: FileLocation) {
    guard let index = columns.firstIndex(where: { $0.location == location }) else { return }
    columns[index].isLoading = false
  }

  @discardableResult
  mutating func replaceItem(_ item: FileItem) -> Bool {
    var replaced = false
    for index in columns.indices {
      guard
        let itemIndex = columns[index].items.firstIndex(where: {
          $0.location == item.location
        })
      else { continue }
      columns[index].items[itemIndex] = item
      columns[index].itemsRevision &+= 1
      replaced = true
    }
    return replaced
  }

  /// 現在表示中の他カラムは変更前の実効幅で固定し、対象カラムだけを変更する。
  /// 呼び出し元は変更後の幅を次に開くカラムの既定幅として永続化できる。
  mutating func setWidth(_ width: Double, at location: FileLocation, defaultWidth: Double) {
    guard let targetIndex = columns.firstIndex(where: { $0.location == location }) else { return }
    let currentDefaultWidth = FileBrowserColumnWidth.clamped(defaultWidth)
    for index in columns.indices where columns[index].widthOverride == nil {
      columns[index].widthOverride = currentDefaultWidth
    }
    columns[targetIndex].widthOverride = FileBrowserColumnWidth.clamped(width)
  }

  func width(at location: FileLocation, defaultWidth: Double) -> Double? {
    guard let column = columns.first(where: { $0.location == location }) else { return nil }
    return FileBrowserColumnWidth.clamped(column.widthOverride ?? defaultWidth)
  }

  mutating func reset() {
    columns.removeAll()
  }
}

enum FileColumnHorizontalDirection: Sendable {
  case left
  case right
}

/// カラム表示の左右キー操作をNSTableViewのフォーカス状態から分離した純粋計算。
/// UIは返された対象を既存の選択コールバックへ渡すだけにする。
enum FileColumnKeyboardNavigation {
  struct Target: Equatable, Sendable {
    let columnIndex: Int
    let item: FileItem
  }

  enum HandlingResult: Equatable, Sendable {
    case move(Target)
    case handledWithoutMovement
    case unhandled
  }

  /// カラム表示が左右キーイベントを消費するかを、実際の移動先と併せて返す。
  /// 左端の←は移動先がなくてもNSTableViewの既定処理へ渡さない。
  static func handlingResult(
    in columns: [FileBrowserColumn],
    activeColumnIndex: Int,
    direction: FileColumnHorizontalDirection
  ) -> HandlingResult {
    guard columns.indices.contains(activeColumnIndex) else { return .unhandled }
    if case .left = direction, activeColumnIndex == columns.startIndex {
      return .handledWithoutMovement
    }
    guard
      let target = horizontalTarget(
        in: columns, activeColumnIndex: activeColumnIndex, direction: direction)
    else { return .unhandled }
    return .move(target)
  }

  static func horizontalTarget(
    in columns: [FileBrowserColumn],
    activeColumnIndex: Int,
    direction: FileColumnHorizontalDirection
  ) -> Target? {
    guard columns.indices.contains(activeColumnIndex) else { return nil }
    switch direction {
    case .left:
      let parentIndex = activeColumnIndex - 1
      guard columns.indices.contains(parentIndex) else { return nil }
      let childLocation = columns[activeColumnIndex].location
      guard
        let parentItem = columns[parentIndex].items.first(where: {
          $0.location == childLocation
        })
      else { return nil }
      return Target(columnIndex: parentIndex, item: parentItem)
    case .right:
      let childIndex = activeColumnIndex + 1
      guard columns.indices.contains(childIndex) else { return nil }
      let childColumn = columns[childIndex]
      guard !childColumn.items.isEmpty else { return nil }
      let target =
        childColumn.items.first { childColumn.selectedItemURLs.contains($0.url) }
        ?? childColumn.items[0]
      return Target(columnIndex: childIndex, item: target)
    }
  }
}

/// 全カラムの表示用フィルタ・ソート変換。セッションのObservation状態から分離し、
/// 深い階層×大量項目の性能を純粋な入力で検証できるようにする。
enum FileBrowserColumnDisplay {
  static func items(
    from column: FileBrowserColumn,
    matching filterText: String,
    sortOrder: FileItemSortOrder,
    ascending: Bool,
    includesHiddenItems: Bool
  ) -> [FileItem] {
    var displayedItems = FileItemFilter.filteredAndSorted(
      column.items, matching: filterText, matchMode: .literal,
      sortOrder: sortOrder, ascending: ascending)
    if !includesHiddenItems {
      displayedItems.removeAll { $0.name.hasPrefix(".") }
    }
    return displayedItems
  }

  static func columns(
    from columns: [FileBrowserColumn],
    matching filterText: String,
    sortOrder: FileItemSortOrder,
    ascending: Bool,
    includesHiddenItems: Bool
  ) -> [FileBrowserColumn] {
    columns.map { column in
      return FileBrowserColumn(
        location: column.location,
        items: items(
          from: column,
          matching: filterText,
          sortOrder: sortOrder,
          ascending: ascending,
          includesHiddenItems: includesHiddenItems),
        itemsRevision: column.itemsRevision,
        selectedItemURLs: column.selectedItemURLs,
        isLoading: column.isLoading,
        widthOverride: column.widthOverride)
    }
  }
}
