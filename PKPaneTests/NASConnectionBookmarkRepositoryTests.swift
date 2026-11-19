import Foundation
import Testing

@testable import PKPane

struct NASConnectionBookmarkRepositoryTests {
  @Test("NAS共有のBookmarkをプロファイルごとに保存して復元する")
  func savesAndRestoresBookmarkByProfile() throws {
    let profile = try NASConnectionProfile(
      displayName: "開発用NAS", host: "nas.example.local", shareName: "Documents")
    let folderURL = URL(filePath: "/Volumes/Documents")
    let codec = StubNASBookmarkCodec()
    let storage = InMemoryNASBookmarkStore()
    let repository = NASConnectionBookmarkRepository(storage: storage, codec: codec)

    try repository.save(folderURL, for: profile.id)

    #expect(try repository.restore(for: profile.id) == folderURL.standardizedFileURL)
  }

  @Test("staleなNAS共有Bookmarkを更新する")
  func refreshesStaleBookmark() throws {
    let profile = try NASConnectionProfile(
      displayName: "開発用NAS", host: "nas.example.local", shareName: "Documents")
    let folderURL = URL(filePath: "/Volumes/Documents")
    let codec = StubNASBookmarkCodec(staleURLs: [folderURL])
    let storage = InMemoryNASBookmarkStore()
    let repository = NASConnectionBookmarkRepository(storage: storage, codec: codec)
    storage.saveBookmarkData(folderURL.path.data(using: .utf8)!, for: profile.id)

    _ = try repository.restore(for: profile.id)

    #expect(codec.createdURLs == [folderURL])
  }
}

private final class StubNASBookmarkCodec: FolderBookmarkCoding {
  private let staleURLs: Set<URL>
  private(set) var createdURLs: [URL] = []

  init(staleURLs: Set<URL> = []) {
    self.staleURLs = staleURLs
  }

  func createBookmark(for url: URL) throws -> Data {
    createdURLs.append(url)
    return url.path.data(using: .utf8)!
  }

  func resolveBookmark(_ data: Data) throws -> ResolvedFolderBookmark {
    let path = String(decoding: data, as: UTF8.self)
    let url = URL(filePath: path)
    return ResolvedFolderBookmark(url: url, isStale: staleURLs.contains(url))
  }
}

private final class InMemoryNASBookmarkStore: NASConnectionBookmarkStoring {
  private var data: [NASConnectionProfile.ID: Data] = [:]

  func loadBookmarkData(for profileID: NASConnectionProfile.ID) -> Data? {
    data[profileID]
  }

  func saveBookmarkData(_ data: Data, for profileID: NASConnectionProfile.ID) {
    self.data[profileID] = data
  }

  func removeBookmarkData(for profileID: NASConnectionProfile.ID) {
    data[profileID] = nil
  }
}
