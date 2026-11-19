import Foundation

struct SFTPFolderRecent: Codable, Equatable, Identifiable {
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

final class SFTPFolderRecentRepository {
  private let defaults: UserDefaults
  private let key: String
  private let limit: Int

  init(
    defaults: UserDefaults? = nil,
    key: String = "recent-sftp-folders",
    limit: Int = 12
  ) {
    self.defaults = defaults ?? Self.defaultUserDefaults
    self.key = key
    self.limit = limit
  }

  func load() -> [SFTPFolderRecent] {
    guard let data = defaults.data(forKey: key) else { return [] }
    return (try? JSONDecoder().decode([SFTPFolderRecent].self, from: data)) ?? []
  }

  @discardableResult
  func record(target: SFTPConnectionTarget, directory: String) -> [SFTPFolderRecent] {
    let normalizedDirectory = directory.isEmpty ? "." : directory
    var recents = load()
    recents.removeAll { $0.target == target && $0.directory == normalizedDirectory }
    recents.insert(SFTPFolderRecent(target: target, directory: normalizedDirectory), at: 0)
    if recents.count > limit {
      recents.removeLast(recents.count - limit)
    }
    save(recents)
    return recents
  }

  @discardableResult
  func remove(id: UUID) -> [SFTPFolderRecent] {
    var recents = load()
    recents.removeAll { $0.id == id }
    save(recents)
    return recents
  }

  private func save(_ recents: [SFTPFolderRecent]) {
    if recents.isEmpty {
      defaults.removeObject(forKey: key)
    } else {
      defaults.set(try? JSONEncoder().encode(recents), forKey: key)
    }
  }

  private static var defaultUserDefaults: UserDefaults {
    PKPaneUserDefaults.resolve()
  }
}
