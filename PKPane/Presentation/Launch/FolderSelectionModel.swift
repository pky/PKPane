import AppKit
import Observation

@Observable
@MainActor
final class FolderSelectionModel {
  private let repository: FolderBookmarkRepository
  private let homeRepository: FolderBookmarkRepository
  private let favoriteRepository: FolderLocationListRepository
  private let recentRepository: FolderLocationListRepository
  private let cloudRootRepository: FolderLocationListRepository
  private let accessManager: FolderBookmarkAccessManager
  private let defaults: UserDefaults
  private let cloudStorageURL: URL
  private let cloudRootIsAvailable: (URL) -> Bool
  private let homeDirectory: URL
  private let folderAuthorizationProvider: @MainActor (URL) -> URL?
  private let usesSystemAuthorizationProvider: Bool
  @ObservationIgnored private var homeAccessLease: WorkspaceBookmarkAccessLease?
  @ObservationIgnored private var launchFolderAccessLease: WorkspaceBookmarkAccessLease?
  @ObservationIgnored private var launchFolderAccessURL: URL?
  @ObservationIgnored private var didRequestHomeAccessAtLaunch = false

  private(set) var selectedFolderURL: URL?
  private(set) var errorMessage: String?
  private(set) var favoriteLocations: [SavedFolderLocation] = []
  private(set) var recentLocations: [SavedFolderLocation] = []
  private(set) var cloudRootLocations: [SavedFolderLocation] = []
  private(set) var accessRootURL: URL?
  @ObservationIgnored private var favoriteChangeHandler: (@MainActor () -> Void)?

  init(
    repository: FolderBookmarkRepository = FolderBookmarkRepository(
      storage: UserDefaultsFolderBookmarkStore(),
      codec: SystemFolderBookmarkCodec()
    ),
    homeRepository: FolderBookmarkRepository? = nil,
    favoriteRepository: FolderLocationListRepository = FolderLocationListRepository(
      storage: UserDefaultsFolderLocationListStore(key: "favorite-folder-bookmarks"),
      codec: SystemFolderBookmarkCodec(),
      mode: .favorites
    ),
    recentRepository: FolderLocationListRepository = FolderLocationListRepository(
      storage: UserDefaultsFolderLocationListStore(key: "recent-folder-bookmarks"),
      codec: SystemFolderBookmarkCodec(),
      mode: .recent(limit: 5)
    ),
    cloudRootRepository: FolderLocationListRepository = FolderLocationListRepository(
      storage: UserDefaultsFolderLocationListStore(key: "cloud-root-bookmarks"),
      codec: SystemFolderBookmarkCodec(),
      mode: .favorites
    ),
    accessManager: FolderBookmarkAccessManager = FolderBookmarkAccessManager(),
    defaults: UserDefaults? = nil,
    cloudStorageURL: URL = UserHomeDirectory.current
      .appending(path: "Library/CloudStorage", directoryHint: .isDirectory),
    cloudRootIsAvailable: @escaping (URL) -> Bool = { url in
      var isDirectory: ObjCBool = false
      return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        && isDirectory.boolValue
    },
    homeDirectory: URL = UserHomeDirectory.current,
    folderAuthorizationProvider: (@MainActor (URL) -> URL?)? = nil
  ) {
    self.repository = repository
    self.favoriteRepository = favoriteRepository
    self.recentRepository = recentRepository
    self.cloudRootRepository = cloudRootRepository
    self.accessManager = accessManager
    self.defaults = defaults ?? Self.defaultUserDefaults
    self.homeRepository =
      homeRepository
      ?? FolderBookmarkRepository(
        storage: UserDefaultsFolderBookmarkStore(
          defaults: self.defaults, key: "home-folder-bookmark"),
        codec: SystemFolderBookmarkCodec())
    self.cloudStorageURL = cloudStorageURL.standardizedFileURL
    self.cloudRootIsAvailable = cloudRootIsAvailable
    self.homeDirectory = homeDirectory.standardizedFileURL
    self.folderAuthorizationProvider =
      folderAuthorizationProvider ?? Self.requestFolderAuthorization
    self.usesSystemAuthorizationProvider = folderAuthorizationProvider == nil

    let center = NSWorkspace.shared.notificationCenter
    let volumeNotifications: [Notification.Name] = [
      NSWorkspace.didMountNotification,
      NSWorkspace.didUnmountNotification,
      NSWorkspace.didRenameVolumeNotification,
    ]
    for name in volumeNotifications {
      volumeObservers.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          MainActor.assumeIsolated {
            self?.smbMountedFolderCache.removeAll()
          }
        }
      )
    }
  }

  isolated deinit {
    if let accessRootURL {
      accessManager.endAccess(to: accessRootURL)
    }
    let center = NSWorkspace.shared.notificationCenter
    for observer in volumeObservers {
      center.removeObserver(observer)
    }
  }

  private static var defaultUserDefaults: UserDefaults {
    PKPaneUserDefaults.resolve()
  }

  func restoreSavedFolder(requestHomeAccess: Bool = false) {
    restoreHomeAccessIfNeeded()
    if requestHomeAccess { requestHomeAccessAtLaunchIfNeeded() }
    reloadSavedLocations()
    // 初回の子フォルダ許可は、お気に入りの初期読込み・作成より先に得られる。
    defer { refreshLaunchFolderFavoriteBookmarkIfNeeded() }
    do {
      if let testFolderURL {
        try select(testFolderURL)
        return
      }
      guard let folderURL = try repository.restore() else {
        return
      }
      guard !UserHomeDirectory.isAppContainerHome(folderURL, home: homeDirectory) else {
        return
      }
      guard shouldRestoreAtLaunch(folderURL) else {
        return
      }

      try select(folderURL)
    } catch {
      errorMessage = PKPaneErrorClassifier.classify(error).displayMessage
    }
  }

  /// 起動時の案内は一度だけ行い、許可しても現在のペインの表示先を変更しない。
  @discardableResult
  func requestHomeAccessAtLaunchIfNeeded() -> Bool {
    guard !didRequestHomeAccessAtLaunch else { return false }
    didRequestHomeAccessAtLaunch = true
    let environment = ProcessInfo.processInfo.environment
    guard
      !usesSystemAuthorizationProvider
        || (!TestEnvironmentDetector.isRunningTests(environment: environment)
          && environment["PKPANE_UI_TESTING"] != "1")
    else { return false }
    if homeAccessLease != nil, accessManager.isReadableDirectory(at: homeDirectory) {
      return false
    }
    guard let authorizedURL = folderAuthorizationProvider(homeDirectory)?.standardizedFileURL
    else { return false }
    do {
      if authorizedURL.path == homeDirectory.path {
        try retainHomeAccess(to: authorizedURL)
      } else {
        // 子フォルダを選んだ場合はその範囲だけ保存し、表示中の場所は維持する。
        guard isWithin(authorizedURL, root: homeDirectory) else {
          errorMessage = String(localized: "対象フォルダまたはその親フォルダを選択してください。")
          return false
        }
        let lease = try WorkspaceBookmarkAccessLease(url: authorizedURL, manager: accessManager)
        if favoriteLocations.contains(where: {
          ($0.url?.standardizedFileURL.path ?? $0.lastKnownPath) == authorizedURL.path
        }) {
          favoriteLocations = try favoriteRepository.refreshFavoriteBookmark(for: authorizedURL)
          favoriteChangeHandler?()
        }
        launchFolderAccessLease = lease
        launchFolderAccessURL = authorizedURL
      }
      errorMessage = nil
      return true
    } catch {
      errorMessage = PKPaneErrorClassifier.classify(error).displayMessage
      return false
    }
  }

  private func restoreHomeAccessIfNeeded() {
    guard homeAccessLease == nil else { return }
    do {
      if let url = try homeRepository.restore(),
        url.standardizedFileURL.path == homeDirectory.path
      {
        // ホームrootだけの可読性は、保存したホーム全域の許可が復元できた根拠にならない。
        homeAccessLease = try WorkspaceBookmarkAccessLease(
          url: url, manager: accessManager, requiresSecurityScope: true)
        return
      }
    } catch {
      // 保存許可の失効は起動時の案内または次の明示クリックで再取得する。
    }
    guard homeAccessLease == nil else { return }
    // 旧版の選択先がホームなら、子の読取りより先に専用の保存先へ移行する。
    do {
      guard let url = try repository.restore(),
        url.standardizedFileURL.path == homeDirectory.path
      else { return }
      try retainHomeAccess(to: url, requiresSecurityScope: true)
    } catch {
      // 実scopeが復元できない保存URLだけでは、一括許可を得たものと見なさない。
    }
  }

  private func refreshLaunchFolderFavoriteBookmarkIfNeeded() {
    guard let root = launchFolderAccessURL,
      favoriteLocations.contains(where: {
        ($0.url?.standardizedFileURL.path ?? $0.lastKnownPath) == root.path
      })
    else { return }
    do {
      favoriteLocations = try favoriteRepository.refreshFavoriteBookmark(for: root)
      favoriteChangeHandler?()
    } catch {
      errorMessage = PKPaneErrorClassifier.classify(error).displayMessage
    }
  }

  private func retainHomeAccess(to url: URL, requiresSecurityScope: Bool = false) throws {
    // 明示選択直後のURLは暗黙の許可でも使える。保存からの復元時だけ実scopeを要求する。
    let lease = try WorkspaceBookmarkAccessLease(
      url: url, manager: accessManager, requiresSecurityScope: requiresSecurityScope)
    try homeRepository.save(url)
    homeAccessLease = lease
  }

  private var testFolderURL: URL? {
    guard ProcessInfo.processInfo.environment["PKPANE_UI_TESTING"] == "1" else {
      return nil
    }
    let arguments = ProcessInfo.processInfo.arguments
    // -ui-test-folder-pathの値(テストごとに一意な一時ディレクトリ)を実際に使う。
    // 従来は引数の有無しか見ておらず、値を無視して常に固定パスを返していたため、
    // PKPaneApp.makeUITestFolder()側を修正しても起動時の復元経路はこの固定パスを
    // 使い続け、過去のテスト実行の残骸に汚染された状態でテストが動いていた。
    guard let index = arguments.firstIndex(of: "-ui-test-folder-path"),
      arguments.indices.contains(index + 1)
    else {
      return nil
    }
    return URL(filePath: arguments[index + 1])
  }

  func chooseFolder(onSelected: ((URL) -> Void)? = nil) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "選択"
    panel.message = "PKPaneで利用するフォルダを選択してください。"

    guard panel.runModal() == .OK, let folderURL = panel.url else {
      return
    }

    do {
      try repository.save(folderURL)
      try select(folderURL)
      onSelected?(folderURL)
    } catch {
      errorMessage = PKPaneErrorClassifier.classify(error).displayMessage
    }
  }

  func chooseCloudRoot(onSelected: ((URL) -> Void)? = nil) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = false
    panel.allowsMultipleSelection = false
    panel.directoryURL = cloudStorageURL
    panel.prompt = String(localized: "許可")
    panel.message = String(localized: "公式アプリのクラウドフォルダを選択してください。")

    guard panel.runModal() == .OK, let folderURL = panel.url else { return }
    if registerCloudRoot(folderURL) {
      onSelected?(selectedFolderURL ?? folderURL)
    }
  }

  @discardableResult
  func registerCloudRoot(_ folderURL: URL) -> Bool {
    let rootURL = folderURL.standardizedFileURL
    guard rootURL.deletingLastPathComponent().path == cloudStorageURL.path else {
      errorMessage = String(localized: "CloudStorage直下のクラウドフォルダを選択してください。")
      return false
    }
    do {
      try select(rootURL)
      cloudRootLocations = try cloudRootRepository.refreshFavoriteBookmark(for: rootURL)
      errorMessage = nil
      return true
    } catch {
      errorMessage = PKPaneErrorClassifier.classify(error).displayMessage
      return false
    }
  }

  func openSavedCloudRoot(at folderURL: URL) -> URL? {
    let folderPath = folderURL.standardizedFileURL.path
    guard
      let location = cloudRootLocations.first(where: {
        let savedURL = $0.url ?? $0.lastKnownPath.map { URL(filePath: $0) }
        return savedURL?.standardizedFileURL.path == folderPath
      })
    else { return nil }
    guard let url = location.url else { return nil }
    do {
      try accessManager.beginAccess(to: url)
      defer { accessManager.endAccess(to: url) }
      guard cloudRootIsAvailable(url) else { return nil }
      try select(url)
      return selectedFolderURL
    } catch {
      errorMessage = PKPaneErrorClassifier.classify(error).displayMessage
      return nil
    }
  }

  func dismissMountedFolder(at volumeURL: URL) {
    let standardizedVolumeURL = volumeURL.standardizedFileURL
    guard let selectedFolderURL, isWithin(selectedFolderURL, root: standardizedVolumeURL) else {
      return
    }
    if let accessRootURL {
      accessManager.endAccess(to: accessRootURL)
    }
    accessRootURL = nil
    self.selectedFolderURL = nil
    errorMessage = nil
  }

  func isFavorite(url: URL) -> Bool {
    let location = FileLocation(directoryURL: url)
    return favoriteLocations.contains { Self.matchesFavorite($0, location: location) }
  }

  func toggleFavorite(url: URL) {
    do {
      let location = FileLocation(directoryURL: url)
      if let favorite = favoriteLocations.first(where: {
        Self.matchesFavorite($0, location: location)
      }) {
        favoriteLocations = try favoriteRepository.remove(id: favorite.id)
      } else {
        favoriteLocations = try favoriteRepository.add(url)
      }
      errorMessage = nil
      favoriteChangeHandler?()
    } catch {
      errorMessage =
        "お気に入りを保存できません: \(PKPaneErrorClassifier.classify(error).displayMessage)"
    }
  }

  /// 別ウインドウで変更した保存一覧だけを再読込し、表示場所や接続は変えない。
  func reloadFavorites() {
    do {
      favoriteLocations = try favoriteRepository.load()
    } catch {
      errorMessage =
        "保存した場所を読み込めません: \(PKPaneErrorClassifier.classify(error).displayMessage)"
    }
  }

  func favoriteID(for url: URL) -> UUID? {
    favoriteLocations.first {
      Self.matchesFavorite($0, location: FileLocation(directoryURL: url))
    }?.id
  }

  @discardableResult
  func addFavorites(urls: [URL]) -> Bool {
    let directories = urls.filter(Self.isExistingDirectory)
    guard !directories.isEmpty else { return false }

    var updatedFavorites = favoriteLocations
    for directory in directories {
      let location = FileLocation(directoryURL: directory)
      guard !updatedFavorites.contains(where: { Self.matchesFavorite($0, location: location) })
      else {
        continue
      }

      do {
        updatedFavorites = try favoriteRepository.add(directory)
      } catch {
        favoriteLocations = updatedFavorites
        errorMessage =
          "お気に入りを保存できません: \(PKPaneErrorClassifier.classify(error).displayMessage)"
        favoriteChangeHandler?()
        return true
      }
    }
    favoriteLocations = updatedFavorites
    errorMessage = nil
    favoriteChangeHandler?()
    return true
  }

  private static func isExistingDirectory(_ url: URL) -> Bool {
    guard url.isFileURL else { return false }
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }

  private static func matchesFavorite(
    _ favorite: SavedFolderLocation,
    location: FileLocation
  ) -> Bool {
    if let url = favorite.url {
      return FileLocation(directoryURL: url) == location
    }
    guard favorite.smbLocation == nil,
      let lastKnownPath = favorite.lastKnownPath,
      let localURL = location.localURL
    else {
      return false
    }
    return URL(filePath: lastKnownPath).standardizedFileURL.path
      == localURL.standardizedFileURL.path
  }

  func removeFavorite(id: UUID) {
    do {
      favoriteLocations = try favoriteRepository.remove(id: id)
      errorMessage = nil
      favoriteChangeHandler?()
    } catch {
      errorMessage =
        "お気に入りを削除できません: \(PKPaneErrorClassifier.classify(error).displayMessage)"
    }
  }

  func removeRecent(id: UUID) {
    do {
      recentLocations = try recentRepository.remove(id: id)
      errorMessage = nil
    } catch {
      errorMessage =
        "最近使用した場所を削除できません: \(PKPaneErrorClassifier.classify(error).displayMessage)"
    }
  }

  func moveFavorite(id: UUID, by offset: Int) {
    do {
      favoriteLocations = try favoriteRepository.move(id: id, by: offset)
      errorMessage = nil
      favoriteChangeHandler?()
    } catch {
      errorMessage =
        "お気に入りを並べ替えできません: \(PKPaneErrorClassifier.classify(error).displayMessage)"
    }
  }

  @discardableResult
  func openSavedLocation(_ location: SavedFolderLocation) -> URL? {
    var resolvedLocation = location
    if resolvedLocation.url == nil, resolvedLocation.smbLocation == nil,
      let path = resolvedLocation.lastKnownPath
    {
      let target = URL(filePath: path).standardizedFileURL
      if hasReadableAccess(to: target) {
        do {
          try select(target)
          return selectedFolderURL
        } catch {
          errorMessage = PKPaneErrorClassifier.classify(error).displayMessage
        }
      }
    }
    if resolvedLocation.url == nil, resolvedLocation.smbLocation == nil,
      let locations = try? favoriteRepository.activateSyncedLocalFavorite(id: location.id)
    {
      favoriteLocations = locations
      resolvedLocation = locations.first(where: { $0.id == location.id }) ?? resolvedLocation
    }
    guard let url = resolvedLocation.url else {
      if resolvedLocation.requiresAuthorization {
        return authorizeSavedLocation(resolvedLocation)
      }
      errorMessage = "「\(resolvedLocation.name)」のアクセス権が失効しています。"
      return nil
    }

    do {
      if isWithinCurrentAccessRoot(url) {
        navigate(to: url)
      } else {
        try select(url)
      }
      return selectedFolderURL
    } catch {
      errorMessage = PKPaneErrorClassifier.classify(error).displayMessage
      guard resolvedLocation.smbLocation == nil else { return nil }
      return authorizeSavedLocation(resolvedLocation)
    }
  }

  func accessLease(for url: URL) -> WorkspaceBookmarkAccessLease? {
    if homeAccessLease != nil, isWithin(url, root: homeDirectory) {
      return try? WorkspaceBookmarkAccessLease(url: homeDirectory, manager: accessManager)
    }
    if let root = launchFolderAccessURL, isWithin(url, root: root) {
      return try? WorkspaceBookmarkAccessLease(url: root, manager: accessManager)
    }
    guard isWithinCurrentAccessRoot(url), let accessRootURL else { return nil }
    return try? WorkspaceBookmarkAccessLease(url: accessRootURL, manager: accessManager)
  }

  /// 現在保持しているアクセス許可の範囲だけを最近ファイル検索に渡す。
  func authorizedRecentFileRoots() -> [URL] {
    var roots = [URL]()
    if homeAccessLease != nil { roots.append(homeDirectory) }
    if launchFolderAccessLease != nil, let launchFolderAccessURL {
      roots.append(launchFolderAccessURL)
    }
    if let accessRootURL { roots.append(accessRootURL) }
    var seen = Set<String>()
    return roots.filter { seen.insert($0.standardizedFileURL.path).inserted }
  }

  /// 検索結果を表示している間、元の許可が別の場所への移動で解放されても読み取りを保つ。
  func recentFileAccessLeases(for roots: [URL]) -> [WorkspaceBookmarkAccessLease] {
    let permitted = Set(authorizedRecentFileRoots().map { $0.standardizedFileURL.path })
    return roots.compactMap { root in
      guard permitted.contains(root.standardizedFileURL.path) else { return nil }
      return accessLease(for: root)
    }
  }

  @discardableResult
  func openLocalFolder(at url: URL, onSelected: ((URL) -> Void)? = nil) -> URL? {
    if isWithinCurrentAccessRoot(url) {
      navigate(to: url)
      onSelected?(url)
      return url
    }
    do {
      try select(url)
      onSelected?(url)
      return url
    } catch {
      return authorizeSavedLocation(
        SavedFolderLocation(id: UUID(), name: url.lastPathComponent, url: url),
        onSelected: onSelected)
    }
  }

  @discardableResult
  func authorizeSavedLocation(
    _ location: SavedFolderLocation, onSelected: ((URL) -> Void)? = nil
  ) -> URL? {
    guard location.smbLocation == nil,
      let targetURL = location.url ?? location.lastKnownPath.map({ URL(filePath: $0) }),
      targetURL.isFileURL
    else { return nil }
    let target = targetURL.standardizedFileURL
    if hasReadableAccess(to: target) {
      do {
        try select(target)
        onSelected?(target)
        return target
      } catch {
        errorMessage = PKPaneErrorClassifier.classify(error).displayMessage
      }
    }
    let requestedURL = isWithin(target, root: homeDirectory) ? homeDirectory : target
    guard let authorizedURL = folderAuthorizationProvider(requestedURL)?.standardizedFileURL
    else { return nil }
    guard isWithin(target, root: authorizedURL) else {
      errorMessage = String(localized: "対象フォルダまたはその親フォルダを選択してください。")
      return nil
    }
    do {
      try accessManager.beginAccess(to: authorizedURL)
      defer { accessManager.endAccess(to: authorizedURL) }
      if authorizedURL.path == homeDirectory.path {
        try retainHomeAccess(to: authorizedURL)
      }
      // 親への許可を保持したまま対象を再保存し、元の保存先IDを維持する。
      let isFavorite = favoriteLocations.contains { $0.id == location.id }
      if isFavorite {
        favoriteLocations = try favoriteRepository.refreshFavoriteBookmark(for: target)
        favoriteChangeHandler?()
      }
      try select(authorizedURL)
      navigate(to: target)
      onSelected?(target)
      return target
    } catch {
      errorMessage = PKPaneErrorClassifier.classify(error).displayMessage
      return nil
    }
  }

  private static func requestFolderAuthorization(_ targetURL: URL) -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = false
    panel.allowsMultipleSelection = false
    panel.directoryURL = targetURL
    panel.prompt = String(localized: "アクセスを許可")
    if targetURL.standardizedFileURL.path == UserHomeDirectory.current.path {
      panel.message = String(localized: "ホームフォルダ内の項目を開くため、アクセスを許可してください。")
    } else {
      panel.message = String(
        format: String(localized: "「%@」を開くには、フォルダへのアクセスを許可してください。"),
        UserHomeDirectory.localizedStandardFolderName(for: targetURL) ?? targetURL.lastPathComponent
      )
    }
    guard panel.runModal() == .OK else { return nil }
    return panel.url
  }

  func setFavoriteChangeHandler(_ handler: @escaping @MainActor () -> Void) {
    favoriteChangeHandler = handler
  }

  func portableFavorites() throws -> [PortableFavorite] {
    try favoriteRepository.portableFavorites()
  }

  func applySyncedFavorites(_ document: FavoriteSyncDocument) {
    guard let locations = try? favoriteRepository.applySyncedFavorites(document) else { return }
    favoriteLocations = locations
  }

  private func navigate(to url: URL) {
    guard selectedFolderURL != url else { return }
    selectedFolderURL = url
    errorMessage = nil
    recordRecentLocation(url)
  }

  private func select(_ folderURL: URL) throws {
    let standardizedURL = folderURL.standardizedFileURL
    let nextAccessRoot: URL
    if homeAccessLease != nil, isWithin(standardizedURL, root: homeDirectory) {
      nextAccessRoot = homeDirectory
    } else if let root = launchFolderAccessURL, isWithin(standardizedURL, root: root) {
      nextAccessRoot = root
    } else {
      nextAccessRoot = standardizedURL
    }
    try accessManager.replaceAccess(from: accessRootURL, to: nextAccessRoot)
    accessRootURL = nextAccessRoot
    selectedFolderURL = standardizedURL
    if !isSMBMountedFolder(standardizedURL) {
      try? repository.save(standardizedURL)
    }
    errorMessage = nil
    recordRecentLocation(standardizedURL)
  }

  private func reloadSavedLocations() {
    seedDefaultFavoritesIfNeeded()
    do {
      favoriteLocations = try favoriteRepository.load()
      recentLocations = try recentLocationsIncludingTestNetworkLocation()
      cloudRootLocations = try cloudRootRepository.load()
    } catch {
      errorMessage =
        "保存した場所を読み込めません: \(PKPaneErrorClassifier.classify(error).displayMessage)"
    }
  }

  /// お気に入り候補の差分注入で使う UserDefaults キー。値は注入を試みた候補パスの配列。
  private static let favoriteSeededPathsKey = "favorite-defaults-seeded-paths"
  /// 旧方式(bool一括フラグ)のキー。差分注入方式への移行判定にのみ使う。
  private static let legacyFavoriteSeededKey = "favorite-defaults-seeded"

  /// まだ注入を試みていない候補フォルダだけを、お気に入りへ差分注入する。
  /// 一度注入を試みた候補は(ユーザーが削除しても)再注入しない。候補を後から増やしても
  /// 未試行の新候補だけが自動的に注入対象になる。
  /// UIテストは saved-location-<名前> という名前ベースの識別子でフィクスチャを参照するため、
  /// Desktop/Documents等の注入がテスト用の項目と衝突しないよう UIテスト実行環境では注入しない。
  /// ユニットテストでも注入しない: 起動経路のシードはDesktop等のbookmark生成で
  /// Sandbox承認を要求し、承認が未付与(リビルドでad-hoc署名が変わった直後など)だと
  /// XCTest接続前にテストホストごとハングして全テストを巻き添えにする。
  /// シード本体のテストはenvironmentを明示注入して検証する。
  func seedDefaultFavoritesIfNeeded(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    guard environment["PKPANE_UI_TESTING"] != "1" else { return }
    guard !TestEnvironmentDetector.isRunningTests(environment: environment) else { return }
    let fileManager = FileManager.default
    var seededPaths = loadFavoriteSeededPaths(fileManager: fileManager)
    repairContainerFavorites(seededPaths: &seededPaths)

    let candidates = Self.allFavoriteCandidateURLs(
      fileManager: fileManager, homeDirectory: homeDirectory)
    let pendingCandidates = candidates.filter { !seededPaths.contains($0.path) }
    guard !pendingCandidates.isEmpty else { return }

    var didUpdateSeededPaths = false
    for url in pendingCandidates {
      // Sandboxの存在確認は未許可フォルダもfalseになる。標準候補はパスを保存し、
      // ブックマーク未生成ならユーザーが選択した時点で許可を取得する。
      guard (try? favoriteRepository.add(url, allowingMissingAuthorization: true)) != nil else {
        continue
      }
      seededPaths.insert(url.path)
      didUpdateSeededPaths = true
    }
    favoriteLocations = (try? favoriteRepository.load()) ?? favoriteLocations
    // 全滅などで進捗がない場合は書き込み自体を行わず、キー未設定(nil)のまま次回再試行できるようにする。
    guard didUpdateSeededPaths else { return }
    defaults.set(Array(seededPaths), forKey: Self.favoriteSeededPathsKey)
  }

  private func repairContainerFavorites(seededPaths: inout Set<String>) {
    let containerHome = homeDirectory.appending(
      path: "Library/Containers/\(Bundle.main.bundleIdentifier ?? "com.pky.PKPane")/Data")
    let containerCandidates = Set(
      UserHomeDirectory.standardFolderURLs(home: containerHome).map(\.path)
        .filter { $0 != "/Applications" })
    let seededContainerPaths = seededPaths.intersection(containerCandidates)
    guard !seededContainerPaths.isEmpty,
      let favorites = try? favoriteRepository.load()
    else { return }
    for favorite in favorites {
      guard let path = favorite.url?.standardizedFileURL.path ?? favorite.lastKnownPath,
        seededContainerPaths.contains(path)
      else { continue }
      guard (try? favoriteRepository.remove(id: favorite.id)) != nil else { return }
    }
    // 実ホーム側の試行済み記録は保持し、ユーザーが削除した項目を再追加しない。
    seededPaths.subtract(seededContainerPaths)
    defaults.set(Array(seededPaths), forKey: Self.favoriteSeededPathsKey)
  }

  /// 差分注入キーの現在値を返す。未設定かつ旧bool一括フラグが立っている環境では、
  /// 旧候補セット(Movies追加後・Applications追加前の6候補、Movies除く)を試行済みとして
  /// 移行する。Movies追加前後の環境は区別できないため、Moviesは常に未試行として扱い、
  /// 既に登録済みならお気に入りリポジトリの重複ガードで二重登録を防ぐ。
  private func loadFavoriteSeededPaths(fileManager: FileManager) -> Set<String> {
    if let paths = defaults.stringArray(forKey: Self.favoriteSeededPathsKey) {
      return Set(paths)
    }
    guard defaults.bool(forKey: Self.legacyFavoriteSeededKey) else { return [] }
    return Self.legacyMigratedFavoriteSeededPaths(
      fileManager: fileManager, homeDirectory: homeDirectory)
  }

  private static func legacyMigratedFavoriteSeededPaths(
    fileManager: FileManager, homeDirectory: URL
  ) -> Set<String> {
    let home = homeDirectory
    var paths = ["Desktop", "Downloads", "Documents", "Pictures"].map {
      home.appending(path: $0).path
    }
    paths.append(home.path)
    paths.append(home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs").path)
    return Set(paths)
  }

  /// デフォルトお気に入りの候補フォルダを、実在するものだけに絞って返す。
  static func defaultFavoriteCandidateURLs(fileManager: FileManager) -> [URL] {
    existingCandidates(
      among: allFavoriteCandidateURLs(fileManager: fileManager), fileManager: fileManager)
  }

  /// 存在確認前の候補フォルダ一覧。iCloud Driveはサイドバー「場所」に常設するため、
  /// 新規ユーザー向けのお気に入り初期注入には含めない。
  static func allFavoriteCandidateURLs(
    fileManager: FileManager, homeDirectory: URL = UserHomeDirectory.current
  ) -> [URL] {
    UserHomeDirectory.standardFolderURLs(home: homeDirectory)
  }

  /// 実在しない候補(iCloud Drive 無効環境など)を取り除く。
  static func existingCandidates(among candidates: [URL], fileManager: FileManager) -> [URL] {
    candidates.filter { fileManager.fileExists(atPath: $0.path) }
  }

  private var testNetworkLocation: SavedFolderLocation? {
    guard ProcessInfo.processInfo.environment["PKPANE_UI_TESTING"] == "1",
      ProcessInfo.processInfo.arguments.contains("-ui-test-network-saved-location"),
      let testFolderURL
    else {
      return nil
    }
    return SavedFolderLocation(
      id: UUID(),
      name: "PKPaneUITestNetwork",
      url: testFolderURL,
      smbLocation: SMBFolderLocation(
        host: "ui-test.local",
        shareName: "PKPaneUITestFixture",
        relativePathComponents: []))
  }

  private func recentLocationsIncludingTestNetworkLocation() throws -> [SavedFolderLocation] {
    includingTestNetworkLocation(try recentRepository.load())
  }

  private func includingTestNetworkLocation(
    _ locations: [SavedFolderLocation]
  ) -> [SavedFolderLocation] {
    guard let testNetworkLocation else { return locations }
    return locations + [testNetworkLocation]
  }

  @ObservationIgnored private var recentRecordingTask: Task<Void, Never>?

  func recordRecentLocation(_ location: FileLocation) {
    guard let url = location.localURL else { return }
    recordRecentLocation(url)
  }

  private func recordRecentLocation(_ url: URL) {
    let repository = recentRepository
    let previousTask = recentRecordingTask
    recentRecordingTask = Task { [weak self] in
      await previousTask?.value
      do {
        let locations = try await Task.detached(priority: .utility) {
          try repository.add(url)
        }.value
        self?.recentLocations = self?.includingTestNetworkLocation(locations) ?? locations
      } catch {
        // Macintosh HD のようにブックマークを作れない場所は履歴に載らないだけで、
        // ユーザーにできる対処はないため、画面には出さずログだけ残す。
        AppLog.notice(
          "recent location not saved: \(PKPaneErrorClassifier.classify(error).displayMessage)",
          category: "RecentLocations")
      }
    }
  }

  private func isWithinCurrentAccessRoot(_ url: URL) -> Bool {
    guard let accessRootURL else { return false }
    return isWithin(url, root: accessRootURL)
  }

  private func hasReadableAccess(to url: URL) -> Bool {
    let hasParentAccess =
      isWithinCurrentAccessRoot(url)
      || (homeAccessLease != nil && isWithin(url, root: homeDirectory))
      || (launchFolderAccessURL.map { isWithin(url, root: $0) } ?? false)
    return hasParentAccess && accessManager.isReadableDirectory(at: url)
  }

  private func isWithin(_ url: URL, root: URL) -> Bool {
    let rootPath = root.standardizedFileURL.pathComponents
    let candidatePath = url.standardizedFileURL.pathComponents
    return candidatePath.starts(with: rootPath)
  }

  @ObservationIgnored private var smbMountedFolderCache: [URL: Bool] = [:]
  @ObservationIgnored private var volumeObservers: [NSObjectProtocol] = []

  private func isSMBMountedFolder(_ folderURL: URL) -> Bool {
    let key = folderURL.standardizedFileURL
    if let cached = smbMountedFolderCache[key] {
      return cached
    }
    let result = computeIsSMBMountedFolder(key)
    smbMountedFolderCache[key] = result
    return result
  }

  private func computeIsSMBMountedFolder(_ folderURL: URL) -> Bool {
    let folderPathComponents = folderURL.standardizedFileURL.pathComponents
    let mountedVolumeURLs =
      FileManager.default.mountedVolumeURLs(
        includingResourceValuesForKeys: [.volumeURLForRemountingKey],
        options: [.skipHiddenVolumes]
      ) ?? []
    return mountedVolumeURLs.contains { volumeURL in
      guard folderPathComponents.starts(with: volumeURL.standardizedFileURL.pathComponents) else {
        return false
      }
      let resourceValues = try? volumeURL.resourceValues(
        forKeys: [.volumeURLForRemountingKey]
      )
      return resourceValues?.volumeURLForRemounting?.scheme?.lowercased() == "smb"
    }
  }

  private func shouldRestoreAtLaunch(_ folderURL: URL) -> Bool {
    guard !isSMBMountedFolder(folderURL) else { return false }
    let components = folderURL.standardizedFileURL.pathComponents
    guard components.count >= 3,
      components[1] == "Volumes"
    else {
      return true
    }
    let volumeURL = URL(
      fileURLWithPath: "/Volumes/\(components[2])",
      isDirectory: true)

    let mountedVolumeURLs =
      FileManager.default.mountedVolumeURLs(
        includingResourceValuesForKeys: [],
        options: [.skipHiddenVolumes]
      ) ?? []

    return mountedVolumeURLs.contains {
      $0.standardizedFileURL == volumeURL.standardizedFileURL
    }
  }
}
