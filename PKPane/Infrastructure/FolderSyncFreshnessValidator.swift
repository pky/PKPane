import Foundation

/// 比較時の項目指紋と実行直前の一覧を照合します。一覧取得に失敗した場合や、存在・種別・
/// サイズ・更新日時のいずれかが変わった場合は、操作を実行せずスキップへ置き換えます。
struct FolderSyncFreshnessValidator: Sendable {
  private enum Scope {
    case all
    case deletions
  }

  private enum Side: Hashable, Sendable {
    case left
    case right
  }

  private struct ListingKey: Hashable, Sendable {
    let side: Side
    let parent: FileLocation
  }

  private enum ListingResult: Sendable {
    case items([FileItem])
    case failure
  }

  private enum ValidationFailure {
    case changed
    case inspectionFailed

    var skipReason: FolderSyncSkipReason {
      switch self {
      case .changed: .changedSinceComparison
      case .inspectionFailed: .inspectionFailed
      }
    }
  }

  private let leftProvider: any FileBrowserProvider
  private let rightProvider: any FileBrowserProvider
  private let maximumConcurrentInspections: Int

  init(
    leftProvider: any FileBrowserProvider,
    rightProvider: any FileBrowserProvider,
    maximumConcurrentInspections: Int = 4
  ) {
    self.leftProvider = leftProvider
    self.rightProvider = rightProvider
    self.maximumConcurrentInspections = max(1, maximumConcurrentInspections)
  }

  func revalidate(_ plan: FolderSyncPlan) async -> FolderSyncPlan {
    await revalidate(plan, scope: .all)
  }

  func revalidateDeletions(_ plan: FolderSyncPlan) async -> FolderSyncPlan {
    await revalidate(plan, scope: .deletions)
  }

  private func revalidate(_ plan: FolderSyncPlan, scope: Scope) async -> FolderSyncPlan {
    let deletionRoots = Set(
      plan.operations.compactMap { operation in
        operation.action == .delete ? operation.relativePath : nil
      })
    let inspectableOperations = plan.operations.filter {
      Self.requiresInspection($0, scope: scope, deletionRoots: deletionRoots)
    }
    let requiredListingKeys = Set(
      inspectableOperations.flatMap { operation in
        listingKeys(for: operation, plan: plan)
      })
    let listings = await loadListings(for: Array(requiredListingKeys))
    var failuresByPath = [String: ValidationFailure]()
    for operation in inspectableOperations {
      if let failure = validationFailure(for: operation, plan: plan, listings: listings) {
        failuresByPath[operation.relativePath] = failure
      }
    }

    let operations = plan.operations.map { operation in
      guard Self.requiresInspection(operation, scope: scope, deletionRoots: deletionRoots) else {
        return operation
      }
      let failure = mostSevereFailure(
        for: operation.relativePath,
        operation: operation,
        failuresByPath: failuresByPath)
      guard let failure else { return operation }
      return FolderSyncOperation(
        relativePath: operation.relativePath,
        action: .skip(failure.skipReason),
        sourceItem: operation.sourceItem,
        destinationItem: operation.destinationItem,
        transferBytes: 0,
        overwritesNewerDestination: operation.overwritesNewerDestination)
    }
    return plan.replacingOperations(operations)
  }

  private static func requiresInspection(
    _ operation: FolderSyncOperation,
    scope: Scope,
    deletionRoots: Set<String>
  ) -> Bool {
    if scope == .deletions {
      if operation.action == .delete { return true }
      guard operation.action == .skip(.coveredByParentOperation) else { return false }
      return deletionRoots.contains { operation.relativePath.hasPrefix("\($0)/") }
    }
    return switch operation.action {
    case .copy, .overwrite, .delete:
      true
    case .skip(.coveredByParentOperation):
      true
    case .skip:
      false
    }
  }

  private func listingKeys(
    for operation: FolderSyncOperation,
    plan: FolderSyncPlan
  ) -> [ListingKey] {
    let checksAbsence: Bool
    switch operation.action {
    case .copy, .overwrite, .delete:
      checksAbsence = true
    case .skip:
      checksAbsence = false
    }
    return [Side.left, .right].compactMap { side in
      let expectedItem = expectedItem(for: side, operation: operation, direction: plan.direction)
      guard checksAbsence || expectedItem != nil,
        let itemLocation = expectedItem?.location
          ?? itemLocation(
            relativePath: operation.relativePath,
            root: root(for: side, plan: plan)),
        let parent = itemLocation.deletingLastPathComponent()
      else { return nil }
      return ListingKey(side: side, parent: parent)
    }
  }

  private func loadListings(
    for keys: [ListingKey]
  ) async -> [ListingKey: ListingResult] {
    var results = [ListingKey: ListingResult]()
    await withTaskGroup(of: (ListingKey, ListingResult).self) { group in
      var nextIndex = 0
      var activeCount = 0

      func addAvailableWork() {
        while activeCount < maximumConcurrentInspections, nextIndex < keys.count {
          let key = keys[nextIndex]
          nextIndex += 1
          activeCount += 1
          group.addTask { [leftProvider, rightProvider] in
            let provider = key.side == .left ? leftProvider : rightProvider
            do {
              let items = try await provider.contents(of: key.parent, includingHidden: true)
              return (key, .items(items))
            } catch {
              return (key, .failure)
            }
          }
        }
      }

      addAvailableWork()
      while let (key, result) = await group.next() {
        activeCount -= 1
        results[key] = result
        addAvailableWork()
      }
    }
    return results
  }

  private func validationFailure(
    for operation: FolderSyncOperation,
    plan: FolderSyncPlan,
    listings: [ListingKey: ListingResult]
  ) -> ValidationFailure? {
    let checksAbsence: Bool
    switch operation.action {
    case .copy, .overwrite, .delete:
      checksAbsence = true
    case .skip:
      checksAbsence = false
    }
    for side in [Side.left, .right] {
      let expectedItem = expectedItem(for: side, operation: operation, direction: plan.direction)
      guard checksAbsence || expectedItem != nil else { continue }
      guard
        let expectedLocation = expectedItem?.location
          ?? itemLocation(
            relativePath: operation.relativePath,
            root: root(for: side, plan: plan)),
        let parent = expectedLocation.deletingLastPathComponent()
      else { return .inspectionFailed }
      let key = ListingKey(side: side, parent: parent)
      guard let listing = listings[key] else { return .inspectionFailed }
      switch listing {
      case .failure:
        return .inspectionFailed
      case .items(let items):
        let currentItem = items.first {
          $0.location == expectedLocation || $0.name == itemName(at: expectedLocation)
        }
        guard fingerprintsMatch(expectedItem, currentItem) else { return .changed }
      }
    }
    return nil
  }

  private func mostSevereFailure(
    for relativePath: String,
    operation: FolderSyncOperation,
    failuresByPath: [String: ValidationFailure]
  ) -> ValidationFailure? {
    var failures = [ValidationFailure]()
    if let ownFailure = failuresByPath[relativePath] {
      failures.append(ownFailure)
    }
    let coversDescendants: Bool
    switch operation.action {
    case .copy, .delete:
      coversDescendants =
        operation.sourceItem?.isDirectory == true || operation.destinationItem?.isDirectory == true
    case .overwrite, .skip:
      coversDescendants = false
    }
    if coversDescendants {
      let prefix = "\(relativePath)/"
      failures.append(
        contentsOf: failuresByPath.compactMap { path, failure in
          path.hasPrefix(prefix) ? failure : nil
        })
    }
    if failures.contains(where: { if case .inspectionFailed = $0 { true } else { false } }) {
      return .inspectionFailed
    }
    return failures.isEmpty ? nil : .changed
  }

  private func expectedItem(
    for side: Side,
    operation: FolderSyncOperation,
    direction: FolderSyncDirection
  ) -> FileItem? {
    switch (direction, side) {
    case (.leftToRight, .left), (.rightToLeft, .right):
      operation.sourceItem
    case (.leftToRight, .right), (.rightToLeft, .left):
      operation.destinationItem
    }
  }

  private func root(for side: Side, plan: FolderSyncPlan) -> FileLocation {
    side == .left ? plan.snapshot.leftRoot : plan.snapshot.rightRoot
  }

  private func itemLocation(relativePath: String, root: FileLocation) -> FileLocation? {
    relativePath.split(separator: "/").reduce(Optional(root)) { location, component in
      location?.appending(pathComponent: String(component))
    }
  }

  private func itemName(at location: FileLocation) -> String {
    switch location.path {
    case .local(let url):
      url.lastPathComponent
    case .remote(let path):
      path.split(separator: "/").last.map(String.init) ?? path
    }
  }

  private func fingerprintsMatch(_ expected: FileItem?, _ current: FileItem?) -> Bool {
    switch (expected, current) {
    case (.none, .none):
      true
    case (.some(let expected), .some(let current)):
      expected.location == current.location
        && expected.isDirectory == current.isDirectory
        && expected.isLink == current.isLink
        && expected.size == current.size
        && expected.modifiedAt == current.modifiedAt
    case (.none, .some), (.some, .none):
      false
    }
  }
}
