import Foundation
import Testing

@testable import PKPane

struct SFTPHostKeyTrustStoreTests {
  @Test("未知・一致・変更済みのホスト鍵を区別する")
  func distinguishesHostKeyTrustStatus() throws {
    let suiteName = "SFTPHostKeyTrustStoreTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let store = SFTPHostKeyTrustStore(defaults: defaults)

    #expect(store.status(for: target, fingerprint: "SHA256:old") == .unknown)

    store.trust("SHA256:known", for: target)

    #expect(store.status(for: target, fingerprint: "SHA256:known") == .trusted)
    #expect(store.status(for: target, fingerprint: "SHA256:changed") == .changed)
  }

  @Test("信頼したOpenSSH公開鍵を接続時の照合用に保持する")
  func savesTrustedOpenSSHPublicKey() throws {
    let suiteName = "SFTPHostKeyTrustStoreKeyTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let publicKey =
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJfkNV4OS33ImTXvorZr72q4v5XhVEQKfvqsxOEJ/XaR"
    let store = SFTPHostKeyTrustStore(defaults: defaults)

    store.trust(openSSHPublicKey: publicKey, for: target)

    #expect(store.trustedOpenSSHPublicKey(for: target) == publicKey)
  }

  @Test("既知のホスト鍵が一致する接続失敗はホスト鍵変更として扱わない")
  func preservesNonHostKeyErrorWhenTrustedKeyMatches() {
    let knownKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleHostKey"

    #expect(
      CitadelSFTPConnectionService.hostKeyError(
        capturedPublicKey: knownKey,
        trustedPublicKey: knownKey) == nil)
  }

  @Test("未知または変更済みのホスト鍵だけを承認フローに送る")
  func returnsHostKeyErrorOnlyWhenApprovalIsRequired() {
    let knownKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKnownHostKey"
    let changedKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIChangedHostKey"

    #expect(
      CitadelSFTPConnectionService.hostKeyError(
        capturedPublicKey: knownKey,
        trustedPublicKey: nil) == .hostKeyRequiresApproval(knownKey))
    #expect(
      CitadelSFTPConnectionService.hostKeyError(
        capturedPublicKey: changedKey,
        trustedPublicKey: knownKey) == .hostKeyChanged(changedKey))
  }
}
