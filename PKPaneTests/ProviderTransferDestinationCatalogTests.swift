import Foundation
import Testing

@testable import PKPane

@MainActor
struct ProviderTransferDestinationCatalogTests {
  @Test("宛先カタログは開いているタブと各保存先を可否理由付きでセクション化する")
  func buildsSectionsWithDisabledReasons() throws {
    let workspace = FileWorkspaceModel(initialBrowser: browser())
    let favorite = SavedFolderLocation(
      id: UUID(), name: "書類",
      url: URL(fileURLWithPath: "/Users/somebody/Documents", isDirectory: true))
    let broken = SavedFolderLocation(
      id: UUID(), name: "切断済み", url: nil, lastKnownPath: "/Volumes/gone")
    let nasProfile = try NASConnectionProfile(
      displayName: "自宅NAS", host: "nas.local", shareName: "share")
    let sftpTarget = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let ftpTarget = try FTPConnectionTarget(host: "ftp.example.com", username: "tester")

    let sections = ProviderTransferDestinationCatalog.makeSections(
      workspace: workspace,
      favorites: [favorite, broken],
      nasProfiles: [nasProfile],
      sftpTargets: [sftpTarget],
      ftpTargets: [ftpTarget])

    // init既定の2ペイン化で反対側タブが1件でき、複製直後は現在地が同じため理由付きで無効化される。
    let tabSection = try #require(sections.first { $0.id == "tabs" })
    #expect(sections.first?.id == "tabs")
    try #require(tabSection.destinations.count == 1)
    #expect(tabSection.destinations[0].disabledReason == "現在の場所と同じです")

    let favoriteSection = try #require(sections.first { $0.id == "favorites" })
    try #require(favoriteSection.destinations.count == 2)
    #expect(favoriteSection.destinations[0].disabledReason == nil)
    #expect(favoriteSection.destinations[1].disabledReason == "場所を利用できません")

    let volumeSection = try #require(sections.first { $0.id == "volumes" })
    try #require(volumeSection.destinations.count == 1)
    #expect(volumeSection.destinations[0].disabledReason == "マウントされていません")

    let sftpSection = try #require(sections.first { $0.id == "sftp" })
    try #require(sftpSection.destinations.count == 1)
    #expect(sftpSection.destinations[0].disabledReason == "未接続です")

    let ftpSection = try #require(sections.first { $0.id == "ftp" })
    try #require(ftpSection.destinations.count == 1)
    #expect(ftpSection.destinations[0].disabledReason == "未接続です")

    // 空セクション(recents)は含めない
    #expect(!sections.contains { $0.id == "recents" })
  }

  @Test("マウント済み・接続済みの宛先は選択可能で宛先セッションを生成できる")
  func createsSessionsForAvailableDestinations() throws {
    let workspace = FileWorkspaceModel(initialBrowser: browser())
    let nasProfile = try NASConnectionProfile(
      displayName: "自宅NAS", host: "nas.local", shareName: "share")
    let volumeURL = URL(fileURLWithPath: "/Volumes/share", isDirectory: true)
    let mountedProvider = MountedVolumeProvider(profile: nasProfile, volumeURL: volumeURL)
    let sftpTarget = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let sftpFileProvider = SFTPFileProvider(
      target: sftpTarget,
      directoryListing: CatalogStubSFTPDirectoryListing(entries: []))
    let ftpTarget = try FTPConnectionTarget(
      host: "ftp.example.com", username: "tester", initialDirectory: "/incoming")
    let ftpSession = CatalogStubFTPClientSession()
    let ftpFileProvider = FTPFileProvider(
      target: ftpTarget,
      session: ftpSession,
      sessionFactory: { ftpSession })

    let sections = ProviderTransferDestinationCatalog.makeSections(
      workspace: workspace,
      nasProfiles: [nasProfile],
      sftpTargets: [sftpTarget],
      ftpTargets: [ftpTarget],
      volumeProvider: { _ in mountedProvider },
      sftpProvider: { _ in sftpFileProvider },
      ftpProvider: { _ in ftpFileProvider })

    let volumeDestination = try #require(
      sections.first { $0.id == "volumes" }?.destinations.first)
    #expect(volumeDestination.disabledReason == nil)
    let volumeSession = try #require(volumeDestination.makeDestination())
    #expect(
      volumeSession.currentLocation
        == FileLocation(localURL: volumeURL, providerID: mountedProvider.id))

    let sftpDestination = try #require(
      sections.first { $0.id == "sftp" }?.destinations.first)
    #expect(sftpDestination.disabledReason == nil)
    let sftpSession = try #require(sftpDestination.makeDestination())
    #expect(
      sftpSession.currentLocation
        == FileLocation(remotePath: ".", providerID: sftpFileProvider.id))

    let ftpDestination = try #require(
      sections.first { $0.id == "ftp" }?.destinations.first)
    #expect(ftpDestination.disabledReason == nil)
    let ftpBrowser = try #require(ftpDestination.makeDestination())
    #expect(
      ftpBrowser.currentLocation
        == FileLocation(remotePath: "/incoming", providerID: ftpFileProvider.id))
  }

  @Test("リンク先を同一宛先として無効化する")
  func disablesCanonicalLocalDestination() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(
        path: "ProviderTransferDestinationCatalogTests-\(UUID().uuidString)",
        directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    let actualDirectory = root.appending(path: "actual", directoryHint: .isDirectory)
    let linkedDirectory = root.appending(path: "linked", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: actualDirectory, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: linkedDirectory, withDestinationURL: actualDirectory)

    let provider = LocalFileProvider()
    let workspace = FileWorkspaceModel(
      initialBrowser: FileBrowserSession(
        provider: provider,
        initialLocation: FileLocation(localURL: linkedDirectory, providerID: provider.id),
        transferQueue: .isolatedForTesting()))
    let favorite = SavedFolderLocation(id: UUID(), name: "実体", url: actualDirectory)

    let sections = ProviderTransferDestinationCatalog.makeSections(
      workspace: workspace, favorites: [favorite])
    let destination = try #require(
      sections.first { $0.id == "favorites" }?.destinations.first)

    #expect(destination.disabledReason == "現在の場所と同じです")
  }

  @Test("SFTPのお気に入りと履歴を別セクションにし同じ場所を無効化する")
  func buildsSFTPFavoriteAndRecentSectionsWithDisabledReasons() throws {
    let target = try SFTPConnectionTarget(
      host: "example.com", port: 22, username: "tester", initialDirectory: "projects")
    let provider = SFTPFileProvider(
      target: target,
      directoryListing: CatalogStubSFTPDirectoryListing(entries: []))
    let workspace = FileWorkspaceModel(
      initialBrowser: FileBrowserSession(
        provider: provider,
        initialLocation: FileLocation(remotePath: "./projects", providerID: provider.id),
        transferQueue: .isolatedForTesting()))

    let sftpFavorite = SFTPFolderFavorite(target: target, directory: "projects")
    let sftpRecent = SFTPFolderRecent(target: target, directory: "projects")
    let sections = ProviderTransferDestinationCatalog.makeSections(
      workspace: workspace,
      sftpFavorites: [sftpFavorite],
      sftpRecents: [sftpRecent],
      sftpProvider: { _ in provider })

    let favorite = try #require(
      sections.first { $0.id == "favorites" }?.destinations.first)
    #expect(favorite.id == "sftp-favorite-\(sftpFavorite.id.uuidString)")
    #expect(favorite.disabledReason == "現在の場所と同じです")

    let recent = try #require(sections.first { $0.id == "recents" }?.destinations.first)
    #expect(recent.id == "sftp-recent-\(sftpRecent.id.uuidString)")
    #expect(recent.disabledReason == "現在の場所と同じです")
  }

  @Test("通常パスで現在地と同じお気に入りを無効化する")
  func disablesDirectLocalFavoriteMatchingCurrentLocation() throws {
    let workspace = FileWorkspaceModel(initialBrowser: browser())
    let favorite = SavedFolderLocation(
      id: UUID(), name: "一時フォルダ",
      url: URL(fileURLWithPath: "/tmp", isDirectory: true))

    let sections = ProviderTransferDestinationCatalog.makeSections(
      workspace: workspace, favorites: [favorite])
    let destination = try #require(
      sections.first { $0.id == "favorites" }?.destinations.first)

    #expect(destination.disabledReason == "現在の場所と同じです")
  }

  @Test("FTPのお気に入りと履歴を転送先として生成する")
  func buildsFTPFolderDestinations() throws {
    let workspace = FileWorkspaceModel(initialBrowser: browser())
    let target = try FTPConnectionTarget(host: "ftp.example.com", username: "tester")
    let session = CatalogStubFTPClientSession()
    let provider = FTPFileProvider(
      target: target,
      session: session,
      sessionFactory: { session })
    let favorite = FTPFolderFavorite(target: target, directory: "/incoming")
    let recent = FTPFolderRecent(target: target, directory: "/archive")

    let sections = ProviderTransferDestinationCatalog.makeSections(
      workspace: workspace,
      ftpFavorites: [favorite],
      ftpRecents: [recent],
      ftpProvider: { _ in provider })

    let favoriteDestination = try #require(
      sections.first { $0.id == "favorites" }?.destinations.first)
    #expect(favoriteDestination.id == "ftp-favorite-\(favorite.id.uuidString)")
    #expect(favoriteDestination.makeDestination()?.currentLocation.remotePath == "/incoming")
    let recentDestination = try #require(
      sections.first { $0.id == "recents" }?.destinations.first)
    #expect(recentDestination.id == "ftp-recent-\(recent.id.uuidString)")
    #expect(recentDestination.makeDestination()?.currentLocation.remotePath == "/archive")
  }

  @Test("ローカル履歴があると最近使用した場所セクションを作る")
  func buildsRecentsSectionForLocalRecentLocation() throws {
    let workspace = FileWorkspaceModel(initialBrowser: browser())
    let recent = SavedFolderLocation(
      id: UUID(), name: "書類",
      url: URL(fileURLWithPath: "/Users/somebody/Documents", isDirectory: true))

    let sections = ProviderTransferDestinationCatalog.makeSections(
      workspace: workspace, recents: [recent])
    let recentSection = try #require(sections.first { $0.id == "recents" })

    try #require(recentSection.destinations.count == 1)
    #expect(recentSection.destinations[0].title == "書類")
  }

  @Test("保存先IDから対応するお気に入りと履歴だけを検索する")
  func findsDestinationByID() throws {
    let workspace = FileWorkspaceModel(initialBrowser: browser())
    let favorite = SavedFolderLocation(
      id: UUID(), name: "書類",
      url: URL(fileURLWithPath: "/Users/somebody/Documents", isDirectory: true))
    let recent = SavedFolderLocation(
      id: UUID(), name: "ダウンロード",
      url: URL(fileURLWithPath: "/Users/somebody/Downloads", isDirectory: true))
    let sections = ProviderTransferDestinationCatalog.makeSections(
      workspace: workspace, favorites: [favorite], recents: [recent])

    let favoriteDestination = try #require(
      ProviderTransferDestinationCatalog.destination(
        id: "favorite-\(favorite.id.uuidString)", in: sections))
    let recentDestination = try #require(
      ProviderTransferDestinationCatalog.destination(
        id: "recent-\(recent.id.uuidString)", in: sections))

    #expect(favoriteDestination.title == "書類")
    #expect(recentDestination.title == "ダウンロード")
    #expect(
      ProviderTransferDestinationCatalog.destination(
        id: "favorite-unknown", in: sections) == nil)
  }

  private func browser() -> FileBrowserSession {
    let provider = LocalFileProvider()
    let location = FileLocation(localURL: URL(fileURLWithPath: "/tmp", isDirectory: true))
    return FileBrowserSession(
      provider: provider, initialLocation: location, transferQueue: .isolatedForTesting())
  }
}

/// PKPaneTests/SFTPFileProviderTests.swift のStubSFTPDirectoryListingはprivateで
/// 参照できないため、entriesを返すだけの最小スタブをこのファイル専用に定義する。
private struct CatalogStubSFTPDirectoryListing: SFTPClientSession {
  let entries: [SFTPDirectoryEntry]

  func contents(of remotePath: String) async throws -> [SFTPDirectoryEntry] {
    entries
  }

  func createDirectory(at _: String) async throws {}

  func remove(at _: String, isDirectory _: Bool) async throws {}

  func rename(at _: String, to _: String) async throws {}

  func close() async throws {}
}

private struct CatalogStubFTPClientSession: FTPClientSession {
  func contents(of _: String) async throws -> [FTPDirectoryEntry] { [] }
  func createDirectory(at _: String) async throws {}
  func remove(at _: String, isDirectory _: Bool) async throws {}
  func rename(at _: String, to _: String) async throws {}
  func streamFileContents(
    of _: String,
    receive _: @escaping @Sendable (Data) async throws -> Void
  ) async throws {}
  func writeFileContents(
    to _: String,
    chunks _: AsyncThrowingStream<Data, Error>,
    progress _: @escaping @Sendable (Int64) -> Void
  ) async throws {}
  func fileSize(at _: String) async throws -> Int64? { nil }
  func setPosixPermissions(_: Int, at _: String) async throws {}
  func isActive() async -> Bool { true }
  func close() async {}
}
