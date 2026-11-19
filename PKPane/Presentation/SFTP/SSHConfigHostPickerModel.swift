import Foundation
import Observation

struct SSHConfigHostCandidate: Identifiable, Equatable {
  let alias: String
  let hostName: String
  let username: String

  var id: String { alias }
}

@MainActor
@Observable
final class SSHConfigHostPickerModel: Identifiable {
  let id = UUID()
  let folderURL: URL
  let warnings: [SSHConfigWarning]
  var query: String {
    didSet { updateResults() }
  }
  private(set) var results: [SSHConfigHostCandidate] = []
  var selectedAlias: String?

  private let document: SSHConfigDocument
  private let candidates: [SSHConfigHostCandidate]

  init(document: SSHConfigDocument, folderURL: URL, initialQuery: String) {
    self.document = document
    self.folderURL = folderURL
    warnings = document.warnings
    query = initialQuery
    let aliases = document.concreteAliases
    let preparedAliases = aliases.map(PreparedAlias.init)
    var aliasIndexes: [String: Int] = [:]
    aliasIndexes.reserveCapacity(aliases.count)
    for (index, alias) in preparedAliases.enumerated() {
      aliasIndexes[alias.normalized] = index
    }
    var matchingBlocks = Array(repeating: [SSHConfigHostBlock](), count: aliases.count)
    var matchedBlockIndexes = Array(repeating: -1, count: aliases.count)
    var wildcardMatchIndexes: [String: [Int]] = [:]

    func matchingAliasIndexes(for pattern: String) -> [Int] {
      let normalized = pattern.lowercased()
      if let cached = wildcardMatchIndexes[normalized] { return cached }
      let compiled = CompiledHostPattern(normalized)
      let matched = preparedAliases.indices.filter { compiled.matches(preparedAliases[$0]) }
      wildcardMatchIndexes[normalized] = matched
      return matched
    }

    for (blockIndex, block) in document.blocks.enumerated() {
      var exactPositiveIndexes: [Int] = []
      var wildcardPositivePatterns: [String] = []
      var excludedIndexes: Set<Int> = []
      var wildcardNegativePatterns: [String] = []

      for rawPattern in block.patterns {
        let isNegative = rawPattern.hasPrefix("!")
        let pattern = isNegative ? String(rawPattern.dropFirst()) : rawPattern
        if pattern.contains("*") || pattern.contains("?") {
          if isNegative {
            wildcardNegativePatterns.append(pattern)
          } else {
            wildcardPositivePatterns.append(pattern)
          }
        } else {
          let normalized = pattern.lowercased()
          if isNegative {
            if let index = aliasIndexes[normalized] { excludedIndexes.insert(index) }
          } else if let index = aliasIndexes[normalized] {
            exactPositiveIndexes.append(index)
          }
        }
      }

      for pattern in wildcardNegativePatterns {
        excludedIndexes.formUnion(matchingAliasIndexes(for: pattern))
      }

      for index in exactPositiveIndexes where matchedBlockIndexes[index] != blockIndex {
        guard !excludedIndexes.contains(index) else { continue }
        matchingBlocks[index].append(block)
        matchedBlockIndexes[index] = blockIndex
      }

      for pattern in wildcardPositivePatterns {
        for index in matchingAliasIndexes(for: pattern)
        where matchedBlockIndexes[index] != blockIndex && !excludedIndexes.contains(index) {
          matchingBlocks[index].append(block)
          matchedBlockIndexes[index] = blockIndex
        }
      }
    }
    candidates = aliases.enumerated().map { index, alias in
      let values = SSHConfigParser.resolvedDirectives(
        alias: alias, matchingBlocks: matchingBlocks[index],
        baseDirectory: document.baseDirectory, defaultUsername: NSUserName())
      return SSHConfigHostCandidate(
        alias: alias,
        hostName: values["hostname"]?.first?.value ?? alias,
        username: values["user"]?.first?.value ?? NSUserName())
    }
    updateResults()
  }

  func moveSelection(by offset: Int) {
    guard !results.isEmpty, offset != 0 else { return }
    let currentIndex =
      selectedAlias.flatMap { alias in
        results.firstIndex { $0.alias == alias }
      } ?? 0
    let nextIndex = min(
      max(currentIndex + offset, results.startIndex), results.index(before: results.endIndex))
    selectedAlias = results[nextIndex].alias
  }

  func confirm() -> SSHConfigImportResult? {
    guard let alias = selectedAlias else { return nil }
    return SSHConfigImportResolver.resolve(
      alias: alias, in: document, localUsername: NSUserName())
  }

  func confirm(alias: String) -> SSHConfigImportResult? {
    guard results.contains(where: { $0.alias == alias }) else { return nil }
    selectedAlias = alias
    return confirm()
  }

  private func updateResults() {
    let normalizedQuery = Self.normalize(query.trimmingCharacters(in: .whitespacesAndNewlines))
    if normalizedQuery.isEmpty {
      results = candidates
    } else {
      results = candidates.enumerated().compactMap { index, candidate -> RankedCandidate? in
        let aliasRank = QuickOpenIndex.matchRank(
          in: candidate.alias, query: normalizedQuery)
        let hostRank = QuickOpenIndex.matchRank(
          in: candidate.hostName, query: normalizedQuery)
        let rank: Int
        switch (aliasRank, hostRank) {
        case (.some(let aliasRank), .some(let hostRank)):
          rank = min(aliasRank, hostRank)
        case (.some(let aliasRank), .none):
          rank = aliasRank
        case (.none, .some(let hostRank)):
          rank = hostRank
        case (.none, .none):
          return nil
        }
        return RankedCandidate(candidate: candidate, rank: rank, index: index)
      }
      .sorted { lhs, rhs in
        lhs.rank == rhs.rank ? lhs.index < rhs.index : lhs.rank < rhs.rank
      }
      .map(\.candidate)
    }
    if !results.contains(where: { $0.alias == selectedAlias }) {
      selectedAlias = results.first?.alias
    }
  }

  private static func normalize(_ value: String) -> String {
    value.folding(
      options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
      locale: .current)
  }

  private struct RankedCandidate {
    let candidate: SSHConfigHostCandidate
    let rank: Int
    let index: Int
  }

  private struct PreparedAlias {
    let normalized: String
    let utf8: [UInt8]
    let isASCII: Bool

    init(_ alias: String) {
      normalized = alias.lowercased()
      utf8 = Array(normalized.utf8)
      isASCII = utf8.allSatisfy { $0 < 0x80 }
    }
  }

  private struct CompiledHostPattern {
    let normalized: String
    let utf8: [UInt8]
    let isASCII: Bool

    init(_ pattern: String) {
      normalized = pattern.lowercased()
      utf8 = Array(normalized.utf8)
      isASCII = utf8.allSatisfy { $0 < 0x80 }
    }

    func matches(_ host: PreparedAlias) -> Bool {
      guard isASCII, host.isASCII else {
        return SSHConfigParser.matches(pattern: normalized, host: host.normalized)
      }
      var patternIndex = 0
      var hostIndex = 0
      var starIndex: Int?
      var starHostIndex = 0
      while hostIndex < host.utf8.count {
        if patternIndex < utf8.count,
          utf8[patternIndex] == 0x3F || utf8[patternIndex] == host.utf8[hostIndex]
        {
          patternIndex += 1
          hostIndex += 1
        } else if patternIndex < utf8.count, utf8[patternIndex] == 0x2A {
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
      while patternIndex < utf8.count, utf8[patternIndex] == 0x2A {
        patternIndex += 1
      }
      return patternIndex == utf8.count
    }
  }
}
