import Foundation
import Synchronization
import Testing

@testable import PKPane

@MainActor
struct SpotlightSearchEngineTests {
  @Test("gather完了結果を100件単位のバッチへ変換する")
  func convertsGatheredURLsIntoBatches() async {
    let fake = FakeSpotlightMetadataQuery()
    let generation = UUID()
    let query = SearchQuery(
      text: "report",
      root: FileLocation(localURL: URL(filePath: "/")),
      scope: .thisMac,
      generation: generation)
    let collector = Task {
      await collect(
        SpotlightSearchEngine(
          makeMetadataQuery: { fake },
          itemLoader: makeItem
        ).search(query))
    }
    await waitUntil { fake.didStart }
    fake.finishGathering(
      with: (0..<205).map { URL(filePath: "/tmp/report-\($0).txt") })
    let updates = await collector.value

    let batchSizes = updates.compactMap { update -> Int? in
      guard case .results(let results, _) = update else { return nil }
      return results.count
    }
    #expect(batchSizes == [100, 100, 5])
    #expect(updates.last == .finished(generation))
    #expect(fake.receivedText == "report")
    #expect(fake.receivedSearchScopes == [NSMetadataQueryLocalComputerScope])
    #expect(fake.receivedResultLimit == ProviderSearchEngine.maximumResultCount)

    let predicate = SpotlightSearchEngine.fileNamePredicate(for: "report")
    #expect(predicate.evaluate(with: [NSMetadataItemFSNameKey: "Quarterly REPORT.txt"]))
    #expect(!predicate.evaluate(with: [NSMetadataItemFSNameKey: "notes.txt"]))
  }

  @Test("FileItem化に失敗したSpotlight結果だけをスキップする")
  func skipsURLsThatCannotBecomeFileItems() async {
    let fake = FakeSpotlightMetadataQuery()
    let brokenURL = URL(filePath: "/tmp/broken.txt")
    let query = SearchQuery(
      text: "txt",
      root: FileLocation(localURL: URL(filePath: "/")),
      scope: .thisMac)
    let collector = Task {
      await collect(
        SpotlightSearchEngine(
          makeMetadataQuery: { fake },
          itemLoader: { url in
            if url == brokenURL { throw SpotlightFixtureError.unreadable }
            return makeItem(url)
          }
        ).search(query))
    }
    await waitUntil { fake.didStart }
    fake.finishGathering(
      with: [
        URL(filePath: "/tmp/first.txt"), brokenURL, URL(filePath: "/tmp/last.txt"),
      ])
    let updates = await collector.value

    #expect(resultNames(in: updates) == ["first.txt", "last.txt"])
    let errorCount = updates.reduce(into: 0) { count, update in
      if case .partialError(let error) = update { count += error.count }
    }
    #expect(errorCount == 1)
  }

  @Test("名前とタグの有無に応じたSpotlight述語を生成する")
  func buildsNameAndTagPredicates() {
    let nameOnly = SpotlightSearchEngine.predicate(for: "report")
    let nameAndTag = SpotlightSearchEngine.predicate(for: "tag:仕事 report")
    let tagOnly = SpotlightSearchEngine.predicate(for: "tag:重要")

    #expect(
      nameOnly.evaluate(
        with: [NSMetadataItemFSNameKey: "REPORT.txt", "kMDItemUserTags": "個人"]))
    #expect(
      nameAndTag.evaluate(
        with: [NSMetadataItemFSNameKey: "REPORT.txt", "kMDItemUserTags": "重要な仕事"]))
    #expect(
      !nameAndTag.evaluate(
        with: [NSMetadataItemFSNameKey: "notes.txt", "kMDItemUserTags": "重要な仕事"]))
    #expect(
      !nameAndTag.evaluate(
        with: [NSMetadataItemFSNameKey: "REPORT.txt", "kMDItemUserTags": "個人"]))
    #expect(
      tagOnly.evaluate(
        with: [NSMetadataItemFSNameKey: "notes.txt", "kMDItemUserTags": "最重要"])
    )
  }

  @Test("tag:なしのSpotlight述語は入力の連続空白を維持する")
  func preservesRawNameTextWithoutTagTerm() {
    let predicate = SpotlightSearchEngine.predicate(for: "Quarterly  Report")

    #expect(
      predicate.evaluate(
        with: [NSMetadataItemFSNameKey: "Quarterly  Report.txt"]))
    #expect(
      !predicate.evaluate(
        with: [NSMetadataItemFSNameKey: "Quarterly Report.txt"]))
  }

  @Test("内容・名前・タグ条件をANDで結合したSpotlight述語を生成する")
  func buildsContentPredicates() {
    // 複数のcontent:語はANDで評価される(複数tag:と同型)。
    let multipleContent = SpotlightSearchEngine.predicate(for: "content:四半期 content:売上")
    #expect(
      multipleContent.evaluate(with: ["kMDItemTextContent": "第1四半期の売上集計"]))
    #expect(
      !multipleContent.evaluate(with: ["kMDItemTextContent": "第1四半期の実績"]))

    let contentOnly = SpotlightSearchEngine.predicate(for: "content:四半期")
    let nameAndContent = SpotlightSearchEngine.predicate(for: "report content:売上")
    let tagAndContent = SpotlightSearchEngine.predicate(for: "tag:仕事 content:予算")

    #expect(
      contentOnly.evaluate(with: ["kMDItemTextContent": "第1四半期の実績"]))
    #expect(
      nameAndContent.evaluate(
        with: [
          NSMetadataItemFSNameKey: "REPORT.txt",
          "kMDItemTextContent": "年間売上の集計",
        ]))
    #expect(
      !nameAndContent.evaluate(
        with: [
          NSMetadataItemFSNameKey: "notes.txt",
          "kMDItemTextContent": "年間売上の集計",
        ]))
    #expect(
      tagAndContent.evaluate(
        with: [
          "kMDItemUserTags": "重要な仕事",
          "kMDItemTextContent": "来期予算案",
        ]))
    #expect(
      !tagAndContent.evaluate(
        with: [
          "kMDItemUserTags": "個人",
          "kMDItemTextContent": "来期予算案",
        ]))
  }

  @Test("content:なしのSpotlight述語は従来の名前・タグ評価を維持する")
  func preservesPredicatesWithoutContentTerm() {
    let nameOnly = SpotlightSearchEngine.predicate(for: "Quarterly  Report")
    let tagAndName = SpotlightSearchEngine.predicate(for: "tag:仕事 report")

    #expect(
      nameOnly.evaluate(
        with: [NSMetadataItemFSNameKey: "Quarterly  Report.txt"]))
    #expect(
      !nameOnly.evaluate(
        with: [NSMetadataItemFSNameKey: "Quarterly Report.txt"]))
    #expect(
      tagAndName.evaluate(
        with: [NSMetadataItemFSNameKey: "REPORT.txt", "kMDItemUserTags": "仕事"]))
  }

  @Test("gathering進捗を完了通知より前に検索結果へ変換する")
  func progressivelyConvertsGatheringUpdates() async {
    let fake = FakeSpotlightMetadataQuery()
    let query = SearchQuery(
      text: "report",
      root: FileLocation(localURL: URL(filePath: "/")),
      scope: .thisMac)
    let recorder = SpotlightUpdateRecorder()
    let consumer = Task {
      for await update in SpotlightSearchEngine(
        makeMetadataQuery: { fake },
        itemLoader: makeItem
      ).search(query) {
        recorder.append(update)
      }
    }
    await waitUntil { fake.didStart }

    fake.publishProgress(with: (0..<100).map { URL(filePath: "/tmp/report-\($0).txt") })
    await waitUntil { recorder.resultCount == 100 }

    #expect(recorder.resultCount == 100)
    #expect(!recorder.containsFinished)
    fake.finishGathering(with: [URL(filePath: "/tmp/report-last.txt")])
    _ = await consumer.result
    #expect(recorder.resultCount == 101)
  }

  @Test("gatheringがタイムアウトしても部分結果を残して完了する")
  func finishesWithPartialResultsAfterTimeout() async {
    let fake = FakeSpotlightMetadataQuery()
    let query = SearchQuery(
      text: "report",
      root: FileLocation(localURL: URL(filePath: "/")),
      scope: .thisMac)
    let collector = Task {
      await collect(
        SpotlightSearchEngine(
          makeMetadataQuery: { fake },
          itemLoader: makeItem,
          gatheringTimeout: .milliseconds(20)
        ).search(query))
    }
    await waitUntil { fake.didStart }
    fake.publishProgress(with: [URL(filePath: "/tmp/report-partial.txt")])

    let updates = await collector.value

    #expect(resultNames(in: updates) == ["report-partial.txt"])
    #expect(updates.last == .finished(query.generation))
    #expect(fake.stopCallCount > 0)
  }

  @Test("検索ストリームのキャンセルでNSMetadataQueryを停止する")
  func stopsMetadataQueryWhenCancelled() async {
    let fake = FakeSpotlightMetadataQuery()
    let query = SearchQuery(
      text: "report",
      root: FileLocation(localURL: URL(filePath: "/")),
      scope: .thisMac)
    let consumer = Task {
      for await _ in SpotlightSearchEngine(
        makeMetadataQuery: { fake },
        itemLoader: makeItem
      ).search(query) {}
    }
    await waitUntil { fake.didStart }

    consumer.cancel()
    _ = await consumer.result
    await waitUntil { fake.stopCallCount > 0 }

    #expect(fake.stopCallCount > 0)
  }

  private func collect(_ stream: AsyncStream<SearchUpdate>) async -> [SearchUpdate] {
    var updates = [SearchUpdate]()
    for await update in stream { updates.append(update) }
    return updates
  }

  private func resultNames(in updates: [SearchUpdate]) -> [String] {
    updates.flatMap { update -> [String] in
      guard case .results(let results, _) = update else { return [] }
      return results.map(\.item.name)
    }
  }

  private func waitUntil(_ condition: () -> Bool) async {
    await PKPaneTests.waitUntil(
      "Spotlight検索エンジンの状態が期限内に条件を満たさなかった"
    ) {
      condition()
    }
  }
}

@MainActor
private final class FakeSpotlightMetadataQuery: SpotlightMetadataQuerying {
  private var gatherContinuation: AsyncStream<SpotlightMetadataUpdate>.Continuation?
  private(set) var didStart = false
  private(set) var receivedText: String?
  private(set) var receivedSearchScopes: [String] = []
  private(set) var receivedResultLimit: Int?
  private(set) var stopCallCount = 0

  func gather(
    fileNameContaining text: String,
    searchScopes: [String],
    resultLimit: Int
  ) -> AsyncStream<SpotlightMetadataUpdate> {
    didStart = true
    receivedText = text
    receivedSearchScopes = searchScopes
    receivedResultLimit = resultLimit
    let stream = AsyncStream<SpotlightMetadataUpdate>.makeStream()
    gatherContinuation = stream.continuation
    return stream.stream
  }

  func publishProgress(with urls: [URL]) {
    gatherContinuation?.yield(.urls(urls))
  }

  func finishGathering(with urls: [URL]) {
    guard let gatherContinuation else { return }
    self.gatherContinuation = nil
    if !urls.isEmpty {
      gatherContinuation.yield(.urls(urls))
    }
    gatherContinuation.finish()
  }

  func stop() {
    stopCallCount += 1
    guard let gatherContinuation else { return }
    self.gatherContinuation = nil
    gatherContinuation.finish()
  }
}

private final class SpotlightUpdateRecorder: @unchecked Sendable {
  private let updates = Mutex<[SearchUpdate]>([])

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

private enum SpotlightFixtureError: Error {
  case unreadable
}

private func makeItem(_ url: URL) -> FileItem {
  FileItem(url: url, isDirectory: false)
}
