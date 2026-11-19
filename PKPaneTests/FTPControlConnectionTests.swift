import Foundation
import Testing

@testable import PKPane

struct FTPControlConnectionTests {
  @Test("ログイン後にバイナリモードと開始フォルダを設定する")
  func connectsAndLogsIn() async throws {
    let transport = FTPRecordingControlTransport(responses: [
      "220 ready", "331 password required", "230 logged in", "200 binary", "250 changed",
    ])
    let target = try FTPConnectionTarget(
      host: "example.com", username: "tester", initialDirectory: "/incoming", security: .plain)
    let keychain = FTPControlKeychainStore(password: "secret")
    let connection = FTPControlConnection(
      target: target,
      passwordStore: FTPPasswordStore(keychain: keychain),
      connector: FTPRecordingControlConnector(transport: transport))

    try await connection.connectAndLogin()

    #expect(await connection.state == .authenticated)
    #expect(
      await transport.commands == [
        "USER tester", "PASS secret", "TYPE I", "CWD /incoming",
      ])
  }

  @Test("FEAT、UTF8、PWD、NOOP、QUITを同じ制御接続で処理する")
  func executesControlCommands() async throws {
    let transport = FTPRecordingControlTransport(responses: [
      "220 ready", "230 logged in", "200 binary",
      "211-Features", " UTF8", " MLST type*;size*;", "211 End",
      "200 UTF8 enabled", "257 \"/a\"\"b\" current", "200 alive", "221 bye",
    ])
    let target = try FTPConnectionTarget(
      host: "example.com", username: "anonymous", security: .plain)
    let connection = FTPControlConnection(
      target: target,
      passwordStore: FTPPasswordStore(keychain: FTPControlKeychainStore(password: "unused")),
      connector: FTPRecordingControlConnector(transport: transport))
    try await connection.connectAndLogin()

    let features = try await connection.features()
    let enabled = try await connection.enableUTF8IfSupported()
    let directory = try await connection.workingDirectory()
    try await connection.noop()
    await connection.quit()

    #expect(features == ["UTF8", "MLST TYPE*;SIZE*;"])
    #expect(enabled)
    #expect(directory == "/a\"b")
    #expect(await connection.state == .closed)
    #expect(await transport.isClosed)
  }

  @Test("EPSVを優先し、非対応時だけPASVへ戻して応答内ホストを無視する")
  func negotiatesPassiveMode() async throws {
    let epsvTransport = FTPRecordingControlTransport(responses: [
      "220 ready", "230 logged in", "200 binary", "229 Entering Extended Passive Mode (|||6446|)",
    ])
    let target = try FTPConnectionTarget(
      host: "control.example.com", username: "anonymous", security: .plain)
    let epsvConnection = FTPControlConnection(
      target: target,
      passwordStore: FTPPasswordStore(keychain: FTPControlKeychainStore(password: "unused")),
      connector: FTPRecordingControlConnector(transport: epsvTransport))
    try await epsvConnection.connectAndLogin()

    #expect(
      try await epsvConnection.enterPassiveMode()
        == FTPPassiveEndpoint(
          host: "control.example.com", port: 6446))

    let pasvTransport = FTPRecordingControlTransport(responses: [
      "220 ready", "230 logged in", "200 binary", "500 EPSV unsupported",
      "227 Entering Passive Mode (10,0,0,1,19,136)",
    ])
    let pasvConnection = FTPControlConnection(
      target: target,
      passwordStore: FTPPasswordStore(keychain: FTPControlKeychainStore(password: "unused")),
      connector: FTPRecordingControlConnector(transport: pasvTransport))
    try await pasvConnection.connectAndLogin()

    #expect(
      try await pasvConnection.enterPassiveMode()
        == FTPPassiveEndpoint(
          host: "control.example.com", port: 5_000))
    #expect(await pasvTransport.commands.suffix(2) == ["EPSV", "PASV"])
  }

  @Test("コマンド引数への改行注入を送信前に拒否する")
  func rejectsCommandInjection() async throws {
    let transport = FTPRecordingControlTransport(responses: [
      "220 ready", "230 logged in", "200 binary",
    ])
    let target = try FTPConnectionTarget(
      host: "example.com", username: "anonymous", security: .plain)
    let connection = FTPControlConnection(
      target: target,
      passwordStore: FTPPasswordStore(keychain: FTPControlKeychainStore(password: "unused")),
      connector: FTPRecordingControlConnector(transport: transport))
    try await connection.connectAndLogin()

    await #expect(throws: FTPControlConnectionError.invalidCommand) {
      try await connection.changeWorkingDirectory(to: "/safe\r\nDELE victim")
    }
  }

  @Test("明示的FTPSはAUTH TLS後に認証しデータ接続も保護する")
  func negotiatesExplicitTLSBeforeCredentials() async throws {
    let transport = FTPRecordingControlTransport(responses: [
      "220 ready", "234 begin TLS", "331 password required", "230 logged in", "200 binary",
      "200 PBSZ accepted", "200 private data",
    ])
    let target = try FTPConnectionTarget(host: "example.com", username: "tester")
    let connection = FTPControlConnection(
      target: target,
      passwordStore: FTPPasswordStore(keychain: FTPControlKeychainStore(password: "secret")),
      connector: FTPRecordingControlConnector(transport: transport))

    try await connection.connectAndLogin()

    #expect(
      await transport.commands == [
        "AUTH TLS", "USER tester", "PASS secret", "TYPE I", "PBSZ 0", "PROT P",
      ])
    #expect(await transport.tlsServerHostnames == ["example.com"])
    #expect(await connection.state == .authenticated)
  }

  @Test("TLS証明書検証失敗時は資格情報を送信しない")
  func stopsBeforeCredentialsWhenTLSValidationFails() async throws {
    let transport = FTPRecordingControlTransport(
      responses: ["220 ready", "234 begin TLS"],
      tlsError: .tlsHostnameValidationFailed)
    let target = try FTPConnectionTarget(host: "example.com", username: "tester")
    let connection = FTPControlConnection(
      target: target,
      passwordStore: FTPPasswordStore(keychain: FTPControlKeychainStore(password: "secret")),
      connector: FTPRecordingControlConnector(transport: transport))

    await #expect(throws: FTPTransportError.self) {
      try await connection.connectAndLogin()
    }
    #expect(await transport.commands == ["AUTH TLS"])
    #expect(await transport.isClosed)
  }

  @Test("応答タイムアウト時は制御接続を閉じて後続コマンドを防ぐ")
  func closesAfterTimeout() async throws {
    let transport = FTPFailingControlTransport()
    let target = try FTPConnectionTarget(
      host: "example.com", username: "anonymous", security: .plain)
    let connection = FTPControlConnection(
      target: target,
      passwordStore: FTPPasswordStore(keychain: FTPControlKeychainStore(password: "unused")),
      connector: FTPFailingControlConnector(transport: transport))
    try await connection.connectAndLogin()

    await #expect(throws: FTPTransportError.timedOut) {
      try await connection.noop()
    }

    #expect(await connection.state == .closed)
    #expect(await transport.isClosed)
  }
}

private struct FTPRecordingControlConnector: FTPControlTransportConnecting {
  let transport: FTPRecordingControlTransport

  func connect(host _: String, port _: Int, timeout _: Duration) async throws
    -> any FTPControlTransport
  {
    transport
  }
}

private actor FTPRecordingControlTransport: FTPControlTransport {
  private var responses: [String]
  private let tlsError: FTPTransportError?
  private(set) var commands: [String] = []
  private(set) var tlsServerHostnames: [String] = []
  private(set) var isClosed = false

  init(responses: [String], tlsError: FTPTransportError? = nil) {
    self.responses = responses
    self.tlsError = tlsError
  }

  func writeLine(_ line: String) async throws {
    commands.append(line)
  }

  func readLine(timeout _: Duration) async throws -> String {
    guard !responses.isEmpty else { throw FTPControlTestError.missingResponse }
    return responses.removeFirst()
  }

  func upgradeToTLS(serverHostname: String, timeout _: Duration) async throws {
    tlsServerHostnames.append(serverHostname)
    if let tlsError { throw tlsError }
  }

  func close() async {
    isClosed = true
  }
}

private struct FTPFailingControlConnector: FTPControlTransportConnecting {
  let transport: FTPFailingControlTransport

  func connect(host _: String, port _: Int, timeout _: Duration) async throws
    -> any FTPControlTransport
  {
    transport
  }
}

private actor FTPFailingControlTransport: FTPControlTransport {
  private var responses = ["220 ready", "230 logged in", "200 binary"]
  private(set) var isClosed = false

  func writeLine(_: String) async throws {}

  func readLine(timeout _: Duration) async throws -> String {
    guard !responses.isEmpty else { throw FTPTransportError.timedOut }
    return responses.removeFirst()
  }

  func close() async {
    isClosed = true
  }
}

private final class FTPControlKeychainStore: KeychainPasswordDataStoring {
  let storedPassword: String?

  init(password: String?) {
    storedPassword = password
  }

  func save(password _: String, service _: String, account _: String) throws {}

  func password(service _: String, account _: String) throws -> String? {
    storedPassword
  }
}

private enum FTPControlTestError: Error {
  case missingResponse
}
