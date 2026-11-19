import Foundation

struct FileSystemGitRepositoryLocator: GitRepositoryLocating {
  let maximumDepth: Int

  init(maximumDepth: Int = 32) {
    self.maximumDepth = max(0, maximumDepth)
  }

  func repositoryRoot(containing directory: URL) async -> URL? {
    let maximumDepth = maximumDepth
    return await Task.detached(priority: .utility) {
      let fileManager = FileManager.default
      var candidate = directory.standardizedFileURL
      for depth in 0...maximumDepth {
        let marker = candidate.appending(path: ".git")
        if fileManager.fileExists(atPath: marker.path) {
          return candidate
        }
        guard depth < maximumDepth else { break }
        let parent = candidate.deletingLastPathComponent()
        guard parent.path != candidate.path else { break }
        candidate = parent
      }
      return nil
    }.value
  }
}

/// Mac App Store版では外部gitプロセスを起動しない。将来プロセス不要の実装へ
/// 差し替えられるよう、サービスの注入境界だけを残す。
private struct DisabledGitStatusRunner: GitStatusRunning {
  func status(repositoryRoot: URL, directory: URL) async throws -> Data {
    Data()
  }
}

actor GitStatusService: GitStatusProviding {
  private enum RepositoryCacheEntry: Sendable {
    case repository(URL)
    case notFound

    var root: URL? {
      switch self {
      case .repository(let url): url
      case .notFound: nil
      }
    }
  }

  private enum LoadResult: Sendable {
    case completed([URL: GitFileStatus])
    case ignored
    case cancelled
  }

  private enum RepositoryLookupResult: Sendable {
    case completed(RepositoryCacheEntry)
    case cancelled
  }

  private struct InFlightRepositoryLookup {
    let token: UUID
    let task: Task<RepositoryLookupResult, Never>
  }

  private struct InFlightStatus {
    let token: UUID
    let task: Task<LoadResult, Never>
  }

  private enum RaceResult: Sendable {
    case output(Data)
    case failed
    case timedOut
  }

  private let locator: any GitRepositoryLocating
  private let runner: any GitStatusRunning
  private let timeout: Duration
  private let cacheEntryLimit: Int
  private var repositoryCache: [URL: RepositoryCacheEntry] = [:]
  private var statusCache: [URL: [URL: GitFileStatus]] = [:]
  private var cacheRecency: [URL] = []
  private var inFlightRepositoryLookups: [URL: InFlightRepositoryLookup] = [:]
  private var inFlightStatuses: [URL: InFlightStatus] = [:]

  init(
    locator: any GitRepositoryLocating = FileSystemGitRepositoryLocator(),
    runner: any GitStatusRunning = DisabledGitStatusRunner(),
    timeout: Duration = .seconds(2),
    cacheEntryLimit: Int = GitStatusCachePolicy.directoryLimit
  ) {
    self.locator = locator
    self.runner = runner
    self.timeout = timeout
    self.cacheEntryLimit = max(1, cacheEntryLimit)
  }

  func statuses(in directory: URL) async -> [URL: GitFileStatus] {
    let key = directory.standardizedFileURL
    if let cached = statusCache[key] {
      recordCacheAccess(key)
      return cached
    }

    let repositoryRoot: URL?
    if let cached = repositoryCache[key] {
      recordCacheAccess(key)
      repositoryRoot = cached.root
    } else {
      let lookup: InFlightRepositoryLookup
      if let existing = inFlightRepositoryLookups[key] {
        lookup = existing
      } else {
        let token = UUID()
        let locator = locator
        let task = Task {
          let located = await locator.repositoryRoot(containing: key)?.standardizedFileURL
          guard !Task.isCancelled else { return RepositoryLookupResult.cancelled }
          return .completed(located.map(RepositoryCacheEntry.repository) ?? .notFound)
        }
        lookup = InFlightRepositoryLookup(token: token, task: task)
        inFlightRepositoryLookups[key] = lookup
      }

      let result = await withTaskCancellationHandler {
        await lookup.task.value
      } onCancel: {
        lookup.task.cancel()
      }
      if inFlightRepositoryLookups[key]?.token == lookup.token {
        inFlightRepositoryLookups[key] = nil
        if case .completed(let entry) = result {
          repositoryCache[key] = entry
        }
      }
      guard !Task.isCancelled, let cached = repositoryCache[key] else { return [:] }
      recordCacheAccess(key)
      repositoryRoot = cached.root
    }
    guard let repositoryRoot else {
      statusCache[key] = [:]
      return [:]
    }

    let inFlight: InFlightStatus
    if let existing = inFlightStatuses[key] {
      inFlight = existing
    } else {
      let token = UUID()
      let runner = runner
      let timeout = timeout
      let task = Task {
        await Self.loadStatuses(
          runner: runner,
          repositoryRoot: repositoryRoot,
          directory: key,
          timeout: timeout)
      }
      inFlight = InFlightStatus(token: token, task: task)
      inFlightStatuses[key] = inFlight
    }

    let result = await withTaskCancellationHandler {
      await inFlight.task.value
    } onCancel: {
      inFlight.task.cancel()
    }
    if inFlightStatuses[key]?.token == inFlight.token {
      inFlightStatuses[key] = nil
    }
    switch result {
    case .completed(let statuses):
      statusCache[key] = statuses
      recordCacheAccess(key)
      return statuses
    case .ignored:
      statusCache[key] = [:]
      recordCacheAccess(key)
      return [:]
    case .cancelled:
      return [:]
    }
  }

  func invalidate(directory: URL) {
    let key = directory.standardizedFileURL
    repositoryCache[key] = nil
    statusCache[key] = nil
    cacheRecency.removeAll { $0 == key }
    inFlightRepositoryLookups.removeValue(forKey: key)?.task.cancel()
    inFlightStatuses.removeValue(forKey: key)?.task.cancel()
  }

  private func recordCacheAccess(_ key: URL) {
    cacheRecency.removeAll { $0 == key }
    cacheRecency.append(key)
    while cacheRecency.count > cacheEntryLimit {
      let evicted = cacheRecency.removeFirst()
      repositoryCache[evicted] = nil
      statusCache[evicted] = nil
    }
  }

  private nonisolated static func loadStatuses(
    runner: any GitStatusRunning,
    repositoryRoot: URL,
    directory: URL,
    timeout: Duration
  ) async -> LoadResult {
    let race = await withTaskGroup(of: RaceResult.self) { group in
      group.addTask {
        do {
          return .output(
            try await runner.status(repositoryRoot: repositoryRoot, directory: directory))
        } catch {
          return .failed
        }
      }
      group.addTask {
        do {
          try await Task.sleep(for: timeout)
          return .timedOut
        } catch {
          return .failed
        }
      }
      let first = await group.next() ?? .failed
      group.cancelAll()
      return first
    }
    guard !Task.isCancelled else { return .cancelled }
    guard case .output(let data) = race else { return .ignored }
    let entries = GitPorcelainParser.parse(data)
    return .completed(
      GitStatusProjection.directChildStatuses(
        from: entries,
        repositoryRoot: repositoryRoot,
        displayedDirectory: directory))
  }
}
