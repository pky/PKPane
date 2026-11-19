import Foundation

enum BatchRenameReplacementMode: CaseIterable, Equatable, Hashable, Sendable {
  case none
  case plain
  case regex
}

struct BatchRenameRule: Equatable, Sendable {
  var replacementMode: BatchRenameReplacementMode = .none
  var searchText = ""
  var replacementText = ""
  var isCaseSensitive = true
  var prefix = ""
  var suffix = ""
  var sequenceStart: Int?
  var sequencePadding = 0

  fileprivate func regularExpression() throws -> NSRegularExpression? {
    guard replacementMode == .regex else { return nil }
    let options: NSRegularExpression.Options = isCaseSensitive ? [] : [.caseInsensitive]
    return try NSRegularExpression(pattern: searchText, options: options)
  }

  fileprivate func renamedName(
    for item: FileItem,
    index: Int,
    regularExpression: NSRegularExpression?
  ) -> String {
    let replacedName: String
    switch replacementMode {
    case .none:
      replacedName = item.name
    case .plain:
      replacedName =
        searchText.isEmpty
        ? item.name
        : item.name.replacingOccurrences(of: searchText, with: replacementText)
    case .regex:
      guard let regularExpression else { return item.name }
      let range = NSRange(item.name.startIndex..<item.name.endIndex, in: item.name)
      replacedName = regularExpression.stringByReplacingMatches(
        in: item.name,
        range: range,
        withTemplate: replacementText
      )
    }

    let nameParts = Self.nameParts(of: replacedName, isDirectory: item.isDirectory)
    let sequence =
      sequenceStart.map { start in
        String(format: "%0*d", max(0, sequencePadding), start + index)
      } ?? ""
    let baseName = prefix + nameParts.baseName + suffix + sequence
    return nameParts.extensionName.isEmpty ? baseName : baseName + "." + nameParts.extensionName
  }

  private static func nameParts(
    of name: String,
    isDirectory: Bool
  ) -> (baseName: String, extensionName: String) {
    guard !isDirectory else { return (name, "") }
    let path = name as NSString
    let extensionName = path.pathExtension
    guard !extensionName.isEmpty else { return (name, "") }
    return (path.deletingPathExtension, extensionName)
  }
}

struct BatchRenamePreview: Identifiable, Equatable, Sendable {
  let item: FileItem
  let renamedName: String

  var id: URL { item.url }
  var hasChanged: Bool { item.name != renamedName }
}

enum BatchRenameValidationIssue: Identifiable, Equatable, Hashable, Sendable {
  case invalidPattern
  case invalidName(String)
  case duplicateName(String)
  case existingName(String)

  var id: String {
    switch self {
    case .invalidPattern: "invalid-pattern"
    case .invalidName(let name): "invalid-\(name)"
    case .duplicateName(let name): "duplicate-\(name)"
    case .existingName(let name): "existing-\(name)"
    }
  }

  var message: String {
    switch self {
    case .invalidPattern:
      String(localized: "正規表現が無効です")
    case .invalidName(let name):
      String(format: String(localized: "「%@」はファイル名として使用できません。"), name)
    case .duplicateName(let name):
      String(format: String(localized: "「%@」が選択項目内で重複します。"), name)
    case .existingName(let name):
      String(format: String(localized: "「%@」はフォルダ内に既に存在します。"), name)
    }
  }
}

struct BatchRenameValidation: Equatable, Sendable {
  let issues: [BatchRenameValidationIssue]

  var isSafe: Bool { issues.isEmpty }
}

struct BatchRenameSuccess: Equatable, Sendable {
  let parentLocation: FileLocation
  let oldName: String
  let newName: String
  let renamedItem: FileItem

  init(item: FileItem, newName: String) {
    parentLocation =
      item.location.deletingLastPathComponent()
      ?? item.location
    oldName = item.name
    self.newName = newName
    renamedItem = Self.makeRenamedItem(item, newName: newName, parent: parentLocation)
  }

  private static func makeRenamedItem(
    _ item: FileItem,
    newName: String,
    parent: FileLocation
  ) -> FileItem {
    let renamedURL = item.url.deletingLastPathComponent().appending(path: newName)
    if let remotePath = parent.appending(pathComponent: newName)?.remotePath {
      return FileItem(
        remotePath: remotePath,
        url: renamedURL,
        providerID: item.location.providerID,
        isDirectory: item.isDirectory,
        isSymbolicLink: item.isSymbolicLink,
        size: item.size,
        createdAt: item.createdAt,
        modifiedAt: item.modifiedAt,
        tags: item.tags,
        posixPermissions: item.posixPermissions,
        ownerName: item.ownerName,
        groupName: item.groupName
      )
    }
    return FileItem(
      url: renamedURL,
      providerID: item.location.providerID,
      isDirectory: item.isDirectory,
      isSymbolicLink: item.isSymbolicLink,
      isAliasFile: item.isAliasFile,
      size: item.size,
      createdAt: item.createdAt,
      modifiedAt: item.modifiedAt,
      tags: item.tags,
      posixPermissions: item.posixPermissions,
      ownerName: item.ownerName,
      groupName: item.groupName
    )
  }
}

struct BatchRenameFailure: Equatable, Sendable {
  let itemName: String
  let newName: String
  let error: PKPaneError
}

struct BatchRenameResult: Equatable, Sendable {
  let requestedCount: Int
  let successes: [BatchRenameSuccess]
  let failures: [BatchRenameFailure]

  var partialFailureError: PKPaneError? {
    guard !failures.isEmpty else { return nil }
    let displayedNames = failures.prefix(3).map { "「\($0.itemName)」" }.joined(separator: "、")
    let remainingCount = failures.count - min(3, failures.count)
    let subjectSummary =
      remainingCount > 0
      ? String(
        format: String(localized: "%@、ほか%ld件"), displayedNames, remainingCount)
      : displayedNames
    return PKPaneError(
      category: .partialFailure,
      userMessage: String(
        format: String(localized: "%1$ld件中%2$ld件を変更できませんでした。"),
        requestedCount,
        failures.count
      ),
      recoverySuggestion: String(
        format: String(localized: "失敗した項目: %@"), subjectSummary)
    )
  }
}

enum BatchRenamePreviewBuilder {
  static func make(items: [FileItem], rule: BatchRenameRule) -> [BatchRenamePreview] {
    let regularExpression = try? rule.regularExpression()
    return items.enumerated().map { index, item in
      BatchRenamePreview(
        item: item,
        renamedName: rule.renamedName(
          for: item,
          index: index,
          regularExpression: regularExpression
        )
      )
    }
  }
}

enum BatchRenameValidator {
  static func validate(
    renames: [(item: FileItem, newName: String)],
    existingItems: [FileItem]
  ) -> BatchRenameValidation {
    validate(
      previews: renames.map {
        BatchRenamePreview(item: $0.item, renamedName: $0.newName)
      },
      existingItems: existingItems,
      rule: BatchRenameRule()
    )
  }

  static func validate(
    previews: [BatchRenamePreview],
    existingItems: [FileItem],
    rule: BatchRenameRule
  ) -> BatchRenameValidation {
    if rule.replacementMode == .regex {
      do {
        _ = try rule.regularExpression()
      } catch {
        return BatchRenameValidation(issues: [.invalidPattern])
      }
    }

    let renamedPreviews = previews.filter(\.hasChanged)
    let invalidNames = Set(
      renamedPreviews.map(\.renamedName).filter { !isValidName($0) }
    )
    let previewsByName = Dictionary(grouping: previews) { normalizedName($0.renamedName) }
    let duplicateNames = Set(
      previewsByName.values.compactMap { matchingPreviews in
        matchingPreviews.count > 1 ? matchingPreviews.first?.renamedName : nil
      }
    )
    let duplicateNormalizedNames = Set(duplicateNames.map(normalizedName))
    let occupiedNames = Set(
      renamedPreviews.compactMap { preview -> String? in
        let targetName = normalizedName(preview.renamedName)
        guard !duplicateNormalizedNames.contains(targetName) else { return nil }
        let collides = existingItems.contains { item in
          item.url != preview.item.url && normalizedName(item.name) == targetName
        }
        return collides ? preview.renamedName : nil
      }
    )
    let issues =
      invalidNames.sorted(by: localizedNameOrder).map(BatchRenameValidationIssue.invalidName)
      + duplicateNames.sorted(by: localizedNameOrder).map(BatchRenameValidationIssue.duplicateName)
      + occupiedNames.sorted(by: localizedNameOrder).map(BatchRenameValidationIssue.existingName)
    return BatchRenameValidation(issues: issues)
  }

  private static func isValidName(_ name: String) -> Bool {
    !name.isEmpty
      && name != "."
      && name != ".."
      && !name.contains("/")
      && !name.unicodeScalars.contains { $0.value == 0 }
  }

  private static func normalizedName(_ name: String) -> String {
    name.folding(options: .caseInsensitive, locale: .current)
  }

  private static func localizedNameOrder(_ lhs: String, _ rhs: String) -> Bool {
    lhs.localizedStandardCompare(rhs) == .orderedAscending
  }
}
