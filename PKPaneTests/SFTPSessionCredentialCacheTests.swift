import Testing

@testable import PKPane

struct SFTPSessionCredentialCacheTests {
  @Test("資格情報キャッシュはホップと種別ごとに保存と削除を行う")
  func cacheStoresAndRemovesPerHopAndKind() async {
    let cache = SFTPSessionCredentialCache()
    let relay = SFTPHopIdentity(host: "gateway", port: 22, username: "ops")
    let finalHop = SFTPHopIdentity(host: "files.example", port: 22, username: "tester")
    let passphraseKind = SFTPCredentialKind.passphrase(keyPath: "/Users/me/.ssh/id_ed25519")

    await cache.store("s", for: relay, kind: .password)
    await cache.store("p", for: relay, kind: passphraseKind)
    await cache.store("final", for: finalHop, kind: .password)

    #expect(await cache.secret(for: relay, kind: .password) == "s")
    #expect(await cache.secret(for: relay, kind: passphraseKind) == "p")
    #expect(await cache.secret(for: finalHop, kind: .password) == "final")
    #expect(await cache.secret(for: finalHop, kind: passphraseKind) == nil)

    await cache.remove(for: relay, kind: .password)

    #expect(await cache.secret(for: relay, kind: .password) == nil)
    #expect(await cache.secret(for: relay, kind: passphraseKind) == "p")
    #expect(await cache.secret(for: finalHop, kind: .password) == "final")
  }
}
