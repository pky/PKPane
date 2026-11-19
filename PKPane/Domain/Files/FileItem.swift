import Foundation

enum FileBrowserViewMode: String, CaseIterable, Codable, Identifiable, Equatable {
  case icon = "アイコン"
  case list = "リスト"
  case column = "カラム"

  var id: Self { self }

  /// ツールバー・表示オプションへ露出する表示モード。
  static var selectableCases: [FileBrowserViewMode] { [.icon, .list, .column] }

  var shortcutKey: String {
    switch self {
    case .icon: "1"
    case .list: "2"
    case .column: "3"
    }
  }

  var displayName: String {
    switch self {
    case .icon: String(localized: "アイコン")
    case .list: String(localized: "リスト")
    case .column: String(localized: "カラム")
    }
  }

  var systemImageName: String {
    switch self {
    case .icon: "square.grid.2x2"
    case .list: "list.bullet"
    case .column: "rectangle.split.3x1"
    }
  }
}

struct FileItem: Equatable, Identifiable, Sendable {
  let url: URL
  let location: FileLocation
  let name: String
  let isDirectory: Bool
  let isSymbolicLink: Bool
  let isAliasFile: Bool
  let size: Int64?
  let createdAt: Date?
  let modifiedAt: Date?
  let tags: [String]?
  let posixPermissions: Int?
  let ownerName: String?
  let groupName: String?

  init(
    url: URL,
    providerID: FileProviderID = .local,
    isDirectory: Bool,
    isSymbolicLink: Bool = false,
    isAliasFile: Bool = false,
    size: Int64? = nil,
    createdAt: Date? = nil,
    modifiedAt: Date? = nil,
    tags: [String]? = nil,
    posixPermissions: Int? = nil,
    ownerName: String? = nil,
    groupName: String? = nil
  ) {
    self.url = url
    self.location = FileLocation(localURL: url, providerID: providerID)
    self.name = url.lastPathComponent
    self.isDirectory = isDirectory
    self.isSymbolicLink = isSymbolicLink
    self.isAliasFile = isAliasFile
    self.size = size
    self.createdAt = createdAt
    self.modifiedAt = modifiedAt
    self.tags = tags
    self.posixPermissions = posixPermissions
    self.ownerName = ownerName
    self.groupName = groupName
  }

  /// 列挙ホットパス用。urlは正規化済み、nameはurl.lastPathComponentと一致すること。
  init(
    normalizedLocalURL: URL,
    name: String,
    providerID: FileProviderID = .local,
    isDirectory: Bool,
    isSymbolicLink: Bool = false,
    size: Int64? = nil,
    modifiedAt: Date? = nil
  ) {
    url = normalizedLocalURL
    location = FileLocation(normalizedLocalURL: normalizedLocalURL, providerID: providerID)
    self.name = name
    self.isDirectory = isDirectory
    self.isSymbolicLink = isSymbolicLink
    isAliasFile = false
    self.size = size
    createdAt = nil
    self.modifiedAt = modifiedAt
    tags = nil
    posixPermissions = nil
    ownerName = nil
    groupName = nil
  }

  init(
    remotePath: String,
    url: URL,
    providerID: FileProviderID,
    isDirectory: Bool,
    isSymbolicLink: Bool = false,
    size: Int64? = nil,
    createdAt: Date? = nil,
    modifiedAt: Date? = nil,
    tags: [String]? = nil,
    posixPermissions: Int? = nil,
    ownerName: String? = nil,
    groupName: String? = nil,
    /// urlから機械的に決まる名前(lastPathComponent)ではなく明示的な表示名を使いたい場合に
    /// 指定する。現在は詳細ペインの「現在フォルダ」プレースホルダ(ルート・ホーム等、urlの
    /// lastPathComponentが不自然になるケース)のためだけに使う。
    name: String? = nil
  ) {
    self.url = url
    location = FileLocation(remotePath: remotePath, providerID: providerID)
    self.name = name ?? url.lastPathComponent
    self.isDirectory = isDirectory
    self.isSymbolicLink = isSymbolicLink
    isAliasFile = false
    self.size = size
    self.createdAt = createdAt
    self.modifiedAt = modifiedAt
    self.tags = tags
    self.posixPermissions = posixPermissions
    self.ownerName = ownerName
    self.groupName = groupName
  }

  fileprivate init(_ item: FileItem, fillingMissingMetadataFrom previous: FileItem) {
    url = item.url
    location = item.location
    name = item.name
    isDirectory = item.isDirectory
    isSymbolicLink = item.isSymbolicLink
    isAliasFile = item.isAliasFile
    size = item.size ?? previous.size
    createdAt = item.createdAt ?? previous.createdAt
    modifiedAt = item.modifiedAt ?? previous.modifiedAt
    tags = item.tags ?? previous.tags
    posixPermissions = item.posixPermissions ?? previous.posixPermissions
    ownerName = item.ownerName ?? previous.ownerName
    groupName = item.groupName ?? previous.groupName
  }

  var id: URL { url }
  var isLink: Bool { isSymbolicLink || isAliasFile }
  var kindDisplayName: String {
    if isAliasFile { return String(localized: "エイリアス") }
    if isSymbolicLink { return String(localized: "シンボリックリンク") }
    return isDirectory ? String(localized: "フォルダ") : String(localized: "書類")
  }
  var systemImageName: String {
    if isAliasFile { return "arrow.turn.down.right" }
    if isSymbolicLink { return "link" }
    return isDirectory ? "folder" : "doc"
  }
  var displaySize: String {
    size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
  }
  var displayModifiedAt: String {
    modifiedAt?.formatted(date: .abbreviated, time: .shortened) ?? "—"
  }

  var displayCreatedAt: String {
    createdAt?.formatted(date: .abbreviated, time: .shortened) ?? "—"
  }

  var displayTags: String {
    guard let tags, !tags.isEmpty else { return "—" }
    return tags.joined(separator: "、")
  }

  var displayPermissions: String {
    guard let posixPermissions else { return "—" }
    return String(format: "%04o", posixPermissions & 0o7777)
  }

  var displayParentPath: String {
    switch location.path {
    case .local(let url):
      url.deletingLastPathComponent().path
    case .remote(let path):
      location.deletingLastPathComponent()?.remotePath ?? path
    }
  }

  /// パスをコピー用の表示文字列。ローカル/NASはファイルシステムパス、
  /// SFTP等リモートはリモートパス文字列。
  var pathForClipboard: String {
    location.localURL?.path ?? location.remotePath ?? url.path
  }

  /// 情報を見るダイアログのヘッダで、QLThumbnailGeneratorによる内部プレビュー
  /// サムネイルを試みてよいか。ローカル/マウント済みNAS(localURLあり)のみ対象。
  /// SFTP等リモートはダウンロードが必要になるため対象外(常にfalse)。
  var supportsThumbnailPreview: Bool {
    location.localURL != nil
  }

  /// フォルダの内容合計(サイズ・件数)を計算できるか。ローカル/マウント済みNASの
  /// フォルダのみ対象。SFTP等リモートは非対応。
  var supportsFolderContentsScan: Bool {
    isDirectory && location.localURL != nil
  }

  func replacingTags(_ tagNames: [String]) -> FileItem {
    switch location.path {
    case .local(let url):
      return FileItem(
        url: url,
        providerID: location.providerID,
        isDirectory: isDirectory,
        isSymbolicLink: isSymbolicLink,
        isAliasFile: isAliasFile,
        size: size,
        createdAt: createdAt,
        modifiedAt: modifiedAt,
        tags: tagNames,
        posixPermissions: posixPermissions,
        ownerName: ownerName,
        groupName: groupName)
    case .remote(let path):
      return FileItem(
        remotePath: path,
        url: url,
        providerID: location.providerID,
        isDirectory: isDirectory,
        isSymbolicLink: isSymbolicLink,
        size: size,
        createdAt: createdAt,
        modifiedAt: modifiedAt,
        tags: tagNames,
        posixPermissions: posixPermissions,
        ownerName: ownerName,
        groupName: groupName,
        name: name)
    }
  }
}

extension Array where Element == FileItem {
  func fillingMissingMetadata(from previousItems: [FileItem]) -> [FileItem] {
    guard !isEmpty, !previousItems.isEmpty else { return self }
    let previousByLocation = Dictionary(
      previousItems.lazy.map { ($0.location, $0) }, uniquingKeysWith: { first, _ in first })
    return map { item in
      guard let previous = previousByLocation[item.location] else { return item }
      return FileItem(item, fillingMissingMetadataFrom: previous)
    }
  }

  /// 複数選択時の合計サイズ。sizeが不明(nil)な項目は補完せず無視し、判明分のみ合計する。
  var totalKnownSize: Int64 {
    reduce(0) { $0 + ($1.size ?? 0) }
  }

  var displayTotalKnownSize: String {
    ByteCountFormatter.string(fromByteCount: totalKnownSize, countStyle: .file)
  }
}

enum FileItemSortOrder: String, CaseIterable, Identifiable, Equatable {
  case name = "名前"
  case kind = "種類"
  case size = "サイズ"
  case modifiedAt = "更新日時"

  var id: Self { self }

  var displayName: String {
    switch self {
    case .name: String(localized: "名前")
    case .kind: String(localized: "種類")
    case .size: String(localized: "サイズ")
    case .modifiedAt: String(localized: "更新日時")
    }
  }

  func areInIncreasingOrder(_ lhs: FileItem, _ rhs: FileItem, ascending: Bool) -> Bool {
    let primary: ComparisonResult
    switch self {
    case .name:
      primary = lhs.name.localizedStandardCompare(rhs.name)
    case .kind:
      if lhs.isDirectory == rhs.isDirectory {
        primary = .orderedSame
      } else {
        primary = lhs.isDirectory ? .orderedAscending : .orderedDescending
      }
    case .size:
      primary = compare(lhs.size ?? -1, rhs.size ?? -1)
    case .modifiedAt:
      primary = compare(lhs.modifiedAt ?? .distantPast, rhs.modifiedAt ?? .distantPast)
    }
    if primary != .orderedSame {
      return ascending ? primary == .orderedAscending : primary == .orderedDescending
    }
    let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
    if nameOrder != .orderedSame {
      return ascending ? nameOrder == .orderedAscending : nameOrder == .orderedDescending
    }
    return lhs.url.absoluteString < rhs.url.absoluteString
  }

  private func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
    if lhs < rhs { return .orderedAscending }
    if lhs > rhs { return .orderedDescending }
    return .orderedSame
  }
}

enum FileItemFilter {
  static func filteredAndSorted(
    _ items: [FileItem], matching query: String, matchMode: NameMatchMode,
    sortOrder: FileItemSortOrder,
    ascending: Bool
  ) -> [FileItem] {
    if query.isEmpty, sortOrder == .name, ascending {
      return items
    }
    let parsedQuery = SearchQueryParser.parse(query)
    // tag:がない入力は、既存どおり入力文字列全体を名前条件として扱う。
    let nameText = parsedQuery.hasTagTerms ? parsedQuery.nameText : query
    let nameMatcher = NameMatcher(pattern: nameText, mode: matchMode)
    let filtered: [FileItem]
    if nameText.isEmpty, !parsedQuery.hasTagTerms {
      filtered = items
    } else {
      filtered = items.filter { item in
        let matchesName = nameText.isEmpty || nameMatcher.matches(item.name)
        guard matchesName, parsedQuery.hasTagTerms, let tagNames = item.tags else {
          return matchesName && !parsedQuery.hasTagTerms
        }
        let normalizedTagNames = FinderTagEditing.normalizedNames(tagNames)
        return parsedQuery.tagTerms.allSatisfy { tagTerm in
          normalizedTagNames.contains { tagName in
            tagName.localizedCaseInsensitiveContains(tagTerm)
          }
        }
      }
    }
    return filtered.sorted {
      sortOrder.areInIncreasingOrder($0, $1, ascending: ascending)
    }
  }
}
