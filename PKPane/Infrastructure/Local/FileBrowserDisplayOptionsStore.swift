import Foundation

final class FileBrowserDisplayOptionsStore {
  private let defaults: UserDefaults
  private let key = "file-browser-display-options"

  init(defaults: UserDefaults? = nil) {
    self.defaults = defaults ?? Self.defaultUserDefaults
  }

  func save(_ options: FileBrowserDisplayOptions) {
    guard let data = try? JSONEncoder().encode(options) else {
      return
    }
    defaults.set(data, forKey: key)
  }

  func load() -> FileBrowserDisplayOptions {
    guard let data = defaults.data(forKey: key),
      let options = try? JSONDecoder().decode(FileBrowserDisplayOptions.self, from: data)
    else {
      return FileBrowserDisplayOptions()
    }
    return options
  }

  func remove() {
    defaults.removeObject(forKey: key)
  }

  private static var defaultUserDefaults: UserDefaults {
    PKPaneUserDefaults.resolve()
  }
}
