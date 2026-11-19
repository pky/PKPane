import Foundation

struct SFTPHopIdentity: Hashable, Sendable {
  let host: String
  let port: Int
  let username: String
}

struct SFTPJumpHost: Codable, Hashable, Sendable {
  let host: String
  let port: Int
  let username: String
  let label: String?

  init(host: String, port: Int, username: String, label: String?) throws {
    let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !normalizedHost.isEmpty, !normalizedHost.contains(where: { "/@?#".contains($0) }) else {
      throw SFTPConnectionTargetError.invalidHost
    }
    guard (1...65_535).contains(port) else {
      throw SFTPConnectionTargetError.invalidPort
    }
    guard !normalizedUsername.isEmpty, !normalizedUsername.contains("@") else {
      throw SFTPConnectionTargetError.invalidUsername
    }

    self.host = normalizedHost
    self.port = port
    self.username = normalizedUsername
    self.label = label
  }

  var identity: SFTPHopIdentity {
    SFTPHopIdentity(host: host, port: port, username: username)
  }

  private enum CodingKeys: String, CodingKey {
    case host
    case port
    case username
    case label
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      host: container.decode(String.self, forKey: .host),
      port: container.decode(Int.self, forKey: .port),
      username: container.decode(String.self, forKey: .username),
      label: container.decodeIfPresent(String.self, forKey: .label))
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(host, forKey: .host)
    try container.encode(port, forKey: .port)
    try container.encode(username, forKey: .username)
    try container.encodeIfPresent(label, forKey: .label)
  }
}
