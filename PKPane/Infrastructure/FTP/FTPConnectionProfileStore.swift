import Foundation

final class FTPConnectionProfileStore {
  private let defaults: UserDefaults
  private let key = "ftp-connection-targets"

  init(defaults: UserDefaults? = nil) {
    self.defaults = defaults ?? PKPaneUserDefaults.resolve()
  }

  func loadAll() -> [FTPConnectionTarget] {
    guard let data = defaults.data(forKey: key),
      let targets = try? JSONDecoder().decode([FTPConnectionTarget].self, from: data)
    else {
      return []
    }
    return targets
  }

  func save(_ target: FTPConnectionTarget) {
    var targets = loadAll()
    targets.removeAll { $0 == target }
    targets.append(target)
    persist(targets)
  }

  func replace(_ existingTarget: FTPConnectionTarget, with target: FTPConnectionTarget) {
    var targets = loadAll()
    targets.removeAll { $0 == existingTarget || $0 == target }
    targets.append(target)
    persist(targets)
  }

  func remove(_ target: FTPConnectionTarget) {
    var targets = loadAll()
    targets.removeAll { $0 == target }
    persist(targets)
  }

  private func persist(_ targets: [FTPConnectionTarget]) {
    guard let data = try? JSONEncoder().encode(targets) else { return }
    defaults.set(data, forKey: key)
  }
}
