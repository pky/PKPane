import Foundation
import Observation

@Observable
@MainActor
final class SFTPConnectionListModel {
  private let profileStore: SFTPConnectionProfileStore
  private let connectionService: any SFTPConnecting
  private let hostKeyTrustStore: SFTPHostKeyTrustStore
  private let favoriteRepository: SFTPFolderFavoriteRepository
  private let recentRepository: SFTPFolderRecentRepository
  private let connectionLifecycle: FileProviderConnectionLifecycle

  private(set) var targets: [SFTPConnectionTarget]
  private(set) var favoriteFolders: [SFTPFolderFavorite]
  private(set) var recentFolders: [SFTPFolderRecent]
  private(set) var connectingTargets: Set<SFTPConnectionTarget> = []
  private(set) var connectedTargets: Set<SFTPConnectionTarget> = []
  private(set) var pendingHostKeys: [SFTPConnectionTarget: SFTPHostKeyApprovalRequest] = [:]
  private(set) var changedHostKeys: [SFTPConnectionTarget: SFTPHostKeyApprovalRequest] = [:]
  private(set) var errorMessage: String?
  private var clients: [SFTPConnectionTarget: any SFTPClientSession] = [:]
  private var providers: [SFTPConnectionTarget: SFTPFileProvider] = [:]
  private var pendingOpenHandlers: [SFTPConnectionTarget: (SFTPFileProvider) -> Void] = [:]
  @ObservationIgnored private var pendingApprovalHandlers:
    [SFTPConnectionTarget:
      @MainActor (SFTPConnectionTarget, SFTPHostKeyApprovalRequest, Bool) -> Void] = [:]
  @ObservationIgnored private var favoriteChangeHandler: (@MainActor () -> Void)?

  init(
    profileStore: SFTPConnectionProfileStore = SFTPConnectionProfileStore(),
    connectionService: (any SFTPConnecting)? = nil,
    hostKeyTrustStore: SFTPHostKeyTrustStore = SFTPHostKeyTrustStore(),
    favoriteRepository: SFTPFolderFavoriteRepository = SFTPFolderFavoriteRepository(),
    recentRepository: SFTPFolderRecentRepository = SFTPFolderRecentRepository(),
    connectionLifecycle: FileProviderConnectionLifecycle = FileProviderConnectionLifecycle()
  ) {
    self.profileStore = profileStore
    self.connectionService = connectionService ?? Self.defaultConnectionService()
    self.hostKeyTrustStore = hostKeyTrustStore
    self.favoriteRepository = favoriteRepository
    self.recentRepository = recentRepository
    self.connectionLifecycle = connectionLifecycle
    targets = profileStore.loadAll()
    favoriteFolders = favoriteRepository.load()
    recentFolders = recentRepository.load()
  }

  func reload() {
    targets = profileStore.loadAll()
    favoriteFolders = favoriteRepository.load()
    recentFolders = recentRepository.load()
  }

  func isFavorite(target: SFTPConnectionTarget, directory: String) -> Bool {
    favoriteFolders.contains { $0.target == target && $0.directory == directory }
  }

  func toggleFavorite(target: SFTPConnectionTarget, directory: String) {
    favoriteFolders = favoriteRepository.toggle(target: target, directory: directory)
    favoriteChangeHandler?()
  }

  func removeFavorite(id: UUID) {
    favoriteFolders = favoriteRepository.remove(id: id)
    favoriteChangeHandler?()
  }

  func setFavoriteChangeHandler(_ handler: @escaping @MainActor () -> Void) {
    favoriteChangeHandler = handler
  }

  func portableFavorites() throws -> [PortableFavorite] {
    try favoriteRepository.portableFavorites()
  }

  func applySyncedFavorites(_ document: FavoriteSyncDocument) {
    favoriteFolders = favoriteRepository.applySyncedFavorites(document)
  }

  func recordRecent(target: SFTPConnectionTarget, directory: String) {
    recentFolders = recentRepository.record(target: target, directory: directory)
  }

  func removeRecent(id: UUID) {
    recentFolders = recentRepository.remove(id: id)
  }

  func openFavorite(
    _ favorite: SFTPFolderFavorite,
    onConnected: @escaping (SFTPFileProvider) -> Void
  ) {
    if let provider = provider(for: favorite.target) {
      onConnected(provider)
    } else {
      connect(favorite.target, onConnected: onConnected)
    }
  }

  func connect(
    _ target: SFTPConnectionTarget,
    onConnected: @escaping (SFTPFileProvider) -> Void = { _ in },
    onHostKeyApproval:
      @escaping @MainActor (
        SFTPConnectionTarget, SFTPHostKeyApprovalRequest, Bool
      ) -> Void = {
        _, _, _ in
      }
  ) {
    guard !connectedTargets.contains(target),
      connectingTargets.insert(target).inserted
    else { return }
    let identity = "host=\(target.host) port=\(target.port) user=\(target.username)"
    AppLog.notice("connect scheduled \(identity)", category: "SFTPConnect")
    Task { [weak self] in
      guard let self else { return }
      defer { connectingTargets.remove(target) }
      AppLog.notice("connect started \(identity)", category: "SFTPConnect")
      do {
        let client = try await connectionService.connect(to: target)
        AppLog.notice("connect succeeded \(identity)", category: "SFTPConnect")
        clients[target] = client
        connectedTargets.insert(target)
        pendingOpenHandlers.removeValue(forKey: target)
        pendingApprovalHandlers.removeValue(forKey: target)
        errorMessage = nil
        let provider = SFTPFileProvider(
          target: target,
          directoryListing: client)
        await provider.resolveHomeDirectory()
        guard clients[target] != nil else { return }
        providers[target] = provider
        onConnected(provider)
      } catch {
        AppLog.notice(
          "connect failed \(identity) error=\(String(describing: type(of: error)))",
          category: "SFTPConnect")
        if case SFTPConnectionServiceError.hostKeyRequiresApproval(let request) = error {
          pendingHostKeys[target] = request
          pendingApprovalHandlers[target] = onHostKeyApproval
          pendingOpenHandlers[target] = onConnected
          onHostKeyApproval(target, request, false)
        } else if case SFTPConnectionServiceError.hostKeyChanged(let request) = error {
          changedHostKeys[target] = request
          pendingApprovalHandlers[target] = onHostKeyApproval
          pendingOpenHandlers[target] = onConnected
          onHostKeyApproval(target, request, true)
        } else {
          pendingOpenHandlers.removeValue(forKey: target)
          pendingApprovalHandlers.removeValue(forKey: target)
        }
        errorMessage = ConnectionErrorClassifier.guidanceMessage(for: error)
      }
    }
  }

  func isConnecting(_ target: SFTPConnectionTarget) -> Bool {
    connectingTargets.contains(target)
  }

  func isConnected(_ target: SFTPConnectionTarget) -> Bool {
    connectedTargets.contains(target)
  }

  func pendingHostKey(for target: SFTPConnectionTarget) -> String? {
    pendingHostKeys[target]?.publicKey
  }

  func changedHostKey(for target: SFTPConnectionTarget) -> String? {
    changedHostKeys[target]?.publicKey
  }

  func pendingHostKeyRequest(for target: SFTPConnectionTarget) -> SFTPHostKeyApprovalRequest? {
    pendingHostKeys[target]
  }

  func changedHostKeyRequest(for target: SFTPConnectionTarget) -> SFTPHostKeyApprovalRequest? {
    changedHostKeys[target]
  }

  func approveHostKey(for target: SFTPConnectionTarget) {
    guard let request = pendingHostKeys.removeValue(forKey: target) else { return }
    trustHostKey(request, for: target)
  }

  func approveChangedHostKey(for target: SFTPConnectionTarget) {
    guard let request = changedHostKeys.removeValue(forKey: target) else { return }
    trustHostKey(request, for: target)
  }

  private func trustHostKey(
    _ request: SFTPHostKeyApprovalRequest,
    for target: SFTPConnectionTarget
  ) {
    let host = request.host.isEmpty ? target.host : request.host
    hostKeyTrustStore.trust(
      openSSHPublicKey: request.publicKey,
      host: host,
      port: request.host.isEmpty ? target.port : request.port)
    let onConnected = pendingOpenHandlers.removeValue(forKey: target) ?? { _ in }
    let onHostKeyApproval = pendingApprovalHandlers.removeValue(forKey: target) ?? { _, _, _ in }
    connect(target, onConnected: onConnected, onHostKeyApproval: onHostKeyApproval)
  }

  /// 接続情報そのものを削除する(NAS側の削除導線と揃えるためのUI parity)。接続中であれば
  /// 先に切断してから削除する。保留中のホスト鍵承認状態も併せて破棄する。
  func remove(_ target: SFTPConnectionTarget) {
    if connectedTargets.contains(target) {
      disconnect(target)
    }
    pendingHostKeys.removeValue(forKey: target)
    changedHostKeys.removeValue(forKey: target)
    pendingApprovalHandlers.removeValue(forKey: target)
    pendingOpenHandlers.removeValue(forKey: target)
    profileStore.remove(target)
    reload()
  }

  func disconnect(_ target: SFTPConnectionTarget) {
    guard let client = clients.removeValue(forKey: target) else { return }
    providers.removeValue(forKey: target)
    connectedTargets.remove(target)
    pendingOpenHandlers.removeValue(forKey: target)
    pendingHostKeys.removeValue(forKey: target)
    changedHostKeys.removeValue(forKey: target)
    pendingApprovalHandlers.removeValue(forKey: target)
    connectionLifecycle.didDisconnect(SFTPFileProvider.connectionID(for: target))
    Task {
      do {
        try await client.close()
      } catch {
        errorMessage = PKPaneErrorClassifier.classify(error).displayMessage
      }
    }
  }

  func provider(for target: SFTPConnectionTarget) -> SFTPFileProvider? {
    providers[target]
  }

  static func defaultConnectionService(
    credentialPrompter: any SFTPCredentialPrompting = SFTPNoPromptCredentialPrompter()
  ) -> any SFTPConnecting {
    let environment = ProcessInfo.processInfo.environment
    guard environment["PKPANE_UI_TESTING"] == "1",
      environment["PKPANE_UI_TEST_SFTP_HOST_KEY"] == "1"
    else {
      return CitadelSFTPConnectionService(credentialPrompter: credentialPrompter)
    }
    return SFTPUITestHostKeyConnectionService()
  }
}

private actor SFTPUITestHostKeyConnectionService: SFTPConnecting {
  private var connectionCount = 0

  func connect(to _: SFTPConnectionTarget) async throws -> any SFTPClientSession {
    connectionCount += 1
    if connectionCount == 1 {
      throw SFTPConnectionServiceError.hostKeyRequiresApproval(
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestHostKey")
    }
    return SFTPUITestSFTPClientSession()
  }
}

private actor SFTPUITestSFTPClientSession: SFTPClientSession {
  private var entries: [String: [SFTPDirectoryEntry]] = [
    "/srv/projects": [
      SFTPDirectoryEntry(name: "Reports", isDirectory: true),
      SFTPDirectoryEntry(name: "guide.txt", isDirectory: false),
      SFTPDirectoryEntry(name: "readme.txt", isDirectory: false),
    ],
    "/srv/projects/Reports": [SFTPDirectoryEntry(name: "monthly.txt", isDirectory: false)],
  ]
  private var fileContentsByPath: [String: Data] = [
    "/srv/projects/guide.txt": Data("SFTP UI テスト用ガイド".utf8),
    "/srv/projects/readme.txt": Data("SFTP UI テスト用テキスト".utf8),
    "/srv/projects/Reports/monthly.txt": Data("月次レポート".utf8),
  ]

  func contents(of path: String) async throws -> [SFTPDirectoryEntry] {
    entries[path] ?? []
  }

  func createDirectory(at path: String) async throws {
    let parent = parentPath(of: path)
    entries[parent, default: []].append(
      SFTPDirectoryEntry(name: fileName(of: path), isDirectory: true))
    entries[path] = []
  }

  func remove(at path: String, isDirectory _: Bool) async throws {
    let parent = parentPath(of: path)
    entries[parent]?.removeAll { $0.name == fileName(of: path) }
    entries[path] = nil
  }

  func rename(at path: String, to destinationPath: String) async throws {
    let parent = parentPath(of: path)
    guard let entry = entries[parent]?.first(where: { $0.name == fileName(of: path) }) else {
      return
    }
    entries[parent]?.removeAll { $0.name == fileName(of: path) }
    let destinationParent = parentPath(of: destinationPath)
    entries[destinationParent, default: []].append(
      SFTPDirectoryEntry(name: fileName(of: destinationPath), isDirectory: entry.isDirectory))
  }

  func copy(at path: String, to destinationPath: String) async throws {
    try await Task.sleep(for: .milliseconds(300))
    let parent = parentPath(of: path)
    guard let entry = entries[parent]?.first(where: { $0.name == fileName(of: path) }) else {
      return
    }
    let destinationParent = parentPath(of: destinationPath)
    entries[destinationParent, default: []].append(
      SFTPDirectoryEntry(name: fileName(of: destinationPath), isDirectory: entry.isDirectory))
  }

  func fileContents(of path: String) async throws -> Data {
    fileContentsByPath[path] ?? Data()
  }

  func streamFileContents(
    of path: String,
    chunkSize _: Int,
    receive: @escaping @Sendable (Data) async throws -> Void
  ) async throws {
    try await receive(fileContentsByPath[path] ?? Data())
  }

  func writeFileContents(
    to path: String,
    chunks: AsyncThrowingStream<Data, Error>,
    replacingExisting _: Bool,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws {
    var contents = Data()
    for try await chunk in chunks {
      contents.append(chunk)
      progress(Int64(contents.count))
    }
    fileContentsByPath[path] = contents
    let parent = parentPath(of: path)
    if let index = entries[parent]?.firstIndex(where: { $0.name == fileName(of: path) }) {
      entries[parent]?[index] = SFTPDirectoryEntry(
        name: fileName(of: path),
        isDirectory: false,
        size: Int64(contents.count),
        modifiedAt: .now)
    } else {
      entries[parent, default: []].append(
        SFTPDirectoryEntry(
          name: fileName(of: path),
          isDirectory: false,
          size: Int64(contents.count),
          modifiedAt: .now))
    }
  }

  func close() async throws {}
  private func parentPath(of path: String) -> String {
    let components = path.split(separator: "/")
    guard components.count > 1 else { return "/" }
    return "/" + components.dropLast().joined(separator: "/")
  }

  private func fileName(of path: String) -> String {
    path.split(separator: "/").last.map(String.init) ?? ""
  }
}
