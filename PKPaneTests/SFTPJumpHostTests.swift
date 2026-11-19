import Testing

@testable import PKPane

struct SFTPJumpHostTests {
  @Test("踏み台の空のユーザー名を拒否する")
  func rejectsEmptyUsername() {
    #expect(throws: SFTPConnectionTargetError.invalidUsername) {
      try SFTPJumpHost(host: "gateway", port: 22, username: " ", label: nil)
    }
  }

  @Test("踏み台の同一性には正規化した値を使う")
  func identityUsesTrimmedValues() throws {
    let hop = try SFTPJumpHost(host: " gateway ", port: 2222, username: "ops", label: "踏み台")

    #expect(hop.identity == SFTPHopIdentity(host: "gateway", port: 2222, username: "ops"))
  }
}
