import Foundation
import Testing

@testable import PKPane

@MainActor
struct BatchRenameExecutionTests {
  @Test("セッション層は不正な変更後名をProviderへ渡さず全件失敗にする")
  func rejectsInvalidNamesBeforeCallingProvider() async throws {
    for invalidName in ["", ".", "..", "folder/name", "nul\0name"] {
      let provider = BatchRenameExecutionProvider(names: ["source.txt"])
      let session = makeSession(provider: provider)
      try #require(!provider.currentItems.isEmpty)
      let item = provider.currentItems[0]

      let result = await session.batchRename([(item: item, newName: invalidName)])

      #expect(result.successes.isEmpty)
      #expect(result.failures.count == 1)
      #expect(provider.renameCalls.isEmpty)
    }
  }

  @Test("セッション層はバッチ内重複をProviderへ渡さず全件失敗にする")
  func rejectsDuplicateNamesBeforeCallingProvider() async throws {
    let provider = BatchRenameExecutionProvider(names: ["a.txt", "b.txt"])
    let session = makeSession(provider: provider)
    let items = provider.currentItems
    try #require(items.count == 2)

    let result = await session.batchRename([
      (item: items[0], newName: "same.txt"),
      (item: items[1], newName: "SAME.txt"),
    ])

    #expect(result.successes.isEmpty)
    #expect(result.failures.count == 2)
    #expect(provider.renameCalls.isEmpty)
  }

  @Test("セッション層は選択外と変更なし項目の現在名への衝突を実行しない")
  func rejectsExistingAndUnchangedItemCollisionsBeforeCallingProvider() async throws {
    let provider = BatchRenameExecutionProvider(
      names: ["a.txt", "b.txt", "occupied.txt", "unchanged.txt"]
    )
    let session = makeSession(provider: provider)
    session.load()
    await waitUntil { !session.isLoading }
    let a = try #require(session.items.first { $0.name == "a.txt" })
    let b = try #require(session.items.first { $0.name == "b.txt" })

    let result = await session.batchRename([
      (item: a, newName: "occupied.txt"),
      (item: b, newName: "unchanged.txt"),
    ])

    #expect(result.successes.isEmpty)
    #expect(result.failures.count == 2)
    #expect(provider.renameCalls.isEmpty)
  }

  @Test("一括リネームを逐次実行して全件終了後に一覧を一度だけ再読込する")
  func renamesAllItemsAndRefreshesOnce() async throws {
    let provider = BatchRenameExecutionProvider(names: ["a.txt", "b.txt"])
    let session = makeSession(provider: provider)
    let items = provider.currentItems
    try #require(items.count == 2)

    let result = await session.batchRename([
      (item: items[0], newName: "renamed-a.txt"),
      (item: items[1], newName: "renamed-b.txt"),
    ])

    #expect(result.successes.count == 2)
    #expect(result.failures.isEmpty)
    #expect(provider.renameCalls.map(\.oldName) == ["a.txt", "b.txt"])
    #expect(provider.contentsCallCount == 1)
    #expect(Set(session.items.map(\.name)) == ["renamed-a.txt", "renamed-b.txt"])
  }

  @Test("部分失敗は成功分を維持し失敗件数を示して成功分だけUndoへ記録する")
  func preservesPartialSuccessAndUndoesOnlySuccessfulItems() async throws {
    let provider = BatchRenameExecutionProvider(
      names: ["a.txt", "b.txt"],
      failingNames: ["b.txt"]
    )
    let session = makeSession(provider: provider)
    let items = provider.currentItems
    try #require(items.count == 2)

    let result = await session.batchRename([
      (item: items[0], newName: "renamed-a.txt"),
      (item: items[1], newName: "renamed-b.txt"),
    ])

    #expect(result.successes.map(\.oldName) == ["a.txt"])
    #expect(result.failures.map(\.itemName) == ["b.txt"])
    #expect(provider.names == ["renamed-a.txt", "b.txt"])
    #expect(session.errorMessage?.contains("2件中1件を変更できませんでした") == true)
    #expect(session.errorMessage?.contains("b.txt") == true)

    let workspace = FileWorkspaceModel(initialBrowser: session)
    workspace.recordBatchRenameUndo(result.successes, in: session)
    #expect(workspace.canUndoLastTransfer)
    #expect(workspace.lastUndoKind == .batchRename)

    workspace.undoLastTransfer()
    await waitUntil { provider.renameCalls.count == 3 && !session.isLoading }

    #expect(provider.names == ["a.txt", "b.txt"])
    #expect(provider.renameCalls.last?.oldName == "renamed-a.txt")
    #expect(provider.renameCalls.last?.newName == "a.txt")
    #expect(!workspace.canUndoLastTransfer)
  }

  @Test("転送と一括リネームは実行順に新しい方だけをUndo対象にする")
  func latestTransferOrBatchRenameWinsUndo() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "batch-rename-undo-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = root.appending(path: "source", directoryHint: .isDirectory)
    let firstDestinationURL = root.appending(path: "destination-1", directoryHint: .isDirectory)
    let secondDestinationURL = root.appending(path: "destination-2", directoryHint: .isDirectory)
    for directory in [sourceURL, firstDestinationURL, secondDestinationURL] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    try Data("rename".utf8).write(to: sourceURL.appending(path: "rename.txt"))
    try Data("copy".utf8).write(to: sourceURL.appending(path: "copy.txt"))

    let provider = LocalFileProvider()
    let queue = TransferQueue(store: InMemoryTransferJobStore())
    let initialBrowser = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: sourceURL, providerID: provider.id),
      transferQueue: queue
    )
    let workspace = FileWorkspaceModel(initialBrowser: initialBrowser)
    let source = workspace.activeTab.browser
    source.load()
    await waitUntil { !source.isLoading }
    let firstDestination = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: firstDestinationURL, providerID: provider.id),
      transferQueue: queue
    )

    workspace.activeTab.selectedItemURLs = [
      try #require(source.items.first { $0.name == "copy.txt" }).url
    ]
    workspace.transferSelectedItems(to: firstDestination, wasMove: false)
    await waitUntil { workspace.lastUndoKind == .transfer }
    #expect(
      FileManager.default.fileExists(atPath: firstDestinationURL.appending(path: "copy.txt").path))

    let firstRenameItem = try #require(source.items.first { $0.name == "rename.txt" })
    let firstRenameResult = await source.batchRename([
      (item: firstRenameItem, newName: "renamed.txt")
    ])
    workspace.recordBatchRenameUndo(firstRenameResult.successes, in: source)
    #expect(workspace.lastUndoKind == .batchRename)

    workspace.undoLastTransfer()
    await waitUntil {
      FileManager.default.fileExists(atPath: sourceURL.appending(path: "rename.txt").path)
        && !source.isLoading
    }
    #expect(
      FileManager.default.fileExists(atPath: firstDestinationURL.appending(path: "copy.txt").path))

    let secondRenameItem = try #require(source.items.first { $0.name == "rename.txt" })
    let secondRenameResult = await source.batchRename([
      (item: secondRenameItem, newName: "renamed.txt")
    ])
    workspace.recordBatchRenameUndo(secondRenameResult.successes, in: source)
    #expect(workspace.lastUndoKind == .batchRename)

    let secondDestination = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: secondDestinationURL, providerID: provider.id),
      transferQueue: queue
    )
    workspace.activeTab.selectedItemURLs = [
      try #require(source.items.first { $0.name == "copy.txt" }).url
    ]
    workspace.transferSelectedItems(to: secondDestination, wasMove: false)
    await waitUntil { workspace.lastUndoKind == .transfer }

    workspace.undoLastTransfer()
    await waitUntil {
      !FileManager.default.fileExists(
        atPath: secondDestinationURL.appending(path: "copy.txt").path)
    }

    #expect(FileManager.default.fileExists(atPath: sourceURL.appending(path: "renamed.txt").path))
    #expect(!workspace.canUndoLastTransfer)
  }

  private func makeSession(provider: BatchRenameExecutionProvider) -> FileBrowserSession {
    FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: ".", providerID: provider.id),
      transferQueue: .isolatedForTesting())
  }

  private func waitUntil(
    _ condition: @escaping @MainActor () -> Bool
  ) async {
    await PKPaneTests.waitUntil("一括リネーム実行の状態が期限内に条件を満たさなかった") {
      condition()
    }
  }
}

private final class BatchRenameExecutionProvider: FileBrowserOperationProvider,
  @unchecked Sendable
{
  struct RenameCall: Equatable {
    let oldName: String
    let newName: String
  }

  let id = FileProviderID(rawValue: "batch-rename-execution")
  let connectionID: FileProviderConnectionID? = nil
  let capabilities: FileProviderCapabilities = [.read, .write, .rename]

  private let lock = NSLock()
  private var storedNames: Set<String>
  private let failingNames: Set<String>
  private var storedRenameCalls = [RenameCall]()
  private var storedContentsCallCount = 0

  init(names: Set<String>, failingNames: Set<String> = []) {
    storedNames = names
    self.failingNames = failingNames
  }

  var names: Set<String> {
    lock.withLock { storedNames }
  }

  var currentItems: [FileItem] {
    lock.withLock { storedNames.sorted().map(makeItem) }
  }

  var renameCalls: [RenameCall] {
    lock.withLock { storedRenameCalls }
  }

  var contentsCallCount: Int {
    lock.withLock { storedContentsCallCount }
  }

  func contents(of _: FileLocation) async throws -> [FileItem] {
    lock.withLock {
      storedContentsCallCount += 1
      return storedNames.sorted().map(makeItem)
    }
  }

  func parent(of _: FileLocation) -> FileLocation? { nil }

  func breadcrumbs(
    for location: FileLocation,
    constrainedTo _: FileLocation?
  ) -> [FileBrowserBreadcrumb] {
    [FileBrowserBreadcrumb(location: location, name: "Test")]
  }

  func createDirectory(named _: String, in _: FileLocation) async throws {}

  func rename(_ item: FileItem, to name: String) async throws {
    try lock.withLock {
      storedRenameCalls.append(RenameCall(oldName: item.name, newName: name))
      if failingNames.contains(item.name) {
        throw CocoaError(.fileWriteNoPermission)
      }
      guard storedNames.remove(item.name) != nil else {
        throw CocoaError(.fileNoSuchFile)
      }
      storedNames.insert(name)
    }
  }

  func delete(_: FileItem) async throws {}

  private func makeItem(_ name: String) -> FileItem {
    FileItem(
      remotePath: "./\(name)",
      url: URL(filePath: "/\(name)"),
      providerID: id,
      isDirectory: false
    )
  }
}
