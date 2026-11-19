import AppKit
import Foundation
import Observation

private func defaultSidebarMountedVolumes() -> [SidebarPlaceEnumerator.VolumeInfo] {
  let resourceKeys: Set<URLResourceKey> = [
    .volumeLocalizedNameKey,
    .volumeIsLocalKey,
    .volumeIsRootFileSystemKey,
    .volumeIsInternalKey,
    .volumeIsRemovableKey,
    .volumeIsEjectableKey,
    .volumeAvailableCapacityKey,
  ]
  let volumeURLs =
    FileManager.default.mountedVolumeURLs(
      includingResourceValuesForKeys: Array(resourceKeys),
      options: [.skipHiddenVolumes]) ?? []

  return volumeURLs.compactMap { url in
    guard let values = try? url.resourceValues(forKeys: resourceKeys) else {
      return nil
    }
    return SidebarPlaceEnumerator.VolumeInfo(
      url: url,
      localizedName: values.volumeLocalizedName,
      isLocal: values.volumeIsLocal ?? false,
      isRootFileSystem: values.volumeIsRootFileSystem ?? false,
      isInternal: values.volumeIsInternal ?? false,
      isRemovable: values.volumeIsRemovable ?? false,
      isEjectable: values.volumeIsEjectable ?? false,
      availableCapacity: values.volumeAvailableCapacity.map(Int64.init))
  }
}

private func defaultSidebarCloudStorageDirectories() -> [URL] {
  let cloudStorageURL = UserHomeDirectory.current
    .appending(path: "Library/CloudStorage")
  return
    (try? FileManager.default.contentsOfDirectory(
      at: cloudStorageURL,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]))?.filter { url in
      (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    } ?? []
}

/// Finder準拠のサイドバー項目をボリューム通知に合わせて更新する。
@Observable
@MainActor
final class SidebarPlaceListModel {
  private let notificationCenter: NotificationCenter
  private let mountedVolumesProvider: () -> [SidebarPlaceEnumerator.VolumeInfo]
  private let cloudStorageDirectoriesProvider: () -> [URL]
  private let homeDirectory: URL
  private let fileExists: (URL) -> Bool
  private let displayNameProvider: (URL) -> String
  private var notificationTokens: [NSObjectProtocol] = []

  /// Finderの「場所」に表示するローカルボリュームと他社クラウドストレージ。
  private(set) var places: [SidebarPlace] = []
  /// Finderの「場所」に表示するiCloud Drive。
  private(set) var iCloudDrive: SidebarPlace?
  /// ローカル・ネットワークを問わず、取得できたマウント済みボリュームの空き容量。
  private(set) var availableCapacityByVolumePath: [String: Int64] = [:]

  init(
    notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
    mountedVolumesProvider: @escaping () -> [SidebarPlaceEnumerator.VolumeInfo] = {
      defaultSidebarMountedVolumes()
    },
    cloudStorageDirectoriesProvider: @escaping () -> [URL] = {
      defaultSidebarCloudStorageDirectories()
    },
    homeDirectory: URL = UserHomeDirectory.current,
    fileExists: @escaping (URL) -> Bool = { url in
      FileManager.default.fileExists(atPath: url.path)
    },
    displayNameProvider: @escaping (URL) -> String = { url in
      FileManager.default.displayName(atPath: url.path)
    }
  ) {
    self.notificationCenter = notificationCenter
    self.mountedVolumesProvider = mountedVolumesProvider
    self.cloudStorageDirectoriesProvider = cloudStorageDirectoriesProvider
    self.homeDirectory = homeDirectory
    self.fileExists = fileExists
    self.displayNameProvider = displayNameProvider
  }

  func start() {
    guard notificationTokens.isEmpty else {
      return
    }

    let volumeNotifications: [Notification.Name] = [
      NSWorkspace.didMountNotification,
      NSWorkspace.didUnmountNotification,
      NSWorkspace.didRenameVolumeNotification,
    ]
    notificationTokens = volumeNotifications.map { name in
      notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.reload()
        }
      }
    }
    reload()
  }

  func stop() {
    notificationTokens.forEach(notificationCenter.removeObserver)
    notificationTokens.removeAll()
  }

  func availableCapacity(for volumeURL: URL) -> Int64? {
    availableCapacityByVolumePath[volumeURL.standardizedFileURL.path]
  }

  isolated deinit {
    notificationTokens.forEach(notificationCenter.removeObserver)
  }

  private func reload() {
    let mountedVolumes = mountedVolumesProvider()
    availableCapacityByVolumePath = Dictionary(
      mountedVolumes.compactMap { volume in
        volume.availableCapacity.map { (volume.url.standardizedFileURL.path, $0) }
      },
      uniquingKeysWith: { _, latest in latest })
    var updatedPlaces = SidebarPlaceEnumerator.volumePlaces(from: mountedVolumes)
    iCloudDrive = SidebarPlaceEnumerator.iCloudDrivePlace(
      homeDirectory: homeDirectory,
      fileExists: fileExists)
    updatedPlaces += SidebarPlaceEnumerator.cloudStoragePlaces(
      directories: cloudStorageDirectoriesProvider(),
      displayNameProvider: displayNameProvider)
    places = updatedPlaces
  }

}
