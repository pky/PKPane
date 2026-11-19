import Foundation
import Testing

@testable import PKPane

#if PKPANE_SFTP_LOOPBACK_TESTS
  private let sftpJumpLoopbackEnabled =
    ProcessInfo.processInfo.environment["PKPANE_RV26_SFTP_WIRE_CONFIG"] != nil
    && ProcessInfo.processInfo.environment["PKPANE_RV26_SFTP_JUMP_CONFIG"] != nil
#else
  private let sftpJumpLoopbackEnabled = false
#endif

@Suite(.serialized)
struct SFTPJumpLoopbackWireTests {
  @Test("踏み台経由の切断後に再接続できる", .enabled(if: sftpJumpLoopbackEnabled))
  func reconnectsThroughJumpHost() async throws {
    let fixture = try makeFixture()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.defaultsSuiteName) }
    let service = makeService(fixture: fixture)

    for _ in 0..<2 {
      let session = try await service.connect(
        to: fixture.target,
        intent: .userInitiated,
        hopProgress: nil)
      do {
        let entries = try await session.contents(of: ".")
        #expect(entries.contains { $0.name == "read-only.txt" })
        try await session.close()
      } catch {
        try? await session.close()
        throw error
      }
    }
  }

  private func makeFixture() throws -> Fixture {
    let environment = ProcessInfo.processInfo.environment
    let targetConfigurationURL = URL(
      fileURLWithPath: try #require(environment["PKPANE_RV26_SFTP_WIRE_CONFIG"]))
    let jumpConfigurationURL = URL(
      fileURLWithPath: try #require(environment["PKPANE_RV26_SFTP_JUMP_CONFIG"]))
    let targetRoot = targetConfigurationURL.deletingLastPathComponent()
    let jumpRoot = jumpConfigurationURL.deletingLastPathComponent()
    _ = try #require(targetRoot.path.hasPrefix("/private/tmp/pkpane-rv26-sftp-wire-"))
    _ = try #require(jumpRoot.path.hasPrefix("/private/tmp/pkpane-rv26-sftp-jump-"))

    let targetConfiguration = try JSONDecoder().decode(
      TargetConfiguration.self,
      from: Data(contentsOf: targetConfigurationURL))
    let jumpConfiguration = try JSONDecoder().decode(
      JumpConfiguration.self,
      from: Data(contentsOf: jumpConfigurationURL))
    _ = try #require(targetConfiguration.host == "127.0.0.1")
    _ = try #require(jumpConfiguration.host == "127.0.0.1")
    _ = try #require(
      targetConfiguration.fixture == targetRoot.appending(path: "fixture").path)

    let jumpKeyURL = URL(fileURLWithPath: jumpConfiguration.privateKeyPath)
    _ = try #require(jumpKeyURL.path.hasPrefix(jumpRoot.path + "/"))
    let relay = try SFTPJumpHost(
      host: jumpConfiguration.host,
      port: jumpConfiguration.port,
      username: jumpConfiguration.username,
      label: "loopback踏み台")
    let target = try SFTPConnectionTarget(
      host: targetConfiguration.host,
      port: targetConfiguration.port,
      username: targetConfiguration.username,
      jumpHosts: [relay])

    let suiteName = "com.pky.PKPane.unit-tests.sftp-jump-wire.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    let trustStore = SFTPHostKeyTrustStore(defaults: defaults)
    trustStore.trust(
      openSSHPublicKey: try trustedKey(jumpConfiguration.hostPublicKey),
      host: relay.host,
      port: relay.port)
    trustStore.trust(
      openSSHPublicKey: try trustedKey(targetConfiguration.hostPublicKey),
      host: target.host,
      port: target.port)

    return Fixture(
      target: target,
      trustStore: trustStore,
      defaults: defaults,
      defaultsSuiteName: suiteName,
      privateKeys: [
        relay.identity: jumpKeyURL,
        target.finalHop: targetRoot.appending(path: "ed25519"),
      ])
  }

  private func makeService(fixture: Fixture) -> CitadelSFTPConnectionService {
    CitadelSFTPConnectionService(
      passwordStore: SFTPPasswordStore(keychain: SFTPJumpWirePasswordStore()),
      privateKeyRepository: SFTPJumpWireKeyRepository(urls: fixture.privateKeys),
      hostKeyValidatorFactory: CitadelSFTPHostKeyValidatorFactory(
        trustStore: fixture.trustStore))
  }

  private func trustedKey(_ publicKey: String) throws -> String {
    let components = publicKey.split(separator: " ")
    _ = try #require(components.count >= 2)
    return components.prefix(2).joined(separator: " ")
  }

  private struct Fixture {
    let target: SFTPConnectionTarget
    let trustStore: SFTPHostKeyTrustStore
    let defaults: UserDefaults
    let defaultsSuiteName: String
    let privateKeys: [SFTPHopIdentity: URL]
  }

  private struct TargetConfiguration: Decodable {
    let host: String
    let port: Int
    let username: String
    let fixture: String
    let hostPublicKey: String
  }

  private struct JumpConfiguration: Decodable {
    let host: String
    let port: Int
    let username: String
    let privateKeyPath: String
    let hostPublicKey: String
  }
}

private final class SFTPJumpWirePasswordStore: KeychainPasswordDataStoring {
  func save(password _: String, service _: String, account _: String) throws {}
  func password(service _: String, account _: String) throws -> String? { nil }
}

private final class SFTPJumpWireKeyRepository: SFTPPrivateKeyBookmarkPersisting {
  private let urls: [SFTPHopIdentity: URL]

  init(urls: [SFTPHopIdentity: URL]) {
    self.urls = urls
  }

  func save(_: URL, for _: SFTPConnectionTarget) throws {}
  func restore(for target: SFTPConnectionTarget) throws -> URL? { urls[target.finalHop] }
  func remove(for _: SFTPConnectionTarget) {}
  func save(_: URL, for _: SFTPHopIdentity) throws {}
  func restore(for hop: SFTPHopIdentity) throws -> URL? { urls[hop] }
  func remove(for _: SFTPHopIdentity) {}
}
