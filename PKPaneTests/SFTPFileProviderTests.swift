import AppKit
import Foundation
import Synchronization
import Testing

@testable import PKPane

struct SFTPFileProviderTests {
  @Test("ホームの絶対パスを解決するとホームより上へ移動できる")
  func parentOfHomeUsesResolvedAbsoluteHome() async throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let session = ExistingFileSFTPClientSession(
      destinationPath: ".", entries: [], realPaths: [".": "/home/tester"])
    let provider = SFTPFileProvider(target: target, directoryListing: session)

    await provider.resolveHomeDirectory()

    #expect(
      provider.parent(of: FileLocation(remotePath: ".", providerID: provider.id))
        == FileLocation(remotePath: "/home", providerID: provider.id))
    #expect(
      provider.parent(of: FileLocation(remotePath: "/home", providerID: provider.id))
        == FileLocation(remotePath: "/", providerID: provider.id))
    #expect(provider.parent(of: FileLocation(remotePath: "/", providerID: provider.id)) == nil)
    #expect(
      provider.parent(of: FileLocation(remotePath: "./Music", providerID: provider.id))
        == FileLocation(remotePath: ".", providerID: provider.id))

    let directChildSession = ExistingFileSFTPClientSession(
      destinationPath: ".", entries: [], realPaths: [".": "/tester"])
    let directChildProvider = SFTPFileProvider(target: target, directoryListing: directChildSession)
    await directChildProvider.resolveHomeDirectory()
    #expect(
      directChildProvider.parent(
        of: FileLocation(remotePath: ".", providerID: directChildProvider.id))
        == FileLocation(remotePath: "/", providerID: directChildProvider.id))
  }

  @Test("ホームの絶対パスを解決できなくても相対パスの一覧を取得できる")
  func parentOfHomeIsNilWhenRealPathFails() async throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let session = ExistingFileSFTPClientSession(
      destinationPath: ".",
      entries: [SFTPDirectoryEntry(name: "Music", isDirectory: true)],
      failsRealPath: true)
    let provider = SFTPFileProvider(target: target, directoryListing: session)
    let home = FileLocation(remotePath: ".", providerID: provider.id)

    await provider.resolveHomeDirectory()
    let items = try await provider.contents(of: home)

    #expect(provider.parent(of: home) == nil)
    #expect(items.map(\.name) == ["Music"])
    #expect(items.map { $0.location.remotePath } == ["./Music"])
    let breadcrumbs = provider.breadcrumbs(for: home, constrainedTo: nil)
    #expect(breadcrumbs.map(\.name) == ["ホームディレクトリ"])
    #expect(breadcrumbs.map { $0.location.remotePath } == ["."])
    #expect(await session.realPathCalls() == ["."])
  }

  @Test("相対パスのパンくずにはホームより上の絶対パスを含める")
  func relativeBreadcrumbsIncludeAbsoluteAncestors() async throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let session = ExistingFileSFTPClientSession(
      destinationPath: ".", entries: [], realPaths: [".": "/home/tester"])
    let provider = SFTPFileProvider(target: target, directoryListing: session)
    await provider.resolveHomeDirectory()

    let breadcrumbs = provider.breadcrumbs(
      for: FileLocation(remotePath: "./Music", providerID: provider.id), constrainedTo: nil)

    #expect(breadcrumbs.map(\.name) == ["/", "home", "ホームディレクトリ", "Music"])
    #expect(breadcrumbs.map { $0.location.remotePath } == ["/", "/home", ".", "./Music"])
    #expect(breadcrumbs.allSatisfy { $0.location.providerID == provider.id })
  }

  @Test("ホーム配下の絶対パスのパンくずは相対パスへ戻る")
  func absolutePathUnderHomeNormalizesToRelativeBreadcrumbs() async throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let session = ExistingFileSFTPClientSession(
      destinationPath: ".", entries: [], realPaths: [".": "/home/tester"])
    let provider = SFTPFileProvider(target: target, directoryListing: session)
    await provider.resolveHomeDirectory()

    let breadcrumbs = provider.breadcrumbs(
      for: FileLocation(remotePath: "/home/tester/Music", providerID: provider.id),
      constrainedTo: nil)

    #expect(breadcrumbs.map(\.name) == ["/", "home", "ホームディレクトリ", "Music"])
    #expect(breadcrumbs.map { $0.location.remotePath } == ["/", "/home", ".", "./Music"])
    #expect(breadcrumbs.allSatisfy { $0.location.providerID == provider.id })
  }

  @Test("ホーム外の絶対パスのパンくずは絶対パスを維持する")
  func absolutePathOutsideHomeKeepsAbsoluteBreadcrumbs() async throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let session = ExistingFileSFTPClientSession(
      destinationPath: ".", entries: [], realPaths: [".": "/home/tester"])
    let provider = SFTPFileProvider(target: target, directoryListing: session)
    await provider.resolveHomeDirectory()

    let breadcrumbs = provider.breadcrumbs(
      for: FileLocation(remotePath: "/etc/ssh", providerID: provider.id), constrainedTo: nil)

    #expect(breadcrumbs.map(\.name) == ["/", "etc", "ssh"])
    #expect(breadcrumbs.map { $0.location.remotePath } == ["/", "/etc", "/etc/ssh"])
    #expect(breadcrumbs.allSatisfy { $0.location.providerID == provider.id })
  }

  @Test("ホームの絶対パス解決は一度だけ実行する")
  func resolveHomeDirectoryCallsRealPathOnce() async throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let session = ExistingFileSFTPClientSession(
      destinationPath: ".", entries: [], realPaths: [".": "/home/tester"])
    let provider = SFTPFileProvider(target: target, directoryListing: session)

    await provider.resolveHomeDirectory()
    await provider.resolveHomeDirectory()

    #expect(await session.realPathCalls() == ["."])
  }

  @Test("ホーム解決が応答しなくてもタイムアウト後に従来動作へ戻る")
  func homeResolutionTimesOutAndFallsBack() async throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let session = NonRespondingRealPathSFTPClientSession()
    let provider = SFTPFileProvider(target: target, directoryListing: session)
    let clock = ContinuousClock()
    let startedAt = clock.now

    await provider.resolveHomeDirectory(timeout: .milliseconds(200))

    let elapsed = startedAt.duration(to: clock.now)
    #expect(elapsed >= .milliseconds(150))
    #expect(elapsed < .seconds(1))
    #expect(
      provider.parent(of: FileLocation(remotePath: ".", providerID: provider.id)) == nil)
  }

  @Test("ホームがルートなら親を持たずパンくずを重複させない")
  func rootHomeHasNoParentAndNoDuplicateCrumb() async throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "root")
    let session = ExistingFileSFTPClientSession(
      destinationPath: ".", entries: [], realPaths: [".": "/"])
    let provider = SFTPFileProvider(target: target, directoryListing: session)
    let home = FileLocation(remotePath: ".", providerID: provider.id)

    await provider.resolveHomeDirectory()

    #expect(provider.parent(of: home) == nil)
    #expect(
      provider.breadcrumbs(for: home, constrainedTo: nil).map(\.name) == [
        "ホームディレクトリ"
      ])
  }

  @Test("同一版のSFTPプレビューはディスクキャッシュを再利用する")
  func reusesPreviewForSameRemoteVersion() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "remote-preview-\(UUID().uuidString)", directoryHint: .isDirectory)
    let legacyRoot = FileManager.default.temporaryDirectory
      .appending(path: "legacy-preview-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: legacyRoot)
    }
    let session = PreviewRecordingSFTPClientSession(contents: Data("preview".utf8))
    let cache = RemotePreviewCache(rootURL: root, legacyRootURL: legacyRoot)
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let provider = SFTPFileProvider(
      target: target,
      directoryListing: session,
      previewCache: cache)
    let item = FileItem(
      remotePath: "/report.txt",
      url: URL(filePath: "/report.txt"),
      providerID: provider.id,
      isDirectory: false,
      size: 7,
      modifiedAt: Date(timeIntervalSince1970: 100))

    let firstURL = try await provider.previewURL(for: item)
    let secondURL = try await provider.previewURL(for: item)

    #expect(firstURL == secondURL)
    #expect(try Data(contentsOf: secondURL) == Data("preview".utf8))
    #expect(await session.fileContentsCallCount == 1)
  }

  @Test("SFTPプレビューの版が変わると再取得する")
  func reloadsPreviewWhenRemoteVersionChanges() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "remote-preview-\(UUID().uuidString)", directoryHint: .isDirectory)
    let legacyRoot = FileManager.default.temporaryDirectory
      .appending(path: "legacy-preview-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: legacyRoot)
    }
    let session = PreviewRecordingSFTPClientSession(contents: Data("preview".utf8))
    let cache = RemotePreviewCache(rootURL: root, legacyRootURL: legacyRoot)
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let provider = SFTPFileProvider(
      target: target,
      directoryListing: session,
      previewCache: cache)
    let oldItem = FileItem(
      remotePath: "/report.txt",
      url: URL(filePath: "/report.txt"),
      providerID: provider.id,
      isDirectory: false,
      size: 7,
      modifiedAt: Date(timeIntervalSince1970: 100))
    let newItem = FileItem(
      remotePath: "/report.txt",
      url: URL(filePath: "/report.txt"),
      providerID: provider.id,
      isDirectory: false,
      size: 7,
      modifiedAt: Date(timeIntervalSince1970: 200))

    let oldURL = try await provider.previewURL(for: oldItem)
    let newURL = try await provider.previewURL(for: newItem)

    #expect(oldURL != newURL)
    #expect(await session.fileContentsCallCount == 2)
  }

  @Test("SFTP詳細サムネイルはキャッシュ未命中時にダウンロードしない")
  func detailThumbnailMissDoesNotDownload() async throws {
    let fixture = try SFTPPreviewFixture()
    defer { fixture.remove() }
    let session = PreviewRecordingSFTPClientSession(contents: Data("preview".utf8))
    let provider = try fixture.makeProvider(session: session)
    let item = fixture.makeItem(provider: provider)

    let thumbnailURL = try await provider.detailThumbnailURL(for: item)

    #expect(thumbnailURL == nil)
    #expect(await session.fileContentsCallCount == 0)
  }

  @Test("Quick Lookで温めた同一版をSFTP詳細サムネイルに使う")
  @MainActor
  func detailThumbnailUsesWarmedPreviewWithoutRedownload() async throws {
    let fixture = try SFTPPreviewFixture()
    defer { fixture.remove() }
    let pngData = try Self.makePNGData()
    let session = PreviewRecordingSFTPClientSession(contents: pngData)
    let provider = try fixture.makeProvider(session: session)
    let item = fixture.makeItem(provider: provider, size: Int64(pngData.count))
    let browser = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: "/", providerID: provider.id),
      transferQueue: .isolatedForTesting())
    _ = try await provider.previewURL(for: item)
    let model = FileInfoContentModel()

    model.setSelection(
      [item],
      thumbnailURLResolver: { try await browser.detailThumbnailURL(for: $0) })
    await Self.waitForHeaderImage(model)

    #expect(model.headerImage != nil)
    #expect(await session.fileContentsCallCount == 1)
  }

  @Test("SFTP詳細サムネイルは更新日時またはサイズが異なる版に命中しない")
  func detailThumbnailRejectsChangedRemoteVersion() async throws {
    let fixture = try SFTPPreviewFixture()
    defer { fixture.remove() }
    let session = PreviewRecordingSFTPClientSession(contents: Data("preview".utf8))
    let provider = try fixture.makeProvider(session: session)
    let oldItem = fixture.makeItem(
      provider: provider,
      size: 7,
      modifiedAt: Date(timeIntervalSince1970: 100))
    let changedDateItem = fixture.makeItem(
      provider: provider,
      size: 7,
      modifiedAt: Date(timeIntervalSince1970: 200))
    let changedSizeItem = fixture.makeItem(
      provider: provider,
      size: 8,
      modifiedAt: Date(timeIntervalSince1970: 100))
    _ = try await provider.previewURL(for: oldItem)

    let changedDateURL = try await provider.detailThumbnailURL(for: changedDateItem)
    let changedSizeURL = try await provider.detailThumbnailURL(for: changedSizeItem)

    #expect(changedDateURL == nil)
    #expect(changedSizeURL == nil)
    #expect(await session.fileContentsCallCount == 1)
  }

  @Test("SFTP相対ルートのパンくずはホームディレクトリとして表示する")
  func relativeRootBreadcrumbUsesHomeDirectoryName() throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let provider = SFTPFileProvider(
      target: target,
      directoryListing: StubSFTPDirectoryListing(entries: []))
    let root = FileLocation(remotePath: ".", providerID: provider.id)

    let breadcrumbs = provider.breadcrumbs(for: root, constrainedTo: nil)

    #expect(breadcrumbs.map(\.name) == ["ホームディレクトリ"])
    #expect(breadcrumbs.first?.location == root)
    #expect(!provider.capabilities.contains(.finderTags))
    #expect(!provider.capabilities.contains(.gitStatus))
  }

  @MainActor
  private static func waitForHeaderImage(_ model: FileInfoContentModel) async {
    await waitUntil("ヘッダー画像が期限内に生成されなかった") {
      model.headerImage != nil
    }
  }

  @MainActor
  private static func makePNGData() throws -> Data {
    let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
      NSColor.purple.setFill()
      rect.fill()
      return true
    }
    let tiff = try #require(image.tiffRepresentation)
    return try #require(
      NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
  }

  @Test("SFTP一覧はリモートパスと提供元を保った項目を返す")
  func listsRemoteEntries() async throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 2222, username: "tester")
    let listing = StubSFTPDirectoryListing(entries: [
      SFTPDirectoryEntry(name: "report.txt", isDirectory: false, size: 128),
      SFTPDirectoryEntry(name: "Documents", isDirectory: true),
      SFTPDirectoryEntry(name: ".", isDirectory: true),
    ])
    let provider = SFTPFileProvider(target: target, directoryListing: listing)

    let items = try await provider.contents(of: "/Projects")

    #expect(items.map(\.name) == ["Documents", "report.txt"])
    #expect(
      items.compactMap(\.location.remotePath)
        == ["/Projects/Documents", "/Projects/report.txt"])
    #expect(items.allSatisfy { $0.location.providerID == provider.id })
    #expect(items.map(\.url.scheme) == ["sftp", "sftp"])
  }

  @Test("転送検証のitemSizeは単一statを使い親ディレクトリを列挙しない")
  func itemSizeUsesLightweightStatWithoutListingParentDirectory() async throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let session = SizeTrackingSFTPClientSession(size: 900)
    let provider = SFTPFileProvider(target: target, directoryListing: session)
    let location = FileLocation(remotePath: "/Projects/report.txt", providerID: provider.id)

    let size = try await provider.itemSize(at: location)

    #expect(size == 900)
    #expect(await session.listingCallCount() == 0)
  }

  @Test("SFTPReconnectingSession越しでもfileSizeは単一statへ転送され列挙は発生しない")
  func reconnectingSessionForwardsFileSizeWithoutListing() async throws {
    let inner = SizeTrackingSFTPClientSession(size: 900)
    let reconnecting = SFTPReconnectingSession(session: inner) { inner }

    let size = try await reconnecting.fileSize(at: "/Projects/report.txt")

    #expect(size == 900)
    #expect(await inner.listingCallCount() == 0)
  }

  @Test("fileSizeを実装しないSFTPClientSessionは列挙フォールバックで実サイズを返す")
  func fileSizeDefaultImplementationFallsBackToListing() async throws {
    let listing = StubSFTPDirectoryListing(entries: [
      SFTPDirectoryEntry(name: "report.txt", isDirectory: false, size: 900),
      SFTPDirectoryEntry(name: "other.txt", isDirectory: false, size: 1),
    ])

    let size = try await listing.fileSize(at: "/Projects/report.txt")

    #expect(size == 900)
  }

  @Test("情報パネル向けの詳細取得は親ディレクトリ列挙から該当項目を探す")
  func detailedItemFindsMatchingEntryInParentDirectory() async throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let listing = StubSFTPDirectoryListing(entries: [
      SFTPDirectoryEntry(
        name: "report.txt", isDirectory: false, size: 900, posixPermissions: 0o640),
      SFTPDirectoryEntry(name: "other.txt", isDirectory: false, size: 1),
    ])
    let provider = SFTPFileProvider(target: target, directoryListing: listing)
    let location = FileLocation(remotePath: "/Projects/report.txt", providerID: provider.id)

    let item = try await provider.detailedItem(at: location)

    #expect(item.name == "report.txt")
    #expect(item.size == 900)
    #expect(item.posixPermissions == 0o640)
  }

  @Test("SFTPのPOSIX権限変更を接続済みセッションへ渡す")
  func setsRemotePosixPermissions() async throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let session = RecordingSFTPClientSession(entriesAt: "/Projects", entries: [])
    let provider = SFTPFileProvider(target: target, directoryListing: session)
    let location = FileLocation(remotePath: "/Projects/report.txt", providerID: provider.id)

    try await provider.setPosixPermissions(0o100660, at: location)

    #expect(await session.operations() == [.setPosixPermissions("/Projects/report.txt", 0o660)])
  }

  @Test("SFTPの作成・名称変更・移動・確認後削除を接続済みセッションへ渡す")
  func performsRemoteOperations() async throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let session = RecordingSFTPClientSession(
      entriesAt: "/Projects",
      entries: [SFTPDirectoryEntry(name: "report.txt", isDirectory: false)])
    let provider = SFTPFileProvider(target: target, directoryListing: session)
    let item = try #require(try await provider.contents(of: "/Projects").first)

    try await provider.createDirectory(named: "Archive", in: "/Projects")
    try await provider.rename(item, to: "summary.txt")
    try await provider.move(item, to: "/Archive")
    await #expect(throws: FileBrowserOperationError.self) {
      try await provider.delete(item)
    }
    try await (provider as any FileBrowserPermanentDeleteProvider).permanentlyDelete(item)

    let operations = await session.operations()

    #expect(
      operations
        == [
          .createDirectory("/Projects/Archive"),
          .rename("/Projects/report.txt", "/Projects/summary.txt"),
          .rename("/Projects/report.txt", "/Archive/report.txt"),
          .remove("/Projects/report.txt", false),
        ])
  }

  @Test("SFTPの名称変更はremotePathを持たない項目を明示的に拒否する")
  func renameRejectsItemWithoutRemotePath() async throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let session = RecordingSFTPClientSession(entriesAt: "/Projects", entries: [])
    let provider = SFTPFileProvider(target: target, directoryListing: session)
    let localItem = FileItem(
      url: URL(filePath: "/tmp/report.txt"),
      providerID: provider.id,
      isDirectory: false
    )

    do {
      try await provider.rename(localItem, to: "summary.txt")
      Issue.record("remotePathを持たない項目の名称変更が成功扱いになりました")
    } catch SFTPFileProviderError.invalidLocation {
    } catch {
      Issue.record("想定外のエラーです: \(error)")
    }

    #expect(await session.operations().isEmpty)
  }

  @Test("SFTPの移動先は共通のFileLocationで指定できる")
  func movesToProviderLocation() async throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let session = RecordingSFTPClientSession(
      entriesAt: "/Projects",
      entries: [SFTPDirectoryEntry(name: "report.txt", isDirectory: false)])
    let provider = SFTPFileProvider(target: target, directoryListing: session)
    let item = try #require(try await provider.contents(of: "/Projects").first)

    try await provider.move(
      item,
      to: FileLocation(remotePath: "/Archive", providerID: provider.id))

    #expect(await session.operations() == [.rename("/Projects/report.txt", "/Archive/report.txt")])
  }

  @Test("SFTP移動は置換ありで既存の宛先ファイルを削除してから名称変更する")
  func moveWithReplacingRemovesExistingDestinationThenRenames() async throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let session = ExistingFileSFTPClientSession(
      destinationPath: "/Archive",
      entries: [SFTPDirectoryEntry(name: "report.txt", isDirectory: false)])
    let provider = SFTPFileProvider(target: target, directoryListing: session)
    let item = FileItem(
      remotePath: "/Projects/report.txt",
      url: URL(filePath: "/Projects/report.txt"),
      providerID: provider.id,
      isDirectory: false)
    let destination = FileLocation(remotePath: "/Archive", providerID: provider.id)

    try await provider.move(item, to: destination, replacingExisting: true)

    #expect(
      await session.moveOperations() == [
        .remove("/Archive/report.txt", false),
        .rename("/Projects/report.txt", "/Archive/report.txt"),
      ])
  }

  @Test("SFTP移動は置換ありでも算出済み宛先が移動元自身なら何もしない")
  func moveWithReplacingSkipsWhenDestinationIsSource() async throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let session = ExistingFileSFTPClientSession(
      destinationPath: "/Archive",
      entries: [SFTPDirectoryEntry(name: "report.txt", isDirectory: false)])
    let provider = SFTPFileProvider(target: target, directoryListing: session)
    let item = FileItem(
      remotePath: "/Archive/report.txt",
      url: URL(filePath: "/Archive/report.txt"),
      providerID: provider.id,
      isDirectory: false)
    let destination = FileLocation(remotePath: "/Archive", providerID: provider.id)

    try await provider.move(item, to: destination, replacingExisting: true)

    #expect(await session.moveOperations().isEmpty)
  }

  @Test("SFTP移動は置換ありでも移動元フォルダ配下への移動を拒否する")
  func moveWithReplacingRejectsDestinationInsideSource() async throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let session = ExistingFileSFTPClientSession(
      destinationPath: "/Projects/X",
      entries: [SFTPDirectoryEntry(name: "X", isDirectory: true)])
    let provider = SFTPFileProvider(target: target, directoryListing: session)
    let item = FileItem(
      remotePath: "/Projects/X",
      url: URL(filePath: "/Projects/X"),
      providerID: provider.id,
      isDirectory: true)
    let destination = FileLocation(remotePath: "/Projects/X", providerID: provider.id)

    do {
      try await provider.move(item, to: destination, replacingExisting: true)
      Issue.record("移動元フォルダ配下への移動が成功扱いになりました")
    } catch SFTPFileProviderError.invalidLocation {
    } catch {
      Issue.record("想定外のエラーです: \(error)")
    }

    #expect(await session.moveOperations().isEmpty)
  }

  @Test("SFTP移動は相対パスの移動元と実体が同じ宛先なら何もしない")
  func moveWithReplacingSkipsWhenRelativeSourceResolvesToDestination() async throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let session = ExistingFileSFTPClientSession(
      destinationPath: "/home/user",
      entries: [SFTPDirectoryEntry(name: "report.txt", isDirectory: false)],
      realPaths: [
        ".": "/home/user",
        "./report.txt": "/home/user/report.txt",
        "/home/user": "/home/user",
      ])
    let provider = SFTPFileProvider(target: target, directoryListing: session)
    let item = FileItem(
      remotePath: "./report.txt",
      url: URL(filePath: "./report.txt"),
      providerID: provider.id,
      isDirectory: false)
    let destination = FileLocation(remotePath: "/home/user", providerID: provider.id)

    try await provider.move(item, to: destination, replacingExisting: true)

    #expect(await session.moveOperations().isEmpty)
  }

  @Test("SFTP移動は相対パスの移動元フォルダ自身への移動を拒否する")
  func moveWithReplacingRejectsRelativeDestinationInsideSource() async throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let session = ExistingFileSFTPClientSession(
      destinationPath: "/home/user/X",
      entries: [SFTPDirectoryEntry(name: "X", isDirectory: true)],
      realPaths: [
        "./X": "/home/user/X",
        "/home/user/X": "/home/user/X",
      ])
    let provider = SFTPFileProvider(target: target, directoryListing: session)
    let item = FileItem(
      remotePath: "./X",
      url: URL(filePath: "./X"),
      providerID: provider.id,
      isDirectory: true)
    let destination = FileLocation(remotePath: "/home/user/X", providerID: provider.id)

    do {
      try await provider.move(item, to: destination, replacingExisting: true)
      Issue.record("相対パスの移動元フォルダ自身への移動が成功扱いになりました")
    } catch SFTPFileProviderError.invalidLocation {
    } catch {
      Issue.record("想定外のエラーです: \(error)")
    }

    #expect(await session.moveOperations().isEmpty)
  }

  @Test("SFTP移動は実体パスの解決失敗時に既存宛先を削除しない")
  func moveWithReplacingSkipsDeletionWhenRealPathFails() async throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let session = ExistingFileSFTPClientSession(
      destinationPath: "/Archive",
      entries: [SFTPDirectoryEntry(name: "report.txt", isDirectory: false)],
      failsRealPath: true)
    let provider = SFTPFileProvider(target: target, directoryListing: session)
    let item = FileItem(
      remotePath: "./report.txt",
      url: URL(filePath: "./report.txt"),
      providerID: provider.id,
      isDirectory: false)
    let destination = FileLocation(remotePath: "/Archive", providerID: provider.id)

    await #expect(throws: CocoaError(.fileWriteFileExists)) {
      try await provider.move(item, to: destination, replacingExisting: true)
    }

    #expect(
      await session.moveOperations() == [
        .rename("./report.txt", "/Archive/report.txt")
      ])
  }

  @Test("SFTP移動は置換なしなら実体パスを解決しない")
  func moveWithoutReplacingDoesNotResolveRealPath() async throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let session = ExistingFileSFTPClientSession(destinationPath: "/Archive", entries: [])
    let provider = SFTPFileProvider(target: target, directoryListing: session)
    let item = FileItem(
      remotePath: "./report.txt",
      url: URL(filePath: "./report.txt"),
      providerID: provider.id,
      isDirectory: false)
    let destination = FileLocation(remotePath: "/Archive", providerID: provider.id)

    try await provider.move(item, to: destination, replacingExisting: false)

    #expect(await session.realPathCalls().isEmpty)
    #expect(
      await session.moveOperations() == [
        .rename("./report.txt", "/Archive/report.txt")
      ])
  }

  @Test("SFTP移動は置換ありで既存の空フォルダを削除してから名称変更する")
  func moveWithReplacingRemovesExistingDirectoryThenRenames() async throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let session = ExistingFileSFTPClientSession(
      destinationPath: "/Archive",
      entries: [SFTPDirectoryEntry(name: "report.txt", isDirectory: true)])
    let provider = SFTPFileProvider(target: target, directoryListing: session)
    let item = FileItem(
      remotePath: "/Projects/report.txt",
      url: URL(filePath: "/Projects/report.txt"),
      providerID: provider.id,
      isDirectory: false)
    let destination = FileLocation(remotePath: "/Archive", providerID: provider.id)

    try await provider.move(item, to: destination, replacingExisting: true)

    #expect(
      await session.moveOperations() == [
        .remove("/Archive/report.txt", true),
        .rename("/Projects/report.txt", "/Archive/report.txt"),
      ])
  }

  @Test("SFTP移動は置換先フォルダを子から削除してから名称変更する")
  func moveWithReplacingRecursivelyRemovesDestinationDirectory() async throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let existingPath = "/Archive/report.txt"
    let session = ExistingFileSFTPClientSession(
      destinationPath: "/Archive",
      entries: [SFTPDirectoryEntry(name: "report.txt", isDirectory: true)],
      additionalEntries: [
        existingPath: [
          SFTPDirectoryEntry(name: "child.txt", isDirectory: false),
          SFTPDirectoryEntry(name: "Nested", isDirectory: true),
        ],
        "\(existingPath)/Nested": [SFTPDirectoryEntry(name: "leaf.txt", isDirectory: false)],
      ])
    let provider = SFTPFileProvider(target: target, directoryListing: session)
    let item = FileItem(
      remotePath: "/Projects/report.txt",
      url: URL(filePath: "/Projects/report.txt"),
      providerID: provider.id,
      isDirectory: false)

    try await provider.move(
      item,
      to: FileLocation(remotePath: "/Archive", providerID: provider.id),
      replacingExisting: true)

    #expect(
      await session.moveOperations() == [
        .remove("/Archive/report.txt/child.txt", false),
        .remove("/Archive/report.txt/Nested/leaf.txt", false),
        .remove("/Archive/report.txt/Nested", true),
        .remove("/Archive/report.txt", true),
        .rename("/Projects/report.txt", "/Archive/report.txt"),
      ])
  }

  @Test("SFTPの中身のあるフォルダはシンボリックリンクを辿らず子から削除する")
  func deleteRecursivelyWithoutFollowingSymbolicLinks() async throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let folderPath = "/Projects/Folder"
    let session = ExistingFileSFTPClientSession(
      destinationPath: folderPath,
      entries: [
        SFTPDirectoryEntry(name: ".", isDirectory: true),
        SFTPDirectoryEntry(name: "..", isDirectory: true),
        SFTPDirectoryEntry(name: "child.txt", isDirectory: false),
        SFTPDirectoryEntry(name: "Nested", isDirectory: true),
        SFTPDirectoryEntry(name: "linked-folder", isDirectory: true, isSymbolicLink: true),
      ],
      additionalEntries: [
        "\(folderPath)/Nested": [SFTPDirectoryEntry(name: "leaf.txt", isDirectory: false)],
        "\(folderPath)/linked-folder": [
          SFTPDirectoryEntry(name: "outside.txt", isDirectory: false)
        ],
      ])
    let provider = SFTPFileProvider(target: target, directoryListing: session)
    let folder = FileItem(
      remotePath: folderPath,
      url: URL(filePath: folderPath),
      providerID: provider.id,
      isDirectory: true)

    try await (provider as any FileBrowserPermanentDeleteProvider).permanentlyDelete(folder)

    #expect(
      await session.moveOperations() == [
        .remove("/Projects/Folder/child.txt", false),
        .remove("/Projects/Folder/Nested/leaf.txt", false),
        .remove("/Projects/Folder/Nested", true),
        .remove("/Projects/Folder/linked-folder", false),
        .remove("/Projects/Folder", true),
      ])
  }

  @Test("SFTP再帰削除は不正な列挙名があれば削除開始前に拒否する")
  func recursiveDeleteRejectsInvalidEntryBeforeRemovingAnything() async throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let folderPath = "/Projects/Folder"
    let session = ExistingFileSFTPClientSession(
      destinationPath: folderPath,
      entries: [
        SFTPDirectoryEntry(name: "valid.txt", isDirectory: false),
        SFTPDirectoryEntry(name: "../outside.txt", isDirectory: false),
      ])
    let provider = SFTPFileProvider(target: target, directoryListing: session)
    let folder = FileItem(
      remotePath: folderPath,
      url: URL(filePath: folderPath),
      providerID: provider.id,
      isDirectory: true)

    await #expect(throws: SFTPFileProviderError.invalidLocation) {
      try await (provider as any FileBrowserPermanentDeleteProvider).permanentlyDelete(folder)
    }

    #expect(await session.moveOperations().isEmpty)
  }

  @Test("SFTP再帰削除は接続ルート自身を拒否する")
  func recursiveDeleteRejectsConnectionRoot() async throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let session = ExistingFileSFTPClientSession(destinationPath: "/", entries: [])
    let provider = SFTPFileProvider(target: target, directoryListing: session)
    let root = FileItem(
      remotePath: "/",
      url: URL(filePath: "/"),
      providerID: provider.id,
      isDirectory: true)

    await #expect(throws: SFTPFileProviderError.invalidLocation) {
      try await (provider as any FileBrowserPermanentDeleteProvider).permanentlyDelete(root)
    }

    #expect(await session.moveOperations().isEmpty)
  }

  @Test("SFTP上書き移動は移動元を含む祖先宛先を削除前に拒否する", arguments: [false, true])
  func replacingMoveRejectsDestinationContainingSource(alias: Bool) async throws {
    let source = alias ? "./source/A" : "/root/A/B/A"
    let directory = alias ? "/alias" : "/root"
    let paths = alias ? [source: "/root/A/B/A", directory: "/root"] : [:]
    let session = ExistingFileSFTPClientSession(
      destinationPath: directory,
      entries: [SFTPDirectoryEntry(name: "A", isDirectory: true)],
      realPaths: paths)
    let target = try SFTPConnectionTarget(host: "fixture.invalid", port: 22, username: "fixture")
    let provider = SFTPFileProvider(target: target, directoryListing: session)
    let item = FileItem(
      remotePath: source, url: URL(filePath: source), providerID: provider.id, isDirectory: true)
    await #expect(throws: SFTPFileProviderError.invalidLocation) {
      try await provider.move(
        item, to: FileLocation(remotePath: directory, providerID: provider.id),
        replacingExisting: true)
    }
    #expect(await session.moveOperations().isEmpty)
    #expect(
      try await session.contents(of: directory) == [
        SFTPDirectoryEntry(name: "A", isDirectory: true)
      ])
  }

  @Test(
    "SFTP上書きコピーは自己・祖先・子孫への破壊を操作前に拒否する",
    arguments: [0, 1, 2, 3, 4])
  func replacingCopyRejectsDestructiveDestination(scenario: Int) async throws {
    let source: String
    let directory: String
    let isDirectory: Bool
    let paths: [String: String]
    switch scenario {
    case 0:
      (source, directory, isDirectory, paths) = ("/root/report.txt", "/root", false, [:])
    case 1:
      (source, directory, isDirectory, paths) = ("/root/A/B/A", "/root", true, [:])
    case 2:
      (source, directory, isDirectory, paths) = ("/root/A", "/root/A/Sub", true, [:])
    case 3:
      (source, directory, isDirectory, paths) = (
        "/src/report.txt", "/alias", false,
        ["/src/report.txt": "/real/report.txt", "/alias": "/real"]
      )
    default:
      (source, directory, isDirectory, paths) = (
        "/real/source.txt", "/alias", false,
        ["/alias": "/different", "/alias/source.txt": "/real/source.txt"]
      )
    }
    let name = (source as NSString).lastPathComponent
    let existing = SFTPDirectoryEntry(
      name: name, isDirectory: isDirectory, isSymbolicLink: scenario == 4)
    let session = ExistingFileSFTPClientSession(
      destinationPath: directory, entries: [existing], realPaths: paths)
    let target = try SFTPConnectionTarget(host: "fixture.invalid", port: 22, username: "fixture")
    let provider = SFTPFileProvider(target: target, directoryListing: session)
    let item = FileItem(
      remotePath: source, url: URL(filePath: source), providerID: provider.id,
      isDirectory: isDirectory)
    await #expect(throws: SFTPFileProviderError.invalidLocation) {
      try await provider.copy(
        item, to: FileLocation(remotePath: directory, providerID: provider.id),
        replacingExisting: true)
    }
    #expect(await session.moveOperations().isEmpty)
    #expect(await session.copyCalls().isEmpty)
    #expect(try await session.contents(of: directory) == [existing])
  }

  @Test(
    "SFTP上書きコピーは実体確認に失敗すると削除・truncateへ進まない",
    arguments: [false, true])
  func replacingCopyPreservesDestinationWhenRealPathFails(isDirectory: Bool) async throws {
    let session = ExistingFileSFTPClientSession(
      destinationPath: "/Archive",
      entries: [SFTPDirectoryEntry(name: "A", isDirectory: isDirectory)],
      failsRealPath: true)
    let target = try SFTPConnectionTarget(host: "fixture.invalid", port: 22, username: "fixture")
    let provider = SFTPFileProvider(target: target, directoryListing: session)
    let item = FileItem(
      remotePath: "/Projects/A", url: URL(filePath: "/Projects/A"), providerID: provider.id,
      isDirectory: isDirectory)
    await #expect(throws: (any Error).self) {
      try await provider.copy(
        item, to: FileLocation(remotePath: "/Archive", providerID: provider.id),
        replacingExisting: true)
    }
    #expect(await session.moveOperations().isEmpty)
    #expect(await session.copyCalls().isEmpty)
    #expect(
      try await session.contents(of: "/Archive") == [
        SFTPDirectoryEntry(name: "A", isDirectory: isDirectory)
      ])
  }

  @Test("SFTP移動は置換なしで既存の宛先を拒否する")
  func moveWithoutReplacingRejectsExistingDestination() async throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let session = ExistingFileSFTPClientSession(
      destinationPath: "/Archive",
      entries: [SFTPDirectoryEntry(name: "report.txt", isDirectory: false)])
    let provider = SFTPFileProvider(target: target, directoryListing: session)
    let item = FileItem(
      remotePath: "/Projects/report.txt",
      url: URL(filePath: "/Projects/report.txt"),
      providerID: provider.id,
      isDirectory: false)
    let destination = FileLocation(remotePath: "/Archive", providerID: provider.id)
    var thrownError: (any Error)?

    do {
      try await provider.move(item, to: destination, replacingExisting: false)
    } catch {
      thrownError = error
    }

    #expect((thrownError as? CocoaError)?.code == .fileWriteFileExists)
    #expect(
      await session.moveOperations() == [
        .rename("/Projects/report.txt", "/Archive/report.txt")
      ])
    #expect(
      try await session.contents(of: "/Archive") == [
        SFTPDirectoryEntry(name: "report.txt", isDirectory: false)
      ])
  }

  @Test("SFTP移動は置換なしで宛先が無ければ名称変更する")
  func moveWithoutReplacingProceedsWhenDestinationIsAbsent() async throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let session = ExistingFileSFTPClientSession(destinationPath: "/Archive", entries: [])
    let provider = SFTPFileProvider(target: target, directoryListing: session)
    let item = FileItem(
      remotePath: "/Projects/report.txt",
      url: URL(filePath: "/Projects/report.txt"),
      providerID: provider.id,
      isDirectory: false)
    let destination = FileLocation(remotePath: "/Archive", providerID: provider.id)

    try await provider.move(item, to: destination, replacingExisting: false)

    #expect(
      await session.moveOperations() == [
        .rename("/Projects/report.txt", "/Archive/report.txt")
      ])
  }

  @Test("SFTPのコピー先は共通のFileLocationで指定できる")
  func copiesToProviderLocation() async throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let session = RecordingSFTPClientSession(
      entriesAt: "/Projects",
      entries: [SFTPDirectoryEntry(name: "report.txt", isDirectory: false)])
    let provider = SFTPFileProvider(target: target, directoryListing: session)
    let item = try #require(try await provider.contents(of: "/Projects").first)

    try await provider.copy(
      item,
      to: FileLocation(remotePath: "/Archive", providerID: provider.id))

    #expect(await session.operations() == [.copy("/Projects/report.txt", "/Archive/report.txt")])
  }

  @Test("SFTPコピーは置換なしで既存の宛先を拒否する")
  func copyWithoutReplacingRejectsExistingDestination() async throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let session = ExistingFileSFTPClientSession(
      destinationPath: "/Archive",
      entries: [SFTPDirectoryEntry(name: "report.txt", isDirectory: false)])
    let provider = SFTPFileProvider(target: target, directoryListing: session)
    let item = FileItem(
      remotePath: "/Projects/report.txt",
      url: URL(filePath: "/Projects/report.txt"),
      providerID: provider.id,
      isDirectory: false)
    let destination = FileLocation(remotePath: "/Archive", providerID: provider.id)
    var thrownError: (any Error)?

    do {
      try await provider.copy(item, to: destination, replacingExisting: false)
    } catch {
      thrownError = error
    }

    #expect((thrownError as? CocoaError)?.code == .fileWriteFileExists)
    #expect(await session.copyCalls().isEmpty)
  }

  @Test("SFTPコピーは置換ありで既存の宛先を上書きする")
  func copyWithReplacingOverwritesExistingDestination() async throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let session = ExistingFileSFTPClientSession(
      destinationPath: "/Archive",
      entries: [SFTPDirectoryEntry(name: "report.txt", isDirectory: false)])
    let provider = SFTPFileProvider(target: target, directoryListing: session)
    let item = FileItem(
      remotePath: "/Projects/report.txt",
      url: URL(filePath: "/Projects/report.txt"),
      providerID: provider.id,
      isDirectory: false)
    let destination = FileLocation(remotePath: "/Archive", providerID: provider.id)

    try await provider.copy(item, to: destination, replacingExisting: true)

    let calls = await session.copyCalls()
    #expect(calls.count == 1)
    let call = try #require(calls.first)
    #expect(call.source == "/Projects/report.txt")
    #expect(call.destination == "/Archive/report.txt")
    #expect(call.replacingExisting)
  }

  @Test("SFTPコピーは置換なしで宛先が無ければ実行する")
  func copyWithoutReplacingProceedsWhenDestinationIsAbsent() async throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let session = ExistingFileSFTPClientSession(destinationPath: "/Archive", entries: [])
    let provider = SFTPFileProvider(target: target, directoryListing: session)
    let item = FileItem(
      remotePath: "/Projects/report.txt",
      url: URL(filePath: "/Projects/report.txt"),
      providerID: provider.id,
      isDirectory: false)
    let destination = FileLocation(remotePath: "/Archive", providerID: provider.id)

    try await provider.copy(item, to: destination, replacingExisting: false)

    let calls = await session.copyCalls()
    #expect(calls.count == 1)
    let call = try #require(calls.first)
    #expect(call.source == "/Projects/report.txt")
    #expect(call.destination == "/Archive/report.txt")
    #expect(!call.replacingExisting)
  }

  @Test("SFTPは同一接続内でフォルダを再帰コピーする")
  func copiesDirectoryRecursivelyWithinConnection() async throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let sourcePath = "/Projects/Folder"
    let session = ExistingFileSFTPClientSession(
      destinationPath: "/Archive",
      entries: [],
      additionalEntries: [
        sourcePath: [
          SFTPDirectoryEntry(name: "child.txt", isDirectory: false),
          SFTPDirectoryEntry(name: "Nested", isDirectory: true),
          SFTPDirectoryEntry(name: "linked-folder", isDirectory: true, isSymbolicLink: true),
        ],
        "\(sourcePath)/Nested": [SFTPDirectoryEntry(name: "leaf.txt", isDirectory: false)],
      ])
    let provider = SFTPFileProvider(target: target, directoryListing: session)
    let folder = FileItem(
      remotePath: sourcePath,
      url: URL(filePath: sourcePath),
      providerID: provider.id,
      isDirectory: true)

    try await provider.copy(
      folder,
      to: FileLocation(remotePath: "/Archive", providerID: provider.id),
      replacingExisting: false)

    #expect(
      await session.moveOperations() == [
        .createDirectory("/Archive/Folder"),
        .createDirectory("/Archive/Folder/Nested"),
      ])
    #expect(
      await session.copyCalls() == [
        .init(
          source: "/Projects/Folder/child.txt", destination: "/Archive/Folder/child.txt",
          replacingExisting: false),
        .init(
          source: "/Projects/Folder/Nested/leaf.txt",
          destination: "/Archive/Folder/Nested/leaf.txt",
          replacingExisting: false),
        .init(
          source: "/Projects/Folder/linked-folder",
          destination: "/Archive/Folder/linked-folder",
          replacingExisting: false),
      ])
  }

  @Test("SFTPはファイルをローカルと同じ連番名で複製する")
  func duplicatesFileWithAvailableCopyName() async throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let session = ExistingFileSFTPClientSession(
      destinationPath: "/Projects",
      entries: [
        SFTPDirectoryEntry(name: "report.txt", isDirectory: false),
        SFTPDirectoryEntry(name: "reportのコピー.txt", isDirectory: false),
      ])
    let provider = SFTPFileProvider(target: target, directoryListing: session)
    let item = FileItem(
      remotePath: "/Projects/report.txt",
      url: URL(filePath: "/Projects/report.txt"),
      providerID: provider.id,
      isDirectory: false)

    try await (provider as any FileBrowserDuplicateProvider).duplicate(item)

    #expect(
      await session.copyCalls() == [
        .init(
          source: "/Projects/report.txt", destination: "/Projects/reportのコピー2.txt",
          replacingExisting: false)
      ])
  }

  @Test("SFTPはフォルダを同一フォルダ内へ再帰的に複製する")
  func duplicatesDirectoryRecursively() async throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let sourcePath = "/Projects/Folder"
    let session = ExistingFileSFTPClientSession(
      destinationPath: "/Projects",
      entries: [SFTPDirectoryEntry(name: "Folder", isDirectory: true)],
      additionalEntries: [
        sourcePath: [SFTPDirectoryEntry(name: "child.txt", isDirectory: false)]
      ])
    let provider = SFTPFileProvider(target: target, directoryListing: session)
    let folder = FileItem(
      remotePath: sourcePath,
      url: URL(filePath: sourcePath),
      providerID: provider.id,
      isDirectory: true)

    try await (provider as any FileBrowserDuplicateProvider).duplicate(folder)

    #expect(
      await session.moveOperations() == [
        .createDirectory("/Projects/Folderのコピー")
      ])
    #expect(
      await session.copyCalls() == [
        .init(
          source: "/Projects/Folder/child.txt",
          destination: "/Projects/Folderのコピー/child.txt",
          replacingExisting: false)
      ])
  }

  @Test("SFTPフォルダコピーは移動元配下へのコピーを拒否する")
  func directoryCopyRejectsDestinationInsideSource() async throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let sourcePath = "/Projects/Folder"
    let session = ExistingFileSFTPClientSession(
      destinationPath: "/Projects/Folder/Nested",
      entries: [])
    let provider = SFTPFileProvider(target: target, directoryListing: session)
    let folder = FileItem(
      remotePath: sourcePath,
      url: URL(filePath: sourcePath),
      providerID: provider.id,
      isDirectory: true)

    await #expect(throws: SFTPFileProviderError.invalidLocation) {
      try await provider.copy(
        folder,
        to: FileLocation(
          remotePath: "/Projects/Folder/Nested",
          providerID: provider.id),
        replacingExisting: false)
    }

    #expect(await session.moveOperations().isEmpty)
    #expect(await session.copyCalls().isEmpty)
  }

  @Test("SFTPフォルダコピーは不正な列挙名があれば作成開始前に拒否する")
  func directoryCopyRejectsInvalidEntryBeforeCreatingAnything() async throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let sourcePath = "/Projects/Folder"
    let session = ExistingFileSFTPClientSession(
      destinationPath: "/Archive",
      entries: [],
      additionalEntries: [
        sourcePath: [SFTPDirectoryEntry(name: "../outside.txt", isDirectory: false)]
      ])
    let provider = SFTPFileProvider(target: target, directoryListing: session)
    let folder = FileItem(
      remotePath: sourcePath,
      url: URL(filePath: sourcePath),
      providerID: provider.id,
      isDirectory: true)

    await #expect(throws: SFTPFileProviderError.invalidLocation) {
      try await provider.copy(
        folder,
        to: FileLocation(remotePath: "/Archive", providerID: provider.id),
        replacingExisting: false)
    }

    #expect(await session.moveOperations().isEmpty)
    #expect(await session.copyCalls().isEmpty)
  }

  @Test("SFTPコピーは置換なしの宛先列挙失敗時も実行を試みる")
  func copyWithoutReplacingProceedsWhenDestinationListingFails() async throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let session = DestinationListingFailingSFTPClientSession()
    let provider = SFTPFileProvider(target: target, directoryListing: session)
    let item = FileItem(
      remotePath: "/Projects/report.txt",
      url: URL(filePath: "/Projects/report.txt"),
      providerID: provider.id,
      isDirectory: false)
    let destination = FileLocation(remotePath: "/Archive", providerID: provider.id)

    try await provider.copy(item, to: destination, replacingExisting: false)

    let calls = await session.copyCalls()
    #expect(calls.count == 1)
    let call = try #require(calls.first)
    #expect(call.source == "/Projects/report.txt")
    #expect(call.destination == "/Archive/report.txt")
    #expect(!call.replacingExisting)
  }

  @Test("切断済みSFTPセッションの操作は一度だけ再接続して再試行する")
  func reconnectsOnceForInactiveSession() async throws {
    let disconnected = ReconnectableSFTPClientSession(
      isActive: false,
      contentsError: .connectionLost)
    let reconnected = ReconnectableSFTPClientSession(
      entries: [SFTPDirectoryEntry(name: "report.txt", isDirectory: false)])
    let factory = ReconnectingSessionFactory(session: reconnected)
    let session = SFTPReconnectingSession(
      session: disconnected,
      sleep: { _ in },
      reconnect: { await factory.makeSession() })

    let entries = try await session.contents(of: "/")

    #expect(entries.map(\.name) == ["report.txt"])
    #expect(await factory.connectionCount() == 1)
    #expect(await disconnected.closeCount() == 1)
  }

  @Test("接続が生きているSFTPエラーでは再接続しない")
  func doesNotReconnectForActiveSessionError() async throws {
    let active = ReconnectableSFTPClientSession(contentsError: .permissionDenied)
    let factory = ReconnectingSessionFactory(session: ReconnectableSFTPClientSession())
    let session = SFTPReconnectingSession(session: active) {
      await factory.makeSession()
    }

    await #expect(throws: ReconnectableSFTPError.permissionDenied) {
      try await session.contents(of: "/")
    }

    #expect(await factory.connectionCount() == 0)
  }

  @Test("再接続の上限に達したSFTPセッションは再試行しない")
  func doesNotReconnectMoreThanOnce() async throws {
    let first = ReconnectableSFTPClientSession(isActive: false, contentsError: .connectionLost)
    let second = ReconnectableSFTPClientSession(isActive: false, contentsError: .connectionLost)
    let factory = ReconnectingSessionFactory(session: second)
    let session = SFTPReconnectingSession(
      session: first,
      maximumReconnects: 1,
      sleep: { _ in },
      reconnect: { await factory.makeSession() })

    await #expect(throws: ReconnectableSFTPError.connectionLost) {
      try await session.contents(of: "/")
    }

    #expect(await factory.connectionCount() == 1)
  }

  @Test("ストールガードが変換したキャンセル/ストールエラーでは再接続しない")
  func doesNotReconnectForStallGuardErrors() async throws {
    let cancelled = ReconnectableSFTPClientSession(
      isActive: false,
      genericContentsError: CancellationError())
    let cancelledFactory = ReconnectingSessionFactory(session: ReconnectableSFTPClientSession())
    let cancelledSession = SFTPReconnectingSession(session: cancelled) {
      await cancelledFactory.makeSession()
    }
    await #expect(throws: CancellationError.self) {
      try await cancelledSession.contents(of: "/")
    }
    #expect(await cancelledFactory.connectionCount() == 0)

    let stalled = ReconnectableSFTPClientSession(
      isActive: false,
      genericContentsError: SFTPTransferStallError())
    let stalledFactory = ReconnectingSessionFactory(session: ReconnectableSFTPClientSession())
    let stalledSession = SFTPReconnectingSession(session: stalled) {
      await stalledFactory.makeSession()
    }
    await #expect(throws: SFTPTransferStallError.self) {
      try await stalledSession.contents(of: "/")
    }
    #expect(await stalledFactory.connectionCount() == 0)
  }

  @Test("複数回の再接続はバックオフを挟みながら試行し、途中で成功すればそこで止まる")
  func retriesWithBackoffUntilSuccess() async throws {
    let initial = ReconnectableSFTPClientSession(isActive: false, contentsError: .connectionLost)
    let flaky = FlakySFTPClientSession(failuresBeforeSuccess: 2)
    let recorder = SleepDurationRecorder()
    let session = SFTPReconnectingSession(
      session: initial,
      sleep: { duration in await recorder.record(duration) },
      reconnect: { flaky })

    let entries = try await session.contents(of: "/")

    #expect(entries.map(\.name) == ["report.txt"])
    #expect(await flaky.callCount() == 3)
    #expect(await recorder.recorded() == [.seconds(1), .seconds(2), .seconds(4)])
  }

  @Test("既定の上限(3回)を使い切ったら諦めて元のエラーを伝える")
  func exhaustsDefaultMaximumReconnectsAndGivesUp() async throws {
    let initial = ReconnectableSFTPClientSession(isActive: false, contentsError: .connectionLost)
    let alwaysFailing = FlakySFTPClientSession(failuresBeforeSuccess: .max)
    let session = SFTPReconnectingSession(
      session: initial,
      sleep: { _ in },
      reconnect: { alwaysFailing })

    await #expect(throws: ReconnectableSFTPError.connectionLost) {
      try await session.contents(of: "/")
    }

    #expect(await alwaysFailing.callCount() == 3)
  }

  @Test("同一操作中の長時間失敗では再接続枠を復元しない")
  func doesNotRecoverReconnectBudgetDuringSameOperation() async throws {
    let clock = TestClock()
    let alwaysFailing = ConfigurableSlowFailingSFTPClientSession(clock: clock)
    let reconnectCallCount = Mutex<Int>(0)
    let maximumReconnects = 3
    let session = SFTPReconnectingSession(
      session: alwaysFailing,
      maximumReconnects: maximumReconnects,
      reconnectBudgetRecoveryInterval: .seconds(60),
      now: { clock.now() },
      sleep: { _ in },
      reconnect: {
        let count = reconnectCallCount.withLock { value -> Int in
          value += 1
          return value
        }
        guard count <= maximumReconnects else {
          throw SFTPConnectionServiceError.passwordNotFound
        }
        return alwaysFailing
      })

    await #expect(throws: ReconnectableSFTPError.connectionLost) {
      try await session.contents(of: "/")
    }

    #expect(reconnectCallCount.withLock { $0 } == maximumReconnects)
    #expect(await alwaysFailing.callCount() == maximumReconnects + 1)
  }

  @Test("枠切れで諦めた時刻から復元間隔が経過するまでは次の操作でも復元しない")
  func anchorsBudgetRecoveryToGiveUpTime() async throws {
    let clock = TestClock()
    let failing = ConfigurableSlowFailingSFTPClientSession(clock: clock)
    let reconnectCallCount = Mutex<Int>(0)
    let session = SFTPReconnectingSession(
      session: failing,
      maximumReconnects: 3,
      reconnectBudgetRecoveryInterval: .seconds(60),
      now: { clock.now() },
      sleep: { _ in },
      reconnect: {
        reconnectCallCount.withLock { $0 += 1 }
        return failing
      })

    // 1試行が61秒かかり続ける無応答サーバーで枠を使い切る。最終消費の記録が試行開始
    // 時点のままだと、諦めた瞬間には既に「最終消費から60秒超」が成立してしまう。
    await #expect(throws: ReconnectableSFTPError.connectionLost) {
      try await session.contents(of: "/")
    }
    #expect(reconnectCallCount.withLock { $0 } == 3)

    // 諦めた直後に即時失敗へ切り替える。復元窓が「諦めた時刻」起点なら経過0秒なので
    // 復元されず、再接続回数は増えない。
    await failing.setAdvancesClock(false)
    await #expect(throws: ReconnectableSFTPError.connectionLost) {
      try await session.contents(of: "/")
    }
    #expect(reconnectCallCount.withLock { $0 } == 3)

    // 30秒後の即時失敗呼び出しでも復元されず、かつ復元窓の起点も動かないこと。
    // 枠を消費していない呼び出しが起点を更新してしまう実装だと、即時失敗の繰り返しで
    // 復元窓が永遠に先送りされ、この後の60秒経過時点の復元が発火しなくなる。
    clock.advance(by: .seconds(30))
    await #expect(throws: ReconnectableSFTPError.connectionLost) {
      try await session.contents(of: "/")
    }
    #expect(reconnectCallCount.withLock { $0 } == 3)

    // 諦めた時刻から復元間隔(60秒)が経過すれば復元される(既存の時間ベース復元は維持)。
    clock.advance(by: .seconds(30))
    await #expect(throws: ReconnectableSFTPError.connectionLost) {
      try await session.contents(of: "/")
    }
    #expect(reconnectCallCount.withLock { $0 } == 6)
  }

  @Test("再接続後に成功すると試行回数がリセットされ、長時間セッションでも次の切断で再接続できる")
  func resetsRemainingReconnectsAfterSuccess() async throws {
    let initial = ReconnectableSFTPClientSession(isActive: false, contentsError: .connectionLost)
    let firstRecoverySession = StatefulSFTPClientSession()
    let secondRecoverySession = ReconnectableSFTPClientSession(
      entries: [SFTPDirectoryEntry(name: "second.txt", isDirectory: false)])
    let reconnectCallCount = Mutex<Int>(0)
    // maximumReconnects: 1で「1回消費したら以後は再接続不可」を明確にし、2回目の切断でも
    // 再接続できることをもってリセットされたと証明する。
    let session = SFTPReconnectingSession(
      session: initial,
      maximumReconnects: 1,
      sleep: { _ in },
      reconnect: {
        let count = reconnectCallCount.withLock { value -> Int in
          value += 1
          return value
        }
        return count == 1 ? firstRecoverySession : secondRecoverySession
      })

    let first = try await session.contents(of: "/")
    #expect(first.map(\.name) == ["first.txt"])

    // firstRecoverySessionは1回目の呼び出しでは成功、2回目の呼び出しでは失敗するよう
    // 作ってある(isActive()もその時点でfalseへ切り替わる)ため、ここで2回目の「切断」が
    // 起きる。リセットされていなければremainingReconnectsは0のまま(消費済み)で
    // 即座にエラーが伝播するはずだが、リセットされていれば再接続してsecondRecoverySessionの
    // 結果が返るはず。
    let second = try await session.contents(of: "/")
    #expect(second.map(\.name) == ["second.txt"])
    #expect(reconnectCallCount.withLock { $0 } == 2)
  }

  @Test("再接続後のセッションが生きていて直接操作が成功すれば試行回数がリセットされ、次の切断で再接続が再び効く")
  func resetsRemainingReconnectsOnNormalSuccessAfterExhaustion() async throws {
    // 注意: これはperform()の通常成功経路のリセット(生きたセッションで枠だけ消費
    // されたケースを救う)の検証。枠を使い果たした時点のセッション自体が死んでいて
    // 以後operation(session)が永久に失敗し続ける「ラッチ」問題は、この経路には
    // 到達できないため別のテスト(recoversReconnectBudgetAfterTimeElapsesEvenWith
    // DeadSession)で時間ベース復元により検証する。
    let initial = ReconnectableSFTPClientSession(isActive: false, contentsError: .connectionLost)
    let recovering = RecoveringThenDisconnectingAgainSFTPClientSession()
    let healthy = ReconnectableSFTPClientSession(
      entries: [SFTPDirectoryEntry(name: "after-second-reconnect.txt", isDirectory: false)])
    let reconnectCallCount = Mutex<Int>(0)
    // maximumReconnects: 1で「1回消費したら以後は再接続不可」を明確にする。
    let session = SFTPReconnectingSession(
      session: initial,
      maximumReconnects: 1,
      sleep: { _ in },
      reconnect: {
        let count = reconnectCallCount.withLock { value -> Int in
          value += 1
          return value
        }
        return count == 1 ? recovering : healthy
      })

    // Step A(全回失敗): initialの失敗で再接続を1回消費するが、reconnect後のrecovering
    // への1回目の操作も失敗するため、上限を使い果たしてエラーが伝播する(exhausted)。
    await #expect(throws: ReconnectableSFTPError.connectionLost) {
      try await session.contents(of: "/")
    }
    #expect(await recovering.callCount() == 1)

    // Step B(回線復帰): recoveringは2回目の呼び出しで成功する。これはreconnect()を
    // 経由しない、perform()の通常成功経路(operation(session)がそのまま成功)である。
    // Fix Bはこの経路でもremainingReconnectsをmaximumへリセットする。
    let recovered = try await session.contents(of: "/")
    #expect(recovered.map(\.name) == ["recovered.txt"])

    // Step C(次の操作での再接続確認): recoveringは3回目の呼び出しで再び失敗する。
    // Fix BによりremainingReconnectsがリセットされていれば、ここで再接続を試み
    // healthyの結果が返る。リセットされていなければ(バグ再現時)remainingReconnects
    // は0のままexhausted扱いとなり、エラーが伝播してこの行で失敗する。
    let afterSecondDisconnect = try await session.contents(of: "/")
    #expect(afterSecondDisconnect.map(\.name) == ["after-second-reconnect.txt"])
    #expect(reconnectCallCount.withLock { $0 } == 2)
  }

  @Test("枠を使い果たした時点のセッションが死んだままでも、復元間隔経過後は時間ベースで枠が復元し再接続を試みる")
  func recoversReconnectBudgetAfterTimeElapsesEvenWithDeadSession() async throws {
    // 自動再接続(P1-3) Fix B再修正: 枠を使い果たした時点のsessionはreconnect()が
    // 返した(が結局失敗した)セッションのまま保持され続け、以後どの操作を試みても
    // 死んだセッションで永久に失敗する。perform()の通常成功経路のリセットには
    // 到達できないため、時間ベースの枠復元がここで効くことを証明する。
    let initial = ReconnectableSFTPClientSession(isActive: false, contentsError: .connectionLost)
    let dead = DeadSFTPClientSession()
    let recoveredSession = ReconnectableSFTPClientSession(
      entries: [SFTPDirectoryEntry(name: "recovered.txt", isDirectory: false)])
    let useRecovered = Mutex<Bool>(false)
    let clock = TestClock()
    let reconnectCallCount = Mutex<Int>(0)

    let session = SFTPReconnectingSession(
      session: initial,
      maximumReconnects: 1,
      reconnectBudgetRecoveryInterval: .seconds(60),
      now: { clock.now() },
      sleep: { _ in },
      reconnect: {
        reconnectCallCount.withLock { $0 += 1 }
        return useRecovered.withLock { $0 } ? recoveredSession : dead
      })

    // (1) 全操作が失敗しreconnectも(dead自身が)失敗するため枠を0にする(死んだ
    // セッションのラッチを実際に再現する)。
    await #expect(throws: ReconnectableSFTPError.connectionLost) {
      try await session.contents(of: "/")
    }
    #expect(await dead.callCount() == 1)

    // (4) 60秒未満では依然throwする(復元が早すぎない)。sessionは死んだままなので
    // 再接続を試みなければ必ず失敗し続ける。
    clock.advance(by: .seconds(59))
    await #expect(throws: ReconnectableSFTPError.connectionLost) {
      try await session.contents(of: "/")
    }
    #expect(reconnectCallCount.withLock { $0 } == 1)

    // (2) フェイクを回線復帰状態(reconnectが成功する)に切り替え、クロックを
    // 合計60秒(残り1秒)進める。
    useRecovered.withLock { $0 = true }
    clock.advance(by: .seconds(1))

    // (3) 次の操作でrecoverAndRetryが時間ベースで枠を復元して再接続を試み、成功する。
    let recovered = try await session.contents(of: "/")
    #expect(recovered.map(\.name) == ["recovered.txt"])
    #expect(reconnectCallCount.withLock { $0 } == 2)
  }

  @Test("資格情報エラー(ReconnectFutileError)は再接続を試みず即座に伝える")
  func doesNotRetryReconnectFutileErrors() async throws {
    let initial = ReconnectableSFTPClientSession(isActive: false, contentsError: .connectionLost)
    let reconnectCallCount = Mutex<Int>(0)
    let session = SFTPReconnectingSession(
      session: initial,
      sleep: { _ in },
      reconnect: {
        reconnectCallCount.withLock { $0 += 1 }
        throw SFTPConnectionServiceError.passwordNotFound
      })

    await #expect(throws: SFTPConnectionServiceError.self) {
      try await session.contents(of: "/")
    }

    // reconnect()自体が資格情報エラー(ReconnectFutileError)で失敗した時点で諦めるため、
    // 3回の上限まで再接続を試み続けたりしない。
    #expect(reconnectCallCount.withLock { $0 } == 1)
  }

  @Test("転送セッションのabortは閲覧セッションを巻き添えにせず、閲覧操作は継続できる")
  func abortDuringTransferDoesNotAffectBrowsingSession() async throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let transferSpy = SpySFTPClientSession()
    let browsingSpy = SpySFTPClientSession(
      entries: [SFTPDirectoryEntry(name: "report.txt", isDirectory: false)],
      transferSession: transferSpy)
    let provider = SFTPFileProvider(target: target, directoryListing: browsingSpy)

    let neverYieldingStream = AsyncThrowingStream<Data, Error> { _ in }
    let writeTask = Task {
      try await provider.writeFileChunks(
        neverYieldingStream,
        to: FileLocation(remotePath: "/dest/file.bin", providerID: provider.id),
        replacingExisting: true,
        progress: { _ in })
    }
    // writeFileContents内のキャンセル監視ループへ確実に到達させてからキャンセルする。
    await Task.yield()
    await Task.yield()
    writeTask.cancel()
    await #expect(throws: (any Error).self) {
      try await writeTask.value
    }

    #expect(transferSpy.abortCount == 1)
    #expect(browsingSpy.abortCount == 0)
    #expect(browsingSpy.closeCount == 0)

    let items = try await provider.contents(of: "/Projects")
    #expect(items.map(\.name) == ["report.txt"])
  }

  @Test("転送セッションの同時取得は接続を一度しか張らない")
  func transferSessionCoalescesConcurrentRequests() async throws {
    let browsing = ReconnectableSFTPClientSession()
    let factory = ReconnectingSessionFactory(session: ReconnectableSFTPClientSession())
    let session = SFTPReconnectingSession(session: browsing) {
      await factory.makeSession()
    }

    async let first = session.transferSession()
    async let second = session.transferSession()
    let (firstSession, secondSession) = try await (first, second)

    #expect(await factory.connectionCount() == 1)
    #expect(
      ObjectIdentifier(firstSession as AnyObject) == ObjectIdentifier(secondSession as AnyObject))
  }

  @Test("無効化された転送セッションは次回取得で新しい接続を張り直す")
  func transferSessionRecreatesAfterInvalidation() async throws {
    let browsing = ReconnectableSFTPClientSession()
    let factory = ReconnectingSessionFactory(session: ReconnectableSFTPClientSession())
    let session = SFTPReconnectingSession(session: browsing) {
      await factory.makeSession()
    }

    let first = try await session.transferSession()
    await session.invalidateTransferSession(first)
    let second = try await session.transferSession()

    #expect(await factory.connectionCount() == 2)
    #expect(ObjectIdentifier(first as AnyObject) != ObjectIdentifier(second as AnyObject))
  }

  @Test("同一性の異なるセッションからの無効化通知は現在のキャッシュへ影響しない")
  func invalidateTransferSessionIgnoresStaleIdentity() async throws {
    let browsing = ReconnectableSFTPClientSession()
    let factory = ReconnectingSessionFactory(session: ReconnectableSFTPClientSession())
    let session = SFTPReconnectingSession(session: browsing) {
      await factory.makeSession()
    }

    let stale = try await session.transferSession()
    await session.invalidateTransferSession(stale)
    let current = try await session.transferSession()

    // すでに無効化済み(=キャッシュから外れた)staleを再度invalidateしても、
    // 新しく取得したcurrentのキャッシュは破棄されない。
    await session.invalidateTransferSession(stale)
    let stillCurrent = try await session.transferSession()

    #expect(await factory.connectionCount() == 2)
    #expect(ObjectIdentifier(current as AnyObject) == ObjectIdentifier(stillCurrent as AnyObject))
  }

  @Test("閲覧セッションのcloseは取得済みの転送セッションもcloseする")
  func closingBrowsingSessionClosesTransferSession() async throws {
    let browsing = ReconnectableSFTPClientSession()
    let transferInner = ReconnectableSFTPClientSession()
    let factory = ReconnectingSessionFactory(session: transferInner)
    let session = SFTPReconnectingSession(session: browsing) {
      await factory.makeSession()
    }

    _ = try await session.transferSession()
    try await session.close()

    #expect(await browsing.closeCount() == 1)
    #expect(await transferInner.closeCount() == 1)
  }
}

/// fileSize(at:)を独自実装し、既定の列挙フォールバックを使わないことを検証するためのフェイク。
/// contents(of:)の呼び出し回数を数え、単一stat経路が本当に列挙を避けていることを証明する。
private actor SizeTrackingSFTPClientSession: SFTPClientSession {
  private let size: Int64?
  private var listingCalls = 0

  init(size: Int64?) {
    self.size = size
  }

  func contents(of _: String) async throws -> [SFTPDirectoryEntry] {
    listingCalls += 1
    return []
  }

  func createDirectory(at _: String) async throws {}

  func remove(at _: String, isDirectory _: Bool) async throws {}

  func rename(at _: String, to _: String) async throws {}

  func close() async throws {}

  func fileSize(at _: String) async throws -> Int64? {
    size
  }

  func listingCallCount() -> Int { listingCalls }
}

private struct StubSFTPDirectoryListing: SFTPClientSession {
  let entries: [SFTPDirectoryEntry]

  func contents(of remotePath: String) async throws -> [SFTPDirectoryEntry] {
    entries
  }

  func createDirectory(at _: String) async throws {}

  func remove(at _: String, isDirectory _: Bool) async throws {}

  func rename(at _: String, to _: String) async throws {}

  func close() async throws {}
}

private actor RecordingSFTPClientSession: SFTPClientSession {
  enum Operation: Equatable {
    case createDirectory(String)
    case remove(String, Bool)
    case rename(String, String)
    case copy(String, String)
    case setPosixPermissions(String, Int)
  }

  private let entriesByPath: [String: [SFTPDirectoryEntry]]
  private var recordedOperations: [Operation] = []

  init(entriesAt remotePath: String, entries: [SFTPDirectoryEntry]) {
    entriesByPath = [remotePath: entries]
  }

  func contents(of remotePath: String) async throws -> [SFTPDirectoryEntry] {
    entriesByPath[remotePath] ?? []
  }

  func createDirectory(at remotePath: String) async throws {
    recordedOperations.append(.createDirectory(remotePath))
  }

  func remove(at remotePath: String, isDirectory: Bool) async throws {
    recordedOperations.append(.remove(remotePath, isDirectory))
  }

  func rename(at remotePath: String, to destinationPath: String) async throws {
    recordedOperations.append(.rename(remotePath, destinationPath))
  }

  func copy(
    at remotePath: String,
    to destinationPath: String,
    replacingExisting _: Bool
  ) async throws {
    recordedOperations.append(.copy(remotePath, destinationPath))
  }

  func setPosixPermissions(_ permissions: Int, at remotePath: String) async throws {
    recordedOperations.append(.setPosixPermissions(remotePath, permissions))
  }

  func isActive() async -> Bool { true }

  func close() async throws {}

  func operations() -> [Operation] {
    recordedOperations
  }
}

private actor ExistingFileSFTPClientSession: SFTPClientSession {
  private struct RealPathFailure: Error {}

  enum MoveOperation: Equatable {
    case createDirectory(String)
    case remove(String, Bool)
    case rename(String, String)
  }

  struct CopyCall: Equatable {
    let source: String
    let destination: String
    let replacingExisting: Bool
  }

  private let destinationPath: String
  private let entries: [SFTPDirectoryEntry]
  private let additionalEntries: [String: [SFTPDirectoryEntry]]
  private let realPaths: [String: String]
  private let failsRealPath: Bool
  private var recordedMoveOperations: [MoveOperation] = []
  private var recordedCopyCalls: [CopyCall] = []
  private var recordedRealPathCalls: [String] = []
  private var removedPaths: Set<String> = []

  init(
    destinationPath: String,
    entries: [SFTPDirectoryEntry],
    additionalEntries: [String: [SFTPDirectoryEntry]] = [:],
    realPaths: [String: String] = [:],
    failsRealPath: Bool = false
  ) {
    self.destinationPath = destinationPath
    self.entries = entries
    self.additionalEntries = additionalEntries
    self.realPaths = realPaths
    self.failsRealPath = failsRealPath
  }

  func realPath(of remotePath: String) async throws -> String {
    recordedRealPathCalls.append(remotePath)
    if failsRealPath {
      throw RealPathFailure()
    }
    return realPaths[remotePath] ?? remotePath
  }

  func contents(of remotePath: String) async throws -> [SFTPDirectoryEntry] {
    let listing = remotePath == destinationPath ? entries : additionalEntries[remotePath] ?? []
    return listing.filter { entry in
      let path = remotePath == "/" ? "/" + entry.name : remotePath + "/" + entry.name
      return !removedPaths.contains(path)
    }
  }

  func createDirectory(at remotePath: String) async throws {
    recordedMoveOperations.append(.createDirectory(remotePath))
  }

  func remove(at remotePath: String, isDirectory: Bool) async throws {
    recordedMoveOperations.append(.remove(remotePath, isDirectory))
    removedPaths.insert(remotePath)
  }

  func rename(at remotePath: String, to destinationPath: String) async throws {
    recordedMoveOperations.append(.rename(remotePath, destinationPath))
    let value = destinationPath as NSString
    let listing = try await contents(of: value.deletingLastPathComponent)
    if listing.contains(where: { $0.name == value.lastPathComponent }) {
      throw CocoaError(.fileWriteFileExists)
    }
  }

  func copy(
    at remotePath: String,
    to destinationPath: String,
    replacingExisting: Bool
  ) async throws {
    recordedCopyCalls.append(
      CopyCall(
        source: remotePath,
        destination: destinationPath,
        replacingExisting: replacingExisting))
  }

  func close() async throws {}

  func copyCalls() -> [CopyCall] {
    recordedCopyCalls
  }

  func moveOperations() -> [MoveOperation] {
    recordedMoveOperations
  }

  func realPathCalls() -> [String] {
    recordedRealPathCalls
  }
}

private actor NonRespondingRealPathSFTPClientSession: SFTPClientSession {
  func realPath(of _: String) async throws -> String {
    await withUnsafeContinuation { (_: UnsafeContinuation<String, Never>) in }
  }

  func contents(of _: String) async throws -> [SFTPDirectoryEntry] {
    []
  }

  func createDirectory(at _: String) async throws {}

  func remove(at _: String, isDirectory _: Bool) async throws {}

  func rename(at _: String, to _: String) async throws {}

  func close() async throws {}
}

private actor DestinationListingFailingSFTPClientSession: SFTPClientSession {
  struct CopyCall: Equatable {
    let source: String
    let destination: String
    let replacingExisting: Bool
  }

  private var recordedCopyCalls: [CopyCall] = []

  func contents(of _: String) async throws -> [SFTPDirectoryEntry] {
    throw CocoaError(.fileReadUnknown)
  }

  func createDirectory(at _: String) async throws {}

  func remove(at _: String, isDirectory _: Bool) async throws {}

  func rename(at _: String, to _: String) async throws {}

  func copy(
    at remotePath: String,
    to destinationPath: String,
    replacingExisting: Bool
  ) async throws {
    recordedCopyCalls.append(
      CopyCall(
        source: remotePath,
        destination: destinationPath,
        replacingExisting: replacingExisting))
  }

  func close() async throws {}

  func copyCalls() -> [CopyCall] {
    recordedCopyCalls
  }
}

private actor PreviewRecordingSFTPClientSession: SFTPClientSession {
  private let contentsData: Data
  private(set) var fileContentsCallCount = 0

  init(contents: Data) {
    contentsData = contents
  }

  func contents(of _: String) async throws -> [SFTPDirectoryEntry] { [] }

  func createDirectory(at _: String) async throws {}

  func remove(at _: String, isDirectory _: Bool) async throws {}

  func rename(at _: String, to _: String) async throws {}

  func fileContents(of _: String) async throws -> Data {
    fileContentsCallCount += 1
    return contentsData
  }

  func close() async throws {}
}

private struct SFTPPreviewFixture {
  let root: URL
  let legacyRoot: URL

  init() throws {
    let base = FileManager.default.temporaryDirectory.appending(
      path: "sftp-detail-preview-\(UUID().uuidString)",
      directoryHint: .isDirectory)
    root = base.appending(path: "RemotePreviews", directoryHint: .isDirectory)
    legacyRoot = base.appending(path: "LegacyPreviews", directoryHint: .isDirectory)
  }

  func makeProvider(session: any SFTPClientSession) throws -> SFTPFileProvider {
    let target = try SFTPConnectionTarget(
      host: "example.com",
      port: 22,
      username: "tester")
    return SFTPFileProvider(
      target: target,
      directoryListing: session,
      previewCache: RemotePreviewCache(rootURL: root, legacyRootURL: legacyRoot))
  }

  func makeItem(
    provider: SFTPFileProvider,
    size: Int64 = 7,
    modifiedAt: Date = Date(timeIntervalSince1970: 100)
  ) -> FileItem {
    FileItem(
      remotePath: "/report.png",
      url: URL(string: "sftp://tester@example.com/report.png")!,
      providerID: provider.id,
      isDirectory: false,
      size: size,
      modifiedAt: modifiedAt)
  }

  func remove() {
    try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
  }
}

private enum ReconnectableSFTPError: Error, Equatable {
  case connectionLost
  case permissionDenied
}

private actor ReconnectableSFTPClientSession: SFTPClientSession {
  private let entries: [SFTPDirectoryEntry]
  private let contentsError: ReconnectableSFTPError?
  private let genericContentsError: Error?
  private let active: Bool
  private var closedCount = 0

  init(
    entries: [SFTPDirectoryEntry] = [],
    isActive: Bool = true,
    contentsError: ReconnectableSFTPError? = nil,
    genericContentsError: Error? = nil
  ) {
    self.entries = entries
    active = isActive
    self.contentsError = contentsError
    self.genericContentsError = genericContentsError
  }

  func contents(of _: String) async throws -> [SFTPDirectoryEntry] {
    if let genericContentsError {
      throw genericContentsError
    }
    if let contentsError {
      throw contentsError
    }
    return entries
  }

  func createDirectory(at _: String) async throws {}

  func remove(at _: String, isDirectory _: Bool) async throws {}

  func rename(at _: String, to _: String) async throws {}

  func isActive() async -> Bool { active }

  func close() async throws {
    closedCount += 1
  }

  func closeCount() -> Int { closedCount }
}

/// 自動再接続(P1-3)のバックオフ・上限・成功後リセットを検証するためのフェイク。
/// 呼び出し回数を数え、failuresBeforeSuccess回だけ失敗した後は成功するよう振る舞う。
/// isActive()は常にfalse(切断済み)を装う。
private actor FlakySFTPClientSession: SFTPClientSession {
  private var remainingFailures: Int
  private var count = 0

  init(failuresBeforeSuccess: Int) {
    remainingFailures = failuresBeforeSuccess
  }

  func contents(of _: String) async throws -> [SFTPDirectoryEntry] {
    count += 1
    if remainingFailures > 0 {
      remainingFailures -= 1
      throw ReconnectableSFTPError.connectionLost
    }
    return [SFTPDirectoryEntry(name: "report.txt", isDirectory: false)]
  }

  func createDirectory(at _: String) async throws {}
  func remove(at _: String, isDirectory _: Bool) async throws {}
  func rename(at _: String, to _: String) async throws {}
  func isActive() async -> Bool { false }
  func close() async throws {}

  func callCount() -> Int { count }
}

/// 1試行が復元間隔を超えて失敗し続ける無応答サーバーを、実時間待ちなしで再現する
/// フェイク(既定)。setAdvancesClock(false)で「即時失敗」へ途中から切り替えられ、
/// 枠切れで諦めた直後の呼び出しが入口復元されないこと(復元窓=諦めた時刻起点)の
/// 検証にも使う。
private actor ConfigurableSlowFailingSFTPClientSession: SFTPClientSession {
  private let clock: TestClock
  private var advancesClock = true
  private var count = 0

  init(clock: TestClock) {
    self.clock = clock
  }

  func setAdvancesClock(_ advancesClock: Bool) {
    self.advancesClock = advancesClock
  }

  func contents(of _: String) async throws -> [SFTPDirectoryEntry] {
    count += 1
    if advancesClock {
      clock.advance(by: .seconds(61))
    }
    throw ReconnectableSFTPError.connectionLost
  }

  func createDirectory(at _: String) async throws {}
  func remove(at _: String, isDirectory _: Bool) async throws {}
  func rename(at _: String, to _: String) async throws {}
  func isActive() async -> Bool { false }
  func close() async throws {}

  func callCount() -> Int { count }
}

/// 1回目のcontents(of:)呼び出しは成功し、2回目以降は失敗してisActive()もfalseへ切り替わる
/// フェイク。「再接続後に成功したらremainingReconnectsがリセットされる」ことを、maximum
/// Reconnects: 1という厳しい上限のもとで2回目の切断からも回復できることで証明するために使う。
private actor StatefulSFTPClientSession: SFTPClientSession {
  private var callCount = 0
  private var currentlyActive = true

  func contents(of _: String) async throws -> [SFTPDirectoryEntry] {
    callCount += 1
    if callCount == 1 {
      return [SFTPDirectoryEntry(name: "first.txt", isDirectory: false)]
    }
    currentlyActive = false
    throw ReconnectableSFTPError.connectionLost
  }

  func createDirectory(at _: String) async throws {}
  func remove(at _: String, isDirectory _: Bool) async throws {}
  func rename(at _: String, to _: String) async throws {}
  func isActive() async -> Bool { currentlyActive }
  func close() async throws {}
}

/// Fix B(時間ベース復元)検証用: 常に失敗し、isActive()も常にfalseを返す「死んだ
/// セッション」のフェイク。reconnect()を経ても回復しないケースを再現するために使う。
private actor DeadSFTPClientSession: SFTPClientSession {
  private var count = 0

  func contents(of _: String) async throws -> [SFTPDirectoryEntry] {
    count += 1
    throw ReconnectableSFTPError.connectionLost
  }

  func createDirectory(at _: String) async throws {}
  func remove(at _: String, isDirectory _: Bool) async throws {}
  func rename(at _: String, to _: String) async throws {}
  func isActive() async -> Bool { false }
  func close() async throws {}

  func callCount() -> Int { count }
}

/// SFTPReconnectingSessionへ注入する、実時間を待たず手動で進められるテスト用クロック。
private final class TestClock: @unchecked Sendable {
  private let instant: Mutex<ContinuousClock.Instant>

  init() {
    instant = Mutex(ContinuousClock.now)
  }

  func advance(by duration: Duration) {
    instant.withLock { $0 = $0.advanced(by: duration) }
  }

  func now() -> ContinuousClock.Instant {
    instant.withLock { $0 }
  }
}

/// Fix B検証用: 1回目・3回目の呼び出しは失敗(isActive()もfalseへ切り替わる)、
/// 2回目の呼び出しだけ成功する(isActive()はtrueに戻る)フェイク。「使い果たした後の
/// 通常成功→次の切断で再接続が再び効く」という2段階の切断・回復を1つのセッション
/// オブジェクトで表現するために使う。
private actor RecoveringThenDisconnectingAgainSFTPClientSession: SFTPClientSession {
  private var count = 0
  private var currentlyActive = false

  func contents(of _: String) async throws -> [SFTPDirectoryEntry] {
    count += 1
    if count == 2 {
      currentlyActive = true
      return [SFTPDirectoryEntry(name: "recovered.txt", isDirectory: false)]
    }
    currentlyActive = false
    throw ReconnectableSFTPError.connectionLost
  }

  func createDirectory(at _: String) async throws {}
  func remove(at _: String, isDirectory _: Bool) async throws {}
  func rename(at _: String, to _: String) async throws {}
  func isActive() async -> Bool { currentlyActive }
  func close() async throws {}

  func callCount() -> Int { count }
}

/// バックオフのsleep呼び出しを実時間で待たずに記録するためのフェイク。
private actor SleepDurationRecorder {
  private var durations: [Duration] = []

  func record(_ duration: Duration) {
    durations.append(duration)
  }

  func recorded() -> [Duration] {
    durations
  }
}

/// 閲覧用・転送用を区別できるスパイフェイク。transferSession()で指定した別インスタンスを
/// 返すことで、SFTPFileProviderが転送系メソッドに専用セッションを使うことを検証できる。
/// abortActiveTransfers()の呼び出し回数と、それが自身/相手のどちらへ及んだかを追跡する。
private final class SpySFTPClientSession: SFTPClientSession, @unchecked Sendable {
  private let entries: [SFTPDirectoryEntry]
  private let transferSessionOverride: (any SFTPClientSession)?
  private let state = Mutex<(closeCount: Int, abortCount: Int)>((0, 0))

  init(
    entries: [SFTPDirectoryEntry] = [],
    transferSession: (any SFTPClientSession)? = nil
  ) {
    self.entries = entries
    transferSessionOverride = transferSession
  }

  func contents(of _: String) async throws -> [SFTPDirectoryEntry] { entries }

  func createDirectory(at _: String) async throws {}

  func remove(at _: String, isDirectory _: Bool) async throws {}

  func rename(at _: String, to _: String) async throws {}

  func close() async throws {
    state.withLock { $0.closeCount += 1 }
  }

  func transferSession() async throws -> any SFTPClientSession {
    transferSessionOverride ?? self
  }

  /// キャンセルされるまでチェックし続けるフェイクの書き込み。実際のCitadelSFTPClientSessionが
  /// SFTPStallGuard経由でキャンセル検知時に自身をabortActiveTransfers()するのと同じ振る舞いを
  /// 単純化して再現する。
  func writeFileContents(
    to _: String,
    chunks _: AsyncThrowingStream<Data, Error>,
    replacingExisting _: Bool,
    progress _: @escaping @Sendable (Int64) -> Void
  ) async throws {
    do {
      while true {
        try Task.checkCancellation()
        await Task.yield()
      }
    } catch {
      abortActiveTransfers()
      throw error
    }
  }

  func abortActiveTransfers() {
    state.withLock { $0.abortCount += 1 }
  }

  var closeCount: Int { state.withLock(\.closeCount) }
  var abortCount: Int { state.withLock(\.abortCount) }
}

private actor ReconnectingSessionFactory {
  private let session: any SFTPClientSession
  private var count = 0

  init(session: any SFTPClientSession) {
    self.session = session
  }

  func makeSession() -> any SFTPClientSession {
    count += 1
    return session
  }

  func connectionCount() -> Int { count }
}
