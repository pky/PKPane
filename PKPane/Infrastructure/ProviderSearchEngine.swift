import Foundation

/// FileBrowserProviderの既存列挙経路を使い、階層の浅い順に検索するProvider共通エンジン。
struct ProviderSearchEngine: SearchService {
  static let batchSize = 100
  static let maximumResultCount = 20_000
  static let maximumVisitedDirectoryCount = 50_000

  private let provider: any FileBrowserProvider
  private let includesHiddenItems: Bool
  private let maximumConcurrentDirectories: Int
  private let resultLimit: Int
  private let visitedDirectoryLimit: Int

  init(
    provider: any FileBrowserProvider,
    includesHiddenItems: Bool,
    maximumConcurrentDirectories: Int? = nil,
    resultLimit: Int = Self.maximumResultCount,
    visitedDirectoryLimit: Int = Self.maximumVisitedDirectoryCount
  ) {
    self.provider = provider
    self.includesHiddenItems = includesHiddenItems
    // 現行ProviderではSFTPだけが逐次列挙を持たない。SFTPはRTTと接続負荷を考慮して2、
    // ローカル/NASのストリーミングProviderは4ディレクトリまで並行列挙する。
    self.maximumConcurrentDirectories = max(
      1,
      maximumConcurrentDirectories
        ?? (provider is any FileBrowserStreamingProvider ? 4 : 2))
    self.resultLimit = max(1, resultLimit)
    self.visitedDirectoryLimit = max(1, visitedDirectoryLimit)
  }

  func search(_ query: SearchQuery) -> AsyncStream<SearchUpdate> {
    AsyncStream { continuation in
      let task = Task.detached(priority: .utility) {
        await runSearch(query, continuation: continuation)
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func runSearch(
    _ query: SearchQuery,
    continuation: AsyncStream<SearchUpdate>.Continuation
  ) async {
    defer { continuation.finish() }
    guard query.scope == .currentFolder, !query.text.isEmpty else {
      guard !Task.isCancelled else { return }
      continuation.yield(.finished(query.generation))
      return
    }

    let accumulator = SearchResultAccumulator(
      query: query,
      batchSize: Self.batchSize,
      resultLimit: resultLimit)
    var currentLevel = [query.root]
    var visitedDirectoryCount = 0

    while !currentLevel.isEmpty {
      guard !Task.isCancelled else { return }
      let remainingDirectoryCount = visitedDirectoryLimit - visitedDirectoryCount
      guard remainingDirectoryCount > 0 else {
        continuation.yield(
          .limitReached(
            .visitedDirectories(visitedDirectoryLimit), generation: query.generation))
        continuation.yield(.finished(query.generation))
        return
      }
      let directories = Array(currentLevel.prefix(remainingDirectoryCount))
      let omittedDirectories = directories.count < currentLevel.count
      visitedDirectoryCount += directories.count
      let level = await searchLevel(
        directories,
        query: query,
        accumulator: accumulator,
        continuation: continuation)
      guard !Task.isCancelled else { return }

      if let remaining = await accumulator.flush(), !remaining.isEmpty {
        continuation.yield(.results(remaining, generation: query.generation))
      }
      if level.reachedLimit {
        continuation.yield(
          .limitReached(.results(resultLimit), generation: query.generation))
        continuation.yield(.finished(query.generation))
        return
      }
      if omittedDirectories
        || (visitedDirectoryCount == visitedDirectoryLimit && !level.children.isEmpty)
      {
        continuation.yield(
          .limitReached(
            .visitedDirectories(visitedDirectoryLimit), generation: query.generation))
        continuation.yield(.finished(query.generation))
        return
      }
      currentLevel = level.children
    }

    guard !Task.isCancelled else { return }
    continuation.yield(.finished(query.generation))
  }

  private struct LevelResult: Sendable {
    var children: [FileLocation]
    var reachedLimit: Bool
  }

  private struct DirectoryResult: Sendable {
    var children: [FileLocation]
    var reachedLimit: Bool
  }

  private func searchLevel(
    _ directories: [FileLocation],
    query: SearchQuery,
    accumulator: SearchResultAccumulator,
    continuation: AsyncStream<SearchUpdate>.Continuation
  ) async -> LevelResult {
    await withTaskGroup(of: DirectoryResult.self) { group in
      var nextDirectoryIndex = 0
      var result = LevelResult(children: [], reachedLimit: false)

      func addNextDirectory() {
        guard nextDirectoryIndex < directories.count else { return }
        let directory = directories[nextDirectoryIndex]
        nextDirectoryIndex += 1
        group.addTask {
          await searchDirectory(
            directory,
            query: query,
            accumulator: accumulator,
            continuation: continuation)
        }
      }

      for _ in 0..<min(maximumConcurrentDirectories, directories.count) {
        addNextDirectory()
      }

      while let directoryResult = await group.next() {
        result.children.append(contentsOf: directoryResult.children)
        if directoryResult.reachedLimit {
          result.reachedLimit = true
          group.cancelAll()
        } else if !result.reachedLimit {
          addNextDirectory()
        }
      }
      return result
    }
  }

  private func searchDirectory(
    _ directory: FileLocation,
    query: SearchQuery,
    accumulator: SearchResultAccumulator,
    continuation: AsyncStream<SearchUpdate>.Continuation
  ) async -> DirectoryResult {
    var children = [FileLocation]()
    do {
      if let streamingProvider = provider as? any FileBrowserStreamingProvider {
        for try await items in streamingProvider.contentsStream(
          of: directory,
          includingHidden: includesHiddenItems,
          batchSize: 4_096)
        {
          try Task.checkCancellation()
          let outcome = await consume(
            items,
            in: directory,
            query: query,
            accumulator: accumulator,
            continuation: continuation)
          children.append(contentsOf: outcome.children)
          if outcome.reachedLimit {
            return DirectoryResult(children: children, reachedLimit: true)
          }
        }
      } else {
        let items = try await provider.contents(
          of: directory, includingHidden: includesHiddenItems)
        try Task.checkCancellation()
        let outcome = await consume(
          items,
          in: directory,
          query: query,
          accumulator: accumulator,
          continuation: continuation)
        children.append(contentsOf: outcome.children)
        if outcome.reachedLimit {
          return DirectoryResult(children: children, reachedLimit: true)
        }
      }
    } catch is CancellationError {
      return DirectoryResult(children: [], reachedLimit: false)
    } catch {
      guard !Task.isCancelled else {
        return DirectoryResult(children: [], reachedLimit: false)
      }
      continuation.yield(
        .partialError(
          SearchPartialError(
            location: directory,
            message: SecretMasker.maskForDisplay(error),
            generation: query.generation)))
    }
    return DirectoryResult(children: children, reachedLimit: false)
  }

  private func consume(
    _ items: [FileItem],
    in directory: FileLocation,
    query: SearchQuery,
    accumulator: SearchResultAccumulator,
    continuation: AsyncStream<SearchUpdate>.Continuation
  ) async -> DirectoryResult {
    guard !Task.isCancelled else {
      return DirectoryResult(children: [], reachedLimit: false)
    }
    let visibleItems =
      includesHiddenItems ? items : items.filter { !$0.name.hasPrefix(".") }
    let children = visibleItems.compactMap { item in
      item.isDirectory && !item.isSymbolicLink ? item.location : nil
    }
    let outcome = await accumulator.consume(visibleItems, parent: directory)
    guard !Task.isCancelled else {
      return DirectoryResult(children: [], reachedLimit: false)
    }
    for batch in outcome.batches {
      continuation.yield(.results(batch, generation: query.generation))
    }
    return DirectoryResult(children: children, reachedLimit: outcome.reachedLimit)
  }
}

private actor SearchResultAccumulator {
  struct Outcome: Sendable {
    var batches: [[SearchResult]]
    var reachedLimit: Bool
  }

  private let query: SearchQuery
  private let nameMatcher: NameMatcher
  private let batchSize: Int
  private let resultLimit: Int
  private var pending = [SearchResult]()
  private var resultCount = 0
  private var didReachLimit = false

  init(query: SearchQuery, batchSize: Int, resultLimit: Int) {
    self.query = query
    nameMatcher = NameMatcher(pattern: query.text, mode: query.nameMatchMode)
    self.batchSize = batchSize
    self.resultLimit = resultLimit
    pending.reserveCapacity(batchSize)
  }

  func consume(_ items: [FileItem], parent: FileLocation) -> Outcome {
    guard !didReachLimit else { return Outcome(batches: [], reachedLimit: true) }
    var batches = [[SearchResult]]()
    for item in items where nameMatcher.matches(item.name) {
      guard resultCount < resultLimit else {
        didReachLimit = true
        break
      }
      pending.append(
        SearchResult(
          item: item,
          parent: parent,
          providerID: item.location.providerID,
          generation: query.generation))
      resultCount += 1
      if pending.count == batchSize {
        batches.append(pending)
        pending.removeAll(keepingCapacity: true)
      }
    }
    return Outcome(batches: batches, reachedLimit: didReachLimit)
  }

  func flush() -> [SearchResult]? {
    guard !pending.isEmpty else { return nil }
    let batch = pending
    pending.removeAll(keepingCapacity: true)
    return batch
  }
}
