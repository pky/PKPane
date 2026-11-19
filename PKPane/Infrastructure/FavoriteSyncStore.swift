import Foundation

@MainActor
protocol FavoriteSyncKeyValueStoring: AnyObject {
  func data(forKey key: String) -> Data?
  func set(_ data: Data, forKey key: String)
  func synchronize()
  func setExternalChangeHandler(
    forKey key: String,
    _ handler: (@MainActor @Sendable () -> Void)?
  )
}

@MainActor
protocol FavoriteSyncLocalDocumentStoring: AnyObject {
  func loadDocumentData() -> Data?
  func saveDocumentData(_ data: Data)
}

@MainActor
final class UbiquitousFavoriteSyncStore: FavoriteSyncKeyValueStoring {
  private let store: NSUbiquitousKeyValueStore
  private var observer: NSObjectProtocol?

  init(store: NSUbiquitousKeyValueStore = .default) {
    self.store = store
  }

  isolated deinit {
    if let observer {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  func data(forKey key: String) -> Data? {
    store.data(forKey: key)
  }

  func set(_ data: Data, forKey key: String) {
    store.set(data, forKey: key)
  }

  func synchronize() {
    store.synchronize()
  }

  func setExternalChangeHandler(
    forKey key: String,
    _ handler: (@MainActor @Sendable () -> Void)?
  ) {
    if let observer {
      NotificationCenter.default.removeObserver(observer)
      self.observer = nil
    }
    guard let handler else { return }
    observer = NotificationCenter.default.addObserver(
      forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
      object: store,
      queue: .main
    ) { notification in
      if let changedKeys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey]
        as? [String],
        !changedKeys.contains(key)
      {
        return
      }
      MainActor.assumeIsolated {
        handler()
      }
    }
  }
}

@MainActor
final class UserDefaultsFavoriteSyncLocalStore: FavoriteSyncLocalDocumentStoring {
  private let defaults: UserDefaults
  private let key: String

  init(
    defaults: UserDefaults = .standard,
    key: String = "favorite-sync-local-document"
  ) {
    self.defaults = defaults
    self.key = key
  }

  func loadDocumentData() -> Data? {
    defaults.data(forKey: key)
  }

  func saveDocumentData(_ data: Data) {
    defaults.set(data, forKey: key)
  }
}
