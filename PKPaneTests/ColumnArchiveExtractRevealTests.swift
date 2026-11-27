import Foundation
import Testing
import ZIPFoundation

@testable import PKPane

@MainActor
struct ColumnArchiveExtractRevealTests {
  @Test("複数ファイルのZIPを開くとZIP名の右カラムに全ファイルが表示される")
  func loadsGroupedFilesInRightColumn() async throws {
    let fixture = try Fixture(paths: ["first.txt", "second.txt"])
    defer { fixture.close() }

    try await fixture.openZIP(inColumns: true, expecting: "fixture")

    try await expectRightColumn(in: fixture, folder: "fixture", files: ["first.txt", "second.txt"])
  }

  @Test("単一フォルダのZIPを開くとフォルダ名の右カラムに中身が表示される")
  func loadsSingleFolderInRightColumn() async throws {
    let fixture = try Fixture(paths: ["Folder/inside.txt"])
    defer { fixture.close() }

    try await fixture.openZIP(inColumns: true, expecting: "Folder")

    try await expectRightColumn(in: fixture, folder: "Folder", files: ["inside.txt"])
  }

  @Test("単一ファイルのZIPを開くと親カラムに展開したファイルが選択される")
  func selectsSingleExtractedFileWithoutAddingColumn() async throws {
    let fixture = try Fixture(paths: ["inside.txt"])
    defer { fixture.close() }
    let session = fixture.session

    try await fixture.openZIP(inColumns: true, expecting: "inside.txt")

    let parent = try #require(session.columnState.columns.first)
    let extracted = try #require(parent.items.first { $0.name == "inside.txt" })
    #expect(parent.location == fixture.root)
    #expect(parent.selectedItemURLs == [extracted.url])
    #expect(session.columnState.columns.count == 1)
    #expect(
      session.revealRequest?.itemURL.resolvingSymlinksInPath().path
        == extracted.url.resolvingSymlinksInPath().path)
    #expect(session.revealRequest?.directoryLocation == parent.location)
  }

  @Test("リスト表示でZIPを開くと展開したフォルダが一覧に表示される")
  func revealsExtractedFolderInList() async throws {
    let fixture = try Fixture(paths: ["first.txt", "second.txt"])
    defer { fixture.close() }
    let session = fixture.session

    try await fixture.openZIP(inColumns: false, expecting: "fixture")

    let extracted = try #require(session.items.first { $0.name == "fixture" })
    #expect(extracted.isDirectory)
    #expect(session.currentLocation == fixture.root)
    #expect(!session.columnState.isActive)
    #expect(
      session.revealRequest?.itemURL.resolvingSymlinksInPath().path
        == extracted.url.resolvingSymlinksInPath().path)
    #expect(session.revealRequest?.directoryLocation == fixture.root)
  }

  private func expectRightColumn(in fixture: Fixture, folder: String, files: Set<String>)
    async throws
  {
    let session = fixture.session
    let parent = try #require(session.columnState.columns.first)
    let extracted = try #require(parent.items.first { $0.name == folder && $0.isDirectory })
    let loaded = await waitUntil(
      "\(folder) の右カラムが読み込まれませんでした "
        + "(isLoading: \(String(describing: session.columnState.columns.last?.isLoading)), "
        + "items: \(session.columnState.columns.last?.items.map(\.name) ?? []))"
    ) {
      session.columnState.columns.dropFirst().contains {
        $0.location == extracted.location && !$0.isLoading
      }
    }
    guard loaded else { return }
    let child = try #require(
      session.columnState.columns.dropFirst().first { $0.location == extracted.location })
    #expect(Set(child.items.map(\.name)) == files)
  }

  @MainActor
  private struct Fixture {
    let rootURL: URL
    let root: FileLocation
    let session: FileBrowserSession

    init(paths: [String]) throws {
      let rootURL = FileManager.default.temporaryDirectory.appending(
        path: "pkpane-column-archive-\(UUID().uuidString)", directoryHint: .isDirectory)
      do {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let archive = try Archive(
          url: rootURL.appending(path: "fixture.zip"), accessMode: .create)
        let data = Data("fixture".utf8)
        for path in paths {
          try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) {
            offset, size in
            data.subdata(in: Int(offset)..<min(Int(offset) + size, data.count))
          }
        }
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

    func openZIP(inColumns: Bool, expecting outputName: String) async throws {
      session.load()
      let loaded = await waitUntil("ZIPを含むルートの読み込みが完了しませんでした") {
        !session.isLoading && !session.isRefreshing
          && session.items.contains { $0.name == "fixture.zip" }
      }
      try #require(loaded)
      if inColumns {
        session.beginColumnBrowsing()
      }
      let visibleItems = inColumns ? session.columnState.columns.first?.items ?? [] : session.items
      let zip = try #require(visibleItems.first { $0.name == "fixture.zip" })
      session.open(zip)

      let outputURL = rootURL.appending(path: outputName)
      let extracted = await waitUntil("ZIPの展開が完了しませんでした") {
        !session.isArchiving && FileManager.default.fileExists(atPath: outputURL.path)
      }
      try #require(extracted)
      try #require(session.errorMessage == nil)
    }

    func close() {
      session.invalidate()
      try? FileManager.default.removeItem(at: rootURL)
    }
  }
}
