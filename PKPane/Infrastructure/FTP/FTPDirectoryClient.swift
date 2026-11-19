import Foundation

actor FTPDirectoryClient {
  private static let maximumListingBytes = 256 * 1_024 * 1_024

  private let control: FTPControlConnection
  private let dataConnector: any FTPDataTransportConnecting
  private let timeout: Duration
  private(set) var usesLegacyListing = false

  var listingLimitationMessage: String? {
    usesLegacyListing
      ? "このFTPサーバーはMLSDに対応していないため、日時と権限の解釈が不完全な場合があります。"
      : nil
  }

  init(
    control: FTPControlConnection,
    dataConnector: any FTPDataTransportConnecting = NIOFTPDataTransportConnector(),
    timeout: Duration = .seconds(30)
  ) {
    self.control = control
    self.dataConnector = dataConnector
    self.timeout = timeout
  }

  func connect() async throws {
    try await control.connectAndLogin()
    let features = try await control.features()
    if features.contains(where: { $0 == "UTF8" || $0.hasPrefix("UTF8 ") }) {
      _ = try await control.enableUTF8IfSupported()
    }
  }

  func contents(of path: String) async throws -> [FTPDirectoryEntry] {
    if let data = try await fetchListing(command: "MLSD \(path)") {
      usesLegacyListing = false
      return try FTPDirectoryListingParser.parseMLSD(data)
    }
    guard let data = try await fetchListing(command: "LIST \(path)") else {
      throw FTPControlConnectionError.unexpectedReply(expected: "125/150", actual: 500)
    }
    usesLegacyListing = true
    return try FTPDirectoryListingParser.parseLegacyLIST(data)
  }

  private func fetchListing(command: String) async throws -> Data? {
    let endpoint = try await control.enterPassiveMode()
    let dataTransport = try await dataConnector.connect(to: endpoint, timeout: timeout)
    do {
      let reply = try await control.beginDataCommand(command)
      if reply.category == 5 {
        await dataTransport.close()
        return nil
      }
      guard reply.code == 125 || reply.code == 150 else {
        throw FTPControlConnectionError.unexpectedReply(
          expected: "125/150/5xx", actual: reply.code)
      }
      let data = try await dataTransport.readAll(
        timeout: timeout,
        maximumBytes: Self.maximumListingBytes)
      await dataTransport.close()
      _ = try await control.readTransferCompletion()
      return data
    } catch {
      await dataTransport.close()
      await control.abort()
      throw error
    }
  }
}
