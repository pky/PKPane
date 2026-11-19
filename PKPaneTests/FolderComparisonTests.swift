import Foundation
import Synchronization
import Testing

@testable import PKPane

struct FolderComparisonMatcherTests {
  @Test("サイズと日時だけの一致は内容一致と表示せず、欠落情報と型違いを区別する")
  func describesOnlyAvailableMetadata() throws {
    let date = Date(timeIntervalSince1970: 10_000)
    let complete = FolderComparisonMatcher.compare(
      left: [record("same.txt", size: 4, modifiedAt: date, side: .left)],
      right: [record("same.txt", size: 4, modifiedAt: date.addingTimeInterval(2), side: .right)])
    let matching = try #require(complete.first)
    #expect(matching.status == .identical)
    #expect(matching.comparisonDescription == String(localized: "サイズ・更新日時が一致"))
    let missing = FolderComparisonMatcher.compare(
      left: [record("missing.txt", size: 4, side: .left)],
      right: [record("missing.txt", size: 4, side: .right)])
    let incomplete = try #require(missing.first)
    #expect(incomplete.status == .identical)
    #expect(incomplete.hasIncompleteMetadata)
    #expect(incomplete.comparisonDescription == String(localized: "比較情報が不足"))
    let directory = FileItem(url: URL(filePath: "/directory"), isDirectory: true)
    let file = FileItem(url: URL(filePath: "/file"), isDirectory: false)
    let differentType = FolderComparisonEntry(
      relativePath: "item", status: .different, leftItem: directory, rightItem: file)
    #expect(differentType.comparisonDescription == String(localized: "種類が異なる"))
  }

  @Test("相対パスで左右のみ・差異・同一を分類する")
  func classifiesEveryStatus() {
    let baseDate = Date(timeIntervalSince1970: 10_000)
    let left = [
      record("left.txt", size: 1, modifiedAt: baseDate, side: .left),
      record("size.txt", size: 2, modifiedAt: baseDate, side: .left),
      record("date.txt", size: 3, modifiedAt: baseDate, side: .left),
      record("same.txt", size: 4, modifiedAt: baseDate, side: .left),
    ]
    let right = [
      record("right.txt", size: 1, modifiedAt: baseDate, side: .right),
      record("size.txt", size: 20, modifiedAt: baseDate, side: .right),
      record("date.txt", size: 3, modifiedAt: baseDate.addingTimeInterval(3), side: .right),
      record("same.txt", size: 4, modifiedAt: baseDate.addingTimeInterval(2), side: .right),
    ]

    let statuses = Dictionary(
      uniqueKeysWithValues: FolderComparisonMatcher.compare(left: left, right: right)
        .map { ($0.relativePath, $0.status) })

    #expect(statuses["left.txt"] == .leftOnly)
    #expect(statuses["right.txt"] == .rightOnly)
    #expect(statuses["size.txt"] == .different)
    #expect(statuses["date.txt"] == .different)
    #expect(statuses["same.txt"] == .identical)
  }

  @Test("ネストしたパスと大文字小文字の違いを別項目として保つ")
  func preservesNestedAndCaseSensitivePaths() {
    let left = [
      record("folder/report.txt", size: 1, side: .left),
      record("Readme.md", size: 2, side: .left),
    ]
    let right = [
      record("folder/report.txt", size: 1, side: .right),
      record("README.md", size: 2, side: .right),
    ]

    let entries = FolderComparisonMatcher.compare(left: left, right: right)

    #expect(entries.first { $0.relativePath == "folder/report.txt" }?.status == .identical)
    #expect(entries.first { $0.relativePath == "Readme.md" }?.status == .leftOnly)
    #expect(entries.first { $0.relativePath == "README.md" }?.status == .rightOnly)
  }

  private func record(
    _ path: String,
    size: Int64,
    modifiedAt: Date? = nil,
    side: FolderComparisonSide
  ) -> FolderComparisonRecord {
    let providerID = FileProviderID(rawValue: "matcher-\(side)")
    return FolderComparisonRecord(
      relativePath: path,
      item: FileItem(
        remotePath: "/\(path)",
        url: URL(string: "comparison://\(side)/\(path)")!,
        providerID: providerID,
        isDirectory: false,
        size: size,
        modifiedAt: modifiedAt))
  }
}

struct FolderComparisonEngineTests {
  @Test("左右を再帰列挙しシンボリックリンクを除外する")
  func recursivelyEnumeratesBothSidesAndSkipsSymbolicLinks() async throws {
    let left = ComparisonFixture(
      id: "left",
      tree: [
        "/left": [
          directory("nested", parent: "/left", providerID: "left"),
          item("root.txt", parent: "/left", providerID: "left", size: 1),
          item(
            "link", parent: "/left", providerID: "left", size: 0,
            isSymbolicLink: true),
        ],
        "/left/nested": [
          item("deep.txt", parent: "/left/nested", providerID: "left", size: 2)
        ],
      ])
    let right = ComparisonFixture(
      id: "right",
      tree: [
        "/right": [
          directory("nested", parent: "/right", providerID: "right"),
          item("root.txt", parent: "/right", providerID: "right", size: 1),
        ],
        "/right/nested": [
          item("deep.txt", parent: "/right/nested", providerID: "right", size: 3)
        ],
      ])
    let updates = await collect(
      from: FolderComparisonEngine(leftProvider: left.provider, rightProvider: right.provider),
      leftRoot: location("/left", providerID: left.provider.id),
      rightRoot: location("/right", providerID: right.provider.id))
    let snapshot = try #require(finishedSnapshot(in: updates))

    #expect(snapshot.entries.first { $0.relativePath == "root.txt" }?.status == .identical)
    #expect(snapshot.entries.first { $0.relativePath == "nested/deep.txt" }?.status == .different)
    #expect(!snapshot.entries.contains { $0.relativePath == "link" })
    #expect(snapshot.skippedSymbolicLinkCount == 1)
    #expect(snapshot.enumeratedItemCount == 7)
  }

  @Test("左右合算のディレクトリ並行数を指定上限内に抑える")
  func limitsCombinedDirectoryConcurrency() async {
    let sharedState = ComparisonFixtureState(
      trees: [
        "left": makeWideTree(root: "/left", providerID: "left"),
        "right": makeWideTree(root: "/right", providerID: "right"),
      ],
      failingPaths: [],
      delayedPaths: Set(
        (0..<5).flatMap { index in ["left:/left/d\(index)", "right:/right/d\(index)"] }),
      delay: .milliseconds(20))
    let left = ComparisonFixtureProvider(id: "left", state: sharedState)
    let right = ComparisonFixtureProvider(id: "right", state: sharedState)

    _ = await collect(
      from: FolderComparisonEngine(
        leftProvider: left,
        rightProvider: right,
        maximumConcurrentDirectories: 3),
      leftRoot: location("/left", providerID: left.id),
      rightRoot: location("/right", providerID: right.id))

    #expect(await sharedState.maximumConcurrentRequestCount() == 3)
  }

  @Test("読めないフォルダを部分エラーとして数え他方を継続する")
  func continuesAfterPartialError() async throws {
    let left = ComparisonFixture(
      id: "left",
      tree: [
        "/left": [
          directory("broken", parent: "/left", providerID: "left"),
          directory("healthy", parent: "/left", providerID: "left"),
        ],
        "/left/healthy": [
          item("visible.txt", parent: "/left/healthy", providerID: "left", size: 1)
        ],
      ],
      failingPaths: ["left:/left/broken"])
    let right = ComparisonFixture(id: "right", tree: ["/right": []])

    let updates = await collect(
      from: FolderComparisonEngine(leftProvider: left.provider, rightProvider: right.provider),
      leftRoot: location("/left", providerID: left.provider.id),
      rightRoot: location("/right", providerID: right.provider.id))
    let snapshot = try #require(finishedSnapshot(in: updates))

    #expect(snapshot.partialErrorCount == 1)
    #expect(snapshot.entries.contains { $0.relativePath == "healthy/visible.txt" })
    #expect(
      updates.contains {
        guard case .partialError(let error) = $0 else { return false }
        return error.side == .left && error.location.remotePath == "/left/broken"
      })
  }

  @Test("項目上限で打ち切って通知する")
  func stopsAtItemLimit() async throws {
    let left = ComparisonFixture(
      id: "left",
      tree: [
        "/left": (0..<8).map {
          item("item-\($0)", parent: "/left", providerID: "left", size: Int64($0))
        }
      ])
    let right = ComparisonFixture(id: "right", tree: ["/right": []])

    let updates = await collect(
      from: FolderComparisonEngine(
        leftProvider: left.provider,
        rightProvider: right.provider,
        itemLimit: 5),
      leftRoot: location("/left", providerID: left.provider.id),
      rightRoot: location("/right", providerID: right.provider.id))
    let snapshot = try #require(finishedSnapshot(in: updates))

    #expect(snapshot.enumeratedItemCount == 5)
    #expect(snapshot.entries.count == 5)
    #expect(snapshot.didReachItemLimit)
    #expect(updates.contains(.limitReached(5)))
    #expect(FolderComparisonEngine.maximumItemCount == 50_000)
  }

  @Test("ストリーム消費のキャンセル後は完了を通知せずProvider列挙を止める")
  func cancellationStopsEnumeration() async {
    let left = ComparisonFixture(
      id: "left",
      tree: [
        "/left": [directory("slow", parent: "/left", providerID: "left")],
        "/left/slow": [item("late.txt", parent: "/left/slow", providerID: "left", size: 1)],
      ],
      delayedPaths: ["left:/left/slow"])
    let right = ComparisonFixture(id: "right", tree: ["/right": []])
    let recorder = ComparisonUpdateRecorder()
    let engine = FolderComparisonEngine(leftProvider: left.provider, rightProvider: right.provider)
    let consumer = Task {
      let stream = await engine.compare(
        leftRoot: location("/left", providerID: left.provider.id),
        rightRoot: location("/right", providerID: right.provider.id))
      for await update in stream { recorder.append(update) }
    }

    await waitUntil { recorder.progressCount > 0 }
    consumer.cancel()
    _ = await consumer.result
    await waitUntil { await left.state.cancellationCount() > 0 }

    #expect(!recorder.containsFinished)
  }

  private func collect(
    from engine: FolderComparisonEngine,
    leftRoot: FileLocation,
    rightRoot: FileLocation
  ) async -> [FolderComparisonUpdate] {
    var updates = [FolderComparisonUpdate]()
    let stream = await engine.compare(leftRoot: leftRoot, rightRoot: rightRoot)
    for await update in stream { updates.append(update) }
    return updates
  }

  private func finishedSnapshot(
    in updates: [FolderComparisonUpdate]
  ) -> FolderComparisonSnapshot? {
    updates.compactMap { update -> FolderComparisonSnapshot? in
      guard case .finished(let snapshot) = update else { return nil }
      return snapshot
    }.last
  }

  private func makeWideTree(
    root: String,
    providerID: String
  ) -> [String: [FileItem]] {
    var tree = [root: (0..<5).map { directory("d\($0)", parent: root, providerID: providerID) }]
    for index in 0..<5 {
      tree["\(root)/d\(index)"] = [
        item("file", parent: "\(root)/d\(index)", providerID: providerID, size: 1)
      ]
    }
    return tree
  }

  private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async {
    await PKPaneTests.waitUntil("フォルダ比較の状態が期限内に条件を満たさなかった") {
      await condition()
    }
  }
}

private struct ComparisonFixture: Sendable {
  let state: ComparisonFixtureState
  let provider: ComparisonFixtureProvider

  init(
    id: String,
    tree: [String: [FileItem]],
    failingPaths: Set<String> = [],
    delayedPaths: Set<String> = [],
    delay: Duration = .seconds(10)
  ) {
    let state = ComparisonFixtureState(
      trees: [id: tree],
      failingPaths: failingPaths,
      delayedPaths: delayedPaths,
      delay: delay)
    self.state = state
    provider = ComparisonFixtureProvider(id: id, state: state)
  }
}

private actor ComparisonFixtureState {
  private let trees: [String: [String: [FileItem]]]
  private let failingPaths: Set<String>
  private let delayedPaths: Set<String>
  private let delay: Duration
  private var activeRequests = 0
  private var maximumActiveRequests = 0
  private var cancellations = 0

  init(
    trees: [String: [String: [FileItem]]],
    failingPaths: Set<String>,
    delayedPaths: Set<String>,
    delay: Duration
  ) {
    self.trees = trees
    self.failingPaths = failingPaths
    self.delayedPaths = delayedPaths
    self.delay = delay
  }

  func contents(providerID: String, path: String) async throws -> [FileItem] {
    let key = "\(providerID):\(path)"
    activeRequests += 1
    maximumActiveRequests = max(maximumActiveRequests, activeRequests)
    defer { activeRequests -= 1 }
    if delayedPaths.contains(key) {
      do {
        try await Task.sleep(for: delay)
      } catch {
        cancellations += 1
        throw error
      }
    }
    if failingPaths.contains(key) { throw ComparisonFixtureError.unreadable }
    return trees[providerID]?[path] ?? []
  }

  func maximumConcurrentRequestCount() -> Int { maximumActiveRequests }
  func cancellationCount() -> Int { cancellations }
}

private struct ComparisonFixtureProvider: FileBrowserProvider {
  let id: FileProviderID
  let state: ComparisonFixtureState
  let connectionID: FileProviderConnectionID? = nil
  let capabilities: FileProviderCapabilities = [.read]

  init(id: String, state: ComparisonFixtureState) {
    self.id = FileProviderID(rawValue: id)
    self.state = state
  }

  func contents(of location: FileLocation) async throws -> [FileItem] {
    try await state.contents(providerID: id.rawValue, path: location.remotePath ?? "")
  }

  func parent(of _: FileLocation) -> FileLocation? { nil }

  func breadcrumbs(
    for _: FileLocation,
    constrainedTo _: FileLocation?
  ) -> [FileBrowserBreadcrumb] { [] }
}

private enum ComparisonFixtureError: LocalizedError {
  case unreadable

  var errorDescription: String? { "テスト用の列挙失敗" }
}

private final class ComparisonUpdateRecorder: @unchecked Sendable {
  private let updates = Mutex<[FolderComparisonUpdate]>([])

  var progressCount: Int {
    updates.withLock { values in
      values.count { if case .progress = $0 { true } else { false } }
    }
  }
  var containsFinished: Bool {
    updates.withLock { values in
      values.contains { if case .finished = $0 { true } else { false } }
    }
  }

  func append(_ update: FolderComparisonUpdate) {
    updates.withLock { $0.append(update) }
  }
}

private func location(_ path: String, providerID: FileProviderID) -> FileLocation {
  FileLocation(remotePath: path, providerID: providerID)
}

private func item(
  _ name: String,
  parent: String,
  providerID: String,
  size: Int64,
  isSymbolicLink: Bool = false
) -> FileItem {
  let path = parent == "/" ? "/\(name)" : "\(parent)/\(name)"
  return FileItem(
    remotePath: path,
    url: URL(string: "comparison://\(providerID)\(path)")!,
    providerID: FileProviderID(rawValue: providerID),
    isDirectory: false,
    isSymbolicLink: isSymbolicLink,
    size: size)
}

private func directory(_ name: String, parent: String, providerID: String) -> FileItem {
  let path = parent == "/" ? "/\(name)" : "\(parent)/\(name)"
  return FileItem(
    remotePath: path,
    url: URL(string: "comparison://\(providerID)\(path)")!,
    providerID: FileProviderID(rawValue: providerID),
    isDirectory: true)
}
