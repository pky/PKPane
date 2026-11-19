import Foundation

@preconcurrency import SMBClient

/// 直接SMB転送で接続する共有と資格情報です。
struct SMBDirectTransferTarget: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  let host: String
  let shareName: String
  let credentials: SMBDirectCredentials

  var description: String {
    "host: \(host), shareName: \(shareName), credentials: \(credentials)"
  }

  var debugDescription: String { description }
}

/// SMBClientの非Sendableな実装を隔離する、転送専用のSendable境界です。
protocol SMBDirectTransferClient: Sendable {
  func fileSize(at path: String) async throws -> UInt64
  func fileExists(at path: String) async throws -> Bool
  func read(at path: String, offset: UInt64, length: Int) async throws -> Data
  func prepareDestination(at path: String, replacingExisting: Bool) async throws
  func openDestination(at path: String) async throws
  func write(_ data: Data, at offset: UInt64) async throws -> Int
  func renameFile(from temporaryPath: String, to destinationPath: String) async throws
  func deleteFile(at path: String) async throws
  func maximumWriteSize() async -> Int
  func close() async
}

protocol SMBDirectTransferClientFactory: Sendable {
  func connect() async throws -> any SMBDirectTransferClient
}

/// 接続確立時だけを通常のマウント経由転送へフォールバックできるよう示すエラーです。
enum SMBDirectTransferError: LocalizedError, Equatable {
  case connectionFailed
  case invalidChunkSize
  case unexpectedEndOfFile
  case invalidWriteResponse
  case internalConsistencyFailure
  case commitRollbackFailed(backupFileName: String)

  var errorDescription: String? {
    switch self {
    case .connectionFailed:
      "直接SMB接続を確立できませんでした。"
    case .invalidChunkSize:
      "SMB転送のチャンクサイズが不正です。"
    case .unexpectedEndOfFile:
      "SMBファイルの読み取りが途中で終了しました。"
    case .invalidWriteResponse:
      "SMB書き込みの応答が不正です。"
    case .internalConsistencyFailure:
      "SMB直接転送の内部状態が不整合です。"
    case .commitRollbackFailed(let backupFileName):
      "ファイルの置換と復元に失敗しました。元のファイルは「\(backupFileName)」として残っています。"
    }
  }
}

/// 非SendableなSMBClientをactor内部に閉じ込める実接続です。
private actor SMBDirectTransferConnection: SMBDirectTransferClient {
  private let client: SMBClient
  private var destinationFileID: Data?
  // FileReaderはactor内だけで一意に利用し、非SendableなSMBClientの外へ出しません。
  private var reader: FileReader?
  private var readerPath: String?

  init(client: SMBClient) {
    self.client = client
  }

  func fileSize(at path: String) async throws -> UInt64 {
    let reader = try await fileReader(at: path)
    return try await reader.fileSize
  }

  func fileExists(at path: String) async throws -> Bool {
    try await client.existFile(path: path)
  }

  func read(at path: String, offset: UInt64, length: Int) async throws -> Data {
    let reader = try await fileReader(at: path)
    return try await reader.read(offset: offset, length: UInt32(length))
  }

  func prepareDestination(at path: String, replacingExisting: Bool) async throws {
    if try await client.existFile(path: path) {
      guard replacingExisting else { throw CocoaError(.fileWriteFileExists) }
      try await client.deleteFile(path: path)
    }
    let response = try await client.session.create(
      desiredAccess: [.writeData, .readAttributes],
      fileAttributes: [.archive, .normal],
      shareAccess: [.read, .write, .delete],
      createDisposition: .overwriteIf,
      createOptions: [],
      name: createPath(from: path)
    )
    _ = try await client.session.close(fileId: response.fileId)
  }

  func openDestination(at path: String) async throws {
    let response = try await client.session.create(
      desiredAccess: [.writeData, .readAttributes],
      fileAttributes: [.archive, .normal],
      shareAccess: [.read, .write, .delete],
      createDisposition: .openIf,
      createOptions: [],
      name: createPath(from: path)
    )
    destinationFileID = response.fileId
  }

  func write(_ data: Data, at offset: UInt64) async throws -> Int {
    guard let destinationFileID else { throw SMBDirectTransferError.internalConsistencyFailure }
    let response = try await client.session.write(
      data: data,
      fileId: destinationFileID,
      offset: offset)
    return Int(response.count)
  }

  func renameFile(from temporaryPath: String, to destinationPath: String) async throws {
    try await client.rename(from: temporaryPath, to: destinationPath)
  }

  func deleteFile(at path: String) async throws {
    do {
      try await client.deleteFile(path: path)
    } catch let error as ErrorResponse where NTStatus(error.header.status) == .objectNameNotFound {
      return
    }
  }

  func maximumWriteSize() async -> Int {
    Int(client.session.maxWriteSize)
  }

  func close() async {
    if let reader {
      try? await reader.close()
      self.reader = nil
      readerPath = nil
    }
    if let destinationFileID {
      _ = try? await client.session.close(fileId: destinationFileID)
      self.destinationFileID = nil
    }
    _ = try? await client.disconnectShare()
    _ = try? await client.logoff()
    client.session.disconnect()
  }

  private func fileReader(at path: String) async throws -> FileReader {
    if let reader, readerPath == path { return reader }
    if let reader {
      try await reader.close()
      self.reader = nil
      readerPath = nil
    }
    let reader = client.fileReader(path: path)
    self.reader = reader
    readerPath = path
    return reader
  }

  private func createPath(from path: String) -> String {
    path
      .replacingOccurrences(of: "/", with: "\\")
      .precomposedStringWithCanonicalMapping
  }
}

private struct SMBDirectTransferConnectionFactory: SMBDirectTransferClientFactory {
  let target: SMBDirectTransferTarget

  func connect() async throws -> any SMBDirectTransferClient {
    do {
      let client = SMBClient(host: target.host)
      // SMBClientはこのactor所有の接続へ一意にmoveし、以後actor隔離でのみ使用します。
      _ = try await client.login(
        username: target.credentials.account,
        password: target.credentials.password)
      _ = try await client.connectShare(target.shareName)
      return SMBDirectTransferConnection(client: client)
    } catch {
      throw SMBDirectTransferError.connectionFailed
    }
  }
}

/// マウント済みNASの転送データ面を直接SMB接続で実行するactorです。
actor SMBDirectTransferEngine {
  private static let readConnectionCount = 8
  private static let writeConnectionCount = 2

  private let factory: any SMBDirectTransferClientFactory

  init(target: SMBDirectTransferTarget) {
    factory = SMBDirectTransferConnectionFactory(target: target)
  }

  init(factory: any SMBDirectTransferClientFactory) {
    self.factory = factory
  }

  /// フォールバック可能な接続失敗を、転送ストリーム開始前に確定します。
  func prepareForTransfer() async throws {
    let connection = try await factory.connect()
    await connection.close()
  }

  func fileChunks(
    at path: String,
    chunkSize: Int,
    rateLimiter: TransferRateLimiter? = nil
  ) -> AsyncThrowingStream<Data, Error> {
    let engine = self
    let limit = max(4, (4 * 1_048_576) / max(chunkSize, 1))
    return BoundedChunkPipe.stream(limit: limit, rateLimiter: rateLimiter) { yield in
      try await engine.readFile(at: path, chunkSize: chunkSize, receive: yield)
    }
  }

  func writeFileChunks(
    _ chunks: AsyncThrowingStream<Data, Error>,
    to path: String,
    replacingExisting: Bool,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws {
    var connections: [any SMBDirectTransferClient] = []
    do {
      connections.append(try await factory.connect())
      try await connections[0].prepareDestination(at: path, replacingExisting: replacingExisting)
      while connections.count < Self.writeConnectionCount {
        connections.append(try await factory.connect())
      }
      for connection in connections {
        try await connection.openDestination(at: path)
      }
      try await write(
        chunks: chunks,
        connections: connections,
        progress: progress)
    } catch {
      for connection in connections { await connection.close() }
      throw error
    }
    for connection in connections { await connection.close() }
  }

  func statFile(at path: String) async throws -> UInt64 {
    let connection = try await factory.connect()
    do {
      let size = try await connection.fileSize(at: path)
      await connection.close()
      return size
    } catch {
      await connection.close()
      throw error
    }
  }

  func commitFile(
    temporaryPath: String,
    destinationPath: String,
    replacingExisting: Bool,
    backupCleanup: (@Sendable (String) async -> Void)? = nil
  ) async throws {
    let connection = try await factory.connect()
    do {
      let destinationExists = try await connection.fileExists(at: destinationPath)
      if !replacingExisting, destinationExists {
        throw CocoaError(.fileWriteFileExists)
      }

      let backupPath: String?
      if destinationExists {
        let path = destinationPath + ".pkpane-replaced-" + UUID().uuidString
        try await connection.renameFile(from: destinationPath, to: path)
        backupPath = path
      } else {
        backupPath = nil
      }

      do {
        try await connection.renameFile(from: temporaryPath, to: destinationPath)
      } catch {
        if let backupPath {
          do {
            try await connection.renameFile(from: backupPath, to: destinationPath)
          } catch {
            throw SMBDirectTransferError.commitRollbackFailed(
              backupFileName: backupPath)
          }
        }
        throw error
      }

      if let backupPath {
        do {
          try await connection.deleteFile(at: backupPath)
        } catch {
          await backupCleanup?(backupPath)
        }
      }
      await connection.close()
    } catch {
      await connection.close()
      throw error
    }
  }

  func deleteFile(at path: String) async throws {
    let connection = try await factory.connect()
    do {
      try await connection.deleteFile(at: path)
      await connection.close()
    } catch {
      await connection.close()
      throw error
    }
  }

  private func readFile(
    at path: String,
    chunkSize: Int,
    receive: @escaping @Sendable (Data) async throws -> Void
  ) async throws {
    guard chunkSize > 0, chunkSize <= Int(UInt32.max) else {
      throw SMBDirectTransferError.invalidChunkSize
    }
    let metadataConnection = try await factory.connect()
    let size: UInt64
    do {
      size = try await metadataConnection.fileSize(at: path)
      await metadataConnection.close()
    } catch {
      await metadataConnection.close()
      throw error
    }
    guard size > 0 else { return }

    let chunkCount = Int((size + UInt64(chunkSize) - 1) / UInt64(chunkSize))
    let connectionCount = min(Self.readConnectionCount, chunkCount)
    var connections: [any SMBDirectTransferClient] = []
    do {
      for _ in 0..<connectionCount {
        connections.append(try await factory.connect())
      }
      try await read(
        path: path,
        size: size,
        chunkSize: chunkSize,
        connections: connections,
        receive: receive)
    } catch {
      for connection in connections { await connection.close() }
      throw error
    }
    for connection in connections { await connection.close() }
  }

  private func read(
    path: String,
    size: UInt64,
    chunkSize: Int,
    connections: [any SMBDirectTransferClient],
    receive: @escaping @Sendable (Data) async throws -> Void
  ) async throws {
    try await withThrowingTaskGroup(of: (Int, UInt64, Int, Data).self) { group in
      var issuedOffset: UInt64 = 0
      var deliverOffset: UInt64 = 0
      var pending: [UInt64: Data] = [:]
      var inFlight = 0

      func issue(_ connectionIndex: Int, offset: UInt64, length: Int) {
        let connection = connections[connectionIndex]
        group.addTask {
          let data = try await connection.read(at: path, offset: offset, length: length)
          return (connectionIndex, offset, length, data)
        }
        inFlight += 1
      }

      func issueNext(_ connectionIndex: Int) {
        guard issuedOffset < size else { return }
        let length = Int(min(UInt64(chunkSize), size - issuedOffset))
        issue(connectionIndex, offset: issuedOffset, length: length)
        issuedOffset += UInt64(length)
      }

      for index in connections.indices { issueNext(index) }
      while inFlight > 0 {
        try Task.checkCancellation()
        guard let (connectionIndex, offset, requestedLength, data) = try await group.next() else {
          throw SMBDirectTransferError.unexpectedEndOfFile
        }
        inFlight -= 1
        guard !data.isEmpty, data.count <= requestedLength else {
          throw SMBDirectTransferError.unexpectedEndOfFile
        }
        pending[offset] = data

        while let next = pending.removeValue(forKey: deliverOffset) {
          try await receive(next)
          deliverOffset += UInt64(next.count)
        }
        if data.count < requestedLength {
          issue(
            connectionIndex,
            offset: offset + UInt64(data.count),
            length: requestedLength - data.count)
        } else {
          issueNext(connectionIndex)
        }
      }
      guard deliverOffset == size else { throw SMBDirectTransferError.unexpectedEndOfFile }
    }
  }

  private func write(
    chunks: AsyncThrowingStream<Data, Error>,
    connections: [any SMBDirectTransferClient],
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws {
    try await withThrowingTaskGroup(of: (Int, Int).self) { group in
      var nextOffset: UInt64 = 0
      var inFlight = 0
      var completedBytes: Int64 = 0
      var availableConnectionIndexes = Array(connections.indices.reversed())

      func issue(_ data: Data, at offset: UInt64, using connectionIndex: Int) {
        let connection = connections[connectionIndex]
        group.addTask {
          var written = 0
          while written < data.count {
            try Task.checkCancellation()
            let maximumWriteSize = await connection.maximumWriteSize()
            guard maximumWriteSize > 0 else {
              throw SMBDirectTransferError.invalidWriteResponse
            }
            let length = min(data.count - written, maximumWriteSize)
            let responseCount = try await connection.write(
              data.subdata(in: written..<(written + length)),
              at: offset + UInt64(written))
            guard responseCount > 0, responseCount <= length else {
              throw SMBDirectTransferError.invalidWriteResponse
            }
            written += responseCount
          }
          return (connectionIndex, written)
        }
        inFlight += 1
      }

      for try await chunk in chunks {
        try Task.checkCancellation()
        if availableConnectionIndexes.isEmpty {
          guard let (connectionIndex, completed) = try await group.next() else {
            throw SMBDirectTransferError.invalidWriteResponse
          }
          inFlight -= 1
          completedBytes += Int64(completed)
          progress(completedBytes)
          availableConnectionIndexes.append(connectionIndex)
        }
        guard let connectionIndex = availableConnectionIndexes.popLast() else {
          throw SMBDirectTransferError.invalidWriteResponse
        }
        issue(chunk, at: nextOffset, using: connectionIndex)
        nextOffset += UInt64(chunk.count)
      }
      while let (_, completed) = try await group.next() {
        try Task.checkCancellation()
        completedBytes += Int64(completed)
        progress(completedBytes)
      }
      guard completedBytes == Int64(nextOffset) else {
        throw SMBDirectTransferError.invalidWriteResponse
      }
    }
  }
}
