import Foundation

/// 同期プランを既存の転送キューと削除Providerへ委譲して実行します。転送が1件でも
/// 完了しなかった場合は削除フェーズへ進まず、削除候補をすべてスキップとして報告します。
struct FolderSyncExecutionEngine: Sendable {
  /// 終了済みジョブがTransferQueueの履歴上限で消える前に結果を回収する単位。
  static let maximumTransferBatchSize = 256

  typealias TransferEnqueuer =
    @MainActor @Sendable (
      FolderSyncOperation, FolderSyncDirection, FileLocation
    ) async -> TransferJob?

  private let leftProvider: any FileBrowserProvider
  private let rightProvider: any FileBrowserProvider
  private let transferQueue: TransferQueue
  private let freshnessValidator: FolderSyncFreshnessValidator
  private let transferEnqueuer: TransferEnqueuer?
  private let beforeTransferBatchValidation: (@Sendable (Int) async -> Void)?
  private let beforeDeletionRevalidation: (@Sendable () async -> Void)?

  init(
    leftProvider: any FileBrowserProvider,
    rightProvider: any FileBrowserProvider,
    transferQueue: TransferQueue = .shared,
    transferEnqueuer: TransferEnqueuer? = nil,
    beforeTransferBatchValidation: (@Sendable (Int) async -> Void)? = nil,
    beforeDeletionRevalidation: (@Sendable () async -> Void)? = nil
  ) {
    self.leftProvider = leftProvider
    self.rightProvider = rightProvider
    self.transferQueue = transferQueue
    freshnessValidator = FolderSyncFreshnessValidator(
      leftProvider: leftProvider,
      rightProvider: rightProvider)
    self.transferEnqueuer = transferEnqueuer
    self.beforeTransferBatchValidation = beforeTransferBatchValidation
    self.beforeDeletionRevalidation = beforeDeletionRevalidation
  }

  func execute(
    _ plan: FolderSyncPlan,
    confirmsPermanentDeletion: Bool = false
  ) async -> FolderSyncExecutionSummary {
    if plan.destinationDeletionMode == .permanent,
      plan.summary.deleteCount > 0,
      !confirmsPermanentDeletion
    {
      return FolderSyncExecutionSummary(
        results: plan.operations.map { operation in
          if case .skip(let reason) = operation.action {
            return skippedResult(operation, reason: reason)
          }
          return skippedResult(
            operation,
            reason: .permanentDeletionRequiresConfirmation)
        })
    }
    var resultsByPath = initialResults(for: plan)
    let transferOperations = plan.operations.filter {
      $0.action == .copy || $0.action == .overwrite
    }
    for batchStart in stride(
      from: 0,
      to: transferOperations.count,
      by: Self.maximumTransferBatchSize)
    {
      let batchEnd = min(
        batchStart + Self.maximumTransferBatchSize,
        transferOperations.count)
      let batch = Array(transferOperations[batchStart..<batchEnd])
      let batchPaths = Set(batch.map(\.relativePath))
      await beforeTransferBatchValidation?(batchStart / Self.maximumTransferBatchSize)

      // コピー・上書きの鮮度は、長時間同期でも検証から投入までの窓が広がらないよう
      // 各バッチの投入直前にだけ担保する。フォルダ操作は配下の畳み込み項目も同時に
      // 検証する。削除は転送で送り先が変わり得るため、ここには含めず全転送成功後の
      // 削除フェーズ直前にrevalidateDeletionsが最終責任を持つ。
      let validationPlan = plan.replacingOperations(
        operationsForValidation(of: batch, in: plan))
      let validatedBatchPlan = await freshnessValidator.revalidate(validationPlan)
      for operation in validatedBatchPlan.operations {
        guard case .skip(let reason) = operation.action else { continue }
        resultsByPath[operation.relativePath] = skippedResult(operation, reason: reason)
      }
      let executableBatch = validatedBatchPlan.operations.filter {
        batchPaths.contains($0.relativePath)
          && ($0.action == .copy || $0.action == .overwrite)
      }
      var operationByJobID = [UUID: FolderSyncOperation]()
      for operation in executableBatch {
        guard !Task.isCancelled else {
          resultsByPath[operation.relativePath] = failureResult(
            operation,
            message: "同期実行をキャンセルしました。")
          continue
        }
        guard let job = await enqueueTransfer(operation, plan: plan) else {
          resultsByPath[operation.relativePath] = failureResult(
            operation,
            message: "転送先を安全に準備できなかったためスキップしました。")
          continue
        }
        operationByJobID[job.id] = operation
      }

      let terminalJobs = await waitForTerminalJobs(Set(operationByJobID.keys))
      for (jobID, operation) in operationByJobID {
        guard let job = terminalJobs[jobID] else {
          resultsByPath[operation.relativePath] = failureResult(
            operation,
            message: "転送結果を確認できませんでした。")
          continue
        }
        if job.state == .completed {
          resultsByPath[operation.relativePath] = successResult(operation)
        } else {
          resultsByPath[operation.relativePath] = failureResult(
            operation,
            message: job.errorDescription ?? transferFailureMessage(for: job.state))
        }
      }
    }

    let transferFailed = transferOperations.contains {
      guard let result = resultsByPath[$0.relativePath] else { return true }
      if case .failure = result.outcome { return true }
      return false
    }
    if transferFailed {
      for operation in plan.operations where operation.action == .delete {
        resultsByPath[operation.relativePath] = skippedResult(
          operation,
          reason: .deletionDeferredAfterTransferFailure)
      }
    } else {
      await beforeDeletionRevalidation?()
      let deletionPlan = await freshnessValidator.revalidateDeletions(plan)
      await executeDeletions(
        from: deletionPlan,
        originalPlan: plan,
        resultsByPath: &resultsByPath)
    }

    let results = plan.operations.compactMap { resultsByPath[$0.relativePath] }
    return FolderSyncExecutionSummary(results: results)
  }

  private func operationsForValidation(
    of batch: [FolderSyncOperation],
    in plan: FolderSyncPlan
  ) -> [FolderSyncOperation] {
    let roots = batch.map(\.relativePath)
    return plan.operations.filter { operation in
      roots.contains { root in
        operation.relativePath == root || operation.relativePath.hasPrefix("\(root)/")
      }
    }
  }

  private func initialResults(
    for plan: FolderSyncPlan
  ) -> [String: FolderSyncExecutionItemResult] {
    Dictionary(
      uniqueKeysWithValues: plan.operations.compactMap { operation in
        guard case .skip(let reason) = operation.action else { return nil }
        return (operation.relativePath, skippedResult(operation, reason: reason))
      })
  }

  private func enqueueTransfer(
    _ operation: FolderSyncOperation,
    plan: FolderSyncPlan
  ) async -> TransferJob? {
    if let transferEnqueuer {
      return await transferEnqueuer(
        operation,
        plan.direction,
        destinationRoot(for: plan))
    }
    guard let item = operation.sourceItem,
      let destinationDirectory = FolderComparisonPath.parentDirectory(
        for: operation.relativePath,
        under: destinationRoot(for: plan))
    else { return nil }
    let sourceProvider = sourceProvider(for: plan.direction)
    let destinationProvider = destinationProvider(for: plan.direction)
    let replacesExisting = operation.action == .overwrite
    let totalBytes = operation.transferBytes
    let job = TransferJob(
      kind: .copy,
      items: [item],
      sourceProviderID: sourceProvider.id,
      destinationProviderID: destinationProvider.id,
      destination: destinationDirectory)
    let execution: TransferQueue.Execution = { report, itemCompleted in
      try await ProviderFileTransferService().copyTree(
        item: item,
        from: sourceProvider,
        toDirectory: destinationDirectory,
        using: destinationProvider,
        replacingExisting: replacesExisting,
        progress: { progress in
          Task { await report(progress) }
        },
        itemCompleted: itemCompleted)
      await report(
        FileTransferProgress(
          completedBytes: totalBytes,
          totalBytes: totalBytes))
    }
    _ = await transferQueue.enqueue(job, execution: execution)
    await transferQueue.applyAggregatedTotalBytes(job.id, totalBytes: totalBytes)
    return job
  }

  func destinationDeletionMode(for direction: FolderSyncDirection) -> FolderSyncDeletionMode {
    let provider = destinationProvider(for: direction)
    if provider.capabilities.contains(.trash), provider is any FileBrowserTrashProvider {
      return .trash
    }
    if provider.capabilities.contains(.deletePermanently),
      provider is any FileBrowserPermanentDeleteProvider
    {
      return .permanent
    }
    return .unavailable
  }

  private func waitForTerminalJobs(
    _ jobIDs: Set<UUID>
  ) async -> [UUID: TransferJob] {
    guard !jobIDs.isEmpty else { return [:] }
    let transferQueue = transferQueue
    return await withTaskCancellationHandler {
      var seenJobIDs = Set<UUID>()
      for await jobs in await transferQueue.updates() {
        if Task.isCancelled { return [:] }
        let matchingJobs = jobs.filter { jobIDs.contains($0.id) }
        let currentJobIDs = Set(matchingJobs.map(\.id))
        let disappearedJobIDs = seenJobIDs.subtracting(currentJobIDs)
        if !disappearedJobIDs.isEmpty {
          for job in matchingJobs where !job.state.isTerminal {
            await transferQueue.cancel(job.id)
          }
          if matchingJobs.allSatisfy(\.state.isTerminal) {
            return Dictionary(uniqueKeysWithValues: matchingJobs.map { ($0.id, $0) })
          }
          continue
        }
        seenJobIDs.formUnion(currentJobIDs)
        guard seenJobIDs == jobIDs,
          matchingJobs.allSatisfy(\.state.isTerminal)
        else { continue }
        return Dictionary(uniqueKeysWithValues: matchingJobs.map { ($0.id, $0) })
      }
      return [:]
    } onCancel: {
      Task {
        for jobID in jobIDs {
          await transferQueue.cancel(jobID)
        }
      }
    }
  }

  private func executeDeletions(
    from plan: FolderSyncPlan,
    originalPlan: FolderSyncPlan,
    resultsByPath: inout [String: FolderSyncExecutionItemResult]
  ) async {
    let originalActions = Dictionary(
      uniqueKeysWithValues: originalPlan.operations.map { ($0.relativePath, $0.action) })
    guard plan.deletesExtraneousItems else {
      for operation in plan.operations where originalActions[operation.relativePath] == .delete {
        resultsByPath[operation.relativePath] = skippedResult(
          operation,
          reason: .deletionDisabled,
          action: .delete)
      }
      return
    }
    let provider = destinationProvider(for: plan.direction)
    let deleteItem: (@Sendable (FileItem) async throws -> Void)? =
      switch plan.destinationDeletionMode {
      case .trash:
        if provider.capabilities.contains(.trash),
          let trashProvider = provider as? any FileBrowserTrashProvider
        {
          { item in try await trashProvider.delete(item) }
        } else {
          nil
        }
      case .permanent:
        if provider.capabilities.contains(.deletePermanently),
          let permanentDeleteProvider = provider as? any FileBrowserPermanentDeleteProvider
        {
          { item in try await permanentDeleteProvider.permanentlyDelete(item) }
        } else {
          nil
        }
      case .unavailable:
        nil
      }
    guard let deleteItem else {
      for operation in plan.operations where operation.action == .delete {
        resultsByPath[operation.relativePath] = skippedResult(
          operation,
          reason: .deletionUnavailable,
          action: .delete)
      }
      return
    }

    for operation in plan.operations {
      switch operation.action {
      case .delete:
        guard let item = operation.destinationItem else {
          resultsByPath[operation.relativePath] = skippedResult(
            operation,
            reason: .inspectionFailed,
            action: .delete)
          continue
        }
        do {
          try Task.checkCancellation()
          try await deleteItem(item)
          resultsByPath[operation.relativePath] = successResult(operation)
        } catch is CancellationError {
          resultsByPath[operation.relativePath] = failureResult(
            operation,
            message: "同期実行をキャンセルしました。")
        } catch {
          resultsByPath[operation.relativePath] = failureResult(
            operation,
            message: PKPaneErrorClassifier.classify(error).displayMessage)
        }
      case .skip(let reason):
        if resultsByPath[operation.relativePath]?.outcome == .skipped(.coveredByParentOperation),
          reason != .coveredByParentOperation
        {
          resultsByPath[operation.relativePath] = skippedResult(operation, reason: reason)
        } else if reason == .changedSinceComparison || reason == .inspectionFailed {
          resultsByPath[operation.relativePath] = skippedResult(
            operation,
            reason: reason,
            action: originalActions[operation.relativePath] ?? operation.action)
        }
      case .copy, .overwrite:
        break
      }
    }
  }

  private func sourceProvider(
    for direction: FolderSyncDirection
  ) -> any FileBrowserProvider {
    direction == .leftToRight ? leftProvider : rightProvider
  }

  private func destinationProvider(
    for direction: FolderSyncDirection
  ) -> any FileBrowserProvider {
    direction == .leftToRight ? rightProvider : leftProvider
  }

  private func destinationRoot(for plan: FolderSyncPlan) -> FileLocation {
    plan.direction == .leftToRight ? plan.snapshot.rightRoot : plan.snapshot.leftRoot
  }

  private func successResult(
    _ operation: FolderSyncOperation
  ) -> FolderSyncExecutionItemResult {
    FolderSyncExecutionItemResult(
      relativePath: operation.relativePath,
      action: operation.action,
      outcome: .success)
  }

  private func skippedResult(
    _ operation: FolderSyncOperation,
    reason: FolderSyncSkipReason,
    action: FolderSyncOperationAction? = nil
  ) -> FolderSyncExecutionItemResult {
    FolderSyncExecutionItemResult(
      relativePath: operation.relativePath,
      action: action ?? operation.action,
      outcome: .skipped(reason))
  }

  private func failureResult(
    _ operation: FolderSyncOperation,
    message: String
  ) -> FolderSyncExecutionItemResult {
    FolderSyncExecutionItemResult(
      relativePath: operation.relativePath,
      action: operation.action,
      outcome: .failure(SecretMasker.maskForDisplay(message)))
  }

  private func transferFailureMessage(for state: TransferJob.State) -> String {
    switch state {
    case .cancelled:
      "転送をキャンセルしました。"
    case .interrupted:
      "転送が中断されました。"
    case .failed:
      "転送に失敗しました。"
    case .queued, .running, .paused, .completed:
      "転送結果を確認できませんでした。"
    }
  }
}
