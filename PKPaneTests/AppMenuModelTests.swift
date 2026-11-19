import AppKit
import Foundation
import Testing

@testable import PKPane

@MainActor
struct AppMenuModelTests {
  @Test("複数選択の開くを有効にする")
  func enablesOpeningMultipleSelectedItems() {
    let model = AppMenuModel()
    model.register(context: AppMenuContext(isBrowserAvailable: true, selectedItemCount: 2)) { _ in }
    #expect(model.isEnabled(.openSelectedItem))
  }

  @Test("開く候補は既定アプリ先頭・重複なし・固有画像付きで同じURLの再列挙を避ける")
  func openWithCandidatesKeepImagesAndCacheRepeatedReads() throws {
    let file = URL(filePath: "/tmp/open-with.txt")
    let firstApp = URL(filePath: "/Applications/First.app")
    let defaultApp = URL(filePath: "/Applications/Default.app")
    let sourceIcon = NSWorkspace.shared.icon(forFile: "/System/Applications/TextEdit.app")
    let originalSize = sourceIcon.size
    var enumerationCount = 0
    var iconCount = 0
    var clock = Date(timeIntervalSince1970: 100)
    let menu = OpenWithApplicationMenu(
      applications: { _ in
        enumerationCount += 1
        return [firstApp, defaultApp, firstApp]
      },
      defaultApplication: { _ in defaultApp },
      applicationName: { $0.deletingPathExtension().lastPathComponent },
      applicationIcon: { _ in
        iconCount += 1
        return sourceIcon
      },
      now: { clock })
    var opened: [(URL, URL)] = []
    var otherCount = 0
    let items = menu.items(
      for: file, open: { opened.append(($0, $1)) }, chooseOther: { otherCount += 1 })
    #expect(items.map(\.title) == ["Default", "First", "", String(localized: "その他…")])
    #expect(items[2].isSeparator)
    let icon = try #require(items[0].nsImage)
    #expect(icon.size == NSSize(width: 16, height: 16))
    #expect(!icon.isTemplate)
    #expect(sourceIcon.size == originalSize)
    items[0].action()
    #expect(opened.count == 1)
    #expect(opened.first?.0 == file)
    #expect(opened.first?.1 == defaultApp)
    items[3].action()
    #expect(otherCount == 1)
    _ = menu.items(for: file, open: { _, _ in }, chooseOther: {})
    #expect(enumerationCount == 1)
    #expect(iconCount == 2)
    _ = menu.items(for: URL(filePath: "/tmp/other.txt"), open: { _, _ in }, chooseOther: {})
    #expect(enumerationCount == 2)
    clock = clock.addingTimeInterval(31)
    _ = menu.items(for: file, open: { _, _ in }, chooseOther: {})
    #expect(enumerationCount == 3)
  }

  @Test("候補なしでもその他を表示し、リモートURLは列挙しない")
  func openWithEmptyCandidatesAndRemoteURL() throws {
    var enumerationCount = 0
    let menu = OpenWithApplicationMenu(
      applications: { _ in
        enumerationCount += 1
        return []
      },
      defaultApplication: { _ in nil })
    let items = menu.items(
      for: URL(filePath: "/tmp/unknown"), open: { _, _ in }, chooseOther: {})
    #expect(items.map(\.title) == [String(localized: "その他…")])
    let remoteURL = try #require(URL(string: "sftp://example.invalid/file.txt"))
    #expect(menu.items(for: remoteURL, open: { _, _ in }, chooseOther: {}).isEmpty)
    #expect(enumerationCount == 1)
  }

  @Test("メニューバーの候補は選択変更を反映し、古い候補とその他は別ファイルを開かない")
  func openWithMenuFollowsSelectionAndRejectsStaleActions() {
    let first = URL(filePath: "/tmp/first.txt")
    let second = URL(filePath: "/tmp/second.txt")
    let application = URL(filePath: "/System/Applications/TextEdit.app")
    var enumeratedURLs = [URL]()
    let menu = OpenWithApplicationMenu(
      applications: { url in
        enumeratedURLs.append(url)
        return [application]
      },
      defaultApplication: { _ in nil })
    var opened = [URL]()
    var commands = [FileBrowserCommand.Action]()
    let model = AppMenuModel(
      openWithApplicationMenu: menu,
      openWithApplication: { file, _ in opened.append(file) })
    model.register(
      context: AppMenuContext(
        isBrowserAvailable: true, canOpenWithApplication: true, openWithFileURL: first)
    ) { commands.append($0) }
    #expect(enumeratedURLs.isEmpty)
    let stale = model.openWithMenuItems
    _ = model.openWithMenuItems
    #expect(enumeratedURLs == [first])
    model.update(
      context: AppMenuContext(
        isBrowserAvailable: true, canOpenWithApplication: true, openWithFileURL: second))
    #expect(enumeratedURLs == [first])
    stale.first?.action()
    stale.last?.action()
    #expect(opened.isEmpty)
    #expect(commands.isEmpty)
    model.openWithMenuItems.first?.action()
    #expect(opened == [second])
    #expect(enumeratedURLs == [first, second])
    model.invalidateOpenWithApplications()
    #expect(enumeratedURLs == [first, second])
    _ = model.openWithMenuItems
    #expect(enumeratedURLs == [first, second, second])
    model.openWithMenuItems.last?.action()
    #expect(commands.count == 1)
    guard case .openWithApplication = commands.first else {
      Issue.record("その他からアプリ選択コマンドが実行されませんでした")
      return
    }
    model.update(context: AppMenuContext(isBrowserAvailable: true))
    #expect(model.openWithMenuItems.isEmpty)
    #expect(!model.isEnabled(.openWithApplication))
  }

  @Test("完全削除だけの接続では元に戻せない操作名を表示する")
  func permanentDeleteUsesExplicitMenuTitle() {
    let model = AppMenuModel()
    model.register(
      context: AppMenuContext(
        isBrowserAvailable: true,
        capabilities: [.deletePermanently],
        selectedItemCount: 1)
    ) { _ in }

    #expect(model.isEnabled(.deleteSelectedItem))
    #expect(model.menuTitle(for: .deleteSelectedItem) == "完全に削除…")
  }

  @Test("Quick Lookはプレビュー経路を持つファイル1件だけで有効になる")
  func previewRequiresExecutableFileSelection() {
    let model = AppMenuModel()
    model.register(
      context: AppMenuContext(
        isBrowserAvailable: true,
        selectedItemCount: 1,
        canPreviewSelectedItem: true)
    ) { _ in }

    #expect(model.isEnabled(.previewSelectedItem))

    model.update(
      context: AppMenuContext(
        isBrowserAvailable: true,
        selectedItemCount: 1,
        selectedItemIsDirectory: true,
        canPreviewSelectedItem: true))
    #expect(!model.isEnabled(.previewSelectedItem))

    model.update(
      context: AppMenuContext(
        isBrowserAvailable: true,
        selectedItemCount: 1,
        canPreviewSelectedItem: false))
    #expect(!model.isEnabled(.previewSelectedItem))
  }

  @Test("ターミナルで開くはローカル対象を解決できる場合だけ有効になる")
  func openInTerminalRequiresResolvedLocalTarget() {
    let model = AppMenuModel()
    model.register(
      context: AppMenuContext(isBrowserAvailable: true, canOpenInTerminal: false)
    ) { _ in }

    #expect(!model.isEnabled(.openInTerminal))

    model.update(
      context: AppMenuContext(isBrowserAvailable: true, canOpenInTerminal: true))
    #expect(model.isEnabled(.openInTerminal))
  }

  @Test("コンテキスト専用だった操作は対象条件に応じてメニューから有効になる")
  func contextOnlyCommandsFollowCurrentSelectionContext() {
    let model = AppMenuModel()
    model.register(
      context: AppMenuContext(
        isBrowserAvailable: true,
        canOpenWithApplication: true,
        canShowArchiveContents: true,
        canShareSelectedItems: true,
        canCopySelectedItemPath: true,
        canRevealSearchResult: true,
        canToggleSelectedFolderFavorites: true,
        canCloseConnection: true)
    ) { _ in }

    #expect(model.isEnabled(.openWithApplication))
    #expect(model.isEnabled(.showArchiveContents))
    #expect(model.isEnabled(.shareSelectedItems))
    #expect(model.isEnabled(.copyPath))
    #expect(model.isEnabled(.copyFileName))
    #expect(model.isEnabled(.revealSearchResult))
    #expect(model.isEnabled(.toggleSelectedFolderFavorites))
    #expect(model.isEnabled(.closeConnection))
  }

  @Test("キャッシュ削除はメニューモデルの共有経路を使う")
  func globalDiscoveryCommandsUseInjectedHandlers() async {
    var cacheDeletionCount = 0
    let model = AppMenuModel(deleteCaches: { cacheDeletionCount += 1 })

    await model.deleteCaches()
    #expect(cacheDeletionCount == 1)
  }

  @Test
  func registrationEnablesCommandsFromTheCurrentBrowserContext() {
    let model = AppMenuModel()
    model.register(
      context: AppMenuContext(
        isBrowserAvailable: true,
        capabilities: [.write, .rename, .trash],
        selectedItemCount: 1,
        displayedItemCount: 3,
        canPaste: true,
        canUndo: true,
        canRetry: true,
        showsSecondaryPane: true,
        canGoBack: true,
        canGoForward: false,
        canOpenParent: true
      )
    ) { _ in }

    #expect(model.isEnabled(.createDirectory))
    #expect(model.isEnabled(.renameSelectedItem))
    #expect(model.isEnabled(.deleteSelectedItem))
    #expect(model.isEnabled(.paste))
    #expect(model.isEnabled(.undoLastTransfer))
    #expect(model.isEnabled(.retryLastTransfer))
    #expect(model.isEnabled(.copyToOppositePane))
    #expect(model.isEnabled(.toggleSyncBrowsing))
    #expect(model.isEnabled(.quickSelect))
    #expect(model.isEnabled(.goBack))
    #expect(!model.isEnabled(.goForward))
  }

  @Test
  func multipleSelectionEnablesDeleteAndTransferCommands() {
    let model = AppMenuModel()
    model.register(
      context: AppMenuContext(
        isBrowserAvailable: true,
        capabilities: [.trash, .rename],
        selectedItemCount: 2,
        showsSecondaryPane: true)
    ) { _ in }

    #expect(model.isEnabled(.deleteSelectedItem))
    #expect(model.isEnabled(.copyToOppositePane))
    #expect(model.isEnabled(.moveToOppositePane))
    #expect(model.isEnabled(.chooseCopyDestination))
    #expect(model.isEnabled(.chooseMoveDestination))
    #expect(model.isEnabled(.batchRenameSelectedItems))
  }

  @Test("一括リネームは2件以上かつrename能力があるときだけ有効になる")
  func batchRenameRequiresMultipleSelectionAndRenameCapability() {
    let model = AppMenuModel()
    var actions = [FileBrowserCommand.Action]()
    model.register(
      context: AppMenuContext(
        isBrowserAvailable: true,
        capabilities: [.rename],
        selectedItemCount: 1)
    ) { actions.append($0) }

    #expect(!model.isEnabled(.batchRenameSelectedItems))

    model.update(
      context: AppMenuContext(
        isBrowserAvailable: true,
        capabilities: [.rename],
        selectedItemCount: 2))
    #expect(model.isEnabled(.batchRenameSelectedItems))
    model.perform(.batchRenameSelectedItems)
    if let action = actions.first, case .batchRenameSelectedItems = action {
    } else {
      Issue.record("一括リネームのactionへ写像されていません")
    }

    model.update(
      context: AppMenuContext(
        isBrowserAvailable: true,
        capabilities: [.read],
        selectedItemCount: 2))
    #expect(!model.isEnabled(.batchRenameSelectedItems))
  }

  @Test("最近の項目では一括リネームを無効にし、単一リネームは維持する")
  func recentFilesDisableBatchRenameOnly() {
    let model = AppMenuModel()
    model.register(
      context: AppMenuContext(
        isBrowserAvailable: true,
        capabilities: [.rename],
        selectedItemCount: 2,
        canBatchRename: false)
    ) { _ in }

    #expect(!model.isEnabled(.batchRenameSelectedItems))
    model.update(
      context: AppMenuContext(
        isBrowserAvailable: true,
        capabilities: [.rename],
        selectedItemCount: 1,
        canBatchRename: false))
    #expect(model.isEnabled(.renameSelectedItem))
  }

  @Test
  func oppositePaneCommandsRequireTwoPaneLayout() {
    let model = AppMenuModel()
    model.register(
      context: AppMenuContext(isBrowserAvailable: true, selectedItemCount: 1)
    ) { _ in }

    #expect(!model.isEnabled(.copyToOppositePane))
    #expect(!model.isEnabled(.moveToOppositePane))
    #expect(!model.isEnabled(.toggleSyncBrowsing))
    #expect(!model.isEnabled(.compareFolders))
    #expect(!model.isEnabled(.executeFolderSync))
    #expect(model.isEnabled(.chooseCopyDestination))

    model.update(
      context: AppMenuContext(
        isBrowserAvailable: true,
        canCompareFolders: true,
        showsSecondaryPane: true))
    #expect(model.isEnabled(.compareFolders))
    #expect(model.isEnabled(.executeFolderSync))
  }

  @Test("同期ブラウズのチェック状態をメニューへ反映する")
  func reflectsSyncBrowsingState() {
    let model = AppMenuModel()
    model.register(
      context: AppMenuContext(
        isBrowserAvailable: true,
        showsSecondaryPane: true,
        isSyncBrowsingEnabled: true)
    ) { _ in }

    #expect(model.isEnabled(.toggleSyncBrowsing))
    #expect(model.isSyncBrowsingEnabled)
  }

  @Test
  func archivePackageRemoteEditAndFavoriteAvailabilityFollowContext() {
    let model = AppMenuModel()
    model.register(
      context: AppMenuContext(
        isBrowserAvailable: true,
        selectedItemCount: 1,
        selectedItemIsPackage: true,
        selectedItemIsArchive: true,
        canArchive: true,
        canEditRemotely: true,
        canToggleCurrentFavorite: true)
    ) { _ in }

    #expect(model.isEnabled(.showPackageContents))
    #expect(model.isEnabled(.createArchive))
    #expect(model.isEnabled(.extractArchiveHere))
    #expect(model.isEnabled(.editExternally))
    #expect(model.isEnabled(.toggleCurrentFavorite))
    #expect(!model.isEnabled(.cancelArchive))

    model.update(
      context: AppMenuContext(
        isBrowserAvailable: true,
        selectedItemCount: 1,
        selectedItemIsArchive: true,
        canArchive: true,
        isArchiving: true)
    )
    #expect(!model.isEnabled(.createArchive))
    #expect(!model.isEnabled(.extractArchiveToFolder))
    #expect(model.isEnabled(.cancelArchive))
  }

  @Test
  func commandItemsMapToFileBrowserActions() throws {
    let model = AppMenuModel()
    var actions: [FileBrowserCommand.Action] = []
    model.register(
      context: AppMenuContext(isBrowserAvailable: true, displayedItemCount: 1)
    ) { actions.append($0) }

    model.perform(.showIconView)
    model.perform(.showColumnView)
    model.perform(.sortByModifiedAt)
    model.perform(.refresh)
    model.perform(.quickSelect)

    try #require(actions.count == 5)
    if case .setBrowserViewMode(.icon) = actions[0] {
    } else {
      Issue.record("アイコン表示のactionへ写像されていません")
    }
    if case .setBrowserViewMode(.column) = actions[1] {
    } else {
      Issue.record("カラム表示のactionへ写像されていません")
    }
    if case .setSortOrder(.modifiedAt) = actions[2] {
    } else {
      Issue.record("更新日時順のactionへ写像されていません")
    }
    if case .refresh = actions[3] {
    } else {
      Issue.record("更新のactionへ写像されていません")
    }
    if case .showQuickSelect = actions[4] {
    } else {
      Issue.record("Quick Selectのactionへ写像されていません")
    }
  }

  @Test("表示メニューは更新された操作対象ペインのソート状態を反映する")
  func reflectsActivePaneSortContext() {
    let model = AppMenuModel()
    model.register(
      context: AppMenuContext(
        isBrowserAvailable: true,
        sortOrder: .size,
        sortAscending: false)
    ) { _ in }

    #expect(model.sortOrder == .size)
    #expect(!model.sortAscending)

    model.update(
      context: AppMenuContext(
        isBrowserAvailable: true,
        sortOrder: .kind,
        sortAscending: true))

    #expect(model.sortOrder == .kind)
    #expect(model.sortAscending)
  }

  @Test("情報を見るは詳細表示モードに関係なく有効になる")
  func showInfoRemainsEnabledForEveryDetailsDisplayMode() {
    for mode in DetailsDisplayMode.allCases {
      let model = AppMenuModel()
      model.register(
        context: AppMenuContext(
          isBrowserAvailable: true,
          selectedItemCount: 1,
          detailsDisplayMode: mode)
      ) { _ in }

      #expect(model.isEnabled(.showSelectedItemInfo))
    }
  }

  @Test
  func disabledAndUnregisteredCommandsAreNotIssued() {
    let model = AppMenuModel()
    var issuedCount = 0
    model.register(context: AppMenuContext(isBrowserAvailable: true)) { _ in
      issuedCount += 1
    }

    model.perform(.copy)
    #expect(issuedCount == 0)

    model.unregister()
    model.perform(.refresh)
    #expect(issuedCount == 0)
    #expect(!model.isEnabled(.refresh))
  }

  @Test
  func duplicateUsesProviderCapabilityWhileRevealRequiresLocalProvider() {
    let model = AppMenuModel()
    model.register(
      context: AppMenuContext(
        isBrowserAvailable: true,
        capabilities: [.copyWithinProvider],
        selectedItemCount: 1,
        canDuplicate: true,
        isLocalProvider: true)
    ) { _ in }

    #expect(model.isEnabled(.duplicateSelectedItem))
    #expect(model.isEnabled(.revealInFinder))

    model.update(
      context: AppMenuContext(
        isBrowserAvailable: true,
        capabilities: [.copyWithinProvider],
        selectedItemCount: 1,
        canDuplicate: true,
        isLocalProvider: false)
    )
    #expect(model.isEnabled(.duplicateSelectedItem))
    #expect(!model.isEnabled(.revealInFinder))

    model.update(
      context: AppMenuContext(
        isBrowserAvailable: true,
        capabilities: [],
        selectedItemCount: 1,
        isLocalProvider: true)
    )
    #expect(!model.isEnabled(.duplicateSelectedItem))
    #expect(model.isEnabled(.revealInFinder))

    model.update(
      context: AppMenuContext(
        isBrowserAvailable: true,
        capabilities: [.copyWithinProvider],
        selectedItemCount: 0,
        canDuplicate: true,
        isLocalProvider: true)
    )
    #expect(!model.isEnabled(.duplicateSelectedItem))
    #expect(!model.isEnabled(.revealInFinder))
  }

  @Test
  func increaseAndDecreaseIconSizeAreEnabledOutsideIconViewMode() {
    let model = AppMenuModel()
    model.register(
      context: AppMenuContext(isBrowserAvailable: true)
    ) { _ in }

    #expect(model.isEnabled(.increaseIconSize))
    #expect(model.isEnabled(.decreaseIconSize))
  }

  @Test
  func serverConnectionBridgeInvokesRegisteredHandlerWithRequestedEntryMode() {
    let model = AppMenuModel()
    var requestedModes: [ConnectPanelEntryMode] = []
    model.registerConnectServer { requestedModes.append($0) }

    model.connectToServer(.list)
    model.connectToServer(.form(.sftp))

    #expect(requestedModes == [.list, .form(.sftp)])
  }

  @Test
  func serverConnectionBridgeDoesNothingBeforeRegistration() {
    let model = AppMenuModel()
    model.connectToServer(.list)
    // クラッシュせず何も起きなければ成功(未登録時のnilガード確認)
  }

  @Test
  func locationMenuEntriesAreEmptyBeforeRegistration() {
    let model = AppMenuModel()
    #expect(model.favoriteLocationMenuEntries.isEmpty)
    #expect(model.recentLocationMenuEntries.isEmpty)
  }

  @Test
  func locationMenuEntriesReflectRegisteredProviderAtCallTime() {
    let model = AppMenuModel()
    var favoriteTitles = ["最初のお気に入り"]
    var openedIDs: [String] = []
    model.registerLocationMenus(
      favorites: {
        favoriteTitles.map { title in
          AppMenuLocationEntry(id: title, title: title) { openedIDs.append(title) }
        }
      },
      recents: { [] })

    #expect(model.favoriteLocationMenuEntries.map(\.title) == ["最初のお気に入り"])

    // 取得はクロージャ経由の都度評価であることの確認(登録後にソースを変えても反映される)
    favoriteTitles.append("追加されたお気に入り")
    let expectedTitles = ["最初のお気に入り", "追加されたお気に入り"]
    #expect(model.favoriteLocationMenuEntries.map(\.title) == expectedTitles)

    model.favoriteLocationMenuEntries.first?.open()
    #expect(openedIDs == ["最初のお気に入り"])
  }

  @Test
  func contextUpdatesRefreshAvailabilityWithoutReplacingTheHandler() {
    let model = AppMenuModel()
    var issuedCount = 0
    model.register(context: AppMenuContext(isBrowserAvailable: true)) { _ in
      issuedCount += 1
    }

    model.update(
      context: AppMenuContext(
        isBrowserAvailable: true,
        selectedItemCount: 2,
        displayedItemCount: 2)
    )
    model.perform(.copy)

    #expect(model.isEnabled(.selectAll))
    #expect(issuedCount == 1)
  }

  @Test("Quick Openの目録には実行可能なコマンドだけを載せる")
  func quickOpenInventoryContainsOnlyEnabledCommands() {
    let model = AppMenuModel()
    model.register(
      context: AppMenuContext(
        isBrowserAvailable: true,
        displayedItemCount: 2,
        canGoBack: true,
        canGoForward: false)
    ) { _ in }

    let identifiers = Set(model.quickOpenCommandItems.map(\.id))
    #expect(identifiers.contains(AppMenuItem.goBack.rawValue))
    #expect(identifiers.contains(AppMenuItem.selectAll.rawValue))
    #expect(!identifiers.contains(AppMenuItem.goForward.rawValue))
    #expect(!identifiers.contains(AppMenuItem.copy.rawValue))
  }

  @Test("Quick Openのコマンド候補は既存メニュー実行経路へ委譲する")
  func quickOpenCommandUsesExistingMenuDispatcher() {
    let model = AppMenuModel()
    var actions: [FileBrowserCommand.Action] = []
    model.register(context: AppMenuContext(isBrowserAvailable: true)) {
      actions.append($0)
    }

    model.performQuickOpenCommand(id: AppMenuItem.refresh.rawValue)
    model.performQuickOpenCommand(id: "存在しないコマンド")

    #expect(actions.count == 1)
    if case .refresh = actions.first {
    } else {
      Issue.record("更新コマンドの既存実行経路へ委譲されていません")
    }
  }

  @Test("Quick Open表示は登録後だけ発火し解除後は何もしない")
  func quickOpenPresentationBridgeFollowsRegistration() {
    let model = AppMenuModel()
    var presentationCount = 0

    model.showQuickOpen()
    model.registerQuickOpen { presentationCount += 1 }
    #expect(model.canShowQuickOpen)
    model.showQuickOpen()
    model.unregisterQuickOpen()
    model.showQuickOpen()

    #expect(presentationCount == 1)
    #expect(!model.canShowQuickOpen)
  }

  @Test("転送履歴表示は登録後だけ発火し解除後は何もしない")
  func transferLogPresentationBridgeFollowsRegistration() {
    let model = AppMenuModel()
    var presentationCount = 0

    model.showTransferLog()
    model.registerTransferLog { presentationCount += 1 }
    #expect(model.canShowTransferLog)
    model.showTransferLog()
    model.unregisterTransferLog()
    model.showTransferLog()

    #expect(presentationCount == 1)
    #expect(!model.canShowTransferLog)
  }
}
