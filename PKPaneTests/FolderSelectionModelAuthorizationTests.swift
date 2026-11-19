import Foundation
import Testing

@testable import PKPane

@MainActor
struct FolderSelectionModelAuthorizationTests {
  @Test("未許可のお気に入りは対象の許可後に同じIDで開き直す")
  func authorizesSavedFavorite() throws {
    let fixture = makeFixture()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
    let target = fixture.home.appending(path: "Documents")
    _ = try fixture.favorites.add(target, allowingMissingAuthorization: true)
    var granted = false
    let model = makeModel(
      fixture, isGranted: { granted },
      authorize: { requested in
        #expect(requested == fixture.home)
        granted = true
        fixture.codec.canCreate = true
        return target
      })
    model.restoreSavedFolder()
    let location = try #require(model.favoriteLocations.first)

    #expect(model.openSavedLocation(location) == target)
    #expect(model.selectedFolderURL == target)
    #expect(model.accessRootURL == target)
    #expect(model.favoriteLocations.first?.id == location.id)
    #expect(model.favoriteLocations.first?.url == target)
    #expect(model.errorMessage == nil)
  }

  @Test("許可の取消と異なるフォルダの選択は元のお気に入りと表示先を変えない")
  func cancellationAndUnrelatedSelectionPreserveLocation() throws {
    for unrelated in [false, true] {
      let fixture = makeFixture()
      defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
      let target = fixture.home.appending(path: "Documents")
      _ = try fixture.favorites.add(target, allowingMissingAuthorization: true)
      let model = makeModel(
        fixture, isGranted: { false },
        authorize: { _ in
          unrelated ? fixture.home.appending(path: "Other") : nil
        })
      model.restoreSavedFolder()
      let before = model.favoriteLocations

      #expect(model.openSavedLocation(try #require(before.first)) == nil)
      #expect(model.favoriteLocations == before)
      #expect(model.selectedFolderURL == nil)
    }
  }

  @Test("親フォルダを許可してもお気に入りの対象は書類のまま保ちリースを継承できる")
  func parentAuthorizationKeepsTargetAndAccessLease() throws {
    let fixture = makeFixture()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
    let target = fixture.home.appending(path: "Documents")
    _ = try fixture.favorites.add(target, allowingMissingAuthorization: true)
    var granted = false
    var stopped: [URL] = []
    let manager = FolderBookmarkAccessManager(
      startAccess: { _ in granted }, stopAccess: { stopped.append($0) },
      isSandboxed: { true }, canReadDirectory: { _ in granted })
    let model = makeModel(
      fixture, accessManager: manager, isGranted: { granted },
      authorize: { _ in
        granted = true
        fixture.codec.canCreate = true
        return fixture.home
      })
    model.restoreSavedFolder()
    #expect(model.openSavedLocation(try #require(model.favoriteLocations.first)) == target)
    #expect(model.accessRootURL == fixture.home)
    #expect(model.favoriteLocations.first?.url == target)
    var lease = model.accessLease(for: target)
    #expect(lease != nil)
    #expect(model.accessLease(for: URL(filePath: "/unrelated")) == nil)
    let other = URL(filePath: "/tmp/sidebar-other")
    #expect(model.openLocalFolder(at: other) == other)
    #expect(!stopped.contains(fixture.home))
    lease = nil
    // ホームは個別ペインとは別に保持し、兄弟への移動にも使う。
    #expect(!stopped.contains(fixture.home))
  }

  @Test("許可後のブックマーク保存失敗では元のお気に入りと選択を保持する")
  func bookmarkFailureDoesNotOpenTarget() throws {
    let fixture = makeFixture()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
    let target = fixture.home.appending(path: "Documents")
    _ = try fixture.favorites.add(target, allowingMissingAuthorization: true)
    let model = makeModel(fixture, isGranted: { true }, authorize: { _ in target })
    model.restoreSavedFolder()
    let before = model.favoriteLocations

    #expect(model.openSavedLocation(try #require(before.first)) == nil)
    #expect(model.favoriteLocations == before)
    #expect(model.selectedFolderURL == nil)
    #expect(model.errorMessage != nil)
  }

  @Test("自動生成済みコンテナのお気に入りだけを修復し実ホームの削除済み項目は戻さない")
  func repairsOnlySeededContainerFavorites() throws {
    let fixture = makeFixture()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
    let container = fixture.home.appending(
      path: "Library/Containers/\(Bundle.main.bundleIdentifier ?? "com.pky.PKPane")/Data")
    let manualData = fixture.home.appending(path: "Project/Data")
    _ = try fixture.favorites.add(container, allowingMissingAuthorization: true)
    _ = try fixture.favorites.add(manualData, allowingMissingAuthorization: true)
    let deletedDownloads = fixture.home.appending(path: "Downloads")
    fixture.defaults.set(
      [container.path, deletedDownloads.path], forKey: "favorite-defaults-seeded-paths")
    let model = makeModel(fixture, isGranted: { false }, authorize: { _ in nil })

    model.seedDefaultFavoritesIfNeeded(environment: [:])

    let paths = model.favoriteLocations.compactMap(\.lastKnownPath)
    #expect(!paths.contains(container.path))
    #expect(paths.contains(fixture.home.path))
    #expect(paths.contains(manualData.path))
    #expect(!paths.contains(deletedDownloads.path))
    let seeded = fixture.defaults.stringArray(forKey: "favorite-defaults-seeded-paths") ?? []
    #expect(!seeded.contains(container.path))
    #expect(seeded.contains(deletedDownloads.path))
  }

  @Test("起動時に旧コンテナDataの選択ブックマークを復元せず一般Dataは復元する")
  func skipsRestoringOwnContainerHome() throws {
    for isContainer in [false, true] {
      let fixture = makeFixture()
      defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
      fixture.codec.canCreate = true
      let selected =
        isContainer
        ? fixture.home.appending(
          path: "Library/Containers/\(Bundle.main.bundleIdentifier ?? "com.pky.PKPane")/Data")
        : fixture.home.appending(path: "Data")
      fixture.defaults.set(Data(selected.path.utf8), forKey: "selected-folder-bookmark")
      let model = makeModel(
        fixture, isGranted: { true },
        authorize: { _ in
          Issue.record("起動時に許可パネルを出してはいけません")
          return nil
        })

      model.restoreSavedFolder()

      #expect(model.selectedFolderURL == (isContainer ? nil : selected))
      #expect(model.accessRootURL == (isContainer ? nil : selected))
    }
  }

  @Test("Sandboxのscope開始がfalseでも実際に開けるフォルダは許可済みとして扱う")
  func acceptsReadableFolderWithoutAdditionalScope() throws {
    var stopped = false
    let manager = FolderBookmarkAccessManager(
      startAccess: { _ in false }, stopAccess: { _ in stopped = true },
      isSandboxed: { true }, canReadDirectory: { _ in true })
    let url = URL(filePath: "/tmp/already-readable")
    try manager.beginAccess(to: url)
    manager.endAccess(to: url)
    #expect(!stopped)
  }

  @Test("標準お気に入りはホーム一回の許可で未解決の兄弟と再訪を開ける")
  func sharesHomeAuthorizationAcrossUnresolvedFavorites() throws {
    let fixture = makeFixture()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
    let documents = fixture.home.appending(path: "Documents")
    let desktop = fixture.home.appending(path: "Desktop")
    _ = try fixture.favorites.add(documents, allowingMissingAuthorization: true)
    _ = try fixture.favorites.add(desktop, allowingMissingAuthorization: true)
    var granted = false
    var prompts = 0
    let model = makeModel(
      fixture, isGranted: { granted },
      authorize: { requested in
        #expect(requested == fixture.home)
        prompts += 1
        granted = true
        fixture.codec.canCreate = true
        return fixture.home
      })
    model.restoreSavedFolder()
    let locations = model.favoriteLocations
    #expect(model.openSavedLocation(try #require(locations.first)) == documents)
    #expect(model.openLocalFolder(at: URL(filePath: "/tmp/sidebar-outside")) != nil)
    #expect(model.openSavedLocation(try #require(locations.last)) == desktop)
    #expect(model.accessRootURL == fixture.home)
    #expect(prompts == 1)
    #expect(fixture.defaults.data(forKey: "home-folder-bookmark") == Data(fixture.home.path.utf8))
  }

  @Test("ホーム権限は別フォルダ選択後の再起動でも先に復元する")
  func restoresIndependentHomeAuthorization() throws {
    let fixture = makeFixture()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
    let documents = fixture.home.appending(path: "Documents")
    _ = try fixture.favorites.add(documents, allowingMissingAuthorization: true)
    fixture.codec.canCreate = true
    let outside = URL(filePath: "/tmp/sidebar-outside")
    fixture.defaults.set(Data(fixture.home.path.utf8), forKey: "home-folder-bookmark")
    fixture.defaults.set(Data(outside.path.utf8), forKey: "selected-folder-bookmark")
    var started: [URL] = []
    let manager = FolderBookmarkAccessManager(
      startAccess: {
        started.append($0)
        return true
      }, stopAccess: { _ in },
      isSandboxed: { true }, canReadDirectory: { _ in true })
    let model = makeModel(
      fixture, accessManager: manager, isGranted: { true },
      authorize: { _ in
        Issue.record("保存済みのホーム許可で再案内してはいけません")
        return nil
      })
    model.restoreSavedFolder()

    #expect(started.first == fixture.home)
    #expect(model.selectedFolderURL == outside)
    #expect(!model.requestHomeAccessAtLaunchIfNeeded())
    #expect(model.openSavedLocation(try #require(model.favoriteLocations.first)) == documents)
    #expect(model.accessRootURL == fixture.home)
  }

  @Test("前版のホーム選択ブックマークは起動案内なしで専用保存先へ移行する")
  func migratesPreviouslySelectedHomeAuthorization() {
    let fixture = makeFixture()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
    fixture.codec.canCreate = true
    fixture.defaults.set(Data(fixture.home.path.utf8), forKey: "selected-folder-bookmark")
    let model = makeModel(
      fixture, isGranted: { true },
      authorize: { _ in
        Issue.record("ホームの既存許可を再要求してはいけません")
        return nil
      })

    model.restoreSavedFolder()

    #expect(!model.requestHomeAccessAtLaunchIfNeeded())
    #expect(fixture.defaults.data(forKey: "home-folder-bookmark") == Data(fixture.home.path.utf8))
  }

  @Test("起動時のホーム許可は一回だけ案内し既存選択を保持する")
  func requestsHomeAtLaunchWithoutChangingSelection() throws {
    let fixture = makeFixture()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
    fixture.codec.canCreate = true
    let documents = fixture.home.appending(path: "Documents")
    fixture.defaults.set(Data(documents.path.utf8), forKey: "selected-folder-bookmark")
    var prompts = 0
    let model = makeModel(
      fixture, isGranted: { true },
      authorize: { requested in
        #expect(requested == fixture.home)
        prompts += 1
        return fixture.home
      })
    model.restoreSavedFolder()

    // ホーム自体の可読性だけではユーザーの明示許可があると判定しない。
    #expect(model.requestHomeAccessAtLaunchIfNeeded())
    #expect(!model.requestHomeAccessAtLaunchIfNeeded())
    #expect(prompts == 1)
    #expect(model.selectedFolderURL == documents)
    #expect(fixture.defaults.data(forKey: "selected-folder-bookmark") == Data(documents.path.utf8))
  }

  @Test("起動許可の取消は同一起動中に繰り返さず次回起動で再案内する")
  func cancellationAtLaunchIsRequestedOnlyOncePerModel() {
    let fixture = makeFixture()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
    var prompts = 0
    for _ in 0..<2 {
      let model = makeModel(
        fixture, isGranted: { false },
        authorize: { _ in
          prompts += 1
          return nil
        })
      model.restoreSavedFolder()
      #expect(!model.requestHomeAccessAtLaunchIfNeeded())
      #expect(!model.requestHomeAccessAtLaunchIfNeeded())
      #expect(model.selectedFolderURL == nil)
    }
    #expect(prompts == 2)
    #expect(fixture.defaults.data(forKey: "home-folder-bookmark") == nil)
  }

  @Test("起動案内で子を選んでも選択保存を上書きせずその範囲だけ許可する")
  func childSelectionAtLaunchPreservesSavedSelection() throws {
    let fixture = makeFixture()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
    let documents = fixture.home.appending(path: "Documents")
    _ = try fixture.favorites.add(documents, allowingMissingAuthorization: true)
    fixture.codec.canCreate = true
    let outside = URL(filePath: "/tmp/sidebar-outside")
    fixture.defaults.set(Data(outside.path.utf8), forKey: "selected-folder-bookmark")
    let model = makeModel(fixture, isGranted: { true }, authorize: { _ in documents })
    model.restoreSavedFolder()

    #expect(model.requestHomeAccessAtLaunchIfNeeded())
    #expect(model.selectedFolderURL == outside)
    #expect(fixture.defaults.data(forKey: "selected-folder-bookmark") == Data(outside.path.utf8))
    #expect(fixture.defaults.data(forKey: "home-folder-bookmark") == nil)
    #expect(model.openSavedLocation(try #require(model.favoriteLocations.first)) == documents)
    #expect(model.accessRootURL == documents)
  }

  @Test("個別に許可済みのお気に入りはホームの追加許可なしで開く")
  func individuallyAuthorizedFavoriteDoesNotPrompt() throws {
    let fixture = makeFixture()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
    fixture.codec.canCreate = true
    let documents = fixture.home.appending(path: "Documents")
    _ = try fixture.favorites.add(documents)
    let model = makeModel(
      fixture, isGranted: { true },
      authorize: { _ in
        Issue.record("個別許可済みのフォルダでパネルを出してはいけません")
        return nil
      })
    model.restoreSavedFolder()

    #expect(model.openSavedLocation(try #require(model.favoriteLocations.first)) == documents)
    #expect(model.accessRootURL == documents)
  }

  @Test("任意のホーム配下の場所でも最初にホームを許可し兄弟へ共有する")
  func sharesHomeAuthorizationForArbitraryLocalPaths() {
    let fixture = makeFixture()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
    let project = fixture.home.appending(path: "Projects/Example")
    let other = fixture.home.appending(path: "Work/Other")
    var granted = false
    var requests: [URL] = []
    let model = makeModel(
      fixture, isGranted: { granted },
      authorize: { requested in
        requests.append(requested)
        fixture.codec.canCreate = true
        granted = true
        return fixture.home
      })

    #expect(model.openLocalFolder(at: project) == project)
    #expect(model.openLocalFolder(at: other) == other)
    #expect(model.accessRootURL == fixture.home)
    #expect(requests == [fixture.home])
  }

  @Test("ホーム外のフォルダではホームへ許可対象を広げない")
  func requestsOnlyExternalFolderOutsideHome() {
    let fixture = makeFixture()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
    let external = URL(filePath: "/Volumes/sidebar-external/Project")
    var granted = false
    var requests: [URL] = []
    let model = makeModel(
      fixture, isGranted: { granted },
      authorize: { requested in
        requests.append(requested)
        fixture.codec.canCreate = true
        granted = true
        return external
      })

    #expect(model.openLocalFolder(at: external) == external)
    #expect(model.accessRootURL == external)
    #expect(requests == [external])
    #expect(fixture.defaults.data(forKey: "home-folder-bookmark") == nil)
  }

  @Test("保存ホーム権限が失効していても復元時は案内せず起動案内で一回だけ取得する")
  func expiredHomeAuthorizationIsRequestedAtLaunch() {
    let fixture = makeFixture()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
    fixture.codec.canCreate = true
    fixture.defaults.set(Data(fixture.home.path.utf8), forKey: "home-folder-bookmark")
    var prompts = 0
    var granted = false
    let model = makeModel(
      fixture, isGranted: { granted },
      authorize: { requested in
        #expect(requested == fixture.home)
        prompts += 1
        granted = true
        return fixture.home
      })

    model.restoreSavedFolder()
    #expect(prompts == 0)
    #expect(model.requestHomeAccessAtLaunchIfNeeded())
    #expect(!model.requestHomeAccessAtLaunchIfNeeded())
    #expect(prompts == 1)
  }

  @Test("モデルとペインのリースを解放した時だけホームのscopeを閉じる")
  func releasesHomeScopeAfterAllLeases() throws {
    let fixture = makeFixture()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
    fixture.codec.canCreate = true
    fixture.defaults.set(Data(fixture.home.path.utf8), forKey: "home-folder-bookmark")
    var stopped: [URL] = []
    let manager = FolderBookmarkAccessManager(
      startAccess: { _ in true }, stopAccess: { stopped.append($0) },
      isSandboxed: { true }, canReadDirectory: { _ in true })
    var model: FolderSelectionModel? = makeModel(
      fixture, accessManager: manager, isGranted: { true }, authorize: { _ in nil })
    model?.restoreSavedFolder()
    var lease = model?.accessLease(for: fixture.home.appending(path: "Documents"))
    #expect(lease != nil)
    model = nil
    #expect(stopped.isEmpty)
    lease = nil
    #expect(stopped == [fixture.home])
  }

  @Test("Finderでマウント済みの共有はPKPaneの許可後にMountedVolumeProviderのまま開く")
  func mountedShareAuthorizationKeepsProviderAndRootScope() throws {
    let fixture = makeFixture()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
    let root = URL(filePath: "/Volumes/AuthorizationShare")
    let child = root.appending(path: "Documents")
    let provider = MountedVolumeProvider(volumeURL: root)
    var granted = false
    var requested = [URL]()
    let model = makeModel(
      fixture, isGranted: { granted },
      authorize: { url in
        requested.append(url)
        granted = true
        fixture.codec.canCreate = true
        return root
      })

    let presentation = try #require(
      LaunchView.mountedFolderPresentation(
        provider: provider, folderURL: child, title: "共有", folderSelection: model,
        transferQueue: .isolatedForTesting()))

    #expect(requested == [root])
    #expect(presentation.browser.providerID == provider.id)
    #expect(presentation.browser.connectionID == provider.connectionID)
    #expect(presentation.browser.currentLocation.localURL == child)
    #expect(model.accessRootURL == root)
    #expect(model.errorMessage == nil)
  }

  @Test("許可済み共有はパネルなしで開き、ペインの寿命までscopeを保持する")
  func mountedShareKeepsScopeUntilBrowserIsReleased() throws {
    let fixture = makeFixture()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
    fixture.codec.canCreate = true
    let root = URL(filePath: "/Volumes/AuthorizedShare")
    var stopped = [URL]()
    let manager = FolderBookmarkAccessManager(
      startAccess: { _ in true }, stopAccess: { stopped.append($0) },
      isSandboxed: { true }, canReadDirectory: { _ in true })
    var model: FolderSelectionModel? = makeModel(
      fixture, accessManager: manager, isGranted: { true },
      authorize: { _ in
        Issue.record("許可済み共有でパネルを出してはいけません")
        return nil
      })
    var presentation = LaunchView.mountedFolderPresentation(
      provider: MountedVolumeProvider(volumeURL: root), folderURL: root, title: "共有",
      folderSelection: try #require(model), transferQueue: .isolatedForTesting())
    #expect(presentation != nil)

    model = nil
    #expect(stopped.isEmpty)
    presentation = nil
    #expect(stopped == [root])
  }

  @Test("共有の許可取消と別共有の選択は既存ペインを変更せず認証失敗にもならない")
  func mountedShareCancellationAndWrongSharePreserveSelection() throws {
    for wrongShare in [false, true] {
      let fixture = makeFixture()
      defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
      fixture.codec.canCreate = true
      let previous = URL(filePath: "/tmp/previous-share-selection")
      let root = URL(filePath: "/Volumes/DeniedShare")
      let manager = FolderBookmarkAccessManager(
        startAccess: { $0 == previous }, stopAccess: { _ in },
        isSandboxed: { true }, canReadDirectory: { $0 == previous })
      let model = makeModel(
        fixture, accessManager: manager, isGranted: { false },
        authorize: { _ in wrongShare ? URL(filePath: "/Volumes/OtherShare") : nil })
      #expect(model.openLocalFolder(at: previous) == previous)

      let presentation = LaunchView.mountedFolderPresentation(
        provider: MountedVolumeProvider(volumeURL: root), folderURL: root, title: "共有",
        folderSelection: model, transferQueue: .isolatedForTesting())

      #expect(presentation == nil)
      #expect(model.selectedFolderURL == previous)
      #expect(model.accessRootURL == previous)
      #expect(model.errorMessage?.contains("認証に失敗") != true)
    }
  }

  @Test("共有名のない旧復元状態を別の唯一の共有へ誤適用しない")
  func rejectsAmbiguousServerProfileRestorationWithoutPrompting() throws {
    let fixture = makeFixture()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
    let model = makeModel(
      fixture, isGranted: { true },
      authorize: { _ in
        Issue.record("曖昧な復元で許可を要求してはいけません")
        return nil
      })
    let legacyProfile = try NASConnectionProfile(
      displayName: "以前のサーバー", host: "nas.example.invalid", shareName: "")
    let currentShare = URL(filePath: "/Volumes/Documents")
    let presentation = LaunchView.mountedFolderPresentation(
      provider: MountedVolumeProvider(volumeURL: currentShare),
      folderURL: currentShare.appending(path: "2026"), title: "共有",
      folderSelection: model, restoringProfile: legacyProfile,
      transferQueue: .isolatedForTesting())

    #expect(presentation == nil)
    #expect(model.selectedFolderURL == nil)
  }

  @Test("保存ホームのrootだけ読めてもscopeを復元できなければ起動許可を省略しない")
  func readableHomeWithoutRestoredScopeStillRequestsAuthorization() throws {
    for persistedKey in ["home-folder-bookmark", "selected-folder-bookmark"] {
      let fixture = makeFixture()
      defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
      fixture.codec.canCreate = true
      fixture.defaults.set(Data(fixture.home.path.utf8), forKey: persistedKey)
      var scopeGranted = false
      var prompts = 0
      let manager = FolderBookmarkAccessManager(
        startAccess: { _ in scopeGranted }, stopAccess: { _ in },
        isSandboxed: { true },
        canReadDirectory: { $0 == fixture.home || scopeGranted })
      let model = makeModel(
        fixture, accessManager: manager, isGranted: { scopeGranted },
        authorize: { requested in
          #expect(requested == fixture.home)
          prompts += 1
          scopeGranted = true
          return fixture.home
        })

      model.restoreSavedFolder()

      #expect(model.requestHomeAccessAtLaunchIfNeeded())
      #expect(prompts == 1)
      #expect(!model.requestHomeAccessAtLaunchIfNeeded())
    }
  }

  @Test("ホームの明示選択直後はstartAccessがfalseでも暗黙許可を使える")
  func explicitHomeSelectionKeepsImplicitAuthorization() throws {
    let fixture = makeFixture()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
    fixture.codec.canCreate = true
    fixture.defaults.set(Data(fixture.home.path.utf8), forKey: "home-folder-bookmark")
    let documents = fixture.home.appending(path: "Documents")
    fixture.defaults.set(Data(documents.path.utf8), forKey: "selected-folder-bookmark")
    var authorized = false
    var prompts = 0
    var protectedReadsBeforeAuthorization = [URL]()
    let manager = FolderBookmarkAccessManager(
      startAccess: { _ in false }, stopAccess: { _ in }, isSandboxed: { true },
      canReadDirectory: { url in
        if !authorized, url != fixture.home { protectedReadsBeforeAuthorization.append(url) }
        return url == fixture.home || authorized
      })
    let model = makeModel(
      fixture, accessManager: manager, isGranted: { authorized },
      authorize: { requested in
        #expect(requested == fixture.home)
        prompts += 1
        authorized = true
        return fixture.home
      })

    model.restoreSavedFolder(requestHomeAccess: true)

    #expect(prompts == 1)
    #expect(protectedReadsBeforeAuthorization.isEmpty)
    #expect(model.selectedFolderURL == documents)
    #expect(model.openLocalFolder(at: fixture.home.appending(path: "Downloads")) != nil)
    #expect(model.openLocalFolder(at: fixture.home.appending(path: "Project")) != nil)
    #expect(prompts == 1)
    #expect(model.errorMessage == nil)
  }

  @Test("起動統合経路は復元済みhome scopeなら案内なしで保存した子を開く")
  func startupRestoresRealHomeScopeBeforeSavedChild() throws {
    let fixture = makeFixture()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
    fixture.codec.canCreate = true
    let child = fixture.home.appending(path: "Documents")
    fixture.defaults.set(Data(fixture.home.path.utf8), forKey: "home-folder-bookmark")
    fixture.defaults.set(Data(child.path.utf8), forKey: "selected-folder-bookmark")
    let model = makeModel(
      fixture, isGranted: { true },
      authorize: { _ in
        Issue.record("有効なhome scopeで再案内してはいけません")
        return nil
      })

    model.restoreSavedFolder(requestHomeAccess: true)

    #expect(model.selectedFolderURL == child)
    #expect(model.accessRootURL == fixture.home)
    #expect(model.errorMessage == nil)
  }

  @Test("可読fallbackから実scopeへの昇格と失敗で参照数を壊さない")
  func promotesReadableFallbackToScopeWithoutLeakingCounts() throws {
    let home = URL(filePath: "/tmp/home-scope-promotion")
    var scopeAvailable = false
    var starts = 0
    var stops = 0
    let manager = FolderBookmarkAccessManager(
      startAccess: { _ in
        starts += 1
        return scopeAvailable
      },
      stopAccess: { _ in stops += 1 }, isSandboxed: { true }, canReadDirectory: { _ in true })
    try manager.beginAccess(to: home)
    #expect(throws: FolderBookmarkAccessError.accessDenied) {
      try manager.beginAccess(to: home, requiresSecurityScope: true)
    }
    scopeAvailable = true
    try manager.beginAccess(to: home, requiresSecurityScope: true)
    try manager.beginAccess(to: home, requiresSecurityScope: true)
    #expect(starts == 3)
    manager.endAccess(to: home)
    manager.endAccess(to: home)
    #expect(stops == 0)
    manager.endAccess(to: home)
    #expect(stops == 1)
  }

  @Test("起動統合経路の許可取消と子だけの許可は保存済みの表示先を変えず連打しない")
  func startupCancellationAndChildPermissionKeepSavedSelection() throws {
    for selectsChild in [false, true] {
      let fixture = makeFixture()
      defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
      fixture.codec.canCreate = true
      let outside = URL(filePath: "/tmp/home-startup-saved-selection")
      let child = fixture.home.appending(path: "Documents")
      fixture.defaults.set(Data(outside.path.utf8), forKey: "selected-folder-bookmark")
      var childAuthorized = false
      var prompts = 0
      let manager = FolderBookmarkAccessManager(
        startAccess: { _ in false }, stopAccess: { _ in }, isSandboxed: { true },
        canReadDirectory: { $0 == outside || (childAuthorized && $0 == child) })
      let model = makeModel(
        fixture, accessManager: manager, isGranted: { false },
        authorize: { _ in
          prompts += 1
          childAuthorized = selectsChild
          return selectsChild ? child : nil
        })

      model.restoreSavedFolder(requestHomeAccess: true)
      model.restoreSavedFolder(requestHomeAccess: true)

      #expect(prompts == 1)
      #expect(model.selectedFolderURL == outside)
      #expect(fixture.defaults.data(forKey: "selected-folder-bookmark") == Data(outside.path.utf8))
      #expect(fixture.defaults.data(forKey: "home-folder-bookmark") == nil)
    }
  }

  @Test("起動前に未読込みの子お気に入りも許可後同じIDで保存され次のモデルへ引き継がれる")
  func startupChildPermissionPersistsUnloadedFavoriteAcrossModels() throws {
    let fixture = makeFixture()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
    let child = fixture.home.appending(path: "Documents")
    let initial = try fixture.favorites.add(child, allowingMissingAuthorization: true)
    let favoriteID = try #require(initial.first?.id)
    let outside = URL(filePath: "/tmp/home-startup-other-selection")
    fixture.defaults.set(Data(outside.path.utf8), forKey: "selected-folder-bookmark")
    var childGranted = false
    let manager = FolderBookmarkAccessManager(
      startAccess: { $0 == outside || (childGranted && $0 == child) }, stopAccess: { _ in },
      isSandboxed: { true }, canReadDirectory: { $0 == outside || (childGranted && $0 == child) })
    let model = makeModel(
      fixture, accessManager: manager, isGranted: { false },
      authorize: { _ in
        childGranted = true
        fixture.codec.canCreate = true
        return child
      })

    model.restoreSavedFolder(requestHomeAccess: true)

    #expect(model.selectedFolderURL == outside)
    #expect(model.favoriteLocations.first?.id == favoriteID)
    #expect(model.favoriteLocations.first?.url == child)
    let restartedFixture = Fixture(
      home: fixture.home, suite: fixture.suite, defaults: fixture.defaults, codec: fixture.codec,
      favorites: FolderLocationListRepository(
        storage: UserDefaultsFolderLocationListStore(defaults: fixture.defaults, key: "favorites"),
        codec: fixture.codec, mode: .favorites))
    let restarted = makeModel(
      restartedFixture, isGranted: { true },
      authorize: { _ in
        Issue.record("子のお気に入りを開くだけで再許可してはいけません")
        return nil
      })
    restarted.restoreSavedFolder()
    #expect(restarted.openSavedLocation(try #require(restarted.favoriteLocations.first)) == child)
    #expect(restarted.favoriteLocations.first?.id == favoriteID)
  }

  private struct Fixture {
    let home: URL
    let suite: String
    let defaults: UserDefaults
    let codec: AuthorizationBookmarkCodec
    let favorites: FolderLocationListRepository
  }

  private func makeFixture() -> Fixture {
    let suite = "test-sidebar-authorization.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let codec = AuthorizationBookmarkCodec()
    return Fixture(
      home: URL(filePath: "/tmp/sidebar-home-\(UUID().uuidString)"),
      suite: suite, defaults: defaults, codec: codec,
      favorites: FolderLocationListRepository(
        storage: UserDefaultsFolderLocationListStore(defaults: defaults, key: "favorites"),
        codec: codec, mode: .favorites))
  }

  private func makeModel(
    _ fixture: Fixture,
    accessManager: FolderBookmarkAccessManager? = nil,
    isGranted: @escaping () -> Bool,
    authorize: @escaping @MainActor (URL) -> URL?
  ) -> FolderSelectionModel {
    FolderSelectionModel(
      repository: FolderBookmarkRepository(
        storage: UserDefaultsFolderBookmarkStore(defaults: fixture.defaults), codec: fixture.codec),
      homeRepository: FolderBookmarkRepository(
        storage: UserDefaultsFolderBookmarkStore(
          defaults: fixture.defaults, key: "home-folder-bookmark"), codec: fixture.codec),
      favoriteRepository: fixture.favorites,
      recentRepository: FolderLocationListRepository(
        storage: UserDefaultsFolderLocationListStore(defaults: fixture.defaults, key: "recent"),
        codec: fixture.codec, mode: .recent(limit: 5)),
      cloudRootRepository: FolderLocationListRepository(
        storage: UserDefaultsFolderLocationListStore(defaults: fixture.defaults, key: "cloud"),
        codec: fixture.codec, mode: .favorites),
      accessManager: accessManager
        ?? FolderBookmarkAccessManager(
          startAccess: { _ in isGranted() }, stopAccess: { _ in },
          isSandboxed: { true }, canReadDirectory: { _ in isGranted() }),
      defaults: fixture.defaults, homeDirectory: fixture.home,
      folderAuthorizationProvider: authorize)
  }
}

// この型はMainActor上のテストからのみ変更し、実フォルダのブックマークを生成しない。
private final class AuthorizationBookmarkCodec: FolderBookmarkCoding, @unchecked Sendable {
  var canCreate = false

  func createBookmark(for url: URL) throws -> Data {
    guard canCreate else { throw CocoaError(.fileReadNoPermission) }
    return Data(url.path.utf8)
  }

  func resolveBookmark(_ data: Data) throws -> ResolvedFolderBookmark {
    guard let path = String(data: data, encoding: .utf8), !path.isEmpty else {
      throw CocoaError(.fileReadCorruptFile)
    }
    return ResolvedFolderBookmark(url: URL(filePath: path), isStale: false)
  }
}
