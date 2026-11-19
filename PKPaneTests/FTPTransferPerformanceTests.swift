import Foundation
import Synchronization
import Testing

@testable import PKPane

struct FTPTransferPerformanceTests {
  @Test(
    "FTP制御接続を1・100・1000件の往復で10回計測する",
    .enabled(
      if: ProcessInfo.processInfo.environment["PKPANE_RV26_MEASUREMENTS"] == "1",
      "RV26前後計測時だけ10回の遅延フィクスチャを実行する"),
    arguments: [1, 100, 1_000])
  func measuresControlConnectionOverhead(fileCount: Int) async throws {
    var milliseconds: [Double] = []
    var connectionCounts: [Int] = []
    var authenticationCounts: [Int] = []
    var dataConnectionCounts: [Int] = []
    for _ in 0..<10 {
      let statistics = FTPMeasurementStatistics()
      let (provider, browsingSession) = try await makeProvider(
        statistics: statistics, connectionDelay: .milliseconds(1))
      let clock = ContinuousClock()
      let start = clock.now
      for index in 0..<fileCount {
        let item = item(index: index, providerID: provider.id)
        var received = Data()
        for try await chunk in provider.fileChunks(for: item, chunkSize: 256 * 1_024) {
          received.append(chunk)
        }
        #expect(received == Data([0x42]))
        let chunks = AsyncThrowingStream<Data, Error> { continuation in
          continuation.yield(received)
          continuation.finish()
        }
        try await provider.writeFileChunks(
          chunks,
          to: FileLocation(remotePath: "/temporary-\(index)", providerID: provider.id),
          replacingExisting: false,
          progress: { _ in })
      }
      let duration = start.duration(to: clock.now).components
      milliseconds.append(Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15)
      let snapshot = statistics.snapshot
      // 最初の閲覧制御接続を除外し、転送用制御接続だけを数える。
      connectionCounts.append(snapshot.connections - 1)
      authenticationCounts.append(snapshot.authentications - 1)
      dataConnectionCounts.append(snapshot.dataConnections)
      #expect(snapshot.connections - 1 == 2 * fileCount)
      #expect(snapshot.closedConnections == 2 * fileCount)
      #expect(await browsingSession.isActive())
      #expect(snapshot.authentications == snapshot.connections)
      #expect(snapshot.dataConnections == 3 * fileCount)
      await browsingSession.close()
    }
    let sorted = milliseconds.sorted()
    let lower = try #require(sorted.prefix(sorted.count / 2).last)
    let upper = try #require(sorted.dropFirst(sorted.count / 2).first)
    try writeRV26Measurement(
      name: "ftp-control-before-\(fileCount)",
      values: [
        "phase": "before", "fileCount": fileCount, "trialCount": 10,
        "milliseconds": milliseconds, "medianMilliseconds": (lower + upper) / 2,
        "maximumMilliseconds": try #require(sorted.last),
        "transferControlConnections": connectionCounts,
        "transferAuthentications": authenticationCounts,
        "dataConnections": dataConnectionCounts, "payloadBytesPerFile": 1,
        "connectionDelayMilliseconds": 1,
        "condition": "実FTPConnectionService/ControlConnection/Adapter、記録transport、RETR/STOR各ファイル直列",
        "networkScope": "実サーバー/TLSなし。connect遅延だけを1ms注入。認証USERはfixture応答230で完了",
        "cacheScope": "試行ごとに新規fixture。OS cache対象外。閲覧接続1を転送制御接続数から除外",
      ])
    print(
      "RV26-07 FTP \(fileCount)件 各RETR/STOR、factory遅延1ms、"
        + "中央値=\((lower + upper) / 2)ms、最大=\(try #require(sorted.last))ms、"
        + "転送制御接続=\(connectionCounts)、各接続の認証=1")
  }

  @Test("読取保持中の書込と閲覧は制御接続を相互に待たせない")
  func streamsReaderAndWriterIndependentlyFromBrowsing() async throws {
    let statistics = FTPMeasurementStatistics(holdsReaderUntilWriterConsumes: true)
    let (provider, browsingSession) = try await makeProvider(
      statistics: statistics, connectionDelay: .zero)
    let chunks = provider.fileChunks(for: item(index: 0, providerID: provider.id), chunkSize: 1)
    guard await waitUntil(condition: { statistics.snapshot.readerStarted }) else {
      await browsingSession.close()
      return
    }
    _ = try await provider.contents(
      of: FileLocation(remotePath: "/", providerID: provider.id))
    try await provider.writeFileChunks(
      chunks, to: FileLocation(remotePath: "/temporary-stream", providerID: provider.id),
      replacingExisting: false, progress: { _ in })
    let snapshot = statistics.snapshot
    #expect(snapshot.writerConsumed)
    #expect(snapshot.connections == 3)
    #expect(snapshot.authentications == 3)
    #expect(snapshot.closedConnections == 2)
    #expect(await browsingSession.isActive())
    await browsingSession.close()
  }

  private func item(index: Int, providerID: FileProviderID) -> FileItem {
    FileItem(
      remotePath: "/source-\(index)", url: URL(fileURLWithPath: "/source-\(index)"),
      providerID: providerID, isDirectory: false, size: 1)
  }

  private func makeProvider(
    statistics: FTPMeasurementStatistics, connectionDelay: Duration
  ) async throws -> (FTPFileProvider, any FTPClientSession) {
    let target = try FTPConnectionTarget(
      host: "fixture.invalid", username: "anonymous", security: .plain)
    let service = FTPConnectionService(
      passwordStore: FTPPasswordStore(keychain: FTPMeasurementKeychain()),
      controlConnector: FTPMeasurementControlConnector(
        statistics: statistics, delay: connectionDelay),
      dataConnector: FTPMeasurementDataConnector(statistics: statistics))
    let browsingSession = try await service.connect(to: target)
    return (
      FTPFileProvider(
        target: target, session: browsingSession,
        sessionFactory: { try await service.connect(to: target) }), browsingSession
    )
  }
}

private final class FTPMeasurementStatistics: Sendable {
  struct Snapshot: Sendable {
    var connections = 0
    var authentications = 0
    var dataConnections = 0
    var closedConnections = 0
    var readerStarted = false
    var writerConsumed = false
  }
  let holdsReaderUntilWriterConsumes: Bool
  private let state = Mutex(Snapshot())
  init(holdsReaderUntilWriterConsumes: Bool = false) {
    self.holdsReaderUntilWriterConsumes = holdsReaderUntilWriterConsumes
  }
  var snapshot: Snapshot { state.withLock { $0 } }
  func connected() { state.withLock { $0.connections += 1 } }
  func authenticated() { state.withLock { $0.authentications += 1 } }
  func dataConnected() { state.withLock { $0.dataConnections += 1 } }
  func closed() { state.withLock { $0.closedConnections += 1 } }
  func startedReader() { state.withLock { $0.readerStarted = true } }
  func consumedByWriter() { state.withLock { $0.writerConsumed = true } }
}

private struct FTPMeasurementControlConnector: FTPControlTransportConnecting {
  let statistics: FTPMeasurementStatistics
  let delay: Duration

  func connect(host _: String, port _: Int, timeout _: Duration) async throws
    -> any FTPControlTransport
  {
    try await Task.sleep(for: delay)
    statistics.connected()
    return FTPMeasurementControlTransport(statistics: statistics)
  }
}

private actor FTPMeasurementControlTransport: FTPControlTransport {
  let statistics: FTPMeasurementStatistics
  private var replies = ["220 fixture"]
  private var closed = false

  init(statistics: FTPMeasurementStatistics) { self.statistics = statistics }

  func writeLine(_ line: String) async throws {
    guard !closed else { throw FTPTransportError.connectionClosed }
    let command = line.split(separator: " ").first.map(String.init) ?? ""
    switch command {
    case "USER":
      statistics.authenticated()
      replies.append("230 fixture")
    case "TYPE", "NOOP": replies.append("200 fixture")
    case "FEAT": replies.append("211 End")
    case "EPSV": replies.append("229 Entering Extended Passive Mode (|||5000|)")
    case "MLSD", "LIST", "RETR", "STOR":
      replies += ["150 fixture", "226 fixture"]
    case "SIZE": replies.append("213 1")
    case "RNFR": replies.append("350 fixture")
    case "RNTO": replies.append("250 fixture")
    case "QUIT": replies.append("221 fixture")
    default: throw FTPTransportError.connectionClosed
    }
  }

  func readLine(timeout _: Duration) async throws -> String {
    guard !closed, !replies.isEmpty else { throw FTPTransportError.connectionClosed }
    return replies.removeFirst()
  }

  func close() async {
    guard !closed else { return }
    closed = true
    statistics.closed()
  }
}

private struct FTPMeasurementDataConnector: FTPDataTransportConnecting {
  let statistics: FTPMeasurementStatistics
  func connect(to _: FTPPassiveEndpoint, timeout _: Duration) async throws
    -> any FTPDataTransport
  {
    statistics.dataConnected()
    return FTPMeasurementDataTransport(statistics: statistics)
  }
}

private actor FTPMeasurementDataTransport: FTPDataTransport {
  let statistics: FTPMeasurementStatistics
  init(statistics: FTPMeasurementStatistics) { self.statistics = statistics }
  func readAll(timeout _: Duration, maximumBytes _: Int) async throws -> Data { Data() }
  func readChunks(
    timeout _: Duration, receive: @escaping @Sendable (Data) async throws -> Void
  ) async throws {
    statistics.startedReader()
    try await receive(Data([0x42]))
    if statistics.holdsReaderUntilWriterConsumes {
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: .seconds(2))
      while !statistics.snapshot.writerConsumed {
        guard clock.now < deadline else { throw FTPTransportError.timedOut }
        try await Task.sleep(for: .milliseconds(1))
      }
    }
  }
  func writeChunks(
    _ chunks: AsyncThrowingStream<Data, Error>, progress: @escaping @Sendable (Int64) -> Void
  ) async throws {
    var count: Int64 = 0
    for try await chunk in chunks {
      count += Int64(chunk.count)
      statistics.consumedByWriter()
      progress(count)
    }
    #expect(count == 1)
  }
  func close() async {}
}

private final class FTPMeasurementKeychain: KeychainPasswordDataStoring {
  func save(password _: String, service _: String, account _: String) throws {}
  func password(service _: String, account _: String) throws -> String? { nil }
}
