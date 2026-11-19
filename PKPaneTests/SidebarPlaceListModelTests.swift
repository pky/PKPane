import AppKit
import Foundation
import Testing

@testable import PKPane

@MainActor
struct SidebarPlaceListModelTests {
  @Test("開始時に既存のマウント済みボリュームを列挙する")
  func startLoadsExistingMountedVolumes() {
    let notificationCenter = NotificationCenter()
    let source = VolumeSource(volumes: [volume("/Volumes/Archive", name: "Archive")])
    let model = makeModel(notificationCenter: notificationCenter, source: source)

    model.start()

    #expect(model.places.map(\.displayName) == ["Archive"])
  }

  @Test("ローカルとネットワークのマウント済みボリューム容量を保持する")
  func retainsAvailableCapacityForAllMountedVolumes() {
    let notificationCenter = NotificationCenter()
    let local = volume("/", name: "Macintosh HD", availableCapacity: 136_530_000_000)
    let network = volume(
      "/Volumes/NAS",
      name: "NAS",
      isLocal: false,
      availableCapacity: 7_900_000_000_000)
    let source = VolumeSource(volumes: [local, network])
    let model = makeModel(notificationCenter: notificationCenter, source: source)

    model.start()

    #expect(model.availableCapacity(for: local.url) == 136_530_000_000)
    #expect(model.availableCapacity(for: network.url) == 7_900_000_000_000)
    #expect(model.places.map(\.displayName) == ["Macintosh HD"])
  }

  @Test("iCloud Driveを場所の項目として保持する")
  func includesICloudDriveInLocations() {
    let notificationCenter = NotificationCenter()
    let homeDirectory = URL(filePath: "/Users/tester")
    let iCloudDrive = homeDirectory.appending(path: "Library/Mobile Documents/com~apple~CloudDocs")
    let model = SidebarPlaceListModel(
      notificationCenter: notificationCenter,
      mountedVolumesProvider: { [] },
      cloudStorageDirectoriesProvider: { [] },
      homeDirectory: homeDirectory,
      fileExists: { $0 == iCloudDrive },
      displayNameProvider: { $0.lastPathComponent })

    model.start()

    #expect(model.places.isEmpty)
    #expect(model.iCloudDrive?.displayName == "iCloud Drive")
    #expect(model.iCloudDrive?.kind == .iCloudDrive)
  }

  @Test("マウント通知で追加したボリュームを反映する")
  func mountNotificationReloadsPlaces() {
    let notificationCenter = NotificationCenter()
    let source = VolumeSource()
    let model = makeModel(notificationCenter: notificationCenter, source: source)
    model.start()
    source.volumes = [volume("/Volumes/USB", name: "USB", isRemovable: true)]

    notificationCenter.post(name: NSWorkspace.didMountNotification, object: nil)

    #expect(model.places.map(\.displayName) == ["USB"])
  }

  @Test("アンマウント通知で消えたボリュームを反映する")
  func unmountNotificationReloadsPlaces() {
    let notificationCenter = NotificationCenter()
    let source = VolumeSource(volumes: [volume("/Volumes/USB", name: "USB", isRemovable: true)])
    let model = makeModel(notificationCenter: notificationCenter, source: source)
    model.start()
    source.volumes = []

    notificationCenter.post(name: NSWorkspace.didUnmountNotification, object: nil)

    #expect(model.places.isEmpty)
  }

  @Test("ボリューム名変更通知で新しい名前へ置き換える")
  func renameNotificationReloadsPlaces() {
    let notificationCenter = NotificationCenter()
    let source = VolumeSource(volumes: [volume("/Volumes/Before", name: "Before")])
    let model = makeModel(notificationCenter: notificationCenter, source: source)
    model.start()
    source.volumes = [volume("/Volumes/After", name: "After")]

    notificationCenter.post(name: NSWorkspace.didRenameVolumeNotification, object: nil)

    #expect(model.places.map(\.displayName) == ["After"])
    #expect(model.places.map(\.id) == ["/Volumes/After"])
  }

  @Test("停止後はボリューム通知に反応しない")
  func stopRemovesNotificationObservers() {
    let notificationCenter = NotificationCenter()
    let source = VolumeSource(volumes: [volume("/Volumes/Before", name: "Before")])
    let model = makeModel(notificationCenter: notificationCenter, source: source)
    model.start()
    model.stop()
    source.volumes = [volume("/Volumes/After", name: "After")]

    notificationCenter.post(name: NSWorkspace.didMountNotification, object: nil)

    #expect(model.places.map(\.displayName) == ["Before"])
  }

  private func makeModel(
    notificationCenter: NotificationCenter,
    source: VolumeSource
  ) -> SidebarPlaceListModel {
    SidebarPlaceListModel(
      notificationCenter: notificationCenter,
      mountedVolumesProvider: { source.volumes },
      cloudStorageDirectoriesProvider: { [] },
      homeDirectory: URL(filePath: "/Users/tester"),
      fileExists: { _ in false },
      displayNameProvider: { $0.lastPathComponent })
  }

  private func volume(
    _ path: String,
    name: String,
    isLocal: Bool = true,
    isRemovable: Bool = false,
    availableCapacity: Int64? = nil
  ) -> SidebarPlaceEnumerator.VolumeInfo {
    SidebarPlaceEnumerator.VolumeInfo(
      url: URL(filePath: path),
      localizedName: name,
      isLocal: isLocal,
      isRootFileSystem: false,
      isInternal: false,
      isRemovable: isRemovable,
      isEjectable: false,
      availableCapacity: availableCapacity)
  }
}

@MainActor
private final class VolumeSource {
  var volumes: [SidebarPlaceEnumerator.VolumeInfo]

  init(volumes: [SidebarPlaceEnumerator.VolumeInfo] = []) {
    self.volumes = volumes
  }
}
