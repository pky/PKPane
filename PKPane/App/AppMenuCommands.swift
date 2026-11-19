import AppKit
import SwiftUI

struct AppMenuCommands: Commands {
  /// SwiftUI Commandsが静的に宣言するショートカットの目録。
  /// キーマップ設定では重複を拒否せず、メニューが優先されることを警告するために使う。
  static let shortcutInventory = KeyboardShortcutCatalog.staticMenuShortcuts
  static let detailsDisplayModeMenuInventory = [
    AppMenuItem.toggleDetailsInspector.menuTitle(context: .unavailable)
  ]
  static let syncBrowsingMenuInventory = [
    AppMenuItem.toggleSyncBrowsing.menuTitle(context: .unavailable)
  ]
  static let searchMenuInventory = [
    AppMenuItem.focusSearch.menuTitle(context: .unavailable)
  ]
  static let quickSelectMenuInventory = [
    AppMenuItem.quickSelect.menuTitle(context: .unavailable)
  ]
  static let quickSelectShortcutKey = AppMenuItem.quickSelect.menuShortcut!.key
  static let quickSelectShortcutModifiers =
    AppMenuItem.quickSelect.menuShortcut!.modifiers.swiftUIEventModifiers
  static let quickOpenMenuInventory = [AppSupplementalMenuItem.quickOpen.title]
  static let quickOpenShortcutKey = AppSupplementalMenuItem.quickOpen.shortcut!.key
  static let quickOpenShortcutModifiers =
    AppSupplementalMenuItem.quickOpen.shortcut!.modifiers.swiftUIEventModifiers
  static let folderComparisonMenuInventory = [
    AppMenuItem.compareFolders.menuTitle(context: .unavailable),
    AppMenuItem.executeFolderSync.menuTitle(context: .unavailable),
  ]
  static let transferLogMenuInventory = [AppSupplementalMenuItem.transferLog.title]
  static let globalCommandMenuInventory = [AppSupplementalMenuItem.deleteCaches.title]
  static let keyboardShortcutListMenuInventory = [
    AppSupplementalMenuItem.keyboardShortcutList.title
  ]

  let model: AppMenuModel

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Button(model.menuTitle(for: .openSelectedItem)) { model.perform(.openSelectedItem) }
        .appMenuShortcut(.openSelectedItem)
        .disabled(!model.isEnabled(.openSelectedItem))
      Menu(model.menuTitle(for: .openWithApplication)) {
        fileContextMenuContent(model.openWithMenuItems)
      }
      .disabled(!model.isEnabled(.openWithApplication))
      Button(model.menuTitle(for: .showArchiveContents)) {
        model.perform(.showArchiveContents)
      }
      .disabled(!model.isEnabled(.showArchiveContents))
      Button(model.menuTitle(for: .showPackageContents)) { model.perform(.showPackageContents) }
        .disabled(!model.isEnabled(.showPackageContents))
      Divider()
      Button(model.menuTitle(for: .createDirectory)) { model.perform(.createDirectory) }
        .appMenuShortcut(.createDirectory)
        .disabled(!model.isEnabled(.createDirectory))
      Divider()
      Button(model.menuTitle(for: .previewSelectedItem)) { model.perform(.previewSelectedItem) }
        .appMenuShortcut(.previewSelectedItem)
        .disabled(!model.isEnabled(.previewSelectedItem))
      Button(model.menuTitle(for: .showSelectedItemInfo)) { model.perform(.showSelectedItemInfo) }
        .appMenuShortcut(.showSelectedItemInfo)
        .disabled(!model.isEnabled(.showSelectedItemInfo))
      Button(model.menuTitle(for: .editFinderTags)) { model.perform(.editFinderTags) }
        .disabled(!model.isEnabled(.editFinderTags))
      Divider()
      Button(model.menuTitle(for: .duplicateSelectedItem)) { model.perform(.duplicateSelectedItem) }
        .appMenuShortcut(.duplicateSelectedItem)
        .disabled(!model.isEnabled(.duplicateSelectedItem))
      Button(model.menuTitle(for: .revealInFinder)) { model.perform(.revealInFinder) }
        .disabled(!model.isEnabled(.revealInFinder))
      Button(model.menuTitle(for: .shareSelectedItems)) { model.perform(.shareSelectedItems) }
        .disabled(!model.isEnabled(.shareSelectedItems))
      Divider()
      Button(model.menuTitle(for: .toggleCurrentFavorite)) { model.perform(.toggleCurrentFavorite) }
        .disabled(!model.isEnabled(.toggleCurrentFavorite))
      Button(model.menuTitle(for: .toggleSelectedFolderFavorites)) {
        model.perform(.toggleSelectedFolderFavorites)
      }
      .disabled(!model.isEnabled(.toggleSelectedFolderFavorites))
      Divider()
      ForEach(model.archiveCreationFormats, id: \.self) { format in
        Button(format.creationMenuTitle) {
          model.performCreateArchive(format: format)
        }
        .disabled(!model.isEnabled(.createArchive))
      }
      Button(model.menuTitle(for: .extractArchiveHere)) { model.perform(.extractArchiveHere) }
        .disabled(!model.isEnabled(.extractArchiveHere))
      Button(model.menuTitle(for: .extractArchiveToFolder)) {
        model.perform(.extractArchiveToFolder)
      }
      .disabled(!model.isEnabled(.extractArchiveToFolder))
      Button(model.menuTitle(for: .cancelArchive)) { model.perform(.cancelArchive) }
        .disabled(!model.isEnabled(.cancelArchive))
      Divider()
      Button(model.menuTitle(for: .editExternally)) { model.perform(.editExternally) }
        .disabled(!model.isEnabled(.editExternally))
      Divider()
      Button(model.menuTitle(for: .deleteSelectedItem)) { model.perform(.deleteSelectedItem) }
        .appMenuShortcut(.deleteSelectedItem)
        .disabled(!model.isEnabled(.deleteSelectedItem))
      Divider()
      Button(model.menuTitle(for: .retryLastTransfer)) { model.perform(.retryLastTransfer) }
        .disabled(!model.isEnabled(.retryLastTransfer))
      Button(model.menuTitle(for: .closeConnection)) { model.perform(.closeConnection) }
        .disabled(!model.isEnabled(.closeConnection))
    }

    // 編集系5項目(取り消す/カット/コピー/ペースト/すべて選択)はdisabledを付けない。
    // 有効判定にフォーカス中テキスト欄の有無(AppMenuTextEditing.canPerform=観測不能な
    // グローバル状態)が絡むが、SwiftUIはフォーカス変化でCommandsを再評価しないため、
    // シート内のテキスト欄へ⌘Vしても「無効のまま固まった項目」に吸われて何も起きない
    // 退行が起きた。常時有効にし、実行時に performTextEditingAction(テキスト優先→
    // ファイル操作へフォールバック、後者はmodel.perform内のisEnabledガードで安全に無視)
    // で文脈判定する。
    CommandGroup(replacing: .undoRedo) {
      Button(model.menuTitle(for: .undoLastTransfer)) {
        performTextEditingAction(AppMenuTextEditing.undoAction, fallback: .undoLastTransfer)
      }
      .appMenuShortcut(.undoLastTransfer)
    }

    CommandGroup(replacing: .pasteboard) {
      Button(model.menuTitle(for: .cut)) {
        performTextEditingAction(#selector(NSText.cut(_:)), fallback: .cut)
      }
      .appMenuShortcut(.cut)
      Button(model.menuTitle(for: .copy)) {
        performTextEditingAction(#selector(NSText.copy(_:)), fallback: .copy)
      }
      .appMenuShortcut(.copy)
      Button(model.menuTitle(for: .copyPath)) { model.perform(.copyPath) }
        .disabled(!model.isEnabled(.copyPath))
      Button(model.menuTitle(for: .copyFileName)) { model.perform(.copyFileName) }
        .disabled(!model.isEnabled(.copyFileName))
      Button(model.menuTitle(for: .paste)) {
        performTextEditingAction(#selector(NSText.paste(_:)), fallback: .paste)
      }
      .appMenuShortcut(.paste)
      Button(model.menuTitle(for: .movePaste)) { model.perform(.movePaste) }
        .appMenuShortcut(.movePaste)
        .disabled(!model.isEnabled(.movePaste))
    }

    CommandGroup(replacing: .textEditing) {
      Button(model.menuTitle(for: .renameSelectedItem)) { model.perform(.renameSelectedItem) }
        .disabled(!model.isEnabled(.renameSelectedItem))
      Button(model.menuTitle(for: .batchRenameSelectedItems)) {
        model.perform(.batchRenameSelectedItems)
      }
      .disabled(!model.isEnabled(.batchRenameSelectedItems))
      Divider()
      Button(Self.searchMenuInventory[0]) { model.perform(.focusSearch) }
        .appMenuShortcut(.focusSearch)
        .disabled(!model.isEnabled(.focusSearch))
      Divider()
      ForEach(Self.quickSelectMenuInventory, id: \.self) { title in
        Button(title) { model.perform(.quickSelect) }
          .appMenuShortcut(.quickSelect)
          .disabled(!model.isEnabled(.quickSelect))
      }
      Button(model.menuTitle(for: .selectAll)) {
        performTextEditingAction(#selector(NSText.selectAll(_:)), fallback: .selectAll)
      }
      .appMenuShortcut(.selectAll)
    }

    CommandGroup(after: .toolbar) {
      Menu("表示形式") {
        Button(model.menuTitle(for: .showListView)) { model.perform(.showListView) }
          .appMenuShortcut(.showListView)
          .disabled(!model.isEnabled(.showListView))
        Button(model.menuTitle(for: .showIconView)) { model.perform(.showIconView) }
          .appMenuShortcut(.showIconView)
          .disabled(!model.isEnabled(.showIconView))
        Button(model.menuTitle(for: .showColumnView)) { model.perform(.showColumnView) }
          .appMenuShortcut(.showColumnView)
          .disabled(!model.isEnabled(.showColumnView))
      }
      Button(model.menuTitle(for: .increaseIconSize)) { model.perform(.increaseIconSize) }
        .appMenuShortcut(.increaseIconSize)
        .disabled(!model.isEnabled(.increaseIconSize))
      Button(model.menuTitle(for: .decreaseIconSize)) { model.perform(.decreaseIconSize) }
        .appMenuShortcut(.decreaseIconSize)
        .disabled(!model.isEnabled(.decreaseIconSize))
      Menu("並び順") {
        Button {
          model.perform(.sortByName)
        } label: {
          sortMenuLabel(model.menuTitle(for: .sortByName), order: .name)
        }
        .disabled(!model.isEnabled(.sortByName))
        Button {
          model.perform(.sortByKind)
        } label: {
          sortMenuLabel(model.menuTitle(for: .sortByKind), order: .kind)
        }
        .disabled(!model.isEnabled(.sortByKind))
        Button {
          model.perform(.sortBySize)
        } label: {
          sortMenuLabel(model.menuTitle(for: .sortBySize), order: .size)
        }
        .disabled(!model.isEnabled(.sortBySize))
        Button {
          model.perform(.sortByModifiedAt)
        } label: {
          sortMenuLabel(model.menuTitle(for: .sortByModifiedAt), order: .modifiedAt)
        }
        .disabled(!model.isEnabled(.sortByModifiedAt))
        Divider()
        Button(model.menuTitle(for: .toggleSortDirection)) {
          model.perform(.toggleSortDirection)
        }
        .disabled(!model.isEnabled(.toggleSortDirection))
      }
      Divider()
      Button(model.menuTitle(for: .toggleHiddenFiles)) { model.perform(.toggleHiddenFiles) }
        .appMenuShortcut(.toggleHiddenFiles)
        .disabled(!model.isEnabled(.toggleHiddenFiles))
      Button(model.menuTitle(for: .showDisplayOptions)) { model.perform(.showDisplayOptions) }
        .appMenuShortcut(.showDisplayOptions)
        .disabled(!model.isEnabled(.showDisplayOptions))
      Divider()
      Button(model.menuTitle(for: .toggleSecondaryPane)) { model.perform(.toggleSecondaryPane) }
        .appMenuShortcut(.toggleSecondaryPane)
        .disabled(!model.isEnabled(.toggleSecondaryPane))
      ForEach(Self.syncBrowsingMenuInventory, id: \.self) { title in
        Button {
          model.perform(.toggleSyncBrowsing)
        } label: {
          if model.isSyncBrowsingEnabled {
            Label(title, systemImage: "checkmark")
          } else {
            Text(title)
          }
        }
        .appMenuShortcut(.toggleSyncBrowsing)
        .disabled(!model.isEnabled(.toggleSyncBrowsing))
      }
      ForEach(Self.detailsDisplayModeMenuInventory, id: \.self) { title in
        Button {
          model.perform(.toggleDetailsInspector)
        } label: {
          if model.detailsDisplayMode == .pane {
            Label(title, systemImage: "checkmark")
          } else {
            Text(title)
          }
        }
        .appMenuShortcut(.toggleDetailsInspector)
        .disabled(!model.isEnabled(.toggleDetailsInspector))
      }
      Divider()
      ForEach(Self.transferLogMenuInventory, id: \.self) { title in
        Button(title) { model.showTransferLog() }
          .disabled(!model.canShowTransferLog)
      }
    }

    CommandMenu("コマンド") {
      Button(model.menuTitle(for: .copyToOppositePane)) { model.perform(.copyToOppositePane) }
        .disabled(!model.isEnabled(.copyToOppositePane))
      Button(model.menuTitle(for: .moveToOppositePane)) { model.perform(.moveToOppositePane) }
        .disabled(!model.isEnabled(.moveToOppositePane))
      Divider()
      Button(model.menuTitle(for: .chooseCopyDestination)) {
        model.perform(.chooseCopyDestination)
      }
      .disabled(!model.isEnabled(.chooseCopyDestination))
      Button(model.menuTitle(for: .chooseMoveDestination)) {
        model.perform(.chooseMoveDestination)
      }
      .disabled(!model.isEnabled(.chooseMoveDestination))
      Divider()
      Button(Self.globalCommandMenuInventory[0]) {
        Task { await model.deleteCaches() }
      }
      .disabled(model.isDeletingCaches)
    }

    CommandMenu("移動") {
      ForEach(Self.quickOpenMenuInventory, id: \.self) { title in
        Button(title) { model.showQuickOpen() }
          .appMenuShortcut(.quickOpen)
          .disabled(!model.canShowQuickOpen)
      }
      Button(Self.folderComparisonMenuInventory[0]) { model.perform(.compareFolders) }
        .disabled(!model.isEnabled(.compareFolders))
      Button(Self.folderComparisonMenuInventory[1]) { model.perform(.executeFolderSync) }
        .disabled(!model.isEnabled(.executeFolderSync))
      Divider()
      Button(model.menuTitle(for: .goBack)) { model.perform(.goBack) }
        .appMenuShortcut(.goBack)
        .disabled(!model.isEnabled(.goBack))
      Button(model.menuTitle(for: .goForward)) { model.perform(.goForward) }
        .appMenuShortcut(.goForward)
        .disabled(!model.isEnabled(.goForward))
      Button(model.menuTitle(for: .openParent)) { model.perform(.openParent) }
        .appMenuShortcut(.openParent)
        .disabled(!model.isEnabled(.openParent))
      Divider()
      Button(model.menuTitle(for: .goToLocation)) { model.perform(.goToLocation) }
        .appMenuShortcut(.goToLocation)
        .disabled(!model.isEnabled(.goToLocation))
      Button(model.menuTitle(for: .showOriginal)) { model.perform(.showOriginal) }
        .appMenuShortcut(model.shortcut(for: .showOriginal))
        .disabled(!model.isEnabled(.showOriginal))
      Button(model.menuTitle(for: .refresh)) { model.perform(.refresh) }
        .appMenuShortcut(.refresh)
        .disabled(!model.isEnabled(.refresh))
      Button(model.menuTitle(for: .openInTerminal)) { model.perform(.openInTerminal) }
        .disabled(!model.isEnabled(.openInTerminal))
      Button(model.menuTitle(for: .revealSearchResult)) { model.perform(.revealSearchResult) }
        .disabled(!model.isEnabled(.revealSearchResult))
      Divider()
      // 統合Connect Panel(⌘K)を一覧モードで開く。⌘⇧Kは同じパネルをSFTPフォーム直行で開く
      // 経路として温存する(サブメニューではなく2つの独立項目。NSMenuItemの代替項目機構は
      // SwiftUI Commandsから制御できないため、ラベルを分けて両方を可視項目として提供する)。
      Button(AppSupplementalMenuItem.connectServer.title) { model.connectToServer(.list) }
        .appMenuShortcut(.connectServer)
      Button(AppSupplementalMenuItem.connectSFTP.title) { model.connectToServer(.form(.sftp)) }
        .appMenuShortcut(.connectSFTP)
      Menu(AppSupplementalMenuItem.favoriteLocations.title) {
        locationMenuItems(model.favoriteLocationMenuEntries)
      }
      Menu(AppSupplementalMenuItem.recentLocations.title) {
        locationMenuItems(model.recentLocationMenuEntries)
      }
    }

    CommandGroup(after: .help) {
      ForEach(Self.keyboardShortcutListMenuInventory, id: \.self) { title in
        Button(title) { model.showKeyboardShortcuts() }
          .disabled(!model.canShowKeyboardShortcuts)
      }
    }
  }

  @ViewBuilder
  private func sortMenuLabel(_ title: String, order: FileItemSortOrder) -> some View {
    if model.sortOrder == order {
      Label(title, systemImage: "checkmark")
    } else {
      Text(title)
    }
  }

  @ViewBuilder
  private func locationMenuItems(_ entries: [AppMenuLocationEntry]) -> some View {
    if entries.isEmpty {
      Button("なし") {}
        .disabled(true)
    } else {
      ForEach(entries) { entry in
        Button(entry.title) { entry.open() }
      }
    }
  }

  private func performTextEditingAction(_ action: Selector, fallback: AppMenuItem) {
    if !AppMenuTextEditing.perform(action) {
      model.perform(fallback)
    }
  }
}

@MainActor
private enum AppMenuTextEditing {
  static let undoAction = Selector(("undo:"))

  static func canPerform(_ action: Selector) -> Bool {
    guard isEditingText else { return false }
    return NSApp.target(forAction: action, to: nil, from: nil) != nil
  }

  static func perform(_ action: Selector) -> Bool {
    guard isEditingText else { return false }
    return NSApp.sendAction(action, to: nil, from: nil)
  }

  private static var isEditingText: Bool {
    guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView else { return false }
    return textView.isEditable || textView.hasMarkedText()
  }
}

extension KeymapModifierFlags {
  fileprivate var swiftUIEventModifiers: EventModifiers {
    var result: EventModifiers = []
    if contains(.control) { result.insert(.control) }
    if contains(.option) { result.insert(.option) }
    if contains(.command) { result.insert(.command) }
    if contains(.shift) { result.insert(.shift) }
    return result
  }
}

extension View {
  fileprivate func appMenuShortcut(_ item: AppMenuItem) -> some View {
    appMenuShortcut(item.menuShortcut)
  }

  fileprivate func appMenuShortcut(_ item: AppSupplementalMenuItem) -> some View {
    appMenuShortcut(item.shortcut)
  }

  @ViewBuilder
  fileprivate func appMenuShortcut(_ shortcut: KeymapShortcut?) -> some View {
    if let shortcut, let key = shortcut.key.first {
      keyboardShortcut(
        KeyEquivalent(key),
        modifiers: shortcut.modifiers.swiftUIEventModifiers)
    } else {
      self
    }
  }
}
