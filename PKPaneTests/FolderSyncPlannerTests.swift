import Foundation
import Testing

@testable import PKPane

struct FolderSyncPlannerTests {
  @Test("左から右の同期はコピー・上書き・削除候補・同一項目を分類して集計する")
  func plansLeftToRightOperationsAndSummary() throws {
    let snapshot = makeSnapshot(entries: [
      entry("copy.txt", left: file("/left/copy.txt", side: .left, size: 10), right: nil),
      entry(
        "replace.txt",
        left: file("/left/replace.txt", side: .left, size: 20, modifiedAt: date(20)),
        right: file("/right/replace.txt", side: .right, size: 5, modifiedAt: date(5))),
      entry("delete.txt", left: nil, right: file("/right/delete.txt", side: .right, size: 30)),
      entry(
        "same.txt",
        left: file("/left/same.txt", side: .left, size: 40),
        right: file("/right/same.txt", side: .right, size: 40)),
    ])

    let plan = FolderSyncPlanner.makePlan(
      snapshot: snapshot,
      direction: .leftToRight,
      deletesExtraneousItems: true,
      destinationDeletionMode: .trash)

    #expect(plan.operation(for: "copy.txt")?.action == .copy)
    #expect(plan.operation(for: "replace.txt")?.action == .overwrite)
    #expect(plan.operation(for: "delete.txt")?.action == .delete)
    #expect(plan.operation(for: "same.txt")?.action == .skip(.identical))
    #expect(plan.summary.copyCount == 1)
    #expect(plan.summary.overwriteCount == 1)
    #expect(plan.summary.deleteCount == 1)
    #expect(plan.summary.skipCount == 1)
    #expect(plan.summary.totalTransferBytes == 30)
  }

  @Test("右から左ではコピー元と送り先を反転する")
  func reversesSourceAndDestinationForRightToLeft() throws {
    let rightItem = file("/right/new.txt", side: .right, size: 12)
    let snapshot = makeSnapshot(entries: [entry("new.txt", left: nil, right: rightItem)])

    let plan = FolderSyncPlanner.makePlan(
      snapshot: snapshot,
      direction: .rightToLeft,
      deletesExtraneousItems: false,
      destinationDeletionMode: .trash)
    let operation = try #require(plan.operation(for: "new.txt"))

    #expect(operation.action == .copy)
    #expect(operation.sourceItem == rightItem)
    #expect(operation.destinationItem == nil)
  }

  @Test("削除は既定OFFで、ONでも送り先にゴミ箱能力がなければスキップする")
  func deletionRequiresExplicitOptionAndTrashCapability() throws {
    let snapshot = makeSnapshot(entries: [
      entry("extra.txt", left: nil, right: file("/right/extra.txt", side: .right, size: 1))
    ])

    let defaultPlan = FolderSyncPlanner.makePlan(
      snapshot: snapshot,
      direction: .leftToRight,
      deletesExtraneousItems: false,
      destinationDeletionMode: .trash)
    let unsupportedPlan = FolderSyncPlanner.makePlan(
      snapshot: snapshot,
      direction: .leftToRight,
      deletesExtraneousItems: true,
      destinationDeletionMode: .unavailable)

    #expect(defaultPlan.operation(for: "extra.txt")?.action == .skip(.deletionDisabled))
    #expect(unsupportedPlan.operation(for: "extra.txt")?.action == .skip(.deletionUnavailable))
    #expect(defaultPlan.summary.deleteCount == 0)
    #expect(unsupportedPlan.summary.deleteCount == 0)
  }

  @Test("型違い・シンボリックリンク・検証不能なメタデータは安全側へスキップする")
  func skipsUnsafeBoundaries() {
    let snapshot = makeSnapshot(entries: [
      entry(
        "type-change",
        left: directory("/left/type-change", side: .left),
        right: file("/right/type-change", side: .right, size: 1)),
      entry(
        "link",
        left: file("/left/link", side: .left, size: 1, isSymbolicLink: true),
        right: nil),
      entry(
        "unreadable.txt",
        left: file(
          "/left/unreadable.txt", side: .left, size: nil, modifiedAt: nil),
        right: nil),
      entry(
        "unverifiable-pair.txt",
        left: file(
          "/left/unverifiable-pair.txt", side: .left, size: nil, modifiedAt: nil),
        right: file(
          "/right/unverifiable-pair.txt", side: .right, size: nil, modifiedAt: nil)),
    ])

    let plan = FolderSyncPlanner.makePlan(
      snapshot: snapshot,
      direction: .leftToRight,
      deletesExtraneousItems: true,
      destinationDeletionMode: .trash)

    #expect(plan.operation(for: "type-change")?.action == .skip(.itemTypeMismatch))
    #expect(plan.operation(for: "link")?.action == .skip(.symbolicLink))
    #expect(plan.operation(for: "unreadable.txt")?.action == .skip(.metadataUnavailable))
    #expect(
      plan.operation(for: "unverifiable-pair.txt")?.action == .skip(.metadataUnavailable))
    #expect(plan.summary.copyCount == 0)
    #expect(plan.summary.overwriteCount == 0)
    #expect(plan.summary.deleteCount == 0)
    #expect(plan.summary.skipCount == 4)
  }

  @Test("巨大なサイズ集計はオーバーフローせずInt64上限へ丸める")
  func capsTransferByteTotalOnOverflow() {
    let snapshot = makeSnapshot(entries: [
      entry("folder", left: directory("/left/folder", side: .left), right: nil),
      entry(
        "folder/a.bin",
        left: file("/left/folder/a.bin", side: .left, size: .max),
        right: nil),
      entry(
        "folder/b.bin",
        left: file("/left/folder/b.bin", side: .left, size: .max),
        right: nil),
    ])

    let plan = FolderSyncPlanner.makePlan(
      snapshot: snapshot,
      direction: .leftToRight,
      deletesExtraneousItems: false,
      destinationDeletionMode: .trash)

    #expect(plan.summary.totalTransferBytes == .max)
  }

  @Test("読み取り失敗・上限到達・リンク除外を含む比較結果では削除を計画しない")
  func blocksDeletionForIncompleteComparison() {
    let entry = entry(
      "extra.txt", left: nil, right: file("/right/extra.txt", side: .right, size: 1))
    for snapshot in [
      makeSnapshot(entries: [entry], partialErrorCount: 1),
      makeSnapshot(entries: [entry], didReachItemLimit: true),
      makeSnapshot(entries: [entry], skippedSymbolicLinkCount: 1),
    ] {
      let plan = FolderSyncPlanner.makePlan(
        snapshot: snapshot,
        direction: .leftToRight,
        deletesExtraneousItems: true,
        destinationDeletionMode: .trash)

      #expect(plan.operation(for: "extra.txt")?.action == .skip(.comparisonIncomplete))
      #expect(plan.summary.deleteCount == 0)
    }
  }

  @Test("新規フォルダは親だけをコピーし子を重複転送せず合計サイズへ含める")
  func collapsesMissingDirectoryTreeIntoSingleCopy() throws {
    let snapshot = makeSnapshot(entries: [
      entry("folder", left: directory("/left/folder", side: .left), right: nil),
      entry(
        "folder/child.txt",
        left: file("/left/folder/child.txt", side: .left, size: 25),
        right: nil),
    ])

    let plan = FolderSyncPlanner.makePlan(
      snapshot: snapshot,
      direction: .leftToRight,
      deletesExtraneousItems: false,
      destinationDeletionMode: .trash)

    #expect(plan.operation(for: "folder")?.action == .copy)
    #expect(
      plan.operation(for: "folder/child.txt")?.action == .skip(.coveredByParentOperation))
    #expect(plan.summary.copyCount == 1)
    #expect(plan.summary.totalTransferBytes == 25)
  }

  @Test("送り先の方が新しい上書きは既定でスキップし明示確認後だけ計画する")
  func requiresConfirmationToOverwriteNewerDestination() {
    let snapshot = makeSnapshot(entries: [
      entry(
        "newer-at-destination.txt",
        left: file(
          "/left/newer-at-destination.txt", side: .left, size: 10, modifiedAt: date(10)),
        right: file(
          "/right/newer-at-destination.txt", side: .right, size: 12,
          modifiedAt: date(30)))
    ])

    let defaultPlan = FolderSyncPlanner.makePlan(
      snapshot: snapshot,
      direction: .leftToRight,
      deletesExtraneousItems: false,
      destinationDeletionMode: .trash)
    let confirmedPlan = FolderSyncPlanner.makePlan(
      snapshot: snapshot,
      direction: .leftToRight,
      deletesExtraneousItems: false,
      destinationDeletionMode: .trash,
      overwritesNewerDestinationItems: true)

    #expect(
      defaultPlan.operation(for: "newer-at-destination.txt")?.action
        == .skip(.newerDestinationRequiresConfirmation))
    #expect(defaultPlan.summary.overwriteCount == 0)
    #expect(defaultPlan.summary.newerDestinationOverwriteCount == 1)
    #expect(confirmedPlan.operation(for: "newer-at-destination.txt")?.action == .overwrite)
    #expect(confirmedPlan.summary.overwriteCount == 0)
    #expect(confirmedPlan.summary.newerDestinationOverwriteCount == 1)
  }

  @Test("大文字小文字だけが異なる項目はコピーと削除ではなく衝突として除外する")
  func skipsCaseInsensitiveRenameCollision() {
    let snapshot = makeSnapshot(entries: [
      entry(
        "readme.txt",
        left: file("/left/readme.txt", side: .left, size: 10),
        right: nil),
      entry(
        "README.txt",
        left: nil,
        right: file("/right/README.txt", side: .right, size: 10)),
    ])

    let plan = FolderSyncPlanner.makePlan(
      snapshot: snapshot,
      direction: .leftToRight,
      deletesExtraneousItems: true,
      destinationDeletionMode: .trash)

    #expect(
      plan.operation(for: "readme.txt")?.action == .skip(.caseInsensitiveNameCollision))
    #expect(
      plan.operation(for: "README.txt")?.action == .skip(.caseInsensitiveNameCollision))
    #expect(plan.summary.copyCount == 0)
    #expect(plan.summary.deleteCount == 0)
  }

  private func makeSnapshot(
    entries: [FolderComparisonEntry],
    partialErrorCount: Int = 0,
    didReachItemLimit: Bool = false,
    skippedSymbolicLinkCount: Int = 0
  ) -> FolderComparisonSnapshot {
    FolderComparisonSnapshot(
      leftRoot: location("/left", side: .left),
      rightRoot: location("/right", side: .right),
      entries: entries,
      enumeratedItemCount: entries.count,
      skippedSymbolicLinkCount: skippedSymbolicLinkCount,
      partialErrorCount: partialErrorCount,
      didReachItemLimit: didReachItemLimit)
  }

  private func entry(
    _ relativePath: String,
    left: FileItem?,
    right: FileItem?
  ) -> FolderComparisonEntry {
    let status: FolderComparisonStatus
    switch (left, right) {
    case (.some, .none): status = .leftOnly
    case (.none, .some): status = .rightOnly
    case (.some(let left), .some(let right)):
      let matches =
        left.isDirectory == right.isDirectory
        && left.size == right.size
        && left.modifiedAt == right.modifiedAt
      status = matches ? .identical : .different
    case (.none, .none): preconditionFailure("テスト項目が空です")
    }
    return FolderComparisonEntry(
      relativePath: relativePath,
      status: status,
      leftItem: left,
      rightItem: right)
  }

  private func file(
    _ path: String,
    side: FolderComparisonSide,
    size: Int64?,
    modifiedAt: Date? = Date(timeIntervalSince1970: 10),
    isSymbolicLink: Bool = false
  ) -> FileItem {
    FileItem(
      remotePath: path,
      url: URL(fileURLWithPath: path),
      providerID: providerID(side),
      isDirectory: false,
      isSymbolicLink: isSymbolicLink,
      size: size,
      modifiedAt: modifiedAt)
  }

  private func directory(_ path: String, side: FolderComparisonSide) -> FileItem {
    FileItem(
      remotePath: path,
      url: URL(fileURLWithPath: path),
      providerID: providerID(side),
      isDirectory: true,
      size: 0,
      modifiedAt: date(10))
  }

  private func location(_ path: String, side: FolderComparisonSide) -> FileLocation {
    FileLocation(remotePath: path, providerID: providerID(side))
  }

  private func providerID(_ side: FolderComparisonSide) -> FileProviderID {
    FileProviderID(rawValue: side == .left ? "sync-left" : "sync-right")
  }

  private func date(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: seconds)
  }
}

extension FolderSyncPlan {
  fileprivate func operation(for relativePath: String) -> FolderSyncOperation? {
    operations.first { $0.relativePath == relativePath }
  }
}
