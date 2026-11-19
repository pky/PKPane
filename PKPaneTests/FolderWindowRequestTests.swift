import Foundation
import Testing

@testable import PKPane

struct FolderWindowRequestTests {
  @Test func additionalWindowHasIndependentStateAndBookmark() throws {
    let url = URL(filePath: "/Volumes/TestShare/Folder")
    let codec = FolderWindowTestCodec()
    let request = try #require(
      try FolderWindowRequest(location: FileLocation(directoryURL: url), codec: codec))
    let second = try #require(
      try FolderWindowRequest(location: FileLocation(directoryURL: url), codec: codec))
    #expect(request.id != second.id)
    #expect(request.resolvedURL(codec: codec) == url)
    #expect(
      try JSONDecoder().decode(FolderWindowRequest.self, from: JSONEncoder().encode(request))
        == request)

    let root = FileManager.default.temporaryDirectory.appending(path: "FolderWindowTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let defaultURL = root.appending(path: "workspace.json")
    let original = Data("元ウインドウの復元状態".utf8)
    try original.write(to: defaultURL)
    let store = request.workspaceStore(defaultURL: defaultURL)
    let tabID = UUID()
    let state = WorkspaceState(
      tabs: [
        WorkspaceTabState(
          id: tabID, location: .local(bookmarkData: Data(), lastKnownPath: url.path),
          viewMode: .list)
      ],
      activeTabID: tabID,
      pane: WorkspacePaneState(
        showsSecondaryPane: false, activePane: .primary, primaryTabID: tabID, secondaryTabID: nil))
    try store.save(state)
    #expect(try store.load() == state)
    #expect(try Data(contentsOf: defaultURL) == original)
    #expect(store.url != second.workspaceStore(defaultURL: defaultURL).url)
  }

  @Test func failedBookmarkResolutionKeepsRequestedFolderForAuthorization() throws {
    let url = URL(filePath: "/tmp/RequestedFolder")
    let request = try #require(
      try FolderWindowRequest(
        location: FileLocation(directoryURL: url), codec: FolderWindowTestCodec())
    )
    #expect(request.resolvedURL(codec: FolderWindowTestCodec(failsResolution: true)) == url)
  }

  @Test func remoteLocationsAndBookmarkFailuresDoNotOpenNewWindows() throws {
    let remote = FileLocation(
      remotePath: "/folder", providerID: FileProviderID(rawValue: "sftp-test"))
    #expect(try FolderWindowRequest(location: remote, codec: FolderWindowTestCodec()) == nil)
    #expect(throws: CocoaError.self) {
      try FolderWindowRequest(
        location: FileLocation(directoryURL: URL(filePath: "/tmp/folder")),
        codec: FolderWindowTestCodec(failsCreation: true))
    }
  }
}

private struct FolderWindowTestCodec: FolderBookmarkCoding {
  var failsCreation = false
  var failsResolution = false
  func createBookmark(for url: URL) throws -> Data {
    if failsCreation { throw CocoaError(.fileReadNoPermission) }
    return Data(url.path.utf8)
  }
  func resolveBookmark(_ data: Data) throws -> ResolvedFolderBookmark {
    if failsResolution { throw CocoaError(.fileReadCorruptFile) }
    return ResolvedFolderBookmark(
      url: URL(filePath: String(decoding: data, as: UTF8.self)), isStale: false)
  }
}
