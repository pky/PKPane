import Foundation

enum SSHConfigParser {
  typealias ResolvedDirectives = [String: [(value: String, line: Int)]]
  typealias IncludeResolver = (_ pattern: String) -> [(path: String, text: String)]?

  static func parse(
    _ text: String, includeResolver: IncludeResolver, baseDirectory: String
  ) -> SSHConfigDocument {
    var builder = DocumentBuilder(baseDirectory: baseDirectory)
    builder.consume(text, depth: 0, includeResolver: includeResolver)
    builder.finishBlock()
    return SSHConfigDocument(
      blocks: builder.blocks, warnings: builder.warnings, baseDirectory: baseDirectory)
  }

  static func resolve(alias: String, in document: SSHConfigDocument) -> ResolvedDirectives {
    resolvedDirectives(alias: alias, in: document)
  }

  static func resolvedDirectives(
    alias: String, in document: SSHConfigDocument, defaultUsername: String = "",
    overridingUser: String? = nil, overridingPort: Int? = nil
  ) -> ResolvedDirectives {
    resolvedDirectives(
      alias: alias,
      matchingBlocks: document.blocks.filter { matches(block: $0, host: alias) },
      baseDirectory: document.baseDirectory,
      defaultUsername: defaultUsername,
      overridingUser: overridingUser,
      overridingPort: overridingPort)
  }

  static func resolvedDirectives(
    alias: String, matchingBlocks: [SSHConfigHostBlock], baseDirectory: String,
    defaultUsername: String = "", overridingUser: String? = nil, overridingPort: Int? = nil
  ) -> ResolvedDirectives {
    var values: ResolvedDirectives = [:]
    for block in matchingBlocks {
      for directive in block.directives {
        if directive.keyword == "identityfile" || values[directive.keyword] == nil {
          values[directive.keyword, default: []].append((directive.value, directive.line))
        }
      }
    }
    let user = overridingUser ?? values["user"]?.first?.value ?? defaultUsername
    let port = overridingPort.map(String.init) ?? values["port"]?.first?.value ?? "22"
    let host = expandTokens(
      values["hostname"]?.first?.value ?? alias, host: alias, port: port, user: user)
    return values.mapValues { entries in
      entries.map { entry in
        (
          value: expand(
            entry.value, host: host, port: port, user: user,
            baseDirectory: baseDirectory),
          line: entry.line
        )
      }
    }
  }

  static func matches(pattern: String, host: String) -> Bool {
    guard pattern.contains("*") || pattern.contains("?") else {
      return pattern.compare(host, options: [.caseInsensitive]) == .orderedSame
    }
    let pattern = Array(pattern.lowercased())
    let host = Array(host.lowercased())
    var patternIndex = 0
    var hostIndex = 0
    var starIndex: Int?
    var starHostIndex = 0
    while hostIndex < host.count {
      if patternIndex < pattern.count,
        pattern[patternIndex] == "?" || pattern[patternIndex] == host[hostIndex]
      {
        patternIndex += 1
        hostIndex += 1
      } else if patternIndex < pattern.count, pattern[patternIndex] == "*" {
        starIndex = patternIndex
        patternIndex += 1
        starHostIndex = hostIndex
      } else if let starIndex {
        patternIndex = starIndex + 1
        starHostIndex += 1
        hostIndex = starHostIndex
      } else {
        return false
      }
    }
    while patternIndex < pattern.count, pattern[patternIndex] == "*" {
      patternIndex += 1
    }
    return patternIndex == pattern.count
  }

  static func matches(block: SSHConfigHostBlock, host: String) -> Bool {
    var positiveMatch = false
    for pattern in block.patterns {
      if pattern.hasPrefix("!") {
        if matches(pattern: String(pattern.dropFirst()), host: host) { return false }
      } else if matches(pattern: pattern, host: host) {
        positiveMatch = true
      }
    }
    return positiveMatch
  }

  static func expand(
    _ value: String, host: String, port: String, user: String, baseDirectory: String
  ) -> String {
    let expanded = expandTokens(value, host: host, port: port, user: user)
    guard expanded == "~" || expanded.hasPrefix("~/"), !baseDirectory.isEmpty else {
      return expanded
    }
    let home = (baseDirectory as NSString).deletingLastPathComponent
    return home + expanded.dropFirst()
  }

  private static func expandTokens(
    _ value: String, host: String, port: String, user: String
  ) -> String {
    var result = ""
    var iterator = value.makeIterator()
    while let character = iterator.next() {
      guard character == "%", let token = iterator.next() else {
        result.append(character)
        continue
      }
      switch token {
      case "h": result += host
      case "p": result += port
      case "r": result += user
      case "%": result.append("%")
      default:
        result.append("%")
        result.append(token)
      }
    }
    return result
  }

  private struct DocumentBuilder {
    let baseDirectory: String
    var blocks: [SSHConfigHostBlock] = []
    var warnings: [SSHConfigWarning] = []
    var patterns = ["*"]
    var directives: [SSHConfigDirective] = []
    var ignoringMatch = false
    var line = 0
    var activeIncludePaths: Set<String> = []
    var includedFileCount = 0
    let maximumIncludedFileCount = 64

    mutating func finishBlock() {
      if !directives.isEmpty || patterns != ["*"] {
        blocks.append(SSHConfigHostBlock(patterns: patterns, directives: directives))
      }
      directives = []
    }

    mutating func consume(_ text: String, depth: Int, includeResolver: IncludeResolver) {
      for rawLine in text.components(separatedBy: .newlines) {
        // Include の内容も出現順に採番し、別ファイル間の先勝ちを維持する。
        line += 1
        guard let (keyword, value) = SSHConfigTokenizer.directive(rawLine) else { continue }
        if keyword == "host" {
          finishBlock()
          patterns = SSHConfigTokenizer.tokens(value) ?? []
          ignoringMatch = false
        } else if keyword == "match" {
          ignoringMatch = true
          warnings.append(.matchBlockIgnored(line: line))
        } else if !ignoringMatch {
          if keyword == "include" {
            include(value, depth: depth, resolver: includeResolver)
          } else {
            let tokens = SSHConfigTokenizer.tokens(value) ?? []
            // コマンド内の引数の引用符は認識器まで保持し、値全体の引用符だけを外す。
            let parsedValue =
              keyword == "proxycommand" && tokens.count != 1
              ? value : tokens.joined(separator: " ")
            directives.append(SSHConfigDirective(keyword: keyword, value: parsedValue, line: line))
          }
        }
      }
    }

    mutating func include(_ value: String, depth: Int, resolver: IncludeResolver) {
      for pattern in SSHConfigTokenizer.tokens(value) ?? [] {
        var path = SSHConfigParser.expand(
          pattern, host: "", port: "22", user: "", baseDirectory: baseDirectory)
        if !path.hasPrefix("/") {
          path = (baseDirectory as NSString).appendingPathComponent(path)
        }
        guard depth < 8 else {
          warnings.append(.includeUnreadable(path: path))
          continue
        }
        let normalizedPath = URL(filePath: path).standardizedFileURL.path
        let containsGlob = normalizedPath.contains(where: { "*?[".contains($0) })
        if !containsGlob, activeIncludePaths.contains(normalizedPath) {
          warnings.append(.includeUnreadable(path: normalizedPath))
          continue
        }
        guard let files = resolver(path) else {
          warnings.append(.includeOutsideAccessibleFolder(path: path))
          continue
        }
        let parentPatterns = patterns
        let parentIgnoringMatch = ignoringMatch
        finishBlock()
        for file in files {
          let filePath = URL(filePath: file.path).standardizedFileURL.path
          guard !activeIncludePaths.contains(filePath) else {
            warnings.append(.includeUnreadable(path: filePath))
            continue
          }
          guard includedFileCount < maximumIncludedFileCount else {
            warnings.append(.includeUnreadable(path: filePath))
            continue
          }
          activeIncludePaths.insert(filePath)
          includedFileCount += 1
          consume(file.text, depth: depth + 1, includeResolver: resolver)
          activeIncludePaths.remove(filePath)
        }
        finishBlock()
        patterns = parentPatterns
        ignoringMatch = parentIgnoringMatch
      }
    }
  }
}

enum SSHConfigTokenizer {
  static func directive(_ line: String) -> (keyword: String, value: String)? {
    let content = line.trimmingCharacters(in: .whitespaces)
    guard !content.isEmpty, !content.hasPrefix("#") else { return nil }
    let boundary = content.firstIndex { $0.isWhitespace || $0 == "=" } ?? content.endIndex
    let keyword = content[..<boundary].lowercased()
    var value = content[boundary...].drop(while: \.isWhitespace)
    if value.first == "=" { value = value.dropFirst().drop(while: \.isWhitespace) }
    var quote: Character?
    var escaped = false
    var uncommented = ""
    for character in value {
      if escaped {
        escaped = false
      } else if character == "\\" {
        escaped = true
      } else if character == quote {
        quote = nil
      } else if quote == nil {
        if character == "#" { break }
        if character == "\"" || character == "'" { quote = character }
      }
      uncommented.append(character)
    }
    return (keyword, uncommented.trimmingCharacters(in: .whitespaces))
  }

  static func tokens(_ value: String) -> [String]? {
    var result: [String] = []
    var token = ""
    var quote: Character?
    var escaped = false
    var started = false
    for character in value {
      if escaped {
        token.append(character)
        escaped = false
      } else if character == "\\", quote != "'" {
        escaped = true
        started = true
      } else if character == quote {
        quote = nil
      } else if quote == nil, character == "\"" || character == "'" {
        quote = character
        started = true
      } else if quote == nil, character.isWhitespace {
        if started { result.append(token) }
        token = ""
        started = false
      } else {
        token.append(character)
        started = true
      }
    }
    guard quote == nil, !escaped else { return nil }
    if started { result.append(token) }
    return result
  }
}
