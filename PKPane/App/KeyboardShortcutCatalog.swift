import AppKit
import Foundation

enum KeyboardShortcutCategory: String, CaseIterable, Identifiable, Sendable {
  case fileOperations
  case edit
  case view
  case move
  case pane
  case other

  var id: Self { self }

  var title: String {
    switch self {
    case .fileOperations: String(localized: "ファイル操作")
    case .edit: String(localized: "編集")
    case .view: String(localized: "表示")
    case .move: String(localized: "移動")
    case .pane: String(localized: "ペイン")
    case .other: String(localized: "その他")
    }
  }
}

struct KeyboardShortcutEntry: Identifiable, Equatable, Sendable {
  let id: String
  let title: String
  let category: KeyboardShortcutCategory
  let shortcuts: [KeymapShortcut]

  var shortcutDisplayText: String {
    shortcuts.isEmpty ? "—" : shortcuts.map(\.displayText).joined(separator: " / ")
  }
}

enum KeyboardShortcutCatalog {
  static func make(
    context: AppMenuContext,
    keymap: KeyboardCommandMap
  ) -> [KeyboardShortcutEntry] {
    let menuEntries = AppMenuItem.allCases.map { item in
      KeyboardShortcutEntry(
        id: item.rawValue,
        title: item.menuTitle(context: context),
        category: item.shortcutCategory,
        shortcuts: effectiveShortcuts(
          menuShortcut: item.menuShortcut,
          keyboardCommand: item.keyboardCommand,
          keymap: keymap))
    }
    let supplementalEntries = AppSupplementalMenuItem.allCases.map { item in
      KeyboardShortcutEntry(
        id: item.rawValue,
        title: item.title,
        category: item.category,
        shortcuts: item.shortcut.map { [$0] } ?? [])
    }
    let menuBackedKeyboardCommands = Set(AppMenuItem.allCases.compactMap(\.keyboardCommand))
    let keyboardOnlyEntries: [KeyboardShortcutEntry] = KeyboardCommand.allCases.compactMap {
      command in
      guard !menuBackedKeyboardCommands.contains(command) else { return nil }
      return KeyboardShortcutEntry(
        id: "keyboard.\(command.rawValue)",
        title: command.displayName,
        category: command.shortcutCategory,
        shortcuts: keymap.bindings(for: command).map(\.shortcut))
    }
    return menuEntries + supplementalEntries + keyboardOnlyEntries
  }

  static func filtered(
    _ entries: [KeyboardShortcutEntry],
    query: String
  ) -> [KeyboardShortcutEntry] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return entries }
    let canonicalShortcutQuery = canonicalShortcutText(query)
    return entries.filter {
      $0.title.localizedCaseInsensitiveContains(query)
        || $0.shortcutDisplayText.localizedCaseInsensitiveContains(query)
        || $0.shortcuts.contains {
          canonicalShortcutText($0.displayText).localizedCaseInsensitiveContains(
            canonicalShortcutQuery)
        }
    }
  }

  static var staticMenuShortcuts: Set<KeymapShortcut> {
    Set(
      AppMenuItem.allCases.compactMap(\.menuShortcut)
        + AppSupplementalMenuItem.allCases.compactMap(\.shortcut))
  }

  private static func effectiveShortcuts(
    menuShortcut: KeymapShortcut?,
    keyboardCommand: KeyboardCommand?,
    keymap: KeyboardCommandMap
  ) -> [KeymapShortcut] {
    let values =
      (menuShortcut.map { [$0] } ?? [])
      + (keyboardCommand.map { keymap.bindings(for: $0).map(\.shortcut) } ?? [])
    return values.reduce(into: [KeymapShortcut]()) { result, shortcut in
      if !result.contains(shortcut) {
        result.append(shortcut)
      }
    }
  }

  private static func canonicalShortcutText(_ value: String) -> String {
    let modifierSymbols = ["⌃", "⌥", "⇧", "⌘"]
    let modifiers = modifierSymbols.filter(value.contains).joined()
    let key = value.filter { character in
      !modifierSymbols.contains(String(character)) && !character.isWhitespace
    }
    return modifiers + key
  }
}

enum AppSupplementalMenuItem: String, CaseIterable {
  case quickOpen = "menu.quickOpen"
  case transferLog = "menu.transferLog"
  case connectServer = "menu.connectServer"
  case connectSFTP = "menu.connectSFTP"
  case favoriteLocations = "menu.favoriteLocations"
  case recentLocations = "menu.recentLocations"
  case deleteCaches = "menu.deleteCaches"
  case keyboardShortcutList = "menu.keyboardShortcutList"

  var title: String {
    switch self {
    case .quickOpen: String(localized: "クイックオープン…")
    case .transferLog: String(localized: "転送履歴")
    case .connectServer: String(localized: "サーバへ接続…")
    case .connectSFTP: String(localized: "SFTPで接続…")
    case .favoriteLocations: String(localized: "お気に入り")
    case .recentLocations: String(localized: "最近使用した場所")
    case .deleteCaches: String(localized: "キャッシュを削除…")
    case .keyboardShortcutList: String(localized: "キーボードショートカット一覧")
    }
  }

  var category: KeyboardShortcutCategory {
    switch self {
    case .quickOpen, .connectServer, .connectSFTP, .favoriteLocations, .recentLocations:
      .move
    case .transferLog, .deleteCaches, .keyboardShortcutList:
      .other
    }
  }

  var shortcut: KeymapShortcut? {
    switch self {
    case .quickOpen: KeymapShortcut(key: "o", modifiers: [.command, .shift])
    case .connectServer: KeymapShortcut(key: "k", modifiers: [.command])
    case .connectSFTP: KeymapShortcut(key: "k", modifiers: [.command, .shift])
    case .transferLog, .favoriteLocations, .recentLocations, .deleteCaches,
      .keyboardShortcutList:
      nil
    }
  }
}

extension AppMenuItem {
  fileprivate var shortcutCategory: KeyboardShortcutCategory {
    switch self {
    case .openSelectedItem, .openWithApplication, .showArchiveContents, .showPackageContents,
      .createDirectory, .previewSelectedItem, .showSelectedItemInfo, .editFinderTags,
      .createArchive,
      .extractArchiveHere, .extractArchiveToFolder, .cancelArchive, .editExternally,
      .toggleCurrentFavorite, .toggleSelectedFolderFavorites, .shareSelectedItems,
      .closeConnection, .deleteSelectedItem, .retryLastTransfer, .duplicateSelectedItem,
      .revealInFinder:
      .fileOperations
    case .undoLastTransfer, .cut, .copy, .copyPath, .copyFileName, .paste, .movePaste,
      .renameSelectedItem, .batchRenameSelectedItems, .focusSearch, .quickSelect, .selectAll:
      .edit
    case .toggleSecondaryPane, .toggleSyncBrowsing, .toggleDetailsInspector, .showIconView,
      .showListView, .showColumnView, .increaseIconSize, .decreaseIconSize, .sortByName,
      .sortByKind, .sortBySize, .sortByModifiedAt, .toggleSortDirection, .toggleHiddenFiles,
      .showDisplayOptions:
      .view
    case .goBack, .goForward, .openParent, .goToLocation, .refresh, .showOriginal, .openInTerminal,
      .compareFolders, .executeFolderSync, .revealSearchResult:
      .move
    case .copyToOppositePane, .moveToOppositePane, .chooseCopyDestination,
      .chooseMoveDestination:
      .pane
    }
  }

  var menuShortcut: KeymapShortcut? {
    switch self {
    case .openSelectedItem: shortcut("o", [.command])
    case .createDirectory: shortcut("n", [.command, .shift])
    case .previewSelectedItem: shortcut("y", [.command])
    case .showSelectedItemInfo: shortcut("i", [.command])
    case .deleteSelectedItem: shortcut("\u{7F}", [.command])
    case .undoLastTransfer: shortcut("z", [.command])
    case .cut: shortcut("x", [.command])
    case .copy: shortcut("c", [.command])
    case .movePaste: shortcut("v", [.command, .option])
    case .showOriginal: nil
    case .paste: shortcut("v", [.command])
    case .focusSearch: shortcut("f", [.command])
    case .quickSelect: shortcut("a", [.command, .option])
    case .selectAll: shortcut("a", [.command])
    case .toggleSecondaryPane: shortcut("\\", [.command])
    case .toggleSyncBrowsing: shortcut("y", [.command, .option])
    case .toggleDetailsInspector: shortcut("p", [.command, .shift])
    case .showIconView: shortcut("1", [.command])
    case .showListView: shortcut("2", [.command])
    case .showColumnView: shortcut("3", [.command])
    case .increaseIconSize: shortcut("+", [.command])
    case .decreaseIconSize: shortcut("-", [.command])
    case .toggleHiddenFiles: shortcut(".", [.command, .shift])
    case .showDisplayOptions: shortcut("j", [.command])
    case .goBack: shortcut(String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.command])
    case .goForward: shortcut(String(UnicodeScalar(NSRightArrowFunctionKey)!), [.command])
    case .openParent: shortcut(String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command])
    case .goToLocation: shortcut("g", [.command, .shift])
    case .refresh: shortcut("r", [.control])
    case .duplicateSelectedItem: shortcut("d", [.command])
    case .editFinderTags, .openWithApplication, .showArchiveContents, .showPackageContents,
      .createArchive,
      .extractArchiveHere, .extractArchiveToFolder, .cancelArchive, .editExternally,
      .toggleCurrentFavorite, .toggleSelectedFolderFavorites, .shareSelectedItems,
      .closeConnection, .copyPath, .copyFileName, .renameSelectedItem,
      .batchRenameSelectedItems, .copyToOppositePane, .moveToOppositePane,
      .chooseCopyDestination, .chooseMoveDestination, .sortByName, .sortByKind, .sortBySize,
      .sortByModifiedAt, .toggleSortDirection, .retryLastTransfer, .revealInFinder,
      .openInTerminal, .compareFolders, .executeFolderSync,
      .revealSearchResult:
      nil
    }
  }

  fileprivate var keyboardCommand: KeyboardCommand? {
    switch self {
    case .openSelectedItem: .open
    case .previewSelectedItem: .quickLook
    case .renameSelectedItem: .rename
    case .focusSearch: .focusSearch
    case .goBack: .goBack
    case .goForward: .goForward
    case .showOriginal: .showOriginal
    case .refresh: .refresh
    default: nil
    }
  }

  private func shortcut(
    _ key: String,
    _ modifiers: KeymapModifierFlags
  ) -> KeymapShortcut {
    KeymapShortcut(key: key, modifiers: modifiers)
  }
}

extension KeyboardCommand {
  fileprivate var shortcutCategory: KeyboardShortcutCategory {
    switch self {
    case .rename, .quickLook, .selectNext, .selectPrevious, .selectNextPage,
      .selectPreviousPage, .clearSelection, .focusSearch, .endSearch:
      .edit
    case .refresh, .showOriginal, .goBack, .goForward, .open:
      .move
    }
  }
}
