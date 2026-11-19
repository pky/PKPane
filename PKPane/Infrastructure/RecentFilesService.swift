import Foundation
import Synchronization

struct RecentMetadataRecord: Sendable, Equatable {
  let url: URL
  let lastUsedAt: Date
  let isDirectory: Bool
  let size: Int64?
}

enum RecentMetadataUpdate: Sendable, Equatable {
  case records([RecentMetadataRecord])
  case limitReached
}

@MainActor
protocol RecentMetadataQuerying: AnyObject, Sendable {
  func gather(roots: [URL], resultLimit: Int) -> AsyncStream<RecentMetadataUpdate>
  func finishWithPartialResults() async
  func stop()
}

/// Spotlightの結果値だけを読む。ファイルプロバイダへの同期I/Oは行わない。
@MainActor
final class RecentMetadataQueryAdapter: RecentMetadataQuerying {
  private let query: NSMetadataQuery
  private var continuation: AsyncStream<RecentMetadataUpdate>.Continuation?
  private var finishObserver: NSObjectProtocol?
  private var drainTask: Task<Void, Never>?
  private var nextIndex = 0
  private var resultLimit = 1
  private var shouldFinish = false
  private var updatesDisabled = false

  init(query: NSMetadataQuery = NSMetadataQuery()) { self.query = query }

  func gather(roots: [URL], resultLimit: Int) -> AsyncStream<RecentMetadataUpdate> {
    stop()
    guard !roots.isEmpty else { return AsyncStream { $0.finish() } }
    self.resultLimit = max(1, resultLimit)
    nextIndex = 0
    shouldFinish = false
    query.predicate = Self.recentFilePredicate
    query.searchScopes = roots
    query.sortDescriptors = [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false)]

    return AsyncStream { continuation in
      self.continuation = continuation
      continuation.onTermination = { [weak self] _ in
        Task { @MainActor in self?.stop() }
      }
      finishObserver = NotificationCenter.default.addObserver(
        forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main
      ) { [weak self] _ in
        Task { @MainActor in self?.requestDrain(finishing: true) }
      }
      if !query.start() { complete() }
    }
  }

  static var recentFilePredicate: NSPredicate {
    NSPredicate(
      format: "%K > %@", "kMDItemLastUsedDate", Date.distantPast as NSDate)
  }

  func stop() {
    drainTask?.cancel()
    drainTask = nil
    enableUpdatesIfNeeded()
    query.stop()
    removeObservers()
    let active = continuation
    continuation = nil
    active?.finish()
  }

  func finishWithPartialResults() async {
    guard continuation != nil else { return }
    query.disableUpdates()
    updatesDisabled = true
    query.stop()
    requestDrain(finishing: true)
    await drainTask?.value
  }

  private func requestDrain(finishing: Bool) {
    shouldFinish = shouldFinish || finishing
    guard continuation != nil, drainTask == nil else { return }
    drainTask = Task { @MainActor [weak self] in await self?.drain() }
  }

  private func drain() async {
    guard continuation != nil else { return }
    query.disableUpdates()
    updatesDisabled = true
    let available = query.resultCount
    let end = min(available, resultLimit)
    while nextIndex < end, !Task.isCancelled {
      let batchEnd = min(nextIndex + 256, end)
      var records = [RecentMetadataRecord]()
      while nextIndex < batchEnd {
        defer { nextIndex += 1 }
        guard let item = query.result(at: nextIndex) as? NSMetadataItem,
          let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL,
          let date = item.value(forAttribute: "kMDItemLastUsedDate") as? Date
        else { continue }
        let types = item.value(forAttribute: "kMDItemContentTypeTree") as? [String] ?? []
        records.append(
          RecentMetadataRecord(
            url: url, lastUsedAt: date,
            isDirectory: types.contains("public.folder") || types.contains("public.directory"),
            size: (item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value))
      }
      if !records.isEmpty { continuation?.yield(.records(records)) }
      if nextIndex < end { await Task.yield() }
    }
    enableUpdatesIfNeeded()
    drainTask = nil
    guard !Task.isCancelled, continuation != nil else { return }
    if available > resultLimit {
      continuation?.yield(.limitReached)
      complete()
    } else if shouldFinish {
      complete()
    }
  }

  private func complete() {
    enableUpdatesIfNeeded()
    query.stop()
    removeObservers()
    let active = continuation
    continuation = nil
    active?.finish()
  }

  private func enableUpdatesIfNeeded() {
    guard updatesDisabled else { return }
    query.enableUpdates()
    updatesDisabled = false
  }

  private func removeObservers() {
    if let finishObserver { NotificationCenter.default.removeObserver(finishObserver) }
    finishObserver = nil
  }
}

protocol RecentFileSearching: Sendable {
  func search(authorizedRoots: [URL], generation: UUID) -> AsyncStream<SearchUpdate>
}

/// シンボリックリンクを解決した範囲判定を専用スレッドで行う。
/// File Providerの応答が止まっても協調スレッドと画面を塞がない。
final class RecentFilePathValidator: @unchecked Sendable {
  static let shared = RecentFilePathValidator()
  private let queue: OperationQueue
  private let timeout: Duration
  private let unavailableUntil = Mutex<ContinuousClock.Instant?>(nil)
  private let resolve: @Sendable (URL) -> URL
  private let isFile: @Sendable (URL) -> Bool

  init(
    timeout: Duration = .seconds(3),
    resolve: @escaping @Sendable (URL) -> URL = {
      $0.resolvingSymlinksInPath().standardizedFileURL
    },
    isFile: @escaping @Sendable (URL) -> Bool = { url in
      var isDirectory: ObjCBool = false
      return FileManager.default.fileExists(
        atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }
  ) {
    self.timeout = timeout
    self.resolve = resolve
    self.isFile = isFile
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    queue.qualityOfService = .utility
    self.queue = queue
  }

  func filter(_ records: [RecentMetadataRecord], roots: [URL]) async -> [RecentMetadataRecord] {
    let unavailable = unavailableUntil.withLock { until in
      until.map { ContinuousClock.now < $0 } ?? false
    }
    guard !unavailable else { return [] }
    let race = RecentValidationRace()
    return await withCheckedContinuation { continuation in
      race.install(continuation)
      let timer = Task { [timeout] in
        try? await Task.sleep(for: timeout)
        if let continuation = race.take() {
          unavailableUntil.withLock { $0 = ContinuousClock.now + .seconds(30) }
          continuation.resume(returning: [])
        }
      }
      queue.addOperation {
        guard race.isPending else { return }
        let resolvedRoots = roots.map(self.resolve)
        let safeRecords = records.filter { record in
          let resolved = self.resolve(record.url)
          guard
            resolvedRoots.contains(where: { root in
              resolved.pathComponents.starts(with: root.pathComponents)
            })
          else { return false }
          return self.isFile(resolved)
        }
        if let continuation = race.take() {
          timer.cancel()
          continuation.resume(returning: safeRecords)
        }
      }
    }
  }

  func contains(_ candidate: URL, within root: URL) async -> Bool {
    let unavailable = unavailableUntil.withLock { until in
      until.map { ContinuousClock.now < $0 } ?? false
    }
    guard !unavailable else { return false }
    let race = RecentContainmentRace()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        race.install(continuation)
        let timer = Task { [timeout] in
          do {
            try await Task.sleep(for: timeout)
            if let continuation = race.take() {
              unavailableUntil.withLock { $0 = ContinuousClock.now + .seconds(30) }
              continuation.resume(returning: false)
            }
          } catch {}
        }
        queue.addOperation {
          guard race.isPending else { return }
          let resolvedRoot = self.resolve(root)
          let resolvedCandidate = self.resolve(candidate)
          let contained = resolvedCandidate.pathComponents.starts(
            with: resolvedRoot.pathComponents)
          if let continuation = race.take() {
            timer.cancel()
            continuation.resume(returning: contained)
          }
        }
      }
    } onCancel: {
      race.take()?.resume(returning: false)
    }
  }
}

private final class RecentContainmentRace: Sendable {
  private let continuation = Mutex<CheckedContinuation<Bool, Never>?>(nil)

  func install(_ value: CheckedContinuation<Bool, Never>) {
    continuation.withLock { $0 = value }
  }

  var isPending: Bool { continuation.withLock { $0 != nil } }

  func take() -> CheckedContinuation<Bool, Never>? {
    continuation.withLock { value in
      defer { value = nil }
      return value
    }
  }
}

private final class RecentValidationRace: Sendable {
  private let continuation = Mutex<CheckedContinuation<[RecentMetadataRecord], Never>?>(nil)

  func install(_ value: CheckedContinuation<[RecentMetadataRecord], Never>) {
    continuation.withLock { $0 = value }
  }

  var isPending: Bool { continuation.withLock { $0 != nil } }

  func take() -> CheckedContinuation<[RecentMetadataRecord], Never>? {
    continuation.withLock { value in
      defer { value = nil }
      return value
    }
  }
}

struct RecentFilesService: RecentFileSearching {
  typealias QueryFactory = @MainActor @Sendable () -> any RecentMetadataQuerying

  private let makeQuery: QueryFactory
  private let resultLimit: Int
  private let scanLimit: Int
  private let gatheringTimeout: Duration
  private let pathValidator: RecentFilePathValidator

  init(
    makeQuery: @escaping QueryFactory = { RecentMetadataQueryAdapter() },
    resultLimit: Int = 500,
    scanLimit: Int = 2_000,
    gatheringTimeout: Duration = .seconds(30),
    pathValidator: RecentFilePathValidator = RecentFilePathValidator()
  ) {
    self.makeQuery = makeQuery
    self.resultLimit = max(1, resultLimit)
    self.scanLimit = max(self.resultLimit, scanLimit)
    self.gatheringTimeout = gatheringTimeout
    self.pathValidator = pathValidator
  }

  func search(authorizedRoots: [URL], generation: UUID) -> AsyncStream<SearchUpdate> {
    AsyncStream { continuation in
      let task = Task.detached(priority: .utility) {
        await run(roots: authorizedRoots, generation: generation, continuation: continuation)
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func run(
    roots: [URL], generation: UUID,
    continuation: AsyncStream<SearchUpdate>.Continuation
  ) async {
    defer { continuation.finish() }
    let normalizedRoots = Array(Set(roots.filter(\.isFileURL).map(\.standardizedFileURL)))
    guard !normalizedRoots.isEmpty else {
      continuation.yield(.finished(generation))
      return
    }
    let query = await makeQuery()
    let stream = await query.gather(roots: normalizedRoots, resultLimit: scanLimit)
    let collector = Task {
      var seen = Set<URL>()
      var count = 0
      for await update in stream {
        guard !Task.isCancelled else { break }
        switch update {
        case .records(let records):
          var results = [SearchResult]()
          let safeRecords = await pathValidator.filter(records, roots: normalizedRoots)
          for record in safeRecords {
            let url = record.url.standardizedFileURL
            guard url.isFileURL, !record.isDirectory, !seen.contains(url),
              normalizedRoots.contains(where: { root in
                url.pathComponents.starts(with: root.pathComponents)
              })
            else { continue }
            seen.insert(url)
            let item = FileItem(
              url: url, isDirectory: false, size: record.size)
            results.append(
              SearchResult(
                item: item,
                parent: item.location.deletingLastPathComponent()
                  ?? FileLocation(localURL: normalizedRoots[0]),
                providerID: .local, generation: generation,
                lastUsedAt: record.lastUsedAt))
            count += 1
            if count == resultLimit { break }
          }
          if !results.isEmpty { continuation.yield(.results(results, generation: generation)) }
          if count == resultLimit {
            continuation.yield(.limitReached(.results(resultLimit), generation: generation))
            break
          }
        case .limitReached:
          continuation.yield(.limitReached(.results(scanLimit), generation: generation))
        }
      }
    }
    await withTaskCancellationHandler {
      let timeout = Task {
        do {
          try await Task.sleep(for: gatheringTimeout)
          await query.finishWithPartialResults()
        } catch {}
      }
      await collector.value
      timeout.cancel()
    } onCancel: {
      collector.cancel()
      Task { @MainActor in query.stop() }
    }
    await query.stop()
    guard !Task.isCancelled else { return }
    continuation.yield(.finished(generation))
  }
}

/// 転送再開に使うスコープ付きブックマーク生成を専用スレッドで実行する。
final class RecentSourceBookmarkReader: @unchecked Sendable {
  static let shared = RecentSourceBookmarkReader()

  private let queue: OperationQueue
  private let timeout: Duration
  private let create: @Sendable (URL) throws -> Data
  private let unavailableUntil = Mutex<ContinuousClock.Instant?>(nil)

  init(
    timeout: Duration = .seconds(3),
    create: @escaping @Sendable (URL) throws -> Data = { url in
      try url.bookmarkData(
        options: .withSecurityScope,
        includingResourceValuesForKeys: nil,
        relativeTo: nil)
    }
  ) {
    self.timeout = timeout
    self.create = create
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    queue.qualityOfService = .utility
    self.queue = queue
  }

  func bookmark(for root: URL) async -> Data? {
    let unavailable = unavailableUntil.withLock { until in
      until.map { ContinuousClock.now < $0 } ?? false
    }
    guard !unavailable else { return nil }
    let race = RecentBookmarkRace()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        race.install(continuation)
        let timer = Task { [timeout] in
          try? await Task.sleep(for: timeout)
          if let continuation = race.take() {
            unavailableUntil.withLock { $0 = ContinuousClock.now + .seconds(30) }
            continuation.resume(returning: nil)
          }
        }
        queue.addOperation {
          guard race.isPending else { return }
          let data = try? self.create(root)
          if let continuation = race.take() {
            timer.cancel()
            continuation.resume(returning: data)
          }
        }
      }
    } onCancel: {
      race.take()?.resume(returning: nil)
    }
  }
}

private final class RecentBookmarkRace: Sendable {
  private let continuation = Mutex<CheckedContinuation<Data?, Never>?>(nil)

  func install(_ value: CheckedContinuation<Data?, Never>) {
    continuation.withLock { $0 = value }
  }

  var isPending: Bool { continuation.withLock { $0 != nil } }

  func take() -> CheckedContinuation<Data?, Never>? {
    continuation.withLock { value in
      defer { value = nil }
      return value
    }
  }
}
