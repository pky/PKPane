import Foundation
import Testing

@testable import PKPane

struct SFTPConnectionTargetTests {
  @Test("接続先を正規化する")
  func normalizesConnectionTarget() throws {
    let target = try SFTPConnectionTarget(
      host: " files.example ",
      port: 22,
      username: " tester ",
      initialDirectory: " /srv/projects "
    )

    #expect(target.host == "files.example")
    #expect(target.port == 22)
    #expect(target.username == "tester")
    #expect(target.initialDirectory == "/srv/projects")
  }

  @Test("不正な接続先を拒否する")
  func rejectsInvalidConnectionTarget() {
    #expect(throws: SFTPConnectionTargetError.invalidHost) {
      try SFTPConnectionTarget(host: "sftp://example.com", port: 22, username: "tester")
    }
    #expect(throws: SFTPConnectionTargetError.invalidPort) {
      try SFTPConnectionTarget(host: "example.com", port: 0, username: "tester")
    }
    #expect(throws: SFTPConnectionTargetError.invalidUsername) {
      try SFTPConnectionTarget(host: "example.com", port: 22, username: " ")
    }
  }

  @Test("開始ディレクトリを持たない既存プロファイルはホーム開始として復元する")
  func decodesLegacyProfileWithHomeDirectory() throws {
    let legacyProfile = #"{"host":"example.com","port":22,"username":"tester"}"#
    let data = Data(legacyProfile.utf8)

    let target = try JSONDecoder().decode(SFTPConnectionTarget.self, from: data)

    #expect(target.initialDirectory == ".")
  }

  @Test("踏み台のない旧JSONを復元する")
  func decodesLegacyJSONWithoutJumpHosts() throws {
    let json = #"{"host":"files.example","port":22,"username":"tester"}"#
    let target = try JSONDecoder().decode(SFTPConnectionTarget.self, from: Data(json.utf8))

    #expect(target.jumpHosts.isEmpty)
    #expect(target.hops == [SFTPHopIdentity(host: "files.example", port: 22, username: "tester")])
  }

  @Test("踏み台を保存復元しても接続先の同一性は変わらない")
  func jumpHostsRoundTripAndDoNotAffectIdentity() throws {
    let relay = try SFTPJumpHost(host: "gateway", port: 22, username: "ops", label: nil)
    let a = try SFTPConnectionTarget(
      host: "files.example", port: 22, username: "tester", jumpHosts: [relay])
    let b = try SFTPConnectionTarget(host: "files.example", port: 22, username: "tester")

    #expect(a == b)
    #expect(a.hashValue == b.hashValue)
    let decoded = try JSONDecoder().decode(
      SFTPConnectionTarget.self, from: JSONEncoder().encode(a))
    #expect(decoded.jumpHosts == [relay])
    #expect(decoded.hops == [relay.identity, a.finalHop])
  }
}
