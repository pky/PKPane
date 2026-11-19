import Foundation
import Testing

@testable import PKPane

struct FTPDirectoryClientTests {
  @Test("MLSDを標準一覧としてデータ接続から取得する")
  func listsWithMLSD() async throws {
    let controlTransport = FTPDirectoryControlTransport(responses: [
      "220 ready", "230 logged in", "200 binary", "211 End",
      "229 Entering Extended Passive Mode (|||5000|)", "150 opening data", "226 complete",
    ])
    let dataTransport = FTPDirectoryDataTransport(
      data: Data("type=file;size=42;modify=20260916090000; report.txt\r\n".utf8))
    let client = try makeClient(
      controlTransport: controlTransport,
      dataConnector: FTPDirectoryDataConnector(transports: [dataTransport]))

    try await client.connect()
    let entries = try await client.contents(of: "/incoming")

    #expect(entries.map(\.name) == ["report.txt"])
    #expect(entries.first?.source == .mlsd)
    #expect(await controlTransport.commands.suffix(2) == ["EPSV", "MLSD /incoming"])
    #expect(await !client.usesLegacyListing)
  }

  @Test("MLSD非対応サーバーではLISTへフォールバックする")
  func fallsBackToLIST() async throws {
    let controlTransport = FTPDirectoryControlTransport(responses: [
      "220 ready", "230 logged in", "200 binary", "211 End",
      "229 Entering Extended Passive Mode (|||5000|)", "500 MLSD unsupported",
      "229 Entering Extended Passive Mode (|||5001|)", "150 opening data", "226 complete",
    ])
    let emptyMLSDTransport = FTPDirectoryDataTransport(data: Data())
    let listTransport = FTPDirectoryDataTransport(
      data: Data("-rw-r--r-- 1 owner group 42 Sep 16 12:34 report.txt\r\n".utf8))
    let client = try makeClient(
      controlTransport: controlTransport,
      dataConnector: FTPDirectoryDataConnector(transports: [emptyMLSDTransport, listTransport]))

    try await client.connect()
    let entries = try await client.contents(of: "/incoming")

    #expect(entries.map(\.name) == ["report.txt"])
    #expect(entries.first?.source == .legacyList)
    #expect(await client.usesLegacyListing)
    #expect(await emptyMLSDTransport.isClosed)
  }

  private func makeClient(
    controlTransport: FTPDirectoryControlTransport,
    dataConnector: FTPDirectoryDataConnector
  ) throws -> FTPDirectoryClient {
    let target = try FTPConnectionTarget(
      host: "example.com", username: "anonymous", security: .plain)
    let control = FTPControlConnection(
      target: target,
      passwordStore: FTPPasswordStore(keychain: FTPDirectoryKeychainStore()),
      connector: FTPDirectoryControlConnector(transport: controlTransport))
    return FTPDirectoryClient(control: control, dataConnector: dataConnector)
  }
}

private struct FTPDirectoryControlConnector: FTPControlTransportConnecting {
  let transport: FTPDirectoryControlTransport

  func connect(host _: String, port _: Int, timeout _: Duration) async throws
    -> any FTPControlTransport
  {
    transport
  }
}

private actor FTPDirectoryControlTransport: FTPControlTransport {
  private var responses: [String]
  private(set) var commands: [String] = []

  init(responses: [String]) {
    self.responses = responses
  }

  func writeLine(_ line: String) async throws {
    commands.append(line)
  }

  func readLine(timeout _: Duration) async throws -> String {
    guard !responses.isEmpty else { throw FTPDirectoryClientTestError.missingResponse }
    return responses.removeFirst()
  }

  func close() async {}
}

private actor FTPDirectoryDataConnector: FTPDataTransportConnecting {
  private var transports: [FTPDirectoryDataTransport]

  init(transports: [FTPDirectoryDataTransport]) {
    self.transports = transports
  }

  func connect(to _: FTPPassiveEndpoint, timeout _: Duration) async throws
    -> any FTPDataTransport
  {
    guard !transports.isEmpty else { throw FTPDirectoryClientTestError.missingDataTransport }
    return transports.removeFirst()
  }
}

private actor FTPDirectoryDataTransport: FTPDataTransport {
  let data: Data
  private(set) var isClosed = false

  init(data: Data) {
    self.data = data
  }

  func readAll(timeout _: Duration, maximumBytes: Int) async throws -> Data {
    guard data.count <= maximumBytes else { throw FTPDirectoryClientTestError.listingTooLarge }
    return data
  }

  func close() async {
    isClosed = true
  }
}

private final class FTPDirectoryKeychainStore: KeychainPasswordDataStoring {
  func save(password _: String, service _: String, account _: String) throws {}
  func password(service _: String, account _: String) throws -> String? { "unused" }
}

private enum FTPDirectoryClientTestError: Error {
  case missingResponse
  case missingDataTransport
  case listingTooLarge
}
