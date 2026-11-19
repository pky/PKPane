import Foundation
import Testing

@testable import PKPane

#if PKPANE_LIVE_FTP_TESTS
  private let liveFTPTestsEnabled = true
#else
  private let liveFTPTestsEnabled = false
#endif

private let writableLiveFTPConfiguration = LiveFTPWriteServerConfiguration.fromEnvironment()

struct FTPLiveServerTests {
  @Test(
    "Rebex実サーバーでFTPの一覧とダウンロードを確認する",
    .enabled(if: liveFTPTestsEnabled, "--ftp-live-testでだけ外部サーバーへ接続する"))
  func readsFromRebexFTP() async throws {
    try await verifyRebex(security: .plain)
  }

  @Test(
    "Rebex実サーバーで明示的FTPSの一覧とダウンロードを確認する",
    .enabled(if: liveFTPTestsEnabled, "--ftp-live-testでだけ外部サーバーへ接続する"))
  func readsFromRebexExplicitFTPS() async throws {
    try await verifyRebex(security: .explicitTLS)
  }

  @Test(
    "Rebex実サーバーへ切断後に再接続できる",
    .enabled(if: liveFTPTestsEnabled, "--ftp-live-testでだけ外部サーバーへ接続する"))
  func reconnectsToRebexFTP() async throws {
    for _ in 0..<2 {
      let entries = try await withSession(
        host: "test.rebex.net",
        username: "demo",
        password: "password",
        security: .plain
      ) { session in
        try await session.contents(of: "/")
      }
      #expect(entries.contains { $0.name == "pub" && $0.isDirectory })
    }
  }

  @Test(
    "Rebex実サーバーでFTPS証明書のホスト名不一致を拒否する",
    .enabled(if: liveFTPTestsEnabled, "--ftp-live-testでだけ外部サーバーへ接続する"))
  func rejectsMismatchedFTPSHostname() async throws {
    let transport = try await NIOFTPControlTransportConnector().connect(
      host: "test.rebex.net",
      port: 21,
      timeout: .seconds(20))
    do {
      let greeting = try await readReply(from: transport)
      #expect(greeting.code == 220)
      try await transport.writeLine("AUTH TLS")
      let authReply = try await readReply(from: transport)
      #expect(authReply.code == 234)
      await #expect(throws: FTPTransportError.tlsHostnameValidationFailed) {
        try await transport.upgradeToTLS(
          serverHostname: "invalid.example",
          timeout: .seconds(20))
      }
      await transport.close()
    } catch {
      await transport.close()
      throw error
    }
  }

  private func readReply(from transport: any FTPControlTransport) async throws -> FTPReply {
    var parser = FTPReplyParser()
    while true {
      let line = try await transport.readLine(timeout: .seconds(20))
      if let reply = try parser.append(line: line) {
        return reply
      }
    }
  }

  @Test(
    "Brown CS実サーバーで匿名FTP一覧を確認する",
    .enabled(if: liveFTPTestsEnabled, "--ftp-live-testでだけ外部サーバーへ接続する"))
  func listsBrownAnonymousFTP() async throws {
    let entries = try await withSession(
      host: "ftp.cs.brown.edu",
      username: "anonymous",
      password: "pkpane@example.com",
      security: .plain
    ) { session in
      try await session.contents(of: "/")
    }

    #expect(entries.contains { $0.name == "pub" && $0.isDirectory })
  }

  @Test(
    "指定した書込可能FTP実サーバーで安全確定と再帰削除を確認する",
    .enabled(
      if: liveFTPTestsEnabled && writableLiveFTPConfiguration != nil,
      "PKPANE_LIVE_FTP_HOST等を指定した--ftp-live-testでだけ書き込みを行う"))
  func roundTripsWritableFTPServer() async throws {
    guard let configuration = writableLiveFTPConfiguration else { return }
    let target = try FTPConnectionTarget(
      host: configuration.host,
      port: configuration.port,
      username: configuration.username,
      security: configuration.security)
    let service = FTPConnectionService(
      passwordStore: FTPPasswordStore(
        keychain: LiveFTPPasswordStore(password: configuration.password)),
      timeout: .seconds(20))
    let session = try await service.connect(to: target)
    let provider = FTPFileProvider(
      target: target,
      session: session,
      sessionFactory: { try await service.connect(to: target) })
    // 多くのFTPサーバーは標準設定でドット始まりの項目を一覧から除外する。
    let testDirectoryName = "pkpane-live-\(UUID().uuidString)"
    let testDirectory = childPath(named: testDirectoryName, in: configuration.directory)
    let nestedDirectory = childPath(named: "空フォルダ", in: testDirectory)
    let temporaryFile = childPath(named: ".転送中.tmp", in: testDirectory)
    let replacementTemporaryFile = childPath(named: ".置換転送中.tmp", in: testDirectory)
    let destinationFile = childPath(named: "日本語.txt", in: testDirectory)
    let nestedFile = childPath(named: "内容.txt", in: nestedDirectory)
    let payload = Data("FTP/FTPS書き込み往復".utf8)
    let replacementPayload = Data("FTP/FTPS同名置換".utf8)

    do {
      try await session.createDirectory(at: testDirectory)
      try await session.createDirectory(at: nestedDirectory)
      try await session.writeFileContents(
        to: temporaryFile,
        chunks: dataStream(payload),
        progress: { _ in })
      #expect(try await session.fileSize(at: temporaryFile) == Int64(payload.count))

      try await provider.commitTransferFile(
        from: FileLocation(remotePath: temporaryFile, providerID: provider.id),
        to: FileLocation(remotePath: destinationFile, providerID: provider.id),
        replacingExisting: false)
      try await session.writeFileContents(
        to: replacementTemporaryFile,
        chunks: dataStream(replacementPayload),
        progress: { _ in })
      do {
        try await provider.commitTransferFile(
          from: FileLocation(remotePath: replacementTemporaryFile, providerID: provider.id),
          to: FileLocation(remotePath: destinationFile, providerID: provider.id),
          replacingExisting: false)
        Issue.record("同名ファイルへの安全確定が上書きを拒否しませんでした")
      } catch let error as CocoaError {
        #expect(error.code == .fileWriteFileExists)
      } catch {
        Issue.record("同名ファイルへの安全確定が予期しないエラーになりました: \(error)")
      }
      #expect(try await readData(from: destinationFile, using: session) == payload)
      #expect(
        try await session.fileSize(at: replacementTemporaryFile)
          == Int64(replacementPayload.count))

      try await provider.commitTransferFile(
        from: FileLocation(remotePath: replacementTemporaryFile, providerID: provider.id),
        to: FileLocation(remotePath: destinationFile, providerID: provider.id),
        replacingExisting: true)
      try await session.writeFileContents(
        to: nestedFile,
        chunks: dataStream(Data("nested".utf8)),
        progress: { _ in })

      #expect(try await readData(from: destinationFile, using: session) == replacementPayload)
      #expect(try await session.contents(of: testDirectory).contains { $0.name == "日本語.txt" })

      let rootLocation = FileLocation(
        remotePath: configuration.directory,
        providerID: provider.id)
      let createdItem = try #require(
        try await provider.contents(of: rootLocation).first {
          $0.name == testDirectoryName
        }
      )
      try await provider.permanentlyDelete(createdItem)
      #expect(
        try await provider.contents(of: rootLocation).allSatisfy {
          $0.name != testDirectoryName
        })
      await session.close()
      try await verifyUploadCancellation(
        target: target,
        service: service,
        directory: configuration.directory)
    } catch {
      try? await session.remove(at: temporaryFile, isDirectory: false)
      try? await session.remove(at: replacementTemporaryFile, isDirectory: false)
      try? await session.remove(at: destinationFile, isDirectory: false)
      try? await session.remove(at: nestedFile, isDirectory: false)
      try? await session.remove(at: nestedDirectory, isDirectory: true)
      try? await session.remove(at: testDirectory, isDirectory: true)
      await session.close()
      throw error
    }
  }

  private func verifyRebex(security: FTPConnectionSecurity) async throws {
    try await withSession(
      host: "test.rebex.net",
      username: "demo",
      password: "password",
      security: security
    ) { session in
      let rootEntries = try await session.contents(of: "/")
      #expect(rootEntries.contains { $0.name == "pub" && $0.isDirectory })

      let accumulator = LiveFTPDataAccumulator()
      try await session.streamFileContents(of: "/pub/example/readme.txt") { chunk in
        await accumulator.append(chunk)
      }
      #expect(await accumulator.count > 0)
    }
  }

  private func readData(
    from path: String,
    using session: any FTPClientSession
  ) async throws -> Data {
    let accumulator = LiveFTPDataAccumulator()
    try await session.streamFileContents(of: path) { chunk in
      await accumulator.append(chunk)
    }
    return await accumulator.value
  }

  private func verifyUploadCancellation(
    target: FTPConnectionTarget,
    service: FTPConnectionService,
    directory: String
  ) async throws {
    let path = childPath(named: "pkpane-cancel-\(UUID().uuidString).tmp", in: directory)
    let session = try await service.connect(to: target)
    let progressSignal = LiveFTPProgressSignal()
    let uploadTask = Task {
      try await session.writeFileContents(
        to: path,
        chunks: stalledDataStream(Data(repeating: 0x41, count: 1_048_576)),
        progress: { transferred in
          guard transferred > 0 else { return }
          Task { await progressSignal.signal() }
        })
    }

    do {
      try await waitForProgress(progressSignal)
      uploadTask.cancel()
      await #expect(throws: CancellationError.self) {
        try await uploadTask.value
      }
      await session.close()
    } catch {
      uploadTask.cancel()
      _ = try? await uploadTask.value
      await session.close()
      try? await removeLiveFTPFile(at: path, target: target, service: service)
      throw error
    }

    try await removeLiveFTPFile(at: path, target: target, service: service)
  }

  private func removeLiveFTPFile(
    at path: String,
    target: FTPConnectionTarget,
    service: FTPConnectionService
  ) async throws {
    let cleanupSession = try await service.connect(to: target)
    do {
      if try await cleanupSession.fileSize(at: path) != nil {
        try await cleanupSession.remove(at: path, isDirectory: false)
      }
      #expect(try await cleanupSession.fileSize(at: path) == nil)
      await cleanupSession.close()
    } catch {
      await cleanupSession.close()
      throw error
    }
  }

  private func waitForProgress(_ signal: LiveFTPProgressSignal) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await signal.wait() }
      group.addTask {
        try await Task.sleep(for: .seconds(5))
        throw FTPTransportError.timedOut
      }
      defer { group.cancelAll() }
      _ = try await group.next()
    }
  }

  private func withSession<Result: Sendable>(
    host: String,
    port: Int = 21,
    username: String,
    password: String,
    security: FTPConnectionSecurity,
    operation: @Sendable (any FTPClientSession) async throws -> Result
  ) async throws -> Result {
    let target = try FTPConnectionTarget(
      host: host,
      port: port,
      username: username,
      security: security)
    let service = FTPConnectionService(
      passwordStore: FTPPasswordStore(
        keychain: LiveFTPPasswordStore(password: password)),
      timeout: .seconds(20))
    let session = try await service.connect(to: target)
    do {
      let result = try await operation(session)
      await session.close()
      return result
    } catch {
      await session.close()
      throw error
    }
  }

  private func dataStream(_ data: Data) -> AsyncThrowingStream<Data, Error> {
    AsyncThrowingStream { continuation in
      continuation.yield(data)
      continuation.finish()
    }
  }

  private func stalledDataStream(_ data: Data) -> AsyncThrowingStream<Data, Error> {
    AsyncThrowingStream { continuation in
      continuation.yield(data)
    }
  }

  private func childPath(named name: String, in directory: String) -> String {
    directory == "/" ? "/\(name)" : "\(directory)/\(name)"
  }
}

private actor LiveFTPDataAccumulator {
  private var storage = Data()

  var count: Int { storage.count }
  var value: Data { storage }

  func append(_ chunk: Data) {
    storage.append(chunk)
  }
}

private actor LiveFTPProgressSignal {
  private var isSignaled = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func signal() {
    guard !isSignaled else { return }
    isSignaled = true
    let pending = waiters
    waiters.removeAll()
    for waiter in pending {
      waiter.resume()
    }
  }

  func wait() async {
    if isSignaled { return }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }
}

private struct LiveFTPWriteServerConfiguration: Sendable {
  let host: String
  let port: Int
  let username: String
  let password: String
  let directory: String
  let security: FTPConnectionSecurity

  static func fromEnvironment(
    _ environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> LiveFTPWriteServerConfiguration? {
    guard let host = nonempty(environment["PKPANE_LIVE_FTP_HOST"]),
      let username = nonempty(environment["PKPANE_LIVE_FTP_USERNAME"]),
      let password = nonempty(environment["PKPANE_LIVE_FTP_PASSWORD"])
    else { return nil }
    let port = environment["PKPANE_LIVE_FTP_PORT"].flatMap(Int.init) ?? 21
    guard (1...65_535).contains(port) else { return nil }
    let rawDirectory = nonempty(environment["PKPANE_LIVE_FTP_DIRECTORY"]) ?? "/"
    guard rawDirectory.hasPrefix("/"),
      !rawDirectory.utf8.contains(where: { $0 == 0 || $0 == 10 || $0 == 13 })
    else { return nil }
    let directoryComponents = rawDirectory.split(separator: "/")
    let directory =
      directoryComponents.isEmpty
      ? "/" : "/" + directoryComponents.joined(separator: "/")
    let security: FTPConnectionSecurity =
      environment["PKPANE_LIVE_FTP_SECURITY"]?.lowercased() == "plain" ? .plain : .explicitTLS
    return LiveFTPWriteServerConfiguration(
      host: host,
      port: port,
      username: username,
      password: password,
      directory: directory,
      security: security)
  }

  private static func nonempty(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
  }
}

private final class LiveFTPPasswordStore: KeychainPasswordDataStoring {
  private let storedPassword: String

  init(password: String) {
    storedPassword = password
  }

  func save(password _: String, service _: String, account _: String) throws {}

  func password(service _: String, account _: String) throws -> String? {
    storedPassword
  }
}
