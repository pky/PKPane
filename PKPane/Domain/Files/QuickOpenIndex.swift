import Foundation

enum QuickOpenCandidateKind: Int, CaseIterable, Hashable, Sendable {
  case favorite
  case recent
  case connection
  case command

  var label: String {
    switch self {
    case .favorite: "お気に入り"
    case .recent: "最近の場所"
    case .connection: "接続"
    case .command: "コマンド"
    }
  }

  var systemImage: String {
    switch self {
    case .favorite: "star.fill"
    case .recent: "clock"
    case .connection: "network"
    case .command: "command"
    }
  }
}

enum QuickOpenAction: Hashable, Sendable {
  case openFavorite(String)
  case openRecent(String)
  case connect(String)
  case performCommand(String)
}

struct QuickOpenSourceItem: Hashable, Sendable {
  let id: String
  let title: String
  let subtitle: String?

  init(id: String, title: String, subtitle: String? = nil) {
    self.id = id
    self.title = title
    self.subtitle = subtitle
  }
}

struct QuickOpenCandidate: Identifiable, Hashable, Sendable {
  let id: String
  let title: String
  let subtitle: String?
  let kind: QuickOpenCandidateKind
  let action: QuickOpenAction

  fileprivate var searchableText: String {
    [title, subtitle].compactMap { $0 }.joined(separator: " ")
  }
}

enum QuickOpenIndex {
  static let defaultCandidateLimit = 8

  static func makeCandidates(
    favorites: [QuickOpenSourceItem],
    recents: [QuickOpenSourceItem],
    connections: [QuickOpenSourceItem],
    commands: [QuickOpenSourceItem]
  ) -> [QuickOpenCandidate] {
    candidates(favorites, kind: .favorite) { .openFavorite($0) }
      + candidates(recents, kind: .recent) { .openRecent($0) }
      + candidates(connections, kind: .connection) { .connect($0) }
      + candidates(commands, kind: .command) { .performCommand($0) }
  }

  static func search(
    _ candidates: [QuickOpenCandidate],
    query: String,
    defaultLimit: Int = defaultCandidateLimit
  ) -> [QuickOpenCandidate] {
    let normalizedQuery = normalize(query.trimmingCharacters(in: .whitespacesAndNewlines))
    guard !normalizedQuery.isEmpty else {
      return Array(
        candidates.lazy
          .filter { $0.kind == .favorite || $0.kind == .recent }
          .prefix(max(0, defaultLimit)))
    }

    return candidates.enumerated().compactMap { offset, candidate in
      matchRank(in: candidate.searchableText, query: normalizedQuery).map {
        RankedCandidate(candidate: candidate, matchRank: $0, sourceOrder: offset)
      }
    }
    .sorted {
      if $0.matchRank != $1.matchRank {
        return $0.matchRank < $1.matchRank
      }
      if $0.candidate.kind != $1.candidate.kind {
        return $0.candidate.kind.rawValue < $1.candidate.kind.rawValue
      }
      return $0.sourceOrder < $1.sourceOrder
    }
    .map(\.candidate)
  }

  private static func candidates(
    _ items: [QuickOpenSourceItem],
    kind: QuickOpenCandidateKind,
    action: (String) -> QuickOpenAction
  ) -> [QuickOpenCandidate] {
    items.map { item in
      QuickOpenCandidate(
        id: "\(kind.rawValue)-\(item.id)",
        title: item.title,
        subtitle: item.subtitle,
        kind: kind,
        action: action(item.id))
    }
  }

  static func matchRank(in text: String, query: String) -> Int? {
    let normalizedText = normalize(text)
    if normalizedText.hasPrefix(query) {
      return 0
    }
    if startsWord(in: normalizedText, with: query) {
      return 1
    }
    return normalizedText.contains(query) ? 2 : nil
  }

  private static func startsWord(in text: String, with query: String) -> Bool {
    var isWordStart = true
    for index in text.indices {
      if isWordStart, text[index...].hasPrefix(query) {
        return true
      }
      isWordStart = !text[index].isLetter && !text[index].isNumber
    }
    return false
  }

  private static func normalize(_ value: String) -> String {
    value.folding(
      options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
      locale: .current)
  }

  private struct RankedCandidate {
    let candidate: QuickOpenCandidate
    let matchRank: Int
    let sourceOrder: Int
  }
}

struct QuickOpenDispatcher {
  let openFavorite: (String) -> Void
  let openRecent: (String) -> Void
  let connect: (String) -> Void
  let performCommand: (String) -> Void

  func execute(_ action: QuickOpenAction) {
    switch action {
    case .openFavorite(let id):
      openFavorite(id)
    case .openRecent(let id):
      openRecent(id)
    case .connect(let id):
      connect(id)
    case .performCommand(let id):
      performCommand(id)
    }
  }
}
