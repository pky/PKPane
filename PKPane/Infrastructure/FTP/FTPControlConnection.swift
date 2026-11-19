import Foundation

protocol FTPControlTransport: Sendable {
  func writeLine(_ line: String) async throws
  func readLine(timeout: Duration) async throws -> String
  func upgradeToTLS(serverHostname: String, timeout: Duration) async throws
  func tlsSessionIdentifier() async -> Data?
  func close() async
}

extension FTPControlTransport {
  func upgradeToTLS(serverHostname _: String, timeout _: Duration) async throws {
    throw FTPControlConnectionError.secureTransportUnavailable
  }

  func tlsSessionIdentifier() async -> Data? { nil }
}

protocol FTPControlTransportConnecting: Sendable {
  func connect(host: String, port: Int, timeout: Duration) async throws
    -> any FTPControlTransport
}

enum FTPControlConnectionState: Equatable, Sendable {
  case disconnected
  case awaitingGreeting
  case ready
  case authenticated
  case closed
}

enum FTPControlConnectionError: LocalizedError, Equatable {
  case passwordNotFound
  case secureTransportUnavailable
  case invalidCommand
  case unexpectedReply(expected: String, actual: Int)
  case invalidWorkingDirectory
  case invalidPassiveReply

  var errorDescription: String? {
    switch self {
    case .passwordNotFound:
      "FTP接続用のパスワードが保存されていません。"
    case .secureTransportUnavailable:
      "FTPSの暗号化接続はまだ利用できません。"
    case .invalidCommand:
      "FTPコマンドに不正な文字が含まれています。"
    case .unexpectedReply:
      "FTPサーバーから予期しない応答を受信しました。"
    case .invalidWorkingDirectory:
      "FTPサーバーの現在位置を解釈できません。"
    case .invalidPassiveReply:
      "FTPサーバーのPassive Mode応答を解釈できません。"
    }
  }
}

struct FTPPassiveEndpoint: Equatable, Sendable {
  let host: String
  let port: Int
}

actor FTPControlConnection {
  private let target: FTPConnectionTarget
  private let passwordStore: FTPPasswordStore
  private let connector: any FTPControlTransportConnecting
  private let timeout: Duration
  private var transport: (any FTPControlTransport)?
  private var commandInProgress = false
  private enum CommandWaiter {
    case ordinary(CheckedContinuation<Void, Never>)
    case exclusive(UUID, CheckedContinuation<Void, Error>)

    func resume() {
      switch self {
      case .ordinary(let continuation): continuation.resume()
      case .exclusive(_, let continuation): continuation.resume()
      }
    }
  }
  private var commandWaiters: [CommandWaiter] = []
  private var dataTransferInProgress = false
  private var exclusiveLeaseID: UUID?
  private(set) var state: FTPControlConnectionState = .disconnected

  init(
    target: FTPConnectionTarget,
    passwordStore: FTPPasswordStore = FTPPasswordStore(),
    connector: any FTPControlTransportConnecting = NIOFTPControlTransportConnector(),
    timeout: Duration = .seconds(30)
  ) {
    self.target = target
    self.passwordStore = passwordStore
    self.connector = connector
    self.timeout = timeout
  }

  func connectAndLogin() async throws {
    guard state == .disconnected else { return }
    let connectedTransport = try await connector.connect(
      host: target.host,
      port: target.port,
      timeout: timeout)
    transport = connectedTransport
    state = .awaitingGreeting
    do {
      var greeting = try await readReply()
      if greeting.code == 120 {
        greeting = try await readReply()
      }
      try require(greeting, codes: [220], expected: "220")
      state = .ready
      if target.security == .explicitTLS {
        let authReply = try await performCommand("AUTH TLS")
        try require(authReply, codes: [234], expected: "234")
        try await connectedTransport.upgradeToTLS(
          serverHostname: target.host,
          timeout: timeout)
      }
      try await login()
      try await setBinaryType()
      if target.security == .explicitTLS {
        try await protectDataConnections()
      }
      if target.initialDirectory != "/" {
        try await changeWorkingDirectoryDuringConnection(to: target.initialDirectory)
      }
      state = .authenticated
    } catch {
      await connectedTransport.close()
      transport = nil
      state = .closed
      throw error
    }
  }

  func features() async throws -> Set<String> {
    let reply = try await command("FEAT")
    guard reply.code == 211 else { return [] }
    return Set(
      reply.lines.dropFirst().dropLast().compactMap { line in
        let feature = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return feature.isEmpty ? nil : feature.uppercased()
      })
  }

  func enableUTF8IfSupported() async throws -> Bool {
    let reply = try await command("OPTS UTF8 ON")
    if reply.code == 200 || reply.code == 202 { return true }
    if reply.category == 5 { return false }
    throw FTPControlConnectionError.unexpectedReply(expected: "200/202/5xx", actual: reply.code)
  }

  func tlsSessionIdentifier() async -> Data? {
    await transport?.tlsSessionIdentifier()
  }

  func workingDirectory() async throws -> String {
    let reply = try await command("PWD")
    try require(reply, codes: [257], expected: "257")
    guard let firstQuote = reply.message.firstIndex(of: "\"") else {
      throw FTPControlConnectionError.invalidWorkingDirectory
    }
    var index = reply.message.index(after: firstQuote)
    var result = ""
    while index < reply.message.endIndex {
      let character = reply.message[index]
      if character == "\"" {
        let next = reply.message.index(after: index)
        if next < reply.message.endIndex, reply.message[next] == "\"" {
          result.append("\"")
          index = reply.message.index(after: next)
          continue
        }
        return result
      }
      result.append(character)
      index = reply.message.index(after: index)
    }
    throw FTPControlConnectionError.invalidWorkingDirectory
  }

  func changeWorkingDirectory(to path: String) async throws {
    guard state == .authenticated else {
      throw FTPControlConnectionError.unexpectedReply(expected: "接続済み", actual: 0)
    }
    try await changeWorkingDirectoryDuringConnection(to: path)
  }

  private func changeWorkingDirectoryDuringConnection(to path: String) async throws {
    let reply = try await performCommand("CWD \(try sanitizedArgument(path))")
    try require(reply, codes: [250], expected: "250")
  }

  private func setBinaryType() async throws {
    let reply = try await performCommand("TYPE I")
    try require(reply, codes: [200], expected: "200")
  }

  private func protectDataConnections() async throws {
    let pbszReply = try await performCommand("PBSZ 0")
    try require(pbszReply, codes: [200], expected: "200")
    let protReply = try await performCommand("PROT P")
    try require(protReply, codes: [200], expected: "200")
  }

  func noop() async throws {
    let reply = try await command("NOOP")
    try require(reply, codes: [200], expected: "200")
  }

  func enterPassiveMode() async throws -> FTPPassiveEndpoint {
    try await passiveEndpoint { try await self.command($0) }
  }

  private func passiveEndpoint(
    command: @escaping @Sendable (String) async throws -> FTPReply
  ) async throws -> FTPPassiveEndpoint {
    let epsvReply = try await command("EPSV")
    if epsvReply.code == 229, let port = Self.epsvPort(from: epsvReply.message) {
      return FTPPassiveEndpoint(host: target.host, port: port)
    }
    guard epsvReply.category == 5 else {
      throw FTPControlConnectionError.unexpectedReply(expected: "229/5xx", actual: epsvReply.code)
    }
    let pasvReply = try await command("PASV")
    try require(pasvReply, codes: [227], expected: "227")
    guard let port = Self.pasvPort(from: pasvReply.message) else {
      throw FTPControlConnectionError.invalidPassiveReply
    }
    // PASV応答のホスト値はNAT越しで不正確・悪用可能なため、制御接続先を常に使う。
    return FTPPassiveEndpoint(host: target.host, port: port)
  }

  func quit() async {
    guard let transport else {
      state = .closed
      return
    }
    if state == .authenticated {
      _ = try? await command("QUIT")
    }
    await transport.close()
    self.transport = nil
    state = .closed
  }

  func command(_ command: String) async throws -> FTPReply {
    guard state == .authenticated else {
      throw FTPControlConnectionError.unexpectedReply(expected: "接続済み", actual: 0)
    }
    return try await performCommand(command)
  }

  /// CWD変更からデータ完了・CWD復元まで、専用転送のコマンドを一括で借りる。
  /// 失敗時は接続を閉じ、待機コマンドを誤った相対位置で実行させない。
  func withExclusiveCommandLease<Result: Sendable>(
    _ operation: @escaping @Sendable (FTPExclusiveCommandLease) async throws -> Result
  ) async throws -> Result {
    guard state == .authenticated else {
      throw FTPControlConnectionError.unexpectedReply(expected: "接続済み", actual: 0)
    }
    try await acquireExclusiveCommandSlot()
    defer {
      exclusiveLeaseID = nil
      releaseCommandSlot()
    }
    try Task.checkCancellation()
    guard state == .authenticated else {
      throw FTPControlConnectionError.unexpectedReply(expected: "接続済み", actual: 0)
    }
    let leaseID = UUID()
    exclusiveLeaseID = leaseID
    return try await withTaskCancellationHandler {
      do {
        return try await operation(FTPExclusiveCommandLease(connection: self, id: leaseID))
      } catch {
        await abort()
        throw error
      }
    } onCancel: {
      Task { await self.abortExclusiveLease(leaseID) }
    }
  }

  private func abortExclusiveLease(_ id: UUID) async {
    guard exclusiveLeaseID == id else { return }
    await abort()
  }

  fileprivate func exclusiveCommand(_ command: String, leaseID: UUID) async throws -> FTPReply {
    guard exclusiveLeaseID == leaseID else { throw FTPControlConnectionError.invalidCommand }
    return try await sendCommandHoldingSlot(command)
  }

  fileprivate func exclusivePassiveMode(leaseID: UUID) async throws -> FTPPassiveEndpoint {
    guard exclusiveLeaseID == leaseID else { throw FTPControlConnectionError.invalidCommand }
    return try await passiveEndpoint {
      try await self.exclusiveCommand($0, leaseID: leaseID)
    }
  }

  fileprivate func exclusiveTransferCompletion(leaseID: UUID) async throws -> FTPReply {
    guard exclusiveLeaseID == leaseID else { throw FTPControlConnectionError.invalidCommand }
    let reply = try await readReply()
    try require(reply, codes: [226, 250], expected: "226/250")
    return reply
  }

  /// RNFR/RNTOの間に別コマンドが割り込むとサーバー側のrename状態が壊れるため、
  /// 2応答を受け取るまで制御接続のコマンドスロットを保持する。
  func rename(from sourcePath: String, to destinationPath: String) async throws {
    guard state == .authenticated else {
      throw FTPControlConnectionError.unexpectedReply(expected: "接続済み", actual: 0)
    }
    await acquireCommandSlot()
    defer { releaseCommandSlot() }
    let fromReply = try await sendCommandHoldingSlot("RNFR \(sourcePath)")
    guard fromReply.code == 350 else {
      throw FTPControlConnectionError.unexpectedReply(expected: "350", actual: fromReply.code)
    }
    let toReply = try await sendCommandHoldingSlot("RNTO \(destinationPath)")
    guard toReply.code == 250 else {
      throw FTPControlConnectionError.unexpectedReply(expected: "250", actual: toReply.code)
    }
  }

  private func performCommand(_ command: String) async throws -> FTPReply {
    await acquireCommandSlot()
    defer { releaseCommandSlot() }
    return try await sendCommandHoldingSlot(command)
  }

  func beginDataCommand(_ command: String) async throws -> FTPReply {
    guard state == .authenticated else {
      throw FTPControlConnectionError.unexpectedReply(expected: "接続済み", actual: 0)
    }
    await acquireCommandSlot()
    do {
      let reply = try await sendCommandHoldingSlot(command)
      if reply.code == 125 || reply.code == 150 {
        dataTransferInProgress = true
      } else {
        releaseCommandSlot()
      }
      return reply
    } catch {
      releaseCommandSlot()
      throw error
    }
  }

  private func sendCommandHoldingSlot(_ command: String) async throws -> FTPReply {
    guard state == .ready || state == .authenticated, let transport else {
      throw FTPControlConnectionError.unexpectedReply(expected: "接続済み", actual: 0)
    }
    guard !command.isEmpty,
      !command.utf8.contains(where: { $0 == 0 || $0 == 10 || $0 == 13 })
    else {
      throw FTPControlConnectionError.invalidCommand
    }
    do {
      try Task.checkCancellation()
      try await transport.writeLine(command)
      return try await readReply()
    } catch {
      if error is CancellationError || error as? FTPTransportError == .timedOut {
        await transport.close()
        self.transport = nil
        state = .closed
      }
      throw error
    }
  }

  func readTransferCompletion() async throws -> FTPReply {
    guard dataTransferInProgress else {
      throw FTPControlConnectionError.unexpectedReply(expected: "転送中", actual: 0)
    }
    defer {
      dataTransferInProgress = false
      releaseCommandSlot()
    }
    let reply = try await readReply()
    try require(reply, codes: [226, 250], expected: "226/250")
    return reply
  }

  func abort() async {
    // closeのawait中に再入しても、閉鎖中の接続を次のcommandへ貸さない。
    let closingTransport = transport
    transport = nil
    state = .closed
    if dataTransferInProgress {
      dataTransferInProgress = false
      releaseCommandSlot()
    }
    await closingTransport?.close()
  }

  private func login() async throws {
    let userReply = try await performCommand("USER \(try sanitizedArgument(target.username))")
    if userReply.code == 230 {
      return
    }
    try require(userReply, codes: [331], expected: "230/331")
    guard let password = try passwordStore.password(for: target), !password.isEmpty else {
      throw FTPControlConnectionError.passwordNotFound
    }
    let passReply = try await performCommand("PASS \(try sanitizedArgument(password))")
    try require(passReply, codes: [230], expected: "230")
  }

  private func readReply() async throws -> FTPReply {
    guard let transport else {
      throw FTPControlConnectionError.unexpectedReply(expected: "接続済み", actual: 0)
    }
    var parser = FTPReplyParser()
    while true {
      try Task.checkCancellation()
      let line = try await transport.readLine(timeout: timeout)
      if let reply = try parser.append(line: line) {
        return reply
      }
    }
  }

  private func require(_ reply: FTPReply, codes: Set<Int>, expected: String) throws {
    guard codes.contains(reply.code) else {
      throw FTPControlConnectionError.unexpectedReply(expected: expected, actual: reply.code)
    }
  }

  private func sanitizedArgument(_ argument: String) throws -> String {
    guard !argument.utf8.contains(where: { $0 == 0 || $0 == 10 || $0 == 13 }) else {
      throw FTPControlConnectionError.invalidCommand
    }
    return argument
  }

  private func acquireCommandSlot() async {
    if !commandInProgress {
      commandInProgress = true
      return
    }
    await withCheckedContinuation { continuation in
      commandWaiters.append(.ordinary(continuation))
    }
  }

  /// 専用借用を待つ間の取消は、先行転送の終了を待たずに解除する。
  private func acquireExclusiveCommandSlot() async throws {
    try Task.checkCancellation()
    if !commandInProgress {
      commandInProgress = true
      return
    }
    let waiterID = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        commandWaiters.append(.exclusive(waiterID, continuation))
      }
    } onCancel: {
      Task { await self.cancelExclusiveWaiter(waiterID) }
    }
  }

  private func cancelExclusiveWaiter(_ id: UUID) {
    guard
      let index = commandWaiters.firstIndex(where: {
        if case .exclusive(let waiterID, _) = $0 { return waiterID == id }
        return false
      })
    else { return }
    if case .exclusive(_, let continuation) = commandWaiters.remove(at: index) {
      continuation.resume(throwing: CancellationError())
    }
  }

  private func releaseCommandSlot() {
    if commandWaiters.isEmpty {
      commandInProgress = false
    } else {
      commandWaiters.removeFirst().resume()
    }
  }

  nonisolated static func epsvPort(from message: String) -> Int? {
    guard let opening = message.firstIndex(of: "("),
      let closing = message[opening...].firstIndex(of: ")")
    else { return nil }
    let payload = message[message.index(after: opening)..<closing]
    guard let delimiter = payload.first else { return nil }
    let parts = payload.split(separator: delimiter, omittingEmptySubsequences: false)
    guard parts.count >= 5, let port = Int(parts[3]), (1...65_535).contains(port) else {
      return nil
    }
    return port
  }

  nonisolated static func pasvPort(from message: String) -> Int? {
    guard let opening = message.firstIndex(of: "("),
      let closing = message[opening...].firstIndex(of: ")")
    else { return nil }
    let numbers = message[message.index(after: opening)..<closing]
      .split(separator: ",")
      .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    guard numbers.count == 6,
      numbers.allSatisfy({ (0...255).contains($0) })
    else { return nil }
    let port = numbers[4] * 256 + numbers[5]
    return port == 0 ? nil : port
  }
}

/// 期限内だけ有効なコマンド借用。通常commandを呼んで二重にslotを取得しない。
struct FTPExclusiveCommandLease: Sendable {
  fileprivate let connection: FTPControlConnection
  fileprivate let id: UUID

  func command(_ command: String) async throws -> FTPReply {
    try await connection.exclusiveCommand(command, leaseID: id)
  }

  func enterPassiveMode() async throws -> FTPPassiveEndpoint {
    try await connection.exclusivePassiveMode(leaseID: id)
  }

  func readTransferCompletion() async throws -> FTPReply {
    try await connection.exclusiveTransferCompletion(leaseID: id)
  }
}
