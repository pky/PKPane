import Foundation
import SwiftUI
import Testing
import ZIPFoundation

@testable import PKPane

@MainActor
struct ArchiveBrowsingRouteTests {
  @Test("コンテキストメニューからZIPへ入り親移動で元フォルダへ戻る")
  func browsesArchiveThroughContextMenuAndReturnsToSource() async throws {
    let fixture = try ArchiveBrowsingFixture()
    defer { fixture.remove() }
    try fixture.addFile(path: "inside.txt", contents: "inside")
    try fixture.addFile(path: "nested/needle.txt", contents: "needle")
    try fixture.addFile(path: "../unsafe.txt", contents: "unsafe")
    let provider = LocalFileProvider()
    let sourceLocation = FileLocation(directoryURL: fixture.rootURL, providerID: provider.id)
    let sourceBrowser = FileBrowserSession(
      provider: provider, initialLocation: sourceLocation, transferQueue: .isolatedForTesting())
    sourceBrowser.load()
    await waitForLoading(sourceBrowser)
    let archiveItem = try #require(sourceBrowser.items.first { $0.url == fixture.archiveURL })
    let workspace = FileWorkspaceModel(initialBrowser: sourceBrowser)
    let view = makeView(workspace: workspace, mode: .list)
    let menuItem = try #require(
      view.contextMenuItems(
        for: archiveItem,
        selectedItems: [archiveItem],
        browser: sourceBrowser,
        pane: .primary
      ).first { $0.title == "アーカイブの内容を表示" })

    #expect(menuItem.isEnabled)
    menuItem.action()
    await waitUntil { workspace.tab(for: .primary)?.browser !== sourceBrowser }
    let archiveBrowser = try #require(workspace.tab(for: .primary)?.browser)
    await waitForLoading(archiveBrowser)

    #expect(
      workspace.displayedBreadcrumbs(in: .primary).map(\.name)
        == sourceBrowser.breadcrumbs.map(\.name) + ["fixture.zip"])

    #expect(archiveBrowser.currentLocation.remotePath == "/")
    #expect(Set(archiveBrowser.items.map(\.name)) == Set(["inside.txt", "nested"]))
    #expect(archiveBrowser.archiveInvalidEntryCount == 1)
    #expect(archiveBrowser.canGoToParent)
    #expect(!archiveBrowser.supportsThisMacSearch)

    archiveBrowser.setSearchText("needle")
    await waitForSearch(archiveBrowser)
    #expect(archiveBrowser.searchResults.map(\.item.name) == ["needle.txt"])
    archiveBrowser.endSearch()
    archiveBrowser.setSearchText("tag:red")
    #expect(archiveBrowser.searchResults.isEmpty)
    #expect(archiveBrowser.searchScopeNotice == "この接続ではタグ検索を利用できません")
    archiveBrowser.endSearch()

    let insideItem = try #require(archiveBrowser.items.first { $0.name == "inside.txt" })
    workspace.selectItems([insideItem.url], in: .primary)
    #expect(workspace.canCopySelectedItemsToOppositePane)
    #expect(!workspace.canMoveSelectedItemsToOppositePane)
    let archiveView = makeView(workspace: workspace, mode: .list)
    let archiveMenu = archiveView.contextMenuItems(
      for: insideItem,
      selectedItems: [insideItem],
      browser: archiveBrowser,
      pane: .primary)
    #expect(archiveMenu.first { $0.title == "削除" }?.isEnabled == false)
    #expect(archiveMenu.first { $0.title == "名前を変更" }?.isEnabled == false)
    #expect(archiveMenu.first { $0.title == "カット" }?.isEnabled == false)
    #expect(archiveMenu.first { $0.title == "移動先を選択…" }?.isEnabled == false)
    #expect(
      archiveView.backgroundContextMenuItems(browser: archiveBrowser, pane: .primary)
        .first { $0.title == "新規フォルダ" }?.isEnabled == false)

    let copyItem = try #require(archiveMenu.first { $0.title.hasPrefix("コピー ") })
    copyItem.action()
    let destinationBrowser = try #require(workspace.tab(for: .secondary)?.browser)
    destinationBrowser.loadIfNeeded()
    await waitForLoading(destinationBrowser)
    let pasteItem = try #require(
      archiveView.backgroundContextMenuItems(browser: destinationBrowser, pane: .secondary)
        .first { $0.title == "ペースト" })
    #expect(pasteItem.isEnabled)
    pasteItem.action()
    let copiedURL = fixture.rootURL.appending(path: "inside.txt")
    await waitUntil {
      FileManager.default.fileExists(atPath: copiedURL.path) && !archiveBrowser.isTransferring
    }
    #expect(try Data(contentsOf: copiedURL) == Data("inside".utf8))

    workspace.openParent(in: .primary)
    #expect(workspace.tab(for: .primary)?.browser === sourceBrowser)
    await waitForLoading(sourceBrowser)
    #expect(sourceBrowser.currentLocation.representsSameDirectory(as: sourceLocation))
    #expect(workspace.displayedBreadcrumbs(in: .primary) == sourceBrowser.breadcrumbs)
  }

  @Test("アーカイブ内パンくずはZIP内移動とホスト側への退場を振り分ける")
  func routesCombinedArchiveBreadcrumbs() async throws {
    let fixture = try ArchiveBrowsingFixture()
    defer { fixture.remove() }
    try fixture.addFile(path: "nested/deeper/inside.txt", contents: "inside")
    let provider = LocalFileProvider()
    let sourceLocation = FileLocation(directoryURL: fixture.rootURL, providerID: provider.id)
    let sourceBrowser = FileBrowserSession(
      provider: provider, initialLocation: sourceLocation, transferQueue: .isolatedForTesting())
    sourceBrowser.load()
    await waitForLoading(sourceBrowser)
    let archiveItem = try #require(sourceBrowser.items.first { $0.url == fixture.archiveURL })
    let workspace = FileWorkspaceModel(initialBrowser: sourceBrowser, initialViewMode: .column)

    workspace.showArchiveContents(archiveItem, in: .primary)
    await waitUntil { workspace.tab(for: .primary)?.browser !== sourceBrowser }
    let archiveBrowser = try #require(workspace.tab(for: .primary)?.browser)
    await waitForLoading(archiveBrowser)

    let nestedItem = try #require(archiveBrowser.items.first { $0.name == "nested" })
    workspace.open(nestedItem, in: .primary)
    await waitForLoading(archiveBrowser)
    let deeperItem = try #require(archiveBrowser.items.first { $0.name == "deeper" })
    workspace.open(deeperItem, in: .primary)
    await waitForLoading(archiveBrowser)
    let combinedBreadcrumbs = workspace.displayedBreadcrumbs(in: .primary)
    #expect(
      combinedBreadcrumbs.map(\.name)
        == sourceBrowser.breadcrumbs.map(\.name) + ["fixture.zip", "nested", "deeper"])

    let archiveNestedBreadcrumb = try #require(
      combinedBreadcrumbs.first {
        $0.name == "nested" && $0.location.providerID == archiveBrowser.providerID
      })
    workspace.openBreadcrumb(archiveNestedBreadcrumb, in: .primary)
    await waitForLoading(archiveBrowser)
    #expect(workspace.tab(for: .primary)?.browser === archiveBrowser)
    #expect(archiveBrowser.currentLocation.remotePath == "/nested")

    let hostParentBreadcrumb = try #require(sourceBrowser.breadcrumbs.dropLast().last)
    let secondaryBrowser = try #require(workspace.tab(for: .secondary)?.browser)
    let secondaryLocation = secondaryBrowser.currentLocation
    workspace.openBreadcrumb(hostParentBreadcrumb, in: .primary)
    #expect(workspace.tab(for: .primary)?.browser === sourceBrowser)
    await waitForLoading(sourceBrowser)
    #expect(sourceBrowser.currentLocation == hostParentBreadcrumb.location)
    #expect(workspace.tab(for: .secondary)?.browser === secondaryBrowser)
    #expect(secondaryBrowser.currentLocation == secondaryLocation)
    #expect(workspace.displayedBreadcrumbs(in: .primary) == sourceBrowser.breadcrumbs)
  }

  @Test("ZIP直上フォルダのパンくずは移動せずアーカイブを退場する")
  func exitsArchiveAtSourceBreadcrumb() async throws {
    let fixture = try ArchiveBrowsingFixture()
    defer { fixture.remove() }
    try fixture.addFile(path: "inside.txt", contents: "inside")
    let provider = LocalFileProvider()
    let sourceLocation = FileLocation(directoryURL: fixture.rootURL, providerID: provider.id)
    let sourceBrowser = FileBrowserSession(
      provider: provider, initialLocation: sourceLocation, transferQueue: .isolatedForTesting())
    sourceBrowser.load()
    await waitForLoading(sourceBrowser)
    let archiveItem = try #require(sourceBrowser.items.first { $0.url == fixture.archiveURL })
    let workspace = FileWorkspaceModel(initialBrowser: sourceBrowser)

    workspace.showArchiveContents(archiveItem, in: .primary)
    await waitUntil { workspace.tab(for: .primary)?.browser !== sourceBrowser }
    let archiveBrowser = try #require(workspace.tab(for: .primary)?.browser)
    await waitForLoading(archiveBrowser)
    let sourceBreadcrumb = try #require(
      workspace.displayedBreadcrumbs(in: .primary).first {
        $0.location == sourceLocation
      })

    workspace.openBreadcrumb(sourceBreadcrumb, in: .primary)
    #expect(workspace.tab(for: .primary)?.browser === sourceBrowser)
    await waitForLoading(sourceBrowser)
    #expect(sourceBrowser.currentLocation == sourceLocation)
  }

  @Test("ZIP内の書き込み操作は3表示モード共通で無効になる")
  func disablesWritingForEveryViewMode() async throws {
    let fixture = try ArchiveBrowsingFixture()
    defer { fixture.remove() }
    try fixture.addFile(path: "inside.txt", contents: "inside")
    let provider = try ArchiveFileProvider(archiveURL: fixture.archiveURL)
    let item = try #require(try await provider.contents(of: provider.rootLocation).first)

    #expect(provider.capabilities == [.read, .readSymbolicLink])
    for mode in FileBrowserViewMode.allCases {
      let browser = FileBrowserSession(
        provider: provider,
        initialLocation: provider.rootLocation,
        hasExternalParent: true,
        transferQueue: .isolatedForTesting())
      let workspace = FileWorkspaceModel(initialBrowser: browser, initialViewMode: mode)
      let view = makeView(workspace: workspace, mode: mode)
      workspace.selectItems([item.url], in: .primary)
      workspace.copySelectedItems()
      let menu = view.contextMenuItems(
        for: item,
        selectedItems: [item],
        browser: browser,
        pane: .primary)
      let backgroundMenu = view.backgroundContextMenuItems(browser: browser, pane: .primary)

      #expect(FileBrowserCapability.supports(.itemOperations, for: mode))
      #expect(menu.first { $0.title == "削除" }?.isEnabled == false)
      #expect(menu.first { $0.title == "名前を変更" }?.isEnabled == false)
      #expect(menu.first { $0.title == "カット" }?.isEnabled == false)
      #expect(menu.first { $0.title == "移動先を選択…" }?.isEnabled == false)
      #expect(backgroundMenu.first { $0.title == "新規フォルダ" }?.isEnabled == false)
      #expect(backgroundMenu.first { $0.title == "ペースト" }?.isEnabled == false)
    }
  }

  @Test("アーカイブ内の場所はお気に入りへ登録できない")
  func disablesFavoriteRegistrationForArchiveLocation() async throws {
    let fixture = try ArchiveBrowsingFixture()
    defer { fixture.remove() }
    try fixture.addFile(path: "nested/inside.txt", contents: "inside")
    let provider = try ArchiveFileProvider(archiveURL: fixture.archiveURL)
    let directory = try #require(
      try await provider.contents(of: provider.rootLocation).first { $0.isDirectory })
    let browser = FileBrowserSession(
      provider: provider, initialLocation: provider.rootLocation,
      transferQueue: .isolatedForTesting())
    let workspace = FileWorkspaceModel(initialBrowser: browser)
    var resolverCallCount = 0
    let view = makeView(
      workspace: workspace,
      mode: .list,
      favoriteContextMenuItem: { items, _ in
        resolverCallCount += 1
        guard LaunchView.FavoriteContextMenuTargetResolver.localDirectoryURLs(for: items) != nil
        else {
          return nil
        }
        return FileContextMenuItem(title: "お気に入りに追加") {}
      })

    let menu = view.contextMenuItems(
      for: directory,
      selectedItems: [directory],
      browser: browser,
      pane: .primary)

    #expect(resolverCallCount == 1)
    #expect(menu.allSatisfy { !$0.title.contains("お気に入り") })
  }

  @Test("アーカイブ閲覧項目は3表示モード共通で到達できる")
  func exposesArchiveBrowsingForEveryViewMode() throws {
    let rootURL = FileManager.default.temporaryDirectory.appending(
      path: "pkpane-archive-mode-\(UUID().uuidString)",
      directoryHint: .isDirectory)
    let archiveURL = rootURL.appending(path: "fixture.zip")
    let item = FileItem(url: archiveURL, isDirectory: false)

    for mode in FileBrowserViewMode.allCases {
      let browser = FileBrowserSession(
        provider: LocalFileProvider(),
        initialLocation: FileLocation(directoryURL: rootURL),
        transferQueue: .isolatedForTesting())
      let workspace = FileWorkspaceModel(initialBrowser: browser, initialViewMode: mode)
      let menuItem = makeView(workspace: workspace, mode: mode).contextMenuItems(
        for: item,
        selectedItems: [item],
        browser: browser,
        pane: .primary
      ).first { $0.title == "アーカイブの内容を表示" }

      #expect(FileBrowserCapability.supports(.contextMenu, for: mode))
      #expect(menuItem?.isEnabled == true)
    }
  }

  @Test("7z・tar.gz・rarの閲覧項目は3表示モード共通で有効になる")
  func exposesAdditionalArchiveFormatsForEveryViewMode() throws {
    let fixture = try AdditionalArchiveBrowsingFixture()
    defer { fixture.remove() }

    for archiveURL in fixture.archiveURLs {
      let item = FileItem(url: archiveURL, isDirectory: false)
      for mode in FileBrowserViewMode.allCases {
        let browser = FileBrowserSession(
          provider: LocalFileProvider(),
          initialLocation: FileLocation(directoryURL: fixture.rootURL),
          transferQueue: .isolatedForTesting())
        let workspace = FileWorkspaceModel(initialBrowser: browser, initialViewMode: mode)
        let menuItem = makeView(workspace: workspace, mode: mode).contextMenuItems(
          for: item,
          selectedItems: [item],
          browser: browser,
          pane: .primary
        ).first { $0.title == "アーカイブの内容を表示" }

        #expect(FileBrowserCapability.supports(.contextMenu, for: mode))
        #expect(menuItem?.isEnabled == true)
      }
    }
  }

  @Test("SFTP上のZIPではアーカイブ閲覧項目を無効にする")
  func disablesArchiveBrowsingForSFTPItem() async throws {
    let target = try SFTPConnectionTarget(
      host: "example.invalid",
      port: 22,
      username: "tester")
    let provider = SFTPFileProvider(
      target: target,
      directoryListing: ArchiveRouteSFTPClientSession())
    let rootLocation = FileLocation(remotePath: "/", providerID: provider.id)
    let browser = FileBrowserSession(
      provider: provider, initialLocation: rootLocation, transferQueue: .isolatedForTesting())
    let workspace = FileWorkspaceModel(initialBrowser: browser)
    let item = try #require(try await provider.contents(of: rootLocation).first)
    let menuItem = try #require(
      makeView(workspace: workspace, mode: .list).contextMenuItems(
        for: item,
        selectedItems: [item],
        browser: browser,
        pane: .primary
      ).first { $0.title == "アーカイブの内容を表示" })

    #expect(!menuItem.isEnabled)
    menuItem.action()
    #expect(workspace.tab(for: .primary)?.browser === browser)
  }

  @Test("明示したアーカイブ内容表示は全形式で内部ブラウズへ入る")
  func showsLocalArchivesInInternalBrowser() async throws {
    let fixture = try ArchiveOpenRoutingFixture()
    defer { fixture.remove() }

    for archiveURL in fixture.archiveURLs {
      let provider = LocalFileProvider()
      let sourceLocation = FileLocation(directoryURL: fixture.rootURL, providerID: provider.id)
      let sourceBrowser = FileBrowserSession(
        provider: provider, initialLocation: sourceLocation, transferQueue: .isolatedForTesting())
      sourceBrowser.load()
      await waitForLoading(sourceBrowser)
      let archiveItem = try #require(sourceBrowser.items.first { $0.url == archiveURL })
      let workspace = FileWorkspaceModel(initialBrowser: sourceBrowser)

      workspace.showArchiveContents(archiveItem, in: .primary)
      await waitUntil { workspace.tab(for: .primary)?.browser !== sourceBrowser }
      let archiveBrowser = try #require(workspace.tab(for: .primary)?.browser)
      await waitForLoading(archiveBrowser)

      #expect(archiveBrowser.providerID != sourceBrowser.providerID)
      #expect(archiveBrowser.currentLocation.remotePath == "/")
      #expect(
        workspace.displayedBreadcrumbs(in: .primary).last?.name
          == archiveURL.lastPathComponent)
    }
  }

  @Test("アーカイブ内フォルダを開くと同じブラウザ内で移動する")
  func opensArchiveDirectoryInCurrentBrowser() async throws {
    let fixture = try ArchiveBrowsingFixture()
    defer { fixture.remove() }
    try fixture.addFile(path: "nested/inside.txt", contents: "inside")
    let provider = try ArchiveFileProvider(archiveURL: fixture.archiveURL)
    let browser = FileBrowserSession(
      provider: provider, initialLocation: provider.rootLocation,
      transferQueue: .isolatedForTesting())
    let workspace = FileWorkspaceModel(initialBrowser: browser)
    browser.load()
    await waitForLoading(browser)
    let nestedItem = try #require(browser.items.first { $0.name == "nested" })

    #expect(nestedItem.location.localURL == nil)
    workspace.open(nestedItem, in: .primary)
    await waitForLoading(browser)

    #expect(workspace.tab(for: .primary)?.browser === browser)
    #expect(browser.currentLocation.remotePath == "/nested")
  }

  @Test("通常ファイルを開いても内部ブラウズへ入らない")
  func doesNotBrowsePlainFileAsArchive() async throws {
    let fixture = try ArchiveOpenRoutingFixture()
    defer { fixture.remove() }
    let provider = LocalFileProvider()
    let sourceLocation = FileLocation(directoryURL: fixture.rootURL, providerID: provider.id)
    let sourceBrowser = FileBrowserSession(
      provider: provider, initialLocation: sourceLocation, transferQueue: .isolatedForTesting())
    sourceBrowser.load()
    await waitForLoading(sourceBrowser)
    let plainItem = try #require(sourceBrowser.items.first { $0.url == fixture.plainTextURL })
    let workspace = FileWorkspaceModel(initialBrowser: sourceBrowser)

    workspace.open(plainItem, in: .primary)

    #expect(workspace.tab(for: .primary)?.browser === sourceBrowser)
    #expect(sourceBrowser.currentLocation == sourceLocation)
  }

  @Test("圧縮率上限を超えるアーカイブは元フォルダに留まり理由を表示する")
  func keepsSourceBrowserWhenArchiveCompressionRatioIsUnsafe() async throws {
    let fixture = try ArchiveBrowsingFixture()
    defer { fixture.remove() }
    try fixture.addFile(path: "bomb.txt", contents: String(repeating: "A", count: 128 * 1_024))
    let provider = LocalFileProvider()
    let sourceLocation = FileLocation(directoryURL: fixture.rootURL, providerID: provider.id)
    let sourceBrowser = FileBrowserSession(
      provider: provider, initialLocation: sourceLocation, transferQueue: .isolatedForTesting())
    sourceBrowser.load()
    await waitForLoading(sourceBrowser)
    let archiveItem = try #require(sourceBrowser.items.first { $0.url == fixture.archiveURL })
    let workspace = FileWorkspaceModel(initialBrowser: sourceBrowser)

    workspace.open(archiveItem, in: .primary)
    await waitUntil { sourceBrowser.errorMessage != nil }

    #expect(workspace.tab(for: .primary)?.browser === sourceBrowser)
    #expect(sourceBrowser.errorMessage?.contains("圧縮率が安全上限を超えています") == true)
  }

  @Test("選択したアーカイブも明示した内容表示で内部ブラウズする")
  func showsSelectedLocalArchiveInInternalBrowser() async throws {
    let fixture = try ArchiveOpenRoutingFixture()
    defer { fixture.remove() }
    let provider = LocalFileProvider()
    let sourceLocation = FileLocation(directoryURL: fixture.rootURL, providerID: provider.id)
    let sourceBrowser = FileBrowserSession(
      provider: provider, initialLocation: sourceLocation, transferQueue: .isolatedForTesting())
    sourceBrowser.load()
    await waitForLoading(sourceBrowser)
    let archiveURL = try #require(fixture.archiveURLs.first)
    let archiveItem = try #require(sourceBrowser.items.first { $0.url == archiveURL })
    let workspace = FileWorkspaceModel(initialBrowser: sourceBrowser)
    workspace.selectItems([archiveItem.url], in: .primary)

    workspace.showArchiveContents(archiveItem, in: .primary)
    await waitUntil { workspace.tab(for: .primary)?.browser !== sourceBrowser }
    let archiveBrowser = try #require(workspace.tab(for: .primary)?.browser)
    await waitForLoading(archiveBrowser)

    #expect(archiveBrowser.providerID != sourceBrowser.providerID)
    #expect(
      workspace.displayedBreadcrumbs(in: .primary).last?.name
        == archiveURL.lastPathComponent)
  }

  @Test("ZIPの通常オープンは元フォルダで展開する", arguments: ["workspace", "selected", "session"])
  func extractsZIPBesideSourceWhenOpened(route: String) async throws {
    let fixture = try ArchiveBrowsingFixture()
    defer { fixture.remove() }
    try fixture.addFile(path: "inside.txt", contents: "inside")
    let originalArchive = try Data(contentsOf: fixture.archiveURL)
    let provider = LocalFileProvider()
    let location = FileLocation(directoryURL: fixture.rootURL, providerID: provider.id)
    let browser = FileBrowserSession(
      provider: provider, initialLocation: location, transferQueue: .isolatedForTesting())
    browser.load()
    await waitForLoading(browser)
    let item = try #require(browser.items.first { $0.url == fixture.archiveURL })
    let workspace = FileWorkspaceModel(initialBrowser: browser)

    switch route {
    case "selected":
      workspace.selectItems([item.url], in: .primary)
      workspace.openSelectedItem(in: .primary)
    case "session":
      browser.open(item)
    default:
      workspace.open(item, in: .primary)
    }
    let outputURL = fixture.rootURL.appending(path: "inside.txt")
    await waitUntil {
      FileManager.default.fileExists(atPath: outputURL.path) && !browser.isArchiving
    }

    #expect(workspace.tab(for: .primary)?.browser === browser)
    #expect(browser.currentLocation == location)
    #expect(try Data(contentsOf: outputURL) == Data("inside".utf8))
    #expect(try Data(contentsOf: fixture.archiveURL) == originalArchive)
  }

  @Test("ZIPの通常オープンは同名ファイルを避けて展開し元ZIPも保つ")
  func openingZIPPreservesExistingDestination() async throws {
    let fixture = try ArchiveBrowsingFixture()
    defer { fixture.remove() }
    try fixture.addFile(path: "inside.txt", contents: "new")
    let existingURL = fixture.rootURL.appending(path: "inside.txt")
    try Data("existing".utf8).write(to: existingURL)
    let originalArchive = try Data(contentsOf: fixture.archiveURL)
    let provider = LocalFileProvider()
    let location = FileLocation(directoryURL: fixture.rootURL, providerID: provider.id)
    let browser = FileBrowserSession(
      provider: provider, initialLocation: location, transferQueue: .isolatedForTesting())
    browser.load()
    await waitForLoading(browser)
    let item = try #require(browser.items.first { $0.url == fixture.archiveURL })
    let workspace = FileWorkspaceModel(initialBrowser: browser)

    workspace.open(item, in: .primary)
    let outputURL = fixture.rootURL.appending(path: "inside 2.txt")
    await waitUntil {
      FileManager.default.fileExists(atPath: outputURL.path) && !browser.isArchiving
    }

    #expect(workspace.tab(for: .primary)?.browser === browser)
    #expect(try Data(contentsOf: existingURL) == Data("existing".utf8))
    #expect(try Data(contentsOf: fixture.archiveURL) == originalArchive)
    #expect(
      !FileManager.default.fileExists(atPath: fixture.rootURL.appending(path: "other.txt").path))
  }

  @Test("ZIPの複数ルートはZIP名のフォルダにまとめ既存フォルダを避ける")
  func openingZIPGroupsMultipleRootsWithoutReplacingExistingFolder() async throws {
    let fixture = try ArchiveBrowsingFixture()
    defer { fixture.remove() }
    try fixture.addFile(path: "first.txt", contents: "first")
    try fixture.addFile(path: "second.txt", contents: "second")
    let existingURL = fixture.rootURL.appending(path: "fixture")
    try FileManager.default.createDirectory(at: existingURL, withIntermediateDirectories: true)
    let markerURL = existingURL.appending(path: "kept.txt")
    try Data("kept".utf8).write(to: markerURL)
    let provider = LocalFileProvider()
    let location = FileLocation(directoryURL: fixture.rootURL, providerID: provider.id)
    let browser = FileBrowserSession(
      provider: provider, initialLocation: location, transferQueue: .isolatedForTesting())
    browser.load()
    await waitForLoading(browser)
    let item = try #require(browser.items.first { $0.url == fixture.archiveURL })
    let workspace = FileWorkspaceModel(initialBrowser: browser)
    workspace.open(item, in: .primary)
    let output = fixture.rootURL.appending(path: "fixture 2")
    await waitUntil { FileManager.default.fileExists(atPath: output.path) && !browser.isArchiving }

    #expect(try Data(contentsOf: output.appending(path: "first.txt")) == Data("first".utf8))
    #expect(try Data(contentsOf: output.appending(path: "second.txt")) == Data("second".utf8))
    #expect(try Data(contentsOf: markerURL) == Data("kept".utf8))
    #expect(
      !FileManager.default.fileExists(atPath: fixture.rootURL.appending(path: "first.txt").path))
    #expect(workspace.tab(for: .primary)?.browser === browser)
  }

  @Test("ZIPの単一フォルダは名前を保ち空ZIPはZIP名フォルダに展開する", arguments: [false, true])
  func opensSingleDirectoryAndEmptyZIP(isEmpty: Bool) async throws {
    let fixture = try ArchiveBrowsingFixture()
    defer { fixture.remove() }
    if !isEmpty {
      try fixture.addFile(path: "folder.with.dot/inside.txt", contents: "inside")
      try FileManager.default.createDirectory(
        at: fixture.rootURL.appending(path: "folder.with.dot"), withIntermediateDirectories: true)
    }
    let provider = LocalFileProvider()
    let browser = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(directoryURL: fixture.rootURL, providerID: provider.id),
      transferQueue: .isolatedForTesting())
    browser.load()
    await waitForLoading(browser)
    let item = try #require(browser.items.first { $0.url == fixture.archiveURL })
    browser.open(item)
    let expectedName = isEmpty ? "fixture" : "folder.with.dot 2"
    let output = fixture.rootURL.appending(path: expectedName)
    await waitUntil { FileManager.default.fileExists(atPath: output.path) && !browser.isArchiving }

    #expect(browser.errorMessage == nil)
    #expect(browser.items.contains { $0.name == expectedName })
    #expect(
      browser.revealRequest?.itemURL.resolvingSymlinksInPath().path
        == output.resolvingSymlinksInPath().path)
    if !isEmpty {
      #expect(try Data(contentsOf: output.appending(path: "inside.txt")) == Data("inside".utf8))
    }
  }

  @Test("子フォルダのZIPもその隣へ展開し展開行一覧を更新する", arguments: [false, true])
  func opensChildZIPBesideItselfAndRefreshesExpandedChildren(useMountedProvider: Bool) async throws
  {
    let fixture = try ArchiveBrowsingFixture()
    defer { fixture.remove() }
    try fixture.addFile(path: "inside.txt", contents: "inside")
    let childURL = fixture.rootURL.appending(path: "child", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: childURL, withIntermediateDirectories: true)
    let archiveURL = childURL.appending(path: "fixture.zip")
    try FileManager.default.copyItem(at: fixture.archiveURL, to: archiveURL)
    let provider: any FileBrowserProvider =
      useMountedProvider
      ? MountedVolumeProvider(volumeURL: fixture.rootURL) : LocalFileProvider()
    let location = FileLocation(directoryURL: fixture.rootURL, providerID: provider.id)
    let browser = FileBrowserSession(
      provider: provider, initialLocation: location, transferQueue: .isolatedForTesting())
    browser.load()
    await waitForLoading(browser)
    let child = try #require(browser.items.first { $0.name == "child" })
    browser.toggleExpansion(of: child)
    await waitUntil {
      browser.treeState.children(of: child.location)?.contains { $0.name == "fixture.zip" } == true
    }
    let item = try #require(
      browser.treeState.children(of: child.location)?.first { $0.name == "fixture.zip" })
    let workspace = FileWorkspaceModel(initialBrowser: browser)
    workspace.open(item, in: .primary)
    let output = childURL.appending(path: "inside.txt")
    await waitUntil { FileManager.default.fileExists(atPath: output.path) && !browser.isArchiving }

    #expect(try Data(contentsOf: output) == Data("inside".utf8))
    #expect(
      !FileManager.default.fileExists(atPath: fixture.rootURL.appending(path: "inside.txt").path))
    #expect(browser.currentLocation == location)
    #expect(
      browser.treeState.children(of: child.location)?.contains { $0.name == "inside.txt" } == true)
  }

  private func makeView(
    workspace: FileWorkspaceModel,
    mode: FileBrowserViewMode,
    favoriteContextMenuItem: (([FileItem], FileBrowserSession) -> FileContextMenuItem?)? = nil
  ) -> ProviderBrowserView {
    ProviderBrowserView(
      title: "テスト",
      workspace: workspace,
      command: .constant(nil),
      browserViewMode: .constant(mode),
      showsSecondaryPane: .constant(workspace.showsSecondaryPane),
      detailsDisplayMode: .constant(.none),
      detailsInspectorWidth: .constant(280),
      favoriteContextMenuItem: favoriteContextMenuItem,
      onLocationChanged: { _ in })
  }

  private func waitForLoading(_ browser: FileBrowserSession) async {
    await PKPaneTests.waitUntil(timeout: .seconds(5), "ブラウザの読み込みが期限内に完了しなかった") {
      !browser.isLoading && !browser.isRefreshing
    }
  }

  private func waitForSearch(_ browser: FileBrowserSession) async {
    await PKPaneTests.waitUntil(timeout: .seconds(5), "検索が期限内に完了しなかった") {
      !browser.isSearching
    }
  }

  private func waitUntil(_ condition: @MainActor () -> Bool) async {
    await PKPaneTests.waitUntil(
      timeout: .seconds(5), "アーカイブ閲覧ルートの状態が期限内に条件を満たさなかった"
    ) {
      condition()
    }
  }
}

private final class ArchiveOpenRoutingFixture {
  let rootURL: URL
  let archiveURLs: [URL]
  let plainTextURL: URL

  init() throws {
    rootURL = FileManager.default.temporaryDirectory.appending(
      path: "pkpane-archive-open-route-\(UUID().uuidString)",
      directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

    plainTextURL = rootURL.appending(path: "plain.txt")
    try Data("fixture".utf8).write(to: plainTextURL)

    let zipURL = rootURL.appending(path: "fixture.zip")
    let zipArchive = try Archive(url: zipURL, accessMode: .create)
    try zipArchive.addEntry(
      with: "inside.txt", fileURL: plainTextURL, compressionMethod: .deflate)

    let sevenZipURL = rootURL.appending(path: "fixture.7z")
    try ArchiveTestFixtures.makeSevenZipArchive(
      entries: [(plainTextURL, "inside.txt")],
      at: sevenZipURL)

    let tarGzipURL = rootURL.appending(path: "fixture.tar.gz")
    let tarData = ArchiveTestFixtures.makeTarArchive(
      entries: [("inside.txt", Data("fixture".utf8))])
    try ArchiveTestFixtures.gzip(tarData).write(to: tarGzipURL)

    let rarURL = rootURL.appending(path: "fixture.rar")
    try ArchiveTestFixtures.windowsBackslashRAR4Data.write(to: rarURL)
    archiveURLs = [zipURL, sevenZipURL, tarGzipURL, rarURL]
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootURL)
  }
}

private final class AdditionalArchiveBrowsingFixture {
  let rootURL: URL
  let archiveURLs: [URL]

  init() throws {
    rootURL = FileManager.default.temporaryDirectory.appending(
      path: "pkpane-additional-archive-route-\(UUID().uuidString)",
      directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

    let sourceURL = rootURL.appending(path: "source.txt")
    try Data("fixture".utf8).write(to: sourceURL)
    let sevenZipURL = rootURL.appending(path: "fixture.7z")
    try ArchiveTestFixtures.makeSevenZipArchive(
      entries: [(sourceURL, "source.txt")],
      at: sevenZipURL)

    let tarGzipURL = rootURL.appending(path: "fixture.tar.gz")
    try ArchiveTestFixtures.makeEmptyTarGzipArchive(at: tarGzipURL)

    let rarURL = rootURL.appending(path: "fixture.rar")
    try ArchiveTestFixtures.windowsBackslashRAR4Data.write(to: rarURL)
    archiveURLs = [sevenZipURL, tarGzipURL, rarURL]
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootURL)
  }
}

private final class ArchiveBrowsingFixture {
  let rootURL: URL
  let archiveURL: URL
  private let sourceURL: URL
  private let archive: Archive

  init() throws {
    rootURL = FileManager.default.temporaryDirectory.appending(
      path: "pkpane-archive-route-\(UUID().uuidString)",
      directoryHint: .isDirectory)
    archiveURL = rootURL.appending(path: "fixture.zip")
    sourceURL = rootURL.appending(path: "source.bin")
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    archive = try Archive(url: archiveURL, accessMode: .create)
  }

  func addFile(path: String, contents: String) throws {
    try Data(contents.utf8).write(to: sourceURL)
    try archive.addEntry(with: path, fileURL: sourceURL, compressionMethod: .deflate)
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootURL)
  }
}

private struct ArchiveRouteSFTPClientSession: SFTPClientSession {
  func contents(of _: String) async throws -> [SFTPDirectoryEntry] {
    [SFTPDirectoryEntry(name: "fixture.zip", isDirectory: false, size: 4)]
  }

  func createDirectory(at _: String) async throws {}
  func remove(at _: String, isDirectory _: Bool) async throws {}
  func rename(at _: String, to _: String) async throws {}
  func close() async throws {}
}
