import AppKit
import Foundation

/// Finderが標準で使う7色と、色を持たないタグ。
enum FinderTagColor: Int, CaseIterable, Equatable, Sendable {
  case none = 0
  case gray = 1
  case green = 2
  case purple = 3
  case blue = 4
  case yellow = 5
  case red = 6
  case orange = 7
}

struct FinderTag: Equatable, Sendable {
  let name: String
  let color: FinderTagColor
}

/// URLResourceValues.tagNamesの値を、Finderの標準ラベル名と色へ変換する純関数群。
/// Finderの拡張属性由来の値には「タグ名\n色番号」が含まれる場合があるため、色番号を
/// 最優先し、番号がない標準名だけNSWorkspace.fileLabelsの順序で補完する。
enum FinderTagPalette {
  @MainActor
  static var systemLabelNames: [String] {
    NSWorkspace.shared.fileLabels
  }

  static func tags(
    from tagNames: [String]?,
    standardLabelNames: [String]
  ) -> [FinderTag] {
    (tagNames ?? []).compactMap { rawName in
      let components = rawName.split(
        separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
      guard let first = components.first else { return nil }
      let name = String(first)
      guard !name.isEmpty else { return nil }

      let encodedColor = components.count == 2 ? Int(components[1]) : nil
      let standardColor = standardLabelNames.firstIndex(of: name)
      let color = FinderTagColor(rawValue: encodedColor ?? standardColor ?? 0) ?? .none
      return FinderTag(name: name, color: color)
    }
  }

  @MainActor
  static func systemTags(from tagNames: [String]?) -> [FinderTag] {
    tags(from: tagNames, standardLabelNames: systemLabelNames)
  }

  @MainActor
  static func nsColor(for color: FinderTagColor) -> NSColor {
    let systemColors = NSWorkspace.shared.fileLabelColors
    guard systemColors.indices.contains(color.rawValue) else { return .clear }
    return systemColors[color.rawValue]
  }
}

struct FinderTagMutation: Equatable, Sendable {
  let additions: [String]
  let removals: Set<String>

  var isEmpty: Bool { additions.isEmpty && removals.isEmpty }

  func applying(to tagNames: [String]?) -> [String] {
    var result = FinderTagEditing.normalizedNames(tagNames ?? []).filter {
      !removals.contains($0)
    }
    for addition in additions where !result.contains(addition) {
      result.append(addition)
    }
    return result
  }
}

struct FinderTagUpdateResult: Equatable, Sendable {
  let items: [FileItem]
  let failedCount: Int
  let firstErrorDescription: String?

  var errorMessage: String? {
    guard failedCount > 0 else { return nil }
    if let firstErrorDescription {
      return "\(failedCount)件のタグ変更に失敗しました。\(firstErrorDescription)"
    }
    return "\(failedCount)件のタグ変更に失敗しました。"
  }
}

enum FinderTagEditing {
  static func normalizedNames(_ tagNames: [String]) -> [String] {
    var seen = Set<String>()
    return tagNames.compactMap { rawName in
      let name =
        rawName.split(
          separator: "\n", maxSplits: 1, omittingEmptySubsequences: false
        ).first.map(String.init)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !name.isEmpty, seen.insert(name).inserted else { return nil }
      return name
    }
  }

  static func commonNames(in items: [FileItem]) -> [String] {
    guard let first = items.first else { return [] }
    let firstNames = normalizedNames(first.tags ?? [])
    let common = items.dropFirst().reduce(Set(firstNames)) { result, item in
      result.intersection(normalizedNames(item.tags ?? []))
    }
    return firstNames.filter(common.contains)
  }

  static func mutation(from currentNames: [String], to requestedNames: [String])
    -> FinderTagMutation
  {
    let current = normalizedNames(currentNames)
    let requested = normalizedNames(requestedNames)
    let currentSet = Set(current)
    let requestedSet = Set(requested)
    return FinderTagMutation(
      additions: requested.filter { !currentSet.contains($0) },
      removals: currentSet.subtracting(requestedSet))
  }
}

struct FinderTagDisplaySummary: Equatable, Sendable {
  let visibleTags: [FinderTag]
  let omittedCount: Int

  static func make(from tags: [FinderTag], maximumVisibleCount: Int = 3) -> Self {
    let limit = max(0, maximumVisibleCount)
    return Self(
      visibleTags: Array(tags.prefix(limit)),
      omittedCount: max(0, tags.count - limit))
  }
}
