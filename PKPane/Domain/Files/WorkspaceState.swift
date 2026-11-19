import Foundation

enum WorkspaceRemoteProviderKind: String, Codable, Equatable, Sendable {
  case smb
  case sftp
  case ftp
}

enum WorkspaceLocationState: Codable, Equatable, Sendable {
  case local(bookmarkData: Data, lastKnownPath: String)
  case remote(
    providerKind: WorkspaceRemoteProviderKind,
    connectionID: String,
    path: String
  )

  private enum CodingKeys: String, CodingKey {
    case kind
    case bookmarkData
    case lastKnownPath
    case providerKind
    case connectionID
    case path
  }

  private enum Kind: String, Codable {
    case local
    case remote
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .local:
      self = .local(
        bookmarkData: try container.decode(Data.self, forKey: .bookmarkData),
        lastKnownPath: try container.decode(String.self, forKey: .lastKnownPath))
    case .remote:
      self = .remote(
        providerKind: try container.decode(
          WorkspaceRemoteProviderKind.self, forKey: .providerKind),
        connectionID: try container.decode(String.self, forKey: .connectionID),
        path: try container.decode(String.self, forKey: .path))
    }
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .local(let bookmarkData, let lastKnownPath):
      try container.encode(Kind.local, forKey: .kind)
      try container.encode(bookmarkData, forKey: .bookmarkData)
      try container.encode(lastKnownPath, forKey: .lastKnownPath)
    case .remote(let providerKind, let connectionID, let path):
      try container.encode(Kind.remote, forKey: .kind)
      try container.encode(providerKind, forKey: .providerKind)
      try container.encode(connectionID, forKey: .connectionID)
      try container.encode(path, forKey: .path)
    }
  }
}

struct WorkspaceTabState: Codable, Equatable, Sendable, Identifiable {
  let id: UUID
  let location: WorkspaceLocationState
  let viewMode: FileBrowserViewMode

  init(id: UUID, location: WorkspaceLocationState, viewMode: FileBrowserViewMode) {
    self.id = id
    self.location = location
    self.viewMode =
      FileBrowserViewMode.selectableCases.contains(viewMode) ? viewMode : .list
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case location
    case viewMode
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    location = try container.decode(WorkspaceLocationState.self, forKey: .location)
    let restoredViewMode = try container.decodeIfPresent(String.self, forKey: .viewMode)
      .flatMap(FileBrowserViewMode.init(rawValue:))
    viewMode =
      restoredViewMode.flatMap {
        FileBrowserViewMode.selectableCases.contains($0) ? $0 : nil
      } ?? .list
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(location, forKey: .location)
    try container.encode(viewMode.rawValue, forKey: .viewMode)
  }
}

struct WorkspacePaneState: Codable, Equatable, Sendable {
  let showsSecondaryPane: Bool
  let activePane: FolderPaneID
  let primaryTabID: UUID
  let secondaryTabID: UUID?
  let isSyncBrowsingEnabled: Bool

  init(
    showsSecondaryPane: Bool,
    activePane: FolderPaneID,
    primaryTabID: UUID,
    secondaryTabID: UUID?,
    isSyncBrowsingEnabled: Bool = false
  ) {
    self.showsSecondaryPane = showsSecondaryPane
    self.activePane = activePane
    self.primaryTabID = primaryTabID
    self.secondaryTabID = secondaryTabID
    self.isSyncBrowsingEnabled = isSyncBrowsingEnabled && showsSecondaryPane
  }

  private enum CodingKeys: String, CodingKey {
    case showsSecondaryPane
    case activePane
    case primaryTabID
    case secondaryTabID
    case isSyncBrowsingEnabled
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let showsSecondaryPane = try container.decode(Bool.self, forKey: .showsSecondaryPane)
    self.showsSecondaryPane = showsSecondaryPane
    activePane = try container.decode(FolderPaneID.self, forKey: .activePane)
    primaryTabID = try container.decode(UUID.self, forKey: .primaryTabID)
    secondaryTabID = try container.decodeIfPresent(UUID.self, forKey: .secondaryTabID)
    let restoredSyncBrowsing =
      try container.decodeIfPresent(Bool.self, forKey: .isSyncBrowsingEnabled) ?? false
    isSyncBrowsingEnabled = showsSecondaryPane && restoredSyncBrowsing
  }
}

struct WorkspaceState: Codable, Equatable, Sendable {
  static let currentVersion = 1

  let version: Int
  let tabs: [WorkspaceTabState]
  let activeTabID: UUID
  let pane: WorkspacePaneState

  init(
    version: Int = WorkspaceState.currentVersion,
    tabs: [WorkspaceTabState],
    activeTabID: UUID,
    pane: WorkspacePaneState
  ) {
    self.version = version
    self.tabs = tabs
    self.activeTabID = activeTabID
    self.pane = pane
  }
}

struct WorkspaceStateCodec: Sendable {
  func encode(_ state: WorkspaceState) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(state)
  }

  func decode(_ data: Data) throws -> WorkspaceState {
    try JSONDecoder().decode(WorkspaceState.self, from: data)
  }
}

protocol WorkspaceStateStoring: Sendable {
  func load() throws -> WorkspaceState?
  func save(_ state: WorkspaceState) throws
}

struct JSONWorkspaceStateStore: WorkspaceStateStoring {
  let url: URL
  private let codec = WorkspaceStateCodec()

  init(
    url: URL? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    arguments: [String] = ProcessInfo.processInfo.arguments
  ) {
    if let url {
      self.url = url
      return
    }
    self.url = Self.defaultURL(environment: environment, arguments: arguments)
  }

  static func defaultURL(
    environment: [String: String],
    arguments: [String]
  ) -> URL {
    if environment["PKPANE_UI_TESTING"] == "1",
      let pathIndex = arguments.firstIndex(of: "-ui-test-folder-path"),
      arguments.indices.contains(pathIndex + 1)
    {
      return URL(filePath: arguments[pathIndex + 1], directoryHint: .isDirectory)
        .appending(path: ".pkpane-ui-test-workspace.json")
    }
    if TestEnvironmentDetector.isRunningTests(environment: environment) {
      return FileManager.default.temporaryDirectory
        .appending(
          path: "PKPaneWorkspaceTests-\(ProcessInfo.processInfo.processIdentifier)",
          directoryHint: .isDirectory
        )
        .appending(path: "workspace.json")
    }
    let directory = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first!.appending(path: "PKPane", directoryHint: .isDirectory)
    return directory.appending(path: "workspace.json")
  }

  func load() throws -> WorkspaceState? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try codec.decode(Data(contentsOf: url))
  }

  func save(_ state: WorkspaceState) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try codec.encode(state).write(to: url, options: .atomic)
  }
}

@MainActor
struct WorkspaceBrowserFactory {
  private let bookmarkCodec: any FolderBookmarkCoding
  private let fileManager: FileManager
  private let homeDirectory: URL
  private let accessManager: FolderBookmarkAccessManager
  private let transferQueue: TransferQueue
  private let inheritedAccessLease: (@MainActor (URL) -> WorkspaceBookmarkAccessLease?)?

  init(
    bookmarkCodec: any FolderBookmarkCoding = SystemFolderBookmarkCodec(),
    fileManager: FileManager = .default,
    homeDirectory: URL = UserHomeDirectory.current,
    accessManager: FolderBookmarkAccessManager = FolderBookmarkAccessManager(),
    transferQueue: TransferQueue = .shared,
    inheritedAccessLease: (@MainActor (URL) -> WorkspaceBookmarkAccessLease?)? = nil
  ) {
    self.bookmarkCodec = bookmarkCodec
    self.fileManager = fileManager
    self.homeDirectory = homeDirectory
    self.accessManager = accessManager
    self.transferQueue = transferQueue
    self.inheritedAccessLease = inheritedAccessLease
  }

  func makeBrowser(for location: WorkspaceLocationState) -> FileBrowserSession {
    switch location {
    case .local(let bookmarkData, let lastKnownPath):
      let resolvedURL = try? bookmarkCodec.resolveBookmark(bookmarkData).url
      let candidateURL = resolvedURL ?? URL(filePath: lastKnownPath)
      if UserHomeDirectory.isAppContainerHome(candidateURL, home: homeDirectory) {
        return makeLocalBrowser(at: homeDirectory)
      }
      let accessLease =
        resolvedURL.flatMap {
          try? WorkspaceBookmarkAccessLease(url: $0, manager: accessManager)
        } ?? inheritedAccessLease?(candidateURL)
      guard let accessLease else {
        return makeLocalBrowser(at: homeDirectory)
      }
      // Sandboxではブックマークのアクセス開始後に存在を確認する。
      guard isExistingDirectory(candidateURL) else {
        return makeLocalBrowser(at: homeDirectory)
      }
      return makeLocalBrowser(at: candidateURL, accessLease: accessLease)
    case .remote(let providerKind, let connectionID, let path):
      let provider = WorkspaceRemotePlaceholderProvider(
        providerKind: providerKind,
        connectionID: connectionID)
      return FileBrowserSession(
        provider: provider,
        initialLocation: FileLocation(remotePath: path, providerID: provider.id),
        transferQueue: transferQueue)
    }
  }

  private func makeLocalBrowser(
    at url: URL,
    accessLease: WorkspaceBookmarkAccessLease? = nil
  ) -> FileBrowserSession {
    let provider = LocalFileProvider()
    return FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(directoryURL: url, providerID: provider.id),
      transferQueue: transferQueue,
      workspaceBookmarkAccessLease: accessLease)
  }

  private func isExistingDirectory(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }
}

@MainActor
final class WorkspaceBookmarkAccessLease {
  private let url: URL
  private let manager: FolderBookmarkAccessManager

  var rootURL: URL { url }

  init(
    url: URL, manager: FolderBookmarkAccessManager, requiresSecurityScope: Bool = false
  ) throws {
    self.url = url
    self.manager = manager
    try manager.beginAccess(to: url, requiresSecurityScope: requiresSecurityScope)
  }

  isolated deinit {
    manager.endAccess(to: url)
  }
}

struct WorkspaceRemotePlaceholderProvider: FileBrowserProvider {
  let providerKind: WorkspaceRemoteProviderKind
  let restoredConnectionID: String
  let id: FileProviderID
  let connectionID: FileProviderConnectionID?
  let capabilities: FileProviderCapabilities = []

  init(providerKind: WorkspaceRemoteProviderKind, connectionID: String) {
    self.providerKind = providerKind
    restoredConnectionID = connectionID
    let providerID = FileProviderID(
      rawValue: "workspace-placeholder-\(providerKind.rawValue)-\(connectionID)")
    id = providerID
    self.connectionID = FileProviderConnectionID(rawValue: providerID.rawValue)
  }

  func contents(of _: FileLocation) async throws -> [FileItem] { [] }

  func parent(of location: FileLocation) -> FileLocation? {
    location.deletingLastPathComponent()
  }

  func breadcrumbs(
    for location: FileLocation,
    constrainedTo _: FileLocation?
  ) -> [FileBrowserBreadcrumb] {
    guard let path = location.remotePath else { return [] }
    return [FileBrowserBreadcrumb(location: location, name: path)]
  }
}

@MainActor
final class WorkspacePersistenceController {
  private let store: any WorkspaceStateStoring
  private let bookmarkCodec: any FolderBookmarkCoding
  private let debounceDuration: Duration
  private var pendingSaveTask: Task<Void, Never>?
  private var pendingSaveToken: UUID?

  init(
    store: any WorkspaceStateStoring = JSONWorkspaceStateStore(),
    bookmarkCodec: any FolderBookmarkCoding = SystemFolderBookmarkCodec(),
    debounceDuration: Duration = .milliseconds(500)
  ) {
    self.store = store
    self.bookmarkCodec = bookmarkCodec
    self.debounceDuration = debounceDuration
  }

  var hasPendingSave: Bool { pendingSaveTask != nil }

  func load() -> WorkspaceState? {
    guard let state = try? store.load(),
      state.version == WorkspaceState.currentVersion,
      !state.tabs.isEmpty
    else {
      return nil
    }
    return state
  }

  func scheduleSave(of workspace: FileWorkspaceModel) {
    pendingSaveTask?.cancel()
    let token = UUID()
    pendingSaveToken = token
    pendingSaveTask = Task { [weak self, weak workspace] in
      do {
        try await Task.sleep(for: self?.debounceDuration ?? .milliseconds(500))
      } catch {
        return
      }
      guard let self, let workspace, self.pendingSaveToken == token else { return }
      self.persist(workspace)
      if self.pendingSaveToken == token {
        self.pendingSaveTask = nil
        self.pendingSaveToken = nil
      }
    }
  }

  func saveNow(_ workspace: FileWorkspaceModel) {
    pendingSaveTask?.cancel()
    pendingSaveTask = nil
    pendingSaveToken = nil
    persist(workspace)
  }

  private func persist(_ workspace: FileWorkspaceModel) {
    guard let state = try? workspace.makeState(bookmarkCodec: bookmarkCodec) else { return }
    try? store.save(state)
  }
}
