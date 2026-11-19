import Foundation

enum SFTPConnectionTargetError: LocalizedError, Equatable {
  case invalidHost
  case invalidPort
  case invalidUsername

  var errorDescription: String? {
    switch self {
    case .invalidHost:
      "SFTPサーバー名が正しくありません。"
    case .invalidPort:
      "SFTPポート番号が正しくありません。"
    case .invalidUsername:
      "SFTPユーザー名が正しくありません。"
    }
  }
}

struct SFTPConnectionTarget: Codable, Equatable, Hashable, Sendable {
  let host: String
  let port: Int
  let username: String
  let initialDirectory: String
  let jumpHosts: [SFTPJumpHost]

  init(
    host: String,
    port: Int,
    username: String,
    initialDirectory: String = ".",
    jumpHosts: [SFTPJumpHost] = []
  ) throws {
    let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedInitialDirectory = initialDirectory.trimmingCharacters(
      in: .whitespacesAndNewlines)

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
    self.initialDirectory = normalizedInitialDirectory.isEmpty ? "." : normalizedInitialDirectory
    self.jumpHosts = jumpHosts
  }

  var finalHop: SFTPHopIdentity {
    SFTPHopIdentity(host: host, port: port, username: username)
  }

  var hops: [SFTPHopIdentity] {
    jumpHosts.map(\.identity) + [finalHop]
  }

  static func == (lhs: SFTPConnectionTarget, rhs: SFTPConnectionTarget) -> Bool {
    lhs.host == rhs.host && lhs.port == rhs.port && lhs.username == rhs.username
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(host)
    hasher.combine(port)
    hasher.combine(username)
  }

  private enum CodingKeys: String, CodingKey {
    case host
    case port
    case username
    case initialDirectory
    case jumpHosts
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      host: container.decode(String.self, forKey: .host),
      port: container.decode(Int.self, forKey: .port),
      username: container.decode(String.self, forKey: .username),
      initialDirectory: try container.decodeIfPresent(
        String.self,
        forKey: .initialDirectory) ?? ".",
      jumpHosts: try container.decodeIfPresent(
        [SFTPJumpHost].self,
        forKey: .jumpHosts) ?? [])
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(host, forKey: .host)
    try container.encode(port, forKey: .port)
    try container.encode(username, forKey: .username)
    try container.encode(initialDirectory, forKey: .initialDirectory)
    try container.encode(jumpHosts, forKey: .jumpHosts)
  }

  /// 相対パスをSFTP接続の初期パス表記("./"始まり)へ正規化する。既に絶対パス("/"始まり)や
  /// カレントディレクトリ(".")はそのまま返す。
  static func normalizedRelativePath(_ directory: String) -> String {
    directory != "." && !directory.hasPrefix("./") && !directory.hasPrefix("/")
      ? "./\(directory)" : directory
  }
}
