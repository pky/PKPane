import Foundation
import Observation

enum NASConnectionStatus: Equatable {
  case disconnected
  case connected(SMBMountedVolume)

  var displayName: String {
    switch self {
    case .disconnected:
      String(localized: "未接続")
    case .connected:
      String(localized: "接続済み")
    }
  }
}

@Observable
@MainActor
final class NASConnectionListModel {
  private let profileStore: NASConnectionProfileStore
  private let recentConnectionStore: RecentSMBConnectionStore
  private let bookmarkRepository: NASConnectionBookmarkRepository
  private let mountService: any SMBMountConnecting
  private let connectionLifecycle: FileProviderConnectionLifecycle
  private let mountedVolumeProvider: () -> [SMBMountedVolume]

  private(set) var profiles: [NASConnectionProfile]
  private(set) var errorMessage: String?
  private(set) var mountedVolumes: [NASConnectionProfile.ID: SMBMountedVolume] = [:]
  private(set) var unregisteredMountedVolumes: [SMBMountedVolume] = []
  private(set) var recentConnections: [RecentSMBConnection] = []
  private(set) var lastUnmountedVolumeURL: URL?
  private var disconnectingVolumeURLs: Set<URL> = []
  private var connectingConnectionIDs: Set<String> = []
  private var mountObserver: SMBMountObserver?

  init(
    profileStore: NASConnectionProfileStore = NASConnectionProfileStore(),
    recentConnectionStore: RecentSMBConnectionStore = RecentSMBConnectionStore(),
    bookmarkRepository: NASConnectionBookmarkRepository = NASConnectionBookmarkRepository(),
    mountService: any SMBMountConnecting = SystemSMBMountService(),
    connectionLifecycle: FileProviderConnectionLifecycle = FileProviderConnectionLifecycle(),
    mountedVolumeProvider: (() -> [SMBMountedVolume])? = nil
  ) {
    self.profileStore = profileStore
    self.recentConnectionStore = recentConnectionStore
    self.bookmarkRepository = bookmarkRepository
    self.mountService = mountService
    self.connectionLifecycle = connectionLifecycle
    self.mountedVolumeProvider = mountedVolumeProvider ?? Self.systemMountedVolumes
    profiles = profileStore.load()
    recentConnections = recentConnectionStore.load()
    mountObserver = SMBMountObserver { [weak self] event in
      self?.handleMountEvent(event)
    }
    mountObserver?.start()
    refreshMountedVolumes()
  }

  func reload() {
    profiles = profileStore.load()
    refreshMountedVolumes()
  }

  func connect(
    _ profile: NASConnectionProfile,
    onConnected: @escaping (URL) -> Void = { _ in }
  ) {
    startConnection(profile, savesProfileOnSuccess: false, onConnected: onConnected)
  }

  /// Finder等で接続済みなら再認証せず既存共有を使い、複数共有はユーザーに選択を委ねる。
  func openConnection(
    _ profile: NASConnectionProfile,
    savesProfile: Bool = false,
    onMounted: (SMBMountedVolume) -> Void,
    onSelectMounted: ([SMBMountedVolume]) -> Void,
    onConnected: @escaping (URL) -> Void
  ) {
    if savesProfile { update(profile) }
    let existing = existingMountedVolumes(for: profile)
    if existing.count == 1, let volume = existing.first {
      onMounted(volume)
    } else if !existing.isEmpty {
      onSelectMounted(existing)
    } else {
      connect(profile, onConnected: onConnected)
    }
  }

  func existingMountedVolumes(for profile: NASConnectionProfile) -> [SMBMountedVolume] {
    guard let share = try? profile.smbShare() else { return [] }
    var seen = Set<URL>()
    return (Array(mountedVolumes.values) + unregisteredMountedVolumes).filter { volume in
      guard seen.insert(volume.volumeURL).inserted else { return false }
      if !share.shareName.isEmpty { return volume.matches(share) }
      return volume.remountingURL.scheme?.lowercased() == "smb"
        && volume.remountingURL.host?.caseInsensitiveCompare(share.host) == .orderedSame
    }
  }

  func mountedVolume(containing folderURL: URL) -> SMBMountedVolume? {
    let components = folderURL.standardizedFileURL.pathComponents
    return (Array(mountedVolumes.values) + unregisteredMountedVolumes)
      .filter { components.starts(with: $0.volumeURL.standardizedFileURL.pathComponents) }
      .max { $0.volumeURL.pathComponents.count < $1.volumeURL.pathComponents.count }
  }

  func connectNew(
    _ profile: NASConnectionProfile,
    onConnected: @escaping (URL) -> Void = { _ in }
  ) {
    startConnection(profile, savesProfileOnSuccess: true, onConnected: onConnected)
  }

  func clearError() {
    errorMessage = nil
  }

  func update(_ profile: NASConnectionProfile) {
    if let existingProfile = profiles.first(where: { $0.id == profile.id }),
      existingProfile.host != profile.host || existingProfile.shareName != profile.shareName
    {
      bookmarkRepository.remove(for: profile.id)
    }
    profileStore.save(profile)
    profiles = profileStore.load()
    refreshMountedVolumes()
  }

  func connect(
    _ recentConnection: RecentSMBConnection,
    onConnected: @escaping (URL) -> Void = { _ in }
  ) {
    if let share = try? recentConnection.smbShare(),
      let volume = (Array(mountedVolumes.values) + unregisteredMountedVolumes).first(where: {
        $0.matches(share)
      })
    {
      onConnected(volume.volumeURL)
      return
    }
    let connectionID = connectionID(for: recentConnection)
    guard connectingConnectionIDs.insert(connectionID).inserted else { return }
    do {
      let share = try recentConnection.smbShare()
      mountService.connect(to: share) { [weak self] result in
        guard let self else { return }
        self.connectingConnectionIDs.remove(connectionID)
        switch result {
        case .success(let volumeURLs):
          self.refreshMountedVolumes()
          self.recentConnections = self.recentConnectionStore.record(recentConnection)
          self.errorMessage = nil
          if let volumeURL = volumeURLs.first {
            onConnected(volumeURL)
          }
        case .failure(let error):
          self.errorMessage = ConnectionErrorClassifier.guidanceMessage(for: error)
        }
      }
    } catch {
      connectingConnectionIDs.remove(connectionID)
      errorMessage = PKPaneErrorClassifier.classify(error).displayMessage
    }
  }

  func removeRecent(id: String) {
    recentConnections = recentConnectionStore.remove(id: id)
  }

  func disconnect(
    _ profile: NASConnectionProfile,
    onDetached: @escaping (URL) -> Void = { _ in }
  ) {
    guard let volume = mountedVolumes[profile.id] else { return }
    disconnect(volume, onDetached: onDetached)
  }

  func disconnect(
    _ volume: SMBMountedVolume,
    onDetached: @escaping (URL) -> Void = { _ in }
  ) {
    let volumeURL = volume.volumeURL
    guard disconnectingVolumeURLs.insert(volumeURL).inserted else { return }

    mountedVolumes = mountedVolumes.filter { $0.value.volumeURL != volumeURL }
    unregisteredMountedVolumes.removeAll { $0.volumeURL == volumeURL }
    connectionLifecycle.didDisconnect(.smb(volumeURL: volumeURL))
    errorMessage = nil
    onDetached(volumeURL)

    mountService.disconnect(volumeURL: volumeURL) { [weak self] result in
      guard let self else { return }
      switch result {
      case .success:
        break
      case .failure:
        self.disconnectingVolumeURLs.remove(volumeURL)
        self.refreshMountedVolumes()
        self.errorMessage = SMBMountError.disconnectionFailed.errorDescription
      }
    }
  }

  @discardableResult
  func connectSavedLocation(
    _ location: SavedFolderLocation,
    onConnected: @escaping (URL) -> Void
  ) -> Bool {
    guard location.url == nil else { return false }
    if let smbLocation = location.smbLocation,
      let mountedVolume = mountedVolume(for: smbLocation)
    {
      onConnected(folderURL(in: mountedVolume.volumeURL, for: smbLocation.relativePathComponents))
      return true
    }
    guard let target = disconnectedTarget(for: location) else { return false }

    let openTarget: (URL) -> Void = { volumeURL in
      onConnected(self.folderURL(in: volumeURL, for: target.relativePathComponents))
    }
    switch target.connection {
    case .profile(let profile):
      connectToVolumeRoot(profile, savesProfileOnSuccess: false, onVolumeMounted: openTarget)
    case .recent(let connection):
      connect(connection, onConnected: openTarget)
    }
    return true
  }

  func canReconnectSavedLocation(_ location: SavedFolderLocation) -> Bool {
    disconnectedTarget(for: location) != nil
  }

  func isConnecting(_ profile: NASConnectionProfile) -> Bool {
    connectingConnectionIDs.contains(connectionID(for: profile))
  }

  func isConnecting(_ connection: RecentSMBConnection) -> Bool {
    connectingConnectionIDs.contains(connectionID(for: connection))
  }

  func isConnectingSavedLocation(_ location: SavedFolderLocation) -> Bool {
    guard let target = disconnectedTarget(for: location) else { return false }
    return isConnecting(target)
  }

  func status(for profile: NASConnectionProfile) -> NASConnectionStatus {
    if let volume = mountedVolumes[profile.id] {
      .connected(volume)
    } else {
      .disconnected
    }
  }

  func provider(for profile: NASConnectionProfile) -> MountedVolumeProvider? {
    guard let volume = mountedVolumes[profile.id] else { return nil }
    return MountedVolumeProvider(profile: profile, volumeURL: volume.volumeURL)
  }

  func provider(for volume: SMBMountedVolume) -> MountedVolumeProvider {
    if let profile = profiles.first(where: {
      mountedVolumes[$0.id]?.volumeURL.standardizedFileURL == volume.volumeURL.standardizedFileURL
    }) {
      return MountedVolumeProvider(profile: profile, volumeURL: volume.volumeURL)
    }
    return MountedVolumeProvider(volumeURL: volume.volumeURL)
  }

  func mountedFolder(for location: SavedFolderLocation) -> SavedMountedFolder? {
    guard let smbLocation = location.smbLocation,
      let volume = mountedVolume(for: smbLocation)
    else {
      return nil
    }
    return SavedMountedFolder(
      volume: volume,
      folderURL: folderURL(in: volume.volumeURL, for: smbLocation.relativePathComponents))
  }

  func remove(_ profile: NASConnectionProfile) {
    profileStore.remove(id: profile.id)
    bookmarkRepository.remove(for: profile.id)
    mountedVolumes.removeValue(forKey: profile.id)
    reload()
  }

  func saveBookmark(_ folderURL: URL, for profile: NASConnectionProfile) {
    do {
      try bookmarkRepository.save(folderURL, for: profile.id)
      errorMessage = nil
    } catch {
      errorMessage = PKPaneErrorClassifier.classify(error).displayMessage
    }
  }

  func handleMountEvent(_ event: SMBMountEvent) {
    switch event {
    case .mounted(let volume):
      guard !disconnectingVolumeURLs.contains(volume.volumeURL) else { return }
      recordRecentConnection(for: volume)
      if !associate(volume),
        !unregisteredMountedVolumes.contains(where: { $0.volumeURL == volume.volumeURL })
      {
        unregisteredMountedVolumes.append(volume)
      }
    case .unmounted(let volume):
      disconnectingVolumeURLs.remove(volume.volumeURL)
      mountedVolumes = mountedVolumes.filter { $0.value.volumeURL != volume.volumeURL }
      unregisteredMountedVolumes.removeAll { $0.volumeURL == volume.volumeURL }
      connectionLifecycle.didDisconnect(.smb(volumeURL: volume.volumeURL))
      lastUnmountedVolumeURL = volume.volumeURL
    }
  }

  private func refreshMountedVolumes() {
    mountedVolumes.removeAll()
    unregisteredMountedVolumes.removeAll()
    for volume in mountedVolumeProvider() {
      guard !disconnectingVolumeURLs.contains(volume.volumeURL) else { continue }
      recordRecentConnection(for: volume)
      if !associate(volume) {
        unregisteredMountedVolumes.append(volume)
      }
    }
  }

  private static func systemMountedVolumes() -> [SMBMountedVolume] {
    let urls =
      FileManager.default.mountedVolumeURLs(
        includingResourceValuesForKeys: [.volumeURLForRemountingKey],
        options: [.skipHiddenVolumes]
      ) ?? []
    return urls.compactMap { volumeURL in
      guard
        let resourceValues =
          try? volumeURL.resourceValues(forKeys: [.volumeURLForRemountingKey]),
        let remountingURL = resourceValues.volumeURLForRemounting,
        remountingURL.scheme?.lowercased() == "smb"
      else {
        return nil
      }
      return SMBMountedVolume(volumeURL: volumeURL, remountingURL: remountingURL)
    }
  }

  @discardableResult
  private func associate(_ volume: SMBMountedVolume) -> Bool {
    var didAssociate = false
    for profile in profiles where (try? profile.smbShare()).map(volume.matches) == true {
      mountedVolumes[profile.id] = volume
      didAssociate = true
    }
    return didAssociate
  }

  private func recordRecentConnection(for volume: SMBMountedVolume) {
    guard let connection = RecentSMBConnection(volume: volume) else { return }
    recentConnections = recentConnectionStore.record(connection)
  }

  private func disconnectedTarget(forPath path: String) -> DisconnectedSMBTarget? {
    let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
    guard components.count >= 3, components[1] == "Volumes" else { return nil }

    let mountedVolumeName = components[2]
    let volumeName = normalizedShareName(from: mountedVolumeName)
    let mountRootURL = URL(fileURLWithPath: "/Volumes/\(mountedVolumeName)", isDirectory: true)
    guard !isActuallyMounted(mountRootURL) else { return nil }

    let relativePathComponents = Array(components.dropFirst(3))
    if let profile = profiles.first(where: {
      $0.shareName.caseInsensitiveCompare(volumeName) == .orderedSame
    }) {
      return DisconnectedSMBTarget(
        connection: .profile(profile),
        relativePathComponents: relativePathComponents)
    }
    if let connection = recentConnections.first(where: {
      $0.shareName.caseInsensitiveCompare(volumeName) == .orderedSame
    }) {
      return DisconnectedSMBTarget(
        connection: .recent(connection),
        relativePathComponents: relativePathComponents)
    }
    return nil
  }

  private func disconnectedTarget(for location: SavedFolderLocation) -> DisconnectedSMBTarget? {
    if let smbLocation = location.smbLocation,
      let target = disconnectedTarget(for: smbLocation)
    {
      return target
    }
    guard let path = location.lastKnownPath ?? location.url?.path else { return nil }
    return disconnectedTarget(forPath: path)
  }

  private func disconnectedTarget(for smbLocation: SMBFolderLocation) -> DisconnectedSMBTarget? {
    let relativePathComponents = smbLocation.relativePathComponents
    if let profile = profiles.first(where: {
      $0.host.caseInsensitiveCompare(smbLocation.host) == .orderedSame
        && $0.shareName.caseInsensitiveCompare(smbLocation.shareName) == .orderedSame
    }) {
      return DisconnectedSMBTarget(
        connection: .profile(profile),
        relativePathComponents: relativePathComponents)
    }
    let connection = try? RecentSMBConnection(
      host: smbLocation.host,
      shareName: smbLocation.shareName
    )
    guard let connection else { return nil }
    return DisconnectedSMBTarget(
      connection: .recent(connection),
      relativePathComponents: relativePathComponents)
  }

  private func mountedVolume(for smbLocation: SMBFolderLocation) -> SMBMountedVolume? {
    guard let share = try? SMBShare(host: smbLocation.host, shareName: smbLocation.shareName) else {
      return nil
    }
    let mountedVolumeURLs =
      FileManager.default.mountedVolumeURLs(
        includingResourceValuesForKeys: [.volumeURLForRemountingKey],
        options: [.skipHiddenVolumes]
      ) ?? []
    for volumeURL in mountedVolumeURLs {
      guard
        let resourceValues = try? volumeURL.resourceValues(
          forKeys: [.volumeURLForRemountingKey]
        ),
        let remountingURL = resourceValues.volumeURLForRemounting
      else {
        continue
      }
      let volume = SMBMountedVolume(volumeURL: volumeURL, remountingURL: remountingURL)
      if volume.matches(share) {
        return volume
      }
    }
    return nil
  }

  private func folderURL(in volumeURL: URL, for relativePathComponents: [String]) -> URL {
    relativePathComponents.reduce(volumeURL) { url, component in
      url.appendingPathComponent(component, isDirectory: true)
    }
  }

  private func normalizedShareName(from volumeName: String) -> String {
    guard let suffixStart = volumeName.lastIndex(of: "-") else { return volumeName }
    let suffix = volumeName[volumeName.index(after: suffixStart)...]
    guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber) else { return volumeName }
    return String(volumeName[..<suffixStart])
  }

  private func isConnecting(_ target: DisconnectedSMBTarget) -> Bool {
    switch target.connection {
    case .profile(let profile):
      isConnecting(profile)
    case .recent(let connection):
      isConnecting(connection)
    }
  }

  private func connectionID(for profile: NASConnectionProfile) -> String {
    connectionID(host: profile.host, shareName: profile.shareName)
  }

  private func connectionID(for connection: RecentSMBConnection) -> String {
    connectionID(host: connection.host, shareName: connection.shareName)
  }

  private func connectionID(host: String, shareName: String) -> String {
    "\(host.lowercased())/\(shareName.lowercased())"
  }

  private func isActuallyMounted(_ volumeURL: URL) -> Bool {
    let mountedVolumeURLs =
      FileManager.default.mountedVolumeURLs(
        includingResourceValuesForKeys: [],
        options: [.skipHiddenVolumes]
      ) ?? []
    return mountedVolumeURLs.contains { $0.standardizedFileURL == volumeURL.standardizedFileURL }
  }

  private func startConnection(
    _ profile: NASConnectionProfile,
    savesProfileOnSuccess: Bool,
    onConnected: @escaping (URL) -> Void
  ) {
    // 共有UIの「前回の場所へ復元」仕様: onConnectedへはボリュームルートではなく
    // そのprofileで前回ブラウズしたフォルダのブックマークURLを渡す。
    connectToVolumeRoot(profile, savesProfileOnSuccess: savesProfileOnSuccess) {
      [weak self] volumeURL in
      guard let self else { return }
      onConnected(self.bookmarkedFolderURL(for: profile, in: volumeURL))
    }
  }

  // connectSavedLocationなど「履歴の相対パスをボリュームルートへ連結する」呼び出し元向け。
  // onVolumeMountedへは常にボリュームルートそのものを渡す(前回ブラウズ先への解決は行わない)。
  private func connectToVolumeRoot(
    _ profile: NASConnectionProfile,
    savesProfileOnSuccess: Bool,
    onVolumeMounted: @escaping (URL) -> Void
  ) {
    let connectionID = connectionID(for: profile)
    guard connectingConnectionIDs.insert(connectionID).inserted else { return }
    do {
      let share = try profile.smbShare()
      mountService.connect(to: share) { [weak self] result in
        guard let self else { return }
        self.connectingConnectionIDs.remove(connectionID)
        switch result {
        case .success(let volumeURLs):
          if savesProfileOnSuccess {
            self.profileStore.save(profile)
          }
          self.refreshMountedVolumes()
          self.errorMessage = nil
          if let volumeURL = volumeURLs.first ?? self.mountedVolumes[profile.id]?.volumeURL {
            onVolumeMounted(volumeURL)
          }
        case .failure(let error):
          self.errorMessage = ConnectionErrorClassifier.guidanceMessage(for: error)
        }
      }
    } catch {
      connectingConnectionIDs.remove(connectionID)
      errorMessage = PKPaneErrorClassifier.classify(error).displayMessage
    }
  }

  private func bookmarkedFolderURL(
    for profile: NASConnectionProfile,
    in volumeURL: URL
  ) -> URL {
    let standardizedVolumeURL = volumeURL.standardizedFileURL
    if let bookmarkURL = try? bookmarkRepository.restore(for: profile.id),
      isWithin(bookmarkURL, root: standardizedVolumeURL)
    {
      return bookmarkURL
    }
    do {
      try bookmarkRepository.save(standardizedVolumeURL, for: profile.id)
      errorMessage = nil
    } catch {
      errorMessage = PKPaneErrorClassifier.classify(error).displayMessage
    }
    return standardizedVolumeURL
  }

  private func isWithin(_ url: URL, root: URL) -> Bool {
    url.standardizedFileURL.pathComponents.starts(with: root.standardizedFileURL.pathComponents)
  }
}

private struct DisconnectedSMBTarget {
  enum Connection {
    case profile(NASConnectionProfile)
    case recent(RecentSMBConnection)
  }

  let connection: Connection
  let relativePathComponents: [String]
}

struct SavedMountedFolder {
  let volume: SMBMountedVolume
  let folderURL: URL
}
