import Foundation
import Testing
import ZIPFoundation

@testable import PKPane

struct FileColumnRevealScrollTests {
  private let rootURL = URL(filePath: "/tmp/column-root", directoryHint: .isDirectory)
  private var root: FileLocation { FileLocation(directoryURL: rootURL) }

  @Test("表示対象のフォルダがすぐ右のカラムに開いていればそのカラムに移動する")
  func targetsOpenedFolderColumn() {
    let folder = item("Folder", isDirectory: true)
    let descendant = FileItem(
      url: folder.url.appending(path: "Descendant"), isDirectory: true)
    let columns = [
      column(at: root, items: [folder]),
      column(at: folder.location, items: [descendant]),
      column(at: descendant.location),
    ]
    let request = FileItemRevealRequest(generation: 1, itemURL: folder.url, directoryLocation: root)

    #expect(FileColumnRevealScroll.targetLocation(in: columns, for: request) == folder.location)
  }

  @Test("ファイルを表示すると親カラムに移動する")
  func targetsParentColumnForFile() {
    let file = item("report.txt", isDirectory: false)
    let folder = item("Folder", isDirectory: true)
    let columns = [column(at: root, items: [file, folder]), column(at: folder.location)]
    let request = FileItemRevealRequest(generation: 1, itemURL: file.url, directoryLocation: root)

    #expect(FileColumnRevealScroll.targetLocation(in: columns, for: request) == root)
  }

  @Test("右にカラムがなければ親カラムに移動する")
  func targetsParentColumnWithoutRightColumn() {
    let folder = item("Folder", isDirectory: true)
    let columns = [column(at: root, items: [folder])]
    let request = FileItemRevealRequest(generation: 1, itemURL: folder.url, directoryLocation: root)

    #expect(FileColumnRevealScroll.targetLocation(in: columns, for: request) == root)
  }

  @Test("すぐ右のカラムが別のフォルダなら親カラムに移動する")
  func targetsParentColumnWhenRightColumnShowsDifferentFolder() {
    let folder = item("Folder", isDirectory: true)
    let otherFolder = item("Other", isDirectory: true)
    let columns = [
      column(at: root, items: [folder, otherFolder]),
      column(at: otherFolder.location),
    ]
    let request = FileItemRevealRequest(generation: 1, itemURL: folder.url, directoryLocation: root)

    #expect(FileColumnRevealScroll.targetLocation(in: columns, for: request) == root)
  }

  @Test("指定のカラムに対象のURLがなければ移動先を返さない")
  func returnsNilWhenItemOrColumnIsMissing() {
    let file = item("report.txt", isDirectory: false)
    let otherFolder = item("Other", isDirectory: true)
    let columns = [column(at: root, items: [file])]
    let missingItem = FileItemRevealRequest(
      generation: 1, itemURL: otherFolder.url, directoryLocation: root)
    let missingColumn = FileItemRevealRequest(
      generation: 2, itemURL: file.url, directoryLocation: otherFolder.location)

    #expect(FileColumnRevealScroll.targetLocation(in: columns, for: missingItem) == nil)
    #expect(FileColumnRevealScroll.targetLocation(in: columns, for: missingColumn) == nil)
  }

  @MainActor
  @Test("カラム表示で単一フォルダのZIPを開くと展開先のカラムに移動する")
  func targetsExtractedFolderColumnAfterOpeningZIP() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appending(
      path: "pkpane-column-reveal-scroll-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let archive = try Archive(url: rootURL.appending(path: "fixture.zip"), accessMode: .create)
    let data = Data("fixture".utf8)
    let path = "Folder/inside.txt"
    try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) {
      offset, size in
      data.subdata(in: Int(offset)..<min(Int(offset) + size, data.count))
    }

    let provider = LocalFileProvider()
    let session = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(directoryURL: rootURL, providerID: provider.id),
      transferQueue: .isolatedForTesting())
    defer { session.invalidate() }

    session.load()
    let loaded = await waitUntil("ZIPを含むルートの読み込みが完了しませんでした") {
      !session.isLoading && !session.isRefreshing
        && session.items.contains { $0.name == "fixture.zip" }
    }
    try #require(loaded)
    session.beginColumnBrowsing()
    let parent = try #require(session.columnState.columns.first)
    let zip = try #require(parent.items.first { $0.name == "fixture.zip" })
    session.open(zip)

    let outputURL = rootURL.appending(path: "Folder", directoryHint: .isDirectory)
    let extracted = await waitUntil("ZIPの展開が完了しませんでした") {
      !session.isArchiving && FileManager.default.fileExists(atPath: outputURL.path)
    }
    try #require(extracted)
    try #require(session.errorMessage == nil)

    let request = try #require(session.revealRequest)
    let refreshedParent = try #require(session.columnState.columns.first)
    let folder = try #require(
      refreshedParent.items.first { $0.name == "Folder" && $0.isDirectory })
    #expect(
      FileColumnRevealScroll.targetLocation(in: session.columnState.columns, for: request)
        == folder.location)
  }

  private func item(_ name: String, isDirectory: Bool) -> FileItem {
    FileItem(
      url: rootURL.appending(path: name), providerID: root.providerID, isDirectory: isDirectory)
  }

  private func column(at location: FileLocation, items: [FileItem] = []) -> FileBrowserColumn {
    FileBrowserColumn(location: location, items: items, selectedItemURLs: [], isLoading: false)
  }
}
