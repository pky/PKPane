import Foundation
import Testing

@testable import PKPane

@MainActor
struct FTPConnectionListModelTests {
  @Test("接続中の同じ接続先は一度だけ開始する")
  func preventsDuplicateConnectionAttempts() async throws {
    let target = try FTPConnectionTarget(host: "ftp.example.com", username: "tester")
    let connector = ControlledFTPConnector()
    let (profileStore, defaults, suiteName) = isolatedProfileStore()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let model = FTPConnectionListModel(
      profileStore: profileStore,
      connectionService: connector)

    model.connect(target)
    model.connect(target)
    await waitUntil("FTP接続が期限内に開始されなかった") {
      await connector.connectionCount == 1
    }

    #expect(model.isConnecting(target))
    await connector.completeConnection()
    await waitUntil("FTP接続が期限内に完了しなかった") {
      !model.isConnecting(target)
    }

    #expect(model.isConnected(target))
    #expect(model.provider(for: target) != nil)
  }

  @Test("切断時に対応するファイル提供元の接続終了を通知する")
  func publishesProviderDisconnection() async throws {
    let target = try FTPConnectionTarget(host: "ftp.example.com", username: "tester")
    let connector = ControlledFTPConnector()
    let lifecycle = FileProviderConnectionLifecycle()
    let (profileStore, defaults, suiteName) = isolatedProfileStore()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let model = FTPConnectionListModel(
      profileStore: profileStore,
      connectionService: connector,
      connectionLifecycle: lifecycle)

    model.connect(target)
    await waitUntil("FTP接続が期限内に開始されなかった") {
      await connector.connectionCount == 1
    }
    await connector.completeConnection()
    await waitUntil("FTP接続が期限内に完了しなかった") {
      model.isConnected(target)
    }

    model.disconnect(target)

    #expect(
      lifecycle.latestDisconnection?.connectionID
        == FTPFileProvider.connectionID(for: target))
    #expect(!model.isConnected(target))
  }

  private func isolatedProfileStore() -> (
    FTPConnectionProfileStore, UserDefaults, String
  ) {
    let suiteName = "FTPConnectionListModelTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    return (FTPConnectionProfileStore(defaults: defaults), defaults, suiteName)
  }
}

private actor ControlledFTPConnector: FTPConnecting {
  private var continuations: [CheckedContinuation<any FTPClientSession, Error>] = []
  private(set) var connectionCount = 0

  func connect(to _: FTPConnectionTarget) async throws -> any FTPClientSession {
    connectionCount += 1
    return try await withCheckedThrowingContinuation { continuation in
      continuations.append(continuation)
    }
  }

  func completeConnection() {
    guard !continuations.isEmpty else {
      Issue.record("FTP接続要求が届く前に完了操作が呼ばれました")
      return
    }
    continuations.removeFirst().resume(returning: FTPListEmptySession())
  }
}

private struct FTPListEmptySession: FTPClientSession {
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
  func isActive() async -> Bool { true }
  func close() async {}
}
