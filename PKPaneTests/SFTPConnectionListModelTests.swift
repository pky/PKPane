import Foundation
import Testing

@testable import PKPane

@MainActor
struct SFTPConnectionListModelTests {
  @Test("接続中の同じ接続先は一度だけ開始する")
  func preventsDuplicateConnectionAttempts() async throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let connector = ControlledSFTPConnector()
    let (defaults, defaultsSuiteName) = isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
    let model = SFTPConnectionListModel(
      profileStore: SFTPConnectionProfileStore(defaults: defaults),
      connectionService: connector)

    model.connect(target)
    model.connect(target)
    await waitForConnectionStart(connector)

    #expect(await connector.connectionCount() == 1)
    #expect(model.isConnecting(target))

    await connector.completeConnection()
    await waitForConnectionCompletion(model, target: target)

    #expect(model.isConnected(target))
    #expect(!model.isConnecting(target))
  }

  @Test("接続失敗した接続先を接続済みにしない")
  func doesNotMarkFailedConnectionAsConnected() async throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let connector = FailingSFTPConnector()
    let (defaults, defaultsSuiteName) = isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
    let model = SFTPConnectionListModel(
      profileStore: SFTPConnectionProfileStore(defaults: defaults),
      connectionService: connector)

    model.connect(target)
    await waitForConnectionCompletion(model, target: target)

    #expect(!model.isConnected(target))
    #expect(!model.isConnecting(target))
    #expect(
      model.errorMessage
        == ConnectionErrorClassifier.guidanceMessage(for: FailingSFTPConnectionError.failed))
  }

  @Test("未知のホスト鍵は明示承認後にだけ接続を再試行する")
  func requiresExplicitHostKeyApproval() async throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleHostKey"
    let connector = HostKeyApprovalSFTPConnector(publicKey: publicKey)
    let (defaults, defaultsSuiteName) = isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
    let trustStore = SFTPHostKeyTrustStore(defaults: defaults)
    let model = SFTPConnectionListModel(
      profileStore: SFTPConnectionProfileStore(defaults: defaults),
      connectionService: connector,
      hostKeyTrustStore: trustStore)
    var didOpenBrowser = false

    model.connect(target) { _ in
      didOpenBrowser = true
    }
    await waitForConnectionCompletion(model, target: target)

    #expect(model.pendingHostKey(for: target) == publicKey)
    let initialConnectionCount = await connector.connectionCount()
    #expect(initialConnectionCount == 1)

    model.approveHostKey(for: target)
    await waitForConnectionCompletion(model, target: target)

    #expect(trustStore.trustedOpenSSHPublicKey(for: target) == publicKey)
    #expect(model.isConnected(target))
    #expect(didOpenBrowser)
    let approvedConnectionCount = await connector.connectionCount()
    #expect(approvedConnectionCount == 2)
  }

  @Test("踏み台のホスト鍵を承認すると踏み台の接続先へ保存して再接続する")
  func hostKeyApprovalForJumpHopTrustsThatHop() async throws {
    let jumpHost = try SFTPJumpHost(
      host: "gateway", port: 2222, username: "ops", label: "踏み台")
    let target = try SFTPConnectionTarget(
      host: "files.example",
      port: 22,
      username: "tester",
      jumpHosts: [jumpHost])
    let publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIRelayHostKey"
    let request = SFTPHostKeyApprovalRequest(
      host: jumpHost.host,
      port: jumpHost.port,
      publicKey: publicKey)
    let connector = HostKeyApprovalSFTPConnector(request: request)
    let (defaults, defaultsSuiteName) = isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
    let trustStore = SFTPHostKeyTrustStore(defaults: defaults)
    let model = SFTPConnectionListModel(
      profileStore: SFTPConnectionProfileStore(defaults: defaults),
      connectionService: connector,
      hostKeyTrustStore: trustStore)
    var receivedRequest: SFTPHostKeyApprovalRequest?

    model.connect(
      target,
      onHostKeyApproval: { _, approvalRequest, isUpdate in
        receivedRequest = approvalRequest
        #expect(!isUpdate)
      })
    await waitForConnectionCompletion(model, target: target)

    #expect(receivedRequest?.host == "gateway")
    #expect(receivedRequest?.port == 2222)
    #expect(trustStore.trustedOpenSSHPublicKey(host: "gateway", port: 2222) == nil)

    model.approveHostKey(for: target)
    await waitForConnectionCompletion(model, target: target)

    #expect(
      trustStore.trustedOpenSSHPublicKey(host: "gateway", port: 2222)
        == publicKey)
    #expect(model.isConnected(target))
    #expect(await connector.connectionCount() == 2)
  }

  @Test("変更済みホスト鍵は明示更新後にだけ接続を再試行する")
  func requiresExplicitHostKeyUpdate() async throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIChangedHostKey"
    let connector = ChangedHostKeySFTPConnector(publicKey: publicKey)
    let (defaults, defaultsSuiteName) = isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
    let trustStore = SFTPHostKeyTrustStore(defaults: defaults)
    trustStore.trust(openSSHPublicKey: "ssh-ed25519 old-key", for: target)
    let model = SFTPConnectionListModel(
      profileStore: SFTPConnectionProfileStore(defaults: defaults),
      connectionService: connector,
      hostKeyTrustStore: trustStore)

    model.connect(target)
    await waitForConnectionCompletion(model, target: target)

    #expect(model.changedHostKey(for: target) == publicKey)
    #expect(!model.isConnected(target))
    #expect(trustStore.trustedOpenSSHPublicKey(for: target) != publicKey)

    model.approveChangedHostKey(for: target)
    await waitForConnectionCompletion(model, target: target)

    #expect(model.isConnected(target))
    #expect(trustStore.trustedOpenSSHPublicKey(for: target) == publicKey)
  }

  @Test("切断時に対応するファイル提供元の接続終了を通知する")
  func publishesProviderDisconnection() async throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let connector = ControlledSFTPConnector()
    let lifecycle = FileProviderConnectionLifecycle()
    let (defaults, defaultsSuiteName) = isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
    let model = SFTPConnectionListModel(
      profileStore: SFTPConnectionProfileStore(defaults: defaults),
      connectionService: connector,
      connectionLifecycle: lifecycle)

    model.connect(target)
    await waitForConnectionStart(connector)
    await connector.completeConnection()
    await waitForConnectionCompletion(model, target: target)

    model.disconnect(target)

    #expect(
      lifecycle.latestDisconnection?.connectionID
        == SFTPFileProvider.connectionID(for: target))
  }

  @Test("ホーム解決中に切断した接続は完了後も再登録しない")
  func connectIgnoresHomeResolutionWhenDisconnectedMeanwhile() async throws {
    let target = try SFTPConnectionTarget(host: "example.com", port: 22, username: "tester")
    let session = SuspendedRealPathSFTPClientSession()
    let connector = ImmediateSFTPConnector(session: session)
    let (defaults, defaultsSuiteName) = isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
    let model = SFTPConnectionListModel(
      profileStore: SFTPConnectionProfileStore(defaults: defaults),
      connectionService: connector)
    var didConnect = false

    model.connect(target) { _ in
      didConnect = true
    }
    await waitUntil("ホーム解決が期限内に開始されなかった") {
      await session.hasPendingRealPathRequest()
    }

    model.disconnect(target)
    await session.resolveRealPath(with: "/home/tester")
    await waitForConnectionCompletion(model, target: target)

    #expect(model.provider(for: target) == nil)
    #expect(!didConnect)
  }

  private func isolatedDefaults() -> (defaults: UserDefaults, suiteName: String) {
    let suiteName = "SFTPConnectionListModelTests-\(UUID().uuidString)"
    return (UserDefaults(suiteName: suiteName)!, suiteName)
  }

  private func waitForConnectionStart(_ connector: ControlledSFTPConnector) async {
    await waitUntil("接続数が期限内に1件にならなかった") {
      await connector.connectionCount() == 1
    }
  }

  private func waitForConnectionCompletion(
    _ model: SFTPConnectionListModel,
    target: SFTPConnectionTarget
  ) async {
    await waitUntil("接続完了が期限内に検出できなかった") {
      !model.isConnecting(target)
    }
  }
}

private actor ControlledSFTPConnector: SFTPConnecting {
  private var continuations: [CheckedContinuation<any SFTPClientSession, Error>] = []
  private var count = 0

  func connect(to _: SFTPConnectionTarget) async throws -> any SFTPClientSession {
    count += 1
    return try await withCheckedThrowingContinuation { continuation in
      continuations.append(continuation)
    }
  }

  func connectionCount() -> Int {
    count
  }

  func completeConnection() {
    guard !continuations.isEmpty else {
      Issue.record("接続要求が届く前にcompleteConnectionが呼ばれました。待機の期限切れを疑うこと")
      return
    }
    continuations.removeFirst().resume(returning: EmptySFTPClientSession())
  }
}

private struct ImmediateSFTPConnector: SFTPConnecting {
  let session: SuspendedRealPathSFTPClientSession

  func connect(to _: SFTPConnectionTarget) async throws -> any SFTPClientSession {
    session
  }
}

private actor SuspendedRealPathSFTPClientSession: SFTPClientSession {
  private var realPathContinuation: CheckedContinuation<String, Error>?

  func realPath(of _: String) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      realPathContinuation = continuation
    }
  }

  func hasPendingRealPathRequest() -> Bool {
    realPathContinuation != nil
  }

  func resolveRealPath(with path: String) {
    realPathContinuation?.resume(returning: path)
    realPathContinuation = nil
  }

  func contents(of _: String) async throws -> [SFTPDirectoryEntry] {
    []
  }

  func createDirectory(at _: String) async throws {}

  func remove(at _: String, isDirectory _: Bool) async throws {}

  func rename(at _: String, to _: String) async throws {}

  func close() async throws {}
}

private struct FailingSFTPConnector: SFTPConnecting {
  func connect(to _: SFTPConnectionTarget) async throws -> any SFTPClientSession {
    throw FailingSFTPConnectionError.failed
  }
}

private actor HostKeyApprovalSFTPConnector: SFTPConnecting {
  private let request: SFTPHostKeyApprovalRequest
  private var count = 0

  init(publicKey: String) {
    request = SFTPHostKeyApprovalRequest(host: "", port: 22, publicKey: publicKey)
  }

  init(request: SFTPHostKeyApprovalRequest) {
    self.request = request
  }

  func connect(to _: SFTPConnectionTarget) async throws -> any SFTPClientSession {
    count += 1
    if count == 1 {
      throw SFTPConnectionServiceError.hostKeyRequiresApproval(request)
    }
    return EmptySFTPClientSession()
  }

  func connectionCount() -> Int {
    count
  }
}

private actor ChangedHostKeySFTPConnector: SFTPConnecting {
  private let publicKey: String
  private var count = 0

  init(publicKey: String) {
    self.publicKey = publicKey
  }

  func connect(to _: SFTPConnectionTarget) async throws -> any SFTPClientSession {
    count += 1
    if count == 1 {
      throw SFTPConnectionServiceError.hostKeyChanged(publicKey)
    }
    return EmptySFTPClientSession()
  }
}

private enum FailingSFTPConnectionError: LocalizedError {
  case failed

  var errorDescription: String? {
    "接続に失敗しました。"
  }
}

private struct EmptySFTPClientSession: SFTPClientSession {
  func contents(of _: String) async throws -> [SFTPDirectoryEntry] {
    []
  }

  func createDirectory(at _: String) async throws {}

  func remove(at _: String, isDirectory _: Bool) async throws {}

  func rename(at _: String, to _: String) async throws {}

  func close() async throws {}
}
