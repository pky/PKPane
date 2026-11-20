import Foundation
import Testing

@testable import PKPane

@MainActor
struct ColumnFolderRenameTests {
  @Test("カラム表示で選択中のフォルダを改名すると選択と内容表示が新しい名前へ移る")
  func renamingSelectedFolderInColumnViewDoesNotReportError() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    let session = fixture.session
    try await fixture.openRoot()
    let itemA = try fixture.select("A", in: 0)
    try await fixture.waitForColumn(at: itemA.location, containing: "inner.txt")

    session.rename(itemA, to: "B")
    try await fixture.waitForIdle()

    let renamedURL = fixture.rootURL.appending(path: "B", directoryHint: .isDirectory)
    #expect(FileManager.default.fileExists(atPath: renamedURL.path))
    #expect(!FileManager.default.fileExists(atPath: itemA.url.path))
    try #require(session.errorMessage == nil)

    let renamedLocation = FileLocation(directoryURL: renamedURL)
    let contentsDisplayed = await waitUntil("改名後のフォルダに inner.txt が表示されませんでした") {
      session.columnState.columns.contains { column in
        column.location == renamedLocation && !column.isLoading
          && column.items.contains { $0.name == "inner.txt" }
      }
    }
    try #require(contentsDisplayed)
    let rootColumn = try #require(session.columnState.columns.first)
    #expect(rootColumn.location == fixture.root)
    #expect(!rootColumn.items.contains { $0.name == "A" })
    let itemB = try #require(rootColumn.items.first { $0.name == "B" })
    #expect(rootColumn.selectedItemURLs == [itemB.url])
    #expect(session.errorMessage == nil)
  }

  @Test("カラム表示で祖先フォルダを改名すると旧パスのカラムが残らない")
  func renamingAncestorFolderOfDeeperColumnDoesNotReportError() async throws {
    let fixture = try Fixture(fileInFolder: "A/C/inner.txt")
    defer { fixture.close() }
    let session = fixture.session
    try await fixture.openRoot()
    let itemA = try fixture.select("A", in: 0)
    try await fixture.waitForColumn(at: itemA.location, containing: "C")
    let itemC = try fixture.select("C", in: 1)
    try await fixture.waitForColumn(at: itemC.location, containing: "inner.txt")

    session.rename(itemA, to: "B")
    try await fixture.waitForIdle()

    #expect(session.errorMessage == nil)
    let rootColumn = try #require(session.columnState.columns.first)
    #expect(rootColumn.location == fixture.root)
    #expect(rootColumn.items.contains { $0.name == "B" })
    #expect(!rootColumn.items.contains { $0.name == "A" })
    let oldPath = itemA.url.pathComponents
    #expect(
      !session.columnState.columns.contains { column in
        column.location.localURL?.pathComponents.starts(with: oldPath) == true
      })
  }

  @Test("カラム表示で選択中のファイルを改名すると一覧に反映される")
  func renamingFileInColumnViewStillWorks() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    let session = fixture.session
    try await fixture.openRoot()
    let item = try fixture.select("other.txt", in: 0)
    try #require(session.currentLocation == fixture.root)
    try #require(session.columnState.columns.first?.selectedItemURLs == [item.url])

    session.rename(item, to: "renamed.txt")
    try await fixture.waitForIdle()

    #expect(session.errorMessage == nil)
    let rootColumn = try #require(session.columnState.columns.first)
    #expect(rootColumn.location == fixture.root)
    #expect(rootColumn.items.contains { $0.name == "renamed.txt" })
  }

  @MainActor
  private struct Fixture {
    let rootURL: URL
    let root: FileLocation
    let session: FileBrowserSession

    init(fileInFolder: String = "A/inner.txt") throws {
      let rootURL = FileManager.default.temporaryDirectory.appending(
        path: UUID().uuidString, directoryHint: .isDirectory)
      let fileURL = rootURL.appending(path: fileInFolder)
      do {
        try FileManager.default.createDirectory(
          at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: fileURL)
        try Data().write(to: rootURL.appending(path: "other.txt"))
      } catch {
        try? FileManager.default.removeItem(at: rootURL)
        throw error
      }
      self.rootURL = rootURL
      let provider = LocalFileProvider()
      root = FileLocation(directoryURL: rootURL, providerID: provider.id)
      session = FileBrowserSession(
        provider: provider, initialLocation: root, transferQueue: .isolatedForTesting())
    }

    func close() {
      session.invalidate()
      try? FileManager.default.removeItem(at: rootURL)
    }

    func openRoot() async throws {
      session.load()
      let loaded = await waitUntil("ルートの読み込みが完了しませんでした") {
        session.currentLocation == root && !session.isLoading
          && session.items.contains { $0.name == "other.txt" }
      }
      try #require(loaded)
      session.beginColumnBrowsing()
    }

    func select(_ name: String, in columnIndex: Int) throws -> FileItem {
      let columns = session.columnState.columns
      try #require(columns.indices.contains(columnIndex))
      let item = try #require(columns[columnIndex].items.first { $0.name == name })
      session.selectColumnItem(item, inColumnAt: columnIndex)
      return item
    }

    func waitForColumn(at location: FileLocation, containing name: String) async throws {
      let loaded = await waitUntil("\(name) を含む右端のカラムが読み込まれませんでした") {
        guard let column = session.columnState.columns.last else { return false }
        return session.currentLocation == location && column.location == location
          && !column.isLoading && column.items.contains { $0.name == name }
      }
      try #require(loaded)
    }

    func waitForIdle() async throws {
      let idle = await waitUntil("ファイル操作が完了しませんでした") {
        !session.isLoading && !session.hasBackgroundFileOperation
      }
      try #require(idle)
    }
  }
}
