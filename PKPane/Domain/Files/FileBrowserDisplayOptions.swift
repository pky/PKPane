import Foundation

/// カラム表示の既定幅。個別幅はセッション状態に持ち、最後に変更した幅を次に開く
/// カラムと次回起動時の既定値として永続化する。
enum FileBrowserColumnWidth {
  static let minimum = 180.0
  static let defaultValue = 240.0
  static let maximum = 480.0

  static func clamped(_ width: Double) -> Double {
    min(max(width, minimum), maximum)
  }
}

struct FileBrowserDisplayOptions: Codable, Equatable {
  var showsKindColumn: Bool = false
  var showsSizeColumn: Bool = true
  var showsModifiedAtColumn: Bool = true
  var showsLocationColumn: Bool = false
  var showsTagsColumn: Bool = false
  /// アイコン表示・リスト・カラム表示で共有するアイコンサイズ4段階。
  var iconSize: IconGridSize = .medium
  /// 最後に選んだ表示モード。ツールバー・メニューバー・表示オプションで同じ値を共有する。
  var viewMode: FileBrowserViewMode = .list
  /// カラム表示で個別幅が未指定のカラムに使う既定幅。
  var columnWidth: Double = FileBrowserColumnWidth.defaultValue

  /// 列の表示ON/OFFだけを表す値。FileListView.updateNSViewのrebuild判定はこちらを比較する。
  var visibleColumnSignature: [Bool] {
    [
      showsKindColumn, showsSizeColumn, showsModifiedAtColumn, showsLocationColumn,
      showsTagsColumn,
    ]
  }

  init(
    showsKindColumn: Bool = false,
    showsSizeColumn: Bool = true,
    showsModifiedAtColumn: Bool = true,
    showsLocationColumn: Bool = false,
    showsTagsColumn: Bool = false,
    iconSize: IconGridSize = .medium,
    viewMode: FileBrowserViewMode = .list,
    columnWidth: Double = FileBrowserColumnWidth.defaultValue
  ) {
    self.showsKindColumn = showsKindColumn
    self.showsSizeColumn = showsSizeColumn
    self.showsModifiedAtColumn = showsModifiedAtColumn
    self.showsLocationColumn = showsLocationColumn
    self.showsTagsColumn = showsTagsColumn
    self.iconSize = iconSize
    self.viewMode = viewMode
    self.columnWidth = FileBrowserColumnWidth.clamped(columnWidth)
  }

  private enum CodingKeys: String, CodingKey {
    case showsKindColumn, showsSizeColumn, showsModifiedAtColumn, showsLocationColumn,
      showsTagsColumn, iconSize, viewMode, columnWidth
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    showsKindColumn = try container.decodeIfPresent(Bool.self, forKey: .showsKindColumn) ?? false
    showsSizeColumn = try container.decodeIfPresent(Bool.self, forKey: .showsSizeColumn) ?? true
    showsModifiedAtColumn =
      try container.decodeIfPresent(Bool.self, forKey: .showsModifiedAtColumn) ?? true
    showsLocationColumn =
      try container.decodeIfPresent(Bool.self, forKey: .showsLocationColumn) ?? false
    showsTagsColumn = try container.decodeIfPresent(Bool.self, forKey: .showsTagsColumn) ?? false
    iconSize = try container.decodeIfPresent(IconGridSize.self, forKey: .iconSize) ?? .medium
    let decodedViewMode =
      try container.decodeIfPresent(FileBrowserViewMode.self, forKey: .viewMode) ?? .list
    // 未知の将来値など、現在選択できない表示形式だけをリストへフォールバックする。
    viewMode =
      FileBrowserViewMode.selectableCases.contains(decodedViewMode) ? decodedViewMode : .list
    columnWidth = FileBrowserColumnWidth.clamped(
      try container.decodeIfPresent(Double.self, forKey: .columnWidth)
        ?? FileBrowserColumnWidth.defaultValue)
  }
}
