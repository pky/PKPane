import Foundation
import Synchronization
import Testing

@testable import PKPane

@MainActor
struct FolderSyncPresentationTests {
  @Test("メニューの同期実行から比較を経て必須プレビューへ到達する")
  func menuActionReachesRequiredPreview() async throws {
    let provider = FolderSyncRouteProvider()
    let workspace = makeWorkspace(provider: provider)
    let presentation = FolderComparisonPresentationState()
    let menu = AppMenuModel()
    menu.register(
      context: AppMenuContext(
        isBrowserAvailable: true,
        canCompareFolders: true,
        showsSecondaryPane: true)
    ) { action in
      _ = presentation.handle(action, workspace: workspace)
    }

    menu.perform(.executeFolderSync)
    let model = try #require(presentation.model)
    await waitUntil { model.isPresentingSyncPreview }

    #expect(model.snapshot != nil)
    #expect(model.syncDirection == .leftToRight)
    #expect(!model.deletesExtraneousItems)
    #expect(model.syncPlan?.summary.copyCount == 1)
    #expect(model.syncPlan?.summary.deleteCount == 0)
    #expect(!model.canDeleteExtraneousItems)
  }

  @Test("同期実行の実経路は3表示モードで同じ必須プレビューを起動する")
  func routeIsIndependentOfViewMode() async throws {
    let provider = FolderSyncRouteProvider()
    let workspace = makeWorkspace(provider: provider)
    let presentation = FolderComparisonPresentationState()

    for mode in FileBrowserViewMode.selectableCases {
      workspace.setViewMode(mode)
      #expect(presentation.handle(.executeFolderSync, workspace: workspace))
      let model = try #require(presentation.model)
      await waitUntil { model.isPresentingSyncPreview }
      #expect(model.syncPlan != nil)
      presentation.dismiss()
    }
  }

  @Test("本番配線の同一Provider同期は上書きし削除OFFを維持する")
  func productionRouteOverwritesWithinSameProviderAndKeepsDeletionOff() async throws {
    let state = FolderSyncIntegrationState(files: [
      "/left/new.txt": integrationFile("新規", modifiedAt: 30),
      "/left/replace.txt": integrationFile("置換後", modifiedAt: 30),
      "/right/replace.txt": integrationFile("置換前", modifiedAt: 10),
      "/right/extra.txt": integrationFile("保持", modifiedAt: 10),
    ])
    let provider = FolderSyncIntegrationProvider(
      id: FileProviderID(rawValue: "folder-sync-same-provider"),
      state: state)
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let workspace = makeIntegrationWorkspace(
      leftProvider: provider,
      rightProvider: provider,
      queue: queue)
    let model = try #require(workspace.makeFolderComparisonModel())
    model.startComparison()
    await waitUntil { model.snapshot != nil && !model.isComparing }
    let subscriberCountBeforeExecution = await queue.updateSubscriberCount

    #expect(model.presentSyncPreview())
    #expect(!model.deletesExtraneousItems)
    #expect(model.executeSyncPlan())
    await waitUntil(timeout: .seconds(5)) {
      !model.isSyncExecuting && model.syncExecutionSummary != nil
    }
    await waitUntil {
      await queue.updateSubscriberCount == subscriberCountBeforeExecution
    }

    #expect(await state.data(at: "/right/new.txt") == Data("新規".utf8))
    #expect(await state.data(at: "/right/replace.txt") == Data("置換後".utf8))
    #expect(await state.data(at: "/right/extra.txt") == Data("保持".utf8))
    #expect(model.syncExecutionSummary?.failureCount == 0)
    #expect(await queue.updateSubscriberCount == subscriberCountBeforeExecution)
  }

  @Test("送り先の方が新しい項目はプレビューの明示チェックまで実行対象にしない")
  func previewRequiresExplicitConfirmationForNewerDestination() async throws {
    let state = FolderSyncIntegrationState(files: [
      "/left/report.txt": integrationFile("左の旧版", modifiedAt: 10),
      "/right/report.txt": integrationFile("右の新版", modifiedAt: 30),
    ])
    let provider = FolderSyncIntegrationProvider(
      id: FileProviderID(rawValue: "folder-sync-newer-destination"),
      state: state)
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let model = try #require(
      makeIntegrationWorkspace(
        leftProvider: provider,
        rightProvider: provider,
        queue: queue
      ).makeFolderComparisonModel())

    model.startComparison()
    await waitUntil { model.snapshot != nil && !model.isComparing }
    #expect(model.presentSyncPreview())

    #expect(!model.overwritesNewerDestinationItems)
    #expect(model.syncPlan?.summary.newerDestinationOverwriteCount == 1)
    #expect(model.syncPlan?.summary.overwriteCount == 0)
    #expect(model.syncPlan?.hasExecutableOperations == false)

    model.setOverwritesNewerDestinationItems(true)

    #expect(model.syncPlan?.summary.newerDestinationOverwriteCount == 1)
    #expect(model.syncPlan?.summary.overwriteCount == 0)
    #expect(model.syncPlan?.hasExecutableOperations == true)
  }

  @Test("本番配線のクロスProvider同期は既存転送キューでコピーと上書きを完了する")
  func productionRouteCopiesAcrossProviders() async throws {
    let leftState = FolderSyncIntegrationState(files: [
      "/left/new.txt": integrationFile("新規", modifiedAt: 30),
      "/left/replace.txt": integrationFile("置換後", modifiedAt: 30),
    ])
    let rightState = FolderSyncIntegrationState(files: [
      "/right/replace.txt": integrationFile("置換前", modifiedAt: 10)
    ])
    let leftProvider = FolderSyncIntegrationProvider(
      id: FileProviderID(rawValue: "folder-sync-cross-left"),
      state: leftState)
    let rightProvider = FolderSyncIntegrationProvider(
      id: FileProviderID(rawValue: "folder-sync-cross-right"),
      state: rightState)
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let model = try #require(
      makeIntegrationWorkspace(
        leftProvider: leftProvider,
        rightProvider: rightProvider,
        queue: queue
      ).makeFolderComparisonModel())

    model.startComparison()
    await waitUntil { model.snapshot != nil && !model.isComparing }
    #expect(model.presentSyncPreview())
    #expect(model.executeSyncPlan())
    await waitUntil(timeout: .seconds(5)) {
      !model.isSyncExecuting && model.syncExecutionSummary != nil
    }

    #expect(await rightState.data(at: "/right/new.txt") == Data("新規".utf8))
    #expect(await rightState.data(at: "/right/replace.txt") == Data("置換後".utf8))
    #expect(model.syncExecutionSummary?.successCount == 2)
    #expect((await queue.allJobs()).allSatisfy { $0.state == .completed })
  }

  @Test("本番配線の削除ONは全転送成功後にだけゴミ箱へ移動する")
  func productionRouteDeletesOnlyWhenEnabled() async throws {
    let state = FolderSyncIntegrationState(files: [
      "/right/extra.txt": integrationFile("削除対象", modifiedAt: 10)
    ])
    let provider = FolderSyncIntegrationProvider(
      id: FileProviderID(rawValue: "folder-sync-delete"),
      state: state)
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let model = try #require(
      makeIntegrationWorkspace(
        leftProvider: provider,
        rightProvider: provider,
        queue: queue
      ).makeFolderComparisonModel())

    model.startComparison()
    await waitUntil { model.snapshot != nil && !model.isComparing }
    #expect(model.presentSyncPreview())
    model.setDeletesExtraneousItems(true)
    #expect(model.executeSyncPlan())
    await waitUntil { !model.isSyncExecuting && model.syncExecutionSummary != nil }

    #expect(await state.data(at: "/right/extra.txt") == nil)
    #expect(await state.trashedPaths() == ["/right/extra.txt"])
    #expect(model.syncExecutionSummary?.result(for: "extra.txt")?.action == .delete)
  }

  @Test("完全削除Providerの同期は別確認後にだけ削除する")
  func permanentDeleteProviderRequiresSeparateConfirmation() async throws {
    let state = FolderSyncIntegrationState(files: [
      "/right/extra.txt": integrationFile("削除対象", modifiedAt: 10)
    ])
    let provider = FolderSyncIntegrationProvider(
      id: FileProviderID(rawValue: "folder-sync-permanent-delete"),
      state: state,
      usesPermanentDeletion: true)
    let model = try #require(
      makeIntegrationWorkspace(
        leftProvider: provider,
        rightProvider: provider,
        queue: TransferQueue(store: InMemoryTransferJobStore())
      ).makeFolderComparisonModel())

    model.startComparison()
    await waitUntil { model.snapshot != nil && !model.isComparing }
    #expect(model.presentSyncPreview())

    #expect(model.canDeleteExtraneousItems)
    model.setDeletesExtraneousItems(true)
    #expect(model.syncPlan?.summary.deleteCount == 1)

    #expect(model.executeSyncPlan())
    #expect(model.isPresentingPermanentDeleteConfirmation)
    #expect(!model.isSyncExecuting)
    #expect(await state.data(at: "/right/extra.txt") != nil)

    model.cancelPermanentDeleteSync()
    #expect(!model.isPresentingPermanentDeleteConfirmation)
    #expect(await state.data(at: "/right/extra.txt") != nil)

    #expect(model.executeSyncPlan())
    model.confirmPermanentDeleteSync()
    await waitUntil { !model.isSyncExecuting && model.syncExecutionSummary != nil }

    #expect(await state.data(at: "/right/extra.txt") == nil)
    #expect(await state.trashedPaths().isEmpty)
    #expect(await state.permanentlyDeletedPaths() == ["/right/extra.txt"])
    #expect(model.syncExecutionSummary?.successCount == 1)
  }

  @Test("本番配線の転送失敗は削除フェーズを中止する")
  func productionRouteDefersDeletionAfterTransferFailure() async throws {
    let leftState = FolderSyncIntegrationState(
      files: ["/left/bad.txt": integrationFile("失敗", modifiedAt: 30)],
      failingReadPaths: ["/left/bad.txt"])
    let rightState = FolderSyncIntegrationState(files: [
      "/right/extra.txt": integrationFile("保持", modifiedAt: 10)
    ])
    let leftProvider = FolderSyncIntegrationProvider(
      id: FileProviderID(rawValue: "folder-sync-failure-left"),
      state: leftState)
    let rightProvider = FolderSyncIntegrationProvider(
      id: FileProviderID(rawValue: "folder-sync-failure-right"),
      state: rightState)
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let model = try #require(
      makeIntegrationWorkspace(
        leftProvider: leftProvider,
        rightProvider: rightProvider,
        queue: queue
      ).makeFolderComparisonModel())

    model.startComparison()
    await waitUntil { model.snapshot != nil && !model.isComparing }
    #expect(model.presentSyncPreview())
    model.setDeletesExtraneousItems(true)
    #expect(model.executeSyncPlan())
    await waitUntil(timeout: .seconds(5)) {
      !model.isSyncExecuting && model.syncExecutionSummary != nil
    }

    #expect(await rightState.data(at: "/right/extra.txt") == Data("保持".utf8))
    #expect(await rightState.trashedPaths().isEmpty)
    #expect(
      model.syncExecutionSummary?.result(for: "extra.txt")?.outcome
        == .skipped(.deletionDeferredAfterTransferFailure))
  }

  @Test("同期キャンセルは待機中ジョブを止めisSyncExecutingを必ず下ろす")
  func cancellingProductionRouteAlwaysEndsExecutionState() async throws {
    let state = FolderSyncIntegrationState(
      files: [
        "/left/slow.txt": integrationFile("低速", modifiedAt: 30),
        "/right/extra.txt": integrationFile("保持", modifiedAt: 10),
      ],
      delayedCopyPaths: ["/left/slow.txt"])
    let provider = FolderSyncIntegrationProvider(
      id: FileProviderID(rawValue: "folder-sync-cancel"),
      state: state)
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let model = try #require(
      makeIntegrationWorkspace(
        leftProvider: provider,
        rightProvider: provider,
        queue: queue
      ).makeFolderComparisonModel())

    model.startComparison()
    await waitUntil { model.snapshot != nil && !model.isComparing }
    #expect(model.presentSyncPreview())
    model.setDeletesExtraneousItems(true)
    #expect(model.executeSyncPlan())
    await waitUntil {
      await queue.allJobs().contains { $0.state == .running }
    }

    model.cancelSyncExecution()
    await waitUntil(timeout: .seconds(5)) { !model.isSyncExecuting }

    #expect(!model.isSyncExecuting)
    #expect(await state.data(at: "/right/extra.txt") == Data("保持".utf8))
    #expect((await queue.allJobs()).allSatisfy(\.state.isTerminal))
  }

  private func makeWorkspace(
    provider: FolderSyncRouteProvider
  ) -> FileWorkspaceModel {
    let transferQueue = TransferQueue.isolatedForTesting()
    let workspace = FileWorkspaceModel(
      initialBrowser: FileBrowserSession(
        provider: provider,
        initialLocation: syncRouteLocation("/left"),
        transferQueue: transferQueue))
    workspace.activatePane(.secondary)
    workspace.replaceActiveBrowser(
      with: FileBrowserSession(
        provider: provider,
        initialLocation: syncRouteLocation("/right"),
        transferQueue: transferQueue))
    return workspace
  }

  private func makeIntegrationWorkspace(
    leftProvider: any FileBrowserProvider,
    rightProvider: any FileBrowserProvider,
    queue: TransferQueue
  ) -> FileWorkspaceModel {
    let workspace = FileWorkspaceModel(
      initialBrowser: FileBrowserSession(
        provider: leftProvider,
        initialLocation: FileLocation(remotePath: "/left", providerID: leftProvider.id),
        transferQueue: queue))
    workspace.activatePane(.secondary)
    workspace.replaceActiveBrowser(
      with: FileBrowserSession(
        provider: rightProvider,
        initialLocation: FileLocation(remotePath: "/right", providerID: rightProvider.id),
        transferQueue: queue))
    return workspace
  }

  private func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: @escaping @MainActor () async -> Bool
  ) async {
    await PKPaneTests.waitUntil(
      timeout: timeout, "フォルダ同期プレゼンテーションの状態が期限内に条件を満たさなかった"
    ) {
      await condition()
    }
  }
}

private struct FolderSyncIntegrationFile: Sendable {
  let data: Data
  let modifiedAt: Date
}

private actor FolderSyncIntegrationState {
  private var files: [String: FolderSyncIntegrationFile]
  private let failingReadPaths: Set<String>
  private let delayedCopyPaths: Set<String>
  private var trashCalls = [String]()
  private var permanentDeleteCalls = [String]()

  init(
    files: [String: FolderSyncIntegrationFile],
    failingReadPaths: Set<String> = [],
    delayedCopyPaths: Set<String> = []
  ) {
    self.files = files
    self.failingReadPaths = failingReadPaths
    self.delayedCopyPaths = delayedCopyPaths
  }

  func contents(at directory: String, providerID: FileProviderID) -> [FileItem] {
    files.compactMap { path, file in
      guard parentPath(of: path) == directory else { return nil }
      return FileItem(
        remotePath: path,
        url: URL(string: "folder-sync-integration://host\(path)")!,
        providerID: providerID,
        isDirectory: false,
        size: Int64(file.data.count),
        modifiedAt: file.modifiedAt)
    }.sorted { $0.name < $1.name }
  }

  func read(at path: String) async throws -> FolderSyncIntegrationFile {
    if failingReadPaths.contains(path) {
      throw FolderSyncIntegrationError.injectedFailure
    }
    if delayedCopyPaths.contains(path) {
      try await Task.sleep(for: .seconds(30))
    }
    guard let file = files[path] else { throw CocoaError(.fileNoSuchFile) }
    return file
  }

  func write(
    _ file: FolderSyncIntegrationFile,
    to path: String,
    replacingExisting: Bool
  ) throws {
    if files[path] != nil, !replacingExisting {
      throw CocoaError(.fileWriteFileExists)
    }
    files[path] = file
  }

  func commit(from temporaryPath: String, to destinationPath: String, replacingExisting: Bool)
    throws
  {
    guard let file = files[temporaryPath] else { throw CocoaError(.fileNoSuchFile) }
    if files[destinationPath] != nil, !replacingExisting {
      throw CocoaError(.fileWriteFileExists)
    }
    files[temporaryPath] = nil
    files[destinationPath] = file
  }

  func remove(at path: String) {
    files[path] = nil
  }

  func trash(at path: String) {
    files[path] = nil
    trashCalls.append(path)
  }

  func permanentlyDelete(at path: String) {
    files[path] = nil
    permanentDeleteCalls.append(path)
  }

  func data(at path: String) -> Data? { files[path]?.data }
  func trashedPaths() -> [String] { trashCalls }
  func permanentlyDeletedPaths() -> [String] { permanentDeleteCalls }

  private func parentPath(of path: String) -> String {
    let components = path.split(separator: "/")
    guard components.count > 1 else { return "/" }
    return "/" + components.dropLast().joined(separator: "/")
  }
}

private struct FolderSyncIntegrationProvider: FileBrowserProgressTransferProvider,
  FileStreamTransferProvider, FileTransferCommitProvider, FileBrowserTrashProvider,
  FileBrowserPermanentDeleteProvider
{
  let id: FileProviderID
  let state: FolderSyncIntegrationState
  var usesPermanentDeletion = false
  let connectionID: FileProviderConnectionID? = nil
  var capabilities: FileProviderCapabilities {
    var capabilities: FileProviderCapabilities = [
      .read, .write, .copyWithinProvider, .replaceAtomically,
    ]
    capabilities.insert(usesPermanentDeletion ? .deletePermanently : .trash)
    return capabilities
  }

  func contents(of location: FileLocation) async throws -> [FileItem] {
    await state.contents(at: location.remotePath ?? "", providerID: id)
  }

  func parent(of location: FileLocation) -> FileLocation? {
    location.deletingLastPathComponent()
  }

  func breadcrumbs(
    for _: FileLocation,
    constrainedTo _: FileLocation?
  ) -> [FileBrowserBreadcrumb] { [] }

  func createDirectory(named _: String, in _: FileLocation) async throws {}
  func rename(_: FileItem, to _: String) async throws {}

  func delete(_ item: FileItem) async throws {
    await state.trash(at: item.location.remotePath ?? "")
  }

  func permanentlyDelete(_ item: FileItem) async throws {
    await state.permanentlyDelete(at: item.location.remotePath ?? "")
  }

  func move(
    _ item: FileItem,
    to directory: FileLocation,
    replacingExisting _: Bool
  ) async throws {
    try await copy(item, to: directory, replacingExisting: false)
    await state.remove(at: item.location.remotePath ?? "")
  }

  func copy(
    _ item: FileItem,
    to directory: FileLocation,
    replacingExisting: Bool
  ) async throws {
    try await copy(
      item,
      to: directory,
      replacingExisting: replacingExisting,
      progress: { _ in })
  }

  func copy(
    _ item: FileItem,
    to directory: FileLocation,
    replacingExisting: Bool,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws {
    guard let sourcePath = item.location.remotePath,
      let destinationPath = directory.appending(pathComponent: item.name)?.remotePath
    else { throw CocoaError(.fileNoSuchFile) }
    let file = try await state.read(at: sourcePath)
    try await state.write(file, to: destinationPath, replacingExisting: replacingExisting)
    progress(Int64(file.data.count))
  }

  func removeAfterCrossProviderMove(_ item: FileItem) async throws {
    await state.remove(at: item.location.remotePath ?? "")
  }

  func fileChunks(for item: FileItem, chunkSize _: Int) -> AsyncThrowingStream<Data, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let file = try await state.read(at: item.location.remotePath ?? "")
          continuation.yield(file.data)
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  func writeFileChunks(
    _ chunks: AsyncThrowingStream<Data, Error>,
    to destination: FileLocation,
    replacingExisting: Bool,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws {
    var data = Data()
    for try await chunk in chunks {
      data.append(chunk)
      progress(Int64(data.count))
    }
    try await state.write(
      FolderSyncIntegrationFile(data: data, modifiedAt: Date(timeIntervalSince1970: 50)),
      to: destination.remotePath ?? "",
      replacingExisting: replacingExisting)
  }

  func stagedFileSize(at temporaryLocation: FileLocation) async throws -> Int64? {
    await state.data(at: temporaryLocation.remotePath ?? "").map { Int64($0.count) }
  }

  func commitTransferFile(
    from temporaryLocation: FileLocation,
    to destination: FileLocation,
    replacingExisting: Bool
  ) async throws {
    try await state.commit(
      from: temporaryLocation.remotePath ?? "",
      to: destination.remotePath ?? "",
      replacingExisting: replacingExisting)
  }

  func discardTransferFile(at temporaryLocation: FileLocation) async {
    await state.remove(at: temporaryLocation.remotePath ?? "")
  }
}

private enum FolderSyncIntegrationError: Error {
  case injectedFailure
}

private func integrationFile(_ value: String, modifiedAt: TimeInterval) -> FolderSyncIntegrationFile
{
  FolderSyncIntegrationFile(
    data: Data(value.utf8),
    modifiedAt: Date(timeIntervalSince1970: modifiedAt))
}

extension FolderSyncExecutionSummary {
  fileprivate func result(for relativePath: String) -> FolderSyncExecutionItemResult? {
    results.first { $0.relativePath == relativePath }
  }
}

private struct FolderSyncRouteProvider: FileBrowserProvider {
  let id = FileProviderID(rawValue: "folder-sync-route")
  let connectionID: FileProviderConnectionID? = nil
  let capabilities: FileProviderCapabilities = [.read]

  func contents(of location: FileLocation) async throws -> [FileItem] {
    switch location.remotePath {
    case "/left":
      [syncRouteItem("left.txt", parent: "/left", size: 3)]
    case "/right":
      [syncRouteItem("right.txt", parent: "/right", size: 5)]
    default:
      []
    }
  }

  func parent(of _: FileLocation) -> FileLocation? { nil }

  func breadcrumbs(
    for _: FileLocation,
    constrainedTo _: FileLocation?
  ) -> [FileBrowserBreadcrumb] { [] }
}

private func syncRouteLocation(_ path: String) -> FileLocation {
  FileLocation(
    remotePath: path,
    providerID: FileProviderID(rawValue: "folder-sync-route"))
}

private func syncRouteItem(_ name: String, parent: String, size: Int64) -> FileItem {
  let path = "\(parent)/\(name)"
  return FileItem(
    remotePath: path,
    url: URL(string: "folder-sync-route://host\(path)")!,
    providerID: FileProviderID(rawValue: "folder-sync-route"),
    isDirectory: false,
    size: size,
    modifiedAt: Date(timeIntervalSince1970: TimeInterval(size)))
}
