import Foundation

@MainActor
final class FavoriteSyncCoordinator {
  static let key = "favorites-document-v1"
  static let maximumValueSize = 1_000_000

  private let store: any FavoriteSyncKeyValueStoring
  private let localStore: any FavoriteSyncLocalDocumentStoring
  private let debounceDuration: Duration
  private let now: @MainActor @Sendable () -> Date

  private var document: FavoriteSyncDocument?
  private var applyDocument: (@MainActor (FavoriteSyncDocument) -> Void)?
  private var pendingWriteTask: Task<Void, Never>?
  private var pendingWriteToken: UUID?
  private var hasStarted = false

  init(
    store: any FavoriteSyncKeyValueStoring,
    localStore: any FavoriteSyncLocalDocumentStoring,
    debounceDuration: Duration = .milliseconds(300),
    now: @escaping @MainActor @Sendable () -> Date = Date.init
  ) {
    self.store = store
    self.localStore = localStore
    self.debounceDuration = debounceDuration
    self.now = now
  }

  isolated deinit {
    pendingWriteTask?.cancel()
    store.setExternalChangeHandler(forKey: Self.key, nil)
  }

  func start(
    localFavorites: [PortableFavorite],
    apply: @escaping @MainActor (FavoriteSyncDocument) -> Void
  ) {
    guard !hasStarted else { return }
    hasStarted = true
    applyDocument = apply
    store.setExternalChangeHandler(forKey: Self.key) { [weak self] in
      self?.receiveExternalChange()
    }
    store.synchronize()

    let remoteDocument = loadDocument(from: store.data(forKey: Self.key))
    let localDocument = loadDocument(from: localStore.loadDocumentData())
    let nextDocument: FavoriteSyncDocument
    if let localDocument {
      let localUpdate = FavoriteSyncMerger.applyingLocalFavorites(
        localFavorites, to: localDocument, at: now())
      logDroppedFavorites(localUpdate.droppedFavoriteCount)
      nextDocument =
        remoteDocument.map {
          FavoriteSyncMerger.merge(localUpdate.document, $0)
        } ?? localUpdate.document
    } else if let remoteDocument {
      let knownRemoteKeys = Set(
        remoteDocument.items.map(\.favorite.key) + remoteDocument.tombstones.map(\.key))
      let unknownLocalFavorites = localFavorites.filter {
        !knownRemoteKeys.contains($0.key)
      }
      let localAdditions = FavoriteSyncMerger.initialDocument(
        favorites: unknownLocalFavorites, at: now())
      logDroppedFavorites(localAdditions.droppedFavoriteCount)
      nextDocument = FavoriteSyncMerger.merge(remoteDocument, localAdditions.document)
    } else {
      let initial = FavoriteSyncMerger.initialDocument(favorites: localFavorites, at: now())
      logDroppedFavorites(initial.droppedFavoriteCount)
      nextDocument = initial.document
    }

    apply(nextDocument)
    document = nextDocument
    saveLocalDocument(nextDocument)
    scheduleWrite()
  }

  func localFavoritesDidChange(_ favorites: [PortableFavorite]) {
    guard let document else { return }
    let update = FavoriteSyncMerger.applyingLocalFavorites(favorites, to: document, at: now())
    logDroppedFavorites(update.droppedFavoriteCount)
    self.document = update.document
    saveLocalDocument(update.document)
    scheduleWrite()
  }

  func waitForPendingWrite() async {
    await pendingWriteTask?.value
  }

  private func receiveExternalChange() {
    guard let current = document,
      let remote = loadDocument(from: store.data(forKey: Self.key))
    else {
      return
    }
    let merged = FavoriteSyncMerger.merge(current, remote)
    guard merged != current else { return }
    applyDocument?(merged)
    document = merged
    saveLocalDocument(merged)
    scheduleWrite()
  }

  private func scheduleWrite() {
    pendingWriteTask?.cancel()
    let token = UUID()
    pendingWriteToken = token
    pendingWriteTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await Task.sleep(for: debounceDuration)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      writeCurrentDocument()
      if pendingWriteToken == token {
        pendingWriteTask = nil
        pendingWriteToken = nil
      }
    }
  }

  private func writeCurrentDocument() {
    guard let document, let data = try? FavoriteSyncCodec.encode(document) else { return }
    guard data.count <= Self.maximumValueSize else {
      AppLog.error(
        "お気に入り同期データがKVSの1MB上限を超えたため保存を中止しました",
        category: "FavoriteSync")
      return
    }
    store.set(data, forKey: Self.key)
  }

  private func saveLocalDocument(_ document: FavoriteSyncDocument) {
    guard let data = try? FavoriteSyncCodec.encode(document) else { return }
    localStore.saveDocumentData(data)
  }

  private func loadDocument(from data: Data?) -> FavoriteSyncDocument? {
    guard let data,
      let document = try? FavoriteSyncCodec.decode(data),
      document.version == FavoriteSyncDocument.currentVersion
    else {
      return nil
    }
    return document
  }

  private func logDroppedFavorites(_ count: Int) {
    guard count > 0 else { return }
    AppLog.warning("同期上限を超えたお気に入りを省略しました: \(count)", category: "FavoriteSync")
  }
}

@MainActor
enum FavoriteSyncCoordinatorFactory {
  static func makeIfAvailable(
    entitlementChecker: any FavoriteSyncEntitlementChecking =
      SystemFavoriteSyncEntitlementChecker(),
    isICloudAccountAvailable: @MainActor () -> Bool = {
      FileManager.default.ubiquityIdentityToken != nil
    },
    storeFactory: @MainActor () -> any FavoriteSyncKeyValueStoring = {
      UbiquitousFavoriteSyncStore()
    },
    localStoreFactory: @MainActor () -> any FavoriteSyncLocalDocumentStoring = {
      UserDefaultsFavoriteSyncLocalStore()
    },
    debounceDuration: Duration = .milliseconds(300),
    now: @escaping @MainActor @Sendable () -> Date = Date.init
  ) -> FavoriteSyncCoordinator? {
    guard entitlementChecker.hasUbiquityKeyValueStoreEntitlement(),
      isICloudAccountAvailable()
    else {
      return nil
    }
    return FavoriteSyncCoordinator(
      store: storeFactory(),
      localStore: localStoreFactory(),
      debounceDuration: debounceDuration,
      now: now)
  }
}
