import Foundation

enum SearchScope: String, CaseIterable, Identifiable, Sendable, Equatable {
  case currentFolder
  case thisMac

  var id: Self { self }

  var displayName: String {
    switch self {
    case .currentFolder:
      String(localized: "現在のフォルダ")
    case .thisMac:
      String(localized: "このMac")
    }
  }
}

enum NameMatchMode: Sendable, Equatable {
  case literal
  case regex
}

/// ファイル名の照合条件を一度だけコンパイルし、一覧・再帰検索で再利用する値型。
struct NameMatcher: Sendable {
  let pattern: String
  let mode: NameMatchMode
  let isCaseSensitive: Bool

  private let regularExpression: NSRegularExpression?

  init(
    pattern: String,
    mode: NameMatchMode,
    isCaseSensitive: Bool = false
  ) {
    self.pattern = pattern
    self.mode = mode
    self.isCaseSensitive = isCaseSensitive
    if mode == .regex {
      regularExpression = try? NSRegularExpression(
        pattern: pattern,
        options: isCaseSensitive ? [] : [.caseInsensitive])
    } else {
      regularExpression = nil
    }
  }

  var isValid: Bool {
    mode == .literal || regularExpression != nil
  }

  func matches(_ name: String) -> Bool {
    switch mode {
    case .literal:
      if isCaseSensitive {
        return name.range(of: pattern) != nil
      }
      return name.localizedCaseInsensitiveContains(pattern)
    case .regex:
      guard let regularExpression else { return false }
      let range = NSRange(name.startIndex..<name.endIndex, in: name)
      return regularExpression.firstMatch(in: name, range: range) != nil
    }
  }
}

struct SearchQuery: Sendable, Equatable {
  let text: String
  let root: FileLocation
  let scope: SearchScope
  let nameMatchMode: NameMatchMode
  let generation: UUID

  init(
    text: String,
    root: FileLocation,
    scope: SearchScope,
    nameMatchMode: NameMatchMode = .literal,
    generation: UUID = UUID()
  ) {
    self.text = text
    self.root = root
    self.scope = scope
    self.nameMatchMode = nameMatchMode
    self.generation = generation
  }
}

struct ParsedSearchQuery: Sendable, Equatable {
  let nameText: String
  let tagTerms: [String]
  let contentTerms: [String]

  var hasTagTerms: Bool { !tagTerms.isEmpty }
  var hasContentTerms: Bool { !contentTerms.isEmpty }

  var textExcludingContentTerms: String {
    ([nameText] + tagTerms.map { "tag:\($0)" })
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }
}

enum SearchQueryParser {
  static func parse(_ text: String) -> ParsedSearchQuery {
    var nameTerms = [Substring]()
    var tagTerms = [String]()
    var contentTerms = [String]()

    for token in text.split(whereSeparator: \Character.isWhitespace) {
      if token.count > 4,
        token.prefix(4).caseInsensitiveCompare("tag:") == .orderedSame
      {
        let tagName = token.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tagName.isEmpty {
          tagTerms.append(tagName)
          continue
        }
      }
      if token.count > 8,
        token.prefix(8).caseInsensitiveCompare("content:") == .orderedSame
      {
        let contentText = token.dropFirst(8).trimmingCharacters(in: .whitespacesAndNewlines)
        if !contentText.isEmpty {
          contentTerms.append(contentText)
          continue
        }
      }
      nameTerms.append(token)
    }

    return ParsedSearchQuery(
      nameText: nameTerms.map(String.init).joined(separator: " "),
      tagTerms: tagTerms,
      contentTerms: contentTerms)
  }
}

struct SearchResult: Equatable, Sendable {
  let item: FileItem
  let parent: FileLocation
  let providerID: FileProviderID
  let generation: UUID
  let lastUsedAt: Date?

  init(
    item: FileItem,
    parent: FileLocation,
    providerID: FileProviderID,
    generation: UUID,
    lastUsedAt: Date? = nil
  ) {
    self.item = item
    self.parent = parent
    self.providerID = providerID
    self.generation = generation
    self.lastUsedAt = lastUsedAt
  }
}

struct SearchPartialError: Equatable, Sendable {
  let location: FileLocation
  let message: String
  let generation: UUID
  let count: Int

  init(location: FileLocation, message: String, generation: UUID, count: Int = 1) {
    self.location = location
    self.message = message
    self.generation = generation
    self.count = count
  }
}

struct SearchResultSnapshot: Sendable {
  let revision: Int
  let results: [SearchResult]
  let items: [FileItem]
  let locations: Set<FileLocation>
}

/// 検索エンジンの逐次バッチをバックグラウンドで累積・表示順へ投影する。
/// MainActorへ渡すのは、そのまま描画に使える不変スナップショットだけにする。
actor SearchResultProjection {
  private var accumulatedResults = [SearchResult]()
  private var latestReplacementSourceRevision: Int?
  private var sortOrder: FileItemSortOrder
  private var ascending: Bool
  private let includesHiddenItems: Bool
  private let sortsByLastUsedAt: Bool
  private var revision = 0

  init(
    sortOrder: FileItemSortOrder,
    ascending: Bool,
    includesHiddenItems: Bool,
    sortsByLastUsedAt: Bool = false
  ) {
    self.sortOrder = sortOrder
    self.ascending = ascending
    self.includesHiddenItems = includesHiddenItems
    self.sortsByLastUsedAt = sortsByLastUsedAt
  }

  func append(_ results: [SearchResult]) {
    guard !results.isEmpty else { return }
    accumulatedResults.append(contentsOf: results)
    revision &+= 1
  }

  /// 読み込み済み一覧を絞り込む検索では、一覧更新ごとに結果全体を置き換える。
  /// sourceRevisionで遅れて到着した旧一覧の置換を拒否し、補完後の結果を巻き戻さない。
  func replace(_ results: [SearchResult], sourceRevision: Int) -> Bool {
    if let latestReplacementSourceRevision,
      sourceRevision < latestReplacementSourceRevision
    {
      return false
    }
    latestReplacementSourceRevision = sourceRevision
    guard accumulatedResults != results else { return true }
    accumulatedResults = results
    revision &+= 1
    return true
  }

  func updateSortOrder(_ sortOrder: FileItemSortOrder, ascending: Bool) {
    guard self.sortOrder != sortOrder || self.ascending != ascending else { return }
    self.sortOrder = sortOrder
    self.ascending = ascending
    revision &+= 1
  }

  func remove(locations: Set<FileLocation>) {
    guard !locations.isEmpty else { return }
    let previousCount = accumulatedResults.count
    accumulatedResults.removeAll { locations.contains($0.item.location) }
    if accumulatedResults.count != previousCount {
      revision &+= 1
    }
  }

  func snapshot(after publishedRevision: Int?) -> SearchResultSnapshot? {
    guard publishedRevision != revision else { return nil }
    let visibleResults = accumulatedResults.filter {
      includesHiddenItems || !$0.item.name.hasPrefix(".")
    }
    let sortedResults = visibleResults.sorted(by: areInDisplayOrder)
    return SearchResultSnapshot(
      revision: revision,
      results: sortedResults,
      items: sortedResults.map(\.item),
      locations: Set(sortedResults.map { $0.item.location }))
  }

  private func areInDisplayOrder(_ lhs: SearchResult, _ rhs: SearchResult) -> Bool {
    if sortsByLastUsedAt {
      let leftDate = lhs.lastUsedAt ?? .distantPast
      let rightDate = rhs.lastUsedAt ?? .distantPast
      if leftDate != rightDate { return leftDate > rightDate }
      return lhs.item.url.absoluteString < rhs.item.url.absoluteString
    }
    let left = lhs.item
    let right = rhs.item
    let primary: ComparisonResult
    switch sortOrder {
    case .name:
      primary = left.name.localizedStandardCompare(right.name)
    case .kind:
      if left.isDirectory == right.isDirectory {
        primary = .orderedSame
      } else {
        primary = left.isDirectory ? .orderedAscending : .orderedDescending
      }
    case .size:
      primary = compare(left.size ?? -1, right.size ?? -1)
    case .modifiedAt:
      primary = compare(left.modifiedAt ?? .distantPast, right.modifiedAt ?? .distantPast)
    }
    if primary != .orderedSame {
      return ascending ? primary == .orderedAscending : primary == .orderedDescending
    }
    let nameOrder = left.name.localizedStandardCompare(right.name)
    if nameOrder != .orderedSame {
      return ascending ? nameOrder == .orderedAscending : nameOrder == .orderedDescending
    }
    return left.url.absoluteString < right.url.absoluteString
  }

  private func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
    if lhs < rhs { return .orderedAscending }
    if lhs > rhs { return .orderedDescending }
    return .orderedSame
  }
}

enum SearchUpdate: Equatable, Sendable {
  case results([SearchResult], generation: UUID)
  case partialError(SearchPartialError)
  case limitReached(SearchLimit, generation: UUID)
  case finished(UUID)

  var generation: UUID {
    switch self {
    case .results(_, let generation):
      return generation
    case .partialError(let error):
      return error.generation
    case .limitReached(_, let generation), .finished(let generation):
      return generation
    }
  }
}

enum SearchLimit: Equatable, Sendable {
  case results(Int)
  case visitedDirectories(Int)
}

protocol SearchService: Sendable {
  func search(_ query: SearchQuery) -> AsyncStream<SearchUpdate>
}

enum FullDiskAccessStatus: Equatable, Sendable {
  case granted
  case denied
  case unknown
}

protocol FullDiskAccessChecking {
  var status: FullDiskAccessStatus { get }
}

enum FileBrowserSearchPresentation {
  static func shouldShowThisMacAccessGuidance(
    isSearchActive: Bool,
    scope: SearchScope,
    fullDiskAccessStatus: FullDiskAccessStatus
  ) -> Bool {
    isSearchActive && scope == .thisMac && fullDiskAccessStatus == .denied
  }

  static func viewMode(
    configuredMode: FileBrowserViewMode,
    isSearchActive: Bool
  ) -> FileBrowserViewMode {
    isSearchActive
      && FileBrowserCapability.supports(.columnBrowsing, for: configuredMode)
      ? .list : configuredMode
  }

  static func displayOptions(
    configuredOptions: FileBrowserDisplayOptions,
    isSearchActive: Bool
  ) -> FileBrowserDisplayOptions {
    guard isSearchActive else { return configuredOptions }
    var options = configuredOptions
    options.showsLocationColumn = true
    return options
  }
}
