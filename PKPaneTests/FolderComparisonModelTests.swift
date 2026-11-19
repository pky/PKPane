import Foundation
import Synchronization
import Testing

@testable import PKPane

@MainActor
struct FolderComparisonModelTests {
  @Test("比較結果の左右コピーは既存TransferQueueへcopyジョブを積む")
  func copyActionsEnqueueExistingTransferJobs() async throws {
    let state = FolderComparisonTransferFixtureState(
      tree: [
        "/left": [transferItem("left.txt", parent: "/left", size: 1)],
        "/right": [transferItem("right.txt", parent: "/right", size: 2)],
      ])
    let provider = FolderComparisonTransferFixtureProvider(state: state)
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let leftBrowser = FileBrowserSession(
      provider: provider,
      initialLocation: transferLocation("/left"),
      transferQueue: queue)
    let rightBrowser = FileBrowserSession(
      provider: provider,
      initialLocation: transferLocation("/right"),
      transferQueue: queue)
    let workspace = FileWorkspaceModel(initialBrowser: leftBrowser)
    workspace.activatePane(.secondary)
    workspace.replaceActiveBrowser(with: rightBrowser)
    let model = try #require(workspace.makeFolderComparisonModel())

    model.startComparison()
    await waitUntil { !model.isComparing && model.snapshot != nil }
    let leftOnly = try #require(
      model.snapshot?.entries.first { $0.relativePath == "left.txt" })
    let rightOnly = try #require(
      model.snapshot?.entries.first { $0.relativePath == "right.txt" })

    #expect(model.copy(leftOnly, to: .right))
    await waitUntil { await queue.allJobs().count == 1 }
    #expect(model.copy(rightOnly, to: .left))
    await waitUntil { await queue.allJobs().count == 2 }
    let jobs = await queue.allJobs()

    #expect(jobs.allSatisfy { $0.kind == .copy })
    #expect(
      jobs.contains {
        $0.items.map(\.location) == [transferLocation("/left/left.txt")]
          && $0.destination == transferLocation("/right")
      })
    #expect(
      jobs.contains {
        $0.items.map(\.location) == [transferLocation("/right/right.txt")]
          && $0.destination == transferLocation("/left")
      })
    // ジョブ投入(allJobs反映)と実行(provider.copy呼び出し)は非同期に進むため、
    // 実行完了を期限ベースで待ってから回数を検査する。
    await waitUntil { await state.copyCalls().count == 2 }
    #expect(await state.copyCalls().count == 2)
    #expect(await state.deleteCallCount() == 0)
    #expect(await state.removeAfterMoveCallCount() == 0)
  }

  @Test("ネスト項目のコピー先は反対側ルート配下の同じ相対親になる")
  func nestedCopyUsesMatchingRelativeParent() async throws {
    let state = FolderComparisonTransferFixtureState(
      tree: [
        "/left": [transferDirectory("nested", parent: "/left")],
        "/left/nested": [transferItem("deep.txt", parent: "/left/nested", size: 1)],
        "/right": [transferDirectory("nested", parent: "/right")],
        "/right/nested": [],
      ])
    let provider = FolderComparisonTransferFixtureProvider(state: state)
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let workspace = FileWorkspaceModel(
      initialBrowser: FileBrowserSession(
        provider: provider,
        initialLocation: transferLocation("/left"),
        transferQueue: queue))
    workspace.activatePane(.secondary)
    workspace.replaceActiveBrowser(
      with: FileBrowserSession(
        provider: provider,
        initialLocation: transferLocation("/right"),
        transferQueue: queue))
    let model = try #require(workspace.makeFolderComparisonModel())

    model.startComparison()
    await waitUntil { !model.isComparing && model.snapshot != nil }
    let entry = try #require(
      model.snapshot?.entries.first { $0.relativePath == "nested/deep.txt" })
    #expect(model.copy(entry, to: .right))
    await waitUntil { await queue.allJobs().count == 1 }

    #expect(await queue.allJobs().first?.destination == transferLocation("/right/nested"))
  }

  @Test("コピー元がない方向は無効で削除系操作を発火しない")
  func unavailableDirectionDoesNothing() async throws {
    let state = FolderComparisonTransferFixtureState(
      tree: [
        "/left": [transferItem("left.txt", parent: "/left", size: 1)],
        "/right": [],
      ])
    let provider = FolderComparisonTransferFixtureProvider(state: state)
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let workspace = FileWorkspaceModel(
      initialBrowser: FileBrowserSession(
        provider: provider,
        initialLocation: transferLocation("/left"),
        transferQueue: queue))
    workspace.activatePane(.secondary)
    workspace.replaceActiveBrowser(
      with: FileBrowserSession(
        provider: provider,
        initialLocation: transferLocation("/right"),
        transferQueue: queue))
    let model = try #require(workspace.makeFolderComparisonModel())

    model.startComparison()
    await waitUntil { !model.isComparing && model.snapshot != nil }
    let entry = try #require(model.snapshot?.entries.first)

    #expect(!model.canCopy(entry, to: .left))
    #expect(!model.copy(entry, to: .left))
    #expect(await queue.allJobs().isEmpty)
    #expect(await state.deleteCallCount() == 0)
    #expect(await state.removeAfterMoveCallCount() == 0)
  }

  private func waitUntil(_ condition: @escaping @MainActor () async -> Bool) async {
    await PKPaneTests.waitUntil("フォルダ比較モデルの状態が期限内に条件を満たさなかった") {
      await condition()
    }
  }
}

private actor FolderComparisonTransferFixtureState {
  struct CopyCall: Equatable {
    let source: FileLocation
    let destination: FileLocation
  }

  private let tree: [String: [FileItem]]
  private var recordedCopyCalls = [CopyCall]()
  private var recordedDeleteCallCount = 0
  private var recordedRemoveAfterMoveCallCount = 0

  init(tree: [String: [FileItem]]) {
    self.tree = tree
  }

  func contents(at path: String) -> [FileItem] { tree[path] ?? [] }

  func recordCopy(_ item: FileItem, to destination: FileLocation) {
    recordedCopyCalls.append(CopyCall(source: item.location, destination: destination))
  }

  func recordDelete() { recordedDeleteCallCount += 1 }
  func recordRemoveAfterMove() { recordedRemoveAfterMoveCallCount += 1 }
  func copyCalls() -> [CopyCall] { recordedCopyCalls }
  func deleteCallCount() -> Int { recordedDeleteCallCount }
  func removeAfterMoveCallCount() -> Int { recordedRemoveAfterMoveCallCount }
}

private struct FolderComparisonTransferFixtureProvider: FileBrowserTransferProvider {
  let state: FolderComparisonTransferFixtureState
  let id = FileProviderID(rawValue: "folder-comparison-transfer")
  let connectionID: FileProviderConnectionID? = nil
  let capabilities: FileProviderCapabilities = [.read, .write, .copyWithinProvider]

  func contents(of location: FileLocation) async throws -> [FileItem] {
    await state.contents(at: location.remotePath ?? "")
  }

  func parent(of _: FileLocation) -> FileLocation? { nil }

  func breadcrumbs(
    for _: FileLocation,
    constrainedTo _: FileLocation?
  ) -> [FileBrowserBreadcrumb] { [] }

  func createDirectory(named _: String, in _: FileLocation) async throws {}
  func rename(_: FileItem, to _: String) async throws {}

  func delete(_: FileItem) async throws {
    await state.recordDelete()
  }

  func move(
    _: FileItem,
    to _: FileLocation,
    replacingExisting _: Bool
  ) async throws {}

  func copy(
    _ item: FileItem,
    to destination: FileLocation,
    replacingExisting _: Bool
  ) async throws {
    await state.recordCopy(item, to: destination)
  }

  func removeAfterCrossProviderMove(_: FileItem) async throws {
    await state.recordRemoveAfterMove()
  }
}

private func transferLocation(_ path: String) -> FileLocation {
  FileLocation(
    remotePath: path,
    providerID: FileProviderID(rawValue: "folder-comparison-transfer"))
}

private func transferItem(_ name: String, parent: String, size: Int64) -> FileItem {
  let path = "\(parent)/\(name)"
  return FileItem(
    remotePath: path,
    url: URL(string: "folder-comparison-transfer://host\(path)")!,
    providerID: FileProviderID(rawValue: "folder-comparison-transfer"),
    isDirectory: false,
    size: size)
}

private func transferDirectory(_ name: String, parent: String) -> FileItem {
  let path = "\(parent)/\(name)"
  return FileItem(
    remotePath: path,
    url: URL(string: "folder-comparison-transfer://host\(path)")!,
    providerID: FileProviderID(rawValue: "folder-comparison-transfer"),
    isDirectory: true)
}
