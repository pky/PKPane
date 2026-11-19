import Foundation
import Synchronization
import Testing

@testable import PKPane

struct FTPClientSessionTests {
  @Test(
    "STOUの転送前実名を保存してから送り、空白を変えず元CWDへ戻す",
    arguments: ["new.txt", "/incoming/new.txt", " new.txt "])
  func storesUniqueFileAfterRecordingPreliminaryName(returnedName: String) async throws {
    let control = FTPClientControlTransport(responses: [
      "220 ready", "230 logged in", "200 binary", "211 End",
      "257 \"/original\" current", "250 changed", "257 \"/incoming\" current",
      "229 Entering Extended Passive Mode (|||5000|)",
      "150 FILE: " + returnedName, "226 complete", "250 restored",
    ])
    let data = FTPClientDataTransport()
    let session = try await makeSession(
      control: control, dataConnector: FTPClientDataConnector(transports: [data]))
    let recorded = Mutex<[String]>([])
    let expected = returnedName.hasPrefix("/") ? returnedName : "/incoming/" + returnedName
    let result = try await session.writeUniqueFileContents(
      in: "/incoming", suggestedName: nil, chunks: { uniquePayload() },
      reserved: { path in
        #expect(await data.writtenData.isEmpty)
        recorded.withLock { $0.append(path) }
      }, progress: { _ in })
    #expect(result == expected)
    #expect(recorded.withLock { $0 } == [expected])
    #expect(await data.writtenData == Data("contents".utf8))
    #expect(await data.isClosed)
    #expect(
      await control.commands.suffix(5) == [
        "CWD /incoming", "PWD", "EPSV", "STOU", "CWD /original",
      ])
  }

  @Test(
    "MKD257の引用二重化と相対実名を解釈して作成済みの実名を返す",
    arguments: [false, true])
  func reservesExclusiveDirectoryWithReturnedName(absolute: Bool) async throws {
    let quotedPath = absolute ? "/incoming/a\"\"b" : "a\"\"b"
    let control = FTPClientControlTransport(responses: [
      "220 ready", "230 logged in", "200 binary", "211 End",
      "257 \"/original\" current", "250 changed", "257 \"/incoming\" current",
      "257 \"" + quotedPath + "\" created", "250 restored",
    ])
    let session = try await makeSession(control: control)
    #expect(try await session.createExclusiveDirectory(at: "/incoming/a\"b") == "/incoming/a\"b")
    #expect(
      await control.commands.suffix(4) == [
        "CWD /incoming", "PWD", "MKD a\"b", "CWD /original",
      ])
  }

  @Test(
    "STOU実名が不明・越境・引用曖昧なら一切送信せず作成成否を不明とする",
    arguments: [
      "opening", "FILE: ../other", "FILE: /outside/new", "FILE: /incoming/sub/new",
      "FILE: \"new\"",
    ])
  func refusesUnknownOrUnsafeUniqueName(message: String) async throws {
    let control = FTPClientControlTransport(responses: [
      "220 ready", "230 logged in", "200 binary", "211 End",
      "257 \"/original\" current", "250 changed", "257 \"/incoming\" current",
      "229 Entering Extended Passive Mode (|||5000|)", "150 " + message,
      "226 FILE: too-late.txt",
    ])
    let data = FTPClientDataTransport()
    let session = try await makeSession(
      control: control, dataConnector: FTPClientDataConnector(transports: [data]))
    let recorded = Mutex<[String]>([])
    let expectedError = FTPUniqueCreationError.creationOutcomeUnknown(directoryPath: "/incoming")
    await #expect(throws: expectedError) {
      _ = try await session.writeUniqueFileContents(
        in: "/incoming", suggestedName: nil, chunks: { uniquePayload() },
        reserved: { path in recorded.withLock { $0.append(path) } }, progress: { _ in })
    }
    #expect(recorded.withLock { $0 }.isEmpty)
    #expect(await data.writtenData.isEmpty)
    #expect(await data.isClosed)
    #expect(await control.isClosed)
    #expect(await control.commands.allSatisfy { !$0.hasPrefix("DELE") && !$0.hasPrefix("RNTO") })
  }

  @Test("予約callbackが拒否すると内容を送らず、低層で予約名を削除しない")
  func refusesBeforeSendingWhenReservationCallbackFails() async throws {
    let control = FTPClientControlTransport(responses: [
      "220 ready", "230 logged in", "200 binary", "211 End",
      "257 \"/original\" current", "250 changed", "257 \"/incoming\" current",
      "229 Entering Extended Passive Mode (|||5000|)", "150 FILE: allocated.txt",
    ])
    let data = FTPClientDataTransport()
    let session = try await makeSession(
      control: control, dataConnector: FTPClientDataConnector(transports: [data]))
    await #expect(throws: FTPClientSessionTestError.reservationRejected) {
      _ = try await session.writeUniqueFileContents(
        in: "/incoming", suggestedName: nil, chunks: { uniquePayload() },
        reserved: { _ in throw FTPClientSessionTestError.reservationRejected }, progress: { _ in })
    }
    #expect(await data.writtenData.isEmpty)
    #expect(await data.isClosed)
    #expect(await control.commands.allSatisfy { !$0.hasPrefix("DELE") })
  }

  @Test("予約拒否ではsource factoryを起動せず、接続を閉じる")
  func doesNotStartSourceWhenReservationFails() async throws {
    let control = FTPClientControlTransport(responses: uniqueReplies())
    let data = FTPClientDataTransport()
    let session = try await makeSession(
      control: control, dataConnector: FTPClientDataConnector(transports: [data]))
    let factories = Mutex(0)
    await #expect(throws: FTPClientSessionTestError.reservationRejected) {
      _ = try await session.writeUniqueFileContents(
        in: "/incoming", suggestedName: nil,
        chunks: {
          factories.withLock { $0 += 1 }
          return uniquePayload()
        },
        reserved: { _ in throw FTPClientSessionTestError.reservationRejected }, progress: { _ in })
    }
    #expect(factories.withLock { $0 } == 0)
    #expect(await data.isClosed)
    #expect(!(await session.isActive()))
  }

  @Test("PWDの実親が別表記なら作成・source読取前に拒否する", arguments: [false, true])
  func rejectsCanonicalParentMismatch(directory: Bool) async throws {
    let control = FTPClientControlTransport(responses: [
      "220 ready", "230 logged in", "200 binary", "211 End",
      "257 \"/original\" current", "250 changed", "257 \"/canonical\" current",
    ])
    let session = try await makeSession(control: control)
    let factories = Mutex(0)
    await #expect(throws: FTPUniqueCreationError.invalidDestination) {
      if directory {
        _ = try await session.createExclusiveDirectory(at: "/incoming/folder")
      } else {
        _ = try await session.writeUniqueFileContents(
          in: "/incoming", suggestedName: nil,
          chunks: {
            factories.withLock { $0 += 1 }
            return uniquePayload()
          },
          reserved: { _ in Issue.record("別親では予約callbackを呼ばない") }, progress: { _ in })
      }
    }
    #expect(factories.withLock { $0 } == 0)
    #expect(await control.commands.allSatisfy { !$0.hasPrefix("MKD") && !$0.hasPrefix("STOU") })
  }

  @Test("Unicode等価でもwire bytesが異なるPWD親には送信前に拒否する")
  func rejectsUnicodeEquivalentButByteDistinctParent() async throws {
    let requested = "/caf\u{e9}"
    let actual = "/cafe\u{301}"
    #expect(requested == actual)
    #expect(!requested.utf8.elementsEqual(actual.utf8))
    let control = FTPClientControlTransport(responses: [
      "220 ready", "230 logged in", "200 binary", "211 End",
      "257 \"/original\" current", "250 changed", "257 \"" + actual + "\" current",
    ])
    let session = try await makeSession(control: control)
    let factories = Mutex(0)
    await #expect(throws: FTPUniqueCreationError.invalidDestination) {
      _ = try await session.writeUniqueFileContents(
        in: requested, suggestedName: nil,
        chunks: {
          factories.withLock { $0 += 1 }
          return uniquePayload()
        },
        reserved: { _ in Issue.record("byteが異なる親では予約callbackを呼ばない") },
        progress: { _ in })
    }
    #expect(factories.withLock { $0 } == 0)
    #expect(await control.commands.allSatisfy { !$0.hasPrefix("STOU") && !$0.hasPrefix("MKD") })
  }

  @Test("readonly CWD/PWDは実pathを返し元位置へ復元する")
  func resolvesCanonicalDirectoryWithoutCreatingAnything() async throws {
    let control = FTPClientControlTransport(responses: [
      "220 ready", "230 logged in", "200 binary", "211 End",
      "257 \"/original\" current", "250 changed", "257 \"/canonical\" current", "250 restored",
    ])
    let session = try await makeSession(control: control)
    #expect(try await session.canonicalDirectoryPath(at: "/alias") == "/canonical")
    #expect(await control.commands.suffix(4) == ["PWD", "CWD /alias", "PWD", "CWD /original"])
  }

  @Test("STOU完了・MKD応答が失われても自動削除せず成否不明を返す", arguments: [false, true])
  func preservesUnknownCreationAfterReplyLoss(directory: Bool) async throws {
    var replies = uniqueReplies()
    if directory { replies = Array(replies.prefix(7)) }
    let control = FTPClientControlTransport(responses: replies)
    let data = FTPClientDataTransport()
    let session = try await makeSession(
      control: control, dataConnector: FTPClientDataConnector(transports: [data]))
    await #expect(throws: FTPUniqueCreationError.creationOutcomeUnknown(directoryPath: "/incoming"))
    {
      if directory {
        _ = try await session.createExclusiveDirectory(at: "/incoming/folder")
      } else {
        _ = try await session.writeUniqueFileContents(
          in: "/incoming", suggestedName: nil, chunks: { uniquePayload() },
          reserved: { _ in }, progress: { _ in })
      }
    }
    #expect(await control.isClosed)
    #expect(await control.commands.allSatisfy { !$0.hasPrefix("DELE") && !$0.hasPrefix("RMD") })
  }

  @Test("専用leaseは予約callback待ちからCWD復元まで通常コマンドを割り込ませない")
  func holdsExclusiveLeaseUntilWorkingDirectoryIsRestored() async throws {
    let control = FTPClientControlTransport(
      responses: uniqueReplies() + [
        "226 complete", "250 restored", "213 42",
      ])
    let data = FTPClientDataTransport()
    let session = try await makeSession(
      control: control, dataConnector: FTPClientDataConnector(transports: [data]))
    let gate = FTPUniqueTestGate()
    let upload = Task {
      try await session.writeUniqueFileContents(
        in: "/incoming", suggestedName: nil, chunks: { uniquePayload() },
        reserved: { _ in await gate.suspend() }, progress: { _ in })
    }
    await waitUntil { await gate.isSuspended }
    let started = Mutex(false)
    let size = Task {
      started.withLock { $0 = true }
      return try await session.fileSize(at: "/incoming/allocated.txt")
    }
    await waitUntil { started.withLock { $0 } }
    #expect(await control.commands.last == "STOU")
    await gate.resume()
    #expect(try await upload.value == "/incoming/allocated.txt")
    #expect(try await size.value == 42)
    #expect(await control.commands.suffix(2) == ["CWD /original", "SIZE /incoming/allocated.txt"])
  }

  @Test("専用lease待機取消は先行callbackの解放前に終了する")
  func releasesCanceledExclusiveLeaseWaiter() async throws {
    let control = FTPClientControlTransport(
      responses: uniqueReplies() + ["226 complete", "250 restored"])
    let data = FTPClientDataTransport()
    let session = try await makeSession(
      control: control, dataConnector: FTPClientDataConnector(transports: [data]))
    let gate = FTPUniqueTestGate()
    let upload = Task {
      try await session.writeUniqueFileContents(
        in: "/incoming", suggestedName: nil, chunks: { uniquePayload() },
        reserved: { _ in await gate.suspend() }, progress: { _ in })
    }
    await waitUntil { await gate.isSuspended }
    let state = Mutex((started: false, finished: false))
    let pending = Task {
      defer { state.withLock { $0.finished = true } }
      state.withLock { $0.started = true }
      return try await session.createExclusiveDirectory(at: "/incoming/other")
    }
    await waitUntil { state.withLock { $0.started } }
    pending.cancel()
    await waitUntil { state.withLock { $0.finished } }
    // 失敗時にも先行転送を解放してテストのTaskを残さない。
    await gate.resume()
    _ = try await upload.value
    await #expect(throws: CancellationError.self) { try await pending.value }
    #expect(await control.commands.allSatisfy { !$0.hasPrefix("MKD") })
  }

  @Test("予約直後の取消はsource未起動・接続終了で待機コマンドも解放する")
  func cancelsAfterReservationWithoutStartingSource() async throws {
    let control = FTPClientControlTransport(responses: uniqueReplies())
    let data = FTPClientDataTransport()
    let session = try await makeSession(
      control: control, dataConnector: FTPClientDataConnector(transports: [data]))
    let gate = FTPUniqueTestGate()
    let factories = Mutex(0)
    let upload = Task {
      try await session.writeUniqueFileContents(
        in: "/incoming", suggestedName: nil,
        chunks: {
          factories.withLock { $0 += 1 }
          return uniquePayload()
        },
        reserved: { _ in await gate.suspend() }, progress: { _ in })
    }
    await waitUntil { await gate.isSuspended }
    let size = Task { try await session.fileSize(at: "/incoming/allocated.txt") }
    upload.cancel()
    await gate.resume()
    await #expect(throws: CancellationError.self) { try await upload.value }
    await #expect(throws: FTPControlConnectionError.self) { try await size.value }
    #expect(factories.withLock { $0 } == 0)
    #expect(await data.isClosed)
    #expect(await control.isClosed)
  }

  private func uniqueReplies() -> [String] {
    [
      "220 ready", "230 logged in", "200 binary", "211 End",
      "257 \"/original\" current", "250 changed", "257 \"/incoming\" current",
      "229 Entering Extended Passive Mode (|||5000|)", "150 FILE: allocated.txt",
    ]
  }

  private func uniquePayload() -> AsyncThrowingStream<Data, Error> {
    AsyncThrowingStream { continuation in
      continuation.yield(Data("contents".utf8))
      continuation.finish()
    }
  }

  @Test("基本操作をFTPコマンドへ変換しrenameを不可分に実行する")
  func executesBasicCommands() async throws {
    let control = FTPClientControlTransport(responses: [
      "220 ready", "230 logged in", "200 binary", "211 End",
      "257 created", "250 deleted", "250 removed", "350 rename from", "250 renamed",
      "213 42", "200 permissions", "221 bye",
    ])
    let session = try await makeSession(control: control)

    try await session.createDirectory(at: "/folder")
    try await session.remove(at: "/file.txt", isDirectory: false)
    try await session.remove(at: "/folder", isDirectory: true)
    try await session.rename(at: "/old.txt", to: "/new.txt")
    #expect(try await session.fileSize(at: "/new.txt") == 42)
    try await session.setPosixPermissions(0o644, at: "/new.txt")
    await session.close()

    #expect(
      await control.commands == [
        "USER anonymous", "TYPE I", "FEAT",
        "MKD /folder", "DELE /file.txt", "RMD /folder",
        "RNFR /old.txt", "RNTO /new.txt", "SIZE /new.txt",
        "SITE CHMOD 0644 /new.txt", "QUIT",
      ])
  }

  @Test("RETRをチャンク受信し226完了まで待つ")
  func streamsDownload() async throws {
    let control = FTPClientControlTransport(responses: [
      "220 ready", "230 logged in", "200 binary", "211 End",
      "229 Entering Extended Passive Mode (|||5000|)", "150 opening", "226 complete",
    ])
    let data = FTPClientDataTransport(readData: Data("download".utf8))
    let session = try await makeSession(
      control: control,
      dataConnector: FTPClientDataConnector(transports: [data]))
    let received = LockedDataCollector()

    try await session.streamFileContents(of: "/file.txt") { chunk in
      received.append(chunk)
    }

    #expect(received.data == Data("download".utf8))
    #expect(await data.isClosed)
    #expect(await control.commands.suffix(2) == ["EPSV", "RETR /file.txt"])
  }

  @Test("STORへ全チャンクを書き込み累積進捗を報告する")
  func streamsUpload() async throws {
    let control = FTPClientControlTransport(responses: [
      "220 ready", "230 logged in", "200 binary", "211 End",
      "229 Entering Extended Passive Mode (|||5000|)", "150 opening", "226 complete",
    ])
    let data = FTPClientDataTransport()
    let session = try await makeSession(
      control: control,
      dataConnector: FTPClientDataConnector(transports: [data]))
    let stream = AsyncThrowingStream<Data, Error> { continuation in
      continuation.yield(Data("abc".utf8))
      continuation.yield(Data("de".utf8))
      continuation.finish()
    }
    let progress = LockedInt64Collector()

    try await session.writeFileContents(to: "/upload.txt", chunks: stream) {
      progress.append($0)
    }

    #expect(await data.writtenData == Data("abcde".utf8))
    #expect(progress.values == [3, 5])
    #expect(await control.commands.suffix(2) == ["EPSV", "STOR /upload.txt"])
  }

  @Test("明示的FTPSはデータ接続にも同じホスト名のTLS検証を要求する")
  func protectsDataConnectionWithTLS() async throws {
    let control = FTPClientControlTransport(responses: [
      "220 ready", "234 begin TLS", "230 logged in", "200 binary",
      "200 PBSZ accepted", "200 private data", "211 End",
      "229 Entering Extended Passive Mode (|||5000|)", "150 opening", "226 complete",
    ])
    let data = FTPClientDataTransport(readData: Data("secure".utf8))
    let connector = FTPClientDataConnector(transports: [data])
    let session = try await makeSession(
      control: control,
      dataConnector: connector,
      security: .explicitTLS)

    try await session.streamFileContents(of: "/secure.txt") { _ in }

    #expect(await control.tlsServerHostnames == ["example.com"])
    #expect(await connector.tlsServerHostnames == ["example.com"])
    #expect(await connector.tlsSessionIdentifiers == [Data("test-session".utf8)])
    #expect(
      await control.commands.prefix(6) == [
        "AUTH TLS", "USER anonymous", "TYPE I", "PBSZ 0", "PROT P", "FEAT",
      ])
  }

  private func makeSession(
    control: FTPClientControlTransport,
    dataConnector: FTPClientDataConnector = FTPClientDataConnector(transports: []),
    security: FTPConnectionSecurity = .plain
  ) async throws -> any FTPClientSession {
    let target = try FTPConnectionTarget(
      host: "example.com", username: "anonymous", security: security)
    let service = FTPConnectionService(
      passwordStore: FTPPasswordStore(keychain: FTPClientKeychainStore()),
      controlConnector: FTPClientControlConnector(transport: control),
      dataConnector: dataConnector)
    return try await service.connect(to: target)
  }
}

private struct FTPClientControlConnector: FTPControlTransportConnecting {
  let transport: FTPClientControlTransport

  func connect(host _: String, port _: Int, timeout _: Duration) async throws
    -> any FTPControlTransport
  {
    transport
  }
}

private actor FTPClientControlTransport: FTPControlTransport {
  private var responses: [String]
  private(set) var commands: [String] = []
  private(set) var tlsServerHostnames: [String] = []
  private(set) var isClosed = false

  init(responses: [String]) {
    self.responses = responses
  }

  func writeLine(_ line: String) async throws { commands.append(line) }

  func readLine(timeout _: Duration) async throws -> String {
    guard !responses.isEmpty else { throw FTPClientSessionTestError.missingResponse }
    return responses.removeFirst()
  }

  func upgradeToTLS(serverHostname: String, timeout _: Duration) async throws {
    tlsServerHostnames.append(serverHostname)
  }

  func tlsSessionIdentifier() -> Data? {
    tlsServerHostnames.isEmpty ? nil : Data("test-session".utf8)
  }

  func close() async { isClosed = true }
}

private actor FTPClientDataConnector: FTPDataTransportConnecting {
  private var transports: [FTPClientDataTransport]
  private(set) var tlsServerHostnames: [String] = []
  private(set) var tlsSessionIdentifiers: [Data] = []

  init(transports: [FTPClientDataTransport]) {
    self.transports = transports
  }

  func connect(to _: FTPPassiveEndpoint, timeout _: Duration) async throws
    -> any FTPDataTransport
  {
    guard !transports.isEmpty else { throw FTPClientSessionTestError.missingDataTransport }
    return transports.removeFirst()
  }

  func connect(
    to _: FTPPassiveEndpoint,
    timeout _: Duration,
    tlsServerHostname: String?,
    tlsSessionIdentifier: Data?
  ) async throws -> any FTPDataTransport {
    if let tlsServerHostname { tlsServerHostnames.append(tlsServerHostname) }
    if let tlsSessionIdentifier { tlsSessionIdentifiers.append(tlsSessionIdentifier) }
    guard !transports.isEmpty else { throw FTPClientSessionTestError.missingDataTransport }
    return transports.removeFirst()
  }
}

private actor FTPClientDataTransport: FTPDataTransport {
  let readData: Data
  private(set) var writtenData = Data()
  private(set) var isClosed = false

  init(readData: Data = Data()) {
    self.readData = readData
  }

  func readAll(timeout _: Duration, maximumBytes _: Int) async throws -> Data { readData }

  func writeChunks(
    _ chunks: AsyncThrowingStream<Data, Error>,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws {
    for try await chunk in chunks {
      writtenData.append(chunk)
      progress(Int64(writtenData.count))
    }
  }

  func close() async { isClosed = true }
}

private final class FTPClientKeychainStore: KeychainPasswordDataStoring {
  func save(password _: String, service _: String, account _: String) throws {}
  func password(service _: String, account _: String) throws -> String? { "unused" }
}

private final class LockedDataCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = Data()

  var data: Data { lock.withLock { storage } }

  func append(_ data: Data) {
    lock.withLock { storage.append(data) }
  }
}

private final class LockedInt64Collector: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [Int64] = []

  var values: [Int64] { lock.withLock { storage } }

  func append(_ value: Int64) {
    lock.withLock { storage.append(value) }
  }
}

private enum FTPClientSessionTestError: Error {
  case missingResponse
  case missingDataTransport
  case reservationRejected
}

private actor FTPUniqueTestGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private(set) var isSuspended = false

  func suspend() async {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      isSuspended = true
    }
  }

  func resume() {
    continuation?.resume()
    continuation = nil
  }
}
