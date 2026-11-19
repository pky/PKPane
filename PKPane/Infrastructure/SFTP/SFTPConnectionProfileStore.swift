import Foundation

final class SFTPConnectionProfileStore {
  private let defaults: UserDefaults
  private let key = "sftp-connection-targets"
  private let legacyKey = "sftp-connection-target"

  init(defaults: UserDefaults? = nil) {
    self.defaults = defaults ?? Self.defaultUserDefaults
  }

  func save(_ target: SFTPConnectionTarget) {
    var targets = loadAll()
    targets.removeAll { $0 == target }
    targets.append(target)
    guard let data = try? JSONEncoder().encode(targets) else {
      return
    }
    defaults.set(data, forKey: key)
  }

  func load() -> SFTPConnectionTarget? {
    loadAll().last
  }

  func loadAll() -> [SFTPConnectionTarget] {
    if let data = defaults.data(forKey: key),
      let targets = try? JSONDecoder().decode([SFTPConnectionTarget].self, from: data)
    {
      return targets
    }
    guard let data = defaults.data(forKey: legacyKey),
      let target = try? JSONDecoder().decode(SFTPConnectionTarget.self, from: data)
    else {
      return []
    }
    return [target]
  }

  func replace(_ existingTarget: SFTPConnectionTarget, with target: SFTPConnectionTarget) {
    var targets = loadAll()
    targets.removeAll { $0 == existingTarget || $0 == target }
    targets.append(target)
    guard let data = try? JSONEncoder().encode(targets) else { return }
    defaults.set(data, forKey: key)
  }

  func remove(_ target: SFTPConnectionTarget) {
    var targets = loadAll()
    targets.removeAll { $0 == target }
    guard let data = try? JSONEncoder().encode(targets) else { return }
    defaults.set(data, forKey: key)
  }

  private static var defaultUserDefaults: UserDefaults {
    PKPaneUserDefaults.resolve()
  }
}
