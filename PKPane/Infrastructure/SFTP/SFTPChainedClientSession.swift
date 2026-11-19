import Foundation

final class SFTPChainedClientSession: SFTPClientSession, Sendable {
  private let base: any SFTPClientSession
  private let transports: [any SSHHopTransport]

  init(base: any SFTPClientSession, transports: [any SSHHopTransport]) {
    self.base = base
    self.transports = transports
  }

  func realPath(of remotePath: String) async throws -> String {
    try await base.realPath(of: remotePath)
  }

  func contents(of remotePath: String) async throws -> [SFTPDirectoryEntry] {
    try await base.contents(of: remotePath)
  }

  func createDirectory(at remotePath: String) async throws {
    try await base.createDirectory(at: remotePath)
  }

  func remove(at remotePath: String, isDirectory: Bool) async throws {
    try await base.remove(at: remotePath, isDirectory: isDirectory)
  }

  func rename(at remotePath: String, to destinationPath: String) async throws {
    try await base.rename(at: remotePath, to: destinationPath)
  }

  func copy(
    at remotePath: String,
    to destinationPath: String,
    replacingExisting: Bool
  ) async throws {
    try await base.copy(
      at: remotePath,
      to: destinationPath,
      replacingExisting: replacingExisting)
  }

  func streamFileContents(
    of remotePath: String,
    chunkSize: Int,
    receive: @escaping @Sendable (Data) async throws -> Void
  ) async throws {
    try await base.streamFileContents(
      of: remotePath,
      chunkSize: chunkSize,
      receive: receive)
  }

  func writeFileContents(
    to remotePath: String,
    chunks: AsyncThrowingStream<Data, Error>,
    replacingExisting: Bool,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws {
    try await base.writeFileContents(
      to: remotePath,
      chunks: chunks,
      replacingExisting: replacingExisting,
      progress: progress)
  }

  func fileContents(of remotePath: String) async throws -> Data {
    try await base.fileContents(of: remotePath)
  }

  func fileSize(at remotePath: String) async throws -> Int64? {
    try await base.fileSize(at: remotePath)
  }

  func setPosixPermissions(_ permissions: Int, at remotePath: String) async throws {
    try await base.setPosixPermissions(permissions, at: remotePath)
  }

  func isActive() async -> Bool {
    await base.isActive()
  }

  func abortActiveTransfers() {
    base.abortActiveTransfers()
  }

  func transferSession() async throws -> any SFTPClientSession {
    try await base.transferSession()
  }

  func invalidateTransferSession(_ failedSession: any SFTPClientSession) async {
    await base.invalidateTransferSession(failedSession)
  }

  func close() async throws {
    var firstError: Error?
    do {
      try await base.close()
    } catch {
      firstError = error
    }
    for transport in transports.reversed() {
      do {
        try await transport.close()
      } catch {
        if firstError == nil {
          firstError = error
        }
      }
    }
    if let firstError {
      throw firstError
    }
  }
}
