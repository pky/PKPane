import Testing

@testable import PKPane

struct FTPPasswordStoreTests {
  @Test("資格情報を接続方式と接続先ごとのKeychain項目へ保存する")
  func savesPassword() throws {
    let target = try FTPConnectionTarget(host: "example.com", username: "tester")
    let keychain = FTPRecordingKeychainStore()
    let store = FTPPasswordStore(keychain: keychain)

    try store.save("password", for: target)

    #expect(keychain.savedService == "com.pky.PKPane.ftp-password")
    #expect(keychain.savedAccount == "explicitTLS:example.com:21:tester")
    #expect(try store.password(for: target) == "password")
  }
}

private final class FTPRecordingKeychainStore: KeychainPasswordDataStoring {
  private(set) var savedService: String?
  private(set) var savedAccount: String?
  private var savedPassword: String?

  func save(password: String, service: String, account: String) throws {
    savedService = service
    savedAccount = account
    savedPassword = password
  }

  func password(service _: String, account _: String) throws -> String? {
    savedPassword
  }
}
