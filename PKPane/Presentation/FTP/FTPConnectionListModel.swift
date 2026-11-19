import Foundation
import Observation

@Observable
@MainActor
final class FTPConnectionListModel {
  private let profileStore: FTPConnectionProfileStore
  private let connectionService: any FTPConnecting
  private let favoriteRepository: FTPFolderFavoriteRepository
  private let recentRepository: FTPFolderRecentRepository
  private let connectionLifecycle: FileProviderConnectionLifecycle

  private(set) var targets: [FTPConnectionTarget]
  private(set) var favoriteFolders: [FTPFolderFavorite]
  private(set) var recentFolders: [FTPFolderRecent]
  private(set) var connectingTargets: Set<FTPConnectionTarget> = []
  private(set) var connectedTargets: Set<FTPConnectionTarget> = []
  private(set) var errorMessage: String?
  private var clients: [FTPConnectionTarget: any FTPClientSession] = [:]

  init(
    profileStore: FTPConnectionProfileStore = FTPConnectionProfileStore(),
    connectionService: any FTPConnecting = FTPConnectionService(),
    favoriteRepository: FTPFolderFavoriteRepository = FTPFolderFavoriteRepository(),
    recentRepository: FTPFolderRecentRepository = FTPFolderRecentRepository(),
    connectionLifecycle: FileProviderConnectionLifecycle = FileProviderConnectionLifecycle()
  ) {
    self.profileStore = profileStore
    self.connectionService = connectionService
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

  func isFavorite(target: FTPConnectionTarget, directory: String) -> Bool {
    let directory = FTPConnectionTarget.normalizedAbsolutePath(directory)
    return favoriteFolders.contains { $0.target == target && $0.directory == directory }
  }

  func toggleFavorite(target: FTPConnectionTarget, directory: String) {
    favoriteFolders = favoriteRepository.toggle(target: target, directory: directory)
  }

  func removeFavorite(id: UUID) {
    favoriteFolders = favoriteRepository.remove(id: id)
  }

  func recordRecent(target: FTPConnectionTarget, directory: String) {
    recentFolders = recentRepository.record(target: target, directory: directory)
  }

  func removeRecent(id: UUID) {
    recentFolders = recentRepository.remove(id: id)
  }

  func openFavorite(
    _ favorite: FTPFolderFavorite,
    onConnected: @escaping (FTPFileProvider) -> Void
  ) {
    if let provider = provider(for: favorite.target) {
      onConnected(provider)
    } else {
      connect(favorite.target, onConnected: onConnected)
    }
  }

  func connect(
    _ target: FTPConnectionTarget,
    onConnected: @escaping (FTPFileProvider) -> Void = { _ in }
  ) {
    guard !connectedTargets.contains(target), connectingTargets.insert(target).inserted else {
      return
    }
    Task { [weak self] in
      guard let self else { return }
      do {
        let client = try await connectionService.connect(to: target)
        clients[target] = client
        connectedTargets.insert(target)
        errorMessage = nil
        onConnected(makeProvider(target: target, client: client))
      } catch {
        errorMessage = ConnectionErrorClassifier.guidanceMessage(for: error)
      }
      connectingTargets.remove(target)
    }
  }

  func isConnecting(_ target: FTPConnectionTarget) -> Bool {
    connectingTargets.contains(target)
  }

  func isConnected(_ target: FTPConnectionTarget) -> Bool {
    connectedTargets.contains(target)
  }

  func provider(for target: FTPConnectionTarget) -> FTPFileProvider? {
    guard let client = clients[target] else { return nil }
    return makeProvider(target: target, client: client)
  }

  func disconnect(_ target: FTPConnectionTarget) {
    guard let client = clients.removeValue(forKey: target) else { return }
    connectedTargets.remove(target)
    connectionLifecycle.didDisconnect(FTPFileProvider.connectionID(for: target))
    Task { await client.close() }
  }

  func remove(_ target: FTPConnectionTarget) {
    if connectedTargets.contains(target) { disconnect(target) }
    profileStore.remove(target)
    reload()
  }

  private func makeProvider(
    target: FTPConnectionTarget,
    client: any FTPClientSession
  ) -> FTPFileProvider {
    let connectionService = connectionService
    return FTPFileProvider(
      target: target,
      session: client,
      sessionFactory: { try await connectionService.connect(to: target) })
  }
}
