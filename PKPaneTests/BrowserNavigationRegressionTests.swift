import Foundation
import Testing

@testable import PKPane

@MainActor
struct BrowserNavigationRegressionTests {
  @Test("戻ると進むで実際のローカルフォルダ内容を復元する")
  func restoresLocalContentsWhenNavigatingHistory() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let child = root.appending(path: "child", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    try Data().write(to: root.appending(path: "root.txt"))
    try Data().write(to: child.appending(path: "child.txt"))
    let provider = LocalFileProvider()
    let session = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: root, providerID: provider.id),
      transferQueue: .isolatedForTesting())

    session.load()
    await waitForListing(session)
    let childItem = try #require(session.items.first(where: { $0.name == "child" }))
    session.open(childItem)
    await waitForListing(session)
    #expect(session.items.contains(where: { $0.name == "child.txt" }))

    session.goBack()
    await waitForListing(session)
    #expect(session.items.contains(where: { $0.name == "root.txt" }))

    session.goForward()
    await waitForListing(session)
    #expect(session.items.contains(where: { $0.name == "child.txt" }))
  }

  @Test("履歴からブラウザを差し替えると一覧読込を開始する")
  func startsLoadingWhenReplacingBrowser() async {
    let transferQueue = TransferQueue.isolatedForTesting()
    let initialProvider = NavigationListingProvider(id: "navigation-initial")
    let initial = FileBrowserSession(
      provider: initialProvider,
      initialLocation: FileLocation(remotePath: ".", providerID: initialProvider.id),
      transferQueue: transferQueue)
    let providerSession = ProviderBrowserSession(
      title: "最初の場所",
      browser: initial,
      connectionID: nil,
      sftpTarget: nil)
    providerSession.showsSecondaryPane = true
    let replacementProvider = NavigationListingProvider(id: "navigation-replacement")
    let replacement = FileBrowserSession(
      provider: replacementProvider,
      initialLocation: FileLocation(remotePath: ".", providerID: replacementProvider.id),
      transferQueue: transferQueue)

    providerSession.replaceActiveBrowser(
      with: replacement,
      title: "履歴の場所",
      sftpTarget: nil)
    await waitForListing(replacement)

    #expect(replacement.items.map(\.name) == ["report.txt"])
    #expect(providerSession.showsSecondaryPane)
  }

  @Test("新しいブラウザを表示する前に一覧読込を開始する")
  func startsLoadingWhenPreparingBrowserPresentation() async {
    let provider = NavigationListingProvider(id: "navigation-presentation")
    let browser = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: ".", providerID: provider.id),
      transferQueue: .isolatedForTesting())
    let providerSession = ProviderBrowserSession(
      title: "履歴の場所",
      browser: browser,
      connectionID: nil,
      sftpTarget: nil)

    providerSession.prepareForPresentation()
    await waitForListing(browser)

    #expect(browser.items.map(\.name) == ["report.txt"])
  }

  private func waitForListing(_ session: FileBrowserSession) async {
    await waitUntil("一覧の読み込みが期限内に完了しなかった") {
      !(session.isLoading || session.isRefreshing)
    }
  }
}

private struct NavigationListingProvider: FileBrowserProvider {
  let id: FileProviderID
  let connectionID: FileProviderConnectionID? = nil
  let capabilities: FileProviderCapabilities = [.read]

  init(id: String) {
    self.id = FileProviderID(rawValue: id)
  }

  func contents(of _: FileLocation) async throws -> [FileItem] {
    [
      FileItem(
        remotePath: "./report.txt",
        url: URL(fileURLWithPath: "/report.txt"),
        providerID: id,
        isDirectory: false)
    ]
  }

  func parent(of _: FileLocation) -> FileLocation? { nil }

  func breadcrumbs(
    for _: FileLocation,
    constrainedTo _: FileLocation?
  ) -> [FileBrowserBreadcrumb] { [] }
}
