import Foundation

@MainActor
struct ProviderTransferDestination: Identifiable {
  let id: String
  let title: String
  let disabledReason: String?
  let makeDestination: @MainActor () -> FileBrowserSession?
  var isEnabled: Bool { disabledReason == nil }
}

@MainActor
struct ProviderTransferDestinationSection: Identifiable {
  let id: String
  let title: String
  let destinations: [ProviderTransferDestination]
}

@MainActor
enum ProviderTransferDestinationCatalog {
  static func destination(
    id: String,
    in sections: [ProviderTransferDestinationSection]
  ) -> ProviderTransferDestination? {
    for section in sections {
      if let destination = section.destinations.first(where: { $0.id == id }) {
        return destination
      }
    }
    return nil
  }

  static func makeSections(
    workspace: FileWorkspaceModel,
    favorites: [SavedFolderLocation] = [],
    recents: [SavedFolderLocation] = [],
    sftpFavorites: [SFTPFolderFavorite] = [],
    sftpRecents: [SFTPFolderRecent] = [],
    ftpFavorites: [FTPFolderFavorite] = [],
    ftpRecents: [FTPFolderRecent] = [],
    nasProfiles: [NASConnectionProfile] = [],
    sftpTargets: [SFTPConnectionTarget] = [],
    ftpTargets: [FTPConnectionTarget] = [],
    volumeProvider: (NASConnectionProfile) -> MountedVolumeProvider? = { _ in nil },
    sftpProvider: (SFTPConnectionTarget) -> SFTPFileProvider? = { _ in nil },
    ftpProvider: (FTPConnectionTarget) -> FTPFileProvider? = { _ in nil }
  ) -> [ProviderTransferDestinationSection] {
    let sourceLocation = workspace.activeTab.browser.currentLocation
    var sections: [ProviderTransferDestinationSection] = []

    let tabDestinations = workspace.tabs
      .filter { $0.id != workspace.activeTabID }
      .map { tab in
        ProviderTransferDestination(
          id: "tab-\(tab.id.uuidString)",
          title: tab.title,
          disabledReason: tab.browser.currentLocation.representsSameDirectory(as: sourceLocation)
            ? "現在の場所と同じです" : nil,
          makeDestination: { tab.browser })
      }
    appendSection(&sections, id: "tabs", title: "開いているタブ", tabDestinations)

    var favoriteDestinations = favorites.map {
      localDestination(idPrefix: "favorite", location: $0, sourceLocation: sourceLocation)
    }
    favoriteDestinations += sftpFavorites.map {
      sftpFolderDestination(
        id: "sftp-favorite-\($0.id.uuidString)", title: $0.name,
        target: $0.target, directory: $0.directory,
        sourceLocation: sourceLocation, sftpProvider: sftpProvider)
    }
    favoriteDestinations += ftpFavorites.map {
      ftpFolderDestination(
        id: "ftp-favorite-\($0.id.uuidString)", title: $0.name,
        target: $0.target, directory: $0.directory,
        sourceLocation: sourceLocation, ftpProvider: ftpProvider)
    }
    appendSection(&sections, id: "favorites", title: "お気に入り", favoriteDestinations)

    var recentDestinations = recents.map {
      localDestination(idPrefix: "recent", location: $0, sourceLocation: sourceLocation)
    }
    recentDestinations += sftpRecents.map {
      sftpFolderDestination(
        id: "sftp-recent-\($0.id.uuidString)", title: $0.name,
        target: $0.target, directory: $0.directory,
        sourceLocation: sourceLocation, sftpProvider: sftpProvider)
    }
    recentDestinations += ftpRecents.map {
      ftpFolderDestination(
        id: "ftp-recent-\($0.id.uuidString)", title: $0.name,
        target: $0.target, directory: $0.directory,
        sourceLocation: sourceLocation, ftpProvider: ftpProvider)
    }
    appendSection(&sections, id: "recents", title: "最近使用した場所", recentDestinations)

    let volumeDestinations = nasProfiles.map { profile -> ProviderTransferDestination in
      guard let provider = volumeProvider(profile) else {
        return ProviderTransferDestination(
          id: "volume-\(profile.id.uuidString)", title: profile.displayName,
          disabledReason: "マウントされていません", makeDestination: { nil })
      }
      let location = FileLocation(directoryURL: provider.volumeURL, providerID: provider.id)
      return ProviderTransferDestination(
        id: "volume-\(profile.id.uuidString)", title: profile.displayName,
        disabledReason: location.representsSameDirectory(as: sourceLocation)
          ? "現在の場所と同じです" : nil,
        makeDestination: { FileBrowserSession(provider: provider, initialLocation: location) })
    }
    appendSection(&sections, id: "volumes", title: "マウント済みボリューム", volumeDestinations)

    let targetDestinations = sftpTargets.map { target in
      sftpFolderDestination(
        id: "sftp-target-\(target.username)@\(target.host):\(target.port)",
        title: "\(target.username)@\(target.host)",
        target: target, directory: target.initialDirectory,
        sourceLocation: sourceLocation, sftpProvider: sftpProvider)
    }
    appendSection(&sections, id: "sftp", title: "SFTP接続先", targetDestinations)

    let ftpDestinations = ftpTargets.map { target in
      ftpFolderDestination(
        id: "ftp-target-\(target.security.rawValue)-"
          + "\(target.username)@\(target.host):\(target.port)",
        title: "\(target.username)@\(target.host)",
        target: target,
        sourceLocation: sourceLocation,
        ftpProvider: ftpProvider)
    }
    appendSection(&sections, id: "ftp", title: "FTP/FTPS接続先", ftpDestinations)

    return sections
  }

  private static func appendSection(
    _ sections: inout [ProviderTransferDestinationSection],
    id: String, title: String, _ destinations: [ProviderTransferDestination]
  ) {
    guard !destinations.isEmpty else { return }
    sections.append(
      ProviderTransferDestinationSection(id: id, title: title, destinations: destinations))
  }

  private static func localDestination(
    idPrefix: String, location: SavedFolderLocation, sourceLocation: FileLocation
  ) -> ProviderTransferDestination {
    let id = "\(idPrefix)-\(location.id.uuidString)"
    // SavedFolderLocation.urlはFolderLocationListRepository.load()がbookmark解決済みの値。
    // アプリは非サンドボックスのためsecurity-scope開始は不要(サンドボックス化する際は
    // 旧系FolderSelectionModelのFolderBookmarkAccessManager相当の組み込みが必要)。
    guard let url = location.url else {
      return ProviderTransferDestination(
        id: id, title: location.name,
        disabledReason: "場所を利用できません", makeDestination: { nil })
    }
    let provider = LocalFileProvider()
    let destinationLocation = FileLocation(directoryURL: url, providerID: provider.id)
    return ProviderTransferDestination(
      id: id, title: location.name,
      disabledReason: destinationLocation.representsSameDirectory(as: sourceLocation)
        ? "現在の場所と同じです" : nil,
      makeDestination: {
        FileBrowserSession(provider: provider, initialLocation: destinationLocation)
      })
  }

  private static func sftpFolderDestination(
    id: String, title: String,
    target: SFTPConnectionTarget, directory: String,
    sourceLocation: FileLocation,
    sftpProvider: (SFTPConnectionTarget) -> SFTPFileProvider?
  ) -> ProviderTransferDestination {
    guard let provider = sftpProvider(target) else {
      return ProviderTransferDestination(
        id: id, title: title, disabledReason: "未接続です", makeDestination: { nil })
    }
    let destinationLocation = FileLocation(
      remotePath: SFTPConnectionTarget.normalizedRelativePath(directory), providerID: provider.id)
    return ProviderTransferDestination(
      id: id, title: title,
      disabledReason: destinationLocation.representsSameDirectory(as: sourceLocation)
        ? "現在の場所と同じです" : nil,
      makeDestination: {
        FileBrowserSession(provider: provider, initialLocation: destinationLocation)
      })
  }

  private static func ftpFolderDestination(
    id: String, title: String,
    target: FTPConnectionTarget,
    directory: String? = nil,
    sourceLocation: FileLocation,
    ftpProvider: (FTPConnectionTarget) -> FTPFileProvider?
  ) -> ProviderTransferDestination {
    guard let provider = ftpProvider(target) else {
      return ProviderTransferDestination(
        id: id, title: title, disabledReason: "未接続です", makeDestination: { nil })
    }
    let destinationLocation = FileLocation(
      remotePath: FTPConnectionTarget.normalizedAbsolutePath(directory ?? target.initialDirectory),
      providerID: provider.id)
    return ProviderTransferDestination(
      id: id, title: title,
      disabledReason: destinationLocation.representsSameDirectory(as: sourceLocation)
        ? "現在の場所と同じです" : nil,
      makeDestination: {
        FileBrowserSession(provider: provider, initialLocation: destinationLocation)
      })
  }
}
