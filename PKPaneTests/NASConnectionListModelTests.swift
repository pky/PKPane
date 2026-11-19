import Foundation
import Testing

@testable import PKPane

@MainActor
struct NASConnectionListModelTests {
  @Test("フォーム保存とサイドバーはFinderの単一共有を再接続せず開く")
  func reusesExistingMountThroughSaveAndOpenRouting() throws {
    for savesProfile in [false, true] {
      let suite = "NASExistingMountRouting.\(UUID().uuidString)"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let form = NASConnectionFormModel()
      form.host = "smb://nas.example.invalid"
      let profile = try #require(form.makeProfile())
      let volume = SMBMountedVolume(
        volumeURL: URL(filePath: "/Volumes/ExistingDocuments"),
        remountingURL: try #require(URL(string: "smb://nas.example.invalid/Documents")))
      let mount = RecordingNASConnectionListMountService()
      let store = NASConnectionProfileStore(defaults: defaults)
      let model = NASConnectionListModel(
        profileStore: store,
        recentConnectionStore: RecentSMBConnectionStore(defaults: defaults),
        bookmarkRepository: NASConnectionBookmarkRepository(
          storage: InMemoryNASListBookmarkStore(), codec: StubNASListBookmarkCodec()),
        mountService: mount, mountedVolumeProvider: { [volume] })
      var opened: SMBMountedVolume?

      model.openConnection(
        profile, savesProfile: savesProfile, onMounted: { opened = $0 },
        onSelectMounted: { _ in Issue.record("単一共有で選択を要求してはいけません") },
        onConnected: { _ in Issue.record("既存共有を再接続してはいけません") })

      #expect(opened == volume)
      #expect(
        model.mountedVolume(containing: volume.volumeURL.appending(path: "Documents")) == volume)
      #expect(mount.shares.isEmpty)
      #expect(model.errorMessage == nil)
      #expect(store.load() == (savesProfile ? [profile] : []))
    }
  }

  @Test("共有省略サーバーの複数既存共有は明示選択へ渡し、別サーバーは除外する")
  func requestsExplicitChoiceWithoutReauthentication() throws {
    let suite = "NASMultipleExistingMounts.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let profile = try NASConnectionProfile(
      displayName: "既存NAS", host: "nas.example.invalid", shareName: "")
    let first = SMBMountedVolume(
      volumeURL: URL(filePath: "/Volumes/First"),
      remountingURL: try #require(URL(string: "smb://nas.example.invalid/First")))
    let second = SMBMountedVolume(
      volumeURL: URL(filePath: "/Volumes/Second"),
      remountingURL: try #require(URL(string: "smb://nas.example.invalid/Second")))
    let other = SMBMountedVolume(
      volumeURL: URL(filePath: "/Volumes/Other"),
      remountingURL: try #require(URL(string: "smb://other.example.invalid/Other")))
    let mount = RecordingNASConnectionListMountService()
    let model = NASConnectionListModel(
      profileStore: NASConnectionProfileStore(defaults: defaults),
      recentConnectionStore: RecentSMBConnectionStore(defaults: defaults),
      bookmarkRepository: NASConnectionBookmarkRepository(
        storage: InMemoryNASListBookmarkStore(), codec: StubNASListBookmarkCodec()),
      mountService: mount, mountedVolumeProvider: { [first, second, other] })
    var choices = [SMBMountedVolume]()

    model.openConnection(
      profile, savesProfile: true,
      onMounted: { _ in Issue.record("共有を任意に選んではいけません") },
      onSelectMounted: { choices = $0 },
      onConnected: { _ in Issue.record("既存共有を再接続してはいけません") })

    #expect(Set(choices.map(\.volumeURL)) == Set([first.volumeURL, second.volumeURL]))
    #expect(mount.shares.isEmpty)
    #expect(model.provider(for: profile) == nil)
    #expect(model.errorMessage == nil)
  }

  @Test("最近使用の共有も既存マウントを再利用し、未接続時だけ接続を開始する")
  func recentSharesReuseExistingVolumeAndMissingSharesConnect() throws {
    let suite = "NASRecentMountRouting.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let volume = SMBMountedVolume(
      volumeURL: URL(filePath: "/Volumes/ExistingDocuments"),
      remountingURL: try #require(URL(string: "smb://nas.example.invalid/Documents")))
    let mount = RecordingNASConnectionListMountService()
    let model = NASConnectionListModel(
      profileStore: NASConnectionProfileStore(defaults: defaults),
      recentConnectionStore: RecentSMBConnectionStore(defaults: defaults),
      bookmarkRepository: NASConnectionBookmarkRepository(
        storage: InMemoryNASListBookmarkStore(), codec: StubNASListBookmarkCodec()),
      mountService: mount, mountedVolumeProvider: { [volume] })
    let recent = try RecentSMBConnection(host: "nas.example.invalid", shareName: "Documents")
    var opened: URL?
    model.connect(recent) { opened = $0 }
    #expect(opened == volume.volumeURL)
    #expect(mount.shares.isEmpty)

    let profile = try NASConnectionProfile(
      displayName: "未接続", host: "missing.example.invalid", shareName: "")
    model.openConnection(
      profile, onMounted: { _ in Issue.record("未接続の共有を開いてはいけません") },
      onSelectMounted: { _ in Issue.record("未接続の共有を選んではいけません") },
      onConnected: { opened = $0 })
    #expect(mount.shares.map(\.url.absoluteString) == ["smb://missing.example.invalid"])
    #expect(opened == mount.volumeURL)
  }

  @Test("共有省略フォームの保存して接続は認証失敗しても入力を保存する")
  func savesServerOnlyFormBeforeConnectionFailure() throws {
    let suite = "NASConnectionFormPersistence.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = NASConnectionProfileStore(defaults: defaults)
    let form = NASConnectionFormModel()
    form.host = "smb://nas.example.invalid"
    let profile = try #require(form.makeProfile())
    let model = NASConnectionListModel(
      profileStore: store,
      recentConnectionStore: RecentSMBConnectionStore(defaults: defaults),
      bookmarkRepository: NASConnectionBookmarkRepository(
        storage: InMemoryNASListBookmarkStore(), codec: StubNASListBookmarkCodec()),
      mountService: FailingNASConnectionListMountService())
    var opened = false

    model.openConnection(
      profile, savesProfile: true,
      onMounted: { _ in opened = true }, onSelectMounted: { _ in },
      onConnected: { _ in opened = true })

    #expect(store.load() == [profile])
    #expect(model.profiles == [profile])
    #expect(profile.shareName.isEmpty)
    #expect(!opened)
  }

  @Test("保存済みNAS接続先を再接続して削除できる")
  func reconnectsAndRemovesProfile() throws {
    let suiteName = "NASConnectionListModelTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = NASConnectionProfileStore(defaults: defaults)
    let profile = try NASConnectionProfile(
      displayName: "開発用NAS", host: "nas.example.local", shareName: "Documents")
    store.save(profile)
    let mountService = RecordingNASConnectionListMountService()
    // connectNewはbookmarkedFolderURL()経由でbookmarkRepositoryへ実FSアクセスするため、
    // 未注入だとテスト実行環境のFSブックマーク機構に依存してしまう。InMemory実装を注入する。
    let bookmarkRepository = NASConnectionBookmarkRepository(
      storage: InMemoryNASListBookmarkStore(), codec: StubNASListBookmarkCodec())
    let model = NASConnectionListModel(
      profileStore: store, bookmarkRepository: bookmarkRepository, mountService: mountService)
    var openedVolumeURL: URL?

    #expect(model.status(for: profile) == .disconnected)

    model.connectNew(profile) { openedVolumeURL = $0 }

    #expect(mountService.shares.map(\.url) == [URL(string: "smb://nas.example.local/Documents")!])
    #expect(model.errorMessage == nil)
    #expect(store.load() == [profile])
    #expect(openedVolumeURL == mountService.volumeURL)

    model.remove(profile)

    #expect(model.profiles.isEmpty)
    #expect(store.load().isEmpty)
  }

  @Test("サーバー接続先は共有選択用URLで接続して共有名を補完せず保存する")
  func connectsAndSavesServerOnlyProfile() throws {
    let suiteName = "NASConnectionListServerTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = NASConnectionProfileStore(defaults: defaults)
    let profile = try NASConnectionProfile(
      displayName: "開発用NAS", host: "nas.example.local", shareName: "")
    let mountService = RecordingNASConnectionListMountService()
    let model = NASConnectionListModel(
      profileStore: store,
      bookmarkRepository: NASConnectionBookmarkRepository(
        storage: InMemoryNASListBookmarkStore(), codec: StubNASListBookmarkCodec()),
      mountService: mountService)
    var openedVolumeURL: URL?

    model.connectNew(profile) { openedVolumeURL = $0 }

    #expect(mountService.shares.map(\.url.absoluteString) == ["smb://nas.example.local"])
    #expect(store.load() == [profile])
    #expect(openedVolumeURL == mountService.volumeURL)
    model.reload()
    model.handleMountEvent(
      .mounted(
        SMBMountedVolume(
          volumeURL: mountService.volumeURL,
          remountingURL: URL(string: "smb://nas.example.local/Documents")!)))
    #expect(model.status(for: profile) == .disconnected)
    #expect(model.unregisteredMountedVolumes.contains { $0.volumeURL == mountService.volumeURL })
    model.disconnect(profile)
    #expect(mountService.disconnectedURLs.isEmpty)
  }

  @Test("マウント失敗した新規接続は保存しない")
  func doesNotSaveProfileWhenMountFails() throws {
    let suiteName = "NASConnectionListModelFailureTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = NASConnectionProfileStore(defaults: defaults)
    let profile = try NASConnectionProfile(
      displayName: "失敗するNAS", host: "nas.example.local", shareName: "Documents")
    let model = NASConnectionListModel(
      profileStore: store,
      mountService: FailingNASConnectionListMountService())

    model.connectNew(profile)

    #expect(store.load().isEmpty)
    #expect(
      model.errorMessage
        == ConnectionErrorClassifier.guidanceMessage(for: SMBMountError.connectionFailed(-1)))
  }

  @Test("アンマウント通知の共有URLを記録する")
  func recordsUnmountAfterReceivingVolumeNotification() throws {
    let suiteName = "NASConnectionListModelUnmountTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = NASConnectionProfileStore(defaults: defaults)
    let profile = try NASConnectionProfile(
      displayName: "開発用NAS", host: "nas.example.local", shareName: "Documents")
    store.save(profile)
    let model = NASConnectionListModel(profileStore: store)
    let volume = SMBMountedVolume(
      volumeURL: URL(fileURLWithPath: "/Volumes/Documents", isDirectory: true),
      remountingURL: URL(string: "smb://nas.example.local/Documents")!)

    model.handleMountEvent(.unmounted(volume))

    #expect(model.lastUnmountedVolumeURL == volume.volumeURL)
  }

  @Test("切断開始時に表示を直ちに切り離す")
  func detachesBeforeBackgroundUnmountCompletes() throws {
    let suiteName = "NASConnectionListModelDisconnectTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = NASConnectionProfileStore(defaults: defaults)
    let profile = try NASConnectionProfile(
      displayName: "開発用NAS", host: "nas.example.local", shareName: "Documents")
    store.save(profile)
    let mountService = RecordingNASConnectionListMountService()
    let model = NASConnectionListModel(profileStore: store, mountService: mountService)
    let volume = SMBMountedVolume(
      volumeURL: mountService.volumeURL,
      remountingURL: URL(string: "smb://nas.example.local/Documents")!)
    model.handleMountEvent(.mounted(volume))
    var detachedURL: URL?

    model.disconnect(profile) { detachedURL = $0 }

    #expect(detachedURL == mountService.volumeURL)
    #expect(model.status(for: profile) == .disconnected)
    #expect(mountService.disconnectedURLs == [mountService.volumeURL])
  }

  @Test("NAS解除を共通接続ライフサイクルへ通知する")
  func reportsNASDisconnectionToSharedLifecycle() throws {
    let suiteName = "NASConnectionListModelLifecycleTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = NASConnectionProfileStore(defaults: defaults)
    let profile = try NASConnectionProfile(
      displayName: "開発用NAS", host: "nas.example.local", shareName: "Documents")
    store.save(profile)
    let mountService = RecordingNASConnectionListMountService()
    let lifecycle = FileProviderConnectionLifecycle()
    let model = NASConnectionListModel(
      profileStore: store,
      mountService: mountService,
      connectionLifecycle: lifecycle)
    let volume = SMBMountedVolume(
      volumeURL: mountService.volumeURL,
      remountingURL: URL(string: "smb://nas.example.local/Documents")!)
    model.handleMountEvent(.mounted(volume))

    model.disconnect(profile)

    #expect(
      lifecycle.latestDisconnection?.connectionID
        == FileProviderConnectionID.smb(volumeURL: mountService.volumeURL))
  }

  @Test("切断中の共有履歴を再接続して元のサブフォルダを開く")
  func reconnectsSavedNetworkLocation() throws {
    let suiteName = "NASConnectionListModelRecentLocationTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let recentStore = RecentSMBConnectionStore(defaults: defaults)
    let connection = try RecentSMBConnection(host: "nas.example.local", shareName: "Documents")
    recentStore.record(connection)
    let mountService = RecordingNASConnectionListMountService()
    let model = NASConnectionListModel(
      recentConnectionStore: recentStore,
      mountService: mountService)
    let location = SavedFolderLocation(
      id: UUID(),
      name: "設計書",
      url: nil,
      lastKnownPath: "/Volumes/Documents/Projects/Design")
    var openedURL: URL?

    let didStartConnection = model.connectSavedLocation(location) { openedURL = $0 }

    #expect(didStartConnection)
    #expect(mountService.shares.map(\.url) == [URL(string: "smb://nas.example.local/Documents")!])
    #expect(
      openedURL
        == mountService.volumeURL.appendingPathComponent("Projects/Design", isDirectory: true))
  }

  @Test("接続中の共有履歴は再接続要求を重複させない")
  func preventsDuplicateSavedNetworkLocationConnections() throws {
    let suiteName = "NASConnectionListModelDuplicateConnectionTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let recentStore = RecentSMBConnectionStore(defaults: defaults)
    let connection = try RecentSMBConnection(host: "nas.example.local", shareName: "Documents")
    recentStore.record(connection)
    let mountService = DeferredNASConnectionListMountService()
    let model = NASConnectionListModel(
      recentConnectionStore: recentStore,
      mountService: mountService)
    let location = SavedFolderLocation(
      id: UUID(),
      name: "設計書",
      url: nil,
      lastKnownPath: "/Volumes/Documents/Projects/Design")

    #expect(model.connectSavedLocation(location, onConnected: { _ in }))
    #expect(model.connectSavedLocation(location, onConnected: { _ in }))

    #expect(mountService.shares.map(\.url) == [URL(string: "smb://nas.example.local/Documents")!])
    #expect(model.isConnecting(connection))

    mountService.completeConnection()

    #expect(!model.isConnecting(connection))
  }

  @Test("NAS情報を保存した履歴は接続一覧に依存せず再接続する")
  func reconnectsSavedNetworkLocationWithSMBLocation() {
    let mountService = RecordingNASConnectionListMountService()
    let model = NASConnectionListModel(mountService: mountService)
    let location = SavedFolderLocation(
      id: UUID(),
      name: "設計書",
      url: nil,
      smbLocation: SMBFolderLocation(
        host: "nas.example.local",
        shareName: "Documents",
        relativePathComponents: ["Projects", "Design"])
    )
    var openedURL: URL?

    #expect(model.connectSavedLocation(location) { openedURL = $0 })

    #expect(mountService.shares.map(\.url) == [URL(string: "smb://nas.example.local/Documents")!])
    #expect(
      openedURL
        == mountService.volumeURL.appendingPathComponent("Projects/Design", isDirectory: true))
  }

  @Test("プロフィールに前回ブラウズしたフォルダのブックマークがあっても履歴の場所はボリュームルート基準で開く")
  func reconnectsSavedNetworkLocationViaProfileUsesVolumeRootNotBookmark() throws {
    let suiteName = "NASConnectionListModelProfileRecentLocationTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = NASConnectionProfileStore(defaults: defaults)
    let profile = try NASConnectionProfile(
      displayName: "開発用NAS", host: "nas.example.local", shareName: "Documents")
    store.save(profile)
    let mountService = RecordingNASConnectionListMountService()
    let bookmarkRepository = NASConnectionBookmarkRepository(
      storage: InMemoryNASListBookmarkStore(), codec: StubNASListBookmarkCodec())
    // 共有UIで「前回ブラウズしたフォルダ」として別の場所を既にブックマーク済みの状態を再現する。
    try bookmarkRepository.save(
      mountService.volumeURL.appendingPathComponent("PreviousFolder", isDirectory: true),
      for: profile.id)
    let model = NASConnectionListModel(
      profileStore: store, bookmarkRepository: bookmarkRepository, mountService: mountService)
    let location = SavedFolderLocation(
      id: UUID(),
      name: "設計書",
      url: nil,
      lastKnownPath: "/Volumes/Documents/Projects/Design")
    var openedURL: URL?

    let didStartConnection = model.connectSavedLocation(location) { openedURL = $0 }

    #expect(didStartConnection)
    #expect(mountService.shares.map(\.url) == [URL(string: "smb://nas.example.local/Documents")!])
    #expect(
      openedURL
        == mountService.volumeURL.appendingPathComponent("Projects/Design", isDirectory: true))
  }

  @Test("共有UI経由の再接続は前回ブラウズしたフォルダのブックマークへ復元する")
  func connectRestoresBookmarkedFolderForSharedUI() throws {
    let suiteName = "NASConnectionListModelBookmarkRestoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = NASConnectionProfileStore(defaults: defaults)
    let profile = try NASConnectionProfile(
      displayName: "開発用NAS", host: "nas.example.local", shareName: "Documents")
    store.save(profile)
    let mountService = RecordingNASConnectionListMountService()
    let bookmarkRepository = NASConnectionBookmarkRepository(
      storage: InMemoryNASListBookmarkStore(), codec: StubNASListBookmarkCodec())
    let previousFolderURL = URL(filePath: "/Volumes/Documents/PreviousFolder")
    try bookmarkRepository.save(previousFolderURL, for: profile.id)
    let model = NASConnectionListModel(
      profileStore: store, bookmarkRepository: bookmarkRepository, mountService: mountService)
    var openedURL: URL?

    model.connect(profile) { openedURL = $0 }

    #expect(openedURL == previousFolderURL.standardizedFileURL)
  }

  @Test("有効なローカル保存場所はSMB情報を持っていても再接続しない")
  func doesNotReconnectAvailableLocalLocation() throws {
    let mountService = RecordingNASConnectionListMountService()
    let model = NASConnectionListModel(mountService: mountService)
    let location = SavedFolderLocation(
      id: UUID(),
      name: "Desktop",
      url: URL(fileURLWithPath: "/Users/test/Desktop", isDirectory: true),
      smbLocation: SMBFolderLocation(
        host: "nas.example",
        shareName: "Multimedia",
        relativePathComponents: []))

    #expect(!model.connectSavedLocation(location, onConnected: { _ in }))
    #expect(mountService.shares.isEmpty)
  }

}

@MainActor
private final class RecordingNASConnectionListMountService: SMBMountConnecting {
  private(set) var shares: [SMBShare] = []
  private(set) var disconnectedURLs: [URL] = []
  let volumeURL = URL(fileURLWithPath: "/Volumes/Documents", isDirectory: true)

  func connect(
    to share: SMBShare,
    completion: @escaping @MainActor (Result<[URL], SMBMountError>) -> Void
  ) {
    shares.append(share)
    completion(.success([volumeURL]))
  }

  func disconnect(
    volumeURL: URL,
    completion: @escaping @MainActor (Result<Void, SMBMountError>) -> Void
  ) {
    disconnectedURLs.append(volumeURL)
    completion(.success(()))
  }
}

@MainActor
private final class FailingNASConnectionListMountService: SMBMountConnecting {
  func connect(
    to share: SMBShare,
    completion: @escaping @MainActor (Result<[URL], SMBMountError>) -> Void
  ) {
    completion(.failure(.connectionFailed(-1)))
  }

  func disconnect(
    volumeURL: URL,
    completion: @escaping @MainActor (Result<Void, SMBMountError>) -> Void
  ) {
    completion(.success(()))
  }
}

@MainActor
private final class DeferredNASConnectionListMountService: SMBMountConnecting {
  private(set) var shares: [SMBShare] = []
  private var connectionCompletion: (@MainActor (Result<[URL], SMBMountError>) -> Void)?

  func connect(
    to share: SMBShare,
    completion: @escaping @MainActor (Result<[URL], SMBMountError>) -> Void
  ) {
    shares.append(share)
    connectionCompletion = completion
  }

  func disconnect(
    volumeURL: URL,
    completion: @escaping @MainActor (Result<Void, SMBMountError>) -> Void
  ) {
    completion(.success(()))
  }

  func completeConnection() {
    connectionCompletion?(.success([URL(fileURLWithPath: "/Volumes/Documents")]))
    connectionCompletion = nil
  }
}

private final class StubNASListBookmarkCodec: FolderBookmarkCoding {
  func createBookmark(for url: URL) throws -> Data {
    url.path.data(using: .utf8)!
  }

  func resolveBookmark(_ data: Data) throws -> ResolvedFolderBookmark {
    let path = String(decoding: data, as: UTF8.self)
    return ResolvedFolderBookmark(url: URL(filePath: path), isStale: false)
  }
}

private final class InMemoryNASListBookmarkStore: NASConnectionBookmarkStoring {
  private var data: [NASConnectionProfile.ID: Data] = [:]

  func loadBookmarkData(for profileID: NASConnectionProfile.ID) -> Data? {
    data[profileID]
  }

  func saveBookmarkData(_ data: Data, for profileID: NASConnectionProfile.ID) {
    self.data[profileID] = data
  }

  func removeBookmarkData(for profileID: NASConnectionProfile.ID) {
    data[profileID] = nil
  }
}
