import Testing

@testable import PKPane

struct SidebarLocationTests {
  @Test("再接続できる場所は操作可能として扱う")
  func reconnectableLocationIsAvailable() {
    let location = SidebarLocation(
      id: "sftp-example",
      title: "tester@example.com:/srv",
      source: .sftp,
      availability: .reconnectable)

    #expect(location.isAvailable)
    #expect(location.isReconnectable)
  }

  @Test("利用不可の場所は操作不能として扱う")
  func unavailableLocationCannotBeOpened() {
    let location = SidebarLocation(
      id: "local-unavailable",
      title: "失効したフォルダ",
      source: .local,
      availability: .unavailable)

    #expect(!location.isAvailable)
    #expect(!location.isReconnectable)
  }

  @Test("systemImageOverrideが無い場合はsource.systemImageを使う")
  func systemImageFallsBackToSourceIcon() {
    let location = SidebarLocation(
      id: "local-generic",
      title: "適当なフォルダ",
      source: .local)

    #expect(location.systemImage == "folder")
  }

  @Test("systemImageOverrideがある場合はそちらを優先する")
  func systemImagePrefersOverride() {
    let location = SidebarLocation(
      id: "local-desktop",
      title: "デスクトップ",
      source: .local,
      systemImageOverride: "desktopcomputer")

    #expect(location.systemImage == "desktopcomputer")
  }

  @Test("ボリューム場所は種別名と外部ディスクのアイコンを持つ")
  func volumeSourceUsesVolumeNameAndIcon() {
    #expect(SidebarLocationSource.volume.displayName == "ボリューム")
    #expect(SidebarLocationSource.volume.systemImage == "externaldrive")
  }

  @Test("クラウド場所は種別名とクラウドのアイコンを持つ")
  func cloudSourceUsesCloudNameAndIcon() {
    #expect(SidebarLocationSource.cloud.displayName == "クラウド")
    #expect(SidebarLocationSource.cloud.systemImage == "cloud")
  }
}
