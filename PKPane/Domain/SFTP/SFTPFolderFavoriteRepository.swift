import Foundation

struct SFTPFolderFavorite: Codable, Equatable, Identifiable {
  let id: UUID
  let target: SFTPConnectionTarget
  let directory: String

  init(id: UUID = UUID(), target: SFTPConnectionTarget, directory: String) {
    self.id = id
    self.target = target
    self.directory = directory
  }

  var name: String {
    "\(target.username)@\(target.host):\(directory)"
  }
}

final class SFTPFolderFavoriteRepository {
  private let defaults: UserDefaults
  private let key: String

  init(defaults: UserDefaults? = nil, key: String = "favorite-sftp-folders") {
    self.defaults = defaults ?? Self.defaultUserDefaults
    self.key = key
  }

  func load() -> [SFTPFolderFavorite] {
    (try? loadFavorites()) ?? []
  }

  func portableFavorites() throws -> [PortableFavorite] {
    try loadFavorites().compactMap { favorite in
      guard
        let connectionIdentifier = PortableFavoriteConnectionIdentifier.sftp(
          target: favorite.target)
      else {
        return nil
      }
      return PortableFavorite(
        provider: .sftp,
        connectionIdentifier: connectionIdentifier,
        path: favorite.directory,
        displayName: favorite.name)
    }
  }

  @discardableResult
  func applySyncedFavorites(_ document: FavoriteSyncDocument) -> [SFTPFolderFavorite] {
    let current = load()
    let desiredFavorites = document.items.map(\.favorite).filter { $0.provider == .sftp }
    let tombstoneKeys = Set(document.tombstones.map(\.key).filter { $0.provider == .sftp })
    var usedFavoriteIDs: Set<UUID> = []
    var next: [SFTPFolderFavorite] = []

    for favorite in desiredFavorites {
      if let existing = current.first(where: {
        !usedFavoriteIDs.contains($0.id) && portableFavorite(for: $0)?.key == favorite.key
      }) {
        usedFavoriteIDs.insert(existing.id)
        next.append(existing)
      } else if let connectionIdentifier = favorite.connectionIdentifier,
        let target = PortableFavoriteConnectionIdentifier.sftpTarget(
          identifier: connectionIdentifier)
      {
        next.append(SFTPFolderFavorite(target: target, directory: favorite.path))
      }
    }

    for favorite in current where !usedFavoriteIDs.contains(favorite.id) {
      if let key = portableFavorite(for: favorite)?.key, tombstoneKeys.contains(key) {
        continue
      }
      next.append(favorite)
    }
    if next != current {
      save(next)
    }
    return next
  }

  @discardableResult
  func toggle(target: SFTPConnectionTarget, directory: String) -> [SFTPFolderFavorite] {
    var favorites = load()
    if let index = favorites.firstIndex(where: {
      $0.target == target && $0.directory == directory
    }) {
      favorites.remove(at: index)
    } else {
      favorites.append(SFTPFolderFavorite(target: target, directory: directory))
    }
    save(favorites)
    return favorites
  }

  @discardableResult
  func remove(id: UUID) -> [SFTPFolderFavorite] {
    var favorites = load()
    favorites.removeAll { $0.id == id }
    save(favorites)
    return favorites
  }

  func removeAll() {
    defaults.removeObject(forKey: key)
  }

  private func save(_ favorites: [SFTPFolderFavorite]) {
    if favorites.isEmpty {
      defaults.removeObject(forKey: key)
    } else {
      defaults.set(try? JSONEncoder().encode(favorites), forKey: key)
    }
  }

  private func loadFavorites() throws -> [SFTPFolderFavorite] {
    guard let data = defaults.data(forKey: key) else { return [] }
    return try JSONDecoder().decode([SFTPFolderFavorite].self, from: data)
  }

  private func portableFavorite(for favorite: SFTPFolderFavorite) -> PortableFavorite? {
    guard
      let connectionIdentifier = PortableFavoriteConnectionIdentifier.sftp(
        target: favorite.target)
    else {
      return nil
    }
    return PortableFavorite(
      provider: .sftp,
      connectionIdentifier: connectionIdentifier,
      path: favorite.directory,
      displayName: favorite.name)
  }

  private static var defaultUserDefaults: UserDefaults {
    PKPaneUserDefaults.resolve()
  }
}
