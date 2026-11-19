struct SSHConfigResolvedHop: Equatable, Sendable {
  let alias: String
  let hostName: String
  let port: Int
  let username: String
  let identityFiles: [String]
}

struct SSHConfigImportResult: Equatable, Sendable {
  let final: SSHConfigResolvedHop
  let jumpHops: [SSHConfigResolvedHop]
  let warnings: [SSHConfigWarning]
}

enum SSHConfigImportResolver {
  static func resolve(
    alias: String, in document: SSHConfigDocument, localUsername: String, maximumDepth: Int = 8
  ) -> SSHConfigImportResult {
    var resolver = ChainResolver(
      document: document, localUsername: localUsername, maximumDepth: max(0, maximumDepth),
      warnings: document.warnings)
    let spec = SSHJumpSpec(alias: alias, user: nil, port: nil, identityFile: nil)
    let (final, directives) = resolver.resolveHop(spec)
    resolver.appendJumps(
      from: directives, alias: alias, depth: 0, path: [alias.lowercased()])
    return SSHConfigImportResult(
      final: final, jumpHops: resolver.hops, warnings: resolver.warnings)
  }

  private struct ChainResolver {
    let document: SSHConfigDocument
    let localUsername: String
    let maximumDepth: Int
    var warnings: [SSHConfigWarning]
    var emittedAliases: Set<String> = []
    var hops: [SSHConfigResolvedHop] = []

    func resolveHop(_ spec: SSHJumpSpec) -> (
      SSHConfigResolvedHop, SSHConfigParser.ResolvedDirectives
    ) {
      let values = SSHConfigParser.resolvedDirectives(
        alias: spec.alias, in: document, defaultUsername: localUsername,
        overridingUser: spec.user, overridingPort: spec.port)
      let host = values["hostname"]?.first?.value ?? spec.alias
      let username = spec.user ?? values["user"]?.first?.value ?? localUsername
      let configPort = values["port"]?.first.flatMap { Int($0.value) }
      let port = spec.port ?? configPort.flatMap { (1...65535).contains($0) ? $0 : nil } ?? 22
      let identities: [String]
      if let identity = spec.identityFile {
        identities = [
          SSHConfigParser.expand(
            identity, host: host, port: String(port), user: username,
            baseDirectory: document.baseDirectory)
        ]
      } else {
        identities = values["identityfile", default: []].map(\.value)
      }
      return (
        SSHConfigResolvedHop(
          alias: spec.alias, hostName: host, port: port, username: username,
          identityFiles: identities), values
      )
    }

    mutating func appendJumps(
      from values: SSHConfigParser.ResolvedDirectives, alias: String, depth: Int,
      path: Set<String>
    ) {
      let jump = values["proxyjump"]?.first
      let command = values["proxycommand"]?.first
      let directive: SSHProxyDirective
      if let jump, command == nil || jump.line < (command?.line ?? .max) {
        directive = SSHProxyDirective.parseProxyJump(jump.value)
      } else if let command {
        directive = SSHProxyDirective.parseProxyCommand(command.value)
      } else {
        return
      }
      switch directive {
      case .none: return
      case .unsupported(let command):
        warnings.append(.unsupportedProxyCommand(alias: alias, command: command))
      case .jump(let specs):
        for (index, spec) in specs.enumerated() {
          append(
            spec, depth: depth + 1, path: path,
            followsOwnProxyDirective: index == specs.startIndex)
        }
      }
    }

    mutating func append(
      _ spec: SSHJumpSpec, depth: Int, path: Set<String>, followsOwnProxyDirective: Bool
    ) {
      let normalizedAlias = spec.alias.lowercased()
      guard !path.contains(normalizedAlias) else {
        warnings.append(.jumpChainLoop(alias: spec.alias))
        return
      }
      guard !emittedAliases.contains(normalizedAlias) else { return }
      guard depth <= maximumDepth, hops.count < maximumDepth else {
        warnings.append(.jumpChainTooDeep(alias: spec.alias))
        return
      }
      let matchesAnyBlock = document.blocks.contains {
        SSHConfigParser.matches(block: $0, host: spec.alias)
      }
      if !matchesAnyBlock {
        warnings.append(.undefinedJumpAlias(alias: spec.alias))
      }
      let (hop, directives) = resolveHop(spec)
      if followsOwnProxyDirective {
        var nestedPath = path
        nestedPath.insert(normalizedAlias)
        appendJumps(
          from: directives, alias: spec.alias, depth: depth, path: nestedPath)
      }
      guard hops.count < maximumDepth else {
        warnings.append(.jumpChainTooDeep(alias: spec.alias))
        return
      }
      emittedAliases.insert(normalizedAlias)
      hops.append(hop)
    }
  }
}
