import Foundation

final class RecentSMBConnectionStore {
  private let defaults: UserDefaults
  private let key = "recent-smb-connections"
  private let maximumCount = 5

  init(defaults: UserDefaults? = nil) {
    self.defaults = defaults ?? Self.defaultUserDefaults
  }

  func load() -> [RecentSMBConnection] {
    guard let data = defaults.data(forKey: key) else { return [] }
    return (try? JSONDecoder().decode([RecentSMBConnection].self, from: data)) ?? []
  }

  @discardableResult
  func record(_ connection: RecentSMBConnection) -> [RecentSMBConnection] {
    var connections = load()
    connections.removeAll { $0.id == connection.id }
    connections.insert(connection, at: 0)
    connections = Array(connections.prefix(maximumCount))
    guard let data = try? JSONEncoder().encode(connections) else { return connections }
    defaults.set(data, forKey: key)
    return connections
  }

  @discardableResult
  func remove(id: String) -> [RecentSMBConnection] {
    let connections = load().filter { $0.id != id }
    if connections.isEmpty {
      defaults.removeObject(forKey: key)
    } else if let data = try? JSONEncoder().encode(connections) {
      defaults.set(data, forKey: key)
    }
    return connections
  }

  private static var defaultUserDefaults: UserDefaults {
    PKPaneUserDefaults.resolve()
  }
}
