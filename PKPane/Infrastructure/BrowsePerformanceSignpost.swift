import os

enum InteractionPerformanceProviderKind: Int, CaseIterable, Sendable {
  case unknown = 0
  case local = 1
  case mountedVolume = 2
  case sftp = 3
  case archive = 4

  static func classify(_ provider: any FileBrowserProvider) -> Self {
    if provider is LocalFileProvider { return .local }
    if provider is MountedVolumeProvider { return .mountedVolume }
    if provider is SFTPFileProvider { return .sftp }
    if provider is ArchiveFileProvider { return .archive }
    return .unknown
  }
}

enum BrowsePerformanceStage: Int, CaseIterable, Sendable {
  case requestAccepted = 0
  case locationCommitted = 1
  case firstBatchReceived = 2
  case firstVisibleCellConfigured = 3
  case listingModelCompleted = 4
  case listDiffApplied = 5
  case criticalEnrichmentCompleted = 6

  fileprivate var signpostName: StaticString {
    switch self {
    case .requestAccepted: "B0 RequestAccepted"
    case .locationCommitted: "B1 LocationCommitted"
    case .firstBatchReceived: "B2 FirstBatchReceived"
    case .firstVisibleCellConfigured: "B3 FirstVisibleCellConfigured"
    case .listingModelCompleted: "B4 ListingModelCompleted"
    case .listDiffApplied: "B5 ListDiffApplied"
    case .criticalEnrichmentCompleted: "B6 CriticalEnrichmentCompleted"
    }
  }
}

struct MetadataEnrichmentMeasurement: Equatable, Sendable {
  let fullDetailRequestCount: Int
  let finderTagRequestCount: Int
  let successfulDetailCount: Int
  let successfulTagCount: Int
  let appliedItemCount: Int
  let wasCancelled: Bool
}

struct ListDiffMeasurement: Equatable, Sendable {
  let oldItemCount: Int
  let newItemCount: Int
  let removedCount: Int
  let insertedCount: Int
  let updatedCount: Int
  let usedFullReload: Bool
}

/// フォルダを開いてから一覧モデルが確定するまでと、確定後の重い処理を相関させる共有ログ。
/// B0〜B6の意味はdoc/DISPLAY_PERFORMANCE.md 7.5節を正本とする。パスやファイル名は
/// 一切受け取らず、Provider種別、件数、キャッシュヒットだけを記録する。
///
/// FileBrowserSessionとFileListViewの両方が
/// 同じOSSignpostIDを使って計装するため、同一のOSLogインスタンスを共有する必要がある
/// (サブシステム/カテゴリ文字列が一致していても、OSLogインスタンスが別だと
/// Instruments上で同一区間として結合される保証がないため)。
enum BrowsePerformanceSignpost {
  static let log = OSLog(subsystem: "com.pky.PKPane", category: "browse")
  static let name: StaticString = "Browse"
  private static let metadataName: StaticString = "MetadataEnrichment"
  private static let listDiffName: StaticString = "ListDiffApply"

  static func event(
    _ stage: BrowsePerformanceStage,
    signpostID: OSSignpostID,
    providerKind: InteractionPerformanceProviderKind = .unknown,
    itemCount: Int = 0,
    cacheHit: Bool = false
  ) {
    os_signpost(
      .event,
      log: log,
      name: stage.signpostName,
      signpostID: signpostID,
      "provider=%{public}ld items=%{public}ld cacheHit=%{public}ld",
      providerKind.rawValue,
      itemCount,
      cacheHit ? 1 : 0)
  }

  static func beginMetadataEnrichment(
    signpostID: OSSignpostID,
    providerKind: InteractionPerformanceProviderKind,
    fullDetailCount: Int,
    finderTagCount: Int
  ) {
    os_signpost(
      .begin,
      log: log,
      name: metadataName,
      signpostID: signpostID,
      "provider=%{public}ld details=%{public}ld tags=%{public}ld",
      providerKind.rawValue,
      fullDetailCount,
      finderTagCount)
  }

  static func endMetadataEnrichment(
    signpostID: OSSignpostID,
    measurement: MetadataEnrichmentMeasurement
  ) {
    os_signpost(
      .end,
      log: log,
      name: metadataName,
      signpostID: signpostID,
      "detailOK=%{public}ld tagOK=%{public}ld applied=%{public}ld cancelled=%{public}ld",
      measurement.successfulDetailCount,
      measurement.successfulTagCount,
      measurement.appliedItemCount,
      measurement.wasCancelled ? 1 : 0)
  }

  static func beginListDiff(
    signpostID: OSSignpostID,
    oldItemCount: Int,
    newItemCount: Int
  ) {
    os_signpost(
      .begin,
      log: log,
      name: listDiffName,
      signpostID: signpostID,
      "old=%{public}ld new=%{public}ld",
      oldItemCount,
      newItemCount)
  }

  static func endListDiff(
    signpostID: OSSignpostID,
    measurement: ListDiffMeasurement
  ) {
    os_signpost(
      .end,
      log: log,
      name: listDiffName,
      signpostID: signpostID,
      "removed=%{public}ld inserted=%{public}ld updated=%{public}ld fullReload=%{public}ld",
      measurement.removedCount,
      measurement.insertedCount,
      measurement.updatedCount,
      measurement.usedFullReload ? 1 : 0)
  }
}

enum DropPreparationDestinationKind: Int, CaseIterable, Sendable {
  case paneBackground = 1
  case folderRow = 2
  case columnBackground = 3
  case sidebarSavedLocation = 4
}

enum DropPreparationOutcome: Int, CaseIterable, Sendable {
  case enqueued = 1
  case rejected = 2
  case conflict = 3
  case cancelled = 4
}

struct DropPreparationMeasurement: Equatable, Sendable {
  var resolutionPassCount = 0
  var sourceCandidateCount = 0
  var resolvedItemCount = 0
  var volumeResourceLookupCount = 0
  var temporarySessionCount = 0
  var temporarySessionTransferSubscriptionCount = 0
  var temporarySessionBrowsingResourceCount = 0
  var destinationListingCount = 0
  var destinationItemCount = 0
  var collisionPassCount = 0
  var collisionNameLookupCount = 0
  var collisionSourceItemCount = 0
  var collisionDestinationItemCount = 0
  var enqueuedSourceGroupCount = 0
}

/// 1回のドロップ受理からキュー登録までを同じsignpost IDで追跡する。
/// 保持する値は件数と列挙種別だけで、パス、ファイル名、Provider識別子は保持しない。
@MainActor
final class DropPreparationTrace {
  private static let log = OSLog(subsystem: "com.pky.PKPane", category: "drop")
  private static let name: StaticString = "DropPreparation"
  private static let acceptedName: StaticString = "D0 DropAccepted"
  private static let resolvedName: StaticString = "D1 OriginsResolved"
  private static let operationName: StaticString = "D2 OperationDetermined"
  private static let inventoryName: StaticString = "D3 DestinationInventory"
  private static let collisionName: StaticString = "D4 CollisionChecked"
  private static let enqueueName: StaticString = "D5 QueueRegistered"

  let signpostID: OSSignpostID
  private(set) var measurement = DropPreparationMeasurement()
  private(set) var outcome: DropPreparationOutcome?
  private var expectedSourceGroupCount = 1
  private var isFinished = false

  init(itemCount: Int, destinationKind: DropPreparationDestinationKind) {
    signpostID = OSSignpostID(log: Self.log)
    os_signpost(
      .begin,
      log: Self.log,
      name: Self.name,
      signpostID: signpostID,
      "items=%{public}ld destinationKind=%{public}ld",
      itemCount,
      destinationKind.rawValue)
    os_signpost(
      .event,
      log: Self.log,
      name: Self.acceptedName,
      signpostID: signpostID,
      "items=%{public}ld destinationKind=%{public}ld",
      itemCount,
      destinationKind.rawValue)
  }

  func recordResolution(sourceCandidateCount: Int, resolvedItemCount: Int) {
    measurement.resolutionPassCount += 1
    measurement.sourceCandidateCount = max(
      measurement.sourceCandidateCount, sourceCandidateCount)
    measurement.resolvedItemCount = max(measurement.resolvedItemCount, resolvedItemCount)
    os_signpost(
      .event,
      log: Self.log,
      name: Self.resolvedName,
      signpostID: signpostID,
      "pass=%{public}ld candidates=%{public}ld resolved=%{public}ld",
      measurement.resolutionPassCount,
      sourceCandidateCount,
      resolvedItemCount)
  }

  func recordOperationDecision(volumeResourceLookupCount: Int, movesItems: Bool) {
    measurement.volumeResourceLookupCount += volumeResourceLookupCount
    os_signpost(
      .event,
      log: Self.log,
      name: Self.operationName,
      signpostID: signpostID,
      "volumeReads=%{public}ld move=%{public}ld",
      volumeResourceLookupCount,
      movesItems ? 1 : 0)
  }

  func recordTemporarySession() {
    measurement.temporarySessionCount += 1
  }

  func recordTemporarySessionActivity(
    hasTransferUpdateSubscription: Bool,
    hasActiveBrowsingResources: Bool
  ) {
    if hasTransferUpdateSubscription {
      measurement.temporarySessionTransferSubscriptionCount += 1
    }
    if hasActiveBrowsingResources {
      measurement.temporarySessionBrowsingResourceCount += 1
    }
  }

  func recordDestinationInventory(itemCount: Int, listingCount: Int) {
    measurement.destinationListingCount += listingCount
    measurement.destinationItemCount = max(measurement.destinationItemCount, itemCount)
    os_signpost(
      .event,
      log: Self.log,
      name: Self.inventoryName,
      signpostID: signpostID,
      "items=%{public}ld listings=%{public}ld temporarySessions=%{public}ld",
      itemCount,
      measurement.destinationListingCount,
      measurement.temporarySessionCount)
  }

  func prepareForTransfers(sourceGroupCount: Int) {
    expectedSourceGroupCount = max(sourceGroupCount, 1)
  }

  func recordCollisionCheck(
    sourceItemCount: Int,
    destinationItemCount: Int,
    nameLookupCount: Int,
    hasConflict: Bool
  ) {
    measurement.collisionPassCount += 1
    measurement.collisionNameLookupCount += nameLookupCount
    measurement.collisionSourceItemCount += sourceItemCount
    measurement.collisionDestinationItemCount = max(
      measurement.collisionDestinationItemCount, destinationItemCount)
    os_signpost(
      .event,
      log: Self.log,
      name: Self.collisionName,
      signpostID: signpostID,
      "pass=%{public}ld source=%{public}ld destination=%{public}ld nameLookups=%{public}ld conflict=%{public}ld",
      measurement.collisionPassCount,
      sourceItemCount,
      destinationItemCount,
      nameLookupCount,
      hasConflict ? 1 : 0)
    if hasConflict {
      finish(.conflict)
    }
  }

  func recordQueueRegistration() {
    guard !isFinished else { return }
    measurement.enqueuedSourceGroupCount += 1
    os_signpost(
      .event,
      log: Self.log,
      name: Self.enqueueName,
      signpostID: signpostID,
      "enqueuedGroups=%{public}ld expectedGroups=%{public}ld",
      measurement.enqueuedSourceGroupCount,
      expectedSourceGroupCount)
    if measurement.enqueuedSourceGroupCount >= expectedSourceGroupCount {
      finish(.enqueued)
    }
  }

  func finish(_ outcome: DropPreparationOutcome) {
    guard !isFinished else { return }
    isFinished = true
    self.outcome = outcome
    os_signpost(
      .end,
      log: Self.log,
      name: Self.name,
      signpostID: signpostID,
      "outcome=%{public}ld resolutionPasses=%{public}ld volumeReads=%{public}ld listings=%{public}ld",
      outcome.rawValue,
      measurement.resolutionPassCount,
      measurement.volumeResourceLookupCount,
      measurement.destinationListingCount)
  }
}
