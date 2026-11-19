import Foundation
import Synchronization
import Testing

@testable import PKPane

struct WorkspaceStateTests {
  @Test("ローカル・リモート混在の全ワークスペース状態を往復できる")
  func roundTripsCompleteWorkspaceState() throws {
    let primaryID = UUID()
    let secondaryID = UUID()
    let state = WorkspaceState(
      tabs: [
        WorkspaceTabState(
          id: primaryID,
          location: .local(
            bookmarkData: Data("primary-bookmark".utf8),
            lastKnownPath: "/Users/test/Documents"),
          viewMode: .column),
        WorkspaceTabState(
          id: secondaryID,
          location: .remote(
            providerKind: .sftp,
            connectionID: "sftp-example.test:22:test",
            path: "/srv/projects"),
          viewMode: .icon),
        WorkspaceTabState(
          id: UUID(),
          location: .remote(
            providerKind: .smb,
            connectionID: "1E912FB4-4047-4D5E-89AA-865514CA20C5",
            path: "Design/Current"),
          viewMode: .list),
      ],
      activeTabID: secondaryID,
      pane: WorkspacePaneState(
        showsSecondaryPane: true,
        activePane: .secondary,
        primaryTabID: primaryID,
        secondaryTabID: secondaryID,
        isSyncBrowsingEnabled: true))

    let data = try WorkspaceStateCodec().encode(state)
    let decoded = try WorkspaceStateCodec().decode(data)

    #expect(decoded == state)
    #expect(decoded.pane.isSyncBrowsingEnabled)
  }

  @Test("旧保存データで同期ブラウズ状態が欠落していればオフとして復元する")
  func defaultsMissingSyncBrowsingStateToDisabled() throws {
    let tabID = UUID()
    let state = WorkspaceState(
      tabs: [
        WorkspaceTabState(
          id: tabID,
          location: .remote(
            providerKind: .sftp,
            connectionID: "sftp-example.test:22:test",
            path: "/srv/projects"),
          viewMode: .list)
      ],
      activeTabID: tabID,
      pane: WorkspacePaneState(
        showsSecondaryPane: true,
        activePane: .primary,
        primaryTabID: tabID,
        secondaryTabID: nil,
        isSyncBrowsingEnabled: true))
    let encoded = try WorkspaceStateCodec().encode(state)
    let json = try #require(String(data: encoded, encoding: .utf8))
    let legacyData = try #require(
      json.replacingOccurrences(
        of: ",\"isSyncBrowsingEnabled\":true",
        with: ""
      )
      .data(using: .utf8))

    let decoded = try WorkspaceStateCodec().decode(legacyData)

    #expect(!decoded.pane.isSyncBrowsingEnabled)
  }

  @Test("未知または欠落した表示モードはタブ単位でリストへフォールバックする")
  func fallsBackUnknownOrMissingViewModeToList() throws {
    let tabID = UUID()
    let state = WorkspaceState(
      tabs: [
        WorkspaceTabState(
          id: tabID,
          location: .remote(
            providerKind: .sftp,
            connectionID: "sftp-example.test:22:test",
            path: "/srv/projects"),
          viewMode: .column)
      ],
      activeTabID: tabID,
      pane: WorkspacePaneState(
        showsSecondaryPane: false,
        activePane: .primary,
        primaryTabID: tabID,
        secondaryTabID: nil))
    let encoded = try WorkspaceStateCodec().encode(state)
    let json = try #require(String(data: encoded, encoding: .utf8))
    let unknownModeData = try #require(
      json.replacingOccurrences(
        of: "\"viewMode\":\"カラム\"",
        with: "\"viewMode\":\"将来の表示モード\""
      )
      .data(using: .utf8))
    let missingModeData = try #require(
      json.replacingOccurrences(
        of: ",\"viewMode\":\"カラム\"",
        with: ""
      )
      .data(using: .utf8))

    let unknownModeState = try WorkspaceStateCodec().decode(unknownModeData)
    let missingModeState = try WorkspaceStateCodec().decode(missingModeData)

    #expect(unknownModeState.tabs.first?.viewMode == .list)
    #expect(missingModeState.tabs.first?.viewMode == .list)
  }

  @Test("JSONストアはデータなしを初回起動として扱い保存後に復元する")
  func jsonStoreReturnsNilBeforeFirstSave() throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = JSONWorkspaceStateStore(url: directory.appending(path: "workspace.json"))
    let tabID = UUID()
    let state = WorkspaceState(
      tabs: [
        WorkspaceTabState(
          id: tabID,
          location: .local(
            bookmarkData: Data("bookmark".utf8),
            lastKnownPath: "/Users/test"),
          viewMode: .list)
      ],
      activeTabID: tabID,
      pane: WorkspacePaneState(
        showsSecondaryPane: false,
        activePane: .primary,
        primaryTabID: tabID,
        secondaryTabID: nil))

    #expect(try store.load() == nil)

    try store.save(state)

    #expect(try store.load() == state)
  }

  @Test("ワークスペース既定パスをUIテスト用フォルダへ隔離する")
  func isolatesDefaultWorkspacePathForUITests() {
    let fixtureURL = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)

    let url = JSONWorkspaceStateStore.defaultURL(
      environment: ["PKPANE_UI_TESTING": "1"],
      arguments: ["PKPane", "-ui-test-folder-path", fixtureURL.path])

    #expect(url == fixtureURL.appending(path: ".pkpane-ui-test-workspace.json"))
  }

  @Test("ワークスペース既定パスをユニットテスト用一時領域へ隔離する")
  func isolatesDefaultWorkspacePathForUnitTests() {
    let url = JSONWorkspaceStateStore.defaultURL(
      environment: ["XCTestSessionIdentifier": UUID().uuidString],
      arguments: ["PKPaneTests"])

    #expect(url.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    #expect(url.lastPathComponent == "workspace.json")
    #expect(url.path.contains("PKPaneWorkspaceTests-"))
  }

  @Test("保存したタブ順・現在地・表示モード・ペイン構成を復元する")
  @MainActor
  func restoresLocalTabsAndPaneLayout() throws {
    let primaryURL = try makeTemporaryDirectory()
    let secondaryURL = try makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: primaryURL)
      try? FileManager.default.removeItem(at: secondaryURL)
    }
    let primaryID = UUID()
    let secondaryID = UUID()
    let primaryBookmark = Data("primary".utf8)
    let secondaryBookmark = Data("secondary".utf8)
    let state = WorkspaceState(
      tabs: [
        WorkspaceTabState(
          id: primaryID,
          location: .local(
            bookmarkData: primaryBookmark,
            lastKnownPath: primaryURL.path),
          viewMode: .column),
        WorkspaceTabState(
          id: secondaryID,
          location: .local(
            bookmarkData: secondaryBookmark,
            lastKnownPath: secondaryURL.path),
          viewMode: .icon),
      ],
      activeTabID: secondaryID,
      pane: WorkspacePaneState(
        showsSecondaryPane: true,
        activePane: .secondary,
        primaryTabID: primaryID,
        secondaryTabID: secondaryID,
        isSyncBrowsingEnabled: true))
    let transferQueue = TransferQueue.isolatedForTesting()
    let factory = WorkspaceBrowserFactory(
      bookmarkCodec: WorkspaceTestBookmarkCodec(resolutions: [
        primaryBookmark: primaryURL,
        secondaryBookmark: secondaryURL,
      ]),
      transferQueue: transferQueue)

    let workspace = FileWorkspaceModel(restoring: state, browserFactory: factory)

    #expect(workspace.tabs.map(\.id) == [primaryID, secondaryID])
    #expect(workspace.tab(for: .primary)?.browser.currentLocation.localURL == primaryURL)
    #expect(workspace.tab(for: .secondary)?.browser.currentLocation.localURL == secondaryURL)
    #expect(workspace.tab(for: .primary)?.viewMode == .column)
    #expect(workspace.tab(for: .secondary)?.viewMode == .icon)
    #expect(workspace.showsSecondaryPane)
    #expect(workspace.activePane == .secondary)
    #expect(workspace.activeTabID == secondaryID)
    #expect(workspace.isSyncBrowsingEnabled)
  }

  @Test("壊れたローカルBookmarkだけホームへ戻し残りのタブを復元する")
  @MainActor
  func fallsBackOnlyBrokenLocalBookmarkToHome() throws {
    let homeURL = try makeTemporaryDirectory()
    let validURL = try makeTemporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: homeURL)
      try? FileManager.default.removeItem(at: validURL)
    }
    let brokenID = UUID()
    let validID = UUID()
    let brokenBookmark = Data("broken".utf8)
    let validBookmark = Data("valid".utf8)
    let state = WorkspaceState(
      tabs: [
        WorkspaceTabState(
          id: brokenID,
          location: .local(
            bookmarkData: brokenBookmark,
            lastKnownPath: "/missing"),
          viewMode: .list),
        WorkspaceTabState(
          id: validID,
          location: .local(
            bookmarkData: validBookmark,
            lastKnownPath: validURL.path),
          viewMode: .column),
      ],
      activeTabID: brokenID,
      pane: WorkspacePaneState(
        showsSecondaryPane: true,
        activePane: .primary,
        primaryTabID: brokenID,
        secondaryTabID: validID))
    let transferQueue = TransferQueue.isolatedForTesting()
    let factory = WorkspaceBrowserFactory(
      bookmarkCodec: WorkspaceTestBookmarkCodec(resolutions: [validBookmark: validURL]),
      homeDirectory: homeURL,
      transferQueue: transferQueue)

    let workspace = FileWorkspaceModel(restoring: state, browserFactory: factory)

    #expect(workspace.tab(for: .primary)?.browser.currentLocation.localURL == homeURL)
    #expect(workspace.tab(for: .secondary)?.browser.currentLocation.localURL == validURL)
    #expect(workspace.tab(for: .secondary)?.viewMode == .column)
  }

  @Test("保存Bookmarkのアクセスを開始してから対象フォルダの存在を確認する")
  @MainActor
  func beginsBookmarkAccessBeforeCheckingDirectory() throws {
    let directoryURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let bookmark = Data("scoped".utf8)
    let fileManager = WorkspaceAccessVisibilityFileManager()
    let accessManager = FolderBookmarkAccessManager(
      startAccess: { _ in
        fileManager.accessStarted.withLock { $0 = true }
        return true
      },
      stopAccess: { _ in fileManager.accessStarted.withLock { $0 = false } },
      isSandboxed: { true })
    let factory = WorkspaceBrowserFactory(
      bookmarkCodec: WorkspaceTestBookmarkCodec(resolutions: [bookmark: directoryURL]),
      fileManager: fileManager,
      homeDirectory: directoryURL.appending(path: "Fallback"),
      accessManager: accessManager,
      transferQueue: .isolatedForTesting())

    let browser = factory.makeBrowser(
      for: .local(bookmarkData: bookmark, lastKnownPath: directoryURL.path))

    #expect(browser.currentLocation.localURL == directoryURL)
    #expect(fileManager.accessStarted.withLock { $0 })
  }

  @Test("復元できないBookmarkの既定フォールバックはコンテナではなく実ホームを使う")
  @MainActor
  func defaultsBrokenBookmarkFallbackToUserHome() {
    let factory = WorkspaceBrowserFactory(
      bookmarkCodec: WorkspaceTestBookmarkCodec(resolutions: [:]),
      transferQueue: .isolatedForTesting())

    let browser = factory.makeBrowser(
      for: .local(bookmarkData: Data("broken".utf8), lastKnownPath: "/missing"))

    #expect(browser.currentLocation.localURL == UserHomeDirectory.current)
  }

  @Test("ホームの許可があれば個別Bookmarkを復元できないタブも元の場所へ戻す")
  @MainActor
  func restoresHomeChildWithInheritedAccess() throws {
    let homeURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: homeURL) }
    let directoryURL = homeURL.appending(path: "Documents", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    let manager = FolderBookmarkAccessManager(
      startAccess: { _ in true }, stopAccess: { _ in }, isSandboxed: { true })
    var inheritedPaths: [URL] = []
    let factory = WorkspaceBrowserFactory(
      bookmarkCodec: WorkspaceTestBookmarkCodec(resolutions: [:]),
      homeDirectory: homeURL,
      transferQueue: .isolatedForTesting(),
      inheritedAccessLease: { url in
        inheritedPaths.append(url)
        guard url.standardizedFileURL.path == directoryURL.standardizedFileURL.path else {
          return nil
        }
        return try? WorkspaceBookmarkAccessLease(url: homeURL, manager: manager)
      })

    let browser = factory.makeBrowser(
      for: .local(bookmarkData: Data("broken".utf8), lastKnownPath: directoryURL.path))

    #expect(inheritedPaths.map(\.path) == [directoryURL.path])
    #expect(browser.currentLocation.localURL?.path == directoryURL.path)
  }

  @Test("旧コンテナのDataを保存したワークスペースは実ホームへ戻す")
  @MainActor
  func repairsSavedContainerHomeToUserHome() throws {
    let homeURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: homeURL) }
    let containerURL = homeURL.appending(
      path: "Library/Containers/\(Bundle.main.bundleIdentifier ?? "com.pky.PKPane")/Data",
      directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: containerURL, withIntermediateDirectories: true)
    let bookmark = Data("container".utf8)
    let factory = WorkspaceBrowserFactory(
      bookmarkCodec: WorkspaceTestBookmarkCodec(resolutions: [bookmark: containerURL]),
      homeDirectory: homeURL,
      transferQueue: .isolatedForTesting())

    let browser = factory.makeBrowser(
      for: .local(bookmarkData: bookmark, lastKnownPath: containerURL.path))

    #expect(browser.currentLocation.localURL == homeURL)
  }

  @Test(
    "一般Data・別アプリのコンテナ・コンテナ配下のフォルダはそのまま復元する",
    arguments: [
      "Data", "Library/Containers/test.other-app/Data",
      "Library/Containers/\(Bundle.main.bundleIdentifier ?? "com.pky.PKPane")/Data/Working",
    ])
  @MainActor
  func preservesOrdinaryDataDirectory(relativePath: String) throws {
    let homeURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: homeURL) }
    let directoryURL = homeURL.appending(path: relativePath, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    let bookmark = Data("data-directory".utf8)
    let factory = WorkspaceBrowserFactory(
      bookmarkCodec: WorkspaceTestBookmarkCodec(resolutions: [bookmark: directoryURL]),
      homeDirectory: homeURL,
      transferQueue: .isolatedForTesting())

    let browser = factory.makeBrowser(
      for: .local(bookmarkData: bookmark, lastKnownPath: directoryURL.path))

    #expect(browser.currentLocation.localURL == directoryURL)
  }

  @Test("Bookmarkを解決できても対象フォルダがなくなっていればホームへ戻る")
  @MainActor
  func fallsBackWhenResolvedDirectoryIsMissing() throws {
    let homeURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: homeURL) }
    let missingURL = homeURL.appending(path: "Missing", directoryHint: .isDirectory)
    let bookmark = Data("missing".utf8)
    let factory = WorkspaceBrowserFactory(
      bookmarkCodec: WorkspaceTestBookmarkCodec(resolutions: [bookmark: missingURL]),
      homeDirectory: homeURL,
      transferQueue: .isolatedForTesting())

    let browser = factory.makeBrowser(
      for: .local(bookmarkData: bookmark, lastKnownPath: missingURL.path))

    #expect(browser.currentLocation.localURL == homeURL)
  }

  @Test("リモート復元では接続せずアクティブ化時に一度だけ接続する")
  @MainActor
  func defersRemoteConnectionUntilActivation() throws {
    let localURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: localURL) }
    let localID = UUID()
    let remoteID = UUID()
    let bookmark = Data("local".utf8)
    let remoteLocation = WorkspaceLocationState.remote(
      providerKind: .sftp,
      connectionID: "sftp-example.test:22:test",
      path: "/srv/projects")
    let state = WorkspaceState(
      tabs: [
        WorkspaceTabState(
          id: localID,
          location: .local(bookmarkData: bookmark, lastKnownPath: localURL.path),
          viewMode: .list),
        WorkspaceTabState(id: remoteID, location: remoteLocation, viewMode: .column),
      ],
      activeTabID: localID,
      pane: WorkspacePaneState(
        showsSecondaryPane: true,
        activePane: .primary,
        primaryTabID: localID,
        secondaryTabID: remoteID))
    var connectionCount = 0
    let transferQueue = TransferQueue.isolatedForTesting()
    let workspace = FileWorkspaceModel(
      restoring: state,
      browserFactory: WorkspaceBrowserFactory(
        bookmarkCodec: WorkspaceTestBookmarkCodec(resolutions: [bookmark: localURL]),
        transferQueue: transferQueue),
      onActivateRemote: { location, completion in
        connectionCount += 1
        guard case .remote(_, _, let path) = location else {
          completion(nil)
          return
        }
        let provider = WorkspaceTestRemoteProvider()
        completion(
          FileBrowserSession(
            provider: provider,
            initialLocation: FileLocation(remotePath: path, providerID: provider.id),
            transferQueue: transferQueue))
      })

    #expect(connectionCount == 0)
    #expect(workspace.tab(for: .secondary)?.browser.isWorkspaceRemotePlaceholder == true)

    workspace.activatePane(.secondary)
    workspace.activateRestoredRemoteTabIfNeeded()

    #expect(connectionCount == 1)
    #expect(workspace.activeTabID == remoteID)
    #expect(workspace.activeTab.browser.isWorkspaceRemotePlaceholder == false)
    #expect(workspace.activeTab.browser.currentLocation.remotePath == "/srv/projects")
    #expect(workspace.activeTab.viewMode == .column)
  }

  @Test(
    "ホバーでは復元リモートへ接続せず、同じペインをクリックすると接続する",
    arguments: [WorkspaceRemoteProviderKind.smb, .sftp, .ftp])
  @MainActor
  func hoverKeepsRestoredRemoteDisconnectedUntilExplicitActivation(
    providerKind: WorkspaceRemoteProviderKind
  ) throws {
    let firstID = UUID()
    let secondID = UUID()
    let location = WorkspaceLocationState.remote(
      providerKind: providerKind, connectionID: "hover-fixture", path: "/projects")
    let state = WorkspaceState(
      tabs: [
        WorkspaceTabState(id: firstID, location: location, viewMode: .list),
        WorkspaceTabState(id: secondID, location: location, viewMode: .list),
      ],
      activeTabID: firstID,
      pane: WorkspacePaneState(
        showsSecondaryPane: true, activePane: .primary,
        primaryTabID: firstID, secondaryTabID: secondID))
    var connectionCount = 0
    let workspace = FileWorkspaceModel(
      restoring: state,
      browserFactory: WorkspaceBrowserFactory(transferQueue: .isolatedForTesting()),
      onActivateRemote: { _, completion in
        connectionCount += 1
        completion(nil)
      })
    let tab = try #require(workspace.tab(for: .secondary))
    let selection = tab.selectedItemURLs

    workspace.activatePane(.secondary, connectingRestoredRemote: false)

    #expect(workspace.activePane == .secondary)
    #expect(workspace.activeTabID == secondID)
    #expect(tab.selectedItemURLs == selection)
    #expect(tab.browser.isWorkspaceRemotePlaceholder)
    #expect(connectionCount == 0)

    workspace.activatePane(.secondary)

    #expect(connectionCount == 1)
  }

  @Test("表示準備ではアクティブなリモートを接続せず同じペインの明示操作で接続する")
  @MainActor
  func prepareForPresentationKeepsActiveRemoteDisconnectedUntilExplicitActivation() {
    let remoteID = UUID()
    let remoteLocation = WorkspaceLocationState.remote(
      providerKind: .sftp,
      connectionID: "sftp-example.test:22:test",
      path: "/srv/projects")
    let state = WorkspaceState(
      tabs: [
        WorkspaceTabState(id: remoteID, location: remoteLocation, viewMode: .column)
      ],
      activeTabID: remoteID,
      pane: WorkspacePaneState(
        showsSecondaryPane: false,
        activePane: .primary,
        primaryTabID: remoteID,
        secondaryTabID: nil))
    var connectionCount = 0
    let transferQueue = TransferQueue.isolatedForTesting()
    let workspace = FileWorkspaceModel(
      restoring: state,
      browserFactory: WorkspaceBrowserFactory(transferQueue: transferQueue),
      onActivateRemote: { location, completion in
        connectionCount += 1
        guard case .remote(_, _, let path) = location else {
          completion(nil)
          return
        }
        let provider = WorkspaceTestRemoteProvider()
        completion(
          FileBrowserSession(
            provider: provider,
            initialLocation: FileLocation(remotePath: path, providerID: provider.id),
            transferQueue: transferQueue))
      })
    let session = ProviderBrowserSession(title: "復元", workspace: workspace)

    session.prepareForPresentation()

    #expect(connectionCount == 0)
    #expect(workspace.activeTab.browser.isWorkspaceRemotePlaceholder)

    workspace.activatePane(.primary)

    #expect(connectionCount == 1)
    #expect(!workspace.activeTab.browser.isWorkspaceRemotePlaceholder)
    #expect(workspace.activeTab.browser.currentLocation.remotePath == "/srv/projects")
  }

  @Test("連続変更の保存をデバウンスして最後の一回へまとめる")
  @MainActor
  func debouncesWorkspacePersistence() async throws {
    let localURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: localURL) }
    let store = CountingWorkspaceStateStore()
    let controller = WorkspacePersistenceController(
      store: store,
      bookmarkCodec: WorkspaceTestBookmarkCodec(resolutions: [:]),
      debounceDuration: .milliseconds(20))
    let provider = LocalFileProvider()
    let workspace = FileWorkspaceModel(
      initialBrowser: FileBrowserSession(
        provider: provider,
        initialLocation: FileLocation(directoryURL: localURL, providerID: provider.id),
        transferQueue: .isolatedForTesting()))

    controller.scheduleSave(of: workspace)
    controller.scheduleSave(of: workspace)
    controller.scheduleSave(of: workspace)

    await waitUntil("保留中の保存が期限内に完了しなかった") {
      !controller.hasPendingSave
    }

    #expect(!controller.hasPendingSave)
    #expect(store.saveCount == 1)
    #expect(store.savedState?.tabs.count == 2)
  }

  @Test("保存データがなければ従来どおり既定の2ペインで初期化する")
  @MainActor
  func keepsExistingInitialStateWithoutSavedWorkspace() throws {
    let localURL = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: localURL) }
    let store = CountingWorkspaceStateStore()
    let controller = WorkspacePersistenceController(store: store)
    let provider = LocalFileProvider()

    #expect(controller.load() == nil)

    let workspace = FileWorkspaceModel(
      initialBrowser: FileBrowserSession(
        provider: provider,
        initialLocation: FileLocation(directoryURL: localURL, providerID: provider.id),
        transferQueue: .isolatedForTesting()))

    #expect(workspace.tabs.count == 2)
    #expect(workspace.showsSecondaryPane)
    #expect(workspace.activePane == .primary)
  }

  private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}

/// アクセス開始前は対象が見えないSandboxの存在照会を再現する。
private final class WorkspaceAccessVisibilityFileManager: FileManager, @unchecked Sendable {
  let accessStarted = Mutex(false)

  override func fileExists(
    atPath path: String,
    isDirectory: UnsafeMutablePointer<ObjCBool>?
  ) -> Bool {
    let visible = accessStarted.withLock { $0 }
    isDirectory?.pointee = ObjCBool(visible)
    return visible
  }
}

private struct WorkspaceTestBookmarkCodec: FolderBookmarkCoding {
  let resolutions: [Data: URL]

  func createBookmark(for url: URL) throws -> Data {
    Data(url.path.utf8)
  }

  func resolveBookmark(_ data: Data) throws -> ResolvedFolderBookmark {
    guard let url = resolutions[data] else {
      throw CocoaError(.fileReadCorruptFile)
    }
    return ResolvedFolderBookmark(url: url, isStale: false)
  }
}

private struct WorkspaceTestRemoteProvider: FileBrowserProvider {
  let id = FileProviderID(rawValue: "workspace-test-remote")
  let connectionID: FileProviderConnectionID? = FileProviderConnectionID(
    rawValue: "workspace-test-remote")
  let capabilities: FileProviderCapabilities = [.read]

  func contents(of _: FileLocation) async throws -> [FileItem] { [] }

  func parent(of location: FileLocation) -> FileLocation? {
    location.deletingLastPathComponent()
  }

  func breadcrumbs(
    for location: FileLocation,
    constrainedTo _: FileLocation?
  ) -> [FileBrowserBreadcrumb] {
    [FileBrowserBreadcrumb(location: location, name: location.remotePath ?? "")]
  }
}

private final class CountingWorkspaceStateStore: WorkspaceStateStoring, @unchecked Sendable {
  private(set) var saveCount = 0
  private(set) var savedState: WorkspaceState?

  func load() throws -> WorkspaceState? { savedState }

  func save(_ state: WorkspaceState) throws {
    saveCount += 1
    savedState = state
  }
}
