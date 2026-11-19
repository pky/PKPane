import Foundation
import Testing

@testable import PKPane

struct SidebarConnectionVisibilityStoreTests {
  @Test("既定では全接続がサイドバーに表示される(隠されていない)")
  func defaultsToAllVisible() throws {
    let suiteName = "SidebarConnectionVisibilityStoreTests-\(UUID())"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = SidebarConnectionVisibilityStore(defaults: defaults)
    let profile = try NASConnectionProfile(displayName: "NAS", host: "nas.local", shareName: "Docs")
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let ftpTarget = try FTPConnectionTarget(host: "ftp.example.com", username: "tester")

    #expect(store.hiddenIdentifiers().isEmpty)
    #expect(!store.isHidden(SidebarConnectionVisibilityStore.identifier(for: profile)))
    #expect(!store.isHidden(SidebarConnectionVisibilityStore.identifier(for: target)))
    #expect(!store.isHidden(SidebarConnectionVisibilityStore.identifier(for: ftpTarget)))
  }

  @Test("識別子を隠す・戻すをトグルでき永続化される")
  func togglesHiddenState() throws {
    let suiteName = "SidebarConnectionVisibilityStoreTests-\(UUID())"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = SidebarConnectionVisibilityStore(defaults: defaults)
    let profile = try NASConnectionProfile(displayName: "NAS", host: "nas.local", shareName: "Docs")
    let identifier = SidebarConnectionVisibilityStore.identifier(for: profile)

    store.setHidden(true, for: identifier)
    #expect(store.isHidden(identifier))
    #expect(store.hiddenIdentifiers() == [identifier])

    // 別インスタンスからも永続化された状態が読める
    let reloaded = SidebarConnectionVisibilityStore(defaults: defaults)
    #expect(reloaded.isHidden(identifier))

    store.setHidden(false, for: identifier)
    #expect(!store.isHidden(identifier))
    #expect(store.hiddenIdentifiers().isEmpty)
  }

  @Test("接続方式ごとに安定した識別子を生成する")
  func identifiersAreStableAndDistinct() throws {
    let profile = try NASConnectionProfile(displayName: "NAS", host: "nas.local", shareName: "Docs")
    let target = try SFTPConnectionTarget(host: "Example.com", port: 22, username: "Tester")
    let sameTargetDifferentDirectory = try SFTPConnectionTarget(
      host: "example.com", port: 22, username: "tester", initialDirectory: "/other")
    let ftpTarget = try FTPConnectionTarget(
      host: "FTP.example.com", username: "Tester", security: .explicitTLS)
    let plainFTPTarget = try FTPConnectionTarget(
      host: "ftp.example.com", username: "tester", security: .plain)

    #expect(
      SidebarConnectionVisibilityStore.identifier(for: profile) == "nas:\(profile.id.uuidString)")
    // 大文字小文字を無視して同一のSFTP識別子になる(SFTPConnectionTargetのEquatable定義と揃える)
    #expect(
      SidebarConnectionVisibilityStore.identifier(for: target)
        == SidebarConnectionVisibilityStore.identifier(for: sameTargetDifferentDirectory))
    #expect(
      SidebarConnectionVisibilityStore.identifier(for: ftpTarget)
        != SidebarConnectionVisibilityStore.identifier(for: plainFTPTarget))
  }
}
