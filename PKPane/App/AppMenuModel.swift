import AppKit
import Foundation
import Observation

enum AppMenuItem: String, CaseIterable, Hashable {
  case openSelectedItem
  case openWithApplication
  case showArchiveContents
  case showPackageContents
  case createDirectory
  case previewSelectedItem
  case showSelectedItemInfo
  case editFinderTags
  case createArchive
  case extractArchiveHere
  case extractArchiveToFolder
  case cancelArchive
  case editExternally
  case toggleCurrentFavorite
  case toggleSelectedFolderFavorites
  case shareSelectedItems
  case closeConnection
  case deleteSelectedItem
  case undoLastTransfer
  case retryLastTransfer
  case cut
  case copy
  case copyPath
  case copyFileName
  case paste
  case movePaste
  case showOriginal
  case renameSelectedItem
  case batchRenameSelectedItems
  case focusSearch
  case quickSelect
  case selectAll
  case copyToOppositePane
  case moveToOppositePane
  case chooseCopyDestination
  case chooseMoveDestination
  case toggleSecondaryPane
  case toggleSyncBrowsing
  case toggleDetailsInspector
  case showIconView
  case showListView
  case showColumnView
  case increaseIconSize
  case decreaseIconSize
  case sortByName
  case sortByKind
  case sortBySize
  case sortByModifiedAt
  case toggleSortDirection
  case toggleHiddenFiles
  case showDisplayOptions
  case goBack
  case goForward
  case openParent
  case goToLocation
  case refresh
  case duplicateSelectedItem
  case revealInFinder
  case openInTerminal
  case compareFolders
  case executeFolderSync
  case revealSearchResult

  var browserAction: FileBrowserCommand.Action {
    switch self {
    case .openSelectedItem: .openSelectedItem
    case .openWithApplication: .openWithApplication
    case .showArchiveContents: .showArchiveContents
    case .showPackageContents: .showPackageContents
    case .createDirectory: .createDirectory
    case .previewSelectedItem: .previewSelectedItem
    case .showSelectedItemInfo: .showSelectedItemInfo
    case .editFinderTags: .editFinderTags
    case .createArchive: .createArchive(format: .zip)
    case .extractArchiveHere: .extractArchive(destination: .currentDirectory)
    case .extractArchiveToFolder: .extractArchive(destination: .folderNamedAfterArchive)
    case .cancelArchive: .cancelArchive
    case .editExternally: .editExternally
    case .toggleCurrentFavorite: .toggleCurrentFavorite
    case .toggleSelectedFolderFavorites: .toggleSelectedFolderFavorites
    case .shareSelectedItems: .shareSelectedItems
    case .closeConnection: .closeConnection
    case .deleteSelectedItem: .deleteSelectedItem
    case .undoLastTransfer: .undoLastTransfer
    case .retryLastTransfer: .retryLastTransfer
    case .cut: .cut
    case .copy: .copy
    case .copyPath: .copyPath
    case .copyFileName: .copyFileName
    case .movePaste: .movePaste
    case .showOriginal: .showOriginal
    case .paste: .paste
    case .renameSelectedItem: .renameSelectedItem
    case .batchRenameSelectedItems: .batchRenameSelectedItems
    case .focusSearch: .focusSearch
    case .quickSelect: .showQuickSelect
    case .selectAll: .selectAll
    case .copyToOppositePane: .copyToOppositePane
    case .moveToOppositePane: .moveToOppositePane
    case .chooseCopyDestination: .chooseTransferDestination(movesItems: false)
    case .chooseMoveDestination: .chooseTransferDestination(movesItems: true)
    case .toggleSecondaryPane: .toggleSecondaryPane
    case .toggleSyncBrowsing: .toggleSyncBrowsing
    case .toggleDetailsInspector: .toggleDetailsInspector
    case .showIconView: .setBrowserViewMode(.icon)
    case .showListView: .setBrowserViewMode(.list)
    case .showColumnView: .setBrowserViewMode(.column)
    case .increaseIconSize: .increaseIconSize
    case .decreaseIconSize: .decreaseIconSize
    case .sortByName: .setSortOrder(.name)
    case .sortByKind: .setSortOrder(.kind)
    case .sortBySize: .setSortOrder(.size)
    case .sortByModifiedAt: .setSortOrder(.modifiedAt)
    case .toggleSortDirection: .toggleSortDirection
    case .toggleHiddenFiles: .toggleHiddenFiles
    case .showDisplayOptions: .showDisplayOptions
    case .goBack: .goBack
    case .goForward: .goForward
    case .openParent: .openParent
    case .goToLocation: .goToLocation
    case .refresh: .refresh
    case .duplicateSelectedItem: .duplicateSelectedItem
    case .revealInFinder: .revealInFinder
    case .openInTerminal: .openInTerminal
    case .compareFolders: .compareFolders
    case .executeFolderSync: .executeFolderSync
    case .revealSearchResult: .revealSearchResult
    }
  }

  /// メニューバーとQuick Openが共有する表示名の正本。
  /// 状態に応じて変わる項目も同じコンテキストから導出し、表示名の乖離を防ぐ。
  func menuTitle(context: AppMenuContext) -> String {
    let key: String.LocalizationValue =
      switch self {
      case .openSelectedItem: "開く"
      case .openWithApplication: "このアプリケーションで開く"
      case .showArchiveContents: "アーカイブの内容を表示"
      case .showPackageContents: "パッケージの内容を表示"
      case .createDirectory: "新規フォルダ"
      case .previewSelectedItem: "Quick Look"
      case .showSelectedItemInfo: "情報を見る"
      case .editFinderTags: "タグ…"
      case .createArchive: "選択項目をZIPに圧縮"
      case .extractArchiveHere: "アーカイブをここに展開"
      case .extractArchiveToFolder: "アーカイブを同名フォルダへ展開"
      case .cancelArchive: "アーカイブ処理をキャンセル"
      case .editExternally: "外部アプリで編集"
      case .toggleCurrentFavorite:
        context.isCurrentFavorite ? "お気に入りから削除" : "お気に入りに追加"
      case .toggleSelectedFolderFavorites:
        context.selectedFoldersAreFavorites
          ? "選択フォルダをお気に入りから削除" : "選択フォルダをお気に入りに追加"
      case .shareSelectedItems: "共有…"
      case .closeConnection: "接続を閉じる"
      case .deleteSelectedItem:
        if context.capabilities.contains(.trash) {
          "ゴミ箱へ移動"
        } else if context.capabilities.contains(.deletePermanently) {
          "完全に削除…"
        } else {
          "削除"
        }
      case .undoLastTransfer: "取り消す"
      case .retryLastTransfer: "転送を再試行"
      case .cut: "カット"
      case .copy: "コピー"
      case .copyPath: "パスをコピー"
      case .copyFileName: "ファイル名をコピー"
      case .movePaste: "項目をここに移動"
      case .showOriginal: "オリジナルを表示"
      case .paste: "ペースト"
      case .renameSelectedItem: "リネーム"
      case .batchRenameSelectedItems: "一括リネーム"
      case .focusSearch: "検索"
      case .quickSelect: "パターンで選択…"
      case .selectAll: "すべて選択"
      case .copyToOppositePane: "反対側へコピー"
      case .moveToOppositePane: "反対側へ移動"
      case .chooseCopyDestination: "コピー先を選択…"
      case .chooseMoveDestination: "移動先を選択…"
      case .toggleSecondaryPane: "2ペイン表示切替"
      case .toggleSyncBrowsing: "同期ブラウズ"
      case .toggleDetailsInspector: "詳細を表示"
      case .showIconView: "アイコン"
      case .showListView: "リスト"
      case .showColumnView: "カラム"
      case .increaseIconSize: "拡大"
      case .decreaseIconSize: "縮小"
      case .sortByName: "名前"
      case .sortByKind: "種類"
      case .sortBySize: "サイズ"
      case .sortByModifiedAt: "更新日時"
      case .toggleSortDirection: context.sortAscending ? "降順にする" : "昇順にする"
      case .toggleHiddenFiles: "隠しファイルを表示"
      case .showDisplayOptions: "表示オプション"
      case .goBack: "戻る"
      case .goForward: "進む"
      case .openParent: "親フォルダ"
      case .goToLocation: "フォルダへ移動"
      case .refresh: "更新"
      case .duplicateSelectedItem: "複製"
      case .revealInFinder: "Finderで表示"
      case .openInTerminal: "ターミナルで開く"
      case .compareFolders: "フォルダを比較"
      case .executeFolderSync: "同期を実行…"
      case .revealSearchResult: "選択項目の場所へ移動"
      }
    return String(localized: key)
  }
}

/// 移動メニューの「お気に入り」「最近使用した場所」サブメニュー1項目分。
/// 実体(ローカル保存場所/SFTPお気に入り等)への依存をAppMenuModelへ持ち込まないための
/// 中立な表現。取得はLaunchViewが登録するクロージャに委ねる(メニュー展開のたびに
/// 呼ばれるが、対象はいずれも既にメモリ上にある一覧のため同期I/Oは発生しない)。
struct AppMenuLocationEntry: Identifiable {
  let id: String
  let title: String
  let open: () -> Void
}

struct AppMenuContext: Equatable {
  var isBrowserAvailable = false
  var capabilities: FileProviderCapabilities = []
  var selectedItemCount = 0
  var displayedItemCount = 0
  var canPaste = false
  var canShowOriginal = false
  var canMoveSelection = true
  var canBatchRename = true
  var canCopyToOppositePane = true
  var canMoveToOppositePane = true
  var canCompareFolders = false
  var canUndo = false
  var canRetry = false
  var showsSecondaryPane = false
  var isSyncBrowsingEnabled = false
  var detailsDisplayMode: DetailsDisplayMode = .none
  var selectedItemIsPackage = false
  var selectedItemIsArchive = false
  var selectedItemIsDirectory = false
  var canArchive = false
  var isArchiving = false
  var canPreviewSelectedItem = false
  var canDuplicate = false
  var canEditRemotely = false
  var canToggleCurrentFavorite = false
  var isCurrentFavorite = false
  var canGoBack = false
  var canGoForward = false
  var canOpenParent = false
  var canOpenInTerminal = false
  var canOpenWithApplication = false
  var canEditFinderTags = false
  var openWithFileURL: URL? = nil
  var canShowArchiveContents = false
  var canShareSelectedItems = false
  var canCopySelectedItemPath = false
  var canRevealSearchResult = false
  var canToggleSelectedFolderFavorites = false
  var selectedFoldersAreFavorites = false
  var canCloseConnection = false
  /// ローカルファイルシステム系のブラウザ(ローカル/マウント済みNAS)かどうか。
  /// 複製・Finderで表示はSFTPではlocalURLを持てないため、この判定でスコープ外にする。
  var isLocalProvider = false
  var sortOrder: FileItemSortOrder = .name
  var sortAscending = true

  static let unavailable = Self()
}

@Observable
@MainActor
final class AppMenuModel {
  private(set) var context: AppMenuContext = .unavailable
  @ObservationIgnored private let archivePreferencesStore: ArchivePreferencesStore
  @ObservationIgnored private let cacheDeletionHandler: @MainActor () async -> Void
  @ObservationIgnored private let keymapStore: KeymapPreferencesStore
  @ObservationIgnored private var commandHandler: ((FileBrowserCommand.Action) -> Void)?
  // サーバへ接続・お気に入り/最近使用した場所は、閲覧中のブラウザが無い状態(起動直後の
  // サイドバーのみの画面)でも使えてよい操作なので、ブラウザの有無に紐づくcommandHandlerとは
  // 別系統で登録する。LaunchViewの生存期間中ずっと有効(register/unregisterの対象外)。
  @ObservationIgnored private var connectServerHandler: ((ConnectPanelEntryMode) -> Void)?
  @ObservationIgnored private var favoriteLocationsProvider: (() -> [AppMenuLocationEntry])?
  @ObservationIgnored private var recentLocationsProvider: (() -> [AppMenuLocationEntry])?
  @ObservationIgnored private var quickOpenHandler: (() -> Void)?
  @ObservationIgnored private var transferLogHandler: (() -> Void)?
  @ObservationIgnored private var keyboardShortcutsHandler: (() -> Void)?
  private(set) var isDeletingCaches = false
  private var openWithMenuRevision = 0
  @ObservationIgnored private let openWithApplicationMenu: OpenWithApplicationMenu
  @ObservationIgnored private let openWithApplication: (URL, URL) -> Void

  init(
    archivePreferencesStore: ArchivePreferencesStore = .shared,
    keymapStore: KeymapPreferencesStore = .shared,
    openWithApplicationMenu: OpenWithApplicationMenu? = nil,
    openWithApplication: @escaping (URL, URL) -> Void = { fileURL, applicationURL in
      NSWorkspace.shared.open(
        [fileURL], withApplicationAt: applicationURL,
        configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    },
    deleteCaches: @escaping @MainActor () async -> Void = {
      async let archiveRemoval: Void = ArchiveExtractionCache.shared.removeAll()
      async let remotePreviewRemoval: Void = RemotePreviewCache.shared.removeAll()
      _ = await (archiveRemoval, remotePreviewRemoval)
      FileThumbnailService.shared.removeAll()
      FileIconProvider.shared.removeAll()
    }
  ) {
    self.openWithApplicationMenu = openWithApplicationMenu ?? OpenWithApplicationMenu()
    self.openWithApplication = openWithApplication
    self.archivePreferencesStore = archivePreferencesStore
    self.keymapStore = keymapStore
    cacheDeletionHandler = deleteCaches
  }

  private var currentOwnerID: UUID?
  private var canPasteProvider: (@MainActor () -> Bool)?

  func shortcut(for item: AppMenuItem) -> KeymapShortcut? {
    if item == .showOriginal {
      return keymapStore.current.bindings(for: .showOriginal).first?.shortcut
    }
    return item.menuShortcut
  }

  func register(
    context: AppMenuContext,
    perform commandHandler: @escaping (FileBrowserCommand.Action) -> Void,
    canPaste: (@MainActor () -> Bool)? = nil,
    ownerID: UUID? = nil
  ) {
    currentOwnerID = ownerID
    self.context = context
    self.commandHandler = commandHandler
    canPasteProvider = canPaste
  }

  func isRegisteredWindow(ownerID: UUID) -> Bool { currentOwnerID == ownerID }

  func update(context: AppMenuContext, ownerID: UUID? = nil) {
    guard commandHandler != nil, currentOwnerID == ownerID else { return }
    self.context = context
  }

  func unregister(ownerID: UUID? = nil) {
    guard currentOwnerID == ownerID else { return }
    currentOwnerID = nil
    context = .unavailable
    commandHandler = nil
    canPasteProvider = nil
  }

  func invalidateOpenWithApplications() {
    openWithApplicationMenu.invalidate()
    openWithMenuRevision += 1
  }

  var openWithMenuItems: [FileContextMenuItem] {
    _ = openWithMenuRevision
    guard isEnabled(.openWithApplication), let url = context.openWithFileURL, url.isFileURL
    else { return [] }
    return openWithApplicationMenu.items(for: url) { [weak self] fileURL, applicationURL in
      guard let self, self.context.openWithFileURL == fileURL else { return }
      self.openWithApplication(fileURL, applicationURL)
    } chooseOther: { [weak self] in
      // 古いメニューの「その他」で、変更後の別ファイルを開かない。
      guard let self, self.context.openWithFileURL == url else { return }
      self.perform(.openWithApplication)
    }
  }

  func registerConnectServer(_ handler: @escaping (ConnectPanelEntryMode) -> Void) {
    connectServerHandler = handler
  }

  func registerLocationMenus(
    favorites: @escaping () -> [AppMenuLocationEntry],
    recents: @escaping () -> [AppMenuLocationEntry]
  ) {
    favoriteLocationsProvider = favorites
    recentLocationsProvider = recents
  }

  func registerQuickOpen(_ handler: @escaping () -> Void) {
    quickOpenHandler = handler
  }

  func unregisterQuickOpen() {
    quickOpenHandler = nil
  }

  func showQuickOpen() {
    quickOpenHandler?()
  }

  var canShowQuickOpen: Bool {
    quickOpenHandler != nil
  }

  func registerTransferLog(_ handler: @escaping () -> Void) {
    transferLogHandler = handler
  }

  func unregisterTransferLog() {
    transferLogHandler = nil
  }

  func showTransferLog() {
    transferLogHandler?()
  }

  var canShowTransferLog: Bool {
    transferLogHandler != nil
  }

  func registerKeyboardShortcuts(_ handler: @escaping () -> Void) {
    keyboardShortcutsHandler = handler
  }

  func unregisterKeyboardShortcuts() {
    keyboardShortcutsHandler = nil
  }

  func showKeyboardShortcuts() {
    keyboardShortcutsHandler?()
  }

  var canShowKeyboardShortcuts: Bool {
    keyboardShortcutsHandler != nil
  }

  var keyboardShortcutEntries: [KeyboardShortcutEntry] {
    KeyboardShortcutCatalog.make(context: context, keymap: keymapStore.current)
  }

  func connectToServer(_ entryMode: ConnectPanelEntryMode = .list) {
    connectServerHandler?(entryMode)
  }

  var favoriteLocationMenuEntries: [AppMenuLocationEntry] {
    favoriteLocationsProvider?() ?? []
  }

  var recentLocationMenuEntries: [AppMenuLocationEntry] {
    recentLocationsProvider?() ?? []
  }

  func isEnabled(_ item: AppMenuItem) -> Bool {
    guard context.isBrowserAvailable, commandHandler != nil else { return false }
    switch item {
    case .openSelectedItem:
      return context.selectedItemCount > 0
    case .openWithApplication:
      return context.canOpenWithApplication
    case .showArchiveContents:
      return context.canShowArchiveContents
    case .showPackageContents:
      return context.selectedItemCount == 1 && context.selectedItemIsPackage
    case .createDirectory:
      return context.capabilities.contains(.write)
    case .previewSelectedItem:
      return context.selectedItemCount == 1 && !context.selectedItemIsDirectory
        && context.canPreviewSelectedItem
    case .showSelectedItemInfo:
      return context.selectedItemCount > 0
    case .editFinderTags:
      return context.selectedItemCount > 0 && context.canEditFinderTags
    case .createArchive:
      return context.selectedItemCount > 0 && context.canArchive && !context.isArchiving
    case .extractArchiveHere, .extractArchiveToFolder:
      return context.selectedItemCount == 1 && context.selectedItemIsArchive
        && context.canArchive && !context.isArchiving
    case .cancelArchive:
      return context.isArchiving
    case .editExternally:
      return context.selectedItemCount == 1 && !context.selectedItemIsDirectory
        && context.canEditRemotely
    case .toggleCurrentFavorite:
      return context.canToggleCurrentFavorite
    case .toggleSelectedFolderFavorites:
      return context.canToggleSelectedFolderFavorites
    case .shareSelectedItems:
      return context.canShareSelectedItems
    case .closeConnection:
      return context.canCloseConnection
    case .deleteSelectedItem:
      return context.selectedItemCount > 0
        && !context.capabilities.intersection([.trash, .deletePermanently]).isEmpty
    case .cut:
      return context.selectedItemCount > 0 && context.canMoveSelection
    case .copy:
      return context.selectedItemCount > 0
    case .copyPath, .copyFileName:
      return context.canCopySelectedItemPath
    case .showOriginal:
      return context.selectedItemCount == 1 && context.canShowOriginal
    case .paste, .movePaste:
      return canPasteProvider?() ?? context.canPaste
    case .undoLastTransfer:
      return context.canUndo
    case .retryLastTransfer:
      return context.canRetry
    case .renameSelectedItem:
      return context.selectedItemCount == 1 && context.capabilities.contains(.rename)
    case .batchRenameSelectedItems:
      return context.canBatchRename && context.selectedItemCount >= 2
        && context.capabilities.contains(.rename)
    case .focusSearch:
      return true
    case .quickSelect:
      return true
    case .selectAll:
      return context.displayedItemCount > 0
    case .copyToOppositePane:
      return context.selectedItemCount > 0 && context.showsSecondaryPane
        && context.canCopyToOppositePane
    case .moveToOppositePane:
      return context.selectedItemCount > 0 && context.showsSecondaryPane
        && context.canMoveToOppositePane
    case .chooseCopyDestination:
      return context.selectedItemCount > 0
    case .chooseMoveDestination:
      return context.selectedItemCount > 0 && context.canMoveSelection
    case .toggleSecondaryPane, .toggleDetailsInspector:
      return true
    case .toggleSyncBrowsing:
      return context.showsSecondaryPane
    case .goBack:
      return context.canGoBack
    case .goForward:
      return context.canGoForward
    case .openParent:
      return context.canOpenParent
    case .showIconView, .showListView, .showColumnView, .sortByName, .sortByKind, .sortBySize,
      .sortByModifiedAt, .toggleSortDirection, .toggleHiddenFiles, .showDisplayOptions,
      .goToLocation, .refresh, .increaseIconSize, .decreaseIconSize:
      return true
    case .duplicateSelectedItem:
      return context.selectedItemCount > 0 && context.canDuplicate
    case .revealInFinder:
      return context.selectedItemCount > 0 && context.isLocalProvider
    case .openInTerminal:
      return context.canOpenInTerminal
    case .compareFolders, .executeFolderSync:
      return context.canCompareFolders
    case .revealSearchResult:
      return context.canRevealSearchResult
    }
  }

  func perform(_ item: AppMenuItem) {
    guard isEnabled(item), let commandHandler else { return }
    if item == .createArchive {
      commandHandler(.createArchive(format: archivePreferencesStore.defaultFormat))
      return
    }
    commandHandler(item.browserAction)
  }

  func performCreateArchive(format: ArchiveFormat) {
    guard isEnabled(.createArchive), let commandHandler else { return }
    commandHandler(.createArchive(format: format))
  }

  var alternateArchiveFormat: ArchiveFormat {
    archivePreferencesStore.defaultFormat.alternate
  }

  var archiveCreationFormats: [ArchiveFormat] {
    [archivePreferencesStore.defaultFormat, alternateArchiveFormat]
  }

  var alternateArchiveMenuTitle: String {
    alternateArchiveFormat.creationMenuTitle
  }

  var quickOpenCommandItems: [QuickOpenSourceItem] {
    AppMenuItem.allCases.compactMap { item in
      guard isEnabled(item) else { return nil }
      return QuickOpenSourceItem(
        id: item.rawValue,
        title: menuTitle(for: item))
    }
  }

  func performQuickOpenCommand(id: String) {
    guard let item = AppMenuItem(rawValue: id) else { return }
    perform(item)
  }

  var detailsDisplayMode: DetailsDisplayMode { context.detailsDisplayMode }
  var isSyncBrowsingEnabled: Bool { context.isSyncBrowsingEnabled }
  var sortOrder: FileItemSortOrder { context.sortOrder }
  var sortAscending: Bool { context.sortAscending }

  func menuTitle(for item: AppMenuItem) -> String {
    if item == .createArchive {
      return archivePreferencesStore.defaultFormat.creationMenuTitle
    }
    return item.menuTitle(context: context)
  }

  func deleteCaches() async {
    guard !isDeletingCaches else { return }
    isDeletingCaches = true
    defer { isDeletingCaches = false }
    await cacheDeletionHandler()
  }
}
