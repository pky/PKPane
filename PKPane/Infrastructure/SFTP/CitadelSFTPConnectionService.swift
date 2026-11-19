import Citadel
import Crypto
import Foundation
import NIOSSH

struct SFTPHostKeyApprovalRequest: Equatable, Sendable {
  let host: String
  let port: Int
  let publicKey: String
}

enum SFTPConnectionServiceError: LocalizedError, Equatable, ReconnectFutileError,
  CustomStringConvertible
{
  case passwordNotFound
  case privateKeyNotFound
  case unsupportedPrivateKey
  case hostKeyRequiresApproval(SFTPHostKeyApprovalRequest)
  case hostKeyChanged(SFTPHostKeyApprovalRequest)
  case hopAuthenticationFailed(SFTPHopIdentity, reason: String?)
  case authenticationCancelled

  // 既存のフェイクが公開鍵文字列だけでエラーを組み立てる経路を保つ。
  static func hostKeyRequiresApproval(_ publicKey: String) -> Self {
    .hostKeyRequiresApproval(
      SFTPHostKeyApprovalRequest(host: "", port: 22, publicKey: publicKey))
  }

  static func hostKeyChanged(_ publicKey: String) -> Self {
    .hostKeyChanged(
      SFTPHostKeyApprovalRequest(host: "", port: 22, publicKey: publicKey))
  }

  var errorDescription: String? {
    switch self {
    case .passwordNotFound:
      "SFTP接続用のパスワードが保存されていません。"
    case .privateKeyNotFound:
      "SFTP接続用の秘密鍵を読み取れません。"
    case .unsupportedPrivateKey:
      "この秘密鍵形式には対応していません。Ed25519、RSA、ECDSAのOpenSSH秘密鍵を指定してください。"
    case .hostKeyRequiresApproval:
      "SFTPサーバーのホスト鍵を確認して承認してください。"
    case .hostKeyChanged:
      "SFTPサーバーのホスト鍵が変更されました。接続を中止しました。"
    case .hopAuthenticationFailed(let hop, _):
      String(
        format: String(
          localized:
            "%@:%ld の認証に失敗しました。パスワードが誤っているか、サーバーが password 認証を受け付けていません。"),
        hop.host, hop.port)
    case .authenticationCancelled:
      String(localized: "SFTP接続の認証をキャンセルしました。")
    }
  }

  var description: String {
    switch self {
    case .passwordNotFound: "passwordNotFound"
    case .privateKeyNotFound: "privateKeyNotFound"
    case .unsupportedPrivateKey: "unsupportedPrivateKey"
    case .hostKeyRequiresApproval: "hostKeyRequiresApproval"
    case .hostKeyChanged: "hostKeyChanged"
    case .hopAuthenticationFailed: "hopAuthenticationFailed"
    case .authenticationCancelled: "authenticationCancelled"
    }
  }
}

struct SFTPHopConnectionError: Error, LocalizedError {
  let hop: SFTPHopIdentity
  let underlying: any Error

  var errorDescription: String? {
    String(
      format: String(localized: "%@:%ld へ接続できません: %@"),
      hop.host,
      hop.port,
      ConnectionErrorClassifier.guidanceMessage(for: underlying))
  }
}

protocol SFTPConnecting: Sendable {
  func connect(to target: SFTPConnectionTarget) async throws -> any SFTPClientSession
  func connect(
    to target: SFTPConnectionTarget,
    intent: SFTPConnectionIntent,
    hopProgress: (@Sendable (SFTPHopIdentity, Duration) -> Void)?
  ) async throws -> any SFTPClientSession
}

extension SFTPConnecting {
  func connect(to target: SFTPConnectionTarget) async throws -> any SFTPClientSession {
    try await connect(to: target, intent: .userInitiated, hopProgress: nil)
  }

  func connect(
    to target: SFTPConnectionTarget,
    intent _: SFTPConnectionIntent,
    hopProgress _: (@Sendable (SFTPHopIdentity, Duration) -> Void)?
  ) async throws -> any SFTPClientSession {
    try await connect(to: target)
  }
}

struct CitadelSFTPConnectionService: SFTPConnecting, @unchecked Sendable {
  let passwordStore: SFTPPasswordStore
  let privateKeyRepository: any SFTPPrivateKeyBookmarkPersisting
  let hostKeyValidatorFactory: CitadelSFTPHostKeyValidatorFactory
  let hopConnector: SSHHopConnector
  let credentialPrompter: any SFTPCredentialPrompting
  let credentialCache: SFTPSessionCredentialCache
  private let rejectionLedger = SFTPRejectionLedger()
  private let keyLoader: @Sendable (URL, String?) throws -> NIOSSHPrivateKey
  private let usesInjectedKeyLoader: Bool

  init(
    passwordStore: SFTPPasswordStore = SFTPPasswordStore(),
    privateKeyRepository: any SFTPPrivateKeyBookmarkPersisting = SFTPPrivateKeyBookmarkRepository(),
    hostKeyValidatorFactory: CitadelSFTPHostKeyValidatorFactory =
      CitadelSFTPHostKeyValidatorFactory(trustStore: SFTPHostKeyTrustStore()),
    hopConnector: @escaping SSHHopConnector = { settings in
      CitadelSSHHopTransport(client: try await SSHClient.connect(to: settings))
    },
    credentialPrompter: any SFTPCredentialPrompting = SFTPNoPromptCredentialPrompter(),
    credentialCache: SFTPSessionCredentialCache = SFTPSessionCredentialCache()
  ) {
    self.init(
      passwordStore: passwordStore,
      privateKeyRepository: privateKeyRepository,
      hostKeyValidatorFactory: hostKeyValidatorFactory,
      hopConnector: hopConnector,
      credentialPrompter: credentialPrompter,
      credentialCache: credentialCache,
      keyLoader: Self.defaultKeyLoader,
      usesInjectedKeyLoader: false)
  }

  init(
    passwordStore: SFTPPasswordStore = SFTPPasswordStore(),
    privateKeyRepository: any SFTPPrivateKeyBookmarkPersisting = SFTPPrivateKeyBookmarkRepository(),
    hostKeyValidatorFactory: CitadelSFTPHostKeyValidatorFactory =
      CitadelSFTPHostKeyValidatorFactory(trustStore: SFTPHostKeyTrustStore()),
    hopConnector: @escaping SSHHopConnector = { settings in
      CitadelSSHHopTransport(client: try await SSHClient.connect(to: settings))
    },
    credentialPrompter: any SFTPCredentialPrompting = SFTPNoPromptCredentialPrompter(),
    credentialCache: SFTPSessionCredentialCache = SFTPSessionCredentialCache(),
    keyLoader: @escaping @Sendable (URL, String?) throws -> NIOSSHPrivateKey
  ) {
    self.init(
      passwordStore: passwordStore,
      privateKeyRepository: privateKeyRepository,
      hostKeyValidatorFactory: hostKeyValidatorFactory,
      hopConnector: hopConnector,
      credentialPrompter: credentialPrompter,
      credentialCache: credentialCache,
      keyLoader: keyLoader,
      usesInjectedKeyLoader: true)
  }

  private init(
    passwordStore: SFTPPasswordStore,
    privateKeyRepository: any SFTPPrivateKeyBookmarkPersisting,
    hostKeyValidatorFactory: CitadelSFTPHostKeyValidatorFactory,
    hopConnector: @escaping SSHHopConnector,
    credentialPrompter: any SFTPCredentialPrompting,
    credentialCache: SFTPSessionCredentialCache,
    keyLoader: @escaping @Sendable (URL, String?) throws -> NIOSSHPrivateKey,
    usesInjectedKeyLoader: Bool
  ) {
    self.passwordStore = passwordStore
    self.privateKeyRepository = privateKeyRepository
    self.hostKeyValidatorFactory = hostKeyValidatorFactory
    self.hopConnector = hopConnector
    self.credentialPrompter = credentialPrompter
    self.credentialCache = credentialCache
    self.keyLoader = keyLoader
    self.usesInjectedKeyLoader = usesInjectedKeyLoader
  }

  func connect(
    to target: SFTPConnectionTarget,
    intent: SFTPConnectionIntent,
    hopProgress: (@Sendable (SFTPHopIdentity, Duration) -> Void)?
  ) async throws -> any SFTPClientSession {
    let reconnect: SFTPReconnectingSession.SessionFactory = { [self] in
      try await connectSession(to: target, intent: .background, hopProgress: nil)
    }
    let session = try await connectSession(
      to: target,
      intent: intent,
      hopProgress: hopProgress)
    return SFTPReconnectingSession(session: session, reconnect: reconnect)
  }

  private func connectSession(
    to target: SFTPConnectionTarget,
    intent: SFTPConnectionIntent,
    hopProgress: (@Sendable (SFTPHopIdentity, Duration) -> Void)?
  ) async throws -> any SFTPClientSession {
    var transports: [any SSHHopTransport] = []

    for (index, hop) in target.hops.enumerated() {
      Self.logConnect("hop begin index=\(index)", hop: hop)
      let validation = hostKeyValidatorFactory.validation(host: hop.host, port: hop.port)
      let startedAt = ContinuousClock.now

      do {
        let transport = try await connectHop(
          for: hop,
          label: label(forHopAt: index, target: target),
          intent: intent,
          isFinalHop: index == target.hops.count - 1,
          previous: transports.last,
          validation: validation)
        transports.append(transport)
        hopProgress?(hop, ContinuousClock.now - startedAt)
      } catch {
        await close(transports: transports)
        if error is CancellationError { throw error }
        try Task.checkCancellation()
        if let hostKeyError = Self.hostKeyError(
          capturedPublicKey: validation.capture.publicKey,
          trustedPublicKey: validation.trustedPublicKey,
          host: hop.host,
          port: hop.port)
        {
          throw hostKeyError
        }
        if let serviceError = error as? SFTPConnectionServiceError {
          throw serviceError
        }
        if let connectionError = error as? SFTPHopConnectionError {
          throw connectionError
        }
        throw SFTPHopConnectionError(hop: hop, underlying: error)
      }
    }

    guard let finalTransport = transports.last else {
      throw SFTPHopConnectionError(
        hop: target.finalHop,
        underlying: SFTPConnectionTargetError.invalidHost)
    }
    do {
      let base = try await finalTransport.openSFTPSession()
      return SFTPChainedClientSession(base: base, transports: transports)
    } catch {
      await close(transports: transports)
      if error is CancellationError { throw error }
      try Task.checkCancellation()
      throw SFTPHopConnectionError(hop: target.finalHop, underlying: error)
    }
  }

  private func connectHop(
    for hop: SFTPHopIdentity,
    label: String?,
    intent: SFTPConnectionIntent,
    isFinalHop: Bool,
    previous: (any SSHHopTransport)?,
    validation: SFTPHostKeyValidation
  ) async throws -> any SSHHopTransport {
    let privateKeyURL: URL?
    var keyFailureReason: String?
    do {
      privateKeyURL = try privateKeyRepository.restore(for: hop)
    } catch {
      privateKeyURL = nil
      keyFailureReason = SecretMasker.maskForDisplay(error)
    }
    Self.logConnect("keyLookup done hasKey=\(privateKeyURL != nil)", hop: hop)
    let keychainPassword = try passwordStore.secret(for: hop, kind: .password)
    Self.logConnect("keychainLookup done hasPassword=\(keychainPassword != nil)", hop: hop)
    let cachedPassword = await credentialCache.secret(for: hop, kind: .password)
    Self.logConnect("cacheLookup done hasPassword=\(cachedPassword != nil)", hop: hop)
    var usesPasswordSlotForKeyDecryption = false

    if let privateKeyURL {
      let prepared = try await preparePrivateKey(
        at: privateKeyURL,
        for: hop,
        label: label,
        intent: intent,
        isFinalHop: isFinalHop,
        legacyPassword: keychainPassword)
      keyFailureReason = prepared.failureReason
      usesPasswordSlotForKeyDecryption = prepared.usedLegacyPasswordSlot
      if let privateKey = prepared.privateKey {
        do {
          let transport = try await dial(
            settings(
              for: hop,
              authentication: .privateKey(username: hop.username, key: privateKey),
              validation: validation),
            previous: previous)
          Self.logAuthResult(hop: hop, method: "privateKey", outcome: "accepted")
          return transport
        } catch {
          Self.logAuthResult(hop: hop, method: "privateKey", outcome: Self.describe(error))
          guard Self.isRetryableAuthenticationFailure(error) else { throw error }
        }
      }
    }

    // セッションキャッシュは直前に成功した値なので、古いかもしれない Keychain 値より優先する。
    var storedCandidates: [(secret: String, method: String)] = []
    if !usesPasswordSlotForKeyDecryption {
      if let cachedPassword { storedCandidates.append((cachedPassword, "storedPassword(cache)")) }
      if let keychainPassword, keychainPassword != cachedPassword {
        storedCandidates.append((keychainPassword, "storedPassword(keychain)"))
      }
    }
    if storedCandidates.isEmpty, privateKeyURL == nil {
      Self.logAuthAttempt(hop: hop, method: "noStoredPassword")
    }
    for candidate in storedCandidates {
      if await rejectionLedger.isRejected(candidate.secret, for: hop, kind: .password) {
        Self.logAuthAttempt(hop: hop, method: "storedPassword(skippedRejected)")
        continue
      }
      Self.logAuthAttempt(hop: hop, method: candidate.method)
      do {
        let transport = try await dial(
          settings(
            for: hop,
            authentication: .password(username: hop.username, secret: candidate.secret),
            validation: validation),
          previous: previous)
        Self.logAuthResult(hop: hop, method: "storedPassword", outcome: "accepted")
        await rejectionLedger.clearRejections(for: hop, kind: .password)
        return transport
      } catch {
        Self.logAuthResult(hop: hop, method: "storedPassword", outcome: Self.describe(error))
        guard Self.isRetryableAuthenticationFailure(error) else { throw error }
        // 拒否の原因がパスワード誤りとは限らないため消さず、再送だけを止める。
        await rejectionLedger.markRejected(candidate.secret, for: hop, kind: .password)
      }
    }

    if case .userInitiated = intent {
      // 入力の繰り返しは未提示方式のサーバーで無駄に聞き直すだけなので1回で終える。
      Self.logAuthAttempt(hop: hop, method: "passwordPrompt(waitingDialog)")
      guard
        let answer = await credentialPrompter.requestCredential(
          SFTPCredentialRequest(hop: hop, kind: .password, attempt: 1, label: label))
      else { throw SFTPConnectionServiceError.authenticationCancelled }

      Self.logAuthAttempt(hop: hop, method: "promptedPassword#1")
      do {
        let transport = try await dial(
          settings(
            for: hop,
            authentication: .password(username: hop.username, secret: answer.secret),
            validation: validation),
          previous: previous)
        Self.logAuthResult(hop: hop, method: "promptedPassword#1", outcome: "accepted")
        await saveCredential(answer, for: hop, kind: .password)
        await rejectionLedger.clearRejections(for: hop, kind: .password)
        return transport
      } catch {
        Self.logAuthResult(hop: hop, method: "promptedPassword#1", outcome: Self.describe(error))
        guard Self.isRetryableAuthenticationFailure(error) else { throw error }
      }
    }

    throw SFTPConnectionServiceError.hopAuthenticationFailed(hop, reason: keyFailureReason)
  }

  private func preparePrivateKey(
    at url: URL,
    for hop: SFTPHopIdentity,
    label: String?,
    intent: SFTPConnectionIntent,
    isFinalHop: Bool,
    legacyPassword: String?
  ) async throws -> PreparedPrivateKey {
    Self.logAuthAttempt(hop: hop, method: "privateKey")
    var lastError: Error?
    do {
      return PreparedPrivateKey(privateKey: try loadPrivateKey(at: url, passphrase: nil))
    } catch {
      lastError = error
      if error is SFTPConnectionServiceError {
        return PreparedPrivateKey(failureReason: SecretMasker.maskForDisplay(error))
      }
    }

    let kind = SFTPCredentialKind.passphrase(keyPath: url.path)
    let keychainPassphrase = try passwordStore.secret(for: hop, kind: kind)
    let cachedPassphrase = await credentialCache.secret(for: hop, kind: kind)
    if let passphrase = keychainPassphrase ?? cachedPassphrase {
      do {
        return PreparedPrivateKey(
          privateKey: try loadPrivateKey(at: url, passphrase: passphrase))
      } catch {
        lastError = error
      }
    } else if isFinalHop, let legacyPassword {
      do {
        let privateKey = try loadPrivateKey(at: url, passphrase: legacyPassword)
        do {
          try passwordStore.save(legacyPassword, for: hop, kind: kind)
          try? passwordStore.remove(for: hop, kind: .password)
        } catch {
          await credentialCache.store(legacyPassword, for: hop, kind: kind)
        }
        await credentialCache.remove(for: hop, kind: .password)
        return PreparedPrivateKey(privateKey: privateKey, usedLegacyPasswordSlot: true)
      } catch {
        lastError = error
      }
    }

    if case .userInitiated = intent {
      for attempt in 1...3 {
        Self.logAuthAttempt(hop: hop, method: "passphrasePrompt#\(attempt)(waitingDialog)")
        guard
          let answer = await credentialPrompter.requestCredential(
            SFTPCredentialRequest(hop: hop, kind: kind, attempt: attempt, label: label))
        else { throw SFTPConnectionServiceError.authenticationCancelled }
        do {
          let privateKey = try loadPrivateKey(at: url, passphrase: answer.secret)
          await saveCredential(answer, for: hop, kind: kind)
          return PreparedPrivateKey(privateKey: privateKey)
        } catch {
          lastError = error
        }
      }
    }

    return PreparedPrivateKey(failureReason: lastError.map(SecretMasker.maskForDisplay))
  }

  private func saveCredential(
    _ answer: SFTPCredentialAnswer,
    for hop: SFTPHopIdentity,
    kind: SFTPCredentialKind
  ) async {
    if answer.saveToKeychain {
      await credentialCache.remove(for: hop, kind: kind)
      do {
        try passwordStore.save(answer.secret, for: hop, kind: kind)
      } catch {
        await credentialCache.store(answer.secret, for: hop, kind: kind)
      }
    } else {
      // 別の値で接続できた時点で、以前の保存値は確定的に無効になる。
      // 同じ値なら無効とは言えないため、パスワードは一致時に残す。
      let stored = try? passwordStore.secret(for: hop, kind: kind)
      if kind != .password || stored != answer.secret {
        try? passwordStore.remove(for: hop, kind: kind)
      }
      await credentialCache.store(answer.secret, for: hop, kind: kind)
    }
  }

  private func dial(
    _ settings: SSHClientSettings,
    previous: (any SSHHopTransport)?
  ) async throws -> any SSHHopTransport {
    if let previous {
      return try await previous.jump(to: settings)
    }
    return try await hopConnector(settings)
  }

  private func settings(
    for hop: SFTPHopIdentity,
    authentication: PreparedAuthentication,
    validation: SFTPHostKeyValidation
  ) -> SSHClientSettings {
    SSHClientSettings(
      host: hop.host,
      port: hop.port,
      authenticationMethod: { authentication.makeMethod() },
      hostKeyValidator: validation.validator)
  }

  static func hostKeyError(
    capturedPublicKey: String?,
    trustedPublicKey: String?,
    host: String = "",
    port: Int = 22
  ) -> SFTPConnectionServiceError? {
    guard let capturedPublicKey else { return nil }
    let request = SFTPHostKeyApprovalRequest(
      host: host,
      port: port,
      publicKey: capturedPublicKey)
    guard let trustedPublicKey else { return .hostKeyRequiresApproval(request) }
    guard capturedPublicKey != trustedPublicKey else { return nil }
    return .hostKeyChanged(request)
  }

  private func label(forHopAt index: Int, target: SFTPConnectionTarget) -> String? {
    guard index < target.jumpHosts.count else { return nil }
    return target.jumpHosts[index].label
  }

  private func close(transports: [any SSHHopTransport]) async {
    for transport in transports.reversed() {
      try? await transport.close()
    }
  }

  /// 認証経路の診断ログ(秘密情報は含めない。ホスト・ポート・ユーザー名・方式・結果のみ)。
  /// 実機で「保存パスワードが拒否される」「ダイアログが繰り返す」を切り分けるために残す。
  /// 接続がどの段階まで進んだかを追う診断ログ。秘密情報は含めない(有無の真偽値のみ)。
  private static func logConnect(_ stage: String, hop: SFTPHopIdentity) {
    AppLog.notice(
      "\(stage) host=\(hop.host) port=\(hop.port) user=\(hop.username)",
      category: "SFTPConnect")
  }

  private static func logAuthAttempt(hop: SFTPHopIdentity, method: String) {
    AppLog.notice(
      "attempt host=\(hop.host) port=\(hop.port) user=\(hop.username) method=\(method)",
      category: "SFTPAuth")
  }

  private static func logAuthResult(hop: SFTPHopIdentity, method: String, outcome: String) {
    let identity = "host=\(hop.host) port=\(hop.port) user=\(hop.username)"
    AppLog.notice("result \(identity) method=\(method) outcome=\(outcome)", category: "SFTPAuth")
  }

  private static func describe(_ error: Error) -> String {
    if let error = error as? SSHClientError {
      return "SSHClientError.\(error)"
    }
    return "\(type(of: error)).\(error)"
  }

  private static func isRetryableAuthenticationFailure(_ error: Error) -> Bool {
    guard let error = error as? SSHClientError else { return false }
    if case .allAuthenticationOptionsFailed = error { return true }
    return false
  }

  private func loadPrivateKey(at url: URL, passphrase: String?) throws -> LoadedPrivateKey {
    if usesInjectedKeyLoader {
      _ = try keyLoader(url, passphrase)
      return .ed25519(.init())
    }
    return try Self.loadPrivateKeyMaterial(from: url, passphrase: passphrase)
  }

  private static func defaultKeyLoader(
    _ url: URL,
    _ passphrase: String?
  ) throws -> NIOSSHPrivateKey {
    try loadPrivateKeyMaterial(from: url, passphrase: passphrase).nioPrivateKey
  }

  private static func loadPrivateKeyMaterial(
    from privateKeyURL: URL,
    passphrase: String?
  ) throws -> LoadedPrivateKey {
    let isAccessing = privateKeyURL.startAccessingSecurityScopedResource()
    defer {
      if isAccessing { privateKeyURL.stopAccessingSecurityScopedResource() }
    }
    let key: String
    do {
      key = try String(contentsOf: privateKeyURL, encoding: .utf8)
    } catch {
      throw SFTPConnectionServiceError.privateKeyNotFound
    }
    let decryptionKey = passphrase.flatMap { password in
      password.isEmpty ? nil : Data(password.utf8)
    }
    let keyType: SSHKeyType
    do {
      keyType = try SSHKeyDetection.detectPrivateKeyType(from: key)
    } catch {
      throw SFTPConnectionServiceError.unsupportedPrivateKey
    }

    do {
      switch keyType {
      case .ed25519:
        return .ed25519(try .init(sshEd25519: key, decryptionKey: decryptionKey))
      case .rsa:
        return .rsa(try Insecure.RSA.PrivateKey(sshRsa: key, decryptionKey: decryptionKey))
      case .ecdsaP256, .ecdsaP384, .ecdsaP521:
        return try openSSHECDSAPrivateKey(key, keyType: keyType)
      default:
        throw SFTPConnectionServiceError.unsupportedPrivateKey
      }
    } catch let error as SFTPConnectionServiceError {
      if isEncryptedOpenSSHPrivateKey(key) {
        throw PrivateKeyLoadError.passphraseRejected
      }
      throw error
    } catch {
      if isEncryptedOpenSSHPrivateKey(key) {
        throw PrivateKeyLoadError.passphraseRejected
      }
      throw SFTPConnectionServiceError.unsupportedPrivateKey
    }
  }

  private static func isEncryptedOpenSSHPrivateKey(_ key: String) -> Bool {
    let encoded =
      key
      .replacingOccurrences(of: "-----BEGIN OPENSSH PRIVATE KEY-----", with: "")  // gitleaks:allow
      .replacingOccurrences(of: "-----END OPENSSH PRIVATE KEY-----", with: "")
      .filter { !$0.isWhitespace }
    guard let decoded = Data(base64Encoded: encoded) else { return false }
    var reader = OpenSSHKeyReader(data: decoded)
    guard reader.readBytes(count: 15) == Data("openssh-key-v1\0".utf8),
      let cipher = reader.readString()
    else { return false }
    return cipher != "none"
  }

  private static func openSSHECDSAPrivateKey(
    _ key: String,
    keyType: SSHKeyType
  ) throws -> LoadedPrivateKey {
    let encoded =
      key
      .replacingOccurrences(of: "-----BEGIN OPENSSH PRIVATE KEY-----", with: "")  // gitleaks:allow
      .replacingOccurrences(of: "-----END OPENSSH PRIVATE KEY-----", with: "")
      .filter { !$0.isWhitespace }
    guard let decoded = Data(base64Encoded: encoded) else {
      throw SFTPConnectionServiceError.unsupportedPrivateKey
    }
    var reader = OpenSSHKeyReader(data: decoded)
    guard reader.readBytes(count: 15) == Data("openssh-key-v1\0".utf8),
      reader.readString() == "none",
      reader.readString() == "none",
      reader.readData() != nil,
      reader.readUInt32() == 1,
      reader.readData() != nil,
      let privateBlob = reader.readData()
    else { throw SFTPConnectionServiceError.unsupportedPrivateKey }

    var privateReader = OpenSSHKeyReader(data: privateBlob)
    guard let firstCheck = privateReader.readUInt32(),
      firstCheck == privateReader.readUInt32(),
      privateReader.readString() == keyType.rawValue,
      privateReader.readString() != nil,
      privateReader.readData() != nil,
      let scalar = privateReader.readData()
    else { throw SFTPConnectionServiceError.unsupportedPrivateKey }

    switch keyType {
    case .ecdsaP256:
      return .p256(
        try P256.Signing.PrivateKey(
          rawRepresentation: normalizedScalar(scalar, byteCount: 32)))
    case .ecdsaP384:
      return .p384(
        try P384.Signing.PrivateKey(
          rawRepresentation: normalizedScalar(scalar, byteCount: 48)))
    case .ecdsaP521:
      return .p521(
        try P521.Signing.PrivateKey(
          rawRepresentation: normalizedScalar(scalar, byteCount: 66)))
    default:
      throw SFTPConnectionServiceError.unsupportedPrivateKey
    }
  }

  private static func normalizedScalar(_ scalar: Data, byteCount: Int) throws -> Data {
    var bytes = Array(scalar)
    while bytes.count > byteCount, bytes.first == 0 { bytes.removeFirst() }
    guard bytes.count <= byteCount else {
      throw SFTPConnectionServiceError.unsupportedPrivateKey
    }
    return Data(repeating: 0, count: byteCount - bytes.count) + Data(bytes)
  }
}

private struct PreparedPrivateKey {
  var privateKey: LoadedPrivateKey?
  var failureReason: String?
  var usedLegacyPasswordSlot = false
}

private enum LoadedPrivateKey: @unchecked Sendable {
  case ed25519(Curve25519.Signing.PrivateKey)
  case rsa(Insecure.RSA.PrivateKey)
  case p256(P256.Signing.PrivateKey)
  case p384(P384.Signing.PrivateKey)
  case p521(P521.Signing.PrivateKey)

  var nioPrivateKey: NIOSSHPrivateKey {
    switch self {
    case .ed25519(let key): NIOSSHPrivateKey(ed25519Key: key)
    case .rsa(let key): NIOSSHPrivateKey(custom: key)
    case .p256(let key): NIOSSHPrivateKey(p256Key: key)
    case .p384(let key): NIOSSHPrivateKey(p384Key: key)
    case .p521(let key): NIOSSHPrivateKey(p521Key: key)
    }
  }

  func authenticationMethod(username: String) -> SSHAuthenticationMethod {
    switch self {
    case .ed25519(let key): .ed25519(username: username, privateKey: key)
    case .rsa(let key): .rsa(username: username, privateKey: key)
    case .p256(let key): .p256(username: username, privateKey: key)
    case .p384(let key): .p384(username: username, privateKey: key)
    case .p521(let key): .p521(username: username, privateKey: key)
    }
  }
}

private enum PreparedAuthentication: @unchecked Sendable {
  case password(username: String, secret: String)
  case privateKey(username: String, key: LoadedPrivateKey)

  func makeMethod() -> SSHAuthenticationMethod {
    switch self {
    case .password(let username, let secret):
      .passwordBased(username: username, password: secret)
    case .privateKey(let username, let key):
      key.authenticationMethod(username: username)
    }
  }
}

private enum PrivateKeyLoadError: LocalizedError {
  case passphraseRejected

  var errorDescription: String? {
    "秘密鍵のパスフレーズが一致しません。"
  }
}

private struct OpenSSHKeyReader {
  private let data: Data
  private var offset = 0

  init(data: Data) { self.data = data }

  mutating func readUInt32() -> UInt32? {
    guard offset + 4 <= data.count else { return nil }
    let value = data[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    offset += 4
    return value
  }

  mutating func readData() -> Data? {
    guard let length = readUInt32(), length <= UInt32(Int.max) else { return nil }
    return readBytes(count: Int(length))
  }

  mutating func readString() -> String? {
    guard let bytes = readData() else { return nil }
    return String(data: bytes, encoding: .utf8)
  }

  mutating func readBytes(count: Int) -> Data? {
    guard count >= 0, offset + count <= data.count else { return nil }
    defer { offset += count }
    return data.subdata(in: offset..<(offset + count))
  }
}
