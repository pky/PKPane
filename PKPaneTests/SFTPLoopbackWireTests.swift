import Citadel
import CryptoKit
import Foundation
import Testing

@testable import PKPane

#if PKPANE_SFTP_LOOPBACK_TESTS
  private let sftpLoopbackEnabled = true
#else
  private let sftpLoopbackEnabled = false
#endif

@Suite(.serialized)
struct SFTPLoopbackWireTests {
  @Test("2GiB超の本番SFTP読取を検証側で全量保持せず照合する", .enabled(if: sftpLoopbackEnabled))
  func readsLargeFileIncrementally() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["PKPANE_RV26_SFTP_WIRE_CONFIG"])
    let url = URL(fileURLWithPath: path)
    let root = url.deletingLastPathComponent()
    _ = try #require(root.path.hasPrefix("/private/tmp/pkpane-rv26-sftp-wire-"))
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url))
    _ = try #require(configuration.host == "127.0.0.1")
    _ = try #require(configuration.fixture == root.appending(path: "fixture").path)
    let name = try #require(configuration.largeFileName)
    _ = try #require(name.hasPrefix("large-") && !name.contains("/") && !name.contains("\\"))
    _ = try #require(configuration.largeByteCount == 2_147_483_649)
    let expectedSHA = try #require(configuration.largeSHA256)
    let target = try SFTPConnectionTarget(
      host: configuration.host, port: configuration.port, username: configuration.username,
      initialDirectory: configuration.fixture)
    let suiteName = "com.pky.PKPane.unit-tests.sftp-large.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let trustStore = SFTPHostKeyTrustStore(defaults: defaults)
    trustStore.trust(
      openSSHPublicKey: configuration.hostPublicKey.split(separator: " ").prefix(2).joined(
        separator: " "),
      for: target)
    let service = CitadelSFTPConnectionService(
      passwordStore: SFTPPasswordStore(keychain: SFTPWirePasswordStore(value: nil)),
      privateKeyRepository: SFTPWireKeyRepository(url: root.appending(path: "ed25519")),
      hostKeyValidatorFactory: CitadelSFTPHostKeyValidatorFactory(trustStore: trustStore))
    let session = try await service.connect(to: target)
    let received = SFTPWireDigest()
    let started = ContinuousClock.now
    do {
      try await session.streamFileContents(
        of: configuration.fixture + "/" + name, chunkSize: SFTPChunkedTransfer.defaultChunkSize
      ) { await received.append($0) }
      let result = await received.result()
      #expect(result.bytes == 2_147_483_649)
      #expect(result.sha256 == expectedSHA)
      let elapsed = started.duration(to: .now).components
      let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
      let evidence: [String: Any] = [
        "verificationEntry": "scripts/check_all.sh --sftp-loopback-test",
        "serverMode": "非root専用sshd・internal-sftp -R・loopback",
        "bytes": result.bytes, "sha256Matches": result.sha256 == expectedSHA,
        "maximumDeliveredChunkBytes": result.maximumChunk, "seconds": seconds,
        "consumerRetainsWholeFile": false, "adapterAlwaysBoundedVerified": false,
        "rssMeasured": false,
        "signingScope": "Debug/ad-hoc。実ネットワークや配布署名の合格ではない",
      ]
      let data = try JSONSerialization.data(
        withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
      try data.write(
        to: root.appending(path: "large-result-\(UUID().uuidString).json"),
        options: .withoutOverwriting)
      try await session.close()
    } catch {
      try? await session.close()
      throw error
    }
  }

  @Test(
    "本番SFTPアダプターで試験鍵の認証・列挙・読取・再接続を確認する",
    .enabled(if: sftpLoopbackEnabled), arguments: ["ed25519", "rsa", "encrypted-ed25519"])
  func authenticatesAndReadsAfterReconnect(keyKind: String) async throws {
    let path = try #require(ProcessInfo.processInfo.environment["PKPANE_RV26_SFTP_WIRE_CONFIG"])
    let url = URL(fileURLWithPath: path)
    let root = url.deletingLastPathComponent()
    _ = try #require(root.path.hasPrefix("/private/tmp/pkpane-rv26-sftp-wire-"))
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url))
    _ = try #require(configuration.host == "127.0.0.1")
    _ = try #require(configuration.fixture == root.appending(path: "fixture").path)
    let target = try SFTPConnectionTarget(
      host: configuration.host, port: configuration.port, username: configuration.username,
      initialDirectory: configuration.fixture)
    let suiteName = "com.pky.PKPane.unit-tests.sftp-wire.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let trustStore = SFTPHostKeyTrustStore(defaults: defaults)
    let keyComponents = configuration.hostPublicKey.split(separator: " ")
    trustStore.trust(openSSHPublicKey: keyComponents.prefix(2).joined(separator: " "), for: target)
    let service = CitadelSFTPConnectionService(
      passwordStore: SFTPPasswordStore(
        keychain: SFTPWirePasswordStore(
          value: keyKind == "encrypted-ed25519"  // gitleaks:allow
            ? configuration.passphrase : nil)),
      privateKeyRepository: SFTPWireKeyRepository(url: root.appending(path: keyKind)),
      hostKeyValidatorFactory: CitadelSFTPHostKeyValidatorFactory(trustStore: trustStore))
    for _ in 0..<2 {
      let session: any SFTPClientSession
      do {
        session = try await service.connect(to: target)
      } catch {
        let category =
          (error as? SSHClientError).map { String(describing: $0) }
          ?? String(reflecting: type(of: error))
        Issue.record("隔離SFTPの\(keyKind)認証が失敗しました。原因分類: \(category)")
        throw SFTPWireError.authenticationRejected
      }
      do {
        let entries = try await session.contents(of: configuration.fixture)
        #expect(entries.contains { $0.name == "read-only.txt" })
        let received = SFTPWireBytes()
        try await session.streamFileContents(
          of: configuration.fixture + "/read-only.txt", chunkSize: 65_536
        ) {
          await received.append($0)
        }
        #expect(await received.value == Data("PKPane isolated SFTP read-only fixture\n".utf8))
        try await session.close()
      } catch {
        try? await session.close()
        Issue.record("隔離SFTPの列挙・読取が失敗しました。原因型: \(String(reflecting: type(of: error)))")
        throw SFTPWireError.readRejected
      }
    }
  }

  private struct Configuration: Decodable {
    let host: String
    let port: Int
    let username: String
    let fixture: String
    let hostPublicKey: String
    let passphrase: String
    let largeFileName: String?
    let largeByteCount: Int64?
    let largeSHA256: String?
  }
}

private enum SFTPWireError: Error { case authenticationRejected, readRejected }

private actor SFTPWireBytes {
  var value = Data()
  func append(_ data: Data) { value.append(data) }
}

/// ファイル全体を貯めず、SHA状態と件数だけを保持する。
private actor SFTPWireDigest {
  private var digest = SHA256()
  private var bytes: Int64 = 0
  private var maximumChunk = 0
  func append(_ data: Data) {
    digest.update(data: data)
    bytes += Int64(data.count)
    maximumChunk = max(maximumChunk, data.count)
  }
  func result() -> (bytes: Int64, sha256: String, maximumChunk: Int) {
    let sha256 = digest.finalize().map { String(format: "%02x", $0) }.joined()
    return (bytes, sha256, maximumChunk)
  }
}

private final class SFTPWirePasswordStore: KeychainPasswordDataStoring {
  let value: String?
  init(value: String?) { self.value = value }
  func save(password _: String, service _: String, account _: String) throws {}
  func password(service _: String, account _: String) throws -> String? { value }
}

private final class SFTPWireKeyRepository: SFTPPrivateKeyBookmarkPersisting {
  let url: URL
  init(url: URL) { self.url = url }
  func save(_: URL, for _: SFTPConnectionTarget) throws {}
  func restore(for _: SFTPConnectionTarget) throws -> URL? { url }
  func remove(for _: SFTPConnectionTarget) {}
}
