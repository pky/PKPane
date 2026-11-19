import Testing

@testable import PKPane

struct SFTPPasswordStoreTests {
  @Test("パスワードを接続先ごとのKeychain項目へ保存する")
  func savesPasswordForTarget() throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let keychain = RecordingKeychainPasswordDataStore()
    let store = SFTPPasswordStore(keychain: keychain)

    try store.save("password", for: target)

    #expect(keychain.savedService == "com.pky.PKPane.sftp-password")
    #expect(keychain.savedAccount == "example.com:22:tester")
    #expect(keychain.savedPassword == "password")
  }

  @Test("保存済みパスワードを接続先ごとに取得する")
  func loadsPasswordForTarget() throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let keychain = RecordingKeychainPasswordDataStore(password: "password")
    let store = SFTPPasswordStore(keychain: keychain)

    #expect(try store.password(for: target) == "password")
  }

  @Test("最終ホップのパスワードは従来の接続先と同じKeychain項目へ保存する")
  func hopPasswordAccountMatchesLegacyTargetAccount() throws {
    let keychain = RecordingKeychainPasswordDataStore()
    let store = SFTPPasswordStore(keychain: keychain)
    let target = try SFTPConnectionTarget(host: "files.example", port: 22, username: "tester")
    try store.save("x", for: target)
    let legacyAccount = keychain.lastAccount

    try store.save("y", for: target.finalHop, kind: .password)

    #expect(keychain.lastAccount == legacyAccount)
  }

  @Test("パスフレーズのKeychain項目には鍵の絶対パスを含める")
  func passphraseAccountIncludesKeyPath() throws {
    let keychain = RecordingKeychainPasswordDataStore()
    let store = SFTPPasswordStore(keychain: keychain)
    let hop = SFTPHopIdentity(host: "gateway", port: 22, username: "ops")

    try store.save("p", for: hop, kind: .passphrase(keyPath: "/Users/me/.ssh/id_ed25519"))

    #expect(keychain.lastAccount == "gateway:22:ops#passphrase:/Users/me/.ssh/id_ed25519")
  }

  @Test("ホップの保存済み資格情報を削除する")
  func removeDeletesHopSecret() throws {
    let keychain = InMemoryKeychainPasswordDataStore()
    let store = SFTPPasswordStore(keychain: keychain)
    let hop = SFTPHopIdentity(host: "gateway", port: 22, username: "ops")
    try store.save("s", for: hop, kind: .password)
    #expect(try store.secret(for: hop, kind: .password) == "s")

    try store.remove(for: hop, kind: .password)

    #expect(try store.secret(for: hop, kind: .password) == nil)
  }
}

private final class RecordingKeychainPasswordDataStore: KeychainPasswordDataStoring {
  private let storedPassword: String?
  private(set) var savedService: String?
  private(set) var savedAccount: String?
  private(set) var savedPassword: String?

  var lastAccount: String? {
    savedAccount
  }

  init(password: String? = nil) {
    storedPassword = password
  }

  func save(password: String, service: String, account: String) throws {
    savedService = service
    savedAccount = account
    savedPassword = password
  }

  func password(service: String, account: String) throws -> String? {
    storedPassword
  }
}

private final class InMemoryKeychainPasswordDataStore: KeychainPasswordDataStoring {
  private var passwords: [String: String] = [:]

  func save(password: String, service: String, account: String) throws {
    passwords["\(service):\(account)"] = password
  }

  func password(service: String, account: String) throws -> String? {
    passwords["\(service):\(account)"]
  }

  func remove(service: String, account: String) throws {
    passwords["\(service):\(account)"] = nil
  }
}
