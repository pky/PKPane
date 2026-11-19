import Foundation

/// 左右のProviderを再帰列挙し、静的な比較スナップショットを生成します。
/// 1つのタスクグループで左右を扱うため、並行数上限は左右合算で守られます。
actor FolderComparisonEngine {
  static let maximumItemCount = 50_000

  private let leftProvider: any FileBrowserProvider
  private let rightProvider: any FileBrowserProvider
  private let maximumConcurrentDirectories: Int
  private let itemLimit: Int

  init(
    leftProvider: any FileBrowserProvider,
    rightProvider: any FileBrowserProvider,
    maximumConcurrentDirectories: Int = 4,
    itemLimit: Int = FolderComparisonEngine.maximumItemCount
  ) {
    self.leftProvider = leftProvider
    self.rightProvider = rightProvider
    self.maximumConcurrentDirectories = max(1, maximumConcurrentDirectories)
    self.itemLimit = max(1, itemLimit)
  }

  func compare(
    leftRoot: FileLocation,
    rightRoot: FileLocation
  ) -> AsyncStream<FolderComparisonUpdate> {
    AsyncStream { continuation in
      let task = Task.detached(priority: .utility) { [self] in
        await runComparison(
          leftRoot: leftRoot,
          rightRoot: rightRoot,
          continuation: continuation)
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  fileprivate struct DirectoryWork: Sendable {
    let side: FolderComparisonSide
    let location: FileLocation
    let relativePath: String
  }

  private enum DirectoryResult: Sendable {
    case contents(DirectoryWork, [FileItem])
    case failure(DirectoryWork, String)
    case cancelled
  }

  private func runComparison(
    leftRoot: FileLocation,
    rightRoot: FileLocation,
    continuation: AsyncStream<FolderComparisonUpdate>.Continuation
  ) async {
    defer { continuation.finish() }
    let accumulator = FolderComparisonAccumulator(itemLimit: itemLimit)
    var pending = [
      DirectoryWork(side: .left, location: leftRoot, relativePath: ""),
      DirectoryWork(side: .right, location: rightRoot, relativePath: ""),
    ]
    var nextPendingIndex = 0
    var didReachLimit = false

    await withTaskGroup(of: DirectoryResult.self) { group in
      var activeTaskCount = 0

      func addAvailableWork() {
        while activeTaskCount < maximumConcurrentDirectories,
          nextPendingIndex < pending.count
        {
          let work = pending[nextPendingIndex]
          nextPendingIndex += 1
          activeTaskCount += 1
          group.addTask { [leftProvider, rightProvider] in
            guard !Task.isCancelled else { return .cancelled }
            let provider = work.side == .left ? leftProvider : rightProvider
            do {
              let items = try await provider.contents(of: work.location, includingHidden: true)
              try Task.checkCancellation()
              return .contents(work, items)
            } catch is CancellationError {
              return .cancelled
            } catch {
              return .failure(work, SecretMasker.maskForDisplay(error))
            }
          }
        }
      }

      addAvailableWork()
      while activeTaskCount > 0, let result = await group.next() {
        activeTaskCount -= 1
        guard !Task.isCancelled else {
          group.cancelAll()
          return
        }

        switch result {
        case .cancelled:
          break
        case .failure(let work, let message):
          let progress = await accumulator.recordPartialError()
          continuation.yield(
            .partialError(
              FolderComparisonPartialError(
                side: work.side,
                location: work.location,
                message: message)))
          continuation.yield(.progress(progress))
        case .contents(let work, let items):
          let outcome = await accumulator.consume(
            items,
            side: work.side,
            parentRelativePath: work.relativePath)
          continuation.yield(.progress(outcome.progress))
          pending.append(contentsOf: outcome.childDirectories)

          let hasUnvisitedItems =
            outcome.didTruncate
            || (outcome.progress.enumeratedItemCount == itemLimit
              && (nextPendingIndex < pending.count || activeTaskCount > 0))
          if hasUnvisitedItems {
            didReachLimit = true
            nextPendingIndex = pending.count
            group.cancelAll()
          }
        }

        if !didReachLimit {
          addAvailableWork()
        }
      }
    }

    guard !Task.isCancelled else { return }
    if didReachLimit {
      continuation.yield(.limitReached(itemLimit))
    }
    let snapshot = await accumulator.snapshot(
      leftRoot: leftRoot,
      rightRoot: rightRoot,
      didReachItemLimit: didReachLimit)
    continuation.yield(.finished(snapshot))
  }
}

private actor FolderComparisonAccumulator {
  struct ConsumeOutcome: Sendable {
    let childDirectories: [FolderComparisonEngine.DirectoryWork]
    let progress: FolderComparisonProgress
    let didTruncate: Bool
  }

  private let itemLimit: Int
  private var leftRecords = [FolderComparisonRecord]()
  private var rightRecords = [FolderComparisonRecord]()
  private var enumeratedItemCount = 0
  private var skippedSymbolicLinkCount = 0
  private var partialErrorCount = 0

  init(itemLimit: Int) {
    self.itemLimit = itemLimit
  }

  func consume(
    _ items: [FileItem],
    side: FolderComparisonSide,
    parentRelativePath: String
  ) -> ConsumeOutcome {
    let remainingCapacity = max(itemLimit - enumeratedItemCount, 0)
    let acceptedItems = items.prefix(remainingCapacity)
    enumeratedItemCount += acceptedItems.count

    var records = [FolderComparisonRecord]()
    var childDirectories = [FolderComparisonEngine.DirectoryWork]()
    records.reserveCapacity(acceptedItems.count)
    for item in acceptedItems {
      let relativePath =
        parentRelativePath.isEmpty ? item.name : "\(parentRelativePath)/\(item.name)"
      if item.isSymbolicLink {
        skippedSymbolicLinkCount += 1
        continue
      }
      records.append(FolderComparisonRecord(relativePath: relativePath, item: item))
      if item.isDirectory {
        childDirectories.append(
          FolderComparisonEngine.DirectoryWork(
            side: side,
            location: item.location,
            relativePath: relativePath))
      }
    }
    switch side {
    case .left:
      leftRecords.append(contentsOf: records)
    case .right:
      rightRecords.append(contentsOf: records)
    }
    return ConsumeOutcome(
      childDirectories: childDirectories,
      progress: progress,
      didTruncate: acceptedItems.count < items.count)
  }

  func recordPartialError() -> FolderComparisonProgress {
    partialErrorCount += 1
    return progress
  }

  func snapshot(
    leftRoot: FileLocation,
    rightRoot: FileLocation,
    didReachItemLimit: Bool
  ) -> FolderComparisonSnapshot {
    FolderComparisonSnapshot(
      leftRoot: leftRoot,
      rightRoot: rightRoot,
      entries: FolderComparisonMatcher.compare(left: leftRecords, right: rightRecords),
      enumeratedItemCount: enumeratedItemCount,
      skippedSymbolicLinkCount: skippedSymbolicLinkCount,
      partialErrorCount: partialErrorCount,
      didReachItemLimit: didReachItemLimit)
  }

  private var progress: FolderComparisonProgress {
    FolderComparisonProgress(
      enumeratedItemCount: enumeratedItemCount,
      skippedSymbolicLinkCount: skippedSymbolicLinkCount,
      partialErrorCount: partialErrorCount)
  }
}
