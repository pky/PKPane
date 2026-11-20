import Foundation
import Testing

@testable import PKPane

#if PKPANE_SFTP_LOOPBACK_TESTS
  private let sftpAuthMatrixEnabled =
    ProcessInfo.processInfo.environment["PKPANE_RV26_SFTP_MATRIX_CONFIG"] != nil
#else
  private let sftpAuthMatrixEnabled = false
#endif

/// 認証構成の違うSSHサーバー群へ本番接続経路を流し、ダイアログ回数とKeychain操作を期待表どおりに固定する。
@Suite(.serialized)
struct SFTPAuthMatrixWireTests {
  @Test("T1 password-only: 保存パスワードで接続し、ダイアログもKeychain削除も起きない", .enabled(if: sftpAuthMatrixEnabled))
  func t1PasswordOnlyWithStoredPassword() async throws {
    let env = try await makeEnvironment(server: "password-only", storedPassword: .correct)
    defer { env.cleanUp() }
    try await expectConnects(env)
    #expect(env.prompter.requests.isEmpty)
    #expect(env.keychain.events.isEmpty)
  }

  @Test(
    "T2 password-only: 誤った保存パスワードは削除され、入力した正しいパスワードで接続・保存される", .enabled(if: sftpAuthMatrixEnabled))
  func t2PasswordOnlyWithWrongStoredPassword() async throws {
    let env = try await makeEnvironment(
      server: "password-only", storedPassword: .wrong,
      answers: [SFTPCredentialAnswer(secret: try configurationPassword(), saveToKeychain: true)])
    defer { env.cleanUp() }
    try await expectConnects(env)
    #expect(env.prompter.requests.count == 1)
    #expect(env.keychain.events == [.save(env.configuration.password)])
  }

  @Test(
    "T3 password-only: 誤ったパスワードを1回入れると hopAuthenticationFailed で終わる",
    .enabled(if: sftpAuthMatrixEnabled))
  func t3PasswordOnlyWrongThreeTimes() async throws {
    let env = try await makeEnvironment(
      server: "password-only", storedPassword: .none,
      fallback: SFTPCredentialAnswer(
        secret: try configurationWrongPassword(), saveToKeychain: false))
    defer { env.cleanUp() }
    await expectHopAuthenticationFailed(env)
    #expect(env.prompter.requests.map(\.attempt) == [1])
  }

  @Test(
    "T4 password-only: ダイアログのキャンセルは authenticationCancelled で1回だけ聞く",
    .enabled(if: sftpAuthMatrixEnabled))
  func t4PasswordOnlyCancelled() async throws {
    let env = try await makeEnvironment(
      server: "password-only", storedPassword: .none, fallback: nil)
    defer { env.cleanUp() }
    do {
      _ = try await env.service.connect(to: env.target, intent: .userInitiated, hopProgress: nil)
      Issue.record("接続が成功してはいけない")
    } catch let error as SFTPConnectionServiceError {
      if case .authenticationCancelled = error {
      } else {
        Issue.record("authenticationCancelled が期待されたが \(error) だった")
      }
    } catch {
      Issue.record("SFTPConnectionServiceError が期待されたが \(type(of: error)) だった")
    }
    #expect(env.prompter.requests.count == 1)
  }

  @Test("T5 password-only: バックグラウンド接続はパスワード未保存ならダイアログなしでエラー", .enabled(if: sftpAuthMatrixEnabled))
  func t5PasswordOnlyBackground() async throws {
    let env = try await makeEnvironment(server: "password-only", storedPassword: .none)
    defer { env.cleanUp() }
    do {
      let session = try await env.service.connect(
        to: env.target, intent: .background, hopProgress: nil)
      try? await session.close()
      Issue.record("接続が成功してはいけない")
    } catch {
    }
    #expect(env.prompter.requests.isEmpty)
  }

  @Test("T6 publickey-only: 鍵で接続し、ダイアログは出ない", .enabled(if: sftpAuthMatrixEnabled))
  func t6PublicKeyOnlyWithKey() async throws {
    let env = try await makeEnvironment(
      server: "publickey-only", storedPassword: .none, useKey: true)
    defer { env.cleanUp() }
    try await expectConnects(env)
    #expect(env.prompter.requests.isEmpty)
  }

  @Test(
    "T7 publickey-only: 保存パスワードを維持し、ダイアログなしで publicKeyAuthenticationRequired を返す",
    .enabled(if: sftpAuthMatrixEnabled))
  func t7PublicKeyOnlyWithoutKey() async throws {
    let env = try await makeEnvironment(
      server: "publickey-only", storedPassword: .correct,
      fallback: SFTPCredentialAnswer(secret: try configurationPassword(), saveToKeychain: false))
    defer { env.cleanUp() }
    let error = await connectExpectingFailure(env) as? SFTPConnectionServiceError
    #expect(error == .publicKeyAuthenticationRequired(env.target.finalHop))
    #expect(env.prompter.requests.isEmpty)
    #expect(env.keychain.events.isEmpty)
  }

  @Test(
    "T8 keyboard-interactive-only: 保存パスワードを維持し、ダイアログなしで unsupportedAuthenticationMethods を返す",
    .enabled(if: sftpAuthMatrixEnabled)
  )
  func t8KeyboardInteractiveOnly() async throws {
    let env = try await makeEnvironment(
      server: "keyboard-interactive-only", storedPassword: .correct,
      fallback: SFTPCredentialAnswer(secret: try configurationPassword(), saveToKeychain: false))
    defer { env.cleanUp() }
    let error = await connectExpectingFailure(env) as? SFTPConnectionServiceError
    #expect(error == .unsupportedAuthenticationMethods(env.target.finalHop))
    #expect(env.prompter.requests.isEmpty)
    #expect(env.keychain.events.isEmpty)
  }

  @Test(
    "T13 publickey-only: パスワード未保存ならダイアログなしで publicKeyAuthenticationRequired を返す",
    .enabled(if: sftpAuthMatrixEnabled))
  func t13PublicKeyOnlyWithoutStoredPassword() async throws {
    let env = try await makeEnvironment(
      server: "publickey-only", storedPassword: .none,
      fallback: SFTPCredentialAnswer(secret: try configurationPassword(), saveToKeychain: true))
    defer { env.cleanUp() }
    let error = await connectExpectingFailure(env) as? SFTPConnectionServiceError
    #expect(error == .publicKeyAuthenticationRequired(env.target.finalHop))
    #expect(env.prompter.requests.isEmpty)
    #expect(env.keychain.events.isEmpty)
  }

  @Test("T9 openssh-8: 保存パスワードで接続し、ダイアログは出ない", .enabled(if: sftpAuthMatrixEnabled))
  func t9OpenSSH8WithStoredPassword() async throws {
    let env = try await makeEnvironment(server: "openssh-8", storedPassword: .correct)
    defer { env.cleanUp() }
    try await expectConnects(env)
    #expect(env.prompter.requests.isEmpty)
  }

  @Test("T10 openssh-8: 鍵で接続し、ダイアログは出ない", .enabled(if: sftpAuthMatrixEnabled))
  func t10OpenSSH8WithKey() async throws {
    let env = try await makeEnvironment(server: "openssh-8", storedPassword: .none, useKey: true)
    defer { env.cleanUp() }
    try await expectConnects(env)
    #expect(env.prompter.requests.isEmpty)
  }

  @Test("T11 dropbear: 保存パスワードで接続し、ダイアログは出ない", .enabled(if: sftpAuthMatrixEnabled))
  func t11DropbearWithStoredPassword() async throws {
    let env = try await makeEnvironment(server: "dropbear", storedPassword: .correct)
    defer { env.cleanUp() }
    try await expectConnects(env)
    #expect(env.prompter.requests.isEmpty)
  }

  @Test("T12 dropbear: 鍵で接続し、ダイアログは出ない", .enabled(if: sftpAuthMatrixEnabled))
  func t12DropbearWithKey() async throws {
    let env = try await makeEnvironment(server: "dropbear", storedPassword: .none, useKey: true)
    defer { env.cleanUp() }
    try await expectConnects(env)
    #expect(env.prompter.requests.isEmpty)
  }

  // MARK: - 判定ヘルパー

  private func expectConnects(_ env: MatrixEnvironment) async throws {
    let session = try await env.service.connect(
      to: env.target, intent: .userInitiated, hopProgress: nil)
    do {
      let entries = try await session.contents(of: ".")
      #expect(entries.contains { $0.name == env.configuration.fixtureFileName })
      try await session.close()
    } catch {
      try? await session.close()
      throw error
    }
  }

  private func expectHopAuthenticationFailed(_ env: MatrixEnvironment) async {
    do {
      _ = try await env.service.connect(to: env.target, intent: .userInitiated, hopProgress: nil)
      Issue.record("接続が成功してはいけない")
    } catch let error as SFTPConnectionServiceError {
      if case .hopAuthenticationFailed = error {
      } else {
        Issue.record("hopAuthenticationFailed が期待されたが \(error) だった")
      }
    } catch {
      Issue.record("SFTPConnectionServiceError が期待されたが \(type(of: error)) だった")
    }
  }

  private func connectExpectingFailure(_ env: MatrixEnvironment) async -> (any Error)? {
    do {
      let session = try await env.service.connect(
        to: env.target, intent: .userInitiated, hopProgress: nil)
      try? await session.close()
      Issue.record("接続が成功してはいけない")
      return nil
    } catch {
      return error
    }
  }

  // MARK: - 環境構築

  private enum StoredPassword { case none, correct, wrong }

  private func loadConfiguration() throws -> (Configuration, URL) {
    let path = try #require(
      ProcessInfo.processInfo.environment["PKPANE_RV26_SFTP_MATRIX_CONFIG"])
    let url = URL(fileURLWithPath: path)
    let root = url.deletingLastPathComponent()
    _ = try #require(root.path.hasPrefix("/private/tmp/pkpane-rv26-sftp-matrix-"))
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url))
    _ = try #require(configuration.host == "127.0.0.1")
    return (configuration, root)
  }

  private func configurationPassword() throws -> String { try loadConfiguration().0.password }

  private func configurationWrongPassword() throws -> String {
    try loadConfiguration().0.wrongPassword
  }

  private func makeEnvironment(
    server: String,
    storedPassword: StoredPassword,
    useKey: Bool = false,
    answers: [SFTPCredentialAnswer?] = [],
    fallback: SFTPCredentialAnswer? = nil
  ) async throws -> MatrixEnvironment {
    let (configuration, root) = try loadConfiguration()
    let serverConfiguration = try #require(configuration.servers[server])
    let target = try SFTPConnectionTarget(
      host: configuration.host, port: serverConfiguration.port, username: configuration.username)

    let suiteName = "com.pky.PKPane.unit-tests.sftp-matrix.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    let trustStore = SFTPHostKeyTrustStore(defaults: defaults)
    let keyComponents = serverConfiguration.hostPublicKey.split(separator: " ")
    _ = try #require(keyComponents.count >= 2)
    trustStore.trust(
      openSSHPublicKey: keyComponents.prefix(2).joined(separator: " "),
      host: target.host, port: target.port)

    let keychain = MatrixKeychain()
    let passwordStore = SFTPPasswordStore(keychain: keychain)
    switch storedPassword {
    case .none: break
    case .correct:
      try passwordStore.save(configuration.password, for: target.finalHop, kind: .password)
    case .wrong:
      try passwordStore.save(configuration.wrongPassword, for: target.finalHop, kind: .password)
    }
    // 事前投入は製品操作ではないので、検証対象の記録から外す。
    keychain.resetEvents()

    var keyURLs: [SFTPHopIdentity: URL] = [:]
    if useKey {
      let keyURL = URL(fileURLWithPath: configuration.privateKeyPath)
      _ = try #require(keyURL.path.hasPrefix(root.path + "/"))
      keyURLs[target.finalHop] = keyURL
    }

    let prompter = MatrixPrompter(answers: answers, fallback: fallback)
    let service = CitadelSFTPConnectionService(
      passwordStore: passwordStore,
      privateKeyRepository: MatrixKeyRepository(urls: keyURLs),
      hostKeyValidatorFactory: CitadelSFTPHostKeyValidatorFactory(trustStore: trustStore),
      credentialPrompter: prompter)

    return MatrixEnvironment(
      configuration: configuration, target: target, service: service,
      prompter: prompter, keychain: keychain, defaults: defaults, suiteName: suiteName)
  }

  private struct MatrixEnvironment {
    let configuration: Configuration
    let target: SFTPConnectionTarget
    let service: CitadelSFTPConnectionService
    let prompter: MatrixPrompter
    let keychain: MatrixKeychain
    let defaults: UserDefaults
    let suiteName: String

    func cleanUp() { defaults.removePersistentDomain(forName: suiteName) }
  }

  private struct Configuration: Decodable {
    let host: String
    let username: String
    let password: String
    let wrongPassword: String
    let privateKeyPath: String
    let fixtureFileName: String
    let composeProject: String
    let servers: [String: ServerConfiguration]
  }

  private struct ServerConfiguration: Decodable {
    let port: Int
    let hostPublicKey: String
    let banner: String
  }
}

// MARK: - フェイク

/// 台本は呼び出し順で引く。尽きたら fallback を返す。
private final class MatrixPrompter: SFTPCredentialPrompting, @unchecked Sendable {
  private let lock = NSLock()
  private let answers: [SFTPCredentialAnswer?]
  private let fallback: SFTPCredentialAnswer?
  private var recorded: [SFTPCredentialRequest] = []

  init(answers: [SFTPCredentialAnswer?], fallback: SFTPCredentialAnswer?) {
    self.answers = answers
    self.fallback = fallback
  }

  var requests: [SFTPCredentialRequest] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  func requestCredential(_ request: SFTPCredentialRequest) async -> SFTPCredentialAnswer? {
    record(request)
  }

  // NSLock.lock() は async 文脈で使えないため、同期関数に切り出してロックする。
  private func record(_ request: SFTPCredentialRequest) -> SFTPCredentialAnswer? {
    lock.lock()
    defer { lock.unlock() }
    let index = recorded.count
    recorded.append(request)
    return index < answers.count ? answers[index] : fallback
  }
}

private final class MatrixKeychain: KeychainPasswordDataStoring, @unchecked Sendable {
  enum Event: Equatable {
    case save(String)
    case remove
  }

  private let lock = NSLock()
  private var values: [String: String] = [:]
  private var recorded: [Event] = []

  var events: [Event] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  func resetEvents() {
    lock.lock()
    defer { lock.unlock() }
    recorded.removeAll()
  }

  func save(password: String, service: String, account: String) throws {
    lock.lock()
    defer { lock.unlock() }
    values["\(service)|\(account)"] = password
    recorded.append(.save(password))
  }

  func password(service: String, account: String) throws -> String? {
    lock.lock()
    defer { lock.unlock() }
    return values["\(service)|\(account)"]
  }

  func remove(service: String, account: String) throws {
    lock.lock()
    defer { lock.unlock() }
    values["\(service)|\(account)"] = nil
    recorded.append(.remove)
  }
}

private final class MatrixKeyRepository: SFTPPrivateKeyBookmarkPersisting, @unchecked Sendable {
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
