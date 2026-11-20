import Citadel
import NIO
import NIOSSH

protocol SSHHopTransport: Sendable {
  func jump(to settings: SSHClientSettings) async throws -> any SSHHopTransport
  func openAuthProbeChannel(
    to settings: SSHClientSettings,
    initialize: @escaping @Sendable (any Channel) -> EventLoopFuture<Void>
  ) async throws -> any Channel
  func openSFTPSession() async throws -> any SFTPClientSession
  func close() async throws
}

extension SSHHopTransport {
  func openAuthProbeChannel(
    to settings: SSHClientSettings,
    initialize: @escaping @Sendable (any Channel) -> EventLoopFuture<Void>
  ) async throws -> any Channel {
    throw ChannelError.operationUnsupported
  }
}

struct CitadelSSHHopTransport: SSHHopTransport, @unchecked Sendable {
  let client: SSHClient

  func jump(to settings: SSHClientSettings) async throws -> any SSHHopTransport {
    CitadelSSHHopTransport(client: try await client.jump(to: settings))
  }

  func openAuthProbeChannel(
    to settings: SSHClientSettings,
    initialize: @escaping @Sendable (any Channel) -> EventLoopFuture<Void>
  ) async throws -> any Channel {
    // Citadel の jump と同じ送信元表記を使う。
    let originator = try SocketAddress(ipAddress: "fe80::1", port: 22)
    return try await client.createDirectTCPIPChannel(
      using: SSHChannelType.DirectTCPIP(
        targetHost: settings.host, targetPort: settings.port, originatorAddress: originator),
      initialize: initialize)
  }

  func openSFTPSession() async throws -> any SFTPClientSession {
    CitadelSFTPClientSession(client: try await client.openSFTP())
  }

  func close() async throws {
    try await client.close()
  }
}

typealias SSHHopConnector = @Sendable (SSHClientSettings) async throws -> any SSHHopTransport
