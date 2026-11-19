import Foundation

struct FTPFolderRecent: Codable, Equatable, Identifiable {
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

final class FTPFolderRecentRepository {
  private let defaults: UserDefaults
  private let key: String
  private let limit: Int

  init(
    defaults: UserDefaults? = nil,
    key: String = "recent-ftp-folders",
    limit: Int = 12
  ) {
    self.defaults = defaults ?? PKPaneUserDefaults.resolve()
    self.key = key
    self.limit = limit
  }

  func load() -> [FTPFolderRecent] {
    guard let data = defaults.data(forKey: key) else { return [] }
    return (try? JSONDecoder().decode([FTPFolderRecent].self, from: data)) ?? []
  }

  @discardableResult
  func record(target: FTPConnectionTarget, directory: String) -> [FTPFolderRecent] {
    let normalizedDirectory = FTPConnectionTarget.normalizedAbsolutePath(directory)
    var recents = load()
    recents.removeAll { $0.target == target && $0.directory == normalizedDirectory }
    recents.insert(FTPFolderRecent(target: target, directory: normalizedDirectory), at: 0)
    if recents.count > limit {
      recents.removeLast(recents.count - limit)
    }
    save(recents)
    return recents
  }

  @discardableResult
  func remove(id: UUID) -> [FTPFolderRecent] {
    var recents = load()
    recents.removeAll { $0.id == id }
    save(recents)
    return recents
  }

  private func save(_ recents: [FTPFolderRecent]) {
    if recents.isEmpty {
      defaults.removeObject(forKey: key)
    } else {
      defaults.set(try? JSONEncoder().encode(recents), forKey: key)
    }
  }
}
