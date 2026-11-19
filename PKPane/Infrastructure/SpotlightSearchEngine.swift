import Foundation

enum SpotlightMetadataUpdate: Sendable, Equatable {
  case urls([URL])
  case limitReached
}

/// NSMetadataQueryをテスト可能な境界へ閉じ込める最小プロトコル。
@MainActor
protocol SpotlightMetadataQuerying: AnyObject, Sendable {
  func gather(
    fileNameContaining text: String,
    searchScopes: [String],
    resultLimit: Int
  ) -> AsyncStream<SpotlightMetadataUpdate>
  func stop()
}

/// gathering中の進捗通知から追加結果だけを逐次公開する。ライブ更新は追わない。
/// 所有側は返したストリームを最後まで消費するかstop()を呼ぶ契約で、ストリーム終了時にも
/// onTerminationからstop()して通知オブザーバを必ず解除する。
@MainActor
final class NSMetadataQueryAdapter: SpotlightMetadataQuerying {
  private static let extractionBatchSize = 256

  private let query: NSMetadataQuery
  private var progressObserver: NSObjectProtocol?
  private var finishObserver: NSObjectProtocol?
  private var continuation: AsyncStream<SpotlightMetadataUpdate>.Continuation?
  private var drainTask: Task<Void, Never>?
  private var nextResultIndex = 0
  private var resultLimit = 1
  private var shouldFinishAfterDrain = false
  private var updatesAreDisabled = false

  init(query: NSMetadataQuery = NSMetadataQuery()) {
    self.query = query
  }

  func gather(
    fileNameContaining text: String,
    searchScopes: [String],
    resultLimit: Int
  ) -> AsyncStream<SpotlightMetadataUpdate> {
    stop()
    self.resultLimit = max(1, resultLimit)
    nextResultIndex = 0
    shouldFinishAfterDrain = false
    query.predicate = SpotlightSearchEngine.predicate(for: text)
    query.searchScopes = searchScopes

    return AsyncStream { continuation in
      guard !Task.isCancelled else {
        continuation.finish()
        return
      }
      self.continuation = continuation
      continuation.onTermination = { [weak self] _ in
        Task { @MainActor in self?.stop() }
      }
      progressObserver = NotificationCenter.default.addObserver(
        forName: .NSMetadataQueryGatheringProgress,
        object: query,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in self?.requestDrain(finishing: false) }
      }
      finishObserver = NotificationCenter.default.addObserver(
        forName: .NSMetadataQueryDidFinishGathering,
        object: query,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in self?.requestDrain(finishing: true) }
      }
      if !query.start() {
        complete()
      }
    }
  }

  func stop() {
    drainTask?.cancel()
    drainTask = nil
    enableUpdatesIfNeeded()
    query.stop()
    removeObservers()
    let activeContinuation = continuation
    continuation = nil
    activeContinuation?.finish()
  }

  private func requestDrain(finishing: Bool) {
    shouldFinishAfterDrain = shouldFinishAfterDrain || finishing
    guard continuation != nil, drainTask == nil else { return }
    drainTask = Task { @MainActor [weak self] in
      await self?.drainAvailableResults()
    }
  }

  private func drainAvailableResults() async {
    guard continuation != nil else { return }
    query.disableUpdates()
    updatesAreDisabled = true
    let availableResultCount = query.resultCount
    let upperBound = min(availableResultCount, resultLimit)

    while nextResultIndex < upperBound, !Task.isCancelled {
      let batchEnd = min(
        nextResultIndex + Self.extractionBatchSize,
        upperBound)
      var urls = [URL]()
      urls.reserveCapacity(batchEnd - nextResultIndex)
      while nextResultIndex < batchEnd {
        if let item = query.result(at: nextResultIndex) as? NSMetadataItem,
          let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL
        {
          urls.append(url)
        }
        nextResultIndex += 1
      }
      if !urls.isEmpty {
        continuation?.yield(.urls(urls))
      }
      if nextResultIndex < upperBound {
        await Task.yield()
      }
    }

    enableUpdatesIfNeeded()
    drainTask = nil
    guard !Task.isCancelled, continuation != nil else { return }
    if availableResultCount > resultLimit {
      continuation?.yield(.limitReached)
      complete()
    } else if shouldFinishAfterDrain {
      complete()
    }
  }

  private func complete() {
    enableUpdatesIfNeeded()
    query.stop()
    removeObservers()
    let activeContinuation = continuation
    continuation = nil
    activeContinuation?.finish()
  }

  private func enableUpdatesIfNeeded() {
    guard updatesAreDisabled else { return }
    query.enableUpdates()
    updatesAreDisabled = false
  }

  private func removeObservers() {
    if let progressObserver {
      NotificationCenter.default.removeObserver(progressObserver)
      self.progressObserver = nil
    }
    if let finishObserver {
      NotificationCenter.default.removeObserver(finishObserver)
      self.finishObserver = nil
    }
  }
}

struct SpotlightSearchEngine: SearchService {
  typealias MetadataQueryFactory = @MainActor @Sendable () -> any SpotlightMetadataQuerying
  typealias ItemLoader = @Sendable (URL) throws -> FileItem

  private enum GatherRaceResult: Sendable {
    case completed
    case timedOut
    case cancelled
  }

  private let makeMetadataQuery: MetadataQueryFactory
  private let itemLoader: ItemLoader
  private let resultLimit: Int
  private let gatheringTimeout: Duration

  init(
    makeMetadataQuery: @escaping MetadataQueryFactory = { NSMetadataQueryAdapter() },
    itemLoader: @escaping ItemLoader = { url in
      try LocalFileProvider().item(
        at: url,
        providerID: .local,
        includingDetailMetadata: false)
    },
    resultLimit: Int = ProviderSearchEngine.maximumResultCount,
    gatheringTimeout: Duration = .seconds(30)
  ) {
    self.makeMetadataQuery = makeMetadataQuery
    self.itemLoader = itemLoader
    self.resultLimit = max(1, resultLimit)
    self.gatheringTimeout = gatheringTimeout
  }

  func search(_ query: SearchQuery) -> AsyncStream<SearchUpdate> {
    AsyncStream { continuation in
      let task = Task.detached(priority: .utility) {
        await runSearch(query, continuation: continuation)
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  static func fileNamePredicate(for text: String) -> NSPredicate {
    NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, text)
  }

  static func predicate(for text: String) -> NSPredicate {
    let parsedQuery = SearchQueryParser.parse(text)
    var predicates = [NSPredicate]()
    let nameText =
      parsedQuery.hasTagTerms || parsedQuery.hasContentTerms
      ? parsedQuery.nameText
      : text
    if !nameText.isEmpty {
      predicates.append(fileNamePredicate(for: nameText))
    }
    predicates.append(
      contentsOf: parsedQuery.tagTerms.map { tagTerm in
        NSPredicate(format: "%K CONTAINS[cd] %@", "kMDItemUserTags", tagTerm)
      })
    predicates.append(
      contentsOf: parsedQuery.contentTerms.map { contentTerm in
        NSPredicate(format: "%K CONTAINS[cd] %@", "kMDItemTextContent", contentTerm)
      })
    guard !predicates.isEmpty else { return NSPredicate(value: false) }
    guard predicates.count > 1 else { return predicates[0] }
    return NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
  }

  private func runSearch(
    _ query: SearchQuery,
    continuation: AsyncStream<SearchUpdate>.Continuation
  ) async {
    defer { continuation.finish() }
    guard query.scope == .thisMac, !query.text.isEmpty else {
      guard !Task.isCancelled else { return }
      continuation.yield(.finished(query.generation))
      return
    }

    let metadataQuery = await makeMetadataQuery()
    await withTaskCancellationHandler {
      await withTaskGroup(of: GatherRaceResult.self) { group in
        group.addTask {
          let updates = await metadataQuery.gather(
            fileNameContaining: query.text,
            searchScopes: [NSMetadataQueryLocalComputerScope],
            resultLimit: resultLimit)
          await consume(
            updates,
            query: query,
            continuation: continuation)
          return Task.isCancelled ? .cancelled : .completed
        }
        group.addTask {
          do {
            try await Task.sleep(for: gatheringTimeout)
            return .timedOut
          } catch {
            return .cancelled
          }
        }

        guard let firstResult = await group.next() else { return }
        switch firstResult {
        case .completed:
          group.cancelAll()
        case .timedOut:
          await metadataQuery.stop()
        case .cancelled:
          group.cancelAll()
        }
        while await group.next() != nil {}
      }
    } onCancel: {
      Task { @MainActor in metadataQuery.stop() }
    }
    await metadataQuery.stop()
    guard !Task.isCancelled else { return }
    continuation.yield(.finished(query.generation))
  }

  private func consume(
    _ updates: AsyncStream<SpotlightMetadataUpdate>,
    query: SearchQuery,
    continuation: AsyncStream<SearchUpdate>.Continuation
  ) async {
    for await update in updates {
      guard !Task.isCancelled else { return }
      switch update {
      case .urls(let urls):
        publish(
          urls,
          query: query,
          continuation: continuation)
        await Task.yield()
      case .limitReached:
        continuation.yield(
          .limitReached(.results(resultLimit), generation: query.generation))
      }
    }
  }

  private func publish(
    _ urls: [URL],
    query: SearchQuery,
    continuation: AsyncStream<SearchUpdate>.Continuation
  ) {
    var batch = [SearchResult]()
    batch.reserveCapacity(ProviderSearchEngine.batchSize)
    var failureCount = 0
    var firstFailureMessage: String?
    var firstFailureLocation: FileLocation?

    for url in urls {
      guard !Task.isCancelled else { return }
      do {
        let item = try itemLoader(url)
        batch.append(
          SearchResult(
            item: item,
            parent: item.location.deletingLastPathComponent() ?? query.root,
            providerID: .local,
            generation: query.generation))
        if batch.count == ProviderSearchEngine.batchSize {
          continuation.yield(.results(batch, generation: query.generation))
          batch.removeAll(keepingCapacity: true)
        }
      } catch {
        failureCount += 1
        firstFailureMessage =
          firstFailureMessage ?? SecretMasker.maskForDisplay(error)
        firstFailureLocation =
          firstFailureLocation
          ?? FileLocation(localURL: url.deletingLastPathComponent(), providerID: .local)
      }
    }
    if !batch.isEmpty {
      continuation.yield(.results(batch, generation: query.generation))
    }
    if failureCount > 0 {
      continuation.yield(
        .partialError(
          SearchPartialError(
            location: firstFailureLocation ?? query.root,
            message: firstFailureMessage ?? "Spotlight検索結果を読み込めません。",
            generation: query.generation,
            count: failureCount)))
    }
  }
}
