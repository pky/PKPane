import Foundation
import Synchronization

protocol FTPClientSession: Sendable {
  func contents(of remotePath: String) async throws -> [FTPDirectoryEntry]
  func createDirectory(at remotePath: String) async throws
  func canonicalDirectoryPath(at remotePath: String) async throws -> String
  func createExclusiveDirectory(at remotePath: String) async throws -> String
  func remove(at remotePath: String, isDirectory: Bool) async throws
  func rename(at remotePath: String, to destinationPath: String) async throws
  func streamFileContents(
    of remotePath: String,
    receive: @escaping @Sendable (Data) async throws -> Void
  ) async throws
  func writeFileContents(
    to remotePath: String,
    chunks: AsyncThrowingStream<Data, Error>,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws
  func writeUniqueFileContents(
    in directoryPath: String,
    suggestedName: String?,
    chunks: @escaping @Sendable () -> AsyncThrowingStream<Data, Error>,
    reserved: @escaping @Sendable (String) async throws -> Void,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws -> String
  func fileSize(at remotePath: String) async throws -> Int64?
  func setPosixPermissions(_ permissions: Int, at remotePath: String) async throws
  func isActive() async -> Bool
  func close() async
}

extension FTPClientSession {
  func canonicalDirectoryPath(at _: String) async throws -> String {
    throw FTPUniqueCreationError.unsupported
  }

  func createExclusiveDirectory(at _: String) async throws -> String {
    throw FTPUniqueCreationError.unsupported
  }

  func writeUniqueFileContents(
    in _: String,
    suggestedName _: String?,
    chunks _: @escaping @Sendable () -> AsyncThrowingStream<Data, Error>,
    reserved _: @escaping @Sendable (String) async throws -> Void,
    progress _: @escaping @Sendable (Int64) -> Void
  ) async throws -> String {
    throw FTPUniqueCreationError.unsupported
  }
}

/// 不明な予約名を自作と見なして削除せず、作成先の確認を促す。
enum FTPUniqueCreationError: LocalizedError, Equatable, ReconnectFutileError {
  case unsupported
  case invalidDestination
  case creationOutcomeUnknown(directoryPath: String)

  var errorDescription: String? {
    switch self {
    case .unsupported:
      String(localized: "このFTPサーバーでは安全な別名作成を利用できません。")
    case .invalidDestination:
      String(localized: "この保存先の安全な実体パスを確認できません。")
    case .creationOutcomeUnknown(let path):
      String(localized: "別名作成の結果を確認できません。保存先「\(path)」に作成された項目を確認してください。")
    }
  }
}

protocol FTPConnecting: Sendable {
  func connect(to target: FTPConnectionTarget) async throws -> any FTPClientSession
}

enum FTPClientSessionError: LocalizedError, Equatable {
  case unexpectedReply(expected: String, actual: Int)
  case invalidSizeReply
  case permissionsUnavailable

  var errorDescription: String? {
    switch self {
    case .unexpectedReply:
      "FTPサーバーから予期しない応答を受信しました。"
    case .invalidSizeReply:
      "FTPサーバーのSIZE応答を解釈できません。"
    case .permissionsUnavailable:
      "このFTPサーバーではPOSIX権限を変更できません。"
    }
  }
}

struct FTPConnectionService: FTPConnecting, @unchecked Sendable {
  let passwordStore: FTPPasswordStore
  let controlConnector: any FTPControlTransportConnecting
  let dataConnector: any FTPDataTransportConnecting
  let timeout: Duration

  init(
    passwordStore: FTPPasswordStore = FTPPasswordStore(),
    controlConnector: any FTPControlTransportConnecting = NIOFTPControlTransportConnector(),
    dataConnector: any FTPDataTransportConnecting = NIOFTPDataTransportConnector(),
    timeout: Duration = .seconds(30)
  ) {
    self.passwordStore = passwordStore
    self.controlConnector = controlConnector
    self.dataConnector = dataConnector
    self.timeout = timeout
  }

  func connect(to target: FTPConnectionTarget) async throws -> any FTPClientSession {
    let control = FTPControlConnection(
      target: target,
      passwordStore: passwordStore,
      connector: controlConnector,
      timeout: timeout)
    try await control.connectAndLogin()
    let features = try await control.features()
    if features.contains(where: { $0 == "UTF8" || $0.hasPrefix("UTF8 ") }) {
      _ = try await control.enableUTF8IfSupported()
    }
    return FTPClientSessionAdapter(
      control: control,
      dataConnector: dataConnector,
      timeout: timeout,
      tlsServerHostname: target.security == .explicitTLS ? target.host : nil,
      tlsSessionIdentifier: await control.tlsSessionIdentifier())
  }
}

private actor FTPClientSessionAdapter: FTPClientSession {
  private static let maximumListingBytes = 256 * 1_024 * 1_024

  private let control: FTPControlConnection
  private let dataConnector: any FTPDataTransportConnecting
  private let timeout: Duration
  private let tlsServerHostname: String?
  private let tlsSessionIdentifier: Data?

  init(
    control: FTPControlConnection,
    dataConnector: any FTPDataTransportConnecting,
    timeout: Duration,
    tlsServerHostname: String?,
    tlsSessionIdentifier: Data?
  ) {
    self.control = control
    self.dataConnector = dataConnector
    self.timeout = timeout
    self.tlsServerHostname = tlsServerHostname
    self.tlsSessionIdentifier = tlsSessionIdentifier
  }

  func contents(of remotePath: String) async throws -> [FTPDirectoryEntry] {
    if let data = try await receiveData(
      command: "MLSD \(remotePath)",
      allowsUnsupported: true)
    {
      return try FTPDirectoryListingParser.parseMLSD(data)
    }
    guard let data = try await receiveData(command: "LIST \(remotePath)") else {
      throw FTPClientSessionError.unexpectedReply(expected: "125/150", actual: 500)
    }
    return try FTPDirectoryListingParser.parseLegacyLIST(data)
  }

  func createDirectory(at remotePath: String) async throws {
    try require(try await control.command("MKD \(remotePath)"), codes: [250, 257])
  }

  func canonicalDirectoryPath(at remotePath: String) async throws -> String {
    let requested = try FTPExclusiveReplyPath.directory(remotePath)
    return try await control.withExclusiveCommandLease { lease in
      let original = try FTPExclusiveReplyPath.directory(
        FTPExclusiveReplyPath.quotedPath(try await lease.command("PWD")))
      try self.require(try await lease.command("CWD " + requested), codes: [250])
      let canonical = try FTPExclusiveReplyPath.directory(
        FTPExclusiveReplyPath.quotedPath(try await lease.command("PWD")))
      try Task.checkCancellation()
      try self.require(try await lease.command("CWD " + original), codes: [250])
      try Task.checkCancellation()
      return canonical
    }
  }

  func createExclusiveDirectory(at remotePath: String) async throws -> String {
    let (parent, name) = try FTPExclusiveReplyPath.splitRequestedPath(remotePath)
    let state = FTPExclusiveCreationState()
    do {
      return try await control.withExclusiveCommandLease { lease in
        let original = try FTPExclusiveReplyPath.directory(
          FTPExclusiveReplyPath.quotedPath(try await lease.command("PWD")))
        try self.require(try await lease.command("CWD " + parent), codes: [250])
        let actualParent = try FTPExclusiveReplyPath.directory(
          FTPExclusiveReplyPath.quotedPath(try await lease.command("PWD")))
        guard actualParent.utf8.elementsEqual(parent.utf8) else {
          throw FTPUniqueCreationError.invalidDestination
        }
        state.markCreationSent()
        let reply = try await lease.command("MKD " + name)
        if reply.category == 5 {
          state.markRejected()
          if reply.code == 500 || reply.code == 502 { throw FTPUniqueCreationError.unsupported }
          try self.require(reply, codes: [257])
        }
        let created = try FTPExclusiveReplyPath.createdDirectory(reply, parent: parent)
        state.markConfirmed()
        // 返却前のCWD復元失敗でも作成済みの可能性を捨てない。
        state.markAwaitingCompletion()
        try Task.checkCancellation()
        try self.require(try await lease.command("CWD " + original), codes: [250])
        try Task.checkCancellation()
        return created
      }
    } catch {
      if state.outcomeIsUnknown {
        throw FTPUniqueCreationError.creationOutcomeUnknown(directoryPath: parent)
      }
      throw error
    }
  }

  func writeUniqueFileContents(
    in directoryPath: String,
    suggestedName: String?,
    chunks: @escaping @Sendable () -> AsyncThrowingStream<Data, Error>,
    reserved: @escaping @Sendable (String) async throws -> Void,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws -> String {
    let parent = try FTPExclusiveReplyPath.directory(directoryPath)
    if let suggestedName { try FTPExclusiveReplyPath.validateComponent(suggestedName) }
    let state = FTPExclusiveCreationState()
    let connector = dataConnector
    let timeout = timeout
    let hostname = tlsServerHostname
    let tlsIdentifier = tlsSessionIdentifier
    return try await withTaskCancellationHandler {
      do {
        return try await control.withExclusiveCommandLease { lease in
          let original = try FTPExclusiveReplyPath.directory(
            FTPExclusiveReplyPath.quotedPath(try await lease.command("PWD")))
          try self.require(try await lease.command("CWD " + parent), codes: [250])
          let actualParent = try FTPExclusiveReplyPath.directory(
            FTPExclusiveReplyPath.quotedPath(try await lease.command("PWD")))
          guard actualParent.utf8.elementsEqual(parent.utf8) else {
            throw FTPUniqueCreationError.invalidDestination
          }
          let endpoint = try await lease.enterPassiveMode()
          let data = try await connector.connect(
            to: endpoint, timeout: timeout,
            tlsServerHostname: hostname, tlsSessionIdentifier: tlsIdentifier)
          state.setTransport(data)
          do {
            try Task.checkCancellation()
            state.markCreationSent()
            // 引数なしが標準。hint付きは拡張で、返却実名を高層が確認してから送る。
            let command = suggestedName.map { "STOU " + $0 } ?? "STOU"
            let reply = try await lease.command(command)
            if reply.category == 5 {
              state.markRejected()
              if reply.code == 500 || reply.code == 502 { throw FTPUniqueCreationError.unsupported }
              try self.require(reply, codes: [125, 150])
            }
            let created = try FTPExclusiveReplyPath.uniqueFile(reply, parent: parent)
            state.markConfirmed()
            try await reserved(created)
            try Task.checkCancellation()
            try await data.writeChunks(chunks(), progress: progress)
            try Task.checkCancellation()
            await data.close()
            state.markAwaitingCompletion()
            _ = try await lease.readTransferCompletion()
            try Task.checkCancellation()
            try self.require(try await lease.command("CWD " + original), codes: [250])
            try Task.checkCancellation()
            return created
          } catch {
            await data.close()
            throw error
          }
        }
      } catch {
        if state.outcomeIsUnknown {
          throw FTPUniqueCreationError.creationOutcomeUnknown(directoryPath: parent)
        }
        throw error
      }
    } onCancel: {
      Task { await state.transport?.close() }
    }
  }

  func remove(at remotePath: String, isDirectory: Bool) async throws {
    try require(
      try await control.command("\(isDirectory ? "RMD" : "DELE") \(remotePath)"),
      codes: [250])
  }

  func rename(at remotePath: String, to destinationPath: String) async throws {
    try await control.rename(from: remotePath, to: destinationPath)
  }

  func streamFileContents(
    of remotePath: String,
    receive: @escaping @Sendable (Data) async throws -> Void
  ) async throws {
    let dataTransport = try await openDataTransport()
    do {
      try require(try await control.beginDataCommand("RETR \(remotePath)"), codes: [125, 150])
      try await dataTransport.readChunks(timeout: timeout, receive: receive)
      await dataTransport.close()
      _ = try await control.readTransferCompletion()
    } catch {
      await dataTransport.close()
      await control.abort()
      throw error
    }
  }

  func writeFileContents(
    to remotePath: String,
    chunks: AsyncThrowingStream<Data, Error>,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws {
    let dataTransport = try await openDataTransport()
    do {
      try require(try await control.beginDataCommand("STOR \(remotePath)"), codes: [125, 150])
      try await dataTransport.writeChunks(chunks, progress: progress)
      await dataTransport.close()
      _ = try await control.readTransferCompletion()
    } catch {
      await dataTransport.close()
      await control.abort()
      throw error
    }
  }

  func fileSize(at remotePath: String) async throws -> Int64? {
    let reply = try await control.command("SIZE \(remotePath)")
    if reply.code == 550 { return nil }
    try require(reply, codes: [213])
    guard let size = Int64(reply.message.trimmingCharacters(in: .whitespacesAndNewlines)) else {
      throw FTPClientSessionError.invalidSizeReply
    }
    return size
  }

  func setPosixPermissions(_ permissions: Int, at remotePath: String) async throws {
    let mode = String(format: "%04o", PosixPermissions.normalizedMode(permissions))
    let reply = try await control.command("SITE CHMOD \(mode) \(remotePath)")
    if reply.category == 5 { throw FTPClientSessionError.permissionsUnavailable }
    try require(reply, codes: [200, 250])
  }

  func isActive() async -> Bool {
    await control.state == .authenticated
  }

  func close() async {
    await control.quit()
  }

  private func receiveData(command: String, allowsUnsupported: Bool = false) async throws
    -> Data?
  {
    let dataTransport = try await openDataTransport()
    do {
      let reply = try await control.beginDataCommand(command)
      if allowsUnsupported, reply.category == 5 {
        await dataTransport.close()
        return nil
      }
      try require(reply, codes: [125, 150])
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

  private func openDataTransport() async throws -> any FTPDataTransport {
    let endpoint = try await control.enterPassiveMode()
    return try await dataConnector.connect(
      to: endpoint,
      timeout: timeout,
      tlsServerHostname: tlsServerHostname,
      tlsSessionIdentifier: tlsSessionIdentifier)
  }

  private nonisolated func require(_ reply: FTPReply, codes: Set<Int>) throws {
    guard codes.contains(reply.code) else {
      throw FTPClientSessionError.unexpectedReply(
        expected: codes.sorted().map(String.init).joined(separator: "/"),
        actual: reply.code)
    }
  }
}

/// 予約応答と返却pathを、名前の空白を変更せずに検証する。
private enum FTPExclusiveReplyPath {
  static func validateComponent(_ name: String) throws {
    guard !name.isEmpty, name != ".", name != "..",
      !name.utf8.contains(where: { $0 == 0 || $0 == 10 || $0 == 13 || $0 == 47 || $0 == 92 })
    else { throw FTPUniqueCreationError.invalidDestination }
  }

  static func directory(_ path: String) throws -> String {
    guard path.hasPrefix("/"),
      !path.utf8.contains(where: { $0 == 0 || $0 == 10 || $0 == 13 || $0 == 92 })
    else { throw FTPUniqueCreationError.invalidDestination }
    var normalized = path
    while normalized.count > 1, normalized.hasSuffix("/") { normalized.removeLast() }
    if normalized != "/" {
      for part in normalized.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
        try validateComponent(String(part))
      }
    }
    return normalized
  }

  static func splitRequestedPath(_ path: String) throws -> (String, String) {
    guard let slash = path.lastIndex(of: "/") else {
      throw FTPUniqueCreationError.invalidDestination
    }
    let name = String(path[path.index(after: slash)...])
    try validateComponent(name)
    let parent = slash == path.startIndex ? "/" : String(path[..<slash])
    return (try directory(parent), name)
  }

  static func quotedPath(_ reply: FTPReply) throws -> String {
    guard reply.code == 257, reply.lines.count == 1,
      let message = reply.lines.first, message.first == "\""
    else { throw FTPUniqueCreationError.invalidDestination }
    var index = message.index(after: message.startIndex)
    var path = ""
    while index < message.endIndex {
      let character = message[index]
      let next = message.index(after: index)
      if character == "\"" {
        if next < message.endIndex, message[next] == "\"" {
          path.append("\"")
          index = message.index(after: next)
          continue
        }
        guard next == message.endIndex || message[next] == " " else {
          throw FTPUniqueCreationError.invalidDestination
        }
        return path
      }
      path.append(character)
      index = next
    }
    throw FTPUniqueCreationError.invalidDestination
  }

  static func createdDirectory(_ reply: FTPReply, parent: String) throws -> String {
    try resolvedChild(quotedPath(reply), parent: parent)
  }

  static func uniqueFile(_ reply: FTPReply, parent: String) throws -> String {
    guard reply.code == 125 || reply.code == 150, reply.lines.count == 1,
      let message = reply.lines.first, message.hasPrefix("FILE: ")
    else { throw FTPUniqueCreationError.invalidDestination }
    let path = String(message.dropFirst(6))
    // STOUには引用規則が無い。引用文字を除いて別の名前へ推測変換しない。
    guard !path.hasPrefix("\""), !path.hasSuffix("\"") else {
      throw FTPUniqueCreationError.invalidDestination
    }
    return try resolvedChild(path, parent: parent)
  }

  private static func resolvedChild(_ rawPath: String, parent: String) throws -> String {
    let name: String
    if rawPath.hasPrefix("/") {
      let (returnedParent, component) = try splitRequestedPath(rawPath)
      guard returnedParent.utf8.elementsEqual(parent.utf8) else {
        throw FTPUniqueCreationError.invalidDestination
      }
      name = component
    } else {
      name = rawPath.hasPrefix("./") ? String(rawPath.dropFirst(2)) : rawPath
      try validateComponent(name)
    }
    return parent == "/" ? "/" + name : parent + "/" + name
  }
}

/// 回答喪失と既知の拒否を区別する。所有pathの削除は高層が接続状態と併せて判断する。
private final class FTPExclusiveCreationState: Sendable {
  private struct State {
    var transport: (any FTPDataTransport)?
    var creationSent = false
    var rejected = false
    var confirmed = false
    var awaitingCompletion = false
  }
  private let state = Mutex(State())

  var transport: (any FTPDataTransport)? { state.withLock { $0.transport } }
  var outcomeIsUnknown: Bool {
    state.withLock { $0.creationSent && !$0.rejected && (!$0.confirmed || $0.awaitingCompletion) }
  }
  func setTransport(_ transport: any FTPDataTransport) {
    state.withLock { $0.transport = transport }
  }
  func markCreationSent() { state.withLock { $0.creationSent = true } }
  func markRejected() { state.withLock { $0.rejected = true } }
  func markConfirmed() { state.withLock { $0.confirmed = true } }
  func markAwaitingCompletion() { state.withLock { $0.awaitingCompletion = true } }
}
