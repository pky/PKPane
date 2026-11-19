import Foundation
import Observation

@Observable
@MainActor
final class FTPConnectionFormModel {
  private let passwordStore: FTPPasswordStore
  private let profileStore: FTPConnectionProfileStore
  private let connectionService: any FTPConnecting
  private let existingTarget: FTPConnectionTarget?

  var host = ""
  var port = "21"
  var username = ""
  var password = ""
  var startDirectory = "/"
  var security: FTPConnectionSecurity = .explicitTLS
  private(set) var errorMessage: String?
  private(set) var testResultMessage: String?
  private(set) var isTestingConnection = false
  private var testConnectionTask: Task<Void, Never>?

  init(
    target: FTPConnectionTarget? = nil,
    passwordStore: FTPPasswordStore? = nil,
    profileStore: FTPConnectionProfileStore = FTPConnectionProfileStore(),
    connectionService: any FTPConnecting = FTPConnectionService()
  ) {
    self.passwordStore = passwordStore ?? Self.defaultPasswordStore()
    self.profileStore = profileStore
    self.connectionService = connectionService
    existingTarget = target
    host = target?.host ?? ""
    port = target.map { String($0.port) } ?? "21"
    username = target?.username ?? ""
    startDirectory = target?.initialDirectory ?? "/"
    security = target?.security ?? .explicitTLS
  }

  isolated deinit {
    testConnectionTask?.cancel()
  }

  private static func defaultPasswordStore() -> FTPPasswordStore {
    guard ProcessInfo.processInfo.environment["PKPANE_UI_TESTING"] == "1" else {
      return FTPPasswordStore()
    }
    return FTPPasswordStore(keychain: FTPUITestKeychainPasswordDataStore())
  }

  @discardableResult
  func savePassword() -> FTPConnectionTarget? {
    do {
      guard let port = Int(port) else { throw FTPConnectionTargetError.invalidPort }
      let target = try FTPConnectionTarget(
        host: host,
        port: port,
        username: username,
        initialDirectory: startDirectory,
        security: security)
      guard !password.isEmpty || existingTarget != nil else {
        throw FTPConnectionFormError.passwordRequired
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
      errorMessage = nil
      testResultMessage = nil
      return target
    } catch {
      errorMessage = PKPaneErrorClassifier.classify(error).displayMessage
      return nil
    }
  }

  func testConnection() {
    guard !isTestingConnection, let target = savePassword() else { return }
    isTestingConnection = true
    testResultMessage = nil
    let start = ContinuousClock.now
    testConnectionTask = Task { [weak self] in
      guard let self else { return }
      do {
        let session = try await connectionService.connect(to: target)
        await session.close()
        if Task.isCancelled { return }
        errorMessage = nil
        testResultMessage = ConnectionTestResultFormatter.successMessage(
          elapsed: ContinuousClock.now - start)
      } catch {
        if Task.isCancelled { return }
        errorMessage = ConnectionErrorClassifier.guidanceMessage(for: error)
        testResultMessage = nil
      }
      isTestingConnection = false
    }
  }
}

private final class FTPUITestKeychainPasswordDataStore: KeychainPasswordDataStoring {
  private var passwords: [String: String] = [:]

  func save(password: String, service: String, account: String) throws {
    passwords["\(service):\(account)"] = password
  }

  func password(service: String, account: String) throws -> String? {
    passwords["\(service):\(account)"]
  }
}

enum FTPConnectionFormError: LocalizedError, Equatable {
  case passwordRequired

  var errorDescription: String? {
    "パスワードを指定してください。"
  }
}
