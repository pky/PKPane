import Testing

@testable import PKPane

struct SMBDirectCredentialResolverTests {
  @Test("資格情報と転送先の文字列化で認証情報を伏せる")
  func descriptionsHideCredentials() {
    let credentials = SMBDirectCredentials(account: "alice", password: "secret-password")
    let target = SMBDirectTransferTarget(
      host: "nas.example.local",
      shareName: "share",
      credentials: credentials)

    #expect(String(describing: credentials) == "account: ***, password: ***")
    #expect(String(reflecting: credentials) == "account: ***, password: ***")
    #expect(!String(describing: target).contains("alice"))
    #expect(!String(describing: target).contains("secret-password"))
    #expect(!String(reflecting: target).contains("secret-password"))
  }

  @Test("KeychainのSMB資格情報を取得する")
  func returnsMatchingCredential() {
    let expected = SMBDirectCredentials(account: "tester", password: "secret")
    let resolver = SMBDirectCredentialResolver(
      keychain: StubSMBDirectCredentialQuery(credentials: [expected]))

    #expect(resolver.credentials(forServer: "nas.example.local") == expected)
  }

  @Test("Keychainに資格情報がなければnilを返す")
  func returnsNilWhenCredentialIsMissing() {
    let resolver = SMBDirectCredentialResolver(
      keychain: StubSMBDirectCredentialQuery(credentials: []))

    #expect(resolver.credentials(forServer: "nas.example.local") == nil)
  }

  @Test("同一サーバーの複数アカウントでは完全一致を優先する")
  func prefersExactAccountMatch() {
    let resolver = SMBDirectCredentialResolver(
      keychain: StubSMBDirectCredentialQuery(credentials: [
        SMBDirectCredentials(account: "guest", password: "guest-password"),
        SMBDirectCredentials(account: "tester", password: "tester-password"),
      ]))

    let expected = SMBDirectCredentials(account: "tester", password: "tester-password")
    let resolved = resolver.credentials(forServer: "nas.example.local", preferredAccount: "tester")

    #expect(resolved == expected)
  }

  @Test("Keychainアクセス失敗時はフォールバック用にnilを返す")
  func returnsNilWhenKeychainAccessFails() {
    let resolver = SMBDirectCredentialResolver(
      keychain: StubSMBDirectCredentialQuery(error: QueryError.failed))

    #expect(resolver.credentials(forServer: "nas.example.local") == nil)
  }
}

private enum QueryError: Error {
  case failed
}

private final class StubSMBDirectCredentialQuery: SMBDirectCredentialQuerying, Sendable {
  private let storedCredentials: [SMBDirectCredentials]
  private let error: Error?

  init(credentials: [SMBDirectCredentials] = [], error: Error? = nil) {
    storedCredentials = credentials
    self.error = error
  }

  func accounts(forServer _: String) throws -> [String] {
    if let error { throw error }
    return storedCredentials.map(\.account)
  }

  func credential(forServer _: String, account: String) throws -> SMBDirectCredentials? {
    if let error { throw error }
    return storedCredentials.first(where: { $0.account == account })
  }
}
