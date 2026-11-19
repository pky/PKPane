import Foundation
import Testing

@testable import PKPane

#if PKPANE_FTP_LOOPBACK_TESTS
  private let ftpLoopbackEnabled = true
#else
  private let ftpLoopbackEnabled = false
#endif

@MainActor
@Suite(.serialized)
struct FTPLoopbackWireTests {
  @Test("stock FTPの別名保持は本番キュー経由で既存内容と元を保全する", .enabled(if: ftpLoopbackEnabled))
  func keepsBothThroughProductionQueue() async throws {
    try await verifyPublicTransfer(isDirectory: false)
  }

  @Test("stock FTPが子名を変更するフォルダ転送は安全に拒否する", .enabled(if: ftpLoopbackEnabled))
  func rejectsChangedFolderChildName() async throws {
    try await verifyPublicTransfer(isDirectory: true)
  }

  @Test("stock FTPのMKDは実名を返し既存フォルダを再予約しない", .enabled(if: ftpLoopbackEnabled))
  func reservesDirectoryExclusively() async throws {
    let context = try await FTPWireContext.make()
    let path = "/exclusive-\(UUID().uuidString)"
    do {
      let returned = try await context.session.createExclusiveDirectory(at: path)
      #expect(returned == path)
      do {
        _ = try await context.session.createExclusiveDirectory(at: path)
        Issue.record("既存フォルダの再予約を拒否しませんでした")
      } catch {}
      let verification = try await context.service.connect(to: context.target)
      do {
        #expect(try await verification.contents(of: path).isEmpty)
        await verification.close()
      } catch {
        await verification.close()
        throw error
      }
      await context.session.close()
    } catch {
      await context.session.close()
      throw error
    }
  }

  private func verifyPublicTransfer(isDirectory: Bool) async throws {
    let context = try await FTPWireContext.make()
    let remoteRoot = "/queue-\(UUID().uuidString)"
    let name = isDirectory ? "tree" : "report.txt"
    let old = Data("old contents".utf8)
    let payload = Data("wire transfer contents".utf8)
    try await context.session.createDirectory(at: remoteRoot)
    if isDirectory {
      try await context.session.createDirectory(at: remoteRoot + "/tree")
    }
    let oldPath = remoteRoot + (isDirectory ? "/tree/old.txt" : "/report.txt")
    try await context.session.writeFileContents(
      to: oldPath, chunks: stream(old), progress: { _ in })
    let localRoot = context.configurationRoot.appending(path: "source-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: false)
    let sourceURL = localRoot.appending(path: name)
    if isDirectory {
      try FileManager.default.createDirectory(at: sourceURL, withIntermediateDirectories: false)
    }
    try payload.write(to: isDirectory ? sourceURL.appending(path: "report.txt") : sourceURL)
    let provider = FTPFileProvider(
      target: context.target, session: context.session,
      sessionFactory: { try await context.service.connect(to: context.target) })
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let source = FileBrowserSession(
      provider: LocalFileProvider(), initialLocation: FileLocation(localURL: localRoot),
      transferQueue: queue)
    let destination = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: remoteRoot, providerID: provider.id),
      transferQueue: queue)
    defer {
      source.invalidate()
      destination.invalidate()
    }
    var verification: (any FTPClientSession)?
    do {
      source.load()
      destination.load()
      await waitUntil { !source.isLoading && !destination.isLoading && source.items.count == 1 }
      let item = try #require(source.items.first)
      source.move([item], to: destination)
      _ = try #require(source.pendingTransferConflict?.canKeepBoth == true)
      source.resolvePendingTransferConflict(.keepBoth)
      await waitUntil {
        let jobs = await queue.allJobs()
        return jobs.first?.state.isTerminal == true && !source.isTransferring
      }
      let jobs = await queue.allJobs()
      let job = try #require(jobs.first)
      let checkingSession = try await context.service.connect(to: context.target)
      verification = checkingSession
      #expect(try await read(oldPath, session: checkingSession) == old)
      if isDirectory {
        #expect(job.state == .failed)
        #expect(try Data(contentsOf: sourceURL.appending(path: "report.txt")) == payload)
        let options = try #require(job.items.first?.transferOptions)
        let reservedName = try #require(options.destinationName)
        let entries = try await checkingSession.contents(of: remoteRoot + "/" + reservedName)
        let remaining = try #require(entries.count == 1 ? entries.first : nil)
        #expect(!remaining.isDirectory)
        #expect(remaining.name != "report.txt")
        #expect(
          try await checkingSession.fileSize(
            at: remoteRoot + "/" + reservedName + "/" + remaining.name) == 0)
        #expect(job.errorDescription?.contains(reservedName) == true)
      } else {
        #expect(job.state == .completed)
        #expect(!FileManager.default.fileExists(atPath: sourceURL.path))
        let options = try #require(job.items.first?.transferOptions)
        let returnedName = try #require(options.destinationName)
        #expect(returnedName != name)
        #expect(options.destinationNameWasReserved)
        #expect(
          try await read(remoteRoot + "/" + returnedName, session: checkingSession) == payload)
      }
      await verification?.close()
      await context.session.close()
    } catch {
      await verification?.close()
      await context.session.close()
      throw error
    }
  }

  private func stream(_ data: Data) -> AsyncThrowingStream<Data, Error> {
    AsyncThrowingStream { continuation in
      continuation.yield(data)
      continuation.finish()
    }
  }

  private func read(_ path: String, session: any FTPClientSession) async throws -> Data {
    let bytes = FTPWireBytes()
    try await session.streamFileContents(of: path) { await bytes.append($0) }
    return await bytes.value
  }
}

private struct FTPWireContext {
  let configurationRoot: URL
  let target: FTPConnectionTarget
  let service: FTPConnectionService
  let session: any FTPClientSession

  static func make() async throws -> Self {
    let path = try #require(ProcessInfo.processInfo.environment["PKPANE_RV26_FTP_WIRE_CONFIG"])
    let url = URL(fileURLWithPath: path)
    #expect(url.lastPathComponent == "configuration.json")
    #expect(url.deletingLastPathComponent().lastPathComponent.hasPrefix("pkpane-rv26-ftp-wire-"))
    let configuration = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url))
    _ = try #require(configuration.host == "127.0.0.1")
    _ = try #require(configuration.port >= 1024 && configuration.port <= 65535)
    let target = try FTPConnectionTarget(
      host: configuration.host, port: configuration.port,
      username: configuration.username, security: .plain)
    let service = FTPConnectionService(
      passwordStore: FTPPasswordStore(
        keychain: FTPWirePasswordStore(password: configuration.password)),
      timeout: .seconds(10))
    return try await Self(
      configurationRoot: url.deletingLastPathComponent(), target: target, service: service,
      session: service.connect(to: target))
  }

  private struct Configuration: Decodable {
    let host: String
    let port: Int
    let username: String
    let password: String
  }
}

private actor FTPWireBytes {
  var value = Data()
  func append(_ data: Data) { value.append(data) }
}

private final class FTPWirePasswordStore: KeychainPasswordDataStoring {
  let storedPassword: String
  init(password: String) { storedPassword = password }
  func save(password _: String, service _: String, account _: String) throws {}
  func password(service _: String, account _: String) throws -> String? { storedPassword }
}
