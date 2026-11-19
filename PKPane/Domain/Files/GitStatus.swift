import Foundation

enum GitStatusCachePolicy {
  static let directoryLimit = 128
}

/// 一覧へ表示するGit状態。複数の変更が同じ直下項目へ集約される場合はpriorityが高い状態を使う。
enum GitFileStatus: String, CaseIterable, Equatable, Sendable {
  case modified
  case added
  case untracked
  case conflicted

  fileprivate var priority: Int {
    switch self {
    case .modified:
      0
    case .added, .untracked:
      1
    case .conflicted:
      2
    }
  }
}

struct GitStatusEntry: Equatable, Sendable {
  let status: GitFileStatus
  let path: String
  let originalPath: String?
}

/// `git status --porcelain=v1 -z`の出力だけを扱う純粋なパーサー。
enum GitPorcelainParser {
  static func parse(_ data: Data) -> [GitStatusEntry] {
    let fields = data.split(separator: 0, omittingEmptySubsequences: true)
    var entries: [GitStatusEntry] = []
    var index = 0
    while index < fields.count {
      let field = fields[index]
      index += 1
      guard field.count >= 4, field[field.startIndex + 2] == 0x20 else { continue }

      let x = field[field.startIndex]
      let y = field[field.startIndex + 1]
      guard let status = status(x: x, y: y) else { continue }
      let path = String(decoding: field.dropFirst(3), as: UTF8.self)
      guard !path.isEmpty else { continue }

      let isRenameOrCopy =
        x == ascii("R") || x == ascii("C") || y == ascii("R")
        || y == ascii("C")
      let originalPath: String?
      if isRenameOrCopy, index < fields.count {
        originalPath = String(decoding: fields[index], as: UTF8.self)
        index += 1
      } else {
        originalPath = nil
      }
      entries.append(GitStatusEntry(status: status, path: path, originalPath: originalPath))
    }
    return entries
  }

  private static func status(x: UInt8, y: UInt8) -> GitFileStatus? {
    if x == ascii("!") && y == ascii("!") { return nil }
    if x == ascii("?") && y == ascii("?") { return .untracked }
    let pair = String(decoding: [x, y], as: UTF8.self)
    if ["DD", "AU", "UD", "UA", "DU", "AA", "UU"].contains(pair)
      || x == ascii("U") || y == ascii("U")
    {
      return .conflicted
    }
    if x == ascii("A") || y == ascii("A") { return .added }
    return .modified
  }

  private static func ascii(_ character: Character) -> UInt8 {
    character.asciiValue!
  }
}

/// リポジトリ相対のporcelain結果を、表示中ディレクトリの直下項目へ集約する純粋関数。
enum GitStatusProjection {
  static func directChildStatuses(
    from entries: [GitStatusEntry],
    repositoryRoot: URL,
    displayedDirectory: URL
  ) -> [URL: GitFileStatus] {
    let root = repositoryRoot.standardizedFileURL
    let directory = displayedDirectory.standardizedFileURL
    let rootComponents = root.pathComponents
    let directoryComponents = directory.pathComponents
    guard directoryComponents.starts(with: rootComponents) else { return [:] }
    let directoryRelativeComponents = Array(directoryComponents.dropFirst(rootComponents.count))

    var result: [URL: GitFileStatus] = [:]
    for entry in entries {
      var components = entry.path.split(
        separator: "/", omittingEmptySubsequences: false
      ).map(String.init)
      while components.last == "" { components.removeLast() }
      guard !components.isEmpty,
        !components.contains("."),
        !components.contains(".."),
        components.starts(with: directoryRelativeComponents),
        components.count > directoryRelativeComponents.count
      else { continue }

      let childName = components[directoryRelativeComponents.count]
      let childURL = directory.appending(path: childName).standardizedFileURL
      if let current = result[childURL], current.priority >= entry.status.priority {
        continue
      }
      result[childURL] = entry.status
    }
    return result
  }
}

protocol GitRepositoryLocating: Sendable {
  func repositoryRoot(containing directory: URL) async -> URL?
}

protocol GitStatusRunning: Sendable {
  func status(repositoryRoot: URL, directory: URL) async throws -> Data
}

protocol GitStatusProviding: Sendable {
  func statuses(in directory: URL) async -> [URL: GitFileStatus]
  func invalidate(directory: URL) async
}

@MainActor
protocol GitStatusPreferenceReading: AnyObject {
  var isEnabled: Bool { get }
}
