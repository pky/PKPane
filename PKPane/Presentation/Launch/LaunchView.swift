import AppKit
import SwiftUI

private struct SFTPConnectionEditing: Identifiable {
  let id = UUID()
  let target: SFTPConnectionTarget
}

private struct FTPConnectionEditing: Identifiable {
  let id = UUID()
  let target: FTPConnectionTarget
}

struct LaunchView: View {
  @Environment(\.themePalette) private var themePalette
  @Environment(\.openWindow) private var openWindow
  private let initialFolderRequest: FolderWindowRequest?
  private let content: LaunchContent
  private let appMenuModel: AppMenuModel
  private let displayOptionsStore: FileBrowserDisplayOptionsStore
  private let applicationOpenRequestStore: ApplicationOpenRequestStore
  @State private var folderSelection: FolderSelectionModel
  @State private var nasConnections = NASConnectionListModel()
  @State private var providerConnectionLifecycle: FileProviderConnectionLifecycle
  @State private var sftpConnections: SFTPConnectionListModel
  @State private var sftpCredentialPrompter: SFTPCredentialPromptCoordinator
  @State private var ftpConnections: FTPConnectionListModel
  @State private var favoriteSyncIntegration: FavoriteSyncIntegrationController?
  @State private var sidebarPlaces = SidebarPlaceListModel()
  @State private var sidebarTags = SidebarTagListModel()
  @State private var sidebarSectionExpansion = SidebarSectionExpansionModel()
  @State private var favoriteOrder = SidebarFavoriteOrderModel()
  @State private var windowMenuOwnerID = UUID()
  @State private var targetedFavoriteInsertionID: String?
  @State private var providerBrowser: ProviderBrowserSession?
  @State private var providerBrowserLocation: FileLocation?
  @State private var providerBrowserCommand: FileBrowserCommand?
  @State private var providerBrowserViewMode: FileBrowserViewMode
  @State private var workspacePersistence: WorkspacePersistenceController
  @State private var pendingSFTPHostKeyApproval: SFTPHostKeyApproval?
  @State private var editingSFTPConnection: SFTPConnectionEditing?
  @State private var editingFTPConnection: FTPConnectionEditing?
  @State private var editingNASProfile: NASConnectionProfile?
  @State private var isPresentingConnectPanel = false
  @State private var connectPanelEntryMode: ConnectPanelEntryMode = .list
  @State private var isPresentingQuickOpen = false
  @State private var isPresentingKeyboardShortcuts = false
  @State private var transferLogPresentation = TransferLogPresentationState()
  @State private var sidebarPlaceErrorMessage: String?
  @State private var highlightedSidebarTransferDestinationID: String?
  @State private var isFavoriteRegistrationTargeted = false
  @State private var pendingMountedSMBVolumes: [SMBMountedVolume] = []
  /// 接続パネルで選ばれた接続先。シートが閉じきってから接続を始める(資格情報ダイアログや
  /// 共有選択が閉じかけのシートと重なって潰れないようにする)。
  @State private var pendingConnectPanelConnection: ConnectPanelPendingConnection?
  /// 取り出し実行中のSidebarPlace.id。連打による多重ejectと、1回目成功後の2回目失敗が
  /// 誤ったエラー表示になるのを防ぐ。
  @State private var ejectingPlaceIDs: Set<String> = []

  init(
    content: LaunchContent = .initial,
    initialFolderRequest: FolderWindowRequest? = nil,
    appMenuModel: AppMenuModel = AppMenuModel(),
    displayOptionsStore: FileBrowserDisplayOptionsStore = FileBrowserDisplayOptionsStore(),
    workspacePersistence: WorkspacePersistenceController? = nil,
    applicationOpenRequestStore: ApplicationOpenRequestStore = ApplicationOpenRequestStore()
  ) {
    self.initialFolderRequest = initialFolderRequest
    self.content = content
    self.appMenuModel = appMenuModel
    self.displayOptionsStore = displayOptionsStore
    self.applicationOpenRequestStore = applicationOpenRequestStore
    _providerBrowserViewMode = State(initialValue: displayOptionsStore.load().viewMode)
    _workspacePersistence = State(
      initialValue: workspacePersistence
        ?? WorkspacePersistenceController(
          store: initialFolderRequest?.workspaceStore() ?? JSONWorkspaceStateStore()))
    let connectionLifecycle = FileProviderConnectionLifecycle()
    let folderSelection = FolderSelectionModel(
      repository: FolderBookmarkRepository(
        storage: UserDefaultsFolderBookmarkStore(
          key: initialFolderRequest?.selectedFolderBookmarkKey ?? "selected-folder-bookmark"),
        codec: SystemFolderBookmarkCodec()))
    let credentialPrompter = SFTPCredentialPromptCoordinator()
    let sftpConnections = SFTPConnectionListModel(
      connectionService: SFTPConnectionListModel.defaultConnectionService(
        credentialPrompter: credentialPrompter),
      connectionLifecycle: connectionLifecycle)
    _sftpCredentialPrompter = State(initialValue: credentialPrompter)
    let favoriteSyncIntegration = FavoriteSyncCoordinatorFactory.makeIfAvailable().map {
      FavoriteSyncIntegrationController(
        coordinator: $0,
        folderSelection: folderSelection,
        sftpConnections: sftpConnections)
    }
    _folderSelection = State(initialValue: folderSelection)
    _providerConnectionLifecycle = State(initialValue: connectionLifecycle)
    _nasConnections = State(
      initialValue: NASConnectionListModel(connectionLifecycle: connectionLifecycle))
    _sftpConnections = State(initialValue: sftpConnections)
    _ftpConnections = State(
      initialValue: FTPConnectionListModel(connectionLifecycle: connectionLifecycle))
    _favoriteSyncIntegration = State(initialValue: favoriteSyncIntegration)
  }

  var body: some View {
    let displayedContent = content(for: folderSelection.selectedFolderURL)

    NavigationSplitView {
      sidebar
    } detail: {
      if let providerBrowser {
        ProviderBrowserView(
          title: providerBrowser.title,
          workspace: providerBrowser.workspace,
          command: $providerBrowserCommand,
          browserViewMode: providerBrowserViewModeBinding,
          showsSecondaryPane: Binding(
            get: { self.providerBrowser?.showsSecondaryPane ?? false },
            set: { self.providerBrowser?.showsSecondaryPane = $0 }),
          detailsDisplayMode: Binding(
            get: { self.providerBrowser?.detailsDisplayMode ?? .none },
            set: { self.providerBrowser?.detailsDisplayMode = $0 }),
          detailsInspectorWidth: Binding(
            get: { self.providerBrowser?.detailsInspectorWidth ?? 260 },
            set: { self.providerBrowser?.detailsInspectorWidth = $0 }),
          displayOptionsStore: displayOptionsStore,
          transferDestinationSections: { workspace in
            transferDestinationSections(for: workspace)
          },
          favoriteContextMenuItem: { items, browser in
            favoriteContextMenuItem(for: items, browser: browser)
          },
          requestFolderAccess: {
            folderSelection.chooseFolder(onSelected: openLocalBrowser)
          },
          onLocationChanged: handleProviderBrowserLocationChanged)
      } else {
        localBrowserDetail(content: displayedContent)
      }
    }
    .navigationTitle(displayedContent.windowTitle)
    .toolbar {
      if providerBrowser != nil {
        providerBrowserToolbarControls
      }
    }
    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    // 最小サイズ。初期サイズは PKPaneApp.defaultSize(1200x760) が別に定める
    .frame(minWidth: 800, minHeight: 520)
    .background {
      KeyboardCommandMonitor { command in
        handleKeyboardCommand(command)
      }
      WindowToolbarSeparatorConfigurator()
      WindowMenuActivationObserver(activated: registerAppMenuForCurrentWindow)
    }
    .onChange(of: appMenuContext) { _, context in
      appMenuModel.update(context: context, ownerID: windowMenuOwnerID)
    }
    .onDisappear {
      if appMenuModel.isRegisteredWindow(ownerID: windowMenuOwnerID) {
        appMenuModel.unregister(ownerID: windowMenuOwnerID)
        appMenuModel.unregisterQuickOpen()
        appMenuModel.unregisterTransferLog()
        appMenuModel.unregisterKeyboardShortcuts()
      }
      sidebarPlaces.stop()
      sidebarTags.stop()
    }
    .task {
      if let workspace = providerBrowser?.workspace {
        workspace.recordPaneDiagnostic("起動タスク再入")
      } else {
        AppLog.notice("起動タスク開始 ワークスペースなし", category: "PaneLayout")
      }
      sidebarTags.start()
      sidebarTags.updateAssignedTagNames(loadedFinderTagNames)
      await Task.yield()
      folderSelection.restoreSavedFolder(requestHomeAccess: initialFolderRequest == nil)
      sidebarPlaces.start()
      favoriteSyncIntegration?.start()
      if let initialFolderRequest {
        // 追加ウインドウは専用保存先だけを復元し、元の2ペイン構成を読み書きしない。
        if !restoreSavedWorkspace() {
          folderSelection.openLocalFolder(at: initialFolderRequest.resolvedURL()) { url in
            if SMBSharePath(folderURL: url) != nil {
              openMountedFolder(url)
            } else {
              openLocalBrowser(at: url)
            }
          }
        }
      } else if !restoreSavedWorkspace(),
        let selectedFolderURL = folderSelection.selectedFolderURL
      {
        openLocalBrowser(at: selectedFolderURL)
      }
      applicationOpenRequestStore.completeWorkspaceRestoration()
      applyPendingApplicationOpenRequests()
    }
    .onChange(of: applicationOpenRequestStore.revision) { _, _ in
      applyPendingApplicationOpenRequests()
    }
    .onChange(of: loadedFinderTagNames) { _, tagNames in
      sidebarTags.updateAssignedTagNames(tagNames)
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) {
      _ in
      if let workspace = providerBrowser?.workspace {
        workspacePersistence.saveNow(workspace)
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    {
      _ in
      appMenuModel.invalidateOpenWithApplications()
      appMenuModel.update(context: appMenuContext, ownerID: windowMenuOwnerID)
      providerBrowser?.workspace.recordPaneDiagnostic("アプリ前景復帰")
      providerBrowser?.workspace.revalidateDisplayedLocations()
    }
    .onReceive(
      NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)
    ) {
      _ in
      providerBrowser?.workspace.recordPaneDiagnostic("アプリ背景移行")
    }
    .onChange(of: nasConnections.lastUnmountedVolumeURL) { _, volumeURL in
      guard let volumeURL else { return }
      folderSelection.dismissMountedFolder(at: volumeURL)
    }
    .onChange(of: providerConnectionLifecycle.latestDisconnection) { _, disconnection in
      guard let disconnection else { return }
      dismissProviderBrowser(for: disconnection.connectionID)
    }
    .onChange(of: sftpConnections.pendingHostKeys) { _, pendingHostKeys in
      guard pendingSFTPHostKeyApproval == nil,
        let pendingHostKey = pendingHostKeys.first
      else { return }
      pendingSFTPHostKeyApproval = SFTPHostKeyApproval(
        target: pendingHostKey.key,
        request: pendingHostKey.value)
    }
    .sheet(item: $editingSFTPConnection) { editing in
      SFTPConnectionFormView(
        target: editing.target,
        title: "SFTP接続を編集",
        confirmationTitle: "保存"
      ) { _ in
        sftpConnections.reload()
      }
    }
    .sheet(item: $editingFTPConnection) { editing in
      FTPConnectionFormView(
        target: editing.target,
        title: "FTP/FTPS接続を編集",
        confirmationTitle: "保存"
      ) { _ in
        ftpConnections.reload()
      }
    }
    .alert(item: $pendingSFTPHostKeyApproval) { approval in
      Alert(
        title: Text(approval.alertTitle),
        message: Text(approval.alertMessage),
        primaryButton: .default(Text(approval.confirmationTitle)) {
          if approval.isUpdate {
            sftpConnections.approveChangedHostKey(for: approval.target)
          } else {
            sftpConnections.approveHostKey(for: approval.target)
          }
        },
        secondaryButton: .cancel(Text("キャンセル")))
    }
    .modifier(SFTPCredentialPromptPresentation(coordinator: sftpCredentialPrompter))
    .sheet(isPresented: $isPresentingQuickOpen, onDismiss: openPendingConnectPanelConnection) {
      QuickOpenView(
        candidates: quickOpenCandidates,
        execute: executeQuickOpenCandidate,
        cancel: { isPresentingQuickOpen = false })
    }
    .sheet(isPresented: $isPresentingKeyboardShortcuts) {
      KeyboardShortcutListView(entries: appMenuModel.keyboardShortcutEntries)
    }
    .sheet(
      isPresented: Binding(
        get: { transferLogPresentation.isPresented },
        set: { if !$0 { transferLogPresentation.dismiss() } })
    ) {
      TransferLogView(model: transferLogPresentation.model)
    }
    .sheet(isPresented: $isPresentingConnectPanel, onDismiss: openPendingConnectPanelConnection) {
      ConnectPanelView(
        entryMode: connectPanelEntryMode,
        nasConnections: nasConnections,
        sftpConnections: sftpConnections,
        ftpConnections: ftpConnections,
        onSavedNAS: { profile in
          for step in ConnectPanelSaveAction.actions(for: .nas) {
            switch step {
            case .reloadList:
              break
            case .connectAfterDismiss:
              pendingConnectPanelConnection = .nas(profile, savesProfile: true)
            }
          }
        },
        onSavedSFTP: { target in
          for step in ConnectPanelSaveAction.actions(for: .sftp) {
            switch step {
            case .reloadList:
              sftpConnections.reload()
            case .connectAfterDismiss:
              pendingConnectPanelConnection = .sftp(target)
            }
          }
        },
        onSavedFTP: { target in
          for step in ConnectPanelSaveAction.actions(for: .ftp) {
            switch step {
            case .reloadList:
              ftpConnections.reload()
            case .connectAfterDismiss:
              pendingConnectPanelConnection = .ftp(target)
            }
          }
        },
        onConnectNAS: { profile in
          pendingConnectPanelConnection = .nas(profile, savesProfile: false)
        },
        onConnectSFTP: { target in pendingConnectPanelConnection = .sftp(target) },
        onConnectFTP: { target in pendingConnectPanelConnection = .ftp(target) },
        onEditNAS: { profile in editingNASProfile = profile },
        onEditSFTP: { target in editingSFTPConnection = SFTPConnectionEditing(target: target) },
        onEditFTP: { target in editingFTPConnection = FTPConnectionEditing(target: target) })
    }
    .confirmationDialog(
      "共有フォルダを選択",
      isPresented: Binding(
        get: { !pendingMountedSMBVolumes.isEmpty },
        set: { if !$0 { pendingMountedSMBVolumes = [] } }),
      titleVisibility: .visible
    ) {
      ForEach(pendingMountedSMBVolumes, id: \.volumeURL) { volume in
        Button(volume.volumeURL.lastPathComponent) {
          openMountedFolder(SavedMountedFolder(volume: volume, folderURL: volume.volumeURL))
          pendingMountedSMBVolumes = []
        }
      }
    }
    .sheet(item: $editingNASProfile) { profile in
      NASConnectionFormView(
        profile: profile,
        title: "NAS接続を編集",
        confirmationTitle: "保存"
      ) { updatedProfile in
        nasConnections.update(updatedProfile)
      }
    }
  }

  @ToolbarContentBuilder
  private var providerBrowserToolbarControls: some ToolbarContent {
    if providerBrowser?.workspace.activeTab.browser.connectionID != nil {
      ToolbarItem(placement: .cancellationAction) {
        Button("閉じる", systemImage: "xmark.circle", action: closeProviderBrowser)
          .help("接続を閉じる")
      }
    }
    ToolbarItemGroup {
      Button("戻る", systemImage: "chevron.backward") {
        providerBrowserCommand = FileBrowserCommand(action: .goBack)
      }
      .help("戻る")
      Button("進む", systemImage: "chevron.forward") {
        providerBrowserCommand = FileBrowserCommand(action: .goForward)
      }
      .help("進む")
      Button("親フォルダ", systemImage: "chevron.up") {
        providerBrowserCommand = FileBrowserCommand(action: .openParent)
      }
      .disabled(providerBrowser?.workspace.activeTab.browser.isRecentFilesActive == true)
      .help("親フォルダへ")
    }
    ToolbarItemGroup {
      viewMenu
      actionMenu
    }
    ToolbarItemGroup {
      Button("Quick Look", systemImage: "eye") {
        providerBrowserCommand = FileBrowserCommand(action: .previewSelectedItem)
      }
      .help("Quick Look")
      if providerBrowser?.showsSecondaryPane ?? false {
        Button("反対側へコピー", systemImage: "arrow.right.doc.on.clipboard") {
          providerBrowserCommand = FileBrowserCommand(action: .copyToOppositePane)
        }
        .disabled(!(providerBrowser?.workspace.canCopySelectedItemsToOppositePane ?? false))
        .help("反対側のペインへコピー")
        Button("反対側へ移動", systemImage: "arrow.right.square") {
          providerBrowserCommand = FileBrowserCommand(action: .moveToOppositePane)
        }
        .disabled(!(providerBrowser?.workspace.canMoveSelectedItemsToOppositePane ?? false))
        .help("反対側のペインへ移動")
      }
    }
    ToolbarItemGroup {
      let activeBrowser = providerBrowser?.workspace.activeTab.browser
      let selectedItemCount = providerBrowser?.workspace.activeTab.selectedItemURLs.count ?? 0
      let canDeleteSelectedItem =
        activeBrowser?.executableCapabilities
        .intersection([.trash, .deletePermanently])
        .isEmpty == false
      let deleteTitle =
        if activeBrowser?.executableCapabilities.contains(.trash) == true {
          "ゴミ箱へ移動"
        } else if activeBrowser?.executableCapabilities.contains(.deletePermanently) == true {
          "完全に削除…"
        } else {
          "削除"
        }
      Button(
        deleteTitle,
        systemImage: "trash", role: .destructive
      ) {
        providerBrowserCommand = FileBrowserCommand(action: .deleteSelectedItem)
      }
      .disabled(selectedItemCount != 1 || !canDeleteSelectedItem)
      .help(
        activeBrowser?.executableCapabilities.contains(.deletePermanently) == true
          && activeBrowser?.executableCapabilities.contains(.trash) != true
          ? "完全に削除すると元に戻せません" : deleteTitle)
      Button("更新", systemImage: "arrow.clockwise") {
        providerBrowserCommand = FileBrowserCommand(action: .refresh)
      }
      .help("更新")
    }
    ToolbarItem {
      let showsSecondaryPane = providerBrowser?.showsSecondaryPane ?? false
      Button(
        showsSecondaryPane ? "1ペイン" : "2ペイン",
        systemImage: showsSecondaryPane ? "rectangle" : "rectangle.split.2x1"
      ) {
        guard let workspace = providerBrowser?.workspace else { return }
        workspace.setShowsSecondaryPane(
          !workspace.showsSecondaryPane,
          source: "ツールバー \(PaneInputDiagnostic.currentEvent)")
      }
      .help(showsSecondaryPane ? "1ペイン表示へ切り替える" : "左右2ペイン表示へ切り替える")
    }
    if let providerBrowser {
      @Bindable var browser = providerBrowser
      ToolbarItem {
        DetailsDisplayToolbarToggle(mode: $browser.detailsDisplayMode)
      }
    }
  }

  private var providerBrowserViewModeBinding: Binding<FileBrowserViewMode> {
    Binding(
      get: { currentBrowserViewMode },
      set: { providerBrowserViewMode = $0 })
  }

  private var currentBrowserViewMode: FileBrowserViewMode {
    providerBrowser?.workspace.activeTab.viewMode ?? providerBrowserViewMode
  }

  private func handleProviderBrowserLocationChanged(_ location: FileLocation) {
    providerBrowserLocation = location
    folderSelection.recordRecentLocation(location)
    if let workspace = providerBrowser?.workspace {
      workspacePersistence.scheduleSave(of: workspace)
    }
  }

  private var viewMenu: some View {
    Menu {
      Picker(
        "表示形式",
        selection: Binding(
          get: { currentBrowserViewMode },
          set: { mode in
            providerBrowserViewMode = mode
            providerBrowserCommand = FileBrowserCommand(action: .setBrowserViewMode(mode))
          })
      ) {
        ForEach(FileBrowserViewMode.selectableCases) { mode in
          Label(mode.displayName, systemImage: mode.systemImageName)
            .tag(mode)
        }
      }
      .pickerStyle(.inline)
      Divider()
      Picker(
        "並べ替え",
        selection: Binding(
          get: { providerBrowser?.workspace.activeTab.sortOrder ?? .name },
          set: { order in
            providerBrowser?.workspace.setSortOrder(order)
          })
      ) {
        ForEach(FileItemSortOrder.allCases) { Text($0.displayName).tag($0) }
      }
      .pickerStyle(.inline)
      Button(
        providerBrowser?.workspace.activeTab.sortAscending == true ? "降順にする" : "昇順にする"
      ) {
        providerBrowser?.workspace.toggleSortDirection()
      }
      Divider()
      Button("表示オプション...") {
        providerBrowserCommand = FileBrowserCommand(action: .showDisplayOptions)
      }
      Divider()
      Button {
        guard let providerBrowser else { return }
        providerBrowser.detailsDisplayMode = providerBrowser.detailsDisplayMode.togglingPane
      } label: {
        if providerBrowser?.detailsDisplayMode == .pane {
          Label("詳細を表示", systemImage: "checkmark")
        } else {
          Text("詳細を表示")
        }
      }
    } label: {
      Label("表示", systemImage: "eye.circle")
    }
    .help("表示形式・並べ替え・表示オプション")
    .accessibilityIdentifier("provider-browser-view-menu")
  }

  private var actionMenu: some View {
    let selectedItemCount = providerBrowser?.workspace.activeTab.selectedItemURLs.count ?? 0
    return Menu {
      Button("新規フォルダ", systemImage: "folder.badge.plus") {
        providerBrowserCommand = FileBrowserCommand(action: .createDirectory)
      }
      .disabled(
        providerBrowser?.workspace.activeTab.browser.executableCapabilities.contains(.write)
          != true
          || providerBrowser?.workspace.activeTab.browser.isRecentFilesActive == true
      )
      .accessibilityIdentifier("provider-browser-new-folder")
      Button("リネーム") {
        providerBrowserCommand = FileBrowserCommand(action: .renameSelectedItem)
      }
      .disabled(
        providerBrowser?.workspace.activeTab.browser.executableCapabilities.contains(.rename)
          != true
      )
      Button("情報を見る") {
        providerBrowserCommand = FileBrowserCommand(action: .showSelectedItemInfo)
      }
      Divider()
      Button("コピー") { providerBrowserCommand = FileBrowserCommand(action: .copy) }
      Button("カット") { providerBrowserCommand = FileBrowserCommand(action: .cut) }
        .disabled(providerBrowser?.workspace.activeTab.browser.canRemoveItemsAfterCopy != true)
      Button("ペースト") { providerBrowserCommand = FileBrowserCommand(action: .paste) }
        .disabled(
          providerBrowser.map {
            !$0.workspace.canPasteItems(to: $0.workspace.activeTab.browser)
          } ?? true)
      Divider()
      Button("コピー先を選択...") {
        providerBrowserCommand = FileBrowserCommand(
          action: .chooseTransferDestination(movesItems: false))
      }
      .disabled(selectedItemCount == 0)
      Button("移動先を選択...") {
        providerBrowserCommand = FileBrowserCommand(
          action: .chooseTransferDestination(movesItems: true))
      }
      .disabled(
        selectedItemCount == 0
          || providerBrowser?.workspace.activeTab.browser.canRemoveItemsAfterCopy != true)
      Button("取り消す") {
        providerBrowserCommand = FileBrowserCommand(action: .undoLastTransfer)
      }
      .disabled(!(providerBrowser?.workspace.canUndoLastTransfer ?? false))
      Button("転送を再試行") {
        providerBrowserCommand = FileBrowserCommand(action: .retryLastTransfer)
      }
      .disabled(!(providerBrowser?.workspace.activeTab.browser.canRetryLastTransfer ?? false))
      if SidebarCurrentLocationActionPolicy.canTargetCurrentFolder(
        isRecentFilesActive: providerBrowser?.workspace.activeTab.browser.isRecentFilesActive
          == true)
      {
        if let sftpTarget = providerBrowser?.activeSFTPTarget,
          let directory = providerBrowserLocation?.remotePath
        {
          let isFavorite = sftpConnections.isFavorite(target: sftpTarget, directory: directory)
          Divider()
          Button(
            isFavorite ? "お気に入りから削除" : "お気に入りに追加",
            systemImage: isFavorite ? "star.fill" : "star"
          ) {
            SidebarCurrentLocationActionPolicy.performFavoriteToggle(
              isRecentFilesActive: providerBrowser?.workspace.activeTab.browser.isRecentFilesActive
                == true
            ) {
              sftpConnections.toggleFavorite(target: sftpTarget, directory: directory)
            }
          }
          .accessibilityIdentifier("sftp-folder-favorite")
        } else if let ftpTarget = providerBrowser?.activeFTPTarget,
          let directory = providerBrowserLocation?.remotePath
        {
          let isFavorite = ftpConnections.isFavorite(target: ftpTarget, directory: directory)
          Divider()
          Button(
            isFavorite ? "お気に入りから削除" : "お気に入りに追加",
            systemImage: isFavorite ? "star.fill" : "star"
          ) {
            SidebarCurrentLocationActionPolicy.performFavoriteToggle(
              isRecentFilesActive: providerBrowser?.workspace.activeTab.browser.isRecentFilesActive
                == true
            ) {
              ftpConnections.toggleFavorite(target: ftpTarget, directory: directory)
            }
          }
          .accessibilityIdentifier("ftp-folder-favorite")
        } else if let localURL = providerBrowserLocation?.localURL,
          providerBrowser?.activeSFTPTarget == nil
        {
          let isFavorite = folderSelection.isFavorite(url: localURL)
          Divider()
          Button(
            isFavorite ? "お気に入りから削除" : "お気に入りに追加",
            systemImage: isFavorite ? "star.fill" : "star"
          ) {
            SidebarCurrentLocationActionPolicy.performFavoriteToggle(
              isRecentFilesActive: providerBrowser?.workspace.activeTab.browser.isRecentFilesActive
                == true
            ) {
              folderSelection.toggleFavorite(url: localURL)
            }
          }
          .accessibilityIdentifier("local-folder-favorite")
        }
      }
    } label: {
      Label("操作", systemImage: "ellipsis.circle")
    }
    .help("ファイル操作・タブ・転送")
    .accessibilityIdentifier("provider-browser-action-menu")
  }

  private func favoriteContextMenuItem(
    for items: [FileItem],
    browser: FileBrowserSession
  ) -> FileContextMenuItem? {
    guard !items.isEmpty else { return nil }

    if let target = providerBrowser?.sftpTarget(for: browser.providerID) {
      let directories = items.compactMap(\.location.remotePath)
      guard directories.count == items.count else { return nil }
      let allAreFavorites = directories.allSatisfy {
        sftpConnections.isFavorite(target: target, directory: $0)
      }
      return FileContextMenuItem(
        title: allAreFavorites ? "お気に入りから削除" : "お気に入りに追加",
        systemImage: allAreFavorites ? "star.slash" : "star"
      ) {
        for directory in directories
        where sftpConnections.isFavorite(target: target, directory: directory) == allAreFavorites {
          sftpConnections.toggleFavorite(target: target, directory: directory)
        }
      }
    }

    if let target = providerBrowser?.ftpTarget(for: browser.providerID) {
      let directories = items.compactMap(\.location.remotePath)
      guard directories.count == items.count else { return nil }
      let allAreFavorites = directories.allSatisfy {
        ftpConnections.isFavorite(target: target, directory: $0)
      }
      return FileContextMenuItem(
        title: allAreFavorites ? "お気に入りから削除" : "お気に入りに追加",
        systemImage: allAreFavorites ? "star.slash" : "star"
      ) {
        for directory in directories
        where ftpConnections.isFavorite(target: target, directory: directory) == allAreFavorites {
          ftpConnections.toggleFavorite(target: target, directory: directory)
        }
      }
    }

    guard let directories = FavoriteContextMenuTargetResolver.localDirectoryURLs(for: items)
    else { return nil }
    let allAreFavorites = directories.allSatisfy { folderSelection.isFavorite(url: $0) }
    return FileContextMenuItem(
      title: allAreFavorites ? "お気に入りから削除" : "お気に入りに追加",
      systemImage: allAreFavorites ? "star.slash" : "star"
    ) {
      for directory in directories
      where folderSelection.isFavorite(url: directory) == allAreFavorites {
        folderSelection.toggleFavorite(url: directory)
      }
    }
  }

  private func selectedFolderFavoriteState(
    for items: [FileItem],
    browser: FileBrowserSession
  ) -> Bool? {
    guard !items.isEmpty, items.allSatisfy(\.isDirectory) else { return nil }
    if let target = providerBrowser?.sftpTarget(for: browser.providerID) {
      let directories = items.compactMap(\.location.remotePath)
      guard directories.count == items.count else { return nil }
      return directories.allSatisfy {
        sftpConnections.isFavorite(target: target, directory: $0)
      }
    }
    if let target = providerBrowser?.ftpTarget(for: browser.providerID) {
      let directories = items.compactMap(\.location.remotePath)
      guard directories.count == items.count else { return nil }
      return directories.allSatisfy {
        ftpConnections.isFavorite(target: target, directory: $0)
      }
    }
    guard let directories = FavoriteContextMenuTargetResolver.localDirectoryURLs(for: items)
    else { return nil }
    return directories.allSatisfy { folderSelection.isFavorite(url: $0) }
  }

  enum FavoriteContextMenuTargetResolver {
    static func localDirectoryURLs(for items: [FileItem]) -> [URL]? {
      guard !items.isEmpty else { return nil }
      let directories = items.map(\.url)
      guard directories.allSatisfy(\.isFileURL) else { return nil }
      return directories
    }
  }

  private func localBrowserDetail(content: LaunchContent) -> some View {
    LaunchEmptyStateView(content: content) {
      folderSelection.chooseFolder(onSelected: openLocalBrowser)
    }
  }

  private func registerAppMenuForCurrentWindow() {
    folderSelection.reloadFavorites()
    sftpConnections.reload()
    ftpConnections.reload()
    appMenuModel.register(
      context: appMenuContext, perform: issueAppMenuCommand,
      canPaste: {
        providerBrowser.map { $0.workspace.canPasteItems(to: $0.workspace.activeTab.browser) }
          ?? false
      }, ownerID: windowMenuOwnerID)
    appMenuModel.registerConnectServer { entryMode in
      presentConnectPanel(entryMode: entryMode)
    }
    appMenuModel.registerLocationMenus(
      favorites: { appMenuFavoriteLocationEntries },
      recents: { appMenuRecentLocationEntries })
    appMenuModel.registerQuickOpen {
      isPresentingQuickOpen = true
    }
    appMenuModel.registerKeyboardShortcuts {
      isPresentingKeyboardShortcuts = true
    }
    transferLogPresentation.model.registerRetryHandler { job in
      providerBrowser?.workspace.retryTransferJob(job)
    }
    transferLogPresentation.model.registerResumeHandler { job in
      guard let workspace = providerBrowser?.workspace else { return false }
      return workspace.resumeTransferJob(job)
    }
    appMenuModel.registerTransferLog {
      transferLogPresentation.present()
    }
  }

  private var sidebar: some View {
    List {
      favoriteSection
      locationSection
      if SidebarTagSectionPresentation.isVisible(tags: sidebarTags.tags) {
        tagSection
      }
    }
    .listStyle(.sidebar)
    .scrollContentBackground(themePalette.sidebarBackground == nil ? .automatic : .hidden)
    .background {
      if let color = themePalette.sidebarBackground?.color {
        color.ignoresSafeArea()
      }
    }
    .environment(\.defaultMinListRowHeight, 24)
    .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
  }

  private var locationSection: some View {
    collapsibleSidebarSection("場所", section: .locations) {
      if let iCloudDrive = sidebarPlaces.iCloudDrive {
        sidebarPlaceRow(iCloudDrive)
      }
      ForEach(visibleSidebarPlaces) { place in
        sidebarPlaceRow(place)
      }
      ForEach(activeNASProfiles) { profile in
        nasConnectionRow(profile)
      }
      ForEach(nasConnections.unregisteredMountedVolumes, id: \.volumeURL) { volume in
        sharedVolumeRow(volume)
      }
      ForEach(activeFTPTargets, id: \.self) { target in
        ftpConnectionRow(target)
      }
      ForEach(activeSFTPTargets, id: \.self) { target in
        sftpConnectionRow(target)
      }
      Button {
        presentConnectPanel(entryMode: .list)
      } label: {
        sidebarItemLabel("ネットワーク", systemImage: "network")
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("sidebar-location-network")
      Button {
        folderSelection.openLocalFolder(at: trashDirectoryURL, onSelected: openLocalBrowser)
      } label: {
        sidebarItemLabel(
          "ゴミ箱",
          systemImage: "trash",
          isSelected: isSidebarLocationSelected(trashDirectoryURL))
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("sidebar-location-trash")
      if let sidebarPlaceErrorMessage {
        Text(sidebarPlaceErrorMessage)
          .foregroundStyle(themePalette.error)
      }
      if let errorMessage = nasConnections.errorMessage {
        Text(errorMessage)
          .foregroundStyle(themePalette.error)
      } else if let errorMessage = sftpConnections.errorMessage {
        Text(errorMessage)
          .foregroundStyle(themePalette.error)
      } else if let errorMessage = ftpConnections.errorMessage {
        Text(errorMessage)
          .foregroundStyle(themePalette.error)
      }
    }
  }

  private var favoriteSection: some View {
    collapsibleSidebarSection("よく使う項目", section: .favorites) {
      if !folderSelection.isFavorite(url: homeDirectoryURL) {
        Button {
          folderSelection.openLocalFolder(at: homeDirectoryURL, onSelected: openLocalBrowser)
        } label: {
          sidebarItemLabel(
            homeDirectoryURL.lastPathComponent,
            systemImage: "house",
            isSelected: isSidebarLocationSelected(homeDirectoryURL))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("sidebar-location-home")
      }
      if let accessRootURL = folderSelection.accessRootURL {
        if !folderSelection.isFavorite(url: accessRootURL)
          && accessRootURL.standardizedFileURL != homeDirectoryURL.standardizedFileURL
        {
          Button {
            folderSelection.openLocalFolder(at: accessRootURL, onSelected: openLocalBrowser)
          } label: {
            sidebarItemLabel(
              UserHomeDirectory.localizedStandardFolderName(for: accessRootURL)
                ?? FileManager.default.displayName(atPath: accessRootURL.path),
              systemImage: "folder",
              isSelected: isSidebarLocationSelected(accessRootURL))
          }
          .buttonStyle(.plain)
        }
      } else {
        Button {
          folderSelection.chooseFolder(onSelected: openLocalBrowser)
        } label: {
          sidebarItemLabel("フォルダを選択", systemImage: "folder.badge.plus")
        }
        .buttonStyle(.plain)
      }
      ForEach(orderedFavoriteIDs, id: \.self) { id in
        VStack(alignment: .leading, spacing: 0) {
          favoriteInsertionBoundary(before: id)
          favoriteRow(id: id)
            .onDrag { NSItemProvider(object: SidebarFavoriteOrderModel.dragURL(for: id) as NSURL) }
        }
      }
      favoriteRegistrationDropArea
      if let errorMessage = folderSelection.errorMessage {
        Text(errorMessage)
          .foregroundStyle(themePalette.error)
      }
      Button(action: openRecentFiles) {
        sidebarItemLabel(
          "最近の項目",
          systemImage: "clock",
          isSelected: providerBrowser?.workspace.activeTab.browser.isRecentFilesActive == true)
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("sidebar-recent-files")
    }
  }

  /// 既存の保存先行への転送と区別できる、お気に入り登録だけの領域。
  private var favoriteRegistrationDropArea: some View {
    VStack(spacing: 4) {
      Rectangle()
        .fill(isFavoriteRegistrationTargeted ? Color.accentColor : Color.clear)
        .frame(height: 2)
      Label("フォルダをここに追加", systemImage: "plus")
        .font(.caption)
        .foregroundStyle(isFavoriteRegistrationTargeted ? Color.accentColor : Color.secondary)
        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
    }
    .contentShape(Rectangle())
    .accessibilityIdentifier("sidebar-favorite-registration-drop-area")
    .help("フォルダをドロップして、よく使う項目に登録します")
    .dropDestination(for: URL.self) { urls, _ in
      registerDroppedFavorites(urls)
    } isTargeted: { targeted in
      isFavoriteRegistrationTargeted = targeted
    }
  }

  private func registerDroppedFavorites(_ urls: [URL]) -> Bool {
    // 登録経路から転送処理は呼ばない。ローカルは既存の実在フォルダ検証を使う。
    insertDroppedFavorites(urls, before: nil)
  }

  private var availableFavoriteIDs: [String] {
    folderSelection.favoriteLocations.map { "favorite-\($0.id.uuidString)" }
      + sftpConnections.favoriteFolders.map { "sftp-favorite-\($0.id.uuidString)" }
      + ftpConnections.favoriteFolders.map { "ftp-favorite-\($0.id.uuidString)" }
  }

  private var orderedFavoriteIDs: [String] {
    favoriteOrder.orderedIDs(available: availableFavoriteIDs)
  }

  @ViewBuilder
  private func favoriteRow(id: String) -> some View {
    if let location = folderSelection.favoriteLocations.first(where: {
      "favorite-\($0.id.uuidString)" == id
    }) {
      favoriteLocationButton(location, index: orderedFavoriteIDs.firstIndex(of: id) ?? 0)
    } else if let favorite = sftpConnections.favoriteFolders.first(where: {
      "sftp-favorite-\($0.id.uuidString)" == id
    }) {
      sftpFavoriteButton(favorite)
    } else if let favorite = ftpConnections.favoriteFolders.first(where: {
      "ftp-favorite-\($0.id.uuidString)" == id
    }) {
      ftpFavoriteButton(favorite)
    }
  }

  /// 行本体の転送先と重ならない、登録・並べ替え専用の挿入帯。
  private func favoriteInsertionBoundary(before id: String) -> some View {
    Rectangle()
      .fill(targetedFavoriteInsertionID == id ? Color.accentColor : Color.clear)
      .frame(height: 2)
      .frame(maxWidth: .infinity, minHeight: 8)
      .contentShape(Rectangle())
      .accessibilityIdentifier("sidebar-favorite-insertion-\(id)")
      .dropDestination(for: URL.self) { urls, _ in
        targetedFavoriteInsertionID = nil
        return insertDroppedFavorites(urls, before: id)
      } isTargeted: { targeted in
        if targeted {
          targetedFavoriteInsertionID = id
        } else if targetedFavoriteInsertionID == id {
          targetedFavoriteInsertionID = nil
        }
      }
  }

  private func insertDroppedFavorites(_ urls: [URL], before anchor: String?) -> Bool {
    favoriteOrder.performDrop(
      urls, before: anchor, available: { availableFavoriteIDs }, register: registerFavorite)
  }

  private func registerFavorite(_ url: URL) -> String? {
    if url.isFileURL {
      guard folderSelection.addFavorites(urls: [url]),
        let id = folderSelection.favoriteID(for: url)
      else { return nil }
      return "favorite-\(id.uuidString)"
    }
    guard let providerBrowser else { return nil }
    let snapshots = providerBrowser.workspace.tabs.map { $0.browser.selectableItemsSnapshot }
    guard
      let item = FavoriteDropTargetResolver.remoteFolders(
        urls: [url],
        lookup: { url in
          snapshots.lazy.compactMap { $0.item(for: url) }.first
        }
      ).first, let directory = item.location.remotePath
    else { return nil }
    if let target = providerBrowser.sftpTarget(for: item.location.providerID) {
      if !sftpConnections.isFavorite(target: target, directory: directory) {
        sftpConnections.toggleFavorite(target: target, directory: directory)
      }
      return sftpConnections.favoriteFolders.first {
        $0.target == target && $0.directory == directory
      }.map { "sftp-favorite-\($0.id.uuidString)" }
    }
    if let target = providerBrowser.ftpTarget(for: item.location.providerID) {
      if !ftpConnections.isFavorite(target: target, directory: directory) {
        ftpConnections.toggleFavorite(target: target, directory: directory)
      }
      return ftpConnections.favoriteFolders.first {
        $0.target == target
          && $0.directory == FTPConnectionTarget.normalizedAbsolutePath(directory)
      }.map { "ftp-favorite-\($0.id.uuidString)" }
    }
    return nil
  }

  enum FavoriteDropTargetResolver {
    static func remoteFolders(
      urls: [URL], lookup: (URL) -> FileItem?
    ) -> [FileItem] {
      urls.compactMap { url in
        guard !url.isFileURL, let item = lookup(url), item.isDirectory,
          item.location.remotePath != nil
        else { return nil }
        return item
      }
    }
  }

  private var tagSection: some View {
    collapsibleSidebarSection(
      LocalizedStringKey(SidebarTagSectionPresentation.sectionTitle),
      section: .tags
    ) {
      ForEach(sidebarTags.tags, id: \.name) { tag in
        Button {
          SidebarTagSearchAction.perform(
            tag: tag,
            browser: providerBrowser?.workspace.activeTab.browser)
        } label: {
          HStack(spacing: 7) {
            Circle()
              .fill(sidebarTagColor(tag.color))
              .frame(width: 10, height: 10)
              .accessibilityHidden(true)
            Text(tag.name)
              .lineLimit(1)
            Spacer(minLength: 0)
          }
          .padding(.horizontal, 6)
          .padding(.vertical, 1)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(!canSearchSidebarTags)
        .accessibilityIdentifier("sidebar-tag-\(tag.name)")
        .accessibilityLabel(
          SidebarTagSectionPresentation.accessibilityLabel(for: tag.name)
        )
        .help("\(tag.name)タグを検索")
      }
    }
  }

  private func ftpConnectionRow(_ target: FTPConnectionTarget) -> some View {
    HStack {
      Button {
        connectFTPFromConnectPanel(target)
      } label: {
        sidebarItemLabel(
          "\(target.username)@\(target.host):\(target.port)",
          systemImage: target.security == .plain ? "network" : "lock.shield")
      }
      .buttonStyle(.plain)
      .disabled(ftpConnections.isConnecting(target))
      if ftpConnections.isConnecting(target) {
        connectingIndicator
      } else if ftpConnections.isConnected(target) {
        Button {
          ftpConnections.disconnect(target)
        } label: {
          Image(systemName: "eject")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .fixedSize()
        .help("接続を解除")
        .accessibilityLabel("接続を解除")
      }
    }
    .contextMenu {
      Button("編集") {
        editingFTPConnection = FTPConnectionEditing(target: target)
      }
      Button("削除", role: .destructive) {
        ftpConnections.remove(target)
      }
    }
  }

  private func sftpConnectionRow(_ target: SFTPConnectionTarget) -> some View {
    HStack {
      Button {
        connectSFTPFromConnectPanel(target)
      } label: {
        sidebarItemLabel(
          "\(target.username)@\(target.host):\(target.port)",
          systemImage: "server.rack")
      }
      .buttonStyle(.plain)
      .disabled(sftpConnections.isConnecting(target))
      if sftpConnections.isConnecting(target) {
        connectingIndicator
      } else if sftpConnections.isConnected(target) {
        Button {
          sftpConnections.disconnect(target)
        } label: {
          Image(systemName: "eject")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .fixedSize()
        .help("接続を解除")
        .accessibilityLabel("接続を解除")
      } else if sftpConnections.pendingHostKey(for: target) != nil {
        Button("このサーバーを信頼") {
          guard let request = sftpConnections.pendingHostKeyRequest(for: target) else { return }
          pendingSFTPHostKeyApproval = SFTPHostKeyApproval(
            target: target,
            request: request)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
      } else if sftpConnections.changedHostKey(for: target) != nil {
        Button("ホスト鍵を更新") {
          guard let request = sftpConnections.changedHostKeyRequest(for: target) else { return }
          pendingSFTPHostKeyApproval = SFTPHostKeyApproval(
            target: target,
            request: request,
            isUpdate: true)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
      }
    }
    .contextMenu {
      Button("編集") {
        editingSFTPConnection = SFTPConnectionEditing(target: target)
      }
      Button("削除", role: .destructive) {
        sftpConnections.remove(target)
      }
    }
  }

  private var activeSFTPTargets: [SFTPConnectionTarget] {
    let actionRequired = Set(sftpConnections.pendingHostKeys.keys)
      .union(sftpConnections.changedHostKeys.keys)
    let activeRemainder = sftpConnections.connectedTargets
      .union(sftpConnections.connectingTargets)
      .union(actionRequired)
      .sorted {
        SFTPFileProvider.connectionID(for: $0).rawValue
          < SFTPFileProvider.connectionID(for: $1).rawValue
      }
    return SidebarActiveConnectionProjection.activeTargets(
      ordered: sftpConnections.targets,
      additionalOrder: sftpConnections.favoriteFolders.map(\.target)
        + sftpConnections.recentFolders.map(\.target),
      activeRemainder: activeRemainder,
      connected: sftpConnections.connectedTargets,
      connecting: sftpConnections.connectingTargets,
      actionRequired: actionRequired)
  }

  private var activeFTPTargets: [FTPConnectionTarget] {
    let activeRemainder = ftpConnections.connectedTargets
      .union(ftpConnections.connectingTargets)
      .sorted {
        FTPFileProvider.connectionID(for: $0).rawValue
          < FTPFileProvider.connectionID(for: $1).rawValue
      }
    return SidebarActiveConnectionProjection.activeTargets(
      ordered: ftpConnections.targets,
      additionalOrder: ftpConnections.favoriteFolders.map(\.target)
        + ftpConnections.recentFolders.map(\.target),
      activeRemainder: activeRemainder,
      connected: ftpConnections.connectedTargets,
      connecting: ftpConnections.connectingTargets)
  }

  private var activeNASProfiles: [NASConnectionProfile] {
    nasConnections.profiles.filter { profile in
      if case .connected = nasConnections.status(for: profile) {
        return true
      }
      return nasConnections.isConnecting(profile)
    }
  }

  private var homeDirectoryURL: URL {
    UserHomeDirectory.current
  }

  private var trashDirectoryURL: URL {
    FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first
      ?? homeDirectoryURL.appending(path: ".Trash", directoryHint: .isDirectory)
  }

  private func collapsibleSidebarSection<Content: View>(
    _ title: LocalizedStringKey,
    section: SidebarSectionExpansionModel.SectionID,
    @ViewBuilder content: () -> Content
  ) -> some View {
    Section {
      if sidebarSectionExpansion.isExpanded(section) {
        content()
      }
    } header: {
      Button {
        sidebarSectionExpansion.setExpanded(
          !sidebarSectionExpansion.isExpanded(section),
          for: section)
      } label: {
        HStack(spacing: 6) {
          Text(title)
          Spacer(minLength: 0)
          Image(
            systemName: sidebarSectionExpansion.isExpanded(section)
              ? "chevron.down" : "chevron.right"
          )
          .font(.caption.weight(.semibold))
          .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .padding(.trailing, 24)
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("sidebar-section-\(section.rawValue)")
      .accessibilityValue(
        sidebarSectionExpansion.isExpanded(section)
          ? String(localized: "開いています") : String(localized: "閉じています"))
    }
    .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
  }

  private var unregisteredRecentConnections: [RecentSMBConnection] {
    nasConnections.recentConnections.filter { connection in
      !nasConnections.profiles.contains {
        $0.host.caseInsensitiveCompare(connection.host) == .orderedSame
          && $0.shareName.caseInsensitiveCompare(connection.shareName) == .orderedSame
      }
    }
  }

  private func nasConnectionRow(_ profile: NASConnectionProfile) -> some View {
    let status = nasConnections.status(for: profile)
    return HStack {
      Button(action: { openNASConnection(profile) }) {
        nasConnectionLabel(profile)
      }
      .buttonStyle(.plain)
      .disabled(nasConnections.isConnecting(profile))
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityLabel(
        "\(profile.displayName)、\(status.displayName)")
      if case .connected(let volume) = status {
        sidebarVolumeCapacityLabel(for: volume.volumeURL)
        Button {
          disconnectNASConnection(profile)
        } label: {
          Image(systemName: "eject")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .fixedSize()
        .help("接続を解除")
        .accessibilityLabel("接続を解除")
      } else if nasConnections.isConnecting(profile) {
        connectingIndicator
      }
    }
    .contextMenu {
      if case .connected = nasConnections.status(for: profile) {
        Button("接続を解除") {
          disconnectNASConnection(profile)
        }
      }
      Button("編集") {
        editingNASProfile = profile
      }
      Button("削除", role: .destructive) {
        nasConnections.remove(profile)
      }
    }
  }

  private func sharedVolumeRow(_ volume: SMBMountedVolume) -> some View {
    HStack {
      Button {
        openMountedFolder(volume)
      } label: {
        unregisteredNASConnectionLabel(volume)
      }
      .buttonStyle(.plain)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityLabel("\(volume.remountingURL.absoluteString)、接続済み")
      sidebarVolumeCapacityLabel(for: volume.volumeURL)
      Button {
        nasConnections.disconnect(volume, onDetached: folderSelection.dismissMountedFolder)
      } label: {
        Image(systemName: "eject")
      }
      .buttonStyle(.borderless)
      .controlSize(.small)
      .fixedSize()
      .help("接続を解除")
      .accessibilityLabel("接続を解除")
    }
  }

  private func sidebarPlaceRow(_ place: SidebarPlace) -> some View {
    HStack {
      sidebarLocationButton(
        SidebarLocation(
          id: place.id,
          title: place.displayName,
          source: sidebarLocationSource(for: place),
          detail: place.detail,
          systemImageOverride: place.systemImage),
        isSelected: isSidebarLocationSelected(place.url)
      ) {
        openSidebarPlace(place)
      }
      if case .volume = place.kind {
        sidebarVolumeCapacityLabel(for: place.url)
      }
      if case .volume(isEjectable: true) = place.kind {
        Button {
          ejectSidebarPlace(place)
        } label: {
          Image(systemName: "eject")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .fixedSize()
        .help("取り出す")
        .accessibilityLabel("取り出す")
        .disabled(ejectingPlaceIDs.contains(place.id))
      }
    }
    .contextMenu {
      if case .volume(isEjectable: true) = place.kind {
        Button("取り出す") {
          ejectSidebarPlace(place)
        }
        .disabled(ejectingPlaceIDs.contains(place.id))
      }
    }
  }

  private func sidebarLocationSource(for place: SidebarPlace) -> SidebarLocationSource {
    switch place.kind {
    case .volume:
      .volume
    case .iCloudDrive, .cloudStorage:
      .cloud
    }
  }

  private func openSidebarPlace(_ place: SidebarPlace) {
    if case .cloudStorage = place.kind {
      if let url = folderSelection.openSavedCloudRoot(at: place.url) {
        sidebarPlaceErrorMessage = nil
        openLocalBrowser(at: url)
      } else {
        folderSelection.chooseCloudRoot(onSelected: openLocalBrowser)
      }
      return
    }
    sidebarPlaceErrorMessage = nil
    folderSelection.openLocalFolder(at: place.url, onSelected: openLocalBrowser)
  }

  private var visibleSidebarPlaces: [SidebarPlace] {
    var places = sidebarPlaces.places
    var seenIDs = Set(places.map(\.id))
    for location in folderSelection.cloudRootLocations {
      guard let path = location.url?.path ?? location.lastKnownPath else { continue }
      let url = URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL
      guard seenIDs.insert(url.path).inserted else { continue }
      places.append(
        SidebarPlace(
          id: url.path,
          url: url,
          displayName: location.displayName,
          detail: nil,
          kind: .cloudStorage))
    }
    return places
  }

  private func ejectSidebarPlace(_ place: SidebarPlace) {
    guard !ejectingPlaceIDs.contains(place.id) else { return }
    ejectingPlaceIDs.insert(place.id)
    sidebarPlaceErrorMessage = nil
    SystemLocalVolumeEjector().eject(volumeURL: place.url) { result in
      ejectingPlaceIDs.remove(place.id)
      if case .failure = result {
        sidebarPlaceErrorMessage = String(
          format: String(localized: "%@を取り出せませんでした。"),
          place.displayName)
      }
    }
  }

  private func favoriteLocationButton(_ location: SavedFolderLocation, index: Int) -> some View {
    sidebarTransferDropTarget(
      destinationID: "favorite-\(location.id.uuidString)"
    ) {
      savedLocationButton(location)
        .contextMenu {
          Button("上へ移動") {
            favoriteOrder.move(
              "favorite-\(location.id.uuidString)", by: -1, available: availableFavoriteIDs)
          }
          .disabled(index == 0)
          Button("下へ移動") {
            favoriteOrder.move(
              "favorite-\(location.id.uuidString)", by: 1, available: availableFavoriteIDs)
          }
          .disabled(index == orderedFavoriteIDs.count - 1)
          Divider()
          Button("お気に入りから削除", role: .destructive) {
            folderSelection.removeFavorite(id: location.id)
          }
          .accessibilityIdentifier("remove-favorite-location-\(location.name)")
        }
    }
  }

  private func sftpFavoriteButton(_ favorite: SFTPFolderFavorite) -> some View {
    let location = SidebarLocation(
      id: "sftp-favorite-\(favorite.id.uuidString)",
      title: favorite.name,
      source: .sftp,
      availability: sftpConnections.isConnected(favorite.target) ? .available : .reconnectable,
      detail: favorite.directory)
    return sidebarTransferDropTarget(destinationID: location.id) {
      sidebarLocationButton(location) {
        openSFTPFavorite(favorite)
      }
      .contextMenu {
        Button("お気に入りから削除", role: .destructive) {
          sftpConnections.removeFavorite(id: favorite.id)
        }
      }
    }
  }

  private func sftpRecentLocationButton(_ recent: SFTPFolderRecent) -> some View {
    let location = SidebarLocation(
      id: "sftp-recent-\(recent.id.uuidString)",
      title: recent.name,
      source: .sftp,
      availability: sftpConnections.isConnected(recent.target) ? .available : .reconnectable,
      detail: recent.directory)
    return sidebarTransferDropTarget(destinationID: location.id) {
      sidebarLocationButton(location) {
        openSFTPFavorite(SFTPFolderFavorite(target: recent.target, directory: recent.directory))
      }
      .contextMenu {
        Button("最近使用した場所から削除", role: .destructive) {
          sftpConnections.removeRecent(id: recent.id)
        }
      }
    }
  }

  private func ftpFavoriteButton(_ favorite: FTPFolderFavorite) -> some View {
    let location = SidebarLocation(
      id: "ftp-favorite-\(favorite.id.uuidString)",
      title: favorite.name,
      source: .ftp,
      availability: ftpConnections.isConnected(favorite.target) ? .available : .reconnectable,
      detail: favorite.directory)
    return sidebarTransferDropTarget(destinationID: location.id) {
      sidebarLocationButton(location) {
        openFTPFavorite(favorite)
      }
      .contextMenu {
        Button("お気に入りから削除", role: .destructive) {
          ftpConnections.removeFavorite(id: favorite.id)
        }
      }
    }
  }

  private func ftpRecentLocationButton(_ recent: FTPFolderRecent) -> some View {
    let location = SidebarLocation(
      id: "ftp-recent-\(recent.id.uuidString)",
      title: recent.name,
      source: .ftp,
      availability: ftpConnections.isConnected(recent.target) ? .available : .reconnectable,
      detail: recent.directory)
    return sidebarTransferDropTarget(destinationID: location.id) {
      sidebarLocationButton(location) {
        openFTPFavorite(FTPFolderFavorite(target: recent.target, directory: recent.directory))
      }
      .contextMenu {
        Button("最近使用した場所から削除", role: .destructive) {
          ftpConnections.removeRecent(id: recent.id)
        }
      }
    }
  }

  private func sidebarTransferDropTarget<Content: View>(
    destinationID: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    content()
      .background {
        if highlightedSidebarTransferDestinationID == destinationID {
          RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(themePalette.accentFill(.sidebarSelection))
            .overlay {
              RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(themePalette.accentFill(.border), lineWidth: 1)
            }
        }
      }
      .contentShape(Rectangle())
      .dropDestination(for: URL.self) { urls, _ in
        if highlightedSidebarTransferDestinationID == destinationID {
          highlightedSidebarTransferDestinationID = nil
        }
        return transferDroppedItems(urls, toSidebarDestination: destinationID)
      } isTargeted: { isTargeted in
        updateSidebarTransferDropHighlight(
          destinationID: destinationID,
          isTargeted: isTargeted)
      }
  }

  private func updateSidebarTransferDropHighlight(
    destinationID: String,
    isTargeted: Bool
  ) {
    if isTargeted && isSidebarTransferDestinationEnabled(destinationID) {
      highlightedSidebarTransferDestinationID = destinationID
    } else if highlightedSidebarTransferDestinationID == destinationID {
      highlightedSidebarTransferDestinationID = nil
    }
  }

  private func isSidebarTransferDestinationEnabled(_ destinationID: String) -> Bool {
    guard let workspace = providerBrowser?.workspace else { return false }
    return ProviderTransferDestinationCatalog.destination(
      id: destinationID,
      in: transferDestinationSections(for: workspace)
    )?.isEnabled == true
  }

  private func transferDestinationSections(
    for workspace: FileWorkspaceModel
  ) -> [ProviderTransferDestinationSection] {
    ProviderTransferDestinationCatalog.makeSections(
      workspace: workspace,
      favorites: folderSelection.favoriteLocations,
      recents: folderSelection.recentLocations,
      sftpFavorites: sftpConnections.favoriteFolders,
      sftpRecents: sftpConnections.recentFolders,
      ftpFavorites: ftpConnections.favoriteFolders,
      ftpRecents: ftpConnections.recentFolders,
      nasProfiles: nasConnections.profiles,
      sftpTargets: sftpConnections.targets,
      ftpTargets: ftpConnections.targets,
      volumeProvider: { nasConnections.provider(for: $0) },
      sftpProvider: { sftpConnections.provider(for: $0) },
      ftpProvider: { ftpConnections.provider(for: $0) })
  }

  private func transferDroppedItems(
    _ urls: [URL],
    toSidebarDestination destinationID: String
  ) -> Bool {
    guard !urls.isEmpty, !urls.contains(where: SidebarFavoriteOrderModel.isFavoriteDrag),
      let workspace = providerBrowser?.workspace
    else { return false }
    let sections = transferDestinationSections(for: workspace)
    guard
      let destination = ProviderTransferDestinationCatalog.destination(
        id: destinationID, in: sections),
      destination.isEnabled,
      let destinationBrowser = destination.makeDestination()
    else {
      return false
    }
    let trace = DropPreparationTrace(
      itemCount: urls.count,
      destinationKind: .sidebarSavedLocation)
    return workspace.transferDroppedItems(
      urls,
      to: destinationBrowser,
      copyForced: NSEvent.modifierFlags.contains(.option),
      trace: trace)
  }

  private func recentNASLocationButton(_ connection: RecentSMBConnection) -> some View {
    let isConnecting = nasConnections.isConnecting(connection)
    let location = SidebarLocation(
      id: "nas-recent-\(connection.id)",
      title: connection.displayName,
      source: .nas,
      availability: .reconnectable,
      detail: "未接続")
    return HStack {
      sidebarLocationButton(location) {
        nasConnections.connect(connection, onConnected: openMountedFolder)
      }
      .disabled(isConnecting)
      if isConnecting {
        connectingIndicator
      }
    }
    .contextMenu {
      Button("最近使用した場所から削除", role: .destructive) {
        nasConnections.removeRecent(id: connection.id)
      }
      .accessibilityIdentifier("remove-recent-nas-connection-\(connection.id)")
    }
  }

  private func openNASConnection(_ profile: NASConnectionProfile, savesProfile: Bool = false) {
    nasConnections.openConnection(
      profile,
      savesProfile: savesProfile,
      onMounted: { volume in
        openMountedFolder(SavedMountedFolder(volume: volume, folderURL: volume.volumeURL))
      },
      onSelectMounted: { pendingMountedSMBVolumes = $0 },
      onConnected: { volumeURL in
        Task { @MainActor in
          openMountedFolder(volumeURL)
        }
      })
  }

  /// 接続パネルのシートが閉じきってから接続を始める。閉じるアニメーション中に始めると、
  /// NASの共有選択・フォルダ許可パネルや、SFTP/FTPの初回接続で必要な資格情報ダイアログが
  /// 閉じかけのシートと重なって潰れ、キャンセル扱い(認証失敗)になる。
  private func openPendingConnectPanelConnection() {
    guard let pending = pendingConnectPanelConnection else { return }
    pendingConnectPanelConnection = nil
    // onDismiss はシートが消えきる前に呼ばれることがあり、直後に出す資格情報ダイアログや
    // ホスト鍵承認が表示されずに接続が止まったため、消えきるのを待ってから起動する。
    Task { @MainActor in
      AppLog.notice("pending connection waiting for sheet settlement", category: "SFTPConnect")
      let settled = await SheetSettlementWaiter.wait(
        isSheetAttached: SheetSettlementWaiter.anyWindowHasAttachedSheet)
      AppLog.notice("pending connection starting settled=\(settled)", category: "SFTPConnect")
      switch pending {
      case .nas(let profile, let savesProfile):
        openNASConnection(profile, savesProfile: savesProfile)
      case .sftp(let target):
        connectSFTPFromConnectPanel(target)
      case .ftp(let target):
        connectFTPFromConnectPanel(target)
      }
    }
  }

  private func disconnectNASConnection(_ profile: NASConnectionProfile) {
    nasConnections.disconnect(profile, onDetached: folderSelection.dismissMountedFolder)
  }

  private func presentConnectPanel(entryMode: ConnectPanelEntryMode) {
    connectPanelEntryMode = entryMode
    isPresentingConnectPanel = true
  }

  /// Connect Panel一覧モードの行から接続するSFTPターゲット向け。サイドバーの接続行の
  /// 接続動作(connectionSection)と同じ「接続済みなら既存プロバイダで開く、そうでなければ
  /// 接続してから開く」ロジックを共有する。
  private func connectSFTPFromConnectPanel(_ target: SFTPConnectionTarget) {
    if let provider = sftpConnections.provider(for: target) {
      showProviderBrowser(makeSFTPBrowser(target: target, provider: provider))
    } else {
      sftpConnections.connect(
        target,
        onConnected: { provider in
          Task { @MainActor in
            showProviderBrowser(makeSFTPBrowser(target: target, provider: provider))
          }
        },
        onHostKeyApproval: presentSFTPHostKeyApproval)
    }
  }

  private func connectFTPFromConnectPanel(_ target: FTPConnectionTarget) {
    if let provider = ftpConnections.provider(for: target) {
      showProviderBrowser(makeFTPBrowser(target: target, provider: provider))
    } else {
      ftpConnections.connect(target) { provider in
        Task { @MainActor in
          showProviderBrowser(makeFTPBrowser(target: target, provider: provider))
        }
      }
    }
  }

  private func content(for selectedFolderURL: URL?) -> LaunchContent {
    guard let selectedFolderURL else {
      return content
    }

    return LaunchContent(
      title: selectedFolderURL.lastPathComponent,
      message: selectedFolderURL.path
    )
  }

  private func savedLocationButton(
    _ location: SavedFolderLocation
  ) -> some View {
    let canReconnect = nasConnections.canReconnectSavedLocation(location)
    let isConnecting = nasConnections.isConnectingSavedLocation(location)
    let source: SidebarLocationSource = location.smbLocation == nil ? .local : .nas
    let availability: SidebarLocation.Availability =
      location.isAvailable
      ? .available
      : (canReconnect || location.requiresAuthorization ? .reconnectable : .unavailable)
    let sidebarLocation = SidebarLocation(
      id: "saved-\(location.id.uuidString)",
      title: location.displayName,
      source: source,
      availability: availability,
      detail: location.url?.path ?? location.lastKnownPath,
      systemImageOverride: source == .local ? location.sidebarSystemImage : nil)
    return HStack {
      sidebarLocationButton(
        sidebarLocation,
        isSelected: location.url.map(isSidebarLocationSelected) ?? false,
        accessibilityIdentifier: "saved-location-\(location.name)"
      ) {
        openSavedLocation(location)
      }
      .disabled(isConnecting)
      if location.isICloudManagedFolder {
        Image(systemName: "icloud")
          .foregroundStyle(.secondary)
          .accessibilityLabel(String(localized: "iCloudと同期"))
      }
      if isConnecting {
        connectingIndicator
      }
    }
  }

  private func openSavedLocation(_ location: SavedFolderLocation) {
    if let mountedFolder = nasConnections.mountedFolder(for: location) {
      openMountedFolder(mountedFolder)
      return
    }
    if location.url == nil,
      nasConnections.connectSavedLocation(location, onConnected: openMountedFolder)
    {
      return
    }
    if let url = location.url, location.smbLocation != nil {
      openMountedFolder(url)
      return
    }
    if let selectedFolderURL = folderSelection.openSavedLocation(location) {
      openLocalBrowser(at: selectedFolderURL)
    }
  }

  private func openLocalBrowser(at url: URL) {
    if ProcessInfo.processInfo.arguments.contains("-ui-test-nas-trash-unavailable") {
      let provider = MountedVolumeProvider(volumeURL: url) { _ in
        throw FileBrowserOperationError.trashUnavailable
      }
      let location = FileLocation(localURL: url, providerID: provider.id)
      providerBrowserLocation = location
      showProviderBrowser(
        makeProviderBrowser(
          title: url.lastPathComponent,
          provider: provider,
          initialLocation: location))
      return
    }
    let provider = LocalFileProvider()
    let location = FileLocation(localURL: url, providerID: provider.id)
    providerBrowserLocation = location
    showProviderBrowser(
      makeProviderBrowser(
        title: url.lastPathComponent,
        provider: provider,
        initialLocation: location,
        accessLease: folderSelection.accessLease(for: url)))
  }

  private func openRecentFiles() {
    let roots = folderSelection.authorizedRecentFileRoots()
    guard let firstRoot = roots.first else {
      folderSelection.chooseFolder { url in
        openLocalBrowser(at: url)
        startRecentFilesInActiveBrowser()
      }
      return
    }
    if providerBrowser?.workspace.activeTab.browser.usesLocalFileProvider != true {
      openLocalBrowser(at: firstRoot)
    }
    startRecentFilesInActiveBrowser()
  }

  private func startRecentFilesInActiveBrowser() {
    let roots = folderSelection.authorizedRecentFileRoots()
    guard !roots.isEmpty else { return }
    providerBrowser?.workspace.activeTab.browser.startRecentFiles(
      authorizedRoots: roots,
      accessLeases: folderSelection.recentFileAccessLeases(for: roots))
  }

  private func applyPendingApplicationOpenRequests() {
    while let request = applicationOpenRequestStore.takeNextRequestIfReady() {
      openApplicationTarget(request.target)
    }
  }

  private func openApplicationTarget(_ target: ApplicationOpenTarget) {
    let presentation = ApplicationOpenNavigation.presentation(for: target)
    providerBrowserLocation = presentation.browser.currentLocation
    showProviderBrowser(presentation)
  }

  private func restoreSavedWorkspace() -> Bool {
    if let workspace = providerBrowser?.workspace {
      workspace.recordPaneDiagnostic("保存復元をスキップ 既存ワークスペースあり")
      return false
    }
    guard let state = workspacePersistence.load() else {
      AppLog.notice("保存復元をスキップ 保存状態なし", category: "PaneLayout")
      return false
    }
    let workspace = FileWorkspaceModel(
      restoring: state,
      browserFactory: WorkspaceBrowserFactory(
        inheritedAccessLease: { folderSelection.accessLease(for: $0) }))
    let session = ProviderBrowserSession(
      title: workspace.activeTab.title,
      workspace: workspace)
    workspace.setRemoteActivationHandler { [weak session] location, completion in
      guard let session else {
        completion(nil)
        return
      }
      activateRestoredRemoteLocation(location, in: session, completion: completion)
    }
    configurePersistence(for: session)
    providerBrowser = session
    providerBrowserLocation = workspace.activeTab.browser.currentLocation
    providerBrowserViewMode = workspace.activeTab.viewMode
    session.prepareForPresentation()
    return true
  }

  private func activateRestoredRemoteLocation(
    _ location: WorkspaceLocationState,
    in session: ProviderBrowserSession,
    completion: @escaping @MainActor (FileBrowserSession?) -> Void
  ) {
    guard case .remote(let providerKind, let connectionID, let path) = location else {
      completion(nil)
      return
    }
    switch providerKind {
    case .sftp:
      guard
        let target = sftpConnections.targets.first(where: {
          SFTPFileProvider.connectionID(for: $0).rawValue == connectionID
        })
      else {
        completion(nil)
        return
      }
      let useProvider: @MainActor (SFTPFileProvider) -> Void = { provider in
        let presentation = makeSFTPBrowser(
          target: target,
          provider: provider,
          initialDirectory: path)
        session.registerSFTPTarget(target, for: provider.id)
        session.title = presentation.title
        completion(presentation.browser)
      }
      if let provider = sftpConnections.provider(for: target) {
        useProvider(provider)
      } else {
        sftpConnections.connect(
          target,
          onConnected: useProvider,
          onHostKeyApproval: presentSFTPHostKeyApproval)
      }
    case .smb:
      activateRestoredSMBLocation(
        connectionID: connectionID,
        relativePath: path,
        in: session,
        completion: completion)
    case .ftp:
      guard
        let target = ftpConnections.targets.first(where: {
          FTPFileProvider.connectionID(for: $0).rawValue == connectionID
        })
      else {
        completion(nil)
        return
      }
      let useProvider: @MainActor (FTPFileProvider) -> Void = { provider in
        let initialLocation = FileLocation(remotePath: path, providerID: provider.id)
        session.registerFTPTarget(target, for: provider.id)
        session.title = "\(target.username)@\(target.host)"
        providerBrowserLocation = initialLocation
        completion(FileBrowserSession(provider: provider, initialLocation: initialLocation))
      }
      if let provider = ftpConnections.provider(for: target) {
        useProvider(provider)
      } else {
        ftpConnections.connect(target, onConnected: useProvider)
      }
    }
  }

  private func activateRestoredSMBLocation(
    connectionID: String,
    relativePath: String,
    in session: ProviderBrowserSession,
    completion: @escaping @MainActor (FileBrowserSession?) -> Void
  ) {
    if let profile = nasConnections.profiles.first(where: { $0.id.uuidString == connectionID }) {
      if profile.shareName.isEmpty {
        // 旧サーバーIDには共有名がない。現在1共有だけでも過去と同じ共有とは限らない。
        completion(nil)
        return
      }
      let useProvider: @MainActor (MountedVolumeProvider) -> Void = { provider in
        guard
          let location = restoredSMBLocation(
            provider: provider, relativePath: relativePath),
          let folderURL = location.localURL,
          let presentation = Self.mountedFolderPresentation(
            provider: provider, folderURL: folderURL, title: profile.displayName,
            folderSelection: folderSelection, restoringProfile: profile)
        else {
          completion(nil)
          return
        }
        session.title = presentation.title
        providerBrowserLocation = presentation.browser.currentLocation
        nasConnections.clearError()
        completion(presentation.browser)
      }
      if let provider = nasConnections.provider(for: profile) {
        useProvider(provider)
      } else {
        nasConnections.connect(profile) { _ in
          guard let provider = nasConnections.provider(for: profile) else {
            completion(nil)
            return
          }
          useProvider(provider)
        }
      }
      return
    }

    let mountedProvider = nasConnections.unregisteredMountedVolumes
      .map { nasConnections.provider(for: $0) }
      .first { $0.connectionID?.rawValue == connectionID }
    guard let mountedProvider,
      let location = restoredSMBLocation(
        provider: mountedProvider, relativePath: relativePath),
      let folderURL = location.localURL,
      let presentation = Self.mountedFolderPresentation(
        provider: mountedProvider, folderURL: folderURL,
        title: mountedProvider.volumeURL.lastPathComponent, folderSelection: folderSelection)
    else {
      completion(nil)
      return
    }
    session.title = presentation.title
    providerBrowserLocation = presentation.browser.currentLocation
    nasConnections.clearError()
    completion(presentation.browser)
  }

  private func restoredSMBLocation(
    provider: MountedVolumeProvider,
    relativePath: String
  ) -> FileLocation? {
    let components = relativePath.split(separator: "/").map(String.init)
    guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
      return nil
    }
    let url = components.reduce(provider.volumeURL) { partialURL, component in
      partialURL.appending(path: component, directoryHint: .isDirectory)
    }
    return FileLocation(directoryURL: url, providerID: provider.id)
  }

  private func configurePersistence(for session: ProviderBrowserSession) {
    let persistence = workspacePersistence
    let workspace = session.workspace
    workspace.onOpenAdditionalFolder = { location in
      guard let request = try? FolderWindowRequest(location: location) else { return false }
      openWindow(id: FolderWindowRequest.sceneID, value: request)
      return true
    }
    workspace.onStateChange = { [weak persistence, weak workspace] in
      guard let persistence, let workspace else { return }
      persistence.scheduleSave(of: workspace)
    }
  }

  private func openMountedFolder(_ url: URL) {
    if let volume = nasConnections.mountedVolume(containing: url) {
      openMountedProvider(
        nasConnections.provider(for: volume), folderURL: url, title: url.lastPathComponent)
      return
    }
    openMountedProvider(
      MountedVolumeProvider(volumeURL: url), folderURL: url, title: url.lastPathComponent)
  }

  private func openMountedFolder(_ volume: SMBMountedVolume) {
    openMountedFolder(volume.volumeURL)
  }

  private func openMountedFolder(_ mountedFolder: SavedMountedFolder) {
    openMountedProvider(
      nasConnections.provider(for: mountedFolder.volume),
      folderURL: mountedFolder.folderURL, title: mountedFolder.folderURL.lastPathComponent)
  }

  private func openNASBrowser(_ profile: NASConnectionProfile) {
    guard let provider = nasConnections.provider(for: profile) else { return }
    openMountedProvider(provider, folderURL: provider.volumeURL, title: profile.displayName)
  }

  private func openMountedProvider(
    _ provider: MountedVolumeProvider, folderURL: URL, title: String
  ) {
    guard
      let presentation = Self.mountedFolderPresentation(
        provider: provider, folderURL: folderURL, title: title, folderSelection: folderSelection)
    else { return }
    nasConnections.clearError()
    providerBrowserLocation = presentation.browser.currentLocation
    showProviderBrowser(presentation)
  }

  /// Finderのマウント状態と、PKPaneが共有を読むためのSandbox許可は別に確認する。
  static func mountedFolderPresentation(
    provider: MountedVolumeProvider,
    folderURL: URL,
    title: String,
    folderSelection: FolderSelectionModel,
    restoringProfile: NASConnectionProfile? = nil,
    transferQueue: TransferQueue = .shared
  ) -> ProviderBrowserPresentation? {
    guard restoringProfile?.shareName.isEmpty != true else { return nil }
    // 子フォルダの再表示でも共有ルートを許可し、他ペインへ移ってもリースを保持する。
    guard folderSelection.openLocalFolder(at: provider.volumeURL) != nil,
      let accessLease = folderSelection.accessLease(for: provider.volumeURL)
    else { return nil }
    return ProviderBrowserPresentation(
      title: title,
      browser: FileBrowserSession(
        provider: provider,
        initialLocation: FileLocation(localURL: folderURL, providerID: provider.id),
        transferQueue: transferQueue,
        workspaceBookmarkAccessLease: accessLease))
  }

  private func closeProviderBrowser() {
    providerBrowser = nil
    providerBrowserLocation = nil
    if let selectedFolderURL = folderSelection.selectedFolderURL {
      openLocalBrowser(at: selectedFolderURL)
    }
  }

  private func dismissProviderBrowser(for connectionID: FileProviderConnectionID) {
    guard let providerBrowser,
      providerBrowser.workspace.removeTabs(for: connectionID)
    else {
      return
    }
    closeProviderBrowser()
  }

  private func showProviderBrowser(_ presentation: ProviderBrowserPresentation) {
    guard let providerBrowser else {
      let browser = ProviderBrowserSession(
        title: presentation.title,
        browser: presentation.browser,
        connectionID: presentation.browser.connectionID,
        sftpTarget: presentation.sftpTarget,
        ftpTarget: presentation.ftpTarget,
        initialViewMode: currentBrowserViewMode)
      configurePersistence(for: browser)
      browser.prepareForPresentation()
      self.providerBrowser = browser
      workspacePersistence.scheduleSave(of: browser.workspace)
      return
    }
    providerBrowser.replaceActiveBrowser(
      with: presentation.browser,
      title: presentation.title,
      sftpTarget: presentation.sftpTarget,
      ftpTarget: presentation.ftpTarget)
  }

  private func presentSFTPHostKeyApproval(
    target: SFTPConnectionTarget,
    request: SFTPHostKeyApprovalRequest,
    isUpdate: Bool
  ) {
    pendingSFTPHostKeyApproval = SFTPHostKeyApproval(
      target: target,
      request: request,
      isUpdate: isUpdate)
  }

  private var connectingIndicator: some View {
    ProgressView()
      .controlSize(.small)
      .help("接続中")
      .accessibilityLabel("接続中")
  }

  private func sidebarItemLabel(
    _ title: String,
    systemImage: String,
    isSelected: Bool = false
  ) -> some View {
    Label(title, systemImage: systemImage)
      .lineLimit(1)
      .padding(.horizontal, 6)
      .padding(.vertical, 1)
      .background {
        if isSelected {
          RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(themePalette.accentFill(.connectionSelection))
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
  }

  private func sidebarLocationButton(
    _ location: SidebarLocation,
    isSelected: Bool = false,
    accessibilityIdentifier: String? = nil,
    action: @escaping () -> Void
  ) -> some View {
    let icon = location.isAvailable ? location.systemImage : "exclamationmark.triangle"
    return Button(action: action) {
      sidebarItemLabel(location.title, systemImage: icon, isSelected: isSelected)
    }
    .buttonStyle(.plain)
    .frame(maxWidth: .infinity, alignment: .leading)
    .disabled(!location.isAvailable)
    .accessibilityIdentifier(accessibilityIdentifier ?? location.id)
    .accessibilityLabel(sidebarLocationAccessibilityLabel(location))
    // 旧 sidebarLocationSourceIndicator の識別子相当。種別はvalueとしてUIテストから参照可能にする
    .accessibilityValue(location.source.rawValue)
    .help(
      location.detail
        ?? "\(location.source.displayName)の場所"
    )
  }

  private func sidebarLocationAccessibilityLabel(_ location: SidebarLocation) -> String {
    location.isAvailable
      ? "\(location.title)、\(location.source.displayName)"
      : "\(location.title)、\(location.source.displayName)、アクセスできません"
  }

  @ViewBuilder
  private func sidebarVolumeCapacityLabel(for volumeURL: URL) -> some View {
    if let byteCount = sidebarPlaces.availableCapacity(for: volumeURL), byteCount >= 0 {
      let capacity = ByteCountFormatter.string(
        fromByteCount: byteCount,
        countStyle: .file)
      Text(capacity)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize()
        .accessibilityIdentifier(
          "sidebar-volume-capacity-\(volumeURL.standardizedFileURL.path)"
        )
        .help(String(format: String(localized: "空き容量: %@"), capacity))
        .accessibilityLabel(String(format: String(localized: "空き容量: %@"), capacity))
    }
  }

  private func nasConnectionLabel(_ profile: NASConnectionProfile) -> some View {
    let status = nasConnections.status(for: profile)
    let isSelected: Bool
    if case .connected(let volume) = status {
      isSelected = isSidebarLocationSelected(volume.volumeURL)
    } else {
      isSelected = false
    }

    return VStack(alignment: .leading, spacing: 2) {
      Label(
        profile.displayName,
        systemImage: status == .disconnected ? "externaldrive" : "externaldrive.fill")
      Text(
        profile.shareName.isEmpty
          ? "smb://\(profile.host)" : "smb://\(profile.host)/\(profile.shareName)"
      )
      .font(.caption2)
      .foregroundStyle(.secondary)
    }
    .lineLimit(1)
    .padding(.horizontal, 6)
    .padding(.vertical, 1)
    .background {
      if isSelected {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .fill(themePalette.accentFill(.connectionSelection))
      }
    }
    .contentShape(Rectangle())
  }

  private func unregisteredNASConnectionLabel(_ volume: SMBMountedVolume) -> some View {
    let host = volume.remountingURL.host ?? volume.volumeURL.lastPathComponent
    let shareName = volume.remountingURL.lastPathComponent

    return Label("\(host)/\(shareName)", systemImage: "externaldrive.fill")
      .lineLimit(1)
      .padding(.horizontal, 6)
      .padding(.vertical, 1)
      .contentShape(Rectangle())
  }

  private func isSidebarLocationSelected(_ url: URL) -> Bool {
    if providerBrowser?.workspace.activeTab.browser.isRecentFilesActive == true {
      return false
    }
    let selectedURL: URL?
    if let providerBrowser {
      selectedURL = providerBrowser.workspace.activeTab.browser.currentLocation.localURL
    } else {
      selectedURL = folderSelection.selectedFolderURL
    }
    return selectedURL?.standardizedFileURL == url.standardizedFileURL
  }

  private var loadedFinderTagNames: [String] {
    guard let workspace = providerBrowser?.workspace else { return [] }
    return workspace.tabs.flatMap { tab -> [String] in
      guard tab.browser.capabilities.contains(.finderTags) else { return [] }
      return tab.browser.loadedFinderTagNames
    }
  }

  private var canSearchSidebarTags: Bool {
    providerBrowser?.workspace.activeTab.browser.capabilities.contains(.finderTags) == true
  }

  private func sidebarTagColor(_ color: FinderTagColor) -> Color {
    color == .none
      ? Color.secondary.opacity(0.65)
      : Color(nsColor: FinderTagPalette.nsColor(for: color))
  }

  private func handleKeyboardCommand(_ command: KeyboardCommand) {
    guard providerBrowser != nil else { return }
    handleProviderKeyboardCommand(command)
  }

  private func handleProviderKeyboardCommand(_ command: KeyboardCommand) {
    let action: FileBrowserCommand.Action?
    switch command {
    case .refresh:
      action = .refresh
    case .showOriginal:
      action = .showOriginal
    case .goBack:
      action = .goBack
    case .goForward:
      action = .goForward
    case .rename:
      action = .renameSelectedItem
    case .open:
      action = .openSelectedItem
    case .quickLook:
      action = .previewSelectedItem
    case .selectNext:
      action = .selectNext
    case .selectPrevious:
      action = .selectPrevious
    case .selectNextPage:
      action = .selectNextPage
    case .selectPreviousPage:
      action = .selectPreviousPage
    case .clearSelection:
      action = .clearSelection
    case .focusSearch:
      action = .focusSearch
    case .endSearch:
      action = .endSearch
    }
    if let action {
      providerBrowserCommand = FileBrowserCommand(action: action)
    }
  }

  private var appMenuContext: AppMenuContext {
    guard let providerBrowser else { return .unavailable }
    let workspace = providerBrowser.workspace
    let activeBrowser = workspace.activeTab.browser
    let selectedURLs = workspace.activeTab.selectedItemURLs
    let selectedItems = activeBrowser.selectableItemsSnapshot.orderedItems(for: selectedURLs)
    let selectedItem =
      selectedURLs.count == 1
      ? selectedItems.first : nil
    let selectedFolderFavoriteState = selectedFolderFavoriteState(
      for: selectedItems,
      browser: activeBrowser)
    let isCurrentFavorite: Bool
    let canToggleCurrentFavorite: Bool
    if !SidebarCurrentLocationActionPolicy.canTargetCurrentFolder(
      isRecentFilesActive: activeBrowser.isRecentFilesActive)
    {
      isCurrentFavorite = false
      canToggleCurrentFavorite = false
    } else if let sftpTarget = providerBrowser.activeSFTPTarget,
      let directory = providerBrowserLocation?.remotePath
    {
      isCurrentFavorite = sftpConnections.isFavorite(target: sftpTarget, directory: directory)
      canToggleCurrentFavorite = true
    } else if let ftpTarget = providerBrowser.activeFTPTarget,
      let directory = providerBrowserLocation?.remotePath
    {
      isCurrentFavorite = ftpConnections.isFavorite(target: ftpTarget, directory: directory)
      canToggleCurrentFavorite = true
    } else if let localURL = providerBrowserLocation?.localURL,
      providerBrowser.activeSFTPTarget == nil
    {
      isCurrentFavorite = folderSelection.isFavorite(url: localURL)
      canToggleCurrentFavorite = true
    } else {
      isCurrentFavorite = false
      canToggleCurrentFavorite = false
    }
    return AppMenuContext(
      isBrowserAvailable: true,
      capabilities: activeBrowser.isRecentFilesActive
        ? activeBrowser.executableCapabilities.subtracting(.write)
        : activeBrowser.executableCapabilities,
      selectedItemCount: selectedURLs.count,
      displayedItemCount: activeBrowser.items.count,
      canPaste: workspace.canPasteItems(to: activeBrowser),
      canShowOriginal: selectedItem?.location.localURL != nil
        && (selectedItem?.isAliasFile == true || selectedItem?.isSymbolicLink == true),
      canMoveSelection: activeBrowser.canRemoveItemsAfterCopy,
      canBatchRename: !activeBrowser.isRecentFilesActive,
      canCopyToOppositePane: workspace.canCopySelectedItemsToOppositePane,
      canMoveToOppositePane: workspace.canMoveSelectedItemsToOppositePane,
      canCompareFolders: workspace.canCompareFolders,
      canUndo: workspace.canUndoLastTransfer,
      canRetry: activeBrowser.canRetryLastTransfer,
      showsSecondaryPane: workspace.showsSecondaryPane,
      isSyncBrowsingEnabled: workspace.isSyncBrowsingEnabled,
      detailsDisplayMode: providerBrowser.detailsDisplayMode,
      selectedItemIsPackage: selectedItem.map {
        FileBrowserSession.localApplicationBundleURL(for: $0) != nil
      } ?? false,
      selectedItemIsArchive: selectedItem.map {
        !$0.isDirectory && ArchiveFormat(url: $0.url) != nil
      } ?? false,
      selectedItemIsDirectory: selectedItem?.isDirectory ?? false,
      canArchive: !activeBrowser.isRecentFilesActive
        && activeBrowser.canCreateArchive(from: selectedItems),
      isArchiving: activeBrowser.isArchiving,
      canPreviewSelectedItem: activeBrowser.canResolveDetailThumbnailURL,
      canDuplicate: activeBrowser.canDuplicate,
      canEditRemotely: activeBrowser.canEditRemotely,
      canToggleCurrentFavorite: canToggleCurrentFavorite,
      isCurrentFavorite: isCurrentFavorite,
      canGoBack: activeBrowser.canGoBack,
      canGoForward: activeBrowser.canGoForward,
      canOpenParent: !activeBrowser.isRecentFilesActive && activeBrowser.canGoToParent,
      canOpenInTerminal: DeveloperToolTargetResolver.terminalDirectory(
        selectedItems: selectedItems,
        currentLocation: activeBrowser.currentLocation) != nil
        && (!activeBrowser.isRecentFilesActive || !selectedItems.isEmpty)
        && FileBrowserCapability.supports(.openInTerminal, for: currentBrowserViewMode),
      canOpenWithApplication: selectedItem?.location.localURL != nil,
      canEditFinderTags: activeBrowser.canEditFinderTags,
      openWithFileURL: selectedItem?.location.localURL,
      canShowArchiveContents: selectedItem.map {
        !$0.isDirectory
          && $0.location.localURL.flatMap(ArchiveFormat.init(url:))?.isBrowsable == true
      } ?? false,
      canShareSelectedItems: !selectedItems.isEmpty
        && selectedItems.allSatisfy { $0.location.localURL != nil },
      canCopySelectedItemPath: selectedItem != nil,
      canRevealSearchResult: selectedItem.map(activeBrowser.isSearchResult) ?? false,
      canToggleSelectedFolderFavorites: selectedFolderFavoriteState != nil,
      selectedFoldersAreFavorites: selectedFolderFavoriteState ?? false,
      canCloseConnection: activeBrowser.connectionID != nil,
      isLocalProvider: providerBrowser.activeSFTPTarget == nil
        && providerBrowserLocation?.localURL != nil,
      sortOrder: workspace.activeTab.sortOrder,
      sortAscending: workspace.activeTab.sortAscending)
  }

  private func issueAppMenuCommand(_ action: FileBrowserCommand.Action) {
    switch action {
    case .setBrowserViewMode(let mode):
      providerBrowserViewMode = mode
      providerBrowserCommand = FileBrowserCommand(action: action)
    case .setSortOrder(let order):
      providerBrowser?.workspace.setSortOrder(order)
    case .toggleSortDirection:
      providerBrowser?.workspace.toggleSortDirection()
    case .toggleCurrentFavorite:
      toggleProviderBrowserCurrentFavorite()
    case .toggleSelectedFolderFavorites:
      guard let providerBrowser else { return }
      let browser = providerBrowser.workspace.activeTab.browser
      let selectedURLs = providerBrowser.workspace.activeTab.selectedItemURLs
      let items = browser.selectableItemsSnapshot.orderedItems(for: selectedURLs)
      favoriteContextMenuItem(for: items, browser: browser)?.action()
    case .closeConnection:
      closeProviderBrowser()
    case .toggleSyncBrowsing:
      providerBrowser?.workspace.toggleSyncBrowsing()
    case .toggleSecondaryPane:
      providerBrowser?.workspace.recordPaneDiagnostic(
        "メニューコマンド受信 \(PaneInputDiagnostic.currentEvent)")
      providerBrowserCommand = FileBrowserCommand(action: action)
    case .toggleDetailsInspector:
      toggleDetailsPane()
    default:
      providerBrowserCommand = FileBrowserCommand(action: action)
    }
  }

  private var quickOpenCandidates: [QuickOpenCandidate] {
    QuickOpenIndex.makeCandidates(
      favorites: appMenuFavoriteLocationEntries.map {
        QuickOpenSourceItem(id: $0.id, title: $0.title)
      },
      recents: appMenuRecentLocationEntries.map {
        QuickOpenSourceItem(id: $0.id, title: $0.title)
      },
      connections: quickOpenConnectionRows.map {
        QuickOpenSourceItem(id: $0.id, title: $0.title, subtitle: $0.subtitle)
      },
      commands: appMenuModel.quickOpenCommandItems)
  }

  private var quickOpenConnectionRows: [ConnectPanelRow] {
    ConnectPanelRow.rows(
      nasProfiles: nasConnections.profiles,
      sftpTargets: sftpConnections.targets,
      ftpTargets: ftpConnections.targets)
  }

  private func executeQuickOpenCandidate(_ candidate: QuickOpenCandidate) {
    isPresentingQuickOpen = false
    QuickOpenDispatcher(
      openFavorite: { id in
        appMenuFavoriteLocationEntries.first { $0.id == id }?.open()
      },
      openRecent: { id in
        appMenuRecentLocationEntries.first { $0.id == id }?.open()
      },
      connect: executeQuickOpenConnection,
      performCommand: appMenuModel.performQuickOpenCommand
    ).execute(candidate.action)
  }

  /// Quick Open のシートも接続パネルと同じく、閉じきってから接続を始める(資格情報ダイアログや
  /// 共有選択が閉じかけのシートと重ならないようにする)。
  private func executeQuickOpenConnection(id: String) {
    guard let row = quickOpenConnectionRows.first(where: { $0.id == id }) else { return }
    switch row.kind {
    case .nas(let profile):
      pendingConnectPanelConnection = .nas(profile, savesProfile: false)
    case .sftp(let target):
      pendingConnectPanelConnection = .sftp(target)
    case .ftp(let target):
      pendingConnectPanelConnection = .ftp(target)
    }
  }

  private func toggleDetailsPane() {
    guard let providerBrowser else { return }
    providerBrowser.detailsDisplayMode = providerBrowser.detailsDisplayMode.togglingPane
  }

  /// 移動メニュー>お気に入りサブメニューの列挙対象。ローカル/NAS保存場所とSFTP
  /// お気に入りはいずれもメモリ上に保持済みの一覧のため、ここでの結合は同期I/Oを伴わない。
  private var appMenuFavoriteLocationEntries: [AppMenuLocationEntry] {
    folderSelection.favoriteLocations.map { location in
      AppMenuLocationEntry(
        id: "favorite-\(location.id.uuidString)",
        title: location.displayName
      ) { openSavedLocation(location) }
    }
      + sftpConnections.favoriteFolders.map { favorite in
        AppMenuLocationEntry(
          id: "sftp-favorite-\(favorite.id.uuidString)",
          title: favorite.name
        ) { openSFTPFavorite(favorite) }
      }
      + ftpConnections.favoriteFolders.map { favorite in
        AppMenuLocationEntry(
          id: "ftp-favorite-\(favorite.id.uuidString)",
          title: favorite.name
        ) { openFTPFavorite(favorite) }
      }
  }

  /// 移動メニュー>最近使用した場所サブメニューの列挙対象。favoriteと同様、対象は
  /// いずれもメモリ上の一覧。
  private var appMenuRecentLocationEntries: [AppMenuLocationEntry] {
    folderSelection.recentLocations.map { location in
      AppMenuLocationEntry(
        id: "recent-\(location.id.uuidString)",
        title: location.displayName
      ) { openSavedLocation(location) }
    }
      + sftpConnections.recentFolders.map { recent in
        AppMenuLocationEntry(
          id: "sftp-recent-\(recent.id.uuidString)",
          title: recent.name
        ) {
          openSFTPFavorite(
            SFTPFolderFavorite(target: recent.target, directory: recent.directory))
        }
      }
      + ftpConnections.recentFolders.map { recent in
        AppMenuLocationEntry(
          id: "ftp-recent-\(recent.id.uuidString)",
          title: recent.name
        ) {
          openFTPFavorite(
            FTPFolderFavorite(target: recent.target, directory: recent.directory))
        }
      }
  }

  private func openSFTPFavorite(_ favorite: SFTPFolderFavorite) {
    sftpConnections.openFavorite(favorite) { provider in
      showProviderBrowser(
        makeSFTPBrowser(
          target: favorite.target,
          provider: provider,
          initialDirectory: favorite.directory))
    }
  }

  private func openFTPFavorite(_ favorite: FTPFolderFavorite) {
    ftpConnections.openFavorite(favorite) { provider in
      showProviderBrowser(
        makeFTPBrowser(
          target: favorite.target,
          provider: provider,
          initialDirectory: favorite.directory))
    }
  }

  private func toggleProviderBrowserCurrentFavorite() {
    guard let activeBrowser = providerBrowser?.workspace.activeTab.browser else { return }
    SidebarCurrentLocationActionPolicy.performFavoriteToggle(
      isRecentFilesActive: activeBrowser.isRecentFilesActive
    ) {
      if let sftpTarget = providerBrowser?.activeSFTPTarget,
        let directory = providerBrowserLocation?.remotePath
      {
        sftpConnections.toggleFavorite(target: sftpTarget, directory: directory)
      } else if let ftpTarget = providerBrowser?.activeFTPTarget,
        let directory = providerBrowserLocation?.remotePath
      {
        ftpConnections.toggleFavorite(target: ftpTarget, directory: directory)
      } else if let localURL = providerBrowserLocation?.localURL,
        providerBrowser?.activeSFTPTarget == nil
      {
        folderSelection.toggleFavorite(url: localURL)
      }
    }
  }

  private func makeSFTPBrowser(
    target: SFTPConnectionTarget,
    provider: SFTPFileProvider,
    initialDirectory: String? = nil
  ) -> ProviderBrowserPresentation {
    let directory = initialDirectory ?? target.initialDirectory
    let initialPath = SFTPConnectionTarget.normalizedRelativePath(directory)
    let initialLocation = FileLocation(remotePath: initialPath, providerID: provider.id)
    sftpConnections.recordRecent(target: target, directory: initialPath)
    providerBrowserLocation = initialLocation
    return makeProviderBrowser(
      title: "\(target.username)@\(target.host)",
      provider: provider,
      initialLocation: initialLocation,
      sftpTarget: target)
  }

  private func makeFTPBrowser(
    target: FTPConnectionTarget,
    provider: FTPFileProvider,
    initialDirectory: String? = nil
  ) -> ProviderBrowserPresentation {
    let directory = initialDirectory ?? target.initialDirectory
    let initialLocation = FileLocation(
      remotePath: FTPConnectionTarget.normalizedAbsolutePath(directory),
      providerID: provider.id)
    ftpConnections.recordRecent(target: target, directory: directory)
    providerBrowserLocation = initialLocation
    return makeProviderBrowser(
      title: "\(target.username)@\(target.host)",
      provider: provider,
      initialLocation: initialLocation,
      ftpTarget: target)
  }

  private func makeProviderBrowser(
    title: String,
    provider: any FileBrowserProvider,
    initialLocation: FileLocation,
    sftpTarget: SFTPConnectionTarget? = nil,
    ftpTarget: FTPConnectionTarget? = nil,
    accessLease: WorkspaceBookmarkAccessLease? = nil
  ) -> ProviderBrowserPresentation {
    ProviderBrowserPresentation(
      title: title,
      browser: FileBrowserSession(
        provider: provider,
        initialLocation: initialLocation,
        workspaceBookmarkAccessLease: accessLease),
      sftpTarget: sftpTarget,
      ftpTarget: ftpTarget)
  }

}

/// 詳細ペインを開閉するツールバーボタン。識別子は旧トグルから維持する。
private struct DetailsDisplayToolbarToggle: View {
  @Binding var mode: DetailsDisplayMode

  var body: some View {
    Button {
      mode = mode.togglingPane
    } label: {
      Label(
        "詳細を表示",
        systemImage: mode == .pane ? "info.circle.fill" : "info.circle")
    }
    .help(mode == .pane ? "詳細を隠す (⌘⇧P)" : "詳細を表示 (⌘⇧P)")
    .accessibilityIdentifier("provider-browser-details-inspector-toggle")
    .accessibilityValue(mode == .pane ? "オン" : "オフ")
  }
}

/// サイドバー背景をタイトルバーまで連続させたまま、詳細領域の分割線だけを隠す。
private struct WindowToolbarSeparatorConfigurator: NSViewRepresentable {
  @Environment(\.themePalette) private var themePalette
  func makeNSView(context _: Context) -> WindowToolbarSeparatorConfigurationView {
    let view = WindowToolbarSeparatorConfigurationView()
    view.applyTheme(themePalette)
    return view
  }

  func updateNSView(_ view: WindowToolbarSeparatorConfigurationView, context _: Context) {
    view.applyTheme(themePalette)
    view.removeToolbarSeparators()
  }
}

@MainActor
private final class WindowToolbarSeparatorConfigurationView: NSView {
  private weak var observedWindow: NSWindow?
  private let detailToolbarBackground = ToolbarDetailBackgroundView()
  private var themePalette = ThemePalette.standard
  private var themedWindowBackground: NSColor?

  func applyTheme(_ palette: ThemePalette) {
    guard themePalette != palette else { return }
    themePalette = palette
    themedWindowBackground = palette.windowBackground?.nsColor
    detailToolbarBackground.applyTheme(palette.toolbarBackground)
    applyWindowBackground()
  }

  private func applyWindowBackground() {
    guard let window else { return }
    if let themedWindowBackground {
      if window.backgroundColor != themedWindowBackground {
        window.backgroundColor = themedWindowBackground
      }
    } else if window.backgroundColor != .windowBackgroundColor {
      window.backgroundColor = .windowBackgroundColor
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    observeCurrentWindow()
    applyWindowBackground()
    removeToolbarSeparators()
    Task { @MainActor [weak self] in
      self?.removeToolbarSeparators()
    }
  }

  func removeToolbarSeparators() {
    guard let window else { return }
    if window.titlebarSeparatorStyle != .none {
      window.titlebarSeparatorStyle = .none
    }
    guard let toolbar = window.toolbar else { return }
    var trackingItem: NSTrackingSeparatorToolbarItem?
    if let sidebarToggle = toolbar.items.first(where: {
      $0.itemIdentifier == .toggleSidebar
    }) {
      sidebarToggle.label = ""
      sidebarToggle.title = ""
    }
    for item in toolbar.items
    where item is NSTrackingSeparatorToolbarItem
      || item.itemIdentifier.rawValue.contains("splitViewSeparator")
    {
      item.isHidden = true
      trackingItem = trackingItem ?? item as? NSTrackingSeparatorToolbarItem
    }
    updateDetailToolbarBackground(in: window, trackingItem: trackingItem)
  }

  private func updateDetailToolbarBackground(
    in window: NSWindow,
    trackingItem: NSTrackingSeparatorToolbarItem?
  ) {
    guard let trackingItem,
      let rootView = window.contentView?.superview,
      let toolbarView = descendant(in: rootView, className: "NSToolbarView")
    else {
      detailToolbarBackground.removeFromSuperview()
      return
    }

    let dividerIndex = trackingItem.dividerIndex
    guard trackingItem.splitView.arrangedSubviews.indices.contains(dividerIndex) else {
      detailToolbarBackground.removeFromSuperview()
      return
    }
    let leadingPane = trackingItem.splitView.arrangedSubviews[dividerIndex]
    let sidebarBoundaryInWindow = trackingItem.splitView.convert(
      NSPoint(x: leadingPane.frame.maxX, y: leadingPane.frame.midY),
      to: nil)
    let sidebarBoundary = toolbarView.convert(sidebarBoundaryInWindow, from: nil).x
    let backgroundMinX = min(
      max(sidebarBoundary, toolbarView.bounds.minX),
      toolbarView.bounds.maxX)

    if detailToolbarBackground.superview !== toolbarView {
      detailToolbarBackground.removeFromSuperview()
      toolbarView.addSubview(
        detailToolbarBackground,
        positioned: .below,
        relativeTo: toolbarView.subviews.first)
    }
    detailToolbarBackground.frame = NSRect(
      x: backgroundMinX,
      y: toolbarView.bounds.minY,
      width: toolbarView.bounds.maxX - backgroundMinX,
      height: toolbarView.bounds.height)
  }

  private func descendant(in view: NSView, className: String) -> NSView? {
    if NSStringFromClass(type(of: view)) == className {
      return view
    }
    for subview in view.subviews {
      if let match = descendant(in: subview, className: className) {
        return match
      }
    }
    return nil
  }

  private func observeCurrentWindow() {
    guard observedWindow !== window else { return }
    if let observedWindow {
      NotificationCenter.default.removeObserver(
        self,
        name: NSWindow.didUpdateNotification,
        object: observedWindow)
    }
    observedWindow = window
    if let window {
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(windowDidUpdate),
        name: NSWindow.didUpdateNotification,
        object: window)
    }
  }

  @objc private func windowDidUpdate(_: Notification) {
    removeToolbarSeparators()
  }
}

private final class ToolbarDetailBackgroundView: NSView {
  private let materialView = NSVisualEffectView()
  private let colorView = NSView()
  private var themeBackground: ThemeRGB?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    materialView.material = .contentBackground
    materialView.blendingMode = .withinWindow
    materialView.state = .active
    for view in [materialView, colorView] {
      view.frame = bounds
      view.autoresizingMask = [.width, .height]
      addSubview(view)
    }
    colorView.wantsLayer = true
    colorView.isHidden = true
  }

  func applyTheme(_ background: ThemeRGB?) {
    guard themeBackground != background else { return }
    themeBackground = background
    materialView.isHidden = background != nil
    colorView.isHidden = background == nil
    colorView.layer?.backgroundColor = background?.nsColor.cgColor
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:)は使用しません")
  }

  override func hitTest(_: NSPoint) -> NSView? {
    nil
  }
}

private struct SFTPHostKeyApproval: Identifiable {
  let id = UUID()
  let target: SFTPConnectionTarget
  let request: SFTPHostKeyApprovalRequest
  var isUpdate = false

  var alertTitle: String {
    isUpdate ? "SFTPホスト鍵の変更を確認" : "SFTPサーバーを確認"
  }

  var confirmationTitle: String {
    isUpdate ? "鍵を更新" : "接続を続ける"
  }

  var alertMessage: String {
    let guidance: String
    if isUpdate {
      guidance = "以前と異なる鍵です。信頼できることを確認してから更新してください。"
    } else {
      guidance = "このサーバーには初めて接続します。信頼できる接続先であることを確認してから続けてください。"
    }
    let host = request.host.isEmpty ? target.host : request.host
    let port = request.host.isEmpty ? target.port : request.port
    let prefix =
      host == target.finalHop.host && port == target.finalHop.port
      ? "" : String(localized: "踏み台") + " "
    return [
      prefix + "\(host):\(port)", guidance,
      SFTPHostKeyTrustStore.fingerprint(for: request.publicKey),
    ]
    .joined(separator: "\n\n")
  }
}

struct LaunchEmptyStateView: View {
  @Environment(\.themePalette) private var themePalette
  let content: LaunchContent
  let chooseFolder: () -> Void

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: "folder")
        .font(.system(size: 44, weight: .regular))
        .foregroundStyle(.secondary)
      Text(content.title)
        .font(.title2)
        .fontWeight(.semibold)
      Text(content.message)
        .foregroundStyle(.secondary)
      Button("フォルダを選択", action: chooseFolder)
    }
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(
      themePalette.windowBackground.map { AnyShapeStyle($0.color) }
        ?? AnyShapeStyle(.background)
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("launch-empty-state")
  }
}
