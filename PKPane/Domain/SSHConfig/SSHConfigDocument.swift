struct SSHConfigHostBlock: Equatable, Sendable {
  let patterns: [String]
  let directives: [SSHConfigDirective]
}

struct SSHConfigDirective: Equatable, Sendable {
  let keyword: String
  let value: String
  let line: Int
}

enum SSHConfigWarning: Equatable, Sendable {
  case matchBlockIgnored(line: Int)
  case includeOutsideAccessibleFolder(path: String)
  case includeUnreadable(path: String)
  case unsupportedProxyCommand(alias: String, command: String)
  case jumpChainLoop(alias: String)
  case jumpChainTooDeep(alias: String)
  case undefinedJumpAlias(alias: String)
  case unsupportedKeyType(path: String)
  case identityFileOutsideAccessibleFolder(path: String)
}

struct SSHConfigDocument: Equatable, Sendable {
  let blocks: [SSHConfigHostBlock]
  let warnings: [SSHConfigWarning]
  let baseDirectory: String

  init(
    blocks: [SSHConfigHostBlock], warnings: [SSHConfigWarning], baseDirectory: String = ""
  ) {
    self.blocks = blocks
    self.warnings = warnings
    self.baseDirectory = baseDirectory
  }

  var concreteAliases: [String] {
    var seen: Set<String> = []
    return blocks.flatMap(\.patterns).filter { pattern in
      !pattern.hasPrefix("!") && !pattern.contains("*") && !pattern.contains("?")
        && seen.insert(pattern.lowercased()).inserted
    }
  }
}
