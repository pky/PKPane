import Foundation
import Synchronization

enum GrantActivation: Equatable, Sendable {
  case none
  case activated
  case alreadyActive
}

protocol FolderWriteAccessGrantStoring: Sendable {
  func save(_ directoryURL: URL) throws
  func activateGrant(covering url: URL) -> GrantActivation
}

final class FolderWriteAccessGrantStore: FolderWriteAccessGrantStoring {
  static let shared = FolderWriteAccessGrantStore(defaults: PKPaneUserDefaults.resolve())

  private let defaultsKey = "folder-write-access-grants"
  // UserDefaultsはスレッド安全。読み込みから保存までの一連の操作はロックで直列化する。
  private nonisolated(unsafe) let defaults: UserDefaults
  private let codec: any FolderBookmarkCoding & Sendable
  private let startAccessing: @Sendable (URL) -> Bool
  // 開始したスコープ付きURLは共有ストアでプロセス終了まで保持する。
  private let activeURLs = Mutex<[String: URL]>([:])

  init(
    defaults: UserDefaults,
    codec: any FolderBookmarkCoding & Sendable = SystemFolderBookmarkCodec(),
    startAccessing: @escaping @Sendable (URL) -> Bool = {
      $0.startAccessingSecurityScopedResource()
    }
  ) {
    self.defaults = defaults
    self.codec = codec
    self.startAccessing = startAccessing
  }

  func save(_ directoryURL: URL) throws {
    try activeURLs.withLock { activeURLs in
      let path = directoryURL.standardizedFileURL.path
      guard activeURLs[path] == nil else { return }

      let data = try codec.createBookmark(for: directoryURL)
      let resolved = try codec.resolveBookmark(data)
      guard startAccessing(resolved.url) else { throw FolderBookmarkAccessError.accessDenied }

      var bookmarks = defaults.array(forKey: defaultsKey) as? [Data] ?? []
      let existingIndex = bookmarks.firstIndex { bookmark in
        (try? codec.resolveBookmark(bookmark))?.url.standardizedFileURL.path == path
      }
      if let existingIndex {
        bookmarks[existingIndex] = data
      } else {
        bookmarks.append(data)
      }
      defaults.set(bookmarks, forKey: defaultsKey)
      activeURLs[path] = resolved.url
    }
  }

  func activateGrant(covering url: URL) -> GrantActivation {
    activeURLs.withLock { activeURLs in
      if activeURLs.values.contains(where: { Self.covers(url, from: $0) }) {
        return .alreadyActive
      }
      var bookmarks = defaults.array(forKey: defaultsKey) as? [Data] ?? []
      for index in bookmarks.indices {
        guard let resolved = try? codec.resolveBookmark(bookmarks[index]),
          Self.covers(url, from: resolved.url),
          startAccessing(resolved.url)
        else { continue }

        activeURLs[resolved.url.standardizedFileURL.path] = resolved.url
        if resolved.isStale, let refreshed = try? codec.createBookmark(for: resolved.url) {
          bookmarks[index] = refreshed
          defaults.set(bookmarks, forKey: defaultsKey)
        }
        return .activated
      }
      return .none
    }
  }

  static func covers(_ url: URL, from directory: URL) -> Bool {
    guard url.isFileURL, directory.isFileURL else { return false }
    return url.standardizedFileURL.pathComponents.starts(
      with: directory.standardizedFileURL.pathComponents)
  }
}
