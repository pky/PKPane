import Citadel

protocol SSHHopTransport: Sendable {
  func jump(to settings: SSHClientSettings) async throws -> any SSHHopTransport
  func openSFTPSession() async throws -> any SFTPClientSession
  func close() async throws
}

struct CitadelSSHHopTransport: SSHHopTransport, @unchecked Sendable {
  let client: SSHClient

  func jump(to settings: SSHClientSettings) async throws -> any SSHHopTransport {
    CitadelSSHHopTransport(client: try await client.jump(to: settings))
  }

  func openSFTPSession() async throws -> any SFTPClientSession {
    CitadelSFTPClientSession(client: try await client.openSFTP())
  }

  func close() async throws {
    try await client.close()
  }
}

typealias SSHHopConnector = @Sendable (SSHClientSettings) async throws -> any SSHHopTransport
