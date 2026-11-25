import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum ProviderBrowserSearchToolbarPlacement: Equatable {
  case toolbar
}

enum ProviderBrowserSearchToolbarConfiguration {
  static let placement = ProviderBrowserSearchToolbarPlacement.toolbar
  static let prompt = "ファイルを検索"

  static var swiftUIPlacement: SearchFieldPlacement {
    switch placement {
    case .toolbar:
      .toolbar
    }
  }

  static func focusRequest(for action: FileBrowserCommand.Action) -> Bool? {
    switch action {
    case .focusSearch:
      true
    case .endSearch:
      false
    default:
      nil
    }
  }
}

struct ProviderBrowserPresentation {
  let title: String
  let browser: FileBrowserSession
  let sftpTarget: SFTPConnectionTarget?
  let ftpTarget: FTPConnectionTarget?

  init(
    title: String,
    browser: FileBrowserSession,
    sftpTarget: SFTPConnectionTarget? = nil,
    ftpTarget: FTPConnectionTarget? = nil
  ) {
    self.title = title
    self.browser = browser
    self.sftpTarget = sftpTarget
    self.ftpTarget = ftpTarget
  }
}

@Observable
@MainActor
final class ProviderBrowserSession: Identifiable {
  let id: UUID
  var title: String
  let workspace: FileWorkspaceModel
  private var sftpTargets: [FileProviderID: SFTPConnectionTarget] = [:]
  private var ftpTargets: [FileProviderID: FTPConnectionTarget] = [:]
  private let detailsInspectorPreferencesStore: DetailsInspectorPreferencesStore

  /// 詳細の自動表示先。ウィンドウ・セッションをまたいでUserDefaultsへ永続化する。
  var detailsDisplayMode: DetailsDisplayMode {
    didSet {
      guard detailsDisplayMode != oldValue else { return }
      persistDetailsInspectorPreferences()
    }
  }
  /// 詳細ペインの幅(ユーザーがドラッグ調整した値)。同じくUserDefaultsへ永続化する。
  var detailsInspectorWidth: Double {
    didSet {
      guard detailsInspectorWidth != oldValue else { return }
      persistDetailsInspectorPreferences()
    }
  }

  init(
    title: String,
    browser: FileBrowserSession,
    connectionID _: FileProviderConnectionID?,
    sftpTarget: SFTPConnectionTarget?,
    ftpTarget: FTPConnectionTarget? = nil,
    initialViewMode: FileBrowserViewMode = .list,
    detailsInspectorPreferencesStore: DetailsInspectorPreferencesStore =
      DetailsInspectorPreferencesStore()
  ) {
    id = UUID()
    self.title = title
    workspace = FileWorkspaceModel(initialBrowser: browser, initialViewMode: initialViewMode)
    self.detailsInspectorPreferencesStore = detailsInspectorPreferencesStore
    let preferences = detailsInspectorPreferencesStore.load()
    detailsDisplayMode = preferences.mode
    detailsInspectorWidth = preferences.width
    if let sftpTarget {
      sftpTargets[browser.providerID] = sftpTarget
    }
    if let ftpTarget {
      ftpTargets[browser.providerID] = ftpTarget
    }
  }

  init(
    title: String,
    workspace: FileWorkspaceModel,
    detailsInspectorPreferencesStore: DetailsInspectorPreferencesStore =
      DetailsInspectorPreferencesStore()
  ) {
    id = UUID()
    self.title = title
    self.workspace = workspace
    self.detailsInspectorPreferencesStore = detailsInspectorPreferencesStore
    let preferences = detailsInspectorPreferencesStore.load()
    detailsDisplayMode = preferences.mode
    detailsInspectorWidth = preferences.width
  }

  var activeSFTPTarget: SFTPConnectionTarget? {
    sftpTargets[workspace.activeTab.browser.providerID]
  }

  func sftpTarget(for providerID: FileProviderID) -> SFTPConnectionTarget? {
    sftpTargets[providerID]
  }

  func registerSFTPTarget(_ target: SFTPConnectionTarget, for providerID: FileProviderID) {
    sftpTargets[providerID] = target
  }

  var activeFTPTarget: FTPConnectionTarget? {
    ftpTargets[workspace.activeTab.browser.providerID]
  }

  func ftpTarget(for providerID: FileProviderID) -> FTPConnectionTarget? {
    ftpTargets[providerID]
  }

  func registerFTPTarget(_ target: FTPConnectionTarget, for providerID: FileProviderID) {
    ftpTargets[providerID] = target
  }

  var showsSecondaryPane: Bool {
    get { workspace.showsSecondaryPane }
    set { workspace.setShowsSecondaryPane(newValue) }
  }

  private func persistDetailsInspectorPreferences() {
    detailsInspectorPreferencesStore.save(
      DetailsInspectorPreferences(
        mode: detailsDisplayMode,
        width: detailsInspectorWidth))
  }

  func prepareForPresentation() {
    if !workspace.activeTab.browser.isWorkspaceRemotePlaceholder {
      workspace.activeTab.browser.loadIfNeeded()
    }
  }

  func replaceActiveBrowser(
    with browser: FileBrowserSession,
    title: String,
    sftpTarget: SFTPConnectionTarget?,
    ftpTarget: FTPConnectionTarget? = nil
  ) {
    workspace.replaceActiveBrowser(with: browser)
    browser.loadIfNeeded()
    self.title = title
    if let sftpTarget {
      sftpTargets[browser.providerID] = sftpTarget
    }
    if let ftpTarget {
      ftpTargets[browser.providerID] = ftpTarget
    }
  }

}

private struct ProviderTransferDestinationView: View {
  let workspace: FileWorkspaceModel
  let movesItems: Bool
  let sections: [ProviderTransferDestinationSection]
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(movesItems ? "移動先を選択" : "コピー先を選択")
        .font(.title2)
        .fontWeight(.semibold)
      Text(movesItems ? "選んだ場所へ移動します。" : "選んだ場所へコピーします。")
        .foregroundStyle(.secondary)
      List {
        ForEach(sections) { section in
          Section(section.title) {
            ForEach(section.destinations) { destination in
              Button {
                if let session = destination.makeDestination() {
                  workspace.transferSelectedItems(to: session, wasMove: movesItems)
                }
                dismiss()
              } label: {
                HStack {
                  Text(destination.title)
                  Spacer()
                  if let reason = destination.disabledReason {
                    Text(reason)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                }
              }
              .disabled(destination.disabledReason != nil)
              .accessibilityIdentifier("provider-transfer-destination-\(destination.id)")
            }
          }
        }
      }
      .frame(minWidth: 420, minHeight: 260)
      HStack {
        Button("その他のフォルダ…") {
          chooseOtherFolder()
        }
        .accessibilityIdentifier("provider-transfer-destination-other-folder")
        Spacer()
        Button("キャンセル", action: dismiss.callAsFunction)
      }
    }
    .padding()
  }

  private func chooseOtherFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = movesItems ? "移動" : "コピー"
    guard panel.runModal() == .OK, let url = panel.url else { return }

    let provider = LocalFileProvider()
    let destination = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(directoryURL: url, providerID: provider.id))
    workspace.transferSelectedItems(to: destination, wasMove: movesItems)
    dismiss()
  }
}

@MainActor
enum PaneInputDiagnostic {
  /// キー内容や位置情報は記録せず、復帰クリックとコマンド実行を区別する。
  static var currentEvent: String {
    let event = NSApp.currentEvent
    return "イベント種別=\(event.map { String($0.type.rawValue) } ?? "なし") "
      + "アプリ有効=\(NSApp.isActive) キーウィンドウ=\(event?.window?.isKeyWindow ?? false) "
      + "ウィンドウ番号=\(event?.windowNumber ?? -1)"
  }
}

struct FileBrowserCommand: Identifiable {
  enum Action {
    case goBack
    case goForward
    case openParent
    case createDirectory
    case deleteSelectedItem
    case copy
    case cut
    case paste
    case movePaste
    case showOriginal
    case chooseTransferDestination(movesItems: Bool)
    case undoLastTransfer
    case retryLastTransfer
    case refresh
    case setBrowserViewMode(FileBrowserViewMode)
    case setSortOrder(FileItemSortOrder)
    case toggleSortDirection
    case showDisplayOptions
    case increaseIconSize
    case decreaseIconSize
    case goToLocation
    case toggleHiddenFiles
    case openSelectedItem
    case openWithApplication
    case showArchiveContents
    case showPackageContents
    case previewSelectedItem
    case showSelectedItemInfo
    case editFinderTags
    case createArchive(format: ArchiveFormat)
    case extractArchive(destination: ArchiveExtractionDestination)
    case cancelArchive
    case editExternally
    case renameSelectedItem
    case batchRenameSelectedItems
    case showQuickSelect
    case selectAll
    case clearSelection
    case selectNext
    case selectPrevious
    case selectNextPage
    case selectPreviousPage
    case focusSearch
    case endSearch
    case moveToOppositePane
    case copyToOppositePane
    case toggleSecondaryPane
    case toggleSyncBrowsing
    case toggleDetailsInspector
    case toggleCurrentFavorite
    case toggleSelectedFolderFavorites
    case shareSelectedItems
    case closeConnection
    case duplicateSelectedItem
    case revealInFinder
    case copyPath
    case copyFileName
    case openInTerminal
    case compareFolders
    case executeFolderSync
    case revealSearchResult
  }

  let id = UUID()
  let action: Action
}

struct ProviderBrowserView: View {
  @Environment(\.themePalette) private var themePalette
  @State private var isCreatingDirectory = false
  @State private var newDirectoryName = ""
  @State private var goToPath = ""
  @State private var renamingItem: FileItem?
  @State private var renamingBrowser: FileBrowserSession?
  @State private var batchRenamingItems = [FileItem]()
  @State private var batchRenamingBrowser: FileBrowserSession?
  @State private var infoItems: [FileItem] = []
  @State private var isPresentingItemInfo = false
  @State private var finderTagEditorRequest: FinderTagEditorRequest?
  @State private var renamedItemName = ""
  @Binding private var browserViewMode: FileBrowserViewMode
  @State private var displayOptions: FileBrowserDisplayOptions
  @State private var showsHiddenFiles = false
  @State private var isPresentingDisplayOptions = false
  @State private var isPresentingGoToFolder = false
  @State private var isPresentingTransferDestination = false
  @State private var transferDestinationMovesItems = false
  @State private var isPresentingQuickSelect = false
  @State private var quickSelectPattern = ""
  @State private var quickSelectIsCaseSensitive = false
  @State private var quickSelectInterpretsAsRegex = false
  @State private var quickSelectMode = QuickSelectMode.replace
  @State private var quickLookController = QuickLookController()
  @State private var openWithApplicationMenu = OpenWithApplicationMenu()
  @State private var remoteEditController = RemoteEditController.shared
  @State private var conflictCopyName = ""
  @State private var transferActivity = TransferActivityModel()
  @State private var folderComparisonPresentation = FolderComparisonPresentationState()
  @FocusState private var isSearchFocused: Bool
  @Binding private var command: FileBrowserCommand?
  @Binding private var showsSecondaryPane: Bool
  @Binding private var detailsDisplayMode: DetailsDisplayMode
  @Binding private var detailsInspectorWidth: Double
  private let title: String
  private let workspace: FileWorkspaceModel
  private let onLocationChanged: (FileLocation) -> Void
  private let displayOptionsStore: FileBrowserDisplayOptionsStore
  private let gitStatusPreferences: GitStatusPreferencesStore
  private let archivePreferencesStore: ArchivePreferencesStore
  private let transferDestinationSections:
    ((FileWorkspaceModel) -> [ProviderTransferDestinationSection])?
  private let favoriteContextMenuItem: (([FileItem], FileBrowserSession) -> FileContextMenuItem?)?
  private let requestFolderAccess: () -> Void

  init(
    title: String,
    workspace: FileWorkspaceModel,
    command: Binding<FileBrowserCommand?>,
    browserViewMode: Binding<FileBrowserViewMode>,
    showsSecondaryPane: Binding<Bool>,
    detailsDisplayMode: Binding<DetailsDisplayMode>,
    detailsInspectorWidth: Binding<Double>,
    displayOptionsStore: FileBrowserDisplayOptionsStore = FileBrowserDisplayOptionsStore(),
    gitStatusPreferences: GitStatusPreferencesStore = .shared,
    archivePreferencesStore: ArchivePreferencesStore = .shared,
    transferDestinationSections: ((FileWorkspaceModel) -> [ProviderTransferDestinationSection])? =
      nil,
    favoriteContextMenuItem: (([FileItem], FileBrowserSession) -> FileContextMenuItem?)? = nil,
    requestFolderAccess: @escaping () -> Void = {},
    onLocationChanged: @escaping (FileLocation) -> Void
  ) {
    self.title = title
    _command = command
    _browserViewMode = browserViewMode
    _showsSecondaryPane = showsSecondaryPane
    _detailsDisplayMode = detailsDisplayMode
    _detailsInspectorWidth = detailsInspectorWidth
    self.workspace = workspace
    _transferActivity = State(
      initialValue: TransferActivityModel.forBrowser(
        resume: { job in workspace.resumeTransferJob(job) }))
    self.displayOptionsStore = displayOptionsStore
    self.gitStatusPreferences = gitStatusPreferences
    self.archivePreferencesStore = archivePreferencesStore
    _displayOptions = State(initialValue: displayOptionsStore.load())
    self.transferDestinationSections = transferDestinationSections
    self.favoriteContextMenuItem = favoriteContextMenuItem
    self.requestFolderAccess = requestFolderAccess
    self.onLocationChanged = onLocationChanged
  }

  var body: some View {
    mainContent
      .sheet(item: folderComparisonModelBinding) { model in
        FolderComparisonView(model: model)
      }
  }

  private var folderComparisonModelBinding: Binding<FolderComparisonModel?> {
    Binding(
      get: { folderComparisonPresentation.model },
      set: { if $0 == nil { folderComparisonPresentation.dismiss() } })
  }

  private var mainContent: some View {
    VStack(spacing: 0) {
      if externalEditCount > 0 {
        Text("外部編集中: \(externalEditCount)件")
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("remote-edit-status")
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 10)
          .padding(.vertical, 4)
      }
      HSplitView {
        Group {
          if workspace.showsSecondaryPane,
            let primaryTab = workspace.tab(for: .primary),
            let secondaryTab = workspace.tab(for: .secondary)
          {
            HSplitView {
              browserPane(primaryTab, pane: .primary)
              browserPane(secondaryTab, pane: .secondary)
            }
          } else if let primaryTab = workspace.tab(for: workspace.activePane) {
            browserPane(primaryTab, pane: workspace.activePane)
          }
        }
        .layoutPriority(1)
        // pane以外ではこの分岐自体が評価されないため、
        // detailsInspectorItems(選択のフィルタリング)もDetailsInspectorPaneの
        // 詳細取得・サムネイル生成も一切発生しない(性能要件: 閉じている間は追従処理を
        // 一切動かさない)。
        if detailsDisplayMode == .pane {
          detailsInspectorPane
        }
      }
      TransferActivityBar(model: transferActivity, onRetry: retryTransferJob)
    }
    .navigationTitle(activeModel.isRecentFilesActive ? "最近の項目" : title)
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    {
      _ in openWithApplicationMenu.invalidate()
    }
    .searchable(
      text: searchTextBinding,
      placement: ProviderBrowserSearchToolbarConfiguration.swiftUIPlacement,
      prompt: Text(ProviderBrowserSearchToolbarConfiguration.prompt)
    )
    .searchScopes(searchScopeBinding) {
      if !activeModel.isRecentFilesActive {
        Text(SearchScope.currentFolder.displayName)
          .tag(SearchScope.currentFolder)
        if activeModel.supportsThisMacSearch {
          Text(SearchScope.thisMac.displayName)
            .tag(SearchScope.thisMac)
        }
      }
    }
    .searchFocused($isSearchFocused)
    .onChange(of: command?.id) { _, _ in
      guard let command else { return }
      let activeModel = activeModel
      if let requestsFocus = ProviderBrowserSearchToolbarConfiguration.focusRequest(
        for: command.action)
      {
        isSearchFocused = requestsFocus
      }
      switch command.action {
      case .goBack:
        workspace.goBack(in: workspace.activePane)
      case .goForward:
        workspace.goForward(in: workspace.activePane)
      case .openParent:
        guard !activeModel.isRecentFilesActive else { break }
        workspace.openParent(in: workspace.activePane)
      case .createDirectory:
        guard !activeModel.isRecentFilesActive else { break }
        newDirectoryName = ""
        isCreatingDirectory = true
      case .deleteSelectedItem:
        deleteSelectedItem()
      case .copy:
        workspace.copySelectedItems()
      case .cut:
        workspace.cutSelectedItems()
      case .movePaste:
        workspace.pasteItems(moving: true)
      case .showOriginal:
        if workspace.activeTab.selectedItemURLs.count == 1,
          let url = workspace.activeTab.selectedItemURLs.first,
          let item = activeModel.selectableItemsSnapshot.item(for: url)
        {
          activeModel.showOriginal(item)
        }
      case .paste:
        workspace.pasteItems()
      case .chooseTransferDestination(let movesItems):
        transferDestinationMovesItems = movesItems
        isPresentingTransferDestination = true
      case .undoLastTransfer:
        workspace.undoLastTransfer()
      case .retryLastTransfer:
        activeModel.retryLastTransfer()
      case .refresh:
        activeModel.refresh()
      case .setBrowserViewMode(let mode):
        applyBrowserViewMode(mode)
      case .setSortOrder(let order):
        workspace.setSortOrder(order)
      case .toggleSortDirection:
        workspace.toggleSortDirection()
      case .showDisplayOptions:
        isPresentingDisplayOptions = true
      case .increaseIconSize:
        displayOptions.iconSize = displayOptions.iconSize.larger()
      case .decreaseIconSize:
        displayOptions.iconSize = displayOptions.iconSize.smaller()
      case .goToLocation:
        goToPath = activeModel.currentPathDescription
        isPresentingGoToFolder = true
      case .toggleHiddenFiles:
        showsHiddenFiles.toggle()
      case .openSelectedItem:
        workspace.openSelectedItem(in: workspace.activePane)
      case .openWithApplication:
        openSelectedItemWithApplication()
      case .showArchiveContents:
        showSelectedArchiveContents()
      case .showPackageContents:
        showSelectedPackageContents()
      case .previewSelectedItem:
        previewSelectedItem()
      case .showSelectedItemInfo:
        showSelectedItemInfo()
      case .editFinderTags:
        presentFinderTagEditor(items: selectedItems, browser: activeModel)
      case .createArchive(let format):
        guard !activeModel.isRecentFilesActive else { break }
        createArchiveFromSelection(format: format)
      case .extractArchive(let destination):
        guard !activeModel.isRecentFilesActive else { break }
        extractSelectedArchive(to: destination)
      case .cancelArchive:
        activeModel.cancelArchiveOperation()
      case .editExternally:
        editSelectedItemExternally()
      case .renameSelectedItem:
        presentRename(
          browser: activeModel,
          selectedItemURLs: workspace.activeTab.selectedItemURLs)
      case .batchRenameSelectedItems:
        guard !activeModel.isRecentFilesActive else { break }
        presentBatchRename(
          browser: activeModel,
          selectedItemURLs: workspace.activeTab.selectedItemURLs)
      case .showQuickSelect:
        isPresentingQuickSelect = true
      case .selectAll:
        workspace.activeTab.selectedItemURLs = Set(
          visibleItems(for: workspace.activeTab).map(\.url))
      case .clearSelection:
        workspace.activeTab.selectedItemURLs = []
      case .selectNext:
        moveSelection(by: 1)
      case .selectPrevious:
        moveSelection(by: -1)
      case .selectNextPage:
        moveSelection(by: 10)
      case .selectPreviousPage:
        moveSelection(by: -10)
      case .focusSearch:
        break
      case .endSearch:
        activeModel.endSearch()
      case .moveToOppositePane:
        moveSelectedItemsToOppositePane()
      case .copyToOppositePane:
        copySelectedItemsToOppositePane()
      case .toggleSecondaryPane:
        workspace.setShowsSecondaryPane(!workspace.showsSecondaryPane, source: "メニューコマンド")
      case .toggleSyncBrowsing:
        // LaunchView.issueAppMenuCommandがワークスペース状態を直接切り替えるため通常は届かない。
        break
      case .toggleDetailsInspector:
        // LaunchView.issueAppMenuCommandがdetailsDisplayModeを直接切り替えるため
        // (toggleCurrentFavoriteと同じ構造)、ここまでは通常届かない。網羅性のためのno-op。
        break
      case .toggleCurrentFavorite:
        break
      case .toggleSelectedFolderFavorites:
        break
      case .shareSelectedItems:
        shareSelectedItems()
      case .closeConnection:
        break
      case .duplicateSelectedItem:
        duplicateSelectedItem()
      case .revealInFinder:
        revealSelectedItemInFinder()
      case .copyPath:
        copySelectedItemPath(copiesFileName: false)
      case .copyFileName:
        copySelectedItemPath(copiesFileName: true)
      case .openInTerminal:
        openSelectionInTerminal()
      case .compareFolders, .executeFolderSync:
        guard !activeModel.isRecentFilesActive else { break }
        _ = folderComparisonPresentation.handle(command.action, workspace: workspace)
      case .revealSearchResult:
        revealSelectedSearchResult()
      }
      self.command = nil
    }
    .onChange(of: showsHiddenFiles) { _, showsHiddenFiles in
      workspace.setShowsHiddenFiles(showsHiddenFiles)
    }
    .onChange(of: displayOptions) { _, newValue in
      displayOptionsStore.save(newValue)
    }
    .sheet(isPresented: $isPresentingDisplayOptions) {
      FileBrowserDisplayOptionsView(
        browserViewMode: Binding(
          get: { browserViewMode },
          set: { applyBrowserViewMode($0) }),
        displayOptions: $displayOptions,
        sortOrder: Binding(
          get: { workspace.activeTab.sortOrder },
          set: { workspace.setSortOrder($0) }),
        sortAscending: Binding(
          get: { workspace.activeTab.sortAscending },
          set: { ascending in
            guard ascending != workspace.activeTab.sortAscending else { return }
            workspace.toggleSortDirection()
          }),
        showsHiddenFiles: $showsHiddenFiles
      )
    }
    .alert("フォルダへ移動", isPresented: $isPresentingGoToFolder) {
      TextField("パス", text: $goToPath)
      Button("移動") {
        let location = FileLocation(
          remotePath: goToPath,
          providerID: activeModel.currentLocation.providerID)
        activeModel.open(location: location)
      }
      Button("キャンセル", role: .cancel) {}
    }
    .sheet(isPresented: $isPresentingTransferDestination) {
      ProviderTransferDestinationView(
        workspace: workspace,
        movesItems: transferDestinationMovesItems,
        sections: transferDestinationSections?(workspace)
          ?? ProviderTransferDestinationCatalog.makeSections(workspace: workspace))
    }
    .sheet(isPresented: $isPresentingQuickSelect) {
      QuickSelectView(
        pattern: $quickSelectPattern,
        isCaseSensitive: $quickSelectIsCaseSensitive,
        interpretsAsRegex: $quickSelectInterpretsAsRegex,
        mode: $quickSelectMode,
        apply: applyQuickSelect,
        cancel: { isPresentingQuickSelect = false })
    }
    .sheet(item: $finderTagEditorRequest) { request in
      FinderTagEditorSheet(request: request)
    }
    .sheet(isPresented: $isPresentingItemInfo) {
      FileInfoView(
        items: infoItems,
        detailItem: { item in await activeModel.detailedItem(for: item) },
        permissionUpdater: permissionUpdater(for: activeModel),
        finderTagUpdater: finderTagUpdater(for: activeModel),
        thumbnailURLResolver: thumbnailURLResolver(for: activeModel))
    }
    .sheet(
      isPresented: Binding(
        get: { batchRenamingBrowser != nil },
        set: { if !$0 { cancelBatchRename() } }
      )
    ) {
      BatchRenameView(
        items: batchRenamingItems,
        existingItems: batchRenamingBrowser?.items ?? [],
        apply: commitBatchRename,
        cancel: cancelBatchRename
      )
    }
    .alert("新規フォルダ", isPresented: $isCreatingDirectory) {
      TextField("名前", text: $newDirectoryName)
        .accessibilityIdentifier("provider-browser-new-folder-name")
      Button("作成") { activeModel.createDirectory(named: newDirectoryName) }
        .disabled(activeModel.isRecentFilesActive)
      Button("キャンセル", role: .cancel) {}
    }
    .sheet(
      isPresented: Binding(
        get: { renamingItem != nil },
        set: {
          if !$0 {
            renamingItem = nil
            renamingBrowser = nil
          }
        })
    ) {
      VStack(alignment: .leading, spacing: 12) {
        Text("名前を変更")
          .font(.headline)
        RenameTextField(
          text: $renamedItemName,
          originalFullName: renamingItem?.name ?? "",
          baseNameLength: renameBaseNameLength,
          onCommit: commitRename,
          onCancel: cancelRename
        )
        .frame(width: 280, height: 22)
        HStack {
          Spacer()
          Button("キャンセル", role: .cancel, action: cancelRename)
            .keyboardShortcut(.cancelAction)
          Button("変更", action: commitRename)
            .keyboardShortcut(.defaultAction)
        }
      }
      .padding(20)
      .frame(minWidth: 320)
    }
    .alert(
      "ファイル操作エラー",
      isPresented: Binding(
        get: { workspace.fileOperationErrorMessage != nil },
        set: { if !$0 { workspace.clearFileOperationError() } })
    ) {
      Button("OK") { workspace.clearFileOperationError() }
    } message: {
      Text(workspace.fileOperationErrorMessage ?? "")
    }
    .alert(
      "ゴミ箱を利用できません",
      isPresented: Binding(
        get: { !activeModel.pendingPermanentDeleteItems.isEmpty },
        set: { if !$0 { activeModel.cancelPermanentDelete() } })
    ) {
      Button("完全に削除", role: .destructive) {
        activeModel.confirmPermanentDelete()
      }
      Button("キャンセル", role: .cancel) {
        activeModel.cancelPermanentDelete()
      }
      .keyboardShortcut(.defaultAction)
    } message: {
      Text("この場所ではゴミ箱へ移動できません。完全に削除すると元に戻せません。")
    }
    .modifier(transferConflictPresentation)
    .alert(
      "リモートファイルが変更されています",
      isPresented: Binding(
        get: { remoteEditController.conflictSessionID != nil },
        set: { if !$0 { remoteEditController.resolveConflict(.keepLocal) } })
    ) {
      TextField("別名", text: $conflictCopyName)
      Button("上書き", role: .destructive) {
        remoteEditController.resolveConflict(.overwrite)
      }
      Button("別名で保存") {
        remoteEditController.resolveConflict(.saveAs(conflictCopyName))
      }
      Button("最新版を取得") {
        remoteEditController.resolveConflict(.downloadLatest)
      }
      Button("保留", role: .cancel) {
        remoteEditController.resolveConflict(.keepLocal)
      }
    } message: {
      Text("サーバー側の変更を確認しました。未同期の作業コピーは保持されています。")
    }
    .alert(
      "外部編集エラー",
      isPresented: Binding(
        get: { remoteEditController.errorMessage != nil },
        set: { if !$0 { remoteEditController.clearError() } })
    ) {
      Button("OK") { remoteEditController.clearError() }
    } message: {
      Text(remoteEditController.errorMessage ?? "")
    }
  }

  private var transferConflictPresentation: TransferConflictPresentation {
    let browser = workspace.pendingTransferConflictBrowser ?? activeModel
    return TransferConflictPresentation(
      conflict: browser.pendingTransferConflict,
      resolutionNotice: Binding(
        get: { browser.transferResolutionNotice },
        set: { browser.transferResolutionNotice = $0 }),
      resolve: { resolution, applyToRemaining in
        browser.resolvePendingTransferConflict(resolution, applyToRemaining: applyToRemaining)
      })
  }

  private var activeModel: FileBrowserSession {
    workspace.activeTab.browser
  }

  private var searchTextBinding: Binding<String> {
    Binding(
      get: { activeModel.searchText },
      set: { activeModel.setSearchText($0) })
  }

  private var searchScopeBinding: Binding<SearchScope> {
    Binding(
      get: { activeModel.searchScope },
      set: { activeModel.setSearchScope($0) })
  }

  /// 転送バーの「再試行」から呼ばれる。ジョブがこのワークスペースのどちらの向きの
  /// ペイン間転送に属するか(primary→secondaryかsecondary→primaryか)を、既存の
  /// prepareTransferRetry/retryLastTransferの一致判定にそのまま委ねて特定する。
  /// 一致しなければ何もしない(このワークスペースが発生元でない、または該当ペインが
  /// 既に閉じられている場合)。restoreInterruptedTransferではなくprepareTransferRetryを
  /// 使うのは、一覧エラー(errorMessage)を発火させないため(再起動復元とは異なり、
  /// バーの再試行はTransferActivityBar自体が状態を表示している)。
  private func retryTransferJob(_ job: TransferJob) {
    workspace.retryTransferJob(job)
  }

  private var externalEditCount: Int {
    remoteEditController.sessions.count { $0.providerID == activeModel.providerID }
  }

  private func selectionBinding(
    for tab: FileWorkspaceTab,
    pane: FolderPaneID
  ) -> Binding<Set<URL>> {
    Binding(
      get: { tab.selectedItemURLs },
      set: { workspace.selectItems($0, in: pane) })
  }

  @ViewBuilder
  private func browserPane(_ tab: FileWorkspaceTab, pane: FolderPaneID) -> some View {
    let browser = tab.browser
    let effectiveMode = presentationMode(for: tab)
    VStack(spacing: 0) {
      Group {
        if browser.isRecentFilesActive {
          Label("最近の項目", systemImage: "clock")
            .padding(.horizontal, 10)
            .accessibilityLabel("最近の項目")
        } else {
          BreadcrumbBar(
            items: workspace.displayedBreadcrumbs(in: pane),
            name: \.name,
            select: {
              workspace.openBreadcrumb($0, in: pane)
            }
          )
          .accessibilityLabel("現在位置: \(browser.currentPathDescription)")
        }
      }
      .accessibilityIdentifier(breadcrumbAccessibilityIdentifier(for: pane))
      // 専用のクリック領域(旧・Color.clear)を廃し、パンくず行の全幅をBreadcrumbBarへ
      // 使わせる(長いパスでもより多くの階層が見えるようにする)。
      .frame(maxWidth: .infinity, alignment: .leading)
      // パンくず行のどこをクリックしてもそのペインを操作対象へ切り替える
      // (旧・操作対象ボタンの置き換え)。パンくず項目自体のButtonはSwiftUIの標準優先順位で
      // この外側のonTapGestureより優先されるため、階層移動(select)とペイン切替は両立する。
      .contentShape(Rectangle())
      .onTapGesture {
        activate(pane, browser: browser)
      }
      .overlay(alignment: .trailing) {
        if workspace.showsSecondaryPane {
          // VoiceOver/XCUITestがこの要素をアクティベートすると座標クリックになるため、
          // 背後のパンくずButtonではなく、実際に切替アクションを受けるButtonにする。
          // overlayなのでパンくずの幅配分には影響しない。
          Button {
            activate(pane, browser: browser)
          } label: {
            Color.clear
              .frame(width: 24, height: 24)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("provider-browser-pane-\(pane.rawValue)")
          .accessibilityLabel(
            pane == workspace.activePane
              ? "\(pane.title)、操作対象"
              : "\(pane.title)、操作対象にする"
          )
        }
      }
      .padding(.top, 2)
      .padding(.bottom, 1)
      if browser.isSearchActive {
        searchStatus(for: browser)
        if browser.showsThisMacAccessGuidance {
          fullDiskAccessGuidance()
        }
      }
      if let notice = browser.cloudTransferPreparationNotice {
        Text(notice)
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 10)
          .padding(.vertical, 4)
          .accessibilityIdentifier("cloud-transfer-preparation-guidance")
      }
      if browser.archiveInvalidEntryCount > 0 {
        HStack(spacing: 6) {
          Image(systemName: "exclamationmark.triangle")
          Text("安全上の理由で表示しない項目 \(browser.archiveInvalidEntryCount)件")
          Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
      }
      browserContent(tab, pane: pane, browser: browser)
        .accessibilityIdentifier(browserAccessibilityIdentifier(for: pane))
        .background(
          TableDoubleClickMonitor(
            open: {
              // .listはFileListView自体のdoubleActionがopen(item)の正としてダブルクリックを
              // 処理する(activate+browser.openは同じopenクロージャ経由で行われる)ため、
              // ここで2重に開いてしまわないよう何もしない(2重発火防止)。.iconは従来どおり。
              guard
                FileBrowserCapability.supports(
                  .swiftUIItemGestureMonitor, for: effectiveMode)
              else { return }
              workspace.openSelectedItem(in: pane)
            },
            rename: {
              // .listはActivatingTableView(名前セルのその場編集)がクリック・トゥ・リネームの
              // 正として処理するため、ここでシートを二重に開いてしまわないよう何もしない。
              // .iconは従来どおりシートで行う。
              guard
                FileBrowserCapability.supports(
                  .swiftUIItemGestureMonitor, for: effectiveMode)
              else { return }
              activate(pane, browser: browser)
              presentRename(browser: browser, selectedItemURLs: tab.selectedItemURLs)
            }
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        )
        .overlay {
          if browser.isArchiving {
            VStack(spacing: 8) {
              ProgressView(archiveProgressLabel(for: browser))
              Button("アーカイブ処理をキャンセル", action: browser.cancelArchiveOperation)
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
          } else if browser.isLoading && !browser.isSearchActive {
            ProgressView("読み込み中")
          } else if let errorMessage = browser.errorMessage {
            ContentUnavailableView {
              Label("一覧を読み込めません", systemImage: "exclamationmark.triangle")
            } description: {
              Text(errorMessage)
            } actions: {
              Button("再試行") {
                browser.clearError()
                browser.refresh()
              }
            }
          }
        }
        .dropDestination(for: URL.self) { urls, _ in
          guard !browser.isRecentFilesActive,
            FileBrowserCapability.supports(.paneBackgroundDrop, for: effectiveMode)
          else {
            return false
          }
          return transferDroppedItems(urls, to: pane)
        }
    }
    .background {
      PaneHoverActivationMonitor(
        usesNativeList: effectiveMode != .icon,
        isEnabled: {
          workspace.showsSecondaryPane && workspace.activePane != pane && !isSearchFocused
        },
        activate: {
          activate(pane, browser: browser, connectingRestoredRemote: false)
        }
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .task(id: ObjectIdentifier(browser)) {
      if FileBrowserCapability.supports(.columnBrowsing, for: effectiveMode) {
        browser.beginColumnBrowsing()
      }
      browser.restoreRemoteEdits(using: remoteEditController)
      if !browser.isWorkspaceRemotePlaceholder {
        browser.loadIfNeeded()
      }
      if workspace.activePane == pane {
        onLocationChanged(browser.currentLocation)
      }
    }
    .onChange(of: browser.currentLocation) { _, location in
      if workspace.activePane == pane {
        onLocationChanged(location)
      }
    }
    .onChange(of: browser.isSearchActive) { _, _ in
      let mode = presentationMode(for: tab)
      if FileBrowserCapability.supports(.columnBrowsing, for: mode) {
        browser.beginColumnBrowsing()
      } else {
        browser.endColumnBrowsing()
      }
    }
    .onChange(of: browser.previewURL) { _, previewURL in
      if let previewURL {
        quickLookController.show(urls: [previewURL])
      }
    }
    .overlay(alignment: .top) {
      // アクティブペインの明示は全周枠でなく上端のアクセントライン1本にする
      // (全周枠は4辺が視覚ノイズになり内容と近接して窮屈なため。2026-08-25 ユーザー裁定)。
      // 端から端までのベタ塗りは罫線に見え装飾意図が伝わらないため、
      // 左右に余白を取ったカプセル形にする(2026-08-27 ユーザー裁定)。
      // 操作対象の目印は、Macのアクセントカラー設定に左右されないテーマ色で表示する。
      Capsule()
        .fill(
          pane == workspace.activePane && workspace.showsSecondaryPane
            ? themePalette.activePaneIndicator.color
            : Color.clear
        )
        .frame(height: 3)
        .padding(.horizontal, 10)
        .padding(.top, 2)
        .allowsHitTesting(false)
    }
  }

  private func browserAccessibilityIdentifier(for pane: FolderPaneID) -> String {
    let mode = workspace.tab(for: pane).map(presentationMode(for:)) ?? browserViewMode
    let name =
      switch mode {
      case .list: "provider-browser-list"
      case .icon: "provider-browser-icon-grid"
      case .column: "provider-browser-column"
      }
    return pane == .primary ? name : "\(name)-secondary"
  }

  private func breadcrumbAccessibilityIdentifier(for pane: FolderPaneID) -> String {
    pane == .primary ? "provider-browser-breadcrumbs" : "provider-browser-breadcrumbs-secondary"
  }

  /// 由来を解決できない外部ドロップは従来どおり受理しない。Optionキーを押している
  /// 場合だけ、同一ボリューム内のローカル項目でもコピーを強制する。
  private func transferDroppedItems(_ urls: [URL], to pane: FolderPaneID) -> Bool {
    guard workspace.tab(for: pane)?.browser.isRecentFilesActive != true else { return false }
    let trace = DropPreparationTrace(itemCount: urls.count, destinationKind: .paneBackground)
    return workspace.transferDroppedItems(
      urls,
      to: pane,
      copyForced: NSEvent.modifierFlags.contains(.option),
      trace: trace)
  }

  /// リストのフォルダ行を転送先にする。移動/コピー自動判定とOptionコピー強制は
  /// ペイン背景ドロップと同じ経路を使い、行側では転送先フォルダだけを差し替える。
  private func transferDroppedItems(
    _ urls: [URL], into folder: FileItem, to pane: FolderPaneID
  ) -> Bool {
    let trace = DropPreparationTrace(itemCount: urls.count, destinationKind: .folderRow)
    return workspace.transferDroppedItems(
      urls,
      into: folder,
      in: pane,
      copyForced: NSEvent.modifierFlags.contains(.option),
      trace: trace)
  }

  /// カラム背景を転送先にする。途中カラムも対象にできるようFileLocationを明示し、
  /// 移動/コピー自動判定とOptionコピー強制は他のドロップ先と同じ経路へ委譲する。
  private func transferDroppedItems(
    _ urls: [URL], to location: FileLocation, in pane: FolderPaneID
  ) -> Bool {
    guard workspace.tab(for: pane)?.browser.isRecentFilesActive != true else { return false }
    let trace = DropPreparationTrace(itemCount: urls.count, destinationKind: .columnBackground)
    return workspace.transferDroppedItems(
      urls,
      to: location,
      in: pane,
      copyForced: NSEvent.modifierFlags.contains(.option),
      trace: trace)
  }

  private func activate(
    _ pane: FolderPaneID,
    browser: FileBrowserSession,
    selectedItemURLs: Set<URL>? = nil,
    connectingRestoredRemote: Bool = true
  ) {
    if let selectedItemURLs {
      workspace.selectItems(selectedItemURLs, in: pane)
    } else {
      workspace.activatePane(pane, connectingRestoredRemote: connectingRestoredRemote)
    }
    onLocationChanged(browser.currentLocation)
  }

  private func previewSelectedItem() {
    guard workspace.activeTab.selectedItemURLs.count == 1,
      let selectedURL = workspace.activeTab.selectedItemURLs.first,
      let item = activeModel.selectableItemsSnapshot.item(for: selectedURL)
    else {
      return
    }
    activeModel.preview(item)
  }

  /// browserPane本体のFileBrowserContent呼び出しを独立した関数へ切り出したもの。
  /// 引数(展開のonToggleExpand追加を含む)が増えたことでbrowserPane全体が1つの巨大な
  /// SwiftUI式となり、型検査が時間切れ(the compiler is unable to type-check this
  /// expression in reasonable time)になったため、推論範囲を分離する目的の純粋なリファクタ
  /// (見た目・挙動は変えない)。
  @ViewBuilder
  private func browserContent(
    _ tab: FileWorkspaceTab, pane: FolderPaneID, browser: FileBrowserSession
  ) -> some View {
    let presentationMode = presentationMode(for: tab)
    let presentationOptions = FileBrowserSearchPresentation.displayOptions(
      configuredOptions: displayOptions,
      isSearchActive: browser.isSearchActive)
    FileBrowserContent(
      // カラム表示では通常一覧用の全件フィルタ・ツリーフラット化を構築しない。
      // .list/.iconでは従来と同じ値を渡し、両表示モードの挙動・性能は変えない。
      items: FileBrowserCapability.supports(.flatItemProjection, for: presentationMode)
        ? visibleItems(for: tab) : [],
      selectedItemURLs: selectionBinding(for: tab, pane: pane),
      browserViewMode: presentationMode,
      displayOptions: presentationOptions,
      gitStatuses: gitStatusPreferences.isEnabled && browser.supportsGitStatusDisplay
        ? browser.gitStatuses : nil,
      cloudDownloadStatuses: browser.supportsCloudDownloadStatusDisplay && !browser.isSearchActive
        ? browser.cloudDownloadStatuses : nil,
      sortOrder: tab.sortOrder,
      sortAscending: tab.sortAscending,
      onSortRequest: { requestedOrder in
        workspace.applySortRequest(requestedOrder, in: pane)
      },
      nameCell: { item in
        Label(item.name, systemImage: item.systemImageName)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, 2)
      },
      contextMenu: { item in
        let selectedItems = browser.selectableItemsSnapshot.orderedItems(
          for: tab.selectedItemURLs)
        return fileContextMenuContent(
          contextMenuItems(for: item, selectedItems: selectedItems, browser: browser, pane: pane))
      },
      select: { item in
        activate(pane, browser: browser, selectedItemURLs: [item.url])
      },
      selectItems: { urls in
        activate(pane, browser: browser, selectedItemURLs: urls)
      },
      open: { item in
        workspace.open(item, in: pane)
      },
      supportsDragging: true,
      onActivate: {
        activate(pane, browser: browser)
      },
      isActivePane: {
        pane == workspace.activePane
      },
      onCommitInlineRename: { item, newName in
        browser.rename(item, to: newName)
      },
      itemsRevision: browser.treeRowsRevision,
      contextMenuItems: { item in
        let selectedItems = browser.selectableItemsSnapshot.orderedItems(
          for: tab.selectedItemURLs)
        return contextMenuItems(
          for: item, selectedItems: selectedItems, browser: browser, pane: pane)
      },
      backgroundContextMenuItems: {
        backgroundContextMenuItems(browser: browser, pane: pane)
      },
      onDropURLs: { urls in
        transferDroppedItems(urls, to: pane)
      },
      onDropURLsIntoFolder: { urls, folder in
        transferDroppedItems(urls, into: folder, to: pane)
      },
      onDropURLsIntoLocation: { urls, location in
        transferDroppedItems(urls, to: location, in: pane)
      },
      listRows: FileBrowserCapability.supports(.listTreeExpansion, for: presentationMode)
        ? visibleTreeRows(for: tab) : nil,
      onToggleExpand: { item, isOptionClick in
        toggleExpansion(item, recursively: isOptionClick, browser: browser, tab: tab, pane: pane)
      },
      columns: FileBrowserCapability.supports(.columnBrowsing, for: presentationMode)
        ? visibleColumns(for: tab) : [],
      onSelectColumnItems: { selectedURLs, columnLocation in
        // 階層状態の更新前に選択場所を確定し、通常一覧と同じDetailsInspectorSelection
        // 経路へ確実に流す。
        workspace.selectColumnItems(
          selectedURLs, inColumnAt: columnLocation, pane: pane)
      },
      onColumnWidthChange: { columnLocation, width in
        let clampedWidth = FileBrowserColumnWidth.clamped(width)
        browser.setColumnWidth(
          clampedWidth, at: columnLocation, defaultWidth: displayOptions.columnWidth)
        displayOptions.columnWidth = clampedWidth
      },
      browseSignpostID: browser.browseSignpostID,
      onVisibleItemsChange: { visibleItems in
        browser.enrichFinderTags(forVisibleItems: visibleItems)
      },
      revealRequest: browser.revealRequest
    )
    .onChange(of: browser.revealRequest) { _, request in
      guard let request else { return }
      tab.selectRevealedItem(
        for: request,
        visibleItemURLs: visibleItemURLsForArchiveReveal(in: tab))
    }
    .onAppear {
      guard let request = browser.revealRequest else { return }
      tab.selectRevealedItem(
        for: request,
        visibleItemURLs: visibleItemURLsForArchiveReveal(in: tab))
    }
    .onChange(of: gitStatusPreferences.isEnabled) { _, _ in
      browser.applyGitStatusPreference()
    }
  }

  private func visibleItemURLsForArchiveReveal(in tab: FileWorkspaceTab) -> Set<URL> {
    switch presentationMode(for: tab) {
    case .list:
      Set(visibleTreeRows(for: tab).map { $0.item.url })
    case .icon:
      Set(visibleItems(for: tab).map(\.url))
    case .column:
      Set(visibleColumns(for: tab).flatMap { $0.items.map(\.url) })
    }
  }

  private func visibleItems(for tab: FileWorkspaceTab) -> [FileItem] {
    tab.browser.displayItems(
      matching: "",
      sortOrder: tab.sortOrder,
      ascending: tab.sortAscending,
      includesHiddenItems: showsHiddenFiles)
  }

  /// .list専用: 展開状態を反映した深さ付き行配列。.iconはこれを使わない
  /// (FileBrowserContent.listRowsは.list分岐でのみ参照される)。
  private func visibleTreeRows(for tab: FileWorkspaceTab) -> [FileTreeRow] {
    tab.browser.flattenedRows(
      matching: "",
      sortOrder: tab.sortOrder,
      ascending: tab.sortAscending,
      includesHiddenItems: showsHiddenFiles)
  }

  private func visibleColumns(for tab: FileWorkspaceTab) -> [FileBrowserColumn] {
    tab.browser.displayColumns(
      matching: "",
      sortOrder: tab.sortOrder,
      ascending: tab.sortAscending,
      includesHiddenItems: showsHiddenFiles)
  }

  private func applyQuickSelect() {
    let tab = workspace.activeTab
    let mode = presentationMode(for: tab)
    guard FileBrowserCapability.supports(.quickSelect, for: mode) else { return }

    let pattern = QuickSelectPattern(
      quickSelectPattern,
      isCaseSensitive: quickSelectIsCaseSensitive,
      interpretsAsRegex: quickSelectInterpretsAsRegex)
    switch mode {
    case .list:
      applyQuickSelect(
        pattern: pattern,
        to: visibleTreeRows(for: tab).map(\.item),
        currentSelection: tab.selectedItemURLs)
    case .icon:
      applyQuickSelect(
        pattern: pattern,
        to: visibleItems(for: tab),
        currentSelection: tab.selectedItemURLs)
    case .column:
      let columns = visibleColumns(for: tab)
      guard let column = QuickSelectSelection.activeColumn(in: columns) else { break }
      let nextSelection = QuickSelectSelection.applying(
        pattern: pattern,
        mode: quickSelectMode,
        to: column.items,
        currentSelection: column.selectedItemURLs)
      guard nextSelection != column.selectedItemURLs else { break }
      workspace.selectColumnItems(
        nextSelection,
        inColumnAt: column.location,
        pane: workspace.activePane)
    }
    isPresentingQuickSelect = false
  }

  private func applyQuickSelect(
    pattern: QuickSelectPattern,
    to items: [FileItem],
    currentSelection: Set<URL>
  ) {
    let nextSelection = QuickSelectSelection.applying(
      pattern: pattern,
      mode: quickSelectMode,
      to: items,
      currentSelection: currentSelection)
    guard nextSelection != currentSelection else { return }
    workspace.selectItems(nextSelection, in: workspace.activePane)
  }

  private func updateColumnBrowsing() {
    for pane in workspace.visiblePanes {
      guard let tab = workspace.tab(for: pane) else { continue }
      let browser = tab.browser
      let effectiveMode = FileBrowserSearchPresentation.viewMode(
        configuredMode: tab.viewMode,
        isSearchActive: browser.isSearchActive)
      if FileBrowserCapability.supports(.columnBrowsing, for: effectiveMode) {
        browser.beginColumnBrowsing()
      } else {
        browser.endColumnBrowsing()
      }
    }
  }

  private func applyBrowserViewMode(_ mode: FileBrowserViewMode) {
    browserViewMode = mode
    workspace.setViewMode(mode)
    displayOptions.viewMode = mode
    updateColumnBrowsing()
  }

  private func presentationMode(for tab: FileWorkspaceTab) -> FileBrowserViewMode {
    FileBrowserSearchPresentation.viewMode(
      configuredMode: tab.viewMode,
      isSearchActive: tab.browser.isSearchActive)
  }

  @ViewBuilder
  private func searchStatus(for browser: FileBrowserSession) -> some View {
    HStack(spacing: 6) {
      if browser.isSearching {
        ProgressView()
          .controlSize(.small)
      }
      Text(
        browser.isSearching
          ? "検索中（\(browser.searchResults.count)件）"
          : "検索結果 \(browser.searchResults.count)件")
      if browser.searchPartialErrorCount > 0 {
        Text("読めない場所 \(browser.searchPartialErrorCount)件")
      }
      if let notice = browser.searchScopeNotice {
        Text(notice)
      }
      if let limit = browser.searchLimitReached {
        switch limit {
        case .results(let count):
          Text("\(count)件の結果上限に達しました")
        case .visitedDirectories(let count):
          Text("\(count)フォルダの走査上限に達しました")
        }
      }
      Spacer()
      if !browser.isRecentFilesActive {
        Toggle(
          "正規表現",
          isOn: Binding(
            get: { browser.searchUsesRegex },
            set: { browser.setSearchUsesRegex($0) })
        )
        .controlSize(.small)
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 10)
    .padding(.vertical, 4)
    .accessibilityIdentifier("provider-browser-search-status")
  }

  private func fullDiskAccessGuidance() -> some View {
    HStack(spacing: 8) {
      Text(
        String(
          localized: "このMacの検索結果は、アクセスを許可したフォルダに限られます。"))
      Spacer()
      Button(String(localized: "フォルダへのアクセスを許可…")) {
        requestFolderAccess()
      }
      .controlSize(.small)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(themePalette.contentBackground?.color ?? Color(nsColor: .controlBackgroundColor))
    .accessibilityIdentifier("provider-browser-full-disk-access-guidance")
  }

  /// 開閉三角のクリック・←→キーからの展開/折りたたみ要求を受け取る。折りたたみで
  /// 見えなくなった行の選択は自動で除去する(展開はロード完了後にrowsが増えるだけで
  /// 何も隠れないため、除去が必要になるのは折りたたみのときだけ)。
  private func toggleExpansion(
    _ item: FileItem, recursively: Bool, browser: FileBrowserSession, tab: FileWorkspaceTab,
    pane: FolderPaneID
  ) {
    browser.toggleExpansion(of: item, recursively: recursively)
    let rows = visibleTreeRows(for: tab)
    let prunedSelection = FileTreeFlattening.selection(tab.selectedItemURLs, visibleIn: rows)
    if prunedSelection != tab.selectedItemURLs {
      workspace.selectItems(prunedSelection, in: pane)
    }
  }

  private func archiveProgressLabel(for browser: FileBrowserSession) -> String {
    guard let progress = browser.archiveProgress else { return "アーカイブ処理中" }
    let completed = ByteCountFormatter.string(
      fromByteCount: progress.completedBytes,
      countStyle: .file)
    let total = ByteCountFormatter.string(
      fromByteCount: progress.totalBytes,
      countStyle: .file)
    return "アーカイブ処理中 \(progress.percentage)%（\(completed) / \(total)）"
  }

  private func moveSelection(by offset: Int) {
    let items = visibleItems(for: workspace.activeTab)
    guard let firstItem = items.first else { return }
    let currentItem = workspace.activeTab.selectedItemURLs.first.flatMap { selectedURL in
      items.firstIndex { $0.url == selectedURL }
    }
    let initialIndex = currentItem ?? (offset > 0 ? -1 : items.count)
    let proposedIndex = initialIndex + offset
    let index = min(max(proposedIndex, 0), items.count - 1)
    let selectedItem = items.indices.contains(index) ? items[index] : firstItem
    workspace.activeTab.selectedItemURLs = [selectedItem.url]
  }

  private func moveSelectedItemsToOppositePane() {
    guard workspace.canMoveSelectedItemsToOppositePane,
      let destinationTab = workspace.tab(for: workspace.activePane.opposite)
    else { return }
    workspace.transferSelectedItems(to: destinationTab.id, wasMove: true)
  }

  private func copySelectedItemsToOppositePane() {
    guard workspace.canCopySelectedItemsToOppositePane,
      let destinationTab = workspace.tab(for: workspace.activePane.opposite)
    else { return }
    workspace.transferSelectedItems(to: destinationTab.id, wasMove: false)
  }

  private func presentFinderTagEditor(items: [FileItem], browser: FileBrowserSession) {
    guard browser.canEditFinderTags, !items.isEmpty else { return }
    finderTagEditorRequest = FinderTagEditorRequest(browser: browser, items: items)
  }

  private func showSelectedItemInfo() {
    let selectedURLs = workspace.activeTab.selectedItemURLs
    let items = activeModel.selectableItemsSnapshot.orderedItems(for: selectedURLs)
    guard !items.isEmpty else { return }
    infoItems = items
    isPresentingItemInfo = true
  }

  /// 詳細ペイン(インスペクタ)。幅はdetailsInspectorWidthを初期ヒントにし、ユーザーが
  /// ドラッグ調整した結果をbackground(GeometryReader)経由で読み取って書き戻す
  /// (レイアウト自体には影響を与えない標準手法)。
  private var detailsInspectorPane: some View {
    DetailsInspectorPane(
      items: detailsInspectorItems,
      detailItem: { item in await activeModel.detailedItem(for: item) },
      permissionUpdater: permissionUpdater(for: activeModel),
      finderTagUpdater: finderTagUpdater(for: activeModel),
      thumbnailURLResolver: thumbnailURLResolver(for: activeModel)
    )
    .frame(minWidth: 220, idealWidth: detailsInspectorWidth, maxWidth: 420)
    .background(
      GeometryReader { proxy in
        Color.clear
          .onChange(of: proxy.size.width) { _, newWidth in
            detailsInspectorWidth = newWidth
          }
      }
    )
  }

  private func permissionUpdater(
    for model: FileBrowserSession
  ) -> FileInfoContentModel.PermissionUpdater? {
    guard model.canSetPosixPermissions else { return nil }
    return { item, permissions in
      try await model.setPosixPermissions(permissions, for: item)
    }
  }

  private func finderTagUpdater(
    for model: FileBrowserSession
  ) -> FileInfoContentModel.FinderTagUpdater? {
    guard model.canEditFinderTags else { return nil }
    return { items, mutation in
      await model.updateFinderTags(mutation, for: items)
    }
  }

  private func thumbnailURLResolver(
    for model: FileBrowserSession
  ) -> FileInfoContentModel.ThumbnailURLResolver? {
    guard model.canResolveDetailThumbnailURL else { return nil }
    return { item in
      try await model.detailThumbnailURL(for: item)
    }
  }

  /// アクティブペインの選択に追従する表示対象。選択があればその項目群、選択がなければ
  /// 現在フォルダそのものを1件として扱う(件数+合計サイズ表示ではなく通常の単一選択表示に
  /// なる)。自動表示がnoneの間はこのプロパティ自体が参照されない
  /// (mainContent側のif分岐で守られている)。
  private var detailsInspectorItems: [FileItem] {
    DetailsInspectorSelection.resolveItems(
      allItems: activeModel.selectableItems,
      selectedURLs: workspace.activeTab.selectedItemURLs,
      currentFolderItem: currentFolderPlaceholderItem())
  }

  /// 現在フォルダをFileItemとして表すプレースホルダ。locationさえ正しければ
  /// FileBrowserSession.detailedItem(for:)がlocationだけを使って詳細版へ差し替えるため、
  /// url・size・日付は仮値のままでよい(差し替え失敗時のみこの仮値が画面に残る)。
  private func currentFolderPlaceholderItem() -> FileItem? {
    guard !activeModel.isRecentFilesActive else { return nil }
    let location = activeModel.currentLocation
    switch location.path {
    case .local(let url):
      return FileItem(url: url, providerID: location.providerID, isDirectory: true)
    case .remote(let path):
      let name = activeModel.breadcrumbs.last?.name ?? path
      return FileItem(
        remotePath: path,
        url: URL(fileURLWithPath: path),
        providerID: location.providerID,
        isDirectory: true,
        name: name)
    }
  }

  private func showSelectedPackageContents() {
    guard let item = selectedItem,
      FileBrowserSession.localApplicationBundleURL(for: item) != nil
    else { return }
    workspace.showPackageContents(item, in: workspace.activePane)
  }

  private func createArchiveFromSelection(format: ArchiveFormat) {
    let selectedURLs = workspace.activeTab.selectedItemURLs
    let items = activeModel.selectableItemsSnapshot.orderedItems(for: selectedURLs)
    activeModel.createArchive(items, format: format)
  }

  private func extractSelectedArchive(to destination: ArchiveExtractionDestination) {
    guard let item = selectedItem else { return }
    activeModel.extractArchive(item, destination: destination)
  }

  private func editSelectedItemExternally() {
    guard let item = selectedItem, !item.isDirectory else { return }
    let baseName = item.url.deletingPathExtension().lastPathComponent
    conflictCopyName = "\(baseName)-競合.\(item.url.pathExtension)"
    activeModel.editExternally(item, using: remoteEditController)
  }

  private var selectedItem: FileItem? {
    guard workspace.activeTab.selectedItemURLs.count == 1,
      let selectedURL = workspace.activeTab.selectedItemURLs.first
    else { return nil }
    return activeModel.selectableItemsSnapshot.item(for: selectedURL)
  }

  private var selectedItems: [FileItem] {
    let selectedURLs = workspace.activeTab.selectedItemURLs
    return activeModel.selectableItemsSnapshot.orderedItems(for: selectedURLs)
  }

  private func openSelectedItemWithApplication() {
    guard let localURL = selectedItem?.location.localURL else { return }
    presentOpenWithPanel(for: localURL)
  }

  private func showSelectedArchiveContents() {
    guard let item = selectedItem,
      !item.isDirectory,
      item.location.localURL.flatMap(ArchiveFormat.init(url:))?.isBrowsable == true
    else { return }
    workspace.showArchiveContents(item, in: workspace.activePane)
  }

  private func shareSelectedItems() {
    presentSharingPicker(for: selectedItems.compactMap { $0.location.localURL })
  }

  private func copySelectedItemPath(copiesFileName: Bool) {
    guard let item = selectedItem else { return }
    let value =
      copiesFileName
      ? item.name
      : item.location.localURL?.path ?? item.location.remotePath ?? item.url.path
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
  }

  private func revealSelectedSearchResult() {
    guard let item = selectedItem, activeModel.isSearchResult(item) else { return }
    activeModel.revealSearchResult(item)
  }

  private func deleteSelectedItem() {
    let selectedURLs = workspace.activeTab.selectedItemURLs
    let selectedItems = activeModel.selectableItemsSnapshot.orderedItems(for: selectedURLs)
    activeModel.delete(selectedItems)
  }

  private func duplicateSelectedItem() {
    let selectedURLs = workspace.activeTab.selectedItemURLs
    let selectedItems = activeModel.selectableItemsSnapshot.orderedItems(for: selectedURLs)
    activeModel.duplicate(selectedItems)
  }

  /// Finderで表示。localURLを持つ項目(ローカル/マウント済みNAS)だけを対象にする。
  private func revealSelectedItemInFinder() {
    let selectedURLs = workspace.activeTab.selectedItemURLs
    let selectedItems = activeModel.selectableItemsSnapshot.orderedItems(for: selectedURLs)
    let localURLs = selectedItems.compactMap { $0.location.localURL }
    guard !localURLs.isEmpty else { return }
    NSWorkspace.shared.activateFileViewerSelecting(localURLs)
  }

  private func openSelectionInTerminal() {
    let supportsOpenInTerminal = FileBrowserCapability.supports(
      .openInTerminal, for: presentationMode(for: workspace.activeTab))
    guard supportsOpenInTerminal else { return }
    let selectedURLs = workspace.activeTab.selectedItemURLs
    let selectedItems = activeModel.selectableItemsSnapshot.orderedItems(for: selectedURLs)
    guard !activeModel.isRecentFilesActive || !selectedItems.isEmpty else { return }
    openInTerminal(
      DeveloperToolTargetResolver.terminalDirectory(
        selectedItems: selectedItems,
        currentLocation: activeModel.currentLocation))
  }

  private func openInTerminal(_ directoryURL: URL?) {
    guard let directoryURL,
      let terminalURL = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: "com.apple.Terminal")
    else {
      return
    }
    NSWorkspace.shared.open(
      [directoryURL], withApplicationAt: terminalURL,
      configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
  }

  /// コンテキストメニュー項目のデータソース。.icon(SwiftUI .contextMenu)と.list(NSMenu)の
  /// 両方がこのデータから項目・有効条件・動作を組み立てる(単一の実装源泉、DRY)。
  /// グループ順はForkLift/Finder水準に揃えた計画(doc/plans/2026-08-13-context-menu-polish.md)
  /// に従う: 1.開く系 2.削除 3.情報・操作系 4.コピー系(セパレータで区切る)。
  // internal(private不可): メニュー目録テスト(MenuInventoryTests)がこの構築関数を
  // @testable importで直接呼び出し、右クリックメニューの項目退行を検出する。
  func contextMenuItems(
    for item: FileItem,
    selectedItems: [FileItem],
    browser: FileBrowserSession,
    pane: FolderPaneID
  ) -> [FileContextMenuItem] {
    let targets = selectedItems.contains(item) ? selectedItems : [item]
    let localTargetURLs = targets.compactMap { $0.location.localURL }
    let terminalDirectory = DeveloperToolTargetResolver.terminalDirectory(
      selectedItems: targets,
      currentLocation: browser.currentLocation)
    let supportsOpenInTerminal =
      workspace.tab(for: pane).map {
        FileBrowserCapability.supports(.openInTerminal, for: presentationMode(for: $0))
      } ?? false
    let isBrowsableArchive =
      !item.isDirectory && ArchiveFormat(url: item.url)?.isBrowsable == true
    let canBrowseArchive =
      !item.isDirectory
      && item.location.localURL.flatMap(ArchiveFormat.init(url:))?.isBrowsable == true
    let isExtractableArchive = !item.isDirectory && ArchiveFormat(url: item.url) != nil
    let defaultArchiveFormat = archivePreferencesStore.defaultFormat
    let alternateArchiveFormat = defaultArchiveFormat.alternate

    // 1. 開く系
    var menuItems = [
      FileContextMenuItem(title: "開く", systemImage: "arrow.up.forward.app") {
        workspace.open(item, in: pane)
      }
    ]
    if let openWithChildren = openWithMenuItems(for: item, pane: pane, browser: browser) {
      menuItems.append(
        FileContextMenuItem(
          title: "このアプリケーションで開く", systemImage: "app.dashed",
          children: openWithChildren))
    } else {
      menuItems.append(
        FileContextMenuItem(
          title: "このアプリケーションで開く",
          systemImage: "app.dashed",
          isEnabled: false,
          disabledReason: "リモート項目は「外部アプリで編集」を使用してください。"))
    }
    if isBrowsableArchive {
      menuItems.append(
        FileContextMenuItem(
          title: "アーカイブの内容を表示",
          systemImage: "archivebox",
          isEnabled: canBrowseArchive
        ) {
          workspace.showArchiveContents(item, in: pane)
        })
    }
    if FileBrowserSession.localApplicationBundleURL(for: item) != nil {
      menuItems.append(
        FileContextMenuItem(title: "パッケージの内容を表示", systemImage: "shippingbox") {
          workspace.showPackageContents(item, in: pane)
        })
    }
    menuItems.append(.separator())

    // 2. 削除
    let deleteTitle =
      if browser.executableCapabilities.contains(.trash) {
        "ゴミ箱へ移動"
      } else if browser.executableCapabilities.contains(.deletePermanently) {
        "完全に削除…"
      } else {
        "削除"
      }
    menuItems.append(
      FileContextMenuItem(
        title: deleteTitle,
        systemImage: "trash",
        isEnabled:
          !browser.executableCapabilities.intersection([.trash, .deletePermanently]).isEmpty,
        isDestructive: true
      ) {
        activate(pane, browser: browser)
        browser.delete(targets)
      })
    menuItems.append(.separator())

    // 3. 情報・操作系
    let renameMenuItem =
      targets.count >= 2
      ? FileContextMenuItem(
        title: String(localized: "一括リネーム"), systemImage: "pencil.and.list.clipboard",
        isEnabled: !browser.isRecentFilesActive
          && browser.executableCapabilities.contains(.rename)
      ) {
        activate(
          pane,
          browser: browser,
          selectedItemURLs: Set(targets.map(\.url))
        )
        presentBatchRename(browser: browser, selectedItemURLs: Set(targets.map(\.url)))
      }
      : FileContextMenuItem(
        title: "名前を変更", systemImage: "pencil",
        isEnabled: browser.executableCapabilities.contains(.rename)
      ) {
        activate(pane, browser: browser)
        renamedItemName = item.name
        renamingItem = item
        renamingBrowser = browser
      }
    menuItems.append(contentsOf: [
      FileContextMenuItem(title: "情報を見る", systemImage: "info.circle") {
        activate(pane, browser: browser)
        infoItems = targets
        isPresentingItemInfo = true
      },
      renameMenuItem,
      FileContextMenuItem(
        title: "\(defaultArchiveFormat.displayName)に圧縮\(contextMenuTargetSuffix(for: targets))",
        systemImage: "doc.zipper",
        isEnabled: !browser.isRecentFilesActive && browser.canCreateArchive(from: targets)
      ) {
        activate(pane, browser: browser)
        browser.createArchive(targets, format: defaultArchiveFormat)
      },
      FileContextMenuItem(
        title:
          "\(alternateArchiveFormat.displayName)に圧縮\(contextMenuTargetSuffix(for: targets))",
        systemImage: "doc.zipper",
        isEnabled: !browser.isRecentFilesActive && browser.canCreateArchive(from: targets)
      ) {
        activate(pane, browser: browser)
        browser.createArchive(targets, format: alternateArchiveFormat)
      },
      FileContextMenuItem(
        title: "複製", systemImage: "plus.square.on.square",
        isEnabled: browser.canDuplicate
      ) {
        activate(pane, browser: browser)
        browser.duplicate(targets)
      },
      FileContextMenuItem(
        title: "Quick Look",
        systemImage: "eye",
        isEnabled: !item.isDirectory && browser.canResolveDetailThumbnailURL,
        disabledReason:
          browser.canResolveDetailThumbnailURL ? nil : "この接続ではプレビューを利用できません。"
      ) {
        activate(pane, browser: browser)
        browser.preview(item)
      },
      FileContextMenuItem(
        title: "Finderで表示", systemImage: "folder", isEnabled: !localTargetURLs.isEmpty,
        disabledReason: localTargetURLs.isEmpty ? "リモート項目はFinderで表示できません。" : nil
      ) {
        activate(pane, browser: browser)
        NSWorkspace.shared.activateFileViewerSelecting(localTargetURLs)
      },
      FileContextMenuItem(
        title: "ターミナルで開く", systemImage: "terminal",
        isEnabled: supportsOpenInTerminal && terminalDirectory != nil,
        disabledReason: terminalDirectory == nil ? "リモート接続では利用できません。" : nil
      ) {
        activate(pane, browser: browser)
        openInTerminal(terminalDirectory)
      },
      FileContextMenuItem(
        title: "共有…", systemImage: "square.and.arrow.up", isEnabled: !localTargetURLs.isEmpty,
        disabledReason: localTargetURLs.isEmpty ? "リモート項目は共有できません。" : nil
      ) {
        activate(pane, browser: browser)
        presentSharingPicker(for: localTargetURLs)
      },
      FileContextMenuItem(
        title: "外部アプリで編集", systemImage: "square.and.pencil",
        isEnabled: !item.isDirectory && browser.canEditRemotely
      ) {
        activate(pane, browser: browser)
        let baseName = item.url.deletingPathExtension().lastPathComponent
        conflictCopyName = "\(baseName)-競合.\(item.url.pathExtension)"
        browser.editExternally(item, using: remoteEditController)
      },
      FileContextMenuItem(
        title: "\"\(truncatedForContextMenu(item.name))\"をここに展開",
        systemImage: "archivebox",
        isEnabled: !browser.isRecentFilesActive && browser.canArchive && isExtractableArchive
      ) {
        activate(pane, browser: browser)
        browser.extractArchive(item, destination: .currentDirectory)
      },
      FileContextMenuItem(
        title: "\"\(truncatedForContextMenu(item.name))\"を同名フォルダへ展開",
        systemImage: "folder.badge.plus",
        isEnabled: !browser.isRecentFilesActive && browser.canArchive && isExtractableArchive
      ) {
        activate(pane, browser: browser)
        browser.extractArchive(item, destination: .folderNamedAfterArchive)
      },
    ])
    if browser.isSearchResult(item) {
      menuItems.append(
        FileContextMenuItem(title: "場所へ移動", systemImage: "arrow.right.to.line") {
          activate(pane, browser: browser)
          browser.revealSearchResult(item)
        })
    }
    menuItems.append(.separator())

    let tagChoices = FinderTagMenuModel.choices(
      for: targets, standardLabelNames: FinderTagPalette.systemLabelNames,
      canEdit: browser.canEditFinderTags)
    menuItems.append(
      FinderTagMenuModel.paletteItem(choices: tagChoices) { name in
        Task { await browser.toggleFinderTag(name: name, for: targets) }
      })
    menuItems.append(
      FileContextMenuItem(
        title: String(localized: "タグ…"), systemImage: "tag",
        isEnabled: browser.canEditFinderTags,
        disabledReason: browser.canEditFinderTags
          ? nil : String(localized: "この接続ではFinderタグを変更できません。")
      ) {
        presentFinderTagEditor(items: targets, browser: browser)
      })
    menuItems.append(.separator())

    // 4. コピー系
    menuItems.append(contentsOf: [
      FileContextMenuItem(
        title: "コピー\(contextMenuTargetSuffix(for: targets))", systemImage: "doc.on.doc"
      ) {
        activate(pane, browser: browser)
        workspace.copySelectedItems()
      },
      FileContextMenuItem(
        title: "カット", systemImage: "scissors",
        isEnabled: browser.canRemoveItemsAfterCopy
      ) {
        activate(pane, browser: browser)
        workspace.cutSelectedItems()
      },
      FileContextMenuItem(
        title: "ペースト", systemImage: "doc.on.clipboard",
        isEnabled: workspace.canPasteItems(to: browser)
      ) {
        activate(pane, browser: browser)
        workspace.pasteItems()
      },
      FileContextMenuItem(
        title: "パスをコピー", systemImage: "link",
        children: copyPathMenuItems(for: item)),
      FileContextMenuItem(title: "コピー先を選択…", systemImage: "tray.and.arrow.up") {
        activate(pane, browser: browser)
        transferDestinationMovesItems = false
        isPresentingTransferDestination = true
      },
      FileContextMenuItem(
        title: "移動先を選択…", systemImage: "arrowshape.turn.up.right",
        isEnabled: browser.canRemoveItemsAfterCopy
      ) {
        activate(pane, browser: browser)
        transferDestinationMovesItems = true
        isPresentingTransferDestination = true
      },
    ])
    let favoriteTargets = targets.filter(\.isDirectory)
    if let favoriteItem = favoriteContextMenuItem?(favoriteTargets, browser) {
      menuItems.append(favoriteItem)
    }
    return menuItems
  }

  /// 「コピー "名前"」「圧縮 "名前"」等、対象名を埋め込む接尾辞。単一選択は
  /// ` "名前"`(長い名前は中央省略)、複数選択(2件以上)は`(N項目)`。
  private func contextMenuTargetSuffix(for targets: [FileItem]) -> String {
    if targets.count > 1 {
      return "(\(targets.count)項目)"
    }
    guard let name = targets.first?.name else { return "" }
    return " \"\(truncatedForContextMenu(name))\""
  }

  /// メニュー項目に埋め込む対象名の中央省略(約30文字)。
  private func truncatedForContextMenu(_ name: String, maxLength: Int = 30) -> String {
    guard name.count > maxLength else { return name }
    let headCount = (maxLength - 1) / 2
    let tailCount = maxLength - 1 - headCount
    let head = name.prefix(headCount)
    let tail = name.suffix(tailCount)
    return "\(head)…\(tail)"
  }

  /// 「このアプリケーションで開く」サブメニュー。ローカルURLを持つ項目だけに対応する
  /// (SFTP等リモート項目はサブメニュー自体を出さない=nilを返す)。既定アプリを先頭に、
  /// 末尾に「その他…」(NSOpenPanelでアプリを選択)を置く。候補列挙と画像取得は
  /// メニューバーと共通のビルダーがURL単位で短時間キャッシュする。
  private func openWithMenuItems(
    for item: FileItem, pane: FolderPaneID, browser: FileBrowserSession
  ) -> [FileContextMenuItem]? {
    guard let localURL = item.location.localURL else { return nil }
    return openWithApplicationMenu.items(for: localURL) { localURL, appURL in
      activate(pane, browser: browser)
      openLocalFile(localURL, withApplicationAt: appURL)
    } chooseOther: {
      activate(pane, browser: browser)
      presentOpenWithPanel(for: localURL)
    }
  }

  private func presentOpenWithPanel(for localURL: URL) {
    // メニューアクションの実行中(メニュー追跡の終了処理と重なる区間)にrunModalで新たな
    // モーダルセッションを始めると、パネルのXPCサービス接続に失敗する
    // (「開く/保存パネルのサービスに接続できませんでした」)。メニューが完全に閉じた
    // 次のランループで、モーダルセッションを持たないbegin(非モーダル)で開く。
    DispatchQueue.main.async {
      let panel = NSOpenPanel()
      panel.canChooseFiles = true
      panel.canChooseDirectories = false
      // .applicationは抽象型でNSOpenPanelの選択検証に通らないことがある(.appの実体は
      // applicationBundle=ディレクトリパッケージ)。具体型を併記して選択可能にする。
      panel.allowedContentTypes = [.applicationBundle, .application]
      panel.allowsMultipleSelection = false
      panel.directoryURL = URL(fileURLWithPath: "/Applications")
      panel.begin { response in
        guard response == .OK, let appURL = panel.url else { return }
        openLocalFile(localURL, withApplicationAt: appURL)
      }
    }
  }

  private func openLocalFile(_ localURL: URL, withApplicationAt appURL: URL) {
    NSWorkspace.shared.open(
      [localURL], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration(),
      completionHandler: nil)
  }

  /// 「パスをコピー」サブメニュー。ローカル項目はファイルシステムパス、SFTP等リモート項目は
  /// リモートパス文字列をペーストボードへ書き込む。
  private func copyPathMenuItems(for item: FileItem) -> [FileContextMenuItem] {
    let pathString = item.location.localURL?.path ?? item.location.remotePath ?? item.url.path
    return [
      FileContextMenuItem(title: "パス", systemImage: "doc.plaintext") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pathString, forType: .string)
      },
      FileContextMenuItem(title: "ファイル名", systemImage: "textformat") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.name, forType: .string)
      },
    ]
  }

  /// 共有…: NSSharingServicePickerをキーウィンドウの現在のマウス位置付近にアンカーして
  /// 表示する。.list(NSMenu)・.icon(SwiftUI)のどちらから発火してもFileContextMenuItem.action
  /// は同一のクロージャなので、この1実装だけで両ビルダーに対応できる。
  private func presentSharingPicker(for urls: [URL]) {
    guard !urls.isEmpty, let window = NSApp.keyWindow, let contentView = window.contentView else {
      return
    }
    let picker = NSSharingServicePicker(items: urls)
    let mouseLocation = window.mouseLocationOutsideOfEventStream
    let anchorRect = NSRect(origin: mouseLocation, size: .zero)
    picker.show(relativeTo: anchorRect, of: contentView, preferredEdge: .minY)
  }

  /// 項目の外(余白)を右クリックしたときのメニュー。対象アイテムに依存しない操作
  /// (新規フォルダ・ペースト・表示オプション)を並べる。
  // internal(private不可): メニュー目録テスト(MenuInventoryTests)から直接呼び出す。
  func backgroundContextMenuItems(
    browser: FileBrowserSession,
    pane: FolderPaneID
  ) -> [FileContextMenuItem] {
    let terminalDirectory = DeveloperToolTargetResolver.terminalDirectory(
      selectedItems: [], currentLocation: browser.currentLocation)
    let supportsOpenInTerminal =
      workspace.tab(for: pane).map {
        FileBrowserCapability.supports(.openInTerminal, for: presentationMode(for: $0))
      } ?? false
    return [
      FileContextMenuItem(
        title: "新規フォルダ", systemImage: "folder.badge.plus",
        isEnabled: !browser.isRecentFilesActive && browser.executableCapabilities.contains(.write)
      ) {
        activate(pane, browser: browser)
        newDirectoryName = ""
        isCreatingDirectory = true
      },
      FileContextMenuItem(
        title: "ペースト", systemImage: "doc.on.clipboard",
        isEnabled:
          workspace.canPasteItems(to: browser) && browser.executableCapabilities.contains(.write)
      ) {
        activate(pane, browser: browser)
        workspace.pasteItems()
      },
      FileContextMenuItem(
        title: "ターミナルで開く", systemImage: "terminal",
        isEnabled: !browser.isRecentFilesActive && supportsOpenInTerminal
          && terminalDirectory != nil,
        disabledReason: terminalDirectory == nil ? "リモート接続では利用できません。" : nil
      ) {
        activate(pane, browser: browser)
        openInTerminal(terminalDirectory)
      },
      FileContextMenuItem(title: "表示オプションを表示", systemImage: "slider.horizontal.3") {
        activate(pane, browser: browser)
        isPresentingDisplayOptions = true
      },
    ]
  }

  private func presentRename(
    browser: FileBrowserSession,
    selectedItemURLs: Set<URL>
  ) {
    guard selectedItemURLs.count == 1,
      let selectedURL = selectedItemURLs.first,
      let item = browser.selectableItemsSnapshot.item(for: selectedURL),
      browser.executableCapabilities.contains(.rename)
    else {
      return
    }
    renamedItemName = item.name
    renamingItem = item
    renamingBrowser = browser
  }

  private func presentBatchRename(
    browser: FileBrowserSession,
    selectedItemURLs: Set<URL>
  ) {
    guard selectedItemURLs.count >= 2,
      browser.executableCapabilities.contains(.rename)
    else { return }
    let selectedItems = browser.selectableItemsSnapshot.orderedItems(for: selectedItemURLs)
    guard selectedItems.count >= 2 else { return }
    batchRenamingItems = selectedItems
    batchRenamingBrowser = browser
  }

  private func commitBatchRename(
    _ renames: [(item: FileItem, newName: String)]
  ) async {
    guard let browser = batchRenamingBrowser else { return }
    let result = await browser.batchRename(renames)
    workspace.recordBatchRenameUndo(result.successes, in: browser)
    cancelBatchRename()
  }

  private func cancelBatchRename() {
    batchRenamingItems = []
    batchRenamingBrowser = nil
  }

  /// リネーム対象のベース名(拡張子を除く部分。フォルダは拡張子を除かず全体)の文字数。
  /// RenameTextFieldへ渡し、フォーカス確立時にAppKitの既定の全選択をこの範囲へ絞り込む。
  private var renameBaseNameLength: Int {
    guard let renamingItem else { return 0 }
    let baseName =
      renamingItem.isDirectory
      ? renamingItem.name
      : renamingItem.url.deletingPathExtension().lastPathComponent
    return (baseName as NSString).length
  }

  private func commitRename() {
    if let renamingItem, let renamingBrowser {
      renamingBrowser.rename(renamingItem, to: renamedItemName)
    }
    renamingItem = nil
    renamingBrowser = nil
  }

  private func cancelRename() {
    renamingItem = nil
    renamingBrowser = nil
  }
}
