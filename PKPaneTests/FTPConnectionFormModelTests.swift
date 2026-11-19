import Foundation
import Testing

@testable import PKPane

@MainActor
struct FTPConnectionFormModelTests {
  @Test("FTPS接続設定とパスワードを保存する")
  func savesSecureConnectionAndPassword() throws {
    let keychain = FTPFormInMemoryKeychain()
    let (profileStore, defaults, suiteName) = isolatedProfileStore()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let model = FTPConnectionFormModel(
      passwordStore: FTPPasswordStore(keychain: keychain),
      profileStore: profileStore)
    model.host = "ftp.example.com"
    model.username = "tester"
    model.password = "password"
    model.startDirectory = "/incoming"

    let target = try #require(model.savePassword())

    #expect(target.security == .explicitTLS)
    #expect(target.initialDirectory == "/incoming")
    #expect(try FTPPasswordStore(keychain: keychain).password(for: target) == "password")
    #expect(profileStore.loadAll() == [target])
    #expect(model.password.isEmpty)
    #expect(model.errorMessage == nil)
  }

  @Test("接続先編集時に空欄のパスワードは既存値を引き継ぐ")
  func preservesExistingPasswordWhenEditing() throws {
    let existing = try FTPConnectionTarget(
      host: "old.example.com", username: "tester", security: .plain)
    let keychain = FTPFormInMemoryKeychain()
    let passwordStore = FTPPasswordStore(keychain: keychain)
    try passwordStore.save("existing-password", for: existing)
    let (profileStore, defaults, suiteName) = isolatedProfileStore()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    profileStore.save(existing)
    let model = FTPConnectionFormModel(
      target: existing,
      passwordStore: passwordStore,
      profileStore: profileStore)
    model.host = "new.example.com"

    let updated = try #require(model.savePassword())

    #expect(updated.security == .plain)
    #expect(try passwordStore.password(for: updated) == "existing-password")
    #expect(profileStore.loadAll() == [updated])
  }

  @Test("接続テストでFTPセッションを接続後に閉じる")
  func testsConnectionAndClosesSession() async throws {
    let keychain = FTPFormInMemoryKeychain()
    let session = FTPFormTestSession()
    let (profileStore, defaults, suiteName) = isolatedProfileStore()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let model = FTPConnectionFormModel(
      passwordStore: FTPPasswordStore(keychain: keychain),
      profileStore: profileStore,
      connectionService: FTPFormSuccessfulConnector(session: session))
    model.host = "ftp.example.com"
    model.username = "tester"
    model.password = "password"

    model.testConnection()
    await waitUntil("接続テストが期限内に完了しなかった") {
      !model.isTestingConnection
    }

    let result = try #require(model.testResultMessage)
    #expect(result.hasPrefix("応答 "))
    #expect(result.hasSuffix("ms"))
    #expect(await session.isClosed)
    #expect(model.errorMessage == nil)
  }

  private func isolatedProfileStore() -> (
    FTPConnectionProfileStore, UserDefaults, String
  ) {
    let suiteName = "FTPConnectionFormModelTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    return (FTPConnectionProfileStore(defaults: defaults), defaults, suiteName)
  }
}

private final class FTPFormInMemoryKeychain: KeychainPasswordDataStoring {
  private var passwords: [String: String] = [:]

  func save(password: String, service: String, account: String) throws {
    passwords["\(service):\(account)"] = password
  }

  func password(service: String, account: String) throws -> String? {
    passwords["\(service):\(account)"]
  }
}

private struct FTPFormSuccessfulConnector: FTPConnecting {
  let session: FTPFormTestSession

  func connect(to _: FTPConnectionTarget) async throws -> any FTPClientSession {
    session
  }
}

private actor FTPFormTestSession: FTPClientSession {
  private(set) var isClosed = false

  func contents(of _: String) async throws -> [FTPDirectoryEntry] { [] }
  func createDirectory(at _: String) async throws {}
  func remove(at _: String, isDirectory _: Bool) async throws {}
  func rename(at _: String, to _: String) async throws {}
  func streamFileContents(
    of _: String,
    receive _: @escaping @Sendable (Data) async throws -> Void
  ) async throws {}
  func writeFileContents(
    to _: String,
    chunks _: AsyncThrowingStream<Data, Error>,
    progress _: @escaping @Sendable (Int64) -> Void
  ) async throws {}
  func fileSize(at _: String) async throws -> Int64? { nil }
  func setPosixPermissions(_: Int, at _: String) async throws {}
  func isActive() async -> Bool { !isClosed }
  func close() async { isClosed = true }
}
