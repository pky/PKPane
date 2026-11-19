import Foundation
import Synchronization
import Testing

@testable import PKPane

struct ProviderSearchEngineTests {
  @Test("BFSは深い一致より浅い階層の一致を先に返す")
  func returnsShallowMatchesBeforeDeepMatches() async {
    let fixture = SearchFixture(
      tree: [
        "/": [item("root-hit.txt", parent: "/"), directory("level-one", parent: "/")],
        "/level-one": [
          item("shallow-hit.txt", parent: "/level-one"),
          directory("level-two", parent: "/level-one"),
        ],
        "/level-one/level-two": [item("deep-hit.txt", parent: "/level-one/level-two")],
      ])
    let updates = await collect(
      ProviderSearchEngine(provider: fixture.provider, includesHiddenItems: false)
        .search(query(text: "hit", providerID: fixture.provider.id)))

    #expect(resultNames(in: updates) == ["root-hit.txt", "shallow-hit.txt", "deep-hit.txt"])
    #expect(updates.last == .finished(generation(in: updates)))
  }

  @Test("正規表現モードはBFS列挙中の名前だけを正規表現で照合する")
  func searchesWithRegularExpression() async {
    let fixture = SearchFixture(
      tree: [
        "/": [
          item("report-42.txt", parent: "/"),
          item("REPORT-7.TXT", parent: "/"),
          item("old-report-42.txt", parent: "/"),
          item("report-final.txt", parent: "/"),
        ]
      ])
    let updates = await collect(
      ProviderSearchEngine(provider: fixture.provider, includesHiddenItems: false)
        .search(
          query(
            text: "^report-[0-9]+\\.txt$",
            providerID: fixture.provider.id,
            nameMatchMode: .regex)))

    #expect(Set(resultNames(in: updates)) == ["report-42.txt", "REPORT-7.TXT"])
  }

  @Test("一致結果は100件ごとのバッチへ分割する")
  func splitsResultsIntoHundredItemBatches() async {
    let fixture = SearchFixture(
      tree: [
        "/": (0..<250).map { item("match-\($0).txt", parent: "/") }
      ])
    let updates = await collect(
      ProviderSearchEngine(provider: fixture.provider, includesHiddenItems: false)
        .search(query(text: "match", providerID: fixture.provider.id)))

    let batchSizes = updates.compactMap { update -> Int? in
      guard case .results(let results, _) = update else { return nil }
      return results.count
    }
    #expect(batchSizes == [100, 100, 50])
  }

  @Test("結果上限へ達すると列挙を打ち切って通知する")
  func stopsAtResultLimit() async {
    let fixture = SearchFixture(
      tree: [
        "/": (0..<8).map { item("match-\($0).txt", parent: "/") }
      ])
    let generation = UUID()
    let updates = await collect(
      ProviderSearchEngine(
        provider: fixture.provider,
        includesHiddenItems: false,
        resultLimit: 5
      ).search(
        SearchQuery(
          text: "match", root: location("/", providerID: fixture.provider.id),
          scope: .currentFolder, generation: generation)))

    #expect(resultNames(in: updates).count == 5)
    #expect(updates.contains(.limitReached(.results(5), generation: generation)))
    #expect(updates.last == .finished(generation))
    #expect(ProviderSearchEngine.maximumResultCount == 20_000)
  }

  @Test("一致件数が結果上限ちょうどなら切り捨て通知を出さない")
  func doesNotReportLimitWithoutTruncatedResult() async {
    let fixture = SearchFixture(
      tree: [
        "/": (0..<5).map { item("match-\($0).txt", parent: "/") }
      ])
    let updates = await collect(
      ProviderSearchEngine(
        provider: fixture.provider,
        includesHiddenItems: false,
        resultLimit: 5
      ).search(query(text: "match", providerID: fixture.provider.id)))

    #expect(resultNames(in: updates).count == 5)
    #expect(!updates.contains { if case .limitReached = $0 { true } else { false } })
  }

  @Test("訪問フォルダ数の上限で一致なしの走査も収束する")
  func stopsAtVisitedDirectoryLimit() async {
    let fixture = SearchFixture(
      tree: [
        "/": [
          directory("first", parent: "/"),
          directory("second", parent: "/"),
          directory("third", parent: "/"),
        ]
      ])
    let generation = UUID()
    let updates = await collect(
      ProviderSearchEngine(
        provider: fixture.provider,
        includesHiddenItems: false,
        visitedDirectoryLimit: 2
      ).search(
        SearchQuery(
          text: "missing", root: location("/", providerID: fixture.provider.id),
          scope: .currentFolder, generation: generation)))

    #expect(await fixture.state.requestedPaths().count == 2)
    #expect(
      updates.contains(
        .limitReached(.visitedDirectories(2), generation: generation)))
    #expect(ProviderSearchEngine.maximumVisitedDirectoryCount == 50_000)
  }

  @Test("列挙失敗を部分エラーとして通知し他のディレクトリを継続する")
  func continuesAfterPartialError() async {
    let fixture = SearchFixture(
      tree: [
        "/": [directory("broken", parent: "/"), directory("healthy", parent: "/")],
        "/healthy": [item("target.txt", parent: "/healthy")],
      ],
      failingPaths: ["/broken"])
    let updates = await collect(
      ProviderSearchEngine(provider: fixture.provider, includesHiddenItems: false)
        .search(query(text: "target", providerID: fixture.provider.id)))

    #expect(resultNames(in: updates) == ["target.txt"])
    #expect(
      updates.contains {
        guard case .partialError(let error) = $0 else { return false }
        return error.location.remotePath == "/broken"
      })
  }

  @Test("ストリームを持たないProviderはcontents経路で再帰検索する")
  func searchesNonStreamingProvider() async {
    let fixture = SearchFixture(
      tree: [
        "/": [directory("child", parent: "/")],
        "/child": [item("remote-target.txt", parent: "/child")],
      ])
    let updates = await collect(
      ProviderSearchEngine(provider: fixture.provider, includesHiddenItems: false)
        .search(query(text: "target", providerID: fixture.provider.id)))

    #expect(resultNames(in: updates) == ["remote-target.txt"])
    #expect(await fixture.state.requestedPaths() == ["/", "/child"])
  }

  @Test("ストリーミングProviderの並行ディレクトリ数を指定上限内に抑える")
  func limitsConcurrentStreamingDirectories() async {
    let directories = (0..<6).map { directory("child-\($0)", parent: "/") }
    var tree = ["/": directories]
    for index in 0..<6 {
      tree["/child-\(index)"] = [item("target-\(index).txt", parent: "/child-\(index)")]
    }
    let delayedPaths = Set((0..<6).map { "/child-\($0)" })
    let state = SearchFixtureState(
      tree: tree,
      failingPaths: [],
      delayedPaths: delayedPaths,
      delay: .milliseconds(20))
    let provider = StreamingSearchFixtureProvider(state: state)
    let updates = await collect(
      ProviderSearchEngine(
        provider: provider,
        includesHiddenItems: false,
        maximumConcurrentDirectories: 3
      ).search(query(text: "target", providerID: provider.id)))

    #expect(resultNames(in: updates).count == 6)
    #expect(await state.maximumConcurrentRequestCount() == 3)
  }

  @Test("隠し項目設定に従い隠しディレクトリの走査も抑止する")
  func respectsHiddenItemsSetting() async {
    let fixture = SearchFixture(
      tree: [
        "/": [item(".hidden-target", parent: "/"), directory(".secret", parent: "/")],
        "/.secret": [item("nested-target", parent: "/.secret")],
      ])
    let hiddenOff = await collect(
      ProviderSearchEngine(provider: fixture.provider, includesHiddenItems: false)
        .search(query(text: "target", providerID: fixture.provider.id)))
    let hiddenOn = await collect(
      ProviderSearchEngine(provider: fixture.provider, includesHiddenItems: true)
        .search(query(text: "target", providerID: fixture.provider.id)))

    #expect(resultNames(in: hiddenOff).isEmpty)
    #expect(Set(resultNames(in: hiddenOn)) == [".hidden-target", "nested-target"])
  }

  @Test("消費側のキャンセル後は更新を追加せずProvider列挙も中断する")
  func cancellationStopsFurtherUpdates() async {
    let fixture = SearchFixture(
      tree: [
        "/": [item("first-target.txt", parent: "/"), directory("slow", parent: "/")],
        "/slow": [item("late-target.txt", parent: "/slow")],
      ],
      delayedPaths: ["/slow"])
    let recorder = SearchUpdateRecorder()
    let consumer = Task {
      for await update in ProviderSearchEngine(
        provider: fixture.provider, includesHiddenItems: false
      ).search(query(text: "target", providerID: fixture.provider.id)) {
        recorder.append(update)
      }
    }

    await waitUntil { recorder.resultCount > 0 }
    consumer.cancel()
    _ = await consumer.result
    await waitUntil { await fixture.state.cancellationCount() > 0 }
    let countAfterCancellation = recorder.updateCount
    try? await Task.sleep(for: .milliseconds(30))

    #expect(recorder.updateCount == countAfterCancellation)
    #expect(!recorder.containsFinished)
  }

  private func collect(_ stream: AsyncStream<SearchUpdate>) async -> [SearchUpdate] {
    var updates = [SearchUpdate]()
    for await update in stream { updates.append(update) }
    return updates
  }

  private func resultNames(in updates: [SearchUpdate]) -> [String] {
    updates.flatMap { update -> [String] in
      guard case .results(let results, _) = update else { return [String]() }
      return results.map(\.item.name)
    }
  }

  private func generation(in updates: [SearchUpdate]) -> UUID {
    updates.first?.generation ?? UUID()
  }

  private func query(
    text: String,
    providerID: FileProviderID,
    nameMatchMode: NameMatchMode = .literal
  ) -> SearchQuery {
    SearchQuery(
      text: text,
      root: location("/", providerID: providerID),
      scope: .currentFolder,
      nameMatchMode: nameMatchMode)
  }

  private func waitUntil(
    _ condition: @escaping @Sendable () async -> Bool
  ) async {
    await PKPaneTests.waitUntil("検索エンジンの状態が期限内に条件を満たさなかった") {
      await condition()
    }
  }
}

private struct SearchFixture: Sendable {
  let state: SearchFixtureState
  let provider: SearchFixtureProvider

  init(
    tree: [String: [FileItem]],
    failingPaths: Set<String> = [],
    delayedPaths: Set<String> = [],
    delay: Duration = .seconds(10)
  ) {
    let state = SearchFixtureState(
      tree: tree, failingPaths: failingPaths, delayedPaths: delayedPaths, delay: delay)
    self.state = state
    provider = SearchFixtureProvider(state: state)
  }
}

private actor SearchFixtureState {
  private let tree: [String: [FileItem]]
  private let failingPaths: Set<String>
  private let delayedPaths: Set<String>
  private let delay: Duration
  private var requests = [String]()
  private var cancellations = 0
  private var activeRequests = 0
  private var maximumActiveRequests = 0

  init(
    tree: [String: [FileItem]],
    failingPaths: Set<String>,
    delayedPaths: Set<String>,
    delay: Duration = .seconds(10)
  ) {
    self.tree = tree
    self.failingPaths = failingPaths
    self.delayedPaths = delayedPaths
    self.delay = delay
  }

  func contents(at path: String) async throws -> [FileItem] {
    requests.append(path)
    activeRequests += 1
    maximumActiveRequests = max(maximumActiveRequests, activeRequests)
    defer { activeRequests -= 1 }
    if delayedPaths.contains(path) {
      do {
        try await Task.sleep(for: delay)
      } catch {
        cancellations += 1
        throw error
      }
    }
    if failingPaths.contains(path) { throw SearchFixtureError.unreadable }
    return tree[path] ?? []
  }

  func requestedPaths() -> [String] { requests }
  func cancellationCount() -> Int { cancellations }
  func maximumConcurrentRequestCount() -> Int { maximumActiveRequests }
}

private struct SearchFixtureProvider: FileBrowserProvider {
  let state: SearchFixtureState
  let id = FileProviderID(rawValue: "search-fixture")
  let connectionID: FileProviderConnectionID? = nil
  let capabilities: FileProviderCapabilities = [.read]

  func contents(of location: FileLocation) async throws -> [FileItem] {
    try await state.contents(at: location.remotePath ?? "")
  }

  func parent(of _: FileLocation) -> FileLocation? { nil }

  func breadcrumbs(
    for _: FileLocation,
    constrainedTo _: FileLocation?
  ) -> [FileBrowserBreadcrumb] { [] }
}

private struct StreamingSearchFixtureProvider: FileBrowserStreamingProvider {
  let state: SearchFixtureState
  let id = FileProviderID(rawValue: "search-fixture")
  let connectionID: FileProviderConnectionID? = nil
  let capabilities: FileProviderCapabilities = [.read]

  func contents(of location: FileLocation) async throws -> [FileItem] {
    try await state.contents(at: location.remotePath ?? "")
  }

  func contentsStream(
    of location: FileLocation,
    includingHidden _: Bool,
    batchSize _: Int
  ) -> AsyncThrowingStream<[FileItem], Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          continuation.yield(try await contents(of: location))
          continuation.finish()
        } catch is CancellationError {
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  func parent(of _: FileLocation) -> FileLocation? { nil }

  func breadcrumbs(
    for _: FileLocation,
    constrainedTo _: FileLocation?
  ) -> [FileBrowserBreadcrumb] { [] }
}

private enum SearchFixtureError: LocalizedError {
  case unreadable

  var errorDescription: String? { "テスト用の列挙失敗" }
}

private final class SearchUpdateRecorder: @unchecked Sendable {
  private let updates = Mutex<[SearchUpdate]>([])

  var updateCount: Int { updates.withLock(\.count) }
  var resultCount: Int {
    updates.withLock { values in
      values.reduce(into: 0) { count, update in
        if case .results(let results, _) = update { count += results.count }
      }
    }
  }
  var containsFinished: Bool {
    updates.withLock { values in
      values.contains { if case .finished = $0 { true } else { false } }
    }
  }

  func append(_ update: SearchUpdate) {
    updates.withLock { $0.append(update) }
  }
}

private func location(_ path: String, providerID: FileProviderID) -> FileLocation {
  FileLocation(remotePath: path, providerID: providerID)
}

private func item(_ name: String, parent: String) -> FileItem {
  let providerID = FileProviderID(rawValue: "search-fixture")
  let path = parent == "/" ? "/\(name)" : "\(parent)/\(name)"
  return FileItem(
    remotePath: path,
    url: URL(string: "search-fixture://host\(path)")!,
    providerID: providerID,
    isDirectory: false)
}

private func directory(_ name: String, parent: String) -> FileItem {
  let providerID = FileProviderID(rawValue: "search-fixture")
  let path = parent == "/" ? "/\(name)" : "\(parent)/\(name)"
  return FileItem(
    remotePath: path,
    url: URL(string: "search-fixture://host\(path)")!,
    providerID: providerID,
    isDirectory: true)
}
