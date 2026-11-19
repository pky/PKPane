import Foundation

struct FTPFolderFavorite: Codable, Equatable, Identifiable {
  let id: UUID
  let target: FTPConnectionTarget
  let directory: String

  init(id: UUID = UUID(), target: FTPConnectionTarget, directory: String) {
    self.id = id
    self.target = target
    self.directory = FTPConnectionTarget.normalizedAbsolutePath(directory)
  }

  var name: String {
    "\(target.username)@\(target.host):\(directory)"
  }
}

final class FTPFolderFavoriteRepository {
  private let defaults: UserDefaults
  private let key: String

  init(defaults: UserDefaults? = nil, key: String = "favorite-ftp-folders") {
    self.defaults = defaults ?? PKPaneUserDefaults.resolve()
    self.key = key
  }

  func load() -> [FTPFolderFavorite] {
    guard let data = defaults.data(forKey: key) else { return [] }
    return (try? JSONDecoder().decode([FTPFolderFavorite].self, from: data)) ?? []
  }

  @discardableResult
  func toggle(target: FTPConnectionTarget, directory: String) -> [FTPFolderFavorite] {
    let normalizedDirectory = FTPConnectionTarget.normalizedAbsolutePath(directory)
    var favorites = load()
    if let index = favorites.firstIndex(where: {
      $0.target == target && $0.directory == normalizedDirectory
    }) {
      favorites.remove(at: index)
    } else {
      favorites.append(FTPFolderFavorite(target: target, directory: normalizedDirectory))
    }
    save(favorites)
    return favorites
  }

  @discardableResult
  func remove(id: UUID) -> [FTPFolderFavorite] {
    var favorites = load()
    favorites.removeAll { $0.id == id }
    save(favorites)
    return favorites
  }

  private func save(_ favorites: [FTPFolderFavorite]) {
    if favorites.isEmpty {
      defaults.removeObject(forKey: key)
    } else {
      defaults.set(try? JSONEncoder().encode(favorites), forKey: key)
    }
  }
}
