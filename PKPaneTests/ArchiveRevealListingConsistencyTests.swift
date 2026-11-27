import Foundation
import Testing
import ZIPFoundation

@testable import PKPane

@MainActor
struct ArchiveRevealListingConsistencyTests {
  @Test("展開中の子一覧でZIPを作成してもFinderエイリアスの判定を保持する")
  func preservesFinderAliasInExpandedChildrenAfterCreatingZIP() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    let session = fixture.session
    let subURL = fixture.rootURL.appending(path: "Sub", directoryHint: .isDirectory)
    let targetURL = fixture.rootURL.appending(path: "Target", directoryHint: .isDirectory)
    for folderURL in [subURL, targetURL] {
      try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: false)
    }
    try Data("source".utf8).write(to: subURL.appending(path: "source.txt"))
    let aliasData = try targetURL.bookmarkData(
      options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
    try URL.writeBookmarkData(aliasData, to: subURL.appending(path: "Target Alias"))

    try await fixture.loadRoot(containing: "Sub")
    let folder = try #require(session.items.first { $0.name == "Sub" })
    session.toggleExpansion(of: folder)
    let loaded = await waitUntil("Subの子一覧が読み込まれませんでした") {
      session.treeState.children(of: folder.location) != nil
    }
    try #require(loaded)
    let children = try #require(session.treeState.children(of: folder.location))
    let source = try #require(children.first { $0.name == "source.txt" })
    let aliasBefore = try #require(children.first { $0.name == "Target Alias" })
    try #require(aliasBefore.isAliasFile)

    session.createArchive([source])

    let completed = await waitUntil("ZIP作成が完了しませんでした") { !session.isArchiving }
    try #require(completed)
    try #require(session.errorMessage == nil)
    let reveal = try #require(session.revealRequest)
    try #require(reveal.directoryLocation == folder.location)
    try #require(reveal.itemURL.lastPathComponent == "source.txt.zip")
    let updatedChildren = try #require(session.treeState.children(of: folder.location))
    try #require(updatedChildren.contains { $0.name == "source.txt.zip" })
    let aliasAfter = try #require(updatedChildren.first { $0.name == aliasBefore.name })
    #expect(aliasAfter.isAliasFile)
  }

  @Test("同じパスにZIPを再展開すると右カラムに新しい内容を表示する")
  func loadsNewRightColumnContentsAfterExtractingToSamePath() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    let session = fixture.session
    let folderURL = fixture.rootURL.appending(path: "X", directoryHint: .isDirectory)
    let fileManager = FileManager.default
    let folderDate = Date(timeIntervalSince1970: 1_700_000_000)
    try fixture.writeZIP(named: "old.zip", containing: "old.txt", folderDate: folderDate)
    try fixture.writeZIP(named: "new.zip", containing: "new.txt", folderDate: folderDate)
    try await fixture.loadRoot(containing: "old.zip")
    session.beginColumnBrowsing()

    try await fixture.openZIP(named: "old.zip", expecting: folderURL)
    let oldColumn = try await fixture.loadedRightColumn(at: folderURL)
    try #require(oldColumn.items.map(\.name) == ["old.txt"])
    let oldAttributes = try fileManager.attributesOfItem(atPath: folderURL.path)
    let oldModificationDate = try #require(oldAttributes[.modificationDate] as? Date)

    let newZIP = try #require(
      session.columnState.columns.first?.items.first { $0.name == "new.zip" })
    session.selectColumnItem(newZIP, inColumnAt: 0)
    try #require(session.columnState.columns.count == 1)
    try fileManager.removeItem(at: folderURL)

    try await fixture.openZIP(named: "new.zip", expecting: folderURL)
    let newColumn = try await fixture.loadedRightColumn(at: folderURL)
    let namesOnDisk = try fileManager.contentsOfDirectory(atPath: folderURL.path)
    try #require(namesOnDisk == ["new.txt"])
    let newAttributes = try fileManager.attributesOfItem(atPath: folderURL.path)
    let newModificationDate = try #require(newAttributes[.modificationDate] as? Date)
    try #require(newModificationDate == oldModificationDate)
    #expect(newColumn.items.map(\.name) == ["new.txt"])
  }

  @MainActor
  private struct Fixture {
    let rootURL: URL
    let session: FileBrowserSession

    init() throws {
      let directory = FileManager.default.temporaryDirectory.appending(
        path: "pkpane-archive-listing-\(UUID().uuidString)", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
      rootURL = directory.resolvingSymlinksInPath()
      let provider = LocalFileProvider()
      session = FileBrowserSession(
        provider: provider,
        initialLocation: FileLocation(directoryURL: rootURL, providerID: provider.id),
        transferQueue: .isolatedForTesting())
    }

    func loadRoot(containing name: String) async throws {
      session.load()
      let loaded = await waitUntil("ルートの一覧が読み込まれませんでした") {
        !session.isLoading && !session.isRefreshing && session.items.contains { $0.name == name }
      }
      try #require(loaded)
    }

    func writeZIP(named name: String, containing file: String, folderDate: Date) throws {
      let archive = try Archive(url: rootURL.appending(path: name), accessMode: .create)
      let data = Data(file.utf8)
      try archive.addEntry(with: "X/\(file)", type: .file, uncompressedSize: Int64(data.count)) {
        offset, size in
        data.subdata(in: Int(offset)..<min(Int(offset) + size, data.count))
      }
      // 子ファイルを作成した後にフォルダの更新日時が復元されるようにする。
      try archive.addEntry(
        with: "X/", type: .directory, uncompressedSize: Int64(0), modificationDate: folderDate
      ) { _, _ in Data() }
    }

    func openZIP(named name: String, expecting folderURL: URL) async throws {
      let zip = try #require(session.columnState.columns.first?.items.first { $0.name == name })
      let previousRevealGeneration = session.revealRequest?.generation
      session.open(zip)
      let completed = await waitUntil("\(name)の展開が完了しませんでした") { !session.isArchiving }
      try #require(completed)
      try #require(session.errorMessage == nil)
      let reveal = try #require(session.revealRequest)
      try #require(reveal.generation != previousRevealGeneration)
      try #require(reveal.itemURL.resolvingSymlinksInPath().path == folderURL.path)
    }

    func loadedRightColumn(at folderURL: URL) async throws -> FileBrowserColumn {
      let loaded = await waitUntil("\(folderURL.lastPathComponent)の右カラムが読み込まれませんでした") {
        session.columnState.columns.dropFirst().contains {
          $0.location.localURL?.resolvingSymlinksInPath().path == folderURL.path && !$0.isLoading
        }
      }
      try #require(loaded)
      return try #require(
        session.columnState.columns.dropFirst().first {
          $0.location.localURL?.resolvingSymlinksInPath().path == folderURL.path
        })
    }

    func close() {
      session.invalidate()
      try? FileManager.default.removeItem(at: rootURL)
    }
  }
}
