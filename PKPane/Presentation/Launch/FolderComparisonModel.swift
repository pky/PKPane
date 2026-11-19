import Foundation
import Observation

enum FolderComparisonFilter: String, CaseIterable, Identifiable {
  case all
  case leftOnly
  case rightOnly
  case different

  var id: Self { self }

  var displayName: String {
    switch self {
    case .all:
      String(localized: "すべて")
    case .leftOnly:
      String(localized: "左のみ")
    case .rightOnly:
      String(localized: "右のみ")
    case .different:
      String(localized: "差異")
    }
  }

  func includes(_ status: FolderComparisonStatus) -> Bool {
    switch self {
    case .all:
      true
    case .leftOnly:
      status == .leftOnly
    case .rightOnly:
      status == .rightOnly
    case .different:
      status == .different
    }
  }
}

@Observable
@MainActor
final class FolderComparisonTransferCoordinator {
  private let workspace: FileWorkspaceModel
  private let leftSource: FileBrowserSession
  private let rightSource: FileBrowserSession
  private let leftTargetTemplate: FileBrowserSession
  private let rightTargetTemplate: FileBrowserSession
  private let leftRoot: FileLocation
  private let rightRoot: FileLocation
  private var activeSource: FileBrowserSession?

  init(
    workspace: FileWorkspaceModel,
    leftSource: FileBrowserSession,
    rightSource: FileBrowserSession,
    leftTargetTemplate: FileBrowserSession,
    rightTargetTemplate: FileBrowserSession,
    leftRoot: FileLocation,
    rightRoot: FileLocation
  ) {
    self.workspace = workspace
    self.leftSource = leftSource
    self.rightSource = rightSource
    self.leftTargetTemplate = leftTargetTemplate
    self.rightTargetTemplate = rightTargetTemplate
    self.leftRoot = leftRoot
    self.rightRoot = rightRoot
  }

  var pendingTransferConflict: FileBrowserSession.TransferConflict? {
    activeSource?.pendingTransferConflict
  }

  var transferResolutionNotice: String? {
    get { activeSource?.transferResolutionNotice }
    set { activeSource?.transferResolutionNotice = newValue }
  }

  @discardableResult
  func copy(_ entry: FolderComparisonEntry, to direction: FolderComparisonCopyDirection) -> Bool {
    guard pendingTransferConflict == nil else { return false }
    let item: FileItem
    let source: FileBrowserSession
    let targetTemplate: FileBrowserSession
    let targetRoot: FileLocation
    switch direction {
    case .left:
      guard let rightItem = entry.rightItem else { return false }
      item = rightItem
      source = rightSource
      targetTemplate = leftTargetTemplate
      targetRoot = leftRoot
    case .right:
      guard let leftItem = entry.leftItem else { return false }
      item = leftItem
      source = leftSource
      targetTemplate = rightTargetTemplate
      targetRoot = rightRoot
    }
    guard
      let destinationDirectory = FolderComparisonPath.parentDirectory(
        for: entry.relativePath,
        under: targetRoot)
    else {
      return false
    }
    activeSource = source
    return workspace.enqueueFolderComparisonCopy(
      item,
      from: source,
      to: destinationDirectory,
      using: targetTemplate)
  }

  func resolvePendingTransferConflict(replaceExisting: Bool) {
    activeSource?.resolvePendingTransferConflict(replaceExisting: replaceExisting)
  }

  func resolvePendingTransferConflict(
    _ resolution: TransferConflictResolution, applyToRemaining: Bool
  ) {
    activeSource?.resolvePendingTransferConflict(resolution, applyToRemaining: applyToRemaining)
  }

  func refreshBrowsers() {
    leftTargetTemplate.refresh()
    rightTargetTemplate.refresh()
  }
}

@Observable
@MainActor
final class FolderComparisonModel: Identifiable {
  let id = UUID()
  let leftRoot: FileLocation
  let rightRoot: FileLocation
  var filter = FolderComparisonFilter.all
  private(set) var isComparing = false
  private(set) var progress = FolderComparisonProgress(
    enumeratedItemCount: 0,
    skippedSymbolicLinkCount: 0,
    partialErrorCount: 0)
  private(set) var partialErrors = [FolderComparisonPartialError]()
  private(set) var snapshot: FolderComparisonSnapshot?
  private(set) var didReachItemLimit = false
  private(set) var incompleteMetadataCount = 0
  private(set) var syncDirection = FolderSyncDirection.leftToRight
  private(set) var deletesExtraneousItems = false
  private(set) var overwritesNewerDestinationItems = false
  private(set) var syncPlan: FolderSyncPlan?
  private(set) var isPresentingSyncPreview = false
  private(set) var isPresentingPermanentDeleteConfirmation = false
  private(set) var isSyncExecuting = false
  private(set) var syncExecutionSummary: FolderSyncExecutionSummary?

  private let engine: FolderComparisonEngine
  private let syncExecutionEngine: FolderSyncExecutionEngine
  private let transferCoordinator: FolderComparisonTransferCoordinator
  @ObservationIgnored private var comparisonTask: Task<Void, Never>?
  @ObservationIgnored private var syncExecutionTask: Task<Void, Never>?
  @ObservationIgnored private var comparisonGeneration = UUID()
  @ObservationIgnored private var presentsSyncPreviewAfterComparison = false

  init(
    leftRoot: FileLocation,
    rightRoot: FileLocation,
    engine: FolderComparisonEngine,
    syncExecutionEngine: FolderSyncExecutionEngine,
    transferCoordinator: FolderComparisonTransferCoordinator
  ) {
    self.leftRoot = leftRoot
    self.rightRoot = rightRoot
    self.engine = engine
    self.syncExecutionEngine = syncExecutionEngine
    self.transferCoordinator = transferCoordinator
  }

  var displayedEntries: [FolderComparisonEntry] {
    (snapshot?.entries ?? []).filter { filter.includes($0.status) }
  }

  var pendingTransferConflict: FileBrowserSession.TransferConflict? {
    transferCoordinator.pendingTransferConflict
  }

  var transferResolutionNotice: String? {
    get { transferCoordinator.transferResolutionNotice }
    set { transferCoordinator.transferResolutionNotice = newValue }
  }

  var canDeleteExtraneousItems: Bool {
    destinationDeletionMode.isAvailable
  }

  var destinationDeletionMode: FolderSyncDeletionMode {
    syncExecutionEngine.destinationDeletionMode(for: syncDirection)
  }

  func canCopy(
    _ entry: FolderComparisonEntry,
    to direction: FolderComparisonCopyDirection
  ) -> Bool {
    guard pendingTransferConflict == nil else { return false }
    return switch direction {
    case .left:
      entry.rightItem != nil
    case .right:
      entry.leftItem != nil
    }
  }

  func startComparison() {
    guard !isSyncExecuting else { return }
    comparisonTask?.cancel()
    let generation = UUID()
    comparisonGeneration = generation
    isComparing = true
    progress = FolderComparisonProgress(
      enumeratedItemCount: 0,
      skippedSymbolicLinkCount: 0,
      partialErrorCount: 0)
    partialErrors = []
    snapshot = nil
    incompleteMetadataCount = 0
    didReachItemLimit = false
    isPresentingSyncPreview = false
    isPresentingPermanentDeleteConfirmation = false
    syncPlan = nil
    let engine = engine
    let leftRoot = leftRoot
    let rightRoot = rightRoot
    comparisonTask = Task { [weak self] in
      let updates = await engine.compare(leftRoot: leftRoot, rightRoot: rightRoot)
      for await update in updates {
        guard !Task.isCancelled, let self,
          self.comparisonGeneration == generation
        else {
          return
        }
        self.apply(update)
      }
    }
  }

  func cancelComparison() {
    comparisonTask?.cancel()
    comparisonTask = nil
    comparisonGeneration = UUID()
    isComparing = false
    presentsSyncPreviewAfterComparison = false
  }

  @discardableResult
  func copy(
    _ entry: FolderComparisonEntry,
    to direction: FolderComparisonCopyDirection
  ) -> Bool {
    guard canCopy(entry, to: direction) else { return false }
    return transferCoordinator.copy(entry, to: direction)
  }

  func resolvePendingTransferConflict(replaceExisting: Bool) {
    transferCoordinator.resolvePendingTransferConflict(replaceExisting: replaceExisting)
  }

  func resolvePendingTransferConflict(
    _ resolution: TransferConflictResolution, applyToRemaining: Bool
  ) {
    transferCoordinator.resolvePendingTransferConflict(
      resolution, applyToRemaining: applyToRemaining)
  }

  /// 比較結果を土台にした同期プレビューを開く。削除は開くたびに必ずOFFへ戻す。
  @discardableResult
  func presentSyncPreview() -> Bool {
    guard let snapshot, !isComparing, !isSyncExecuting else { return false }
    syncDirection = .leftToRight
    deletesExtraneousItems = false
    overwritesNewerDestinationItems = false
    syncPlan = makeSyncPlan(from: snapshot)
    isPresentingSyncPreview = true
    return true
  }

  func requestSyncPreviewAfterComparison() {
    if presentSyncPreview() { return }
    presentsSyncPreviewAfterComparison = true
  }

  func setSyncDirection(_ direction: FolderSyncDirection) {
    guard !isSyncExecuting else { return }
    isPresentingPermanentDeleteConfirmation = false
    syncDirection = direction
    overwritesNewerDestinationItems = false
    if !canDeleteExtraneousItems {
      deletesExtraneousItems = false
    }
    rebuildSyncPlan()
  }

  func setDeletesExtraneousItems(_ deletes: Bool) {
    guard !isSyncExecuting else { return }
    isPresentingPermanentDeleteConfirmation = false
    deletesExtraneousItems = deletes && canDeleteExtraneousItems
    rebuildSyncPlan()
  }

  func setOverwritesNewerDestinationItems(_ overwrites: Bool) {
    guard !isSyncExecuting else { return }
    isPresentingPermanentDeleteConfirmation = false
    overwritesNewerDestinationItems = overwrites
    rebuildSyncPlan()
  }

  func dismissSyncPreview() {
    guard !isSyncExecuting else { return }
    isPresentingPermanentDeleteConfirmation = false
    isPresentingSyncPreview = false
    syncPlan = nil
  }

  @discardableResult
  func executeSyncPlan() -> Bool {
    guard !isSyncExecuting, let plan = syncPlan, plan.hasExecutableOperations else {
      return false
    }
    if plan.destinationDeletionMode == .permanent, plan.summary.deleteCount > 0 {
      isPresentingPermanentDeleteConfirmation = true
      return true
    }
    startSyncExecution(plan, confirmsPermanentDeletion: false)
    return true
  }

  func confirmPermanentDeleteSync() {
    guard isPresentingPermanentDeleteConfirmation, !isSyncExecuting,
      let plan = syncPlan,
      plan.destinationDeletionMode == .permanent,
      plan.summary.deleteCount > 0,
      plan.hasExecutableOperations
    else { return }
    isPresentingPermanentDeleteConfirmation = false
    startSyncExecution(plan, confirmsPermanentDeletion: true)
  }

  func cancelPermanentDeleteSync() {
    isPresentingPermanentDeleteConfirmation = false
  }

  private func startSyncExecution(
    _ plan: FolderSyncPlan,
    confirmsPermanentDeletion: Bool
  ) {
    isPresentingSyncPreview = false
    isSyncExecuting = true
    syncExecutionSummary = nil
    let executionEngine = syncExecutionEngine
    syncExecutionTask = Task { [weak self] in
      let summary = await executionEngine.execute(
        plan,
        confirmsPermanentDeletion: confirmsPermanentDeletion)
      guard let self else { return }
      self.syncExecutionSummary = summary
      self.isSyncExecuting = false
      self.syncExecutionTask = nil
      self.transferCoordinator.refreshBrowsers()
      self.startComparison()
    }
  }

  func cancelSyncExecution() {
    guard isSyncExecuting else { return }
    syncExecutionTask?.cancel()
  }

  func dismissSyncExecutionSummary() {
    syncExecutionSummary = nil
  }

  private func rebuildSyncPlan() {
    guard let snapshot else {
      syncPlan = nil
      return
    }
    syncPlan = makeSyncPlan(from: snapshot)
  }

  private func makeSyncPlan(from snapshot: FolderComparisonSnapshot) -> FolderSyncPlan {
    FolderSyncPlanner.makePlan(
      snapshot: snapshot,
      direction: syncDirection,
      deletesExtraneousItems: deletesExtraneousItems,
      destinationDeletionMode: destinationDeletionMode,
      overwritesNewerDestinationItems: overwritesNewerDestinationItems)
  }

  private func apply(_ update: FolderComparisonUpdate) {
    switch update {
    case .progress(let progress):
      self.progress = progress
    case .partialError(let error):
      partialErrors.append(error)
    case .limitReached:
      didReachItemLimit = true
    case .finished(let snapshot):
      self.snapshot = snapshot
      incompleteMetadataCount = snapshot.entries.count(where: \.hasIncompleteMetadata)
      progress = FolderComparisonProgress(
        enumeratedItemCount: snapshot.enumeratedItemCount,
        skippedSymbolicLinkCount: snapshot.skippedSymbolicLinkCount,
        partialErrorCount: snapshot.partialErrorCount)
      didReachItemLimit = snapshot.didReachItemLimit
      isComparing = false
      comparisonTask = nil
      if presentsSyncPreviewAfterComparison {
        presentsSyncPreviewAfterComparison = false
        _ = presentSyncPreview()
      }
    }
  }
}
