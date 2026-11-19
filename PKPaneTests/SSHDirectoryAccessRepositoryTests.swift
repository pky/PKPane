import Foundation
import Testing

@testable import PKPane

struct SSHDirectoryAccessRepositoryTests {
  @Test("SSH設定フォルダのBookmarkを保存・復元・削除できる")
  func saveRestoreRemoveRoundTrip() throws {
    let folderURL = URL(filePath: "/Users/test/.ssh", directoryHint: .isDirectory)
    let bookmarkData = Data("ssh-directory-bookmark".utf8)
    let storage = InMemorySSHDirectoryBookmarkStorage()
    let codec = SSHDirectoryBookmarkCodec(
      bookmarkDataByURL: [folderURL: bookmarkData],
      resolvedBookmarkByData: [
        bookmarkData: ResolvedFolderBookmark(url: folderURL, isStale: false)
      ])
    let repository = SSHDirectoryAccessRepository(storage: storage, codec: codec)

    try repository.save(folderURL)

    #expect(storage.bookmarkData == bookmarkData)
    #expect(try repository.restore() == folderURL)

    repository.remove()

    #expect(storage.bookmarkData == nil)
    #expect(try repository.restore() == nil)
  }
}

private final class InMemorySSHDirectoryBookmarkStorage: SSHDirectoryBookmarkStoring {
  var bookmarkData: Data?

  func loadBookmarkData() -> Data? {
    bookmarkData
  }

  func saveBookmarkData(_ data: Data) {
    bookmarkData = data
  }

  func removeBookmarkData() {
    bookmarkData = nil
  }
}

private struct SSHDirectoryBookmarkCodec: FolderBookmarkCoding {
  let bookmarkDataByURL: [URL: Data]
  let resolvedBookmarkByData: [Data: ResolvedFolderBookmark]

  func createBookmark(for url: URL) throws -> Data {
    try #require(bookmarkDataByURL[url])
  }

  func resolveBookmark(_ data: Data) throws -> ResolvedFolderBookmark {
    try #require(resolvedBookmarkByData[data])
  }
}
