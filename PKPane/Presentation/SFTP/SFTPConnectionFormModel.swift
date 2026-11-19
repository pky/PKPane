import Foundation
import Observation
import Synchronization

struct SFTPJumpHostDraft: Identifiable, Equatable {
  let id = UUID()
  var host = ""
  var port = "22"
  var username = ""
  var password = ""
  var privateKeyURL: URL?
  var label: String?
  var originalIdentity: SFTPHopIdentity?
}

struct SFTPJumpHostCandidate: Identifiable, Equatable {
  let identity: SFTPHopIdentity
  let title: String

  var id: SFTPHopIdentity { identity }

  init(identity: SFTPHopIdentity) {
    self.identity = identity
    title =
      identity.port == 22
      ? "\(identity.username)@\(identity.host)"
      : "\(identity.username)@\(identity.host):\(identity.port)"
  }
}

@Observable
@MainActor
final class SFTPConnectionFormModel {
  private let passwordStore: SFTPPasswordStore
  private let profileStore: SFTPConnectionProfileStore
  private let privateKeyRepository: any SFTPPrivateKeyBookmarkPersisting
  private let connectionService: any SFTPConnecting
  private let sshConfigReader: SSHConfigReader?
  private let presentFolderPicker: () -> URL?
  private let existingTarget: SFTPConnectionTarget?
  private let restoredFinalPrivateKeyURL: URL?
  private var restoredJumpPrivateKeyURLs: [UUID: URL] = [:]
  private var importedSSHFolderURL: URL?
  let credentialPrompter: SFTPCredentialPromptCoordinator

  var host = ""
  var port = "22"
  var username = ""
  var password = ""
  var startDirectory = ""
  var privateKeyURL: URL?
  var jumpHosts: [SFTPJumpHostDraft] = []
  var sshConfigPicker: SSHConfigHostPickerModel?
  private(set) var importWarnings: [SSHConfigWarning] = []
  private(set) var errorMessage: String?
  private(set) var testResultMessage: String?
  private(set) var isTestingConnection = false
  private var testConnectionTask: Task<Void, Never>?

  init(
    target: SFTPConnectionTarget? = nil,
    passwordStore: SFTPPasswordStore? = nil,
    profileStore: SFTPConnectionProfileStore = SFTPConnectionProfileStore(),
    privateKeyRepository: any SFTPPrivateKeyBookmarkPersisting = SFTPPrivateKeyBookmarkRepository(),
    connectionService: (any SFTPConnecting)? = nil,
    sshConfigReader: SSHConfigReader? = nil,
    presentFolderPicker: @escaping () -> URL? = { nil }
  ) {
    self.passwordStore = passwordStore ?? Self.defaultPasswordStore()
    self.profileStore = profileStore
    self.privateKeyRepository = privateKeyRepository
    self.sshConfigReader = sshConfigReader
    self.presentFolderPicker = presentFolderPicker
    let credentialPrompter = SFTPCredentialPromptCoordinator()
    self.credentialPrompter = credentialPrompter
    self.connectionService =
      connectionService
      ?? CitadelSFTPConnectionService(credentialPrompter: credentialPrompter)
    existingTarget = target
    host = target?.host ?? ""
    port = target.map { String($0.port) } ?? "22"
    username = target?.username ?? ""
    startDirectory = target?.initialDirectory == "." ? "" : target?.initialDirectory ?? ""
    let restoredFinalPrivateKeyURL = try? target.flatMap {
      try privateKeyRepository.restore(for: $0)
    }
    self.restoredFinalPrivateKeyURL = restoredFinalPrivateKeyURL
    privateKeyURL = restoredFinalPrivateKeyURL
    jumpHosts = (target?.jumpHosts ?? []).map { hop in
      let restoredURL = try? privateKeyRepository.restore(for: hop.identity)
      let draft = SFTPJumpHostDraft(
        host: hop.host, port: String(hop.port), username: hop.username,
        privateKeyURL: restoredURL, label: hop.label, originalIdentity: hop.identity)
      if let restoredURL {
        restoredJumpPrivateKeyURLs[draft.id] = restoredURL
      }
      return draft
    }
  }

  func addJumpHost() {
    jumpHosts.append(SFTPJumpHostDraft())
  }

  func removeJumpHost(id: UUID) {
    jumpHosts.removeAll { $0.id == id }
  }

  func registeredJumpHostCandidates(excluding draftID: UUID) -> [SFTPJumpHostCandidate] {
    var excludedIdentities = Set(
      jumpHosts.compactMap { draft -> SFTPHopIdentity? in
        guard draft.id != draftID else { return nil }
        return Self.identity(host: draft.host, port: draft.port, username: draft.username)
      })
    if let existingTarget {
      excludedIdentities.insert(existingTarget.finalHop)
    }
    if let currentIdentity = Self.identity(host: host, port: port, username: username) {
      excludedIdentities.insert(currentIdentity)
    }
    return profileStore.loadAll().compactMap { target in
      let identity = target.finalHop
      guard !excludedIdentities.contains(identity) else { return nil }
      return SFTPJumpHostCandidate(identity: identity)
    }
  }

  func applyRegisteredJumpHost(_ candidate: SFTPJumpHostCandidate, to draftID: UUID) {
    guard let index = jumpHosts.firstIndex(where: { $0.id == draftID }) else { return }
    jumpHosts[index].host = candidate.identity.host
    jumpHosts[index].port = String(candidate.identity.port)
    jumpHosts[index].username = candidate.identity.username
    jumpHosts[index].password = ""
    jumpHosts[index].privateKeyURL = try? privateKeyRepository.restore(for: candidate.identity)
    jumpHosts[index].label = nil
    jumpHosts[index].originalIdentity = nil
    restoredJumpPrivateKeyURLs.removeValue(forKey: draftID)
  }

  private static func identity(host: String, port: String, username: String) -> SFTPHopIdentity? {
    let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
    let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !host.isEmpty, !username.isEmpty, let port = Int(port) else { return nil }
    return SFTPHopIdentity(host: host, port: port, username: username)
  }

  func beginSSHConfigImport() {
    guard let sshConfigReader else { return }
    if sshConfigReader.accessState() == .unavailable {
      guard let folderURL = presentFolderPicker() else {
        errorMessage = SSHConfigReaderError.accessRequired.errorDescription
        return
      }
      do {
        try sshConfigReader.saveDirectoryAccess(folderURL)
      } catch {
        errorMessage = PKPaneErrorClassifier.classify(error).displayMessage
        return
      }
    }

    do {
      let loaded = try sshConfigReader.loadDocument()
      sshConfigPicker = SSHConfigHostPickerModel(
        document: loaded.document, folderURL: loaded.folderURL, initialQuery: host)
      errorMessage = nil
    } catch {
      errorMessage = PKPaneErrorClassifier.classify(error).displayMessage
    }
  }

  func applyImport(_ result: SSHConfigImportResult, folderURL: URL) {
    let previousFinalPrivateKeyURL = privateKeyURL
    let previousJumpHosts = jumpHosts
    var warnings = result.warnings
    host = result.final.hostName
    port = String(result.final.port)
    username = result.final.username
    password = ""
    privateKeyURL = importedPrivateKeyURL(
      from: result.final.identityFiles.first, within: folderURL,
      fallback: previousFinalPrivateKeyURL, warnings: &warnings)
    jumpHosts = result.jumpHops.map { hop in
      let identity = SFTPHopIdentity(host: hop.hostName, port: hop.port, username: hop.username)
      let previousKey = previousJumpHosts.first { draft in
        if draft.originalIdentity == identity { return true }
        return draft.host == hop.hostName && Int(draft.port) == hop.port
          && draft.username == hop.username
      }?.privateKeyURL
      return SFTPJumpHostDraft(
        host: hop.hostName,
        port: String(hop.port),
        username: hop.username,
        password: "",
        privateKeyURL: importedPrivateKeyURL(
          from: hop.identityFiles.first, within: folderURL, fallback: previousKey,
          warnings: &warnings),
        label: nil,
        originalIdentity: nil)
    }
    importedSSHFolderURL = folderURL.standardizedFileURL
    importWarnings = warnings
    errorMessage = nil
    testResultMessage = nil
  }

  isolated deinit {
    testConnectionTask?.cancel()
  }

  private static func defaultPasswordStore() -> SFTPPasswordStore {
    guard ProcessInfo.processInfo.environment["PKPANE_UI_TESTING"] == "1" else {
      return SFTPPasswordStore()
    }
    return SFTPPasswordStore(keychain: UITestKeychainPasswordDataStore())
  }

  @discardableResult
  func savePassword() -> SFTPConnectionTarget? {
    do {
      guard let port = Int(port) else {
        throw SFTPConnectionTargetError.invalidPort
      }
      let hops = try jumpHosts.map { draft in
        guard let port = Int(draft.port) else { throw SFTPConnectionTargetError.invalidPort }
        return try SFTPJumpHost(
          host: draft.host, port: port, username: draft.username, label: draft.label)
      }
      let target = try SFTPConnectionTarget(
        host: host,
        port: port,
        username: username,
        initialDirectory: startDirectory,
        jumpHosts: hops)
      guard !password.isEmpty || privateKeyURL != nil || existingTarget != nil else {
        throw SFTPConnectionFormError.authenticationRequired
      }
      for (draft, hop) in zip(jumpHosts, hops) {
        let existingHop = draft.originalIdentity
        if !draft.password.isEmpty {
          try passwordStore.save(draft.password, for: hop.identity, kind: .password)
        } else if let existingHop,
          existingHop.host == hop.host,
          existingHop.port == hop.port,
          existingHop.username != hop.username,
          try passwordStore.secret(for: hop.identity, kind: .password) == nil,
          let existingPassword = try passwordStore.secret(for: existingHop, kind: .password)
        {
          try passwordStore.save(existingPassword, for: hop.identity, kind: .password)
        }
        if let privateKeyURL = draft.privateKeyURL {
          try savePrivateKey(privateKeyURL, for: hop.identity)
        } else if restoredJumpPrivateKeyURLs[draft.id] != nil,
          let existingHop
        {
          privateKeyRepository.remove(for: existingHop)
        }
      }
      if let privateKeyURL {
        try savePrivateKey(privateKeyURL, for: target)
      } else if restoredFinalPrivateKeyURL != nil, let existingTarget {
        privateKeyRepository.remove(for: existingTarget)
      }
      if !password.isEmpty {
        try passwordStore.save(password, for: target)
      } else if let existingTarget,
        existingTarget != target,
        let existingPassword = try passwordStore.password(for: existingTarget)
      {
        try passwordStore.save(existingPassword, for: target)
      }
      if let existingTarget {
        profileStore.replace(existingTarget, with: target)
      } else {
        profileStore.save(target)
      }
      password = ""
      for index in jumpHosts.indices { jumpHosts[index].password = "" }
      errorMessage = nil
      testResultMessage = nil
      return target
    } catch {
      errorMessage = PKPaneErrorClassifier.classify(error).displayMessage
      return nil
    }
  }

  private func importedPrivateKeyURL(
    from path: String?, within folderURL: URL, fallback: URL?,
    warnings: inout [SSHConfigWarning]
  ) -> URL? {
    guard let path else { return fallback }
    guard let normalized = sshConfigReader?.normalizedKeyFileURL(path, within: folderURL) else {
      warnings.append(.identityFileOutsideAccessibleFolder(path: path))
      return fallback
    }
    return normalized
  }

  private func savePrivateKey(_ url: URL, for hop: SFTPHopIdentity) throws {
    try withImportedDirectoryAccess(for: url) {
      try privateKeyRepository.save(url, for: hop)
    }
  }

  private func savePrivateKey(_ url: URL, for target: SFTPConnectionTarget) throws {
    try withImportedDirectoryAccess(for: url) {
      try privateKeyRepository.save(url, for: target)
    }
  }

  private func withImportedDirectoryAccess(for keyURL: URL, _ body: () throws -> Void) throws {
    guard let importedSSHFolderURL, let sshConfigReader,
      Self.contains(keyURL.standardizedFileURL, in: importedSSHFolderURL)
    else {
      try body()
      return
    }
    try sshConfigReader.withDirectoryAccess(body)
  }

  private static func contains(_ candidate: URL, in folder: URL) -> Bool {
    let folderComponents = folder.standardizedFileURL.pathComponents
    let candidateComponents = candidate.standardizedFileURL.pathComponents
    return candidateComponents.count >= folderComponents.count
      && Array(candidateComponents.prefix(folderComponents.count)) == folderComponents
  }

  /// 各ホップの接続時間を集め、踏み台なしの場合は既存の応答時間表示を維持する。
  func testConnection() {
    guard !isTestingConnection, let target = savePassword() else { return }
    isTestingConnection = true
    testResultMessage = nil
    let start = ContinuousClock.now
    testConnectionTask = Task { [weak self] in
      guard let self else { return }
      do {
        let hops = Mutex<[(name: String, elapsed: Duration)]>([])
        let session = try await connectionService.connect(
          to: target, intent: .userInitiated,
          hopProgress: { hop, elapsed in
            hops.withLock { $0.append((hop.host, elapsed)) }
          })
        try await session.close()
        if Task.isCancelled { return }
        let elapsed = ContinuousClock.now - start
        errorMessage = nil
        let timings = hops.withLock { $0 }
        testResultMessage = ConnectionTestResultFormatter.hopSuccessMessage(
          timings.isEmpty ? [(target.host, elapsed)] : timings)
      } catch {
        if Task.isCancelled { return }
        errorMessage = ConnectionErrorClassifier.guidanceMessage(for: error)
        testResultMessage = nil
      }
      isTestingConnection = false
    }
  }
}

enum SFTPConnectionFormError: LocalizedError {
  case authenticationRequired

  var errorDescription: String? {
    switch self {
    case .authenticationRequired:
      "パスワードまたは秘密鍵を指定してください。"
    }
  }
}

private final class UITestKeychainPasswordDataStore: KeychainPasswordDataStoring {
  private var passwords: [String: String] = [:]

  func save(password: String, service: String, account: String) throws {
    passwords["\(service):\(account)"] = password
  }

  func password(service: String, account: String) throws -> String? {
    passwords["\(service):\(account)"]
  }
}
