import Foundation

struct SSHJumpSpec: Equatable, Sendable {
  let alias: String
  let user: String?
  let port: Int?
  let identityFile: String?
}

enum SSHProxyDirective: Equatable, Sendable {
  case none
  case jump([SSHJumpSpec])
  case unsupported(String)

  static func parseProxyJump(_ value: String) -> SSHProxyDirective {
    let value = value.trimmingCharacters(in: .whitespaces)
    if value.lowercased() == "none" { return .none }
    var hops: [SSHJumpSpec] = []
    for item in value.split(separator: ",", omittingEmptySubsequences: false) {
      guard let hop = jumpSpec(String(item).trimmingCharacters(in: .whitespaces)) else {
        return .unsupported(value)
      }
      hops.append(hop)
    }
    return hops.isEmpty ? .unsupported(value) : .jump(hops)
  }

  static func parseProxyCommand(_ value: String) -> SSHProxyDirective {
    if value.trimmingCharacters(in: .whitespaces).lowercased() == "none" { return .none }
    guard let tokens = SSHConfigTokenizer.tokens(value),
      let executable = tokens.first,
      executable == "ssh" || (executable.hasPrefix("/") && executable.hasSuffix("/ssh"))
    else { return .unsupported(value) }
    var command = CommandOptions()
    guard command.parse(Array(tokens.dropFirst())), let alias = command.alias,
      let destination = jumpSpec(alias)
    else { return .unsupported(value) }
    let hop = SSHJumpSpec(
      alias: destination.alias, user: command.user ?? destination.user,
      port: command.port ?? destination.port, identityFile: command.identityFile)
    return .jump(command.previousHops + [hop])
  }

  private static func jumpSpec(_ value: String) -> SSHJumpSpec? {
    guard !value.isEmpty, !value.contains(where: \.isWhitespace) else { return nil }
    let userParts = value.split(separator: "@", omittingEmptySubsequences: false)
    guard userParts.count <= 2 else { return nil }
    let user = userParts.count == 2 ? String(userParts[0]) : nil
    guard user != "" else { return nil }
    var host = String(userParts[userParts.count - 1])
    var port: Int?
    if host.hasPrefix("[") {
      guard let end = host.firstIndex(of: "]") else { return nil }
      let suffix = String(host[host.index(after: end)...])
      if !suffix.isEmpty {
        guard suffix.hasPrefix(":"), let parsed = validPort(String(suffix.dropFirst())) else {
          return nil
        }
        port = parsed
      }
      host = String(host[host.index(after: host.startIndex)..<end])
    } else if host.contains(":") {
      let parts = host.split(separator: ":", omittingEmptySubsequences: false)
      guard parts.count == 2, let parsed = validPort(String(parts[1])) else { return nil }
      host = String(parts[0])
      port = parsed
    }
    guard !host.isEmpty, !host.hasPrefix("-") else { return nil }
    return SSHJumpSpec(alias: host, user: user, port: port, identityFile: nil)
  }

  private static func validPort(_ value: String) -> Int? {
    guard let port = Int(value), (1...65535).contains(port) else { return nil }
    return port
  }

  private struct CommandOptions {
    var alias: String?
    var user: String?
    var port: Int?
    var identityFile: String?
    var previousHops: [SSHJumpSpec] = []
    var forwarding = false

    mutating func parse(_ tokens: [String]) -> Bool {
      var index = 0
      while index < tokens.count {
        let token = tokens[index]
        if token.hasPrefix("-") {
          guard index + 1 < tokens.count, option(token, value: tokens[index + 1]) else {
            return false
          }
          index += 2
        } else if alias == nil {
          alias = token
          index += 1
        } else {
          return !forwarding && (token == "nc" || token == "netcat")
            && index + 3 == tokens.count && !tokens[index + 1].isEmpty
            && (tokens[index + 2] == "%p"
              || SSHProxyDirective.validPort(tokens[index + 2]) != nil)
        }
      }
      return forwarding && alias != nil
    }

    mutating func option(_ option: String, value: String) -> Bool {
      switch option {
      case "-p":
        guard let parsed = SSHProxyDirective.validPort(value) else { return false }
        if port == nil { port = parsed }
      case "-l":
        guard !value.isEmpty else { return false }
        if user == nil { user = value }
      case "-i":
        guard !value.isEmpty else { return false }
        if identityFile == nil { identityFile = value }
      case "-J":
        switch SSHProxyDirective.parseProxyJump(value) {
        case .jump(let hops): previousHops += hops
        case .none: break
        case .unsupported: return false
        }
      case "-o":
        let key = value.prefix { $0 != "=" && !$0.isWhitespace }.lowercased()
        guard !["user", "port", "identityfile", "proxyjump"].contains(key) else {
          return false
        }
      case "-W":
        guard !forwarding, let separator = value.lastIndex(of: ":"),
          separator != value.startIndex,
          String(value[value.index(after: separator)...]) == "%p"
            || SSHProxyDirective.validPort(String(value[value.index(after: separator)...])) != nil
        else { return false }
        forwarding = true
      default: return false
      }
      return true
    }
  }
}
