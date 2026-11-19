import Foundation

protocol NASConnectionBookmarkStoring: AnyObject {
  func loadBookmarkData(for profileID: NASConnectionProfile.ID) -> Data?
  func saveBookmarkData(_ data: Data, for profileID: NASConnectionProfile.ID)
  func removeBookmarkData(for profileID: NASConnectionProfile.ID)
}

final class NASConnectionBookmarkRepository {
  private let storage: any NASConnectionBookmarkStoring
  private let codec: any FolderBookmarkCoding

  init(
    storage: any NASConnectionBookmarkStoring = UserDefaultsNASConnectionBookmarkStore(),
    codec: any FolderBookmarkCoding = SystemFolderBookmarkCodec()
  ) {
    self.storage = storage
    self.codec = codec
  }

  func save(_ folderURL: URL, for profileID: NASConnectionProfile.ID) throws {
    storage.saveBookmarkData(try codec.createBookmark(for: folderURL), for: profileID)
  }

  func restore(for profileID: NASConnectionProfile.ID) throws -> URL? {
    guard let bookmarkData = storage.loadBookmarkData(for: profileID) else {
      return nil
    }
    let resolvedBookmark = try codec.resolveBookmark(bookmarkData)
    if resolvedBookmark.isStale {
      try save(resolvedBookmark.url, for: profileID)
    }
    return resolvedBookmark.url.standardizedFileURL
  }

  func remove(for profileID: NASConnectionProfile.ID) {
    storage.removeBookmarkData(for: profileID)
  }
}

final class UserDefaultsNASConnectionBookmarkStore: NASConnectionBookmarkStoring {
  private let defaults: UserDefaults

  init(defaults: UserDefaults? = nil) {
    self.defaults = defaults ?? Self.defaultUserDefaults
  }

  func loadBookmarkData(for profileID: NASConnectionProfile.ID) -> Data? {
    defaults.data(forKey: key(for: profileID))
  }

  func saveBookmarkData(_ data: Data, for profileID: NASConnectionProfile.ID) {
    defaults.set(data, forKey: key(for: profileID))
  }

  func removeBookmarkData(for profileID: NASConnectionProfile.ID) {
    defaults.removeObject(forKey: key(for: profileID))
  }

  private func key(for profileID: NASConnectionProfile.ID) -> String {
    "nas-connection-bookmark-\(profileID.uuidString)"
  }

  private static var defaultUserDefaults: UserDefaults {
    PKPaneUserDefaults.resolve()
  }
}
