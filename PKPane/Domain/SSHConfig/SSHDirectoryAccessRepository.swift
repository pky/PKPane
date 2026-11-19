import Foundation

protocol SSHDirectoryBookmarkStoring: AnyObject {
  func loadBookmarkData() -> Data?
  func saveBookmarkData(_ data: Data)
  func removeBookmarkData()
}

final class SSHDirectoryAccessRepository: @unchecked Sendable {
  private let storage: any SSHDirectoryBookmarkStoring
  private let codec: any FolderBookmarkCoding

  init(
    storage: any SSHDirectoryBookmarkStoring = UserDefaultsSSHDirectoryBookmarkStore(),
    codec: any FolderBookmarkCoding = SystemFolderBookmarkCodec()
  ) {
    self.storage = storage
    self.codec = codec
  }

  func save(_ folderURL: URL) throws {
    storage.saveBookmarkData(try codec.createBookmark(for: folderURL))
  }

  func restore() throws -> URL? {
    guard let bookmarkData = storage.loadBookmarkData() else { return nil }
    let resolved = try codec.resolveBookmark(bookmarkData)
    if resolved.isStale {
      try save(resolved.url)
    }
    return resolved.url
  }

  func remove() {
    storage.removeBookmarkData()
  }
}

final class UserDefaultsSSHDirectoryBookmarkStore: SSHDirectoryBookmarkStoring {
  private let defaults: UserDefaults
  private let key: String

  init(
    defaults: UserDefaults? = nil,
    key: String = "ssh-directory-bookmark"
  ) {
    self.defaults = defaults ?? PKPaneUserDefaults.resolve()
    self.key = key
  }

  func loadBookmarkData() -> Data? {
    defaults.data(forKey: key)
  }

  func saveBookmarkData(_ data: Data) {
    defaults.set(data, forKey: key)
  }

  func removeBookmarkData() {
    defaults.removeObject(forKey: key)
  }
}
