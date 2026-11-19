import Foundation
import Testing

@testable import PKPane

struct FolderSyncFreshnessValidatorTests {
  @Test("存在・サイズ・更新日時・種別が不変なら操作を維持する")
  func keepsOperationsWhoseFingerprintsAreFresh() async throws {
    let fixture = FreshnessFixture(
      leftTree: ["/left": [item("/left/report.txt", providerID: "fresh-left", size: 10)]],
      rightTree: ["/right": []])
    let plan = makePlan(
      left: fixture.leftItems,
      right: fixture.rightItems,
      direction: .leftToRight,
      deletesExtraneousItems: false)

    let result = await fixture.validator.revalidate(plan)

    #expect(result.operation(for: "report.txt")?.action == .copy)
    #expect(result.summary.copyCount == 1)
  }

  @Test("比較後にコピー元のサイズまたは更新日時が変わった項目をスキップする")
  func skipsChangedSourceItem() async throws {
    let fixture = FreshnessFixture(
      leftTree: ["/left": [item("/left/report.txt", providerID: "fresh-left", size: 10)]],
      rightTree: ["/right": []])
    let plan = makePlan(
      left: fixture.leftItems,
      right: fixture.rightItems,
      direction: .leftToRight,
      deletesExtraneousItems: false)
    await fixture.leftState.setItems(
      [item("/left/report.txt", providerID: "fresh-left", size: 11, modifiedAt: date(20))],
      at: "/left")

    let result = await fixture.validator.revalidate(plan)

    #expect(result.operation(for: "report.txt")?.action == .skip(.changedSinceComparison))
    #expect(result.summary.copyCount == 0)
    #expect(result.summary.skipCount == 1)
  }

  @Test("コピー先に比較後の同名項目が現れたら上書きせずスキップする")
  func skipsCopyWhenDestinationAppeared() async throws {
    let fixture = FreshnessFixture(
      leftTree: ["/left": [item("/left/report.txt", providerID: "fresh-left", size: 10)]],
      rightTree: ["/right": []])
    let plan = makePlan(
      left: fixture.leftItems,
      right: fixture.rightItems,
      direction: .leftToRight,
      deletesExtraneousItems: false)
    await fixture.rightState.setItems(
      [item("/right/report.txt", providerID: "fresh-right", size: 1)],
      at: "/right")

    let result = await fixture.validator.revalidate(plan)

    #expect(result.operation(for: "report.txt")?.action == .skip(.changedSinceComparison))
  }

  @Test("削除候補と同じ相対パスが送り元へ現れたらゴミ箱へ移動せずスキップする")
  func skipsDeletionWhenSourceAppeared() async throws {
    let fixture = FreshnessFixture(
      leftTree: ["/left": []],
      rightTree: ["/right": [item("/right/extra.txt", providerID: "fresh-right", size: 10)]])
    let plan = makePlan(
      left: fixture.leftItems,
      right: fixture.rightItems,
      direction: .leftToRight,
      deletesExtraneousItems: true)
    await fixture.leftState.setItems(
      [item("/left/extra.txt", providerID: "fresh-left", size: 10)],
      at: "/left")

    let result = await fixture.validator.revalidate(plan)

    #expect(result.operation(for: "extra.txt")?.action == .skip(.changedSinceComparison))
    #expect(result.summary.deleteCount == 0)
  }

  @Test("検証用の列挙に失敗した項目は実行せず検証失敗として報告する")
  func skipsItemWhenInspectionFails() async throws {
    let fixture = FreshnessFixture(
      leftTree: ["/left": [item("/left/report.txt", providerID: "fresh-left", size: 10)]],
      rightTree: ["/right": []])
    let plan = makePlan(
      left: fixture.leftItems,
      right: fixture.rightItems,
      direction: .leftToRight,
      deletesExtraneousItems: false)
    await fixture.leftState.fail(path: "/left")

    let result = await fixture.validator.revalidate(plan)

    #expect(result.operation(for: "report.txt")?.action == .skip(.inspectionFailed))
  }

  @Test("親フォルダ配下の子が変わった場合は親フォルダの一括コピーを止める")
  func skipsCollapsedDirectoryCopyWhenDescendantChanged() async throws {
    let folder = directory("/left/folder", providerID: "fresh-left")
    let child = item("/left/folder/child.txt", providerID: "fresh-left", size: 10)
    let fixture = FreshnessFixture(
      leftTree: ["/left": [folder], "/left/folder": [child]],
      rightTree: ["/right": []])
    let plan = makePlan(
      left: fixture.allLeftItems,
      right: fixture.rightItems,
      direction: .leftToRight,
      deletesExtraneousItems: false)
    await fixture.leftState.setItems(
      [item("/left/folder/child.txt", providerID: "fresh-left", size: 99)],
      at: "/left/folder")

    let result = await fixture.validator.revalidate(plan)

    #expect(result.operation(for: "folder")?.action == .skip(.changedSinceComparison))
    #expect(result.summary.copyCount == 0)
  }

  private func makePlan(
    left: [FolderComparisonRecord],
    right: [FolderComparisonRecord],
    direction: FolderSyncDirection,
    deletesExtraneousItems: Bool
  ) -> FolderSyncPlan {
    let snapshot = FolderComparisonSnapshot(
      leftRoot: location("/left", providerID: "fresh-left"),
      rightRoot: location("/right", providerID: "fresh-right"),
      entries: FolderComparisonMatcher.compare(left: left, right: right),
      enumeratedItemCount: left.count + right.count,
      skippedSymbolicLinkCount: 0,
      partialErrorCount: 0,
      didReachItemLimit: false)
    return FolderSyncPlanner.makePlan(
      snapshot: snapshot,
      direction: direction,
      deletesExtraneousItems: deletesExtraneousItems,
      destinationDeletionMode: .trash)
  }
}

private struct FreshnessFixture {
  let leftState: FreshnessProviderState
  let rightState: FreshnessProviderState
  let leftProvider: FreshnessProvider
  let rightProvider: FreshnessProvider
  let leftItems: [FolderComparisonRecord]
  let rightItems: [FolderComparisonRecord]
  let allLeftItems: [FolderComparisonRecord]

  init(leftTree: [String: [FileItem]], rightTree: [String: [FileItem]]) {
    leftState = FreshnessProviderState(tree: leftTree)
    rightState = FreshnessProviderState(tree: rightTree)
    leftProvider = FreshnessProvider(id: "fresh-left", state: leftState)
    rightProvider = FreshnessProvider(id: "fresh-right", state: rightState)
    leftItems = Self.records(in: leftTree["/left"] ?? [], root: "/left")
    rightItems = Self.records(in: rightTree["/right"] ?? [], root: "/right")
    allLeftItems = leftTree.keys.sorted().flatMap { path in
      Self.records(in: leftTree[path] ?? [], root: "/left")
    }
  }

  var validator: FolderSyncFreshnessValidator {
    FolderSyncFreshnessValidator(leftProvider: leftProvider, rightProvider: rightProvider)
  }

  private static func records(in items: [FileItem], root: String) -> [FolderComparisonRecord] {
    items.map { item in
      let path = item.location.remotePath ?? ""
      let prefix = root == "/" ? "/" : "\(root)/"
      return FolderComparisonRecord(
        relativePath: String(path.dropFirst(prefix.count)),
        item: item)
    }
  }
}

private actor FreshnessProviderState {
  private var tree: [String: [FileItem]]
  private var failingPaths = Set<String>()

  init(tree: [String: [FileItem]]) {
    self.tree = tree
  }

  func contents(at path: String) throws -> [FileItem] {
    if failingPaths.contains(path) { throw FreshnessFixtureError.inspectionFailed }
    return tree[path] ?? []
  }

  func setItems(_ items: [FileItem], at path: String) {
    tree[path] = items
  }

  func fail(path: String) {
    failingPaths.insert(path)
  }
}

private struct FreshnessProvider: FileBrowserProvider {
  let id: FileProviderID
  let state: FreshnessProviderState
  let connectionID: FileProviderConnectionID? = nil
  let capabilities: FileProviderCapabilities = [.read, .write, .trash]

  init(id: String, state: FreshnessProviderState) {
    self.id = FileProviderID(rawValue: id)
    self.state = state
  }

  func contents(of location: FileLocation) async throws -> [FileItem] {
    try await state.contents(at: location.remotePath ?? "")
  }

  func parent(of location: FileLocation) -> FileLocation? {
    location.deletingLastPathComponent()
  }

  func breadcrumbs(
    for _: FileLocation,
    constrainedTo _: FileLocation?
  ) -> [FileBrowserBreadcrumb] { [] }
}

private enum FreshnessFixtureError: Error {
  case inspectionFailed
}

private func item(
  _ path: String,
  providerID: String,
  size: Int64,
  modifiedAt: Date = date(10)
) -> FileItem {
  FileItem(
    remotePath: path,
    url: URL(fileURLWithPath: path),
    providerID: FileProviderID(rawValue: providerID),
    isDirectory: false,
    size: size,
    modifiedAt: modifiedAt)
}

private func directory(_ path: String, providerID: String) -> FileItem {
  FileItem(
    remotePath: path,
    url: URL(fileURLWithPath: path),
    providerID: FileProviderID(rawValue: providerID),
    isDirectory: true,
    size: 0,
    modifiedAt: date(10))
}

private func location(_ path: String, providerID: String) -> FileLocation {
  FileLocation(remotePath: path, providerID: FileProviderID(rawValue: providerID))
}

private func date(_ seconds: TimeInterval) -> Date {
  Date(timeIntervalSince1970: seconds)
}

extension FolderSyncPlan {
  fileprivate func operation(for relativePath: String) -> FolderSyncOperation? {
    operations.first { $0.relativePath == relativePath }
  }
}
