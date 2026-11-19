import Foundation

final class NASConnectionProfileStore {
  private let defaults: UserDefaults
  private let key = "nas-connection-profiles"

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func load() -> [NASConnectionProfile] {
    guard let data = defaults.data(forKey: key) else {
      return []
    }
    return (try? JSONDecoder().decode([NASConnectionProfile].self, from: data)) ?? []
  }

  func save(_ profile: NASConnectionProfile) {
    var profiles = load()
    if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
      profiles[index] = profile
    } else {
      profiles.append(profile)
    }
    persist(profiles)
  }

  func remove(id: NASConnectionProfile.ID) {
    persist(load().filter { $0.id != id })
  }

  private func persist(_ profiles: [NASConnectionProfile]) {
    guard let data = try? JSONEncoder().encode(profiles) else {
      return
    }
    defaults.set(data, forKey: key)
  }
}
