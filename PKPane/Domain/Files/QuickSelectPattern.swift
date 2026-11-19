import Foundation

/// Quick Select の入力パターンをファイル名へ照合する純粋な値型。
/// `*` と `?` を含む場合は名前全体へワイルドカード照合し、含まない場合は部分一致する。
struct QuickSelectPattern {
  let value: String
  let isCaseSensitive: Bool
  let interpretsAsRegex: Bool

  private let wildcardExpression: NSRegularExpression?
  private let regexMatcher: NameMatcher?

  init(_ value: String, isCaseSensitive: Bool, interpretsAsRegex: Bool = false) {
    self.value = value
    self.isCaseSensitive = isCaseSensitive
    self.interpretsAsRegex = interpretsAsRegex

    if interpretsAsRegex {
      wildcardExpression = nil
      regexMatcher = NameMatcher(
        pattern: value,
        mode: .regex,
        isCaseSensitive: isCaseSensitive)
      return
    }
    regexMatcher = nil

    guard value.contains("*") || value.contains("?") else {
      wildcardExpression = nil
      return
    }

    let body = value.reduce(into: "") { expression, character in
      switch character {
      case "*":
        expression += ".*"
      case "?":
        expression += "."
      default:
        expression += NSRegularExpression.escapedPattern(for: String(character))
      }
    }
    wildcardExpression = try? NSRegularExpression(
      pattern: "^\(body)$",
      options: isCaseSensitive ? [] : [.caseInsensitive])
  }

  var isValid: Bool {
    regexMatcher?.isValid ?? true
  }

  func matches(_ name: String) -> Bool {
    guard !value.isEmpty else { return false }
    if let regexMatcher {
      return regexMatcher.matches(name)
    }
    if let wildcardExpression {
      let range = NSRange(name.startIndex..<name.endIndex, in: name)
      return wildcardExpression.firstMatch(in: name, range: range) != nil
    }
    let options: String.CompareOptions = isCaseSensitive ? [] : [.caseInsensitive]
    return name.range(of: value, options: options) != nil
  }
}

enum QuickSelectMode: String, CaseIterable, Identifiable, Sendable {
  case replace
  case add
  case remove

  var id: Self { self }

  var displayName: String {
    switch self {
    case .replace: "新規選択"
    case .add: "現在の選択に追加"
    case .remove: "現在の選択から解除"
    }
  }
}

/// 表示済み項目と現在の選択から、Quick Select 適用後の選択を計算する純粋関数。
enum QuickSelectSelection {
  static func applying(
    pattern: QuickSelectPattern,
    mode: QuickSelectMode,
    to items: [FileItem],
    currentSelection: Set<URL>
  ) -> Set<URL> {
    let matchedURLs = Set(items.lazy.filter { pattern.matches($0.name) }.map(\.url))
    guard !matchedURLs.isEmpty else { return currentSelection }

    switch mode {
    case .replace:
      return matchedURLs
    case .add:
      return currentSelection.union(matchedURLs)
    case .remove:
      return currentSelection.subtracting(matchedURLs)
    }
  }

  /// カラム表示では、選択を持つ最深カラムを対象にする。どのカラムにも選択がなければ
  /// 左端を返す。読み込み中などでカラム自体がなければ nil とする。
  static func activeColumn(in columns: [FileBrowserColumn]) -> FileBrowserColumn? {
    columns.last(where: { !$0.selectedItemURLs.isEmpty }) ?? columns.first
  }
}
