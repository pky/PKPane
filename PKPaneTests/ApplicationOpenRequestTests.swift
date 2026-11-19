import AppKit
import Foundation
import Testing

@testable import PKPane

@MainActor
struct ApplicationOpenRequestTests {
  @Test("フォルダは代替Viewerとして登録し通常ファイルの関連付けは奪わない")
  func declaresAlternateFolderViewerOnly() throws {
    let repositoryRoot = URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let infoPlistURL = repositoryRoot.appending(path: "Config/PKPane-Info.plist")
    let data = try Data(contentsOf: infoPlistURL)
    let plist = try #require(
      PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    let documentTypes = try #require(
      plist["CFBundleDocumentTypes"] as? [[String: Any]])
    let folderType = try #require(
      documentTypes.first { type in
        (type["LSItemContentTypes"] as? [String])?.contains("public.folder") == true
      })
    let genericItemType = try #require(
      documentTypes.first { type in
        (type["LSItemContentTypes"] as? [String])?.contains("public.item") == true
      })

    #expect(folderType["CFBundleTypeRole"] as? String == "Viewer")
    #expect(folderType["LSHandlerRank"] as? String == "Alternate")
    #expect(genericItemType["LSHandlerRank"] as? String == "None")
  }

  @Test("openイベントはフォルダ・ファイル・存在しないパス・複数パスを分類する")
  func resolvesOpenEventTargets() throws {
    let root = try makeFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let fileURL = root.appending(path: "target.txt")
    let missingURL = root.appending(path: "missing.txt")
    let secondURL = root.appending(path: "second.txt")

    #expect(
      ApplicationOpenRequestResolver.resolve([root])
        == ApplicationOpenResolution(target: .directory(root), ignoredURLCount: 0))
    #expect(
      ApplicationOpenRequestResolver.resolve([fileURL])
        == ApplicationOpenResolution(
          target: .file(fileURL, parentDirectory: root), ignoredURLCount: 0))
    #expect(
      ApplicationOpenRequestResolver.resolve([missingURL])
        == ApplicationOpenResolution(target: nil, ignoredURLCount: 0))
    #expect(
      ApplicationOpenRequestResolver.resolve([root, secondURL])
        == ApplicationOpenResolution(target: .directory(root), ignoredURLCount: 1))
  }

  @Test("Delegateのopen実経路は復元完了まで保留し完了後に先頭URLを配送する")
  func delegateDefersDeliveryUntilWorkspaceRestorationCompletes() throws {
    let root = try makeFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ApplicationOpenRequestStore()
    let delegate = PKPaneAppDelegate(applicationOpenRequestStore: store)

    delegate.application(NSApplication.shared, open: [root])

    #expect(store.takeNextRequestIfReady() == nil)
    store.completeWorkspaceRestoration()
    #expect(store.takeNextRequestIfReady()?.target == .directory(root))
  }

  @Test(
    "open URLの実経路は復元したアクティブペインだけを親フォルダへ移動してファイルを選択する"
  )
  func openEventNavigatesActivePaneAndSelectsFile() async throws {
    let primaryURL = try makeFixture(name: "primary")
    let secondaryURL = try makeFixture(name: "secondary")
    let targetParentURL = try makeFixture(name: "target-parent")
    defer {
      try? FileManager.default.removeItem(at: primaryURL)
      try? FileManager.default.removeItem(at: secondaryURL)
      try? FileManager.default.removeItem(at: targetParentURL)
    }
    let targetURL = targetParentURL.appending(path: "target.txt")
    let store = ApplicationOpenRequestStore()
    let delegate = PKPaneAppDelegate(applicationOpenRequestStore: store)
    let primaryBrowser = makeBrowser(at: primaryURL)
    let workspace = FileWorkspaceModel(initialBrowser: primaryBrowser, initialViewMode: .column)
    workspace.setShowsSecondaryPane(true)
    workspace.activatePane(.secondary)
    workspace.setViewMode(.icon)
    let originalPrimaryBrowser = try #require(workspace.tab(for: .primary)?.browser)
    let session = ProviderBrowserSession(title: "復元", workspace: workspace)

    delegate.application(NSApplication.shared, open: [targetURL])
    store.completeWorkspaceRestoration()
    let request = try #require(store.takeNextRequestIfReady())
    let presentation = ApplicationOpenNavigation.presentation(for: request.target)
    let openedBrowser = presentation.browser
    session.replaceActiveBrowser(
      with: openedBrowser,
      title: presentation.title,
      sftpTarget: presentation.sftpTarget)
    await waitForLoading(openedBrowser)
    let reveal = try #require(openedBrowser.revealRequest)
    let activeTab = workspace.activeTab

    #expect(workspace.activePane == .secondary)
    #expect(workspace.tab(for: .primary)?.browser === originalPrimaryBrowser)
    #expect(activeTab.viewMode == .icon)
    #expect(openedBrowser.currentLocation.localURL == targetParentURL)
    #expect(
      activeTab.selectRevealedItem(
        for: reveal,
        visibleItemURLs: Set(openedBrowser.items.map(\.url))))
    #expect(activeTab.selectedItemURLs == [targetURL])
  }

  private func makeBrowser(at url: URL) -> FileBrowserSession {
    let provider = LocalFileProvider()
    return FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: url, providerID: provider.id),
      transferQueue: .isolatedForTesting())
  }

  private func makeFixture(name: String = UUID().uuidString) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "pkpane-open-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try Data("target".utf8).write(to: url.appending(path: "target.txt"))
    try Data("second".utf8).write(to: url.appending(path: "second.txt"))
    return url.standardizedFileURL
  }

  private func waitForLoading(_ session: FileBrowserSession) async {
    await waitUntil("isLoadingが期限内にfalseにならなかった") {
      !session.isLoading
    }
  }
}
