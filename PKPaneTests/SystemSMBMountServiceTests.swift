import AppKit
import Foundation
import Testing

@testable import PKPane

@MainActor
struct SystemSMBMountServiceTests {
  @Test("SMB共有URLに認証情報を含めない")
  func shareURLContainsOnlyHostAndShareName() throws {
    let share = try SMBShare(host: "nas.example.local", shareName: "共有 資料")

    #expect(share.url.scheme == "smb")
    #expect(share.url.host() == "nas.example.local")
    #expect(share.url.path(percentEncoded: false) == "/共有 資料")
    #expect(share.url.user == nil)
    #expect(share.url.password == nil)
  }

  @Test("共有名なしはサーバー接続として明示された場合だけ許可する")
  func serverOnlyURLRequiresExplicitPermission() throws {
    #expect(throws: SMBShareError.invalidShareName) {
      try SMBShare(host: "nas.example.local", shareName: "")
    }
    let server = try SMBShare(
      host: "nas.example.local", shareName: "", allowsServerOnly: true)
    #expect(server.url.absoluteString == "smb://nas.example.local")
    let volume = SMBMountedVolume(
      volumeURL: URL(filePath: "/Volumes/Documents"),
      remountingURL: URL(string: "smb://nas.example.local/Documents")!)
    #expect(!volume.matches(server))
  }

  @Test("SMB共有の再マウントURLとマウント先を関連付ける")
  func mountedVolumeMatchesShareByRemountingURL() throws {
    let share = try SMBShare(host: "nas.example.local", shareName: "Documents")
    let volume = SMBMountedVolume(
      volumeURL: URL(filePath: "/Volumes/Documents"),
      remountingURL: URL(string: "smb://nas.example.local/Documents")!
    )

    #expect(volume.matches(share))
  }

  @Test("SMB以外の再マウントURLは共有として扱わない")
  func mountedVolumeRejectsNonSMBRemountingURL() throws {
    let share = try SMBShare(host: "nas.example.local", shareName: "Documents")
    let volume = SMBMountedVolume(
      volumeURL: URL(filePath: "/Volumes/Documents"),
      remountingURL: URL(string: "afp://nas.example.local/Documents")!
    )

    #expect(!volume.matches(share))
  }

  @Test("SMBボリュームのマウントとアンマウントを通知する")
  func mountObserverReportsMountAndUnmount() {
    let notificationCenter = NotificationCenter()
    let volumeURL = URL(filePath: "/Volumes/Documents")
    let remountingURL = URL(string: "smb://nas.example.local/Documents")!
    let resolver = StubVolumeRemountingURLResolver(urls: [volumeURL: remountingURL])
    var events: [SMBMountEvent] = []
    let observer = SMBMountObserver(
      notificationCenter: notificationCenter,
      resolver: resolver,
      onEvent: { events.append($0) }
    )
    observer.start()

    notificationCenter.post(
      name: NSWorkspace.didMountNotification,
      object: nil,
      userInfo: [NSWorkspace.volumeURLUserInfoKey: volumeURL]
    )
    notificationCenter.post(
      name: NSWorkspace.didUnmountNotification,
      object: nil,
      userInfo: [NSWorkspace.volumeURLUserInfoKey: volumeURL]
    )

    let volume = SMBMountedVolume(volumeURL: volumeURL, remountingURL: remountingURL)
    #expect(events == [.mounted(volume), .unmounted(volume)])
  }

  @Test("起動前からマウント済みのSMB共有も監視対象に登録する")
  func mountObserverRegistersExistingMountedVolume() {
    let notificationCenter = NotificationCenter()
    let volumeURL = URL(filePath: "/Volumes/Documents")
    let remountingURL = URL(string: "smb://nas.example.local/Documents")!
    let resolver = StubVolumeRemountingURLResolver(urls: [volumeURL: remountingURL])
    var events: [SMBMountEvent] = []
    let observer = SMBMountObserver(
      notificationCenter: notificationCenter,
      resolver: resolver,
      mountedVolumeURLs: { [volumeURL] },
      onEvent: { event in events.append(event) }
    )

    observer.start()

    #expect(
      events == [
        .mounted(
          SMBMountedVolume(
            volumeURL: volumeURL,
            remountingURL: remountingURL))
      ]
    )
  }

  @Test("SMB以外のボリュームは通知しない")
  func mountObserverIgnoresNonSMBVolume() {
    let notificationCenter = NotificationCenter()
    let volumeURL = URL(filePath: "/Volumes/Backup")
    let resolver = StubVolumeRemountingURLResolver(
      urls: [volumeURL: URL(string: "afp://nas.example.local/Backup")!]
    )
    var events: [SMBMountEvent] = []
    let observer = SMBMountObserver(
      notificationCenter: notificationCenter,
      resolver: resolver,
      onEvent: { events.append($0) }
    )
    observer.start()

    notificationCenter.post(
      name: NSWorkspace.didMountNotification,
      object: nil,
      userInfo: [NSWorkspace.volumeURLUserInfoKey: volumeURL]
    )

    #expect(events.isEmpty)
  }
}

@MainActor
private final class StubVolumeRemountingURLResolver: VolumeRemountingURLResolving {
  private let urls: [URL: URL]

  init(urls: [URL: URL]) {
    self.urls = urls
  }

  func remountingURL(for volumeURL: URL) -> URL? {
    urls[volumeURL]
  }
}
