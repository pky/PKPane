import Foundation
import Testing

@testable import PKPane

struct SidebarPlaceEnumeratorTests {
  @Test("macOS内部ボリュームを隠しDataという外部ボリュームは保持する")
  func excludesOnlySystemManagedVolumes() {
    let places = SidebarPlaceEnumerator.volumePlaces(from: [
      volume("/", name: "Macintosh HD"),
      volume("/System/Volumes/Data", name: "Data"),
      volume("/System/Volumes/Preboot", name: "Preboot"),
      volume("/Volumes/Data", name: "Data", isRemovable: true),
    ])
    #expect(places.map(\.id) == ["/Volumes/Data", "/"])
  }

  @Test("Finderの場所と同様にローカルボリュームを名前順に並べる")
  func selectsAndSortsVolumePlaces() {
    let volumes = [
      volume("/", name: "Macintosh HD", isRootFileSystem: true),
      volume("/Volumes/NAS", name: "NAS", isLocal: false),
      volume("/Volumes/Internal", name: "Internal", isInternal: true),
      volume("/Volumes/USB", name: "USB", isRemovable: true, isEjectable: true),
      volume("/Volumes/Archive", name: "Archive", isInternal: false),
      volume("/Volumes/Install macOS", name: "Install macOS", isEjectable: true),
    ]

    let places = SidebarPlaceEnumerator.volumePlaces(from: volumes)

    #expect(
      places.map(\.displayName)
        == ["Archive", "Install macOS", "Internal", "Macintosh HD", "USB"])
    #expect(
      places.map(\.id)
        == ["/Volumes/Archive", "/Volumes/Install macOS", "/Volumes/Internal", "/", "/Volumes/USB"])
    #expect(
      places.map(\.kind) == [
        .volume(isEjectable: false),
        .volume(isEjectable: true),
        .volume(isEjectable: false),
        .volume(isEjectable: false),
        .volume(isEjectable: true),
      ])
  }

  @Test("同名ボリュームも標準化済みパスで区別する")
  func distinguishesSameNamedVolumesByPath() {
    let places = SidebarPlaceEnumerator.volumePlaces(from: [
      volume("/Volumes/Backup", name: "Backup", isRemovable: true),
      volume("/Volumes/Backup-1", name: "Backup", isRemovable: true),
    ])

    #expect(places.map(\.id) == ["/Volumes/Backup", "/Volumes/Backup-1"])
  }

  @Test("iCloud Driveは存在する場合だけ場所用項目にする")
  func createsICloudDrivePlaceOnlyWhenItExists() {
    let homeDirectory = URL(filePath: "/Users/tester")
    let expectedURL = homeDirectory.appending(path: "Library/Mobile Documents/com~apple~CloudDocs")

    let existing = SidebarPlaceEnumerator.iCloudDrivePlace(
      homeDirectory: homeDirectory,
      fileExists: { $0 == expectedURL })
    let missing = SidebarPlaceEnumerator.iCloudDrivePlace(
      homeDirectory: homeDirectory,
      fileExists: { _ in false })

    #expect(
      existing
        == SidebarPlace(
          id: "/Users/tester/Library/Mobile Documents/com~apple~CloudDocs",
          url: expectedURL,
          displayName: "iCloud Drive",
          detail: nil,
          kind: .iCloudDrive))
    #expect(missing == nil)
  }

  @Test("クラウドストレージは表示名とアカウント詳細を分離して名前順に並べる")
  func createsCloudStoragePlaces() {
    let directories = [
      URL(filePath: "/Users/tester/Library/CloudStorage/GoogleDrive-user@example.com"),
      URL(filePath: "/Users/tester/Library/CloudStorage/Dropbox"),
    ]

    let places = SidebarPlaceEnumerator.cloudStoragePlaces(
      directories: directories,
      displayNameProvider: { url in
        url.lastPathComponent == "GoogleDrive-user@example.com" ? "Google Drive" : "Dropbox"
      })

    #expect(places.map(\.displayName) == ["Dropbox", "Google Drive"])
    #expect(places.map(\.detail) == [nil, "user@example.com"])
    #expect(
      places.map(\.id) == [
        "/Users/tester/Library/CloudStorage/Dropbox",
        "/Users/tester/Library/CloudStorage/GoogleDrive-user@example.com",
      ])
    #expect(
      SidebarPlaceEnumerator.cloudStoragePlaces(
        directories: [],
        displayNameProvider: { _ in "" }
      ).isEmpty)
  }

  private func volume(
    _ path: String,
    name: String,
    isLocal: Bool = true,
    isRootFileSystem: Bool = false,
    isInternal: Bool = false,
    isRemovable: Bool = false,
    isEjectable: Bool = false
  ) -> SidebarPlaceEnumerator.VolumeInfo {
    SidebarPlaceEnumerator.VolumeInfo(
      url: URL(filePath: path),
      localizedName: name,
      isLocal: isLocal,
      isRootFileSystem: isRootFileSystem,
      isInternal: isInternal,
      isRemovable: isRemovable,
      isEjectable: isEjectable)
  }
}
