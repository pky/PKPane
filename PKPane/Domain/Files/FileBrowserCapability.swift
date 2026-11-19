import Foundation

/// 表示モードごとの操作機能と、表示部品を構成する機能差の正本。
/// 新しいケースを追加したときは3表示モードすべての判断を書くまでコンパイルできない。
enum FileBrowserCapability: CaseIterable, Sendable {
  // 操作パリティ。原則として3表示モードすべてで提供する。
  case multipleSelection
  case contextMenu
  case dragAndDrop
  case keyboardNavigation
  case detailsTracking
  case itemOperations
  case search
  case syncBrowsing
  case quickSelect
  case openInTerminal
  case finderTagDisplay
  case gitStatusDisplay
  case cloudDownloadStatusDisplay

  // 表示部品固有の機能差。
  case tableColumnHeaders
  case metadataColumns
  case listTreeExpansion
  case listColumnWidthDistribution
  case columnNavigation
  case columnBrowsing
  case paneBackgroundDrop
  case flatItemProjection
  case swiftUIItemGestureMonitor
  case alternatingRowBackgrounds
  case horizontalTableScroller
  case columnScrollRouting
  case columnNameChevron

  /// 表示モード別の機能ゲートはこの網羅switchだけを正本とする。
  static func supports(
    _ capability: FileBrowserCapability,
    for mode: FileBrowserViewMode
  ) -> Bool {
    switch (capability, mode) {
    case (.multipleSelection, .list), (.multipleSelection, .icon),
      (.multipleSelection, .column),
      (.contextMenu, .list), (.contextMenu, .icon), (.contextMenu, .column),
      (.dragAndDrop, .list), (.dragAndDrop, .icon), (.dragAndDrop, .column),
      (.keyboardNavigation, .list), (.keyboardNavigation, .icon),
      (.keyboardNavigation, .column),
      (.detailsTracking, .list), (.detailsTracking, .icon), (.detailsTracking, .column),
      (.itemOperations, .list), (.itemOperations, .icon), (.itemOperations, .column),
      (.search, .list), (.search, .icon), (.search, .column),
      (.syncBrowsing, .list), (.syncBrowsing, .icon), (.syncBrowsing, .column),
      (.quickSelect, .list), (.quickSelect, .icon), (.quickSelect, .column),
      (.openInTerminal, .list), (.openInTerminal, .icon), (.openInTerminal, .column),
      (.finderTagDisplay, .list), (.finderTagDisplay, .icon), (.finderTagDisplay, .column):
      true
    case (.gitStatusDisplay, .list), (.gitStatusDisplay, .icon),
      (.gitStatusDisplay, .column):
      true
    case (.cloudDownloadStatusDisplay, .list), (.cloudDownloadStatusDisplay, .icon),
      (.cloudDownloadStatusDisplay, .column):
      true

    case (.tableColumnHeaders, .list),
      (.metadataColumns, .list),
      (.listTreeExpansion, .list),
      (.listColumnWidthDistribution, .list),
      (.paneBackgroundDrop, .list), (.paneBackgroundDrop, .icon),
      (.flatItemProjection, .list), (.flatItemProjection, .icon),
      (.swiftUIItemGestureMonitor, .icon),
      (.alternatingRowBackgrounds, .list), (.alternatingRowBackgrounds, .column),
      (.horizontalTableScroller, .list),
      (.columnNavigation, .column),
      (.columnBrowsing, .column),
      (.columnScrollRouting, .column),
      (.columnNameChevron, .column):
      true

    case (.tableColumnHeaders, .icon), (.tableColumnHeaders, .column),
      (.metadataColumns, .icon), (.metadataColumns, .column),
      (.listTreeExpansion, .icon), (.listTreeExpansion, .column),
      (.listColumnWidthDistribution, .icon), (.listColumnWidthDistribution, .column),
      (.paneBackgroundDrop, .column),
      (.flatItemProjection, .column),
      (.swiftUIItemGestureMonitor, .list), (.swiftUIItemGestureMonitor, .column),
      (.alternatingRowBackgrounds, .icon),
      (.horizontalTableScroller, .icon), (.horizontalTableScroller, .column),
      (.columnNavigation, .list), (.columnNavigation, .icon),
      (.columnBrowsing, .list), (.columnBrowsing, .icon),
      (.columnScrollRouting, .list), (.columnScrollRouting, .icon),
      (.columnNameChevron, .list), (.columnNameChevron, .icon):
      false
    }
  }
}
