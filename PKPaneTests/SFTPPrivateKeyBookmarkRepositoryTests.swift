import Foundation
import Testing

@testable import PKPane

struct SFTPPrivateKeyBookmarkRepositoryTests {
  @Test("SFTP接続先ごとの秘密鍵Bookmarkを保存して復元する")
  func savesAndRestoresBookmarkByTarget() throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let privateKeyURL = URL(filePath: "/private/keys/id_ed25519")
    let repository = SFTPPrivateKeyBookmarkRepository(
      storage: InMemorySFTPPrivateKeyBookmarkStore(),
      codec: StubSFTPPrivateKeyBookmarkCodec())

    try repository.save(privateKeyURL, for: target)

    #expect(try repository.restore(for: target) == privateKeyURL.standardizedFileURL)
  }

  @Test("staleな秘密鍵Bookmarkを更新する")
  func refreshesStaleBookmark() throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let privateKeyURL = URL(filePath: "/private/keys/id_ed25519")
    let storage = InMemorySFTPPrivateKeyBookmarkStore()
    let codec = StubSFTPPrivateKeyBookmarkCodec(staleURLs: [privateKeyURL])
    let repository = SFTPPrivateKeyBookmarkRepository(storage: storage, codec: codec)
    storage.saveBookmarkData(privateKeyURL.path.data(using: .utf8)!, for: target)

    _ = try repository.restore(for: target)

    #expect(codec.createdURLs == [privateKeyURL])
  }

  @Test("接続先と最終ホップは秘密鍵Bookmarkの保存先を共有する")
  func targetAndFinalHopShareBookmarkKey() throws {
    let target = try SFTPConnectionTarget(host: "files.example", port: 22, username: "tester")
    let privateKeyURL = URL(filePath: "/private/keys/id_ed25519")
    let replacementURL = URL(filePath: "/private/keys/id_rsa")
    let repository = SFTPPrivateKeyBookmarkRepository(
      storage: InMemorySFTPPrivateKeyBookmarkStore(),
      codec: StubSFTPPrivateKeyBookmarkCodec())

    try repository.save(privateKeyURL, for: target)

    #expect(try repository.restore(for: target.finalHop) == privateKeyURL.standardizedFileURL)

    try repository.save(replacementURL, for: target.finalHop)

    #expect(try repository.restore(for: target) == replacementURL.standardizedFileURL)
  }

  @Test("踏み台と最終ホップの秘密鍵Bookmarkは独立する")
  func jumpHopBookmarkIsIndependentFromFinalHop() throws {
    let hop = SFTPHopIdentity(host: "gateway", port: 22, username: "ops")
    let target = try SFTPConnectionTarget(host: "files.example", port: 22, username: "tester")
    let relayKeyURL = URL(filePath: "/private/keys/relay_ed25519")
    let finalKeyURL = URL(filePath: "/private/keys/id_ed25519")
    let repository = SFTPPrivateKeyBookmarkRepository(
      storage: InMemorySFTPPrivateKeyBookmarkStore(),
      codec: StubSFTPPrivateKeyBookmarkCodec())

    try repository.save(relayKeyURL, for: hop)
    try repository.save(finalKeyURL, for: target.finalHop)

    #expect(try repository.restore(for: hop) == relayKeyURL.standardizedFileURL)
    #expect(try repository.restore(for: target.finalHop) == finalKeyURL.standardizedFileURL)
    #expect(try repository.restore(for: target) == finalKeyURL.standardizedFileURL)
  }
}

private final class StubSFTPPrivateKeyBookmarkCodec: FolderBookmarkCoding {
  private let staleURLs: Set<URL>
  private(set) var createdURLs: [URL] = []

  init(staleURLs: Set<URL> = []) {
    self.staleURLs = staleURLs
  }

  func createBookmark(for url: URL) throws -> Data {
    createdURLs.append(url)
    return url.path.data(using: .utf8)!
  }

  func resolveBookmark(_ data: Data) throws -> ResolvedFolderBookmark {
    let url = URL(filePath: String(decoding: data, as: UTF8.self))
    return ResolvedFolderBookmark(url: url, isStale: staleURLs.contains(url))
  }
}

private final class InMemorySFTPPrivateKeyBookmarkStore: SFTPPrivateKeyBookmarkStoring {
  private var data: [String: Data] = [:]

  func loadBookmarkData(for target: SFTPConnectionTarget) -> Data? {
    data[key(for: target)]
  }

  func saveBookmarkData(_ data: Data, for target: SFTPConnectionTarget) {
    self.data[key(for: target)] = data
  }

  func removeBookmarkData(for target: SFTPConnectionTarget) {
    data[key(for: target)] = nil
  }

  private func key(for target: SFTPConnectionTarget) -> String {
    "\(target.host):\(target.port):\(target.username)"
  }
}
