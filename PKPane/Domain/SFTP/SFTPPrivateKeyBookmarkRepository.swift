import Foundation

protocol SFTPPrivateKeyBookmarkStoring: AnyObject {
  func loadBookmarkData(for target: SFTPConnectionTarget) -> Data?
  func saveBookmarkData(_ data: Data, for target: SFTPConnectionTarget)
  func removeBookmarkData(for target: SFTPConnectionTarget)
}

protocol SFTPPrivateKeyBookmarkPersisting: AnyObject {
  func save(_ privateKeyURL: URL, for target: SFTPConnectionTarget) throws
  func restore(for target: SFTPConnectionTarget) throws -> URL?
  func remove(for target: SFTPConnectionTarget)
  func save(_ privateKeyURL: URL, for hop: SFTPHopIdentity) throws
  func restore(for hop: SFTPHopIdentity) throws -> URL?
  func remove(for hop: SFTPHopIdentity)
}

extension SFTPPrivateKeyBookmarkPersisting {
  func save(_ privateKeyURL: URL, for hop: SFTPHopIdentity) throws {
    try save(privateKeyURL, for: SFTPConnectionTarget(hop))
  }

  func restore(for hop: SFTPHopIdentity) throws -> URL? {
    try restore(for: SFTPConnectionTarget(hop))
  }

  func remove(for hop: SFTPHopIdentity) {
    guard let target = try? SFTPConnectionTarget(hop) else {
      return
    }
    remove(for: target)
  }
}

final class SFTPPrivateKeyBookmarkRepository: SFTPPrivateKeyBookmarkPersisting {
  private let storage: any SFTPPrivateKeyBookmarkStoring
  private let codec: any FolderBookmarkCoding

  init(
    storage: any SFTPPrivateKeyBookmarkStoring = UserDefaultsSFTPPrivateKeyBookmarkStore(),
    codec: any FolderBookmarkCoding = SystemFolderBookmarkCodec()
  ) {
    self.storage = storage
    self.codec = codec
  }

  func save(_ privateKeyURL: URL, for target: SFTPConnectionTarget) throws {
    try save(privateKeyURL, for: target.finalHop)
  }

  func save(_ privateKeyURL: URL, for hop: SFTPHopIdentity) throws {
    let bookmarkData = try codec.createBookmark(for: privateKeyURL)
    storage.saveBookmarkData(bookmarkData, for: try SFTPConnectionTarget(hop))
  }

  func restore(for target: SFTPConnectionTarget) throws -> URL? {
    try restore(for: target.finalHop)
  }

  func restore(for hop: SFTPHopIdentity) throws -> URL? {
    let target = try SFTPConnectionTarget(hop)
    guard let bookmarkData = storage.loadBookmarkData(for: target) else {
      return nil
    }
    let resolvedBookmark = try codec.resolveBookmark(bookmarkData)
    if resolvedBookmark.isStale {
      try save(resolvedBookmark.url, for: hop)
    }
    return resolvedBookmark.url.standardizedFileURL
  }

  func remove(for target: SFTPConnectionTarget) {
    remove(for: target.finalHop)
  }

  func remove(for hop: SFTPHopIdentity) {
    guard let target = try? SFTPConnectionTarget(hop) else {
      return
    }
    storage.removeBookmarkData(for: target)
  }
}

extension SFTPConnectionTarget {
  fileprivate init(_ hop: SFTPHopIdentity) throws {
    try self.init(host: hop.host, port: hop.port, username: hop.username)
  }
}

final class UserDefaultsSFTPPrivateKeyBookmarkStore: SFTPPrivateKeyBookmarkStoring {
  private let defaults: UserDefaults

  init(defaults: UserDefaults? = nil) {
    self.defaults = defaults ?? Self.defaultUserDefaults
  }

  func loadBookmarkData(for target: SFTPConnectionTarget) -> Data? {
    defaults.data(forKey: key(for: target))
  }

  func saveBookmarkData(_ data: Data, for target: SFTPConnectionTarget) {
    defaults.set(data, forKey: key(for: target))
  }

  func removeBookmarkData(for target: SFTPConnectionTarget) {
    defaults.removeObject(forKey: key(for: target))
  }

  private func key(for target: SFTPConnectionTarget) -> String {
    "sftp-private-key-bookmark-\(target.host):\(target.port):\(target.username)"
  }

  private static var defaultUserDefaults: UserDefaults {
    PKPaneUserDefaults.resolve()
  }
}
