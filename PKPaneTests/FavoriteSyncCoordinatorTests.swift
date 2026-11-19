import Foundation
import Testing

@testable import PKPane

@MainActor
struct FavoriteSyncCoordinatorTests {
  @Test("起動時にローカルとKVSを統合して1キーへ書き出す")
  func importsAndWritesAtStartup() async throws {
    let store = FakeFavoriteSyncKeyValueStore()
    let localStore = FakeFavoriteSyncLocalStore()
    let remote = FavoriteSyncMerger.initialDocument(
      favorites: [favorite("/remote")], at: Date(timeIntervalSince1970: 10)
    ).document
    store.values[FavoriteSyncCoordinator.key] = try FavoriteSyncCodec.encode(remote)
    let coordinator = makeCoordinator(store: store, localStore: localStore)
    var applied: [PortableFavorite] = []

    coordinator.start(localFavorites: [favorite("/local")]) {
      applied = $0.items.map(\.favorite)
    }
    await coordinator.waitForPendingWrite()

    #expect(store.synchronizeCallCount == 1)
    #expect(Set(applied.map(\.path)) == ["/local", "/remote"])
    #expect(store.setCallCount == 1)
    let written = try #require(store.values[FavoriteSyncCoordinator.key])
    let writtenDocument = try FavoriteSyncCodec.decode(written)
    #expect(Set(writtenDocument.items.map(\.favorite.path)) == ["/local", "/remote"])
    #expect(localStore.savedData != nil)
  }

  @Test("連続するローカル変更をデバウンスして最後の一覧だけ保存する")
  func debouncesLocalWrites() async throws {
    let store = FakeFavoriteSyncKeyValueStore()
    let coordinator = makeCoordinator(store: store)
    coordinator.start(localFavorites: []) { _ in }
    await coordinator.waitForPendingWrite()
    store.setCallCount = 0

    coordinator.localFavoritesDidChange([favorite("/first")])
    coordinator.localFavoritesDidChange([favorite("/first"), favorite("/second")])
    await coordinator.waitForPendingWrite()

    #expect(store.setCallCount == 1)
    let written = try #require(store.values[FavoriteSyncCoordinator.key])
    let document = try FavoriteSyncCodec.decode(written)
    #expect(document.items.map(\.favorite.path) == ["/first", "/second"])
  }

  @Test("KVSの外部変更通知を現在一覧へ反映して統合結果を書き戻す")
  func appliesExternalChanges() async throws {
    let store = FakeFavoriteSyncKeyValueStore()
    let coordinator = makeCoordinator(store: store)
    var snapshots: [[PortableFavorite]] = []
    coordinator.start(localFavorites: [favorite("/local")]) {
      snapshots.append($0.items.map(\.favorite))
    }
    await coordinator.waitForPendingWrite()
    store.setCallCount = 0
    let remote = FavoriteSyncMerger.initialDocument(
      favorites: [favorite("/remote")], at: Date(timeIntervalSince1970: 20)
    ).document
    store.values[FavoriteSyncCoordinator.key] = try FavoriteSyncCodec.encode(remote)

    store.sendExternalChange()
    await coordinator.waitForPendingWrite()

    #expect(Set(snapshots.last?.map(\.path) ?? []) == ["/local", "/remote"])
    #expect(store.setCallCount == 1)
  }

  @Test("ローカル同期履歴がない初回起動でもリモート削除を復活させない")
  func remoteTombstoneWinsWithoutLocalHistory() throws {
    let store = FakeFavoriteSyncKeyValueStore()
    let original = FavoriteSyncMerger.initialDocument(
      favorites: [favorite("/deleted")], at: Date(timeIntervalSince1970: 10)
    ).document
    let deleted = FavoriteSyncMerger.applyingLocalFavorites(
      [], to: original, at: Date(timeIntervalSince1970: 20)
    ).document
    store.values[FavoriteSyncCoordinator.key] = try FavoriteSyncCodec.encode(deleted)
    let coordinator = makeCoordinator(store: store)
    var applied: [PortableFavorite] = []

    coordinator.start(localFavorites: [favorite("/deleted")]) {
      applied = $0.items.map(\.favorite)
    }

    #expect(applied.isEmpty)
  }

  @Test("entitlementがなければKVSとローカル同期層を生成しない")
  func unavailableWithoutEntitlement() {
    let entitlementChecker = FakeFavoriteSyncEntitlementChecker(hasEntitlement: false)
    var storeFactoryCallCount = 0
    var localStoreFactoryCallCount = 0

    let coordinator = FavoriteSyncCoordinatorFactory.makeIfAvailable(
      entitlementChecker: entitlementChecker,
      isICloudAccountAvailable: { true },
      storeFactory: {
        storeFactoryCallCount += 1
        return FakeFavoriteSyncKeyValueStore()
      },
      localStoreFactory: {
        localStoreFactoryCallCount += 1
        return FakeFavoriteSyncLocalStore()
      })

    #expect(coordinator == nil)
    #expect(storeFactoryCallCount == 0)
    #expect(localStoreFactoryCallCount == 0)
  }

  @Test("iCloud未サインインならKVSを生成しない")
  func unavailableWithoutICloudAccount() {
    var storeFactoryCallCount = 0
    let coordinator = FavoriteSyncCoordinatorFactory.makeIfAvailable(
      entitlementChecker: FakeFavoriteSyncEntitlementChecker(hasEntitlement: true),
      isICloudAccountAvailable: { false },
      storeFactory: {
        storeFactoryCallCount += 1
        return FakeFavoriteSyncKeyValueStore()
      })

    #expect(coordinator == nil)
    #expect(storeFactoryCallCount == 0)
  }

  private func makeCoordinator(
    store: FakeFavoriteSyncKeyValueStore,
    localStore: FakeFavoriteSyncLocalStore = FakeFavoriteSyncLocalStore()
  ) -> FavoriteSyncCoordinator {
    var timestamp = 100.0
    return FavoriteSyncCoordinator(
      store: store,
      localStore: localStore,
      debounceDuration: .milliseconds(1),
      now: {
        defer { timestamp += 1 }
        return Date(timeIntervalSince1970: timestamp)
      })
  }

  private func favorite(_ path: String) -> PortableFavorite {
    PortableFavorite(provider: .local, path: path, displayName: path)
  }
}

@MainActor
private final class FakeFavoriteSyncKeyValueStore: FavoriteSyncKeyValueStoring {
  var values: [String: Data] = [:]
  var synchronizeCallCount = 0
  var setCallCount = 0
  private var externalChangeHandler: (@MainActor @Sendable () -> Void)?

  func data(forKey key: String) -> Data? {
    values[key]
  }

  func set(_ data: Data, forKey key: String) {
    setCallCount += 1
    values[key] = data
  }

  func synchronize() {
    synchronizeCallCount += 1
  }

  func setExternalChangeHandler(
    forKey _: String,
    _ handler: (@MainActor @Sendable () -> Void)?
  ) {
    externalChangeHandler = handler
  }

  func sendExternalChange() {
    externalChangeHandler?()
  }
}

@MainActor
private final class FakeFavoriteSyncLocalStore: FavoriteSyncLocalDocumentStoring {
  var savedData: Data?

  func loadDocumentData() -> Data? {
    savedData
  }

  func saveDocumentData(_ data: Data) {
    savedData = data
  }
}

private struct FakeFavoriteSyncEntitlementChecker: FavoriteSyncEntitlementChecking {
  let hasEntitlement: Bool

  func hasUbiquityKeyValueStoreEntitlement() -> Bool {
    hasEntitlement
  }
}
