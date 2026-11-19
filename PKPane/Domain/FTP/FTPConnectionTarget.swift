import Foundation

enum FTPConnectionSecurity: String, Codable, CaseIterable, Hashable, Sendable {
  case plain
  case explicitTLS

  var defaultPort: Int { 21 }

  var displayName: String {
    switch self {
    case .plain:
      "FTP（暗号化なし）"
    case .explicitTLS:
      "FTPS（明示的TLS）"
    }
  }

  var warningMessage: String? {
    switch self {
    case .plain:
      "FTPは通信を暗号化しません。ユーザー名、パスワード、ファイル内容が第三者に読み取られる可能性があります。"
    case .explicitTLS:
      nil
    }
  }
}

enum FTPConnectionTargetError: LocalizedError, Equatable {
  case invalidHost
  case invalidPort
  case invalidUsername
  case invalidInitialDirectory

  var errorDescription: String? {
    switch self {
    case .invalidHost:
      "FTPサーバー名が正しくありません。"
    case .invalidPort:
      "FTPポート番号が正しくありません。"
    case .invalidUsername:
      "FTPユーザー名が正しくありません。"
    case .invalidInitialDirectory:
      "FTP開始ディレクトリが正しくありません。"
    }
  }
}

struct FTPConnectionTarget: Codable, Equatable, Hashable, Sendable {
  let host: String
  let port: Int
  let username: String
  let initialDirectory: String
  let security: FTPConnectionSecurity

  init(
    host: String,
    port: Int = 21,
    username: String,
    initialDirectory: String = "/",
    security: FTPConnectionSecurity = .explicitTLS
  ) throws {
    let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedDirectory = initialDirectory.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !normalizedHost.isEmpty, !normalizedHost.contains(where: { "/@?#".contains($0) }) else {
      throw FTPConnectionTargetError.invalidHost
    }
    guard (1...65_535).contains(port) else {
      throw FTPConnectionTargetError.invalidPort
    }
    guard !normalizedUsername.isEmpty,
      !normalizedUsername.utf8.contains(where: { $0 == 0 || $0 == 10 || $0 == 13 })
    else {
      throw FTPConnectionTargetError.invalidUsername
    }
    guard !normalizedDirectory.utf8.contains(where: { $0 == 0 || $0 == 10 || $0 == 13 }) else {
      throw FTPConnectionTargetError.invalidInitialDirectory
    }

    self.host = normalizedHost
    self.port = port
    self.username = normalizedUsername
    self.initialDirectory = Self.normalizedAbsolutePath(normalizedDirectory)
    self.security = security
  }

  static func == (lhs: FTPConnectionTarget, rhs: FTPConnectionTarget) -> Bool {
    lhs.host == rhs.host && lhs.port == rhs.port && lhs.username == rhs.username
      && lhs.security == rhs.security
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(host)
    hasher.combine(port)
    hasher.combine(username)
    hasher.combine(security)
  }

  static func normalizedAbsolutePath(_ path: String) -> String {
    var result = path.trimmingCharacters(in: .whitespacesAndNewlines)
    if result.isEmpty { return "/" }
    if !result.hasPrefix("/") { result = "/\(result)" }
    while result.count > 1, result.hasSuffix("/") { result.removeLast() }
    return result
  }
}
