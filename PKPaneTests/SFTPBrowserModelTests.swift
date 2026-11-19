import Foundation
import Testing

@testable import PKPane

@MainActor
struct SFTPBrowserModelTests {
  @Test("SFTPブラウザはログイン後のホームディレクトリから一覧を始める")
  func startsInRemoteHomeDirectory() async throws {
    let session = RecordingBrowserSFTPClientSession(entriesByPath: [".": []])
    let model = browser(session: session)

    model.load()
    await waitForLoading(model)

    #expect(await session.listedPaths() == ["."])
    #expect(model.currentPathDescription == ".")
  }

  @Test("開始ディレクトリより上の親フォルダを開ける")
  func opensParentAboveConfiguredStartDirectory() async throws {
    let session = RecordingBrowserSFTPClientSession(entriesByPath: [
      "/srv/projects/reports": [],
      "/srv/projects": [],
    ])
    let model = browser(session: session, initialDirectory: "/srv/projects/reports")

    model.load()
    await waitForLoading(model)
    model.openParent()
    await waitForLoading(model)

    #expect(await session.listedPaths() == ["/srv/projects/reports", "/srv/projects"])
    #expect(model.currentPathDescription == "/srv/projects")
  }

  @Test("相対開始ディレクトリからもホーム配下の親フォルダを開ける")
  func opensParentAboveRelativeStartDirectory() async throws {
    let session = RecordingBrowserSFTPClientSession(entriesByPath: [
      "./Projects/reports": [],
      "./Projects": [],
    ])
    let model = browser(session: session, initialDirectory: "Projects/reports")

    model.load()
    await waitForLoading(model)
    model.openParent()
    await waitForLoading(model)

    #expect(await session.listedPaths() == ["./Projects/reports", "./Projects"])
    #expect(model.currentPathDescription == "./Projects")
  }

  @Test("SFTPブラウザは親フォルダへ戻る")
  func opensParentDirectory() async throws {
    let session = RecordingBrowserSFTPClientSession(entriesByPath: [
      "/Projects/Reports": [],
      "/Projects": [],
    ])
    let fileProvider = provider(session: session)
    let model = browser(provider: fileProvider)

    model.load(location: remoteLocation("/Projects/Reports", for: fileProvider))
    await waitForLoading(model)
    model.openParent()
    await waitForLoading(model)

    #expect(model.currentPathDescription == "/Projects")
  }

  @Test("SFTPブラウザは戻ると進むでフォルダ履歴を移動できる")
  func navigatesBackAndForward() async throws {
    let session = RecordingBrowserSFTPClientSession(entriesByPath: [
      "/Projects": [],
      "/": [],
    ])
    let fileProvider = provider(session: session)
    let model = browser(provider: fileProvider)

    model.load(location: remoteLocation("/Projects", for: fileProvider))
    await waitForLoading(model)
    model.openParent()
    await waitForLoading(model)
    model.goBack()
    await waitForLoading(model)
    model.goForward()
    await waitForLoading(model)

    #expect(model.currentPathDescription == "/")
    #expect(model.canGoBack)
    #expect(!model.canGoForward)
  }

  @Test("SFTPブラウザの新規フォルダ操作後に一覧を更新する")
  func createsDirectoryAndReloads() async throws {
    let session = RecordingBrowserSFTPClientSession(entriesByPath: [".": []])
    let model = browser(session: session)

    model.createDirectory(named: "Archive")
    await waitForLoading(model)

    #expect(await session.createdPaths() == ["./Archive"])
  }

  @Test("SFTPブラウザはProvider契約を通じて選択項目を別ペインの場所へ移動する")
  func movesItemsToProviderLocation() async throws {
    let session = RecordingBrowserSFTPClientSession(entriesByPath: [
      "/Projects": [SFTPDirectoryEntry(name: "report.txt", isDirectory: false)],
      "/Archive": [],
    ])
    let provider = provider(session: session, initialDirectory: "/Projects")
    let model = browser(provider: provider)
    model.load()
    await waitForLoading(model)
    let item = try #require(model.items.first)

    model.move(
      [item],
      to: FileLocation(remotePath: "/Archive", providerID: provider.id))
    await waitForLoading(model)

    #expect(
      await session.renamedPaths()
        == [.init(source: "/Projects/report.txt", destination: "/Archive/report.txt")])
  }

  @Test("SFTPブラウザは表示中フォルダの項目だけを絞り込む")
  func filtersVisibleDirectoryItems() async throws {
    let session = RecordingBrowserSFTPClientSession(entriesByPath: [
      ".": [
        SFTPDirectoryEntry(name: "report.txt", isDirectory: false),
        SFTPDirectoryEntry(name: "archive.zip", isDirectory: false),
      ]
    ])
    let model = browser(session: session)

    model.load()
    await waitForLoading(model)

    #expect(model.filteredItems(matching: "report").map(\.name) == ["report.txt"])
  }

  @Test("存在しないSFTPお気に入りフォルダは接続後に理由を表示する")
  func reportsMissingFavoriteDirectory() async throws {
    let model = browser(
      session: MissingDirectorySFTPClientSession(),
      initialDirectory: "/srv/missing")

    model.load()
    await waitForLoading(model)

    #expect(model.errorMessage == "「/srv/missing」フォルダが存在しません。")
  }

  private func provider(
    session: any SFTPClientSession,
    initialDirectory: String = "."
  ) -> SFTPFileProvider {
    let target = try! SFTPConnectionTarget(
      host: "example.com",
      port: 22,
      username: "tester",
      initialDirectory: initialDirectory)
    return SFTPFileProvider(target: target, directoryListing: session)
  }

  private func browser(
    session: any SFTPClientSession,
    initialDirectory: String = "."
  ) -> FileBrowserSession {
    browser(provider: provider(session: session, initialDirectory: initialDirectory))
  }

  private func browser(provider: SFTPFileProvider) -> FileBrowserSession {
    FileBrowserSession(
      provider: provider,
      initialLocation: remoteLocation(provider.target.initialDirectory, for: provider),
      transferQueue: .isolatedForTesting())
  }

  private func remoteLocation(_ path: String, for provider: SFTPFileProvider) -> FileLocation {
    let navigationPath =
      path != "." && !path.hasPrefix("./") && !path.hasPrefix("/")
      ? "./\(path)"
      : path
    return FileLocation(remotePath: navigationPath, providerID: provider.id)
  }

  private func waitForLoading(_ model: FileBrowserSession) async {
    await waitUntil("isLoadingが期限内にfalseにならなかった") {
      !model.isLoading
    }
  }
}

private actor RecordingBrowserSFTPClientSession: SFTPClientSession {
  struct RenamedPath: Equatable {
    let source: String
    let destination: String
  }

  private var created: [String] = []
  private var listed: [String] = []
  private var renamed: [RenamedPath] = []
  private let entriesByPath: [String: [SFTPDirectoryEntry]]

  init(entriesByPath: [String: [SFTPDirectoryEntry]]) {
    self.entriesByPath = entriesByPath
  }

  func contents(of remotePath: String) async throws -> [SFTPDirectoryEntry] {
    listed.append(remotePath)
    return entriesByPath[remotePath] ?? []
  }

  func createDirectory(at remotePath: String) async throws {
    created.append(remotePath)
  }

  func remove(at _: String, isDirectory _: Bool) async throws {}

  func rename(at remotePath: String, to destinationPath: String) async throws {
    renamed.append(.init(source: remotePath, destination: destinationPath))
  }

  func close() async throws {}

  func createdPaths() -> [String] {
    created
  }

  func listedPaths() -> [String] {
    listed
  }

  func renamedPaths() -> [RenamedPath] {
    renamed
  }
}

private struct MissingDirectorySFTPClientSession: SFTPClientSession {
  func contents(of _: String) async throws -> [SFTPDirectoryEntry] {
    throw SFTPDirectoryListingError.directoryNotFound
  }

  func createDirectory(at _: String) async throws {}

  func remove(at _: String, isDirectory _: Bool) async throws {}

  func rename(at _: String, to _: String) async throws {}

  func close() async throws {}
}
