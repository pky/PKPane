import Foundation
import Testing

@testable import PKPane

@MainActor
struct FolderSelectionModelCloudRootTests {
  @Test("選択した複数のクラウドルートを再起動後もブックマークから開ける")
  func restoresSelectedCloudRoots() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "PKPaneCloudRoots-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let cloudStorage = root.appending(path: "Library/CloudStorage", directoryHint: .isDirectory)
    let first = cloudStorage.appending(path: "GoogleDrive-Test", directoryHint: .isDirectory)
    let second = cloudStorage.appending(path: "Dropbox", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)

    let storage = CloudRootTestLocationStorage()
    let model = makeModel(cloudStorage: cloudStorage, storage: storage)
    #expect(model.registerCloudRoot(first))
    #expect(model.registerCloudRoot(second))
    #expect(model.cloudRootLocations.count == 2)

    let restored = makeModel(cloudStorage: cloudStorage, storage: storage)
    restored.restoreSavedFolder()

    #expect(restored.cloudRootLocations.count == 2)
    #expect(restored.openSavedCloudRoot(at: first) == first.standardizedFileURL)
    #expect(restored.selectedFolderURL == first.standardizedFileURL)
  }

  @Test("CloudStorage直下以外のフォルダは保存しない")
  func rejectsFoldersOutsideServiceRoots() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "PKPaneCloudRoots-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let cloudStorage = root.appending(path: "Library/CloudStorage", directoryHint: .isDirectory)
    let service = cloudStorage.appending(path: "Dropbox", directoryHint: .isDirectory)
    let nested = service.appending(path: "Documents", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

    let storage = CloudRootTestLocationStorage()
    let model = makeModel(cloudStorage: cloudStorage, storage: storage)

    #expect(!model.registerCloudRoot(nested))
    #expect(!model.registerCloudRoot(root))
    #expect(model.cloudRootLocations.isEmpty)
    #expect(storage.locationListData == nil)
  }

  @Test("クラウドルートの未許可・部分許可・許可済みを区別する")
  func opensOnlyAvailableCloudRoots() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "PKPaneCloudRoots-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let cloudStorage = root.appending(path: "Library/CloudStorage", directoryHint: .isDirectory)
    let first = cloudStorage.appending(path: "GoogleDrive-Test", directoryHint: .isDirectory)
    let second = cloudStorage.appending(path: "Dropbox", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)

    let availability = CloudRootTestAvailability()
    let model = makeModel(
      cloudStorage: cloudStorage,
      storage: CloudRootTestLocationStorage(),
      directoryIsAvailable: { availability.urls.contains($0.standardizedFileURL) })
    #expect(model.registerCloudRoot(first))
    #expect(model.registerCloudRoot(second))

    #expect(model.openSavedCloudRoot(at: first) == nil)
    availability.urls = [first.standardizedFileURL]
    #expect(model.openSavedCloudRoot(at: first) == first.standardizedFileURL)
    #expect(model.openSavedCloudRoot(at: second) == nil)
    availability.urls.insert(second.standardizedFileURL)
    #expect(model.openSavedCloudRoot(at: second) == second.standardizedFileURL)
  }

  @Test("サービス削除後は保存済みURLを開かず再選択を促せる")
  func removedCloudRootDoesNotOpen() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "PKPaneCloudRoots-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let cloudStorage = root.appending(path: "Library/CloudStorage", directoryHint: .isDirectory)
    let first = cloudStorage.appending(path: "GoogleDrive-Test", directoryHint: .isDirectory)
    let second = cloudStorage.appending(path: "Dropbox", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)

    let model = makeModel(cloudStorage: cloudStorage, storage: CloudRootTestLocationStorage())
    #expect(model.registerCloudRoot(first))
    #expect(model.registerCloudRoot(second))
    try FileManager.default.removeItem(at: first)

    #expect(model.openSavedCloudRoot(at: first) == nil)
    #expect(model.selectedFolderURL == second.standardizedFileURL)
  }

  @Test("ブックマークを解決できないルートは再許可後に復帰する")
  func unavailableBookmarkCanBeReauthorized() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "PKPaneCloudRoots-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let cloudStorage = root.appending(path: "Library/CloudStorage", directoryHint: .isDirectory)
    let service = cloudStorage.appending(path: "Dropbox", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: service, withIntermediateDirectories: true)

    let storage = CloudRootTestLocationStorage()
    let original = makeModel(
      cloudStorage: cloudStorage,
      storage: storage,
      cloudRootCodec: CloudRootTestCodec(canResolve: true))
    #expect(original.registerCloudRoot(service))

    let unavailable = makeModel(
      cloudStorage: cloudStorage,
      storage: storage,
      cloudRootCodec: CloudRootTestCodec(canResolve: false))
    unavailable.restoreSavedFolder()
    #expect(unavailable.cloudRootLocations.first?.url == nil)
    #expect(unavailable.cloudRootLocations.first?.lastKnownPath == service.path)
    #expect(unavailable.openSavedCloudRoot(at: service) == nil)

    let reauthorized = makeModel(
      cloudStorage: cloudStorage,
      storage: storage,
      cloudRootCodec: CloudRootTestCodec(canResolve: true))
    reauthorized.restoreSavedFolder()
    #expect(reauthorized.registerCloudRoot(service))
    #expect(reauthorized.cloudRootLocations.count == 1)
    #expect(reauthorized.openSavedCloudRoot(at: service)?.path == service.path)
  }

  private func makeModel(
    cloudStorage: URL,
    storage: CloudRootTestLocationStorage,
    cloudRootCodec: any FolderBookmarkCoding & Sendable = SystemFolderBookmarkCodec(),
    directoryIsAvailable: @escaping (URL) -> Bool = { url in
      var isDirectory: ObjCBool = false
      return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        && isDirectory.boolValue
    }
  ) -> FolderSelectionModel {
    FolderSelectionModel(
      repository: FolderBookmarkRepository(
        storage: CloudRootTestBookmarkStorage(),
        codec: SystemFolderBookmarkCodec()),
      favoriteRepository: FolderLocationListRepository(
        storage: CloudRootTestLocationStorage(),
        codec: SystemFolderBookmarkCodec(),
        mode: .favorites),
      recentRepository: FolderLocationListRepository(
        storage: CloudRootTestLocationStorage(),
        codec: SystemFolderBookmarkCodec(),
        mode: .recent(limit: 5)),
      cloudRootRepository: FolderLocationListRepository(
        storage: storage,
        codec: cloudRootCodec,
        mode: .favorites),
      cloudStorageURL: cloudStorage,
      cloudRootIsAvailable: directoryIsAvailable)
  }
}

@MainActor
private final class CloudRootTestAvailability {
  var urls: Set<URL> = []
}

private final class CloudRootTestBookmarkStorage: FolderBookmarkStoring {
  private var data: Data?

  func loadBookmarkData() -> Data? { data }
  func saveBookmarkData(_ data: Data) { self.data = data }
  func removeBookmarkData() { data = nil }
}

private final class CloudRootTestLocationStorage: FolderLocationListStoring, @unchecked Sendable {
  var locationListData: Data?

  func loadLocationListData() -> Data? { locationListData }
  func saveLocationListData(_ data: Data) { locationListData = data }
  func removeLocationListData() { locationListData = nil }
}

private struct CloudRootTestCodec: FolderBookmarkCoding, Sendable {
  struct ResolutionUnavailable: Error {}

  let canResolve: Bool

  func createBookmark(for url: URL) throws -> Data { Data(url.path.utf8) }

  func resolveBookmark(_ data: Data) throws -> ResolvedFolderBookmark {
    guard canResolve, let path = String(data: data, encoding: .utf8) else {
      throw ResolutionUnavailable()
    }
    return ResolvedFolderBookmark(url: URL(filePath: path), isStale: false)
  }
}
