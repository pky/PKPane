import Foundation
import Synchronization
import Testing

@testable import PKPane

@MainActor
struct SyncBrowsingWorkspaceTests {
  @Test("フォルダ移動と履歴を相手ペインへ一度だけ連動する")
  func followsFolderAndHistoryNavigationWithoutLoop() async throws {
    let source = SyncBrowsingTestProvider(
      id: "sync-source-history",
      directories: ["/source", "/source/X"])
    let target = SyncBrowsingTestProvider(
      id: "sync-target-history",
      directories: ["/backup", "/backup/X"])
    let workspace = makeWorkspace(
      source: source,
      sourcePath: "/source",
      target: target,
      targetPath: "/backup")

    workspace.open(source.item(at: "/source/X"), in: .primary)
    await waitForSync(workspace)
    #expect(workspace.tab(for: .secondary)?.browser.currentLocation == target.location("/backup/X"))
    #expect(target.contentsCallCount(at: "/backup/X") == 1)
    #expect(workspace.syncNavigationRequestCount == 1)

    workspace.goBack(in: .primary)
    await waitForSync(workspace)
    #expect(workspace.tab(for: .secondary)?.browser.currentLocation == target.location("/backup"))

    workspace.goForward(in: .primary)
    await waitForSync(workspace)
    #expect(workspace.tab(for: .secondary)?.browser.currentLocation == target.location("/backup/X"))
    #expect(workspace.syncNavigationRequestCount == 3)
  }

  @Test("親移動とパンくず移動を相手ペインへ連動する")
  func followsParentAndBreadcrumbNavigation() async throws {
    let source = SyncBrowsingTestProvider(
      id: "sync-source-breadcrumb",
      directories: ["/source", "/source/A", "/source/A/B"])
    let target = SyncBrowsingTestProvider(
      id: "sync-target-breadcrumb",
      directories: ["/backup", "/backup/A", "/backup/A/B"])
    let workspace = makeWorkspace(
      source: source,
      sourcePath: "/source/A/B",
      target: target,
      targetPath: "/backup/A/B")

    workspace.openParent(in: .primary)
    await waitForSync(workspace)
    #expect(workspace.tab(for: .secondary)?.browser.currentLocation == target.location("/backup/A"))

    let sourceBrowser = try #require(workspace.tab(for: .primary)?.browser)
    let breadcrumb = try #require(
      sourceBrowser.breadcrumbs.first { $0.location == source.location("/source") })
    workspace.openBreadcrumb(breadcrumb, in: .primary)
    await waitForSync(workspace)

    #expect(workspace.tab(for: .secondary)?.browser.currentLocation == target.location("/backup"))
  }

  @Test("同名フォルダがなくても留まり次の移動で現在地から再連動する")
  func staysOnFailureThenFollowsFromCurrentLocations() async {
    let source = SyncBrowsingTestProvider(
      id: "sync-source-recovery",
      directories: ["/source", "/source/missing", "/source/missing/found"])
    let target = SyncBrowsingTestProvider(
      id: "sync-target-recovery",
      directories: ["/backup", "/backup/found"])
    let workspace = makeWorkspace(
      source: source,
      sourcePath: "/source",
      target: target,
      targetPath: "/backup")

    workspace.open(source.item(at: "/source/missing"), in: .primary)
    await waitForSync(workspace)
    let targetBrowser = workspace.tab(for: .secondary)?.browser
    #expect(targetBrowser?.currentLocation == target.location("/backup"))
    #expect(targetBrowser?.errorMessage == nil)

    workspace.open(source.item(at: "/source/missing/found"), in: .primary)
    await waitForSync(workspace)
    #expect(targetBrowser?.currentLocation == target.location("/backup/found"))
    #expect(workspace.syncNavigationRequestCount == 2)
  }

  @Test("1ペイン化すると同期ブラウズを自動で解除する")
  func disablesWhenSecondaryPaneCloses() {
    let provider = SyncBrowsingTestProvider(
      id: "sync-single-pane",
      directories: ["/source"])
    let workspace = FileWorkspaceModel(
      initialBrowser: FileBrowserSession(
        provider: provider,
        initialLocation: provider.location("/source"),
        transferQueue: .isolatedForTesting()))
    workspace.setSyncBrowsingEnabled(true)

    workspace.setShowsSecondaryPane(false)

    #expect(!workspace.showsSecondaryPane)
    #expect(!workspace.isSyncBrowsingEnabled)
    workspace.setShowsSecondaryPane(true)
    #expect(!workspace.isSyncBrowsingEnabled)
  }

  @Test("タブ終了で1ペインになっても同期ブラウズを自動で解除する")
  func disablesWhenClosingSecondaryTab() throws {
    let provider = SyncBrowsingTestProvider(
      id: "sync-close-tab",
      directories: ["/source"])
    let workspace = FileWorkspaceModel(
      initialBrowser: FileBrowserSession(
        provider: provider,
        initialLocation: provider.location("/source"),
        transferQueue: .isolatedForTesting()))
    let secondaryTab = try #require(workspace.tab(for: .secondary))
    workspace.setSyncBrowsingEnabled(true)

    workspace.closeTab(id: secondaryTab.id)

    #expect(!workspace.showsSecondaryPane)
    #expect(!workspace.isSyncBrowsingEnabled)
  }

  @Test("ブラウザの場所差し替えは同期対象にしない")
  func doesNotFollowWholeBrowserReplacement() {
    let source = SyncBrowsingTestProvider(
      id: "sync-source-replacement",
      directories: ["/source", "/favorite"])
    let target = SyncBrowsingTestProvider(
      id: "sync-target-replacement",
      directories: ["/backup", "/favorite"])
    let workspace = makeWorkspace(
      source: source,
      sourcePath: "/source",
      target: target,
      targetPath: "/backup")
    let replacement = FileBrowserSession(
      provider: source,
      initialLocation: source.location("/favorite"),
      transferQueue: .isolatedForTesting())

    workspace.replaceActiveBrowser(with: replacement)

    #expect(workspace.tab(for: .primary)?.browser === replacement)
    #expect(workspace.tab(for: .secondary)?.browser.currentLocation == target.location("/backup"))
    #expect(workspace.syncNavigationRequestCount == 0)
  }

  @Test("カラムクリックの移動も相手ペインへ連動する")
  func followsColumnSelection() async throws {
    let source = SyncBrowsingTestProvider(
      id: "sync-source-column",
      directories: ["/source", "/source/X"])
    let target = SyncBrowsingTestProvider(
      id: "sync-target-column",
      directories: ["/backup", "/backup/X"])
    let workspace = makeWorkspace(
      source: source,
      sourcePath: "/source",
      target: target,
      targetPath: "/backup")
    let sourceBrowser = try #require(workspace.tab(for: .primary)?.browser)
    workspace.setViewMode(.column)
    sourceBrowser.load()
    await waitForLoading(sourceBrowser)
    sourceBrowser.beginColumnBrowsing()
    let folder = try #require(sourceBrowser.items.first { $0.name == "X" })

    workspace.selectColumnItems(
      [folder.url], inColumnAt: source.location("/source"), pane: .primary)
    await waitForSync(workspace)

    #expect(sourceBrowser.currentLocation == source.location("/source/X"))
    #expect(workspace.tab(for: .secondary)?.browser.currentLocation == target.location("/backup/X"))
  }

  private func makeWorkspace(
    source: SyncBrowsingTestProvider,
    sourcePath: String,
    target: SyncBrowsingTestProvider,
    targetPath: String
  ) -> FileWorkspaceModel {
    let transferQueue = TransferQueue.isolatedForTesting()
    let workspace = FileWorkspaceModel(
      initialBrowser: FileBrowserSession(
        provider: source,
        initialLocation: source.location(sourcePath),
        transferQueue: transferQueue))
    workspace.activatePane(.secondary)
    workspace.replaceActiveBrowser(
      with: FileBrowserSession(
        provider: target,
        initialLocation: target.location(targetPath),
        transferQueue: transferQueue))
    workspace.activatePane(.primary)
    workspace.setSyncBrowsingEnabled(true)
    return workspace
  }

  private func waitForSync(_ workspace: FileWorkspaceModel) async {
    await waitUntil("同期ナビゲーションの保留が期限内に解消しなかった") {
      !workspace.hasPendingSyncNavigation
    }
  }

  private func waitForLoading(_ browser: FileBrowserSession) async {
    await waitUntil("セッションの読み込みが期限内に完了しなかった") {
      !(browser.isLoading || browser.isRefreshing)
    }
  }
}

private final class SyncBrowsingTestProvider: FileBrowserProvider, @unchecked Sendable {
  let id: FileProviderID
  let connectionID: FileProviderConnectionID? = nil
  let capabilities: FileProviderCapabilities = [.read]
  private let directories: Set<String>
  private let callCounts = Mutex<[String: Int]>([:])

  init(id: String, directories: Set<String>) {
    self.id = FileProviderID(rawValue: id)
    self.directories = directories
  }

  func contents(of location: FileLocation) async throws -> [FileItem] {
    let path = try remotePath(of: location)
    callCounts.withLock { $0[path, default: 0] += 1 }
    guard directories.contains(path) else {
      throw CocoaError(.fileNoSuchFile)
    }
    return
      directories
      .filter { parentPath(of: $0) == path }
      .sorted()
      .map(item(at:))
  }

  func parent(of location: FileLocation) -> FileLocation? {
    location.deletingLastPathComponent()
  }

  func breadcrumbs(
    for location: FileLocation,
    constrainedTo _: FileLocation?
  ) -> [FileBrowserBreadcrumb] {
    guard let path = location.remotePath else { return [] }
    var current = ""
    return path.split(separator: "/").map { component in
      current += "/\(component)"
      return FileBrowserBreadcrumb(
        location: self.location(current),
        name: String(component))
    }
  }

  func location(_ path: String) -> FileLocation {
    FileLocation(remotePath: path, providerID: id)
  }

  func item(at path: String) -> FileItem {
    FileItem(
      remotePath: path,
      url: URL(fileURLWithPath: "/\(id.rawValue)\(path)"),
      providerID: id,
      isDirectory: true,
      name: path.split(separator: "/").last.map(String.init) ?? "/")
  }

  func contentsCallCount(at path: String) -> Int {
    callCounts.withLock { $0[path, default: 0] }
  }

  private func remotePath(of location: FileLocation) throws -> String {
    guard location.providerID == id, let path = location.remotePath else {
      throw CocoaError(.fileReadUnsupportedScheme)
    }
    return path
  }

  private func parentPath(of path: String) -> String? {
    location(path).deletingLastPathComponent()?.remotePath
  }
}
