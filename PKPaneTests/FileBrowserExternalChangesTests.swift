import Foundation
import Testing

@testable import PKPane

@MainActor
struct FileBrowserExternalChangesTests {
  @Test("更新日時による列挙省略はAPFSだけに限定する")
  func skipsArmRevalidationOnlyForAPFS() {
    #expect(ColumnDirectoryDatePolicy.canSkipRevalidation(fileSystemType: "apfs"))
    for fileSystemType in ["msdos", "exfat", "hfs", "smbfs"] {
      #expect(!ColumnDirectoryDatePolicy.canSkipRevalidation(fileSystemType: fileSystemType))
    }
    #expect(!ColumnDirectoryDatePolicy.canSkipRevalidation(fileSystemType: nil))
  }

  @Test("カラムで開いたローカルフォルダへの外部作成を一覧へ反映する")
  func reflectsExternalCreationInSelectedColumn() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appending(path: "pkpane-column-watch-\(UUID().uuidString)", directoryHint: .isDirectory)
    let childURL = rootURL.appending(path: "child", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: childURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let provider = LocalFileProvider()
    let session = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(directoryURL: rootURL, providerID: provider.id),
      transferQueue: .isolatedForTesting())
    defer { session.invalidate() }

    session.load()
    let clock = ContinuousClock()
    let initialDeadline = clock.now.advanced(by: .seconds(2))
    while session.isLoading || !session.items.contains(where: { $0.name == "child" }),
      clock.now < initialDeadline
    {
      try await Task.sleep(for: .milliseconds(10))
    }
    let childItem = try #require(session.items.first(where: { $0.name == "child" }))

    session.beginColumnBrowsing()
    session.selectColumnItem(childItem, inColumnAt: 0)
    let childLocation = childItem.location
    let columnDeadline = clock.now.advanced(by: .seconds(2))
    while session.columnState.columns.first(where: { $0.location == childLocation })?.isLoading
      != false,
      clock.now < columnDeadline
    {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(session.currentLocation == childLocation)
    try #require(
      session.columnState.columns.first(where: { $0.location == childLocation })?.isLoading == false
    )

    // 非同期の監視武装を待ってから、表示中の子フォルダを外部ツール相当の方法で変更する。
    try await Task.sleep(for: .milliseconds(200))
    let createdURL = childURL.appending(path: "external.txt")
    try Data("外部作成".utf8).write(to: createdURL)

    let reflectionDeadline = clock.now.advanced(by: .seconds(2))
    while !session.items.contains(where: { $0.name == "external.txt" }),
      clock.now < reflectionDeadline
    {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(session.items.contains(where: { $0.name == "external.txt" }))
    #expect(
      session.columnState.columns.first(where: { $0.location == childLocation })?
        .items.contains(where: { $0.name == "external.txt" }) == true)
  }

  @Test("カラム表示中の外部作成・改名・削除を順に反映する")
  func reflectsExternalCreateRenameDelete() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appending(path: "pkpane-column-changes-\(UUID().uuidString)", directoryHint: .isDirectory)
    let childURL = rootURL.appending(path: "child", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: childURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let provider = LocalFileProvider()
    let session = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(directoryURL: rootURL, providerID: provider.id),
      transferQueue: .isolatedForTesting())
    defer { session.invalidate() }
    session.load()
    try await waitUntil { !session.isLoading && session.items.contains { $0.name == "child" } }
    let childItem = try #require(session.items.first { $0.name == "child" })
    session.beginColumnBrowsing()
    session.selectColumnItem(childItem, inColumnAt: 0)
    try await waitUntil {
      session.currentLocation == childItem.location
        && session.columnState.columns.first(where: { $0.location == childItem.location })?
          .isLoading == false
    }
    try await Task.sleep(for: .milliseconds(200))

    let firstURL = childURL.appending(path: "first.txt")
    let renamedURL = childURL.appending(path: "renamed.txt")
    try Data("追加".utf8).write(to: firstURL)
    try await waitForNames(["first.txt"], in: session, at: childItem.location)

    try FileManager.default.moveItem(at: firstURL, to: renamedURL)
    try await waitForNames(["renamed.txt"], in: session, at: childItem.location)

    try FileManager.default.removeItem(at: renamedURL)
    try await waitForNames([], in: session, at: childItem.location)
  }

  @Test("別カラムへ移動した後は古い場所の変更を混ぜず、キャッシュで戻った場所を監視する")
  func ignoresOldColumnEventsAndRearmsCachedColumn() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appending(path: "pkpane-column-switch-\(UUID().uuidString)", directoryHint: .isDirectory)
    let firstURL = rootURL.appending(path: "first", directoryHint: .isDirectory)
    let secondURL = rootURL.appending(path: "second", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: firstURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondURL, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let provider = LocalFileProvider()
    let session = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(directoryURL: rootURL, providerID: provider.id),
      transferQueue: .isolatedForTesting())
    defer { session.invalidate() }
    session.load()
    try await waitUntil { !session.isLoading && session.items.count == 2 }
    let firstItem = try #require(session.items.first { $0.name == "first" })
    let secondItem = try #require(session.items.first { $0.name == "second" })
    session.beginColumnBrowsing()
    session.selectColumnItem(firstItem, inColumnAt: 0)
    try await waitUntil {
      session.currentLocation == firstItem.location
        && session.columnState.columns.first(where: { $0.location == firstItem.location })?
          .isLoading == false
    }
    session.selectColumnItem(secondItem, inColumnAt: 0)
    try await waitUntil {
      session.currentLocation == secondItem.location
        && session.columnState.columns.first(where: { $0.location == secondItem.location })?
          .isLoading == false
    }
    try await Task.sleep(for: .milliseconds(200))

    try Data("旧場所".utf8).write(to: firstURL.appending(path: "old-place.txt"))
    // 旧監視のdebounceより長く待ち、遅延イベントが新しい場所へ混入しないことを確かめる。
    try await Task.sleep(for: .milliseconds(400))
    #expect(session.currentLocation == secondItem.location)
    #expect(session.items.isEmpty)
    #expect(columnNames(in: session, at: secondItem.location) == [])
    #expect(session.hasCachedDirectorySnapshot(at: firstItem.location))

    session.selectColumnItem(firstItem, inColumnAt: 0)
    try await waitForNames(["old-place.txt"], in: session, at: firstItem.location)
    try await Task.sleep(for: .milliseconds(200))
    try Data("再監視".utf8).write(to: firstURL.appending(path: "after-return.txt"))
    try await waitForNames(
      ["after-return.txt", "old-place.txt"], in: session, at: firstItem.location)
  }

  private func columnNames(in session: FileBrowserSession, at location: FileLocation) -> [String]? {
    session.columnState.columns.first(where: { $0.location == location })?.items.map(\.name)
  }

  private func waitForNames(
    _ expected: [String], in session: FileBrowserSession, at location: FileLocation
  ) async throws {
    try await waitUntil {
      session.currentLocation == location
        && session.items.map(\.name) == expected
        && columnNames(in: session, at: location) == expected
    }
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while !condition(), clock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(condition())
  }
}
