import Foundation
import Testing

@testable import PKPane

struct NASConnectionProfileTests {
  @Test("NAS接続先を正規化して認証情報なしの共有URLを作る")
  func normalizesProfileAndCreatesCredentialFreeShare() throws {
    let profile = try NASConnectionProfile(
      displayName: " 開発用NAS ",
      host: " nas.example.local ",
      shareName: " Documents ")

    let share = try profile.smbShare()

    #expect(profile.displayName == "開発用NAS")
    #expect(profile.host == "nas.example.local")
    #expect(profile.shareName == "Documents")
    #expect(share.url.absoluteString == "smb://nas.example.local/Documents")
    #expect(share.url.user == nil)
    #expect(share.url.password == nil)
  }

  @Test("共有名なしのサーバー接続先を正規化して保存復元する")
  func roundTripsServerOnlyProfile() throws {
    let profile = try NASConnectionProfile(
      displayName: " NAS ", host: " nas.example.local ", shareName: " ")

    let restored = try JSONDecoder().decode(
      NASConnectionProfile.self, from: JSONEncoder().encode(profile))

    #expect(restored == profile)
    #expect(restored.shareName.isEmpty)
    #expect(try restored.smbShare().url.absoluteString == "smb://nas.example.local")
  }

  @Test("不正なNAS接続先を拒否する")
  func rejectsInvalidProfile() {
    #expect(throws: NASConnectionProfileError.invalidDisplayName) {
      try NASConnectionProfile(
        displayName: " ", host: "nas.example.local", shareName: "Documents")
    }
    #expect(throws: SMBShareError.invalidHost) {
      try NASConnectionProfile(
        displayName: "NAS", host: "smb://nas.example.local", shareName: "Documents")
    }
    #expect(throws: SMBShareError.invalidShareName) {
      try NASConnectionProfile(
        displayName: "NAS", host: "nas.example.local", shareName: "Documents/Private")
    }
  }
}
