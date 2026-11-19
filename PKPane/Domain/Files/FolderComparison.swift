import Foundation

enum FolderComparisonSide: Sendable, Equatable {
  case left
  case right
}

enum FolderComparisonCopyDirection: Sendable, Equatable {
  case left
  case right
}

enum FolderComparisonStatus: String, CaseIterable, Identifiable, Sendable {
  case leftOnly
  case rightOnly
  case different
  case identical

  var id: Self { self }

  var displayName: String {
    switch self {
    case .leftOnly:
      String(localized: "左のみ")
    case .rightOnly:
      String(localized: "右のみ")
    case .different:
      String(localized: "サイズ・更新日時が異なる")
    case .identical:
      String(localized: "サイズ・更新日時が一致")
    }
  }
}

struct FolderComparisonRecord: Equatable, Sendable {
  let relativePath: String
  let item: FileItem
}

struct FolderComparisonEntry: Identifiable, Equatable, Sendable {
  let relativePath: String
  let status: FolderComparisonStatus
  let leftItem: FileItem?
  let rightItem: FileItem?

  var id: String { relativePath }

  var hasIncompleteMetadata: Bool {
    guard let leftItem, let rightItem else { return false }
    return leftItem.size == nil || rightItem.size == nil
      || leftItem.modifiedAt == nil || rightItem.modifiedAt == nil
  }

  var comparisonDescription: String {
    guard let leftItem, let rightItem else { return status.displayName }
    if leftItem.isDirectory != rightItem.isDirectory {
      return String(localized: "種類が異なる")
    }
    if hasIncompleteMetadata { return String(localized: "比較情報が不足") }
    return status.displayName
  }
}

struct FolderComparisonSnapshot: Equatable, Sendable {
  let leftRoot: FileLocation
  let rightRoot: FileLocation
  let entries: [FolderComparisonEntry]
  let enumeratedItemCount: Int
  let skippedSymbolicLinkCount: Int
  let partialErrorCount: Int
  let didReachItemLimit: Bool
}

struct FolderComparisonProgress: Equatable, Sendable {
  let enumeratedItemCount: Int
  let skippedSymbolicLinkCount: Int
  let partialErrorCount: Int
}

struct FolderComparisonPartialError: Equatable, Sendable {
  let side: FolderComparisonSide
  let location: FileLocation
  let message: String
}

enum FolderComparisonUpdate: Equatable, Sendable {
  case progress(FolderComparisonProgress)
  case partialError(FolderComparisonPartialError)
  case limitReached(Int)
  case finished(FolderComparisonSnapshot)
}

/// 左右の列挙結果を相対パスで突き合わせる純粋関数です。パスの大文字小文字は
/// Providerの規則へ寄せず、文字列として区別します。
enum FolderComparisonMatcher {
  static let defaultTimestampTolerance: TimeInterval = 2

  static func compare(
    left: [FolderComparisonRecord],
    right: [FolderComparisonRecord],
    timestampTolerance: TimeInterval = defaultTimestampTolerance
  ) -> [FolderComparisonEntry] {
    let leftByPath = Dictionary(
      left.map { ($0.relativePath, $0.item) },
      uniquingKeysWith: { first, _ in first })
    let rightByPath = Dictionary(
      right.map { ($0.relativePath, $0.item) },
      uniquingKeysWith: { first, _ in first })
    let paths = Set(leftByPath.keys).union(rightByPath.keys).sorted()

    return paths.map { path in
      let leftItem = leftByPath[path]
      let rightItem = rightByPath[path]
      let status: FolderComparisonStatus
      switch (leftItem, rightItem) {
      case (.some, .none):
        status = .leftOnly
      case (.none, .some):
        status = .rightOnly
      case (.some(let leftItem), .some(let rightItem)):
        status =
          itemsMatch(
            leftItem,
            rightItem,
            timestampTolerance: timestampTolerance) ? .identical : .different
      case (.none, .none):
        preconditionFailure("比較対象のない相対パスが生成されました。")
      }
      return FolderComparisonEntry(
        relativePath: path,
        status: status,
        leftItem: leftItem,
        rightItem: rightItem)
    }
  }

  private static func itemsMatch(
    _ left: FileItem,
    _ right: FileItem,
    timestampTolerance: TimeInterval
  ) -> Bool {
    guard left.isDirectory == right.isDirectory,
      left.size == right.size
    else {
      return false
    }
    switch (left.modifiedAt, right.modifiedAt) {
    case (.none, .none):
      return true
    case (.some(let leftDate), .some(let rightDate)):
      return abs(leftDate.timeIntervalSince(rightDate)) <= timestampTolerance
    case (.none, .some), (.some, .none):
      return false
    }
  }
}

enum FolderComparisonPath {
  static func parentDirectory(
    for relativePath: String,
    under root: FileLocation
  ) -> FileLocation? {
    let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
    guard !components.isEmpty else { return nil }
    return components.dropLast().reduce(Optional(root)) { location, component in
      location?.appending(pathComponent: String(component))
    }
  }
}
