import Foundation

enum FolderSyncDirection: String, CaseIterable, Identifiable, Sendable {
  case leftToRight
  case rightToLeft

  var id: Self { self }

  var displayName: String {
    switch self {
    case .leftToRight:
      String(localized: "左から右へ")
    case .rightToLeft:
      String(localized: "右から左へ")
    }
  }
}

enum FolderSyncSkipReason: Equatable, Sendable {
  case identical
  case deletionDisabled
  case deletionUnavailable
  case comparisonIncomplete
  case itemTypeMismatch
  case symbolicLink
  case metadataUnavailable
  case directoryMetadataOnly
  case coveredByParentOperation
  case changedSinceComparison
  case inspectionFailed
  case deletionDeferredAfterTransferFailure
  case permanentDeletionRequiresConfirmation
  case newerDestinationRequiresConfirmation
  case caseInsensitiveNameCollision

  var displayName: String {
    switch self {
    case .identical:
      String(localized: "同一内容のため変更なし")
    case .deletionDisabled:
      String(localized: "削除設定がOFFのため保持")
    case .deletionUnavailable:
      String(localized: "送り先が削除に未対応")
    case .comparisonIncomplete:
      String(localized: "比較結果が不完全なため安全のため除外")
    case .itemTypeMismatch:
      String(localized: "ファイルとフォルダの種類が不一致")
    case .symbolicLink:
      String(localized: "シンボリックリンクのため除外")
    case .metadataUnavailable:
      String(localized: "サイズまたは更新日時を確認できないため除外")
    case .directoryMetadataOnly:
      String(localized: "フォルダ属性のみの差異は対象外")
    case .coveredByParentOperation:
      String(localized: "親フォルダの操作に含まれます")
    case .changedSinceComparison:
      String(localized: "比較後に変更されたためスキップ")
    case .inspectionFailed:
      String(localized: "実行直前の確認に失敗したためスキップ")
    case .deletionDeferredAfterTransferFailure:
      String(localized: "転送失敗があるため削除を見送り")
    case .permanentDeletionRequiresConfirmation:
      String(localized: "完全削除の確認がないため同期を見送り")
    case .newerDestinationRequiresConfirmation:
      String(localized: "送り先の方が新しいため明示確認までスキップ")
    case .caseInsensitiveNameCollision:
      String(localized: "大文字小文字だけが異なる同名項目との衝突を回避")
    }
  }
}

enum FolderSyncExecutionOutcome: Equatable, Sendable {
  case success
  case skipped(FolderSyncSkipReason)
  case failure(String)

  var displayName: String {
    switch self {
    case .success:
      String(localized: "成功")
    case .skipped(let reason):
      reason.displayName
    case .failure(let message):
      message
    }
  }

  var isFailure: Bool {
    if case .failure = self { return true }
    return false
  }
}

struct FolderSyncExecutionItemResult: Identifiable, Equatable, Sendable {
  let relativePath: String
  let action: FolderSyncOperationAction
  let outcome: FolderSyncExecutionOutcome

  var id: String { relativePath }
}

struct FolderSyncExecutionSummary: Equatable, Sendable {
  let results: [FolderSyncExecutionItemResult]

  var successCount: Int {
    results.count { $0.outcome == .success }
  }

  var skipCount: Int {
    results.count {
      if case .skipped = $0.outcome { return true }
      return false
    }
  }

  var failureCount: Int {
    results.count {
      if case .failure = $0.outcome { return true }
      return false
    }
  }
}

enum FolderSyncOperationAction: Equatable, Sendable {
  case copy
  case overwrite
  case delete
  case skip(FolderSyncSkipReason)

  var displayName: String {
    switch self {
    case .copy:
      String(localized: "コピー")
    case .overwrite:
      String(localized: "上書き")
    case .delete:
      String(localized: "削除")
    case .skip:
      String(localized: "スキップ")
    }
  }
}

enum FolderSyncDeletionMode: Equatable, Sendable {
  case unavailable
  case trash
  case permanent

  var isAvailable: Bool { self != .unavailable }
}

struct FolderSyncOperation: Identifiable, Equatable, Sendable {
  let relativePath: String
  let action: FolderSyncOperationAction
  let sourceItem: FileItem?
  let destinationItem: FileItem?
  let transferBytes: Int64
  let overwritesNewerDestination: Bool

  var id: String { relativePath }
}

struct FolderSyncPlanSummary: Equatable, Sendable {
  let copyCount: Int
  let overwriteCount: Int
  let newerDestinationOverwriteCount: Int
  let deleteCount: Int
  let skipCount: Int
  let totalTransferBytes: Int64
}

struct FolderSyncPlan: Equatable, Sendable {
  let snapshot: FolderComparisonSnapshot
  let direction: FolderSyncDirection
  let deletesExtraneousItems: Bool
  let destinationDeletionMode: FolderSyncDeletionMode
  let operations: [FolderSyncOperation]
  let summary: FolderSyncPlanSummary

  var hasExecutableOperations: Bool {
    operations.contains {
      $0.action == .copy || $0.action == .overwrite || $0.action == .delete
    }
  }

  func replacingOperations(_ operations: [FolderSyncOperation]) -> Self {
    let summary = FolderSyncPlanSummary(
      copyCount: operations.count { $0.action == .copy },
      overwriteCount: operations.count {
        $0.action == .overwrite && !$0.overwritesNewerDestination
      },
      newerDestinationOverwriteCount: operations.count { $0.overwritesNewerDestination },
      deleteCount: operations.count { $0.action == .delete },
      skipCount: operations.count {
        if case .skip = $0.action { return true }
        return false
      },
      totalTransferBytes: operations.reduce(0) {
        FolderSyncByteCount.adding($0, $1.transferBytes)
      })
    return Self(
      snapshot: snapshot,
      direction: direction,
      deletesExtraneousItems: deletesExtraneousItems,
      destinationDeletionMode: destinationDeletionMode,
      operations: operations,
      summary: summary)
  }
}

/// 比較スナップショットを、実行前に確認できる片方向同期プランへ変換する純粋関数です。
/// 不明なメタデータ、型違い、リンク、不完全な比較は安全側へ倒してスキップします。
enum FolderSyncPlanner {
  static func makePlan(
    snapshot: FolderComparisonSnapshot,
    direction: FolderSyncDirection,
    deletesExtraneousItems: Bool,
    destinationDeletionMode: FolderSyncDeletionMode,
    overwritesNewerDestinationItems: Bool = false
  ) -> FolderSyncPlan {
    let entries = snapshot.entries.sorted {
      let leftDepth = pathDepth($0.relativePath)
      let rightDepth = pathDepth($1.relativePath)
      return leftDepth == rightDepth
        ? $0.relativePath < $1.relativePath
        : leftDepth < rightDepth
    }
    var coveredDirectoryPaths = Set<String>()
    var operations = [FolderSyncOperation]()
    operations.reserveCapacity(entries.count)
    let caseInsensitiveCollisionPaths = caseInsensitiveCollisionPaths(
      in: entries,
      direction: direction)

    for entry in entries {
      let sourceItem = direction == .leftToRight ? entry.leftItem : entry.rightItem
      let destinationItem = direction == .leftToRight ? entry.rightItem : entry.leftItem

      if hasCoveredAncestor(entry.relativePath, in: coveredDirectoryPaths) {
        operations.append(
          operation(
            entry.relativePath,
            action: .skip(.coveredByParentOperation),
            sourceItem: sourceItem,
            destinationItem: destinationItem))
        continue
      }

      let action = plannedAction(
        sourceItem: sourceItem,
        destinationItem: destinationItem,
        snapshot: snapshot,
        deletesExtraneousItems: deletesExtraneousItems,
        destinationDeletionMode: destinationDeletionMode,
        overwritesNewerDestinationItems: overwritesNewerDestinationItems,
        hasCaseInsensitiveNameCollision: caseInsensitiveCollisionPaths.contains(
          entry.relativePath))
      let overwritesNewerDestination =
        isNewerDestinationOverwrite(
          sourceItem: sourceItem,
          destinationItem: destinationItem)
        && (action == .overwrite || action == .skip(.newerDestinationRequiresConfirmation))
      var transferBytes: Int64 = 0
      switch action {
      case .copy, .overwrite:
        if sourceItem?.isDirectory == true {
          transferBytes = subtreeTransferBytes(
            under: entry.relativePath,
            entries: entries,
            direction: direction)
          coveredDirectoryPaths.insert(entry.relativePath)
        } else {
          transferBytes = sourceItem?.size ?? 0
        }
      case .delete:
        if destinationItem?.isDirectory == true {
          coveredDirectoryPaths.insert(entry.relativePath)
        }
      case .skip:
        break
      }
      operations.append(
        operation(
          entry.relativePath,
          action: action,
          sourceItem: sourceItem,
          destinationItem: destinationItem,
          transferBytes: transferBytes,
          overwritesNewerDestination: overwritesNewerDestination))
    }

    let plan = FolderSyncPlan(
      snapshot: snapshot,
      direction: direction,
      deletesExtraneousItems: deletesExtraneousItems,
      destinationDeletionMode: destinationDeletionMode,
      operations: operations,
      summary: FolderSyncPlanSummary(
        copyCount: 0,
        overwriteCount: 0,
        newerDestinationOverwriteCount: 0,
        deleteCount: 0,
        skipCount: 0,
        totalTransferBytes: 0))
    return plan.replacingOperations(operations)
  }

  private static func plannedAction(
    sourceItem: FileItem?,
    destinationItem: FileItem?,
    snapshot: FolderComparisonSnapshot,
    deletesExtraneousItems: Bool,
    destinationDeletionMode: FolderSyncDeletionMode,
    overwritesNewerDestinationItems: Bool,
    hasCaseInsensitiveNameCollision: Bool
  ) -> FolderSyncOperationAction {
    if hasCaseInsensitiveNameCollision {
      return .skip(.caseInsensitiveNameCollision)
    }
    if sourceItem?.isLink == true || destinationItem?.isLink == true {
      return .skip(.symbolicLink)
    }
    if let sourceItem, let destinationItem,
      sourceItem.isDirectory != destinationItem.isDirectory
    {
      return .skip(.itemTypeMismatch)
    }

    switch (sourceItem, destinationItem) {
    case (.some(let source), .none):
      guard hasFreshnessMetadata(source) else { return .skip(.metadataUnavailable) }
      if source.isDirectory,
        snapshot.partialErrorCount > 0 || snapshot.didReachItemLimit
          || snapshot.skippedSymbolicLinkCount > 0
      {
        return .skip(.comparisonIncomplete)
      }
      return .copy
    case (.some(let source), .some(let destination)):
      guard hasFreshnessMetadata(source), hasFreshnessMetadata(destination) else {
        return .skip(.metadataUnavailable)
      }
      guard !itemsMatch(source, destination) else { return .skip(.identical) }
      guard !source.isDirectory else { return .skip(.directoryMetadataOnly) }
      if isNewerDestinationOverwrite(sourceItem: source, destinationItem: destination),
        !overwritesNewerDestinationItems
      {
        return .skip(.newerDestinationRequiresConfirmation)
      }
      return .overwrite
    case (.none, .some(let destination)):
      guard deletesExtraneousItems else { return .skip(.deletionDisabled) }
      guard destinationDeletionMode.isAvailable else { return .skip(.deletionUnavailable) }
      guard snapshot.partialErrorCount == 0, !snapshot.didReachItemLimit,
        snapshot.skippedSymbolicLinkCount == 0
      else {
        return .skip(.comparisonIncomplete)
      }
      guard hasFreshnessMetadata(destination) else { return .skip(.metadataUnavailable) }
      return .delete
    case (.none, .none):
      return .skip(.inspectionFailed)
    }
  }

  private static func hasFreshnessMetadata(_ item: FileItem) -> Bool {
    guard let size = item.size else { return false }
    return size >= 0 && item.modifiedAt != nil
  }

  private static func itemsMatch(_ source: FileItem, _ destination: FileItem) -> Bool {
    guard source.isDirectory == destination.isDirectory,
      source.size == destination.size
    else { return false }
    switch (source.modifiedAt, destination.modifiedAt) {
    case (.none, .none):
      return true
    case (.some(let sourceDate), .some(let destinationDate)):
      return abs(sourceDate.timeIntervalSince(destinationDate))
        <= FolderComparisonMatcher.defaultTimestampTolerance
    case (.none, .some), (.some, .none):
      return false
    }
  }

  private static func isNewerDestinationOverwrite(
    sourceItem: FileItem?,
    destinationItem: FileItem?
  ) -> Bool {
    guard let sourceItem, let destinationItem,
      !sourceItem.isDirectory,
      !destinationItem.isDirectory,
      let sourceModifiedAt = sourceItem.modifiedAt,
      let destinationModifiedAt = destinationItem.modifiedAt
    else { return false }
    return destinationModifiedAt.timeIntervalSince(sourceModifiedAt)
      > FolderComparisonMatcher.defaultTimestampTolerance
  }

  private static func caseInsensitiveCollisionPaths(
    in entries: [FolderComparisonEntry],
    direction: FolderSyncDirection
  ) -> Set<String> {
    let groups = Dictionary(grouping: entries) {
      $0.relativePath.folding(
        options: [.caseInsensitive],
        locale: Locale(identifier: "en_US_POSIX"))
    }
    var collisions = Set<String>()
    for group in groups.values {
      let sourceOnly = group.filter { entry in
        let source = direction == .leftToRight ? entry.leftItem : entry.rightItem
        let destination = direction == .leftToRight ? entry.rightItem : entry.leftItem
        return source != nil && destination == nil
      }
      let destinationOnly = group.filter { entry in
        let source = direction == .leftToRight ? entry.leftItem : entry.rightItem
        let destination = direction == .leftToRight ? entry.rightItem : entry.leftItem
        return source == nil && destination != nil
      }
      guard !sourceOnly.isEmpty, !destinationOnly.isEmpty else { continue }
      collisions.formUnion(sourceOnly.map(\.relativePath))
      collisions.formUnion(destinationOnly.map(\.relativePath))
    }
    return collisions
  }

  private static func subtreeTransferBytes(
    under relativePath: String,
    entries: [FolderComparisonEntry],
    direction: FolderSyncDirection
  ) -> Int64 {
    let prefix = "\(relativePath)/"
    return entries.reduce(0) { total, entry in
      guard entry.relativePath.hasPrefix(prefix) else { return total }
      let item = direction == .leftToRight ? entry.leftItem : entry.rightItem
      guard let item, !item.isDirectory, !item.isLink else { return total }
      return FolderSyncByteCount.adding(total, item.size ?? 0)
    }
  }

  private static func operation(
    _ relativePath: String,
    action: FolderSyncOperationAction,
    sourceItem: FileItem?,
    destinationItem: FileItem?,
    transferBytes: Int64 = 0,
    overwritesNewerDestination: Bool = false
  ) -> FolderSyncOperation {
    FolderSyncOperation(
      relativePath: relativePath,
      action: action,
      sourceItem: sourceItem,
      destinationItem: destinationItem,
      transferBytes: transferBytes,
      overwritesNewerDestination: overwritesNewerDestination)
  }

  private static func hasCoveredAncestor(
    _ relativePath: String,
    in coveredDirectoryPaths: Set<String>
  ) -> Bool {
    var components = relativePath.split(separator: "/")
    guard components.count > 1 else { return false }
    components.removeLast()
    while !components.isEmpty {
      if coveredDirectoryPaths.contains(components.joined(separator: "/")) {
        return true
      }
      components.removeLast()
    }
    return false
  }

  private static func pathDepth(_ relativePath: String) -> Int {
    relativePath.split(separator: "/").count
  }
}

private enum FolderSyncByteCount {
  static func adding(_ left: Int64, _ right: Int64) -> Int64 {
    guard right > 0 else { return left }
    let (sum, overflow) = left.addingReportingOverflow(right)
    return overflow ? .max : sum
  }
}
