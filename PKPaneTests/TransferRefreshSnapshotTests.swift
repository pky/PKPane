import Foundation
import Testing

@testable import PKPane

@MainActor
struct TransferRefreshSnapshotTests {
  @Test(
    "どの表示でも移動完了の再列挙は途中の短い一覧を公開しない",
    arguments: [FileBrowserViewMode.list, .icon, .column])
  func moveRefreshKeepsCompleteSourceSnapshot(mode: FileBrowserViewMode) async throws {
    let provider = TransferRefreshSnapshotProvider()
    let queue = TransferQueue.isolatedForTesting()
    let source = FileBrowserSession(
      provider: provider, initialLocation: provider.source, transferQueue: queue)
    let destination = FileBrowserSession(
      provider: provider, initialLocation: provider.destination, transferQueue: queue)
    defer {
      provider.finishRefresh()
      source.invalidate()
      destination.invalidate()
    }
    source.load()
    destination.load()
    try #require(
      await waitUntil("初期一覧が完成しなかった") {
        !source.isLoading && !destination.isLoading && source.items.count == 200
      })
    if mode == .column { source.beginColumnBrowsing() }
    let originalItems = source.items
    let movedItem = try #require(originalItems.last)
    source.move([movedItem], to: destination)
    try #require(
      await waitUntil("移動後の再列挙が始まらなかった") {
        provider.hasPendingRefresh && source.isRefreshing
      })
    // ゲートは第1バッチの処理後、次のバッチを要求した時点で立つ。
    #expect(source.items.count == originalItems.count)
    if mode == .column {
      #expect(source.columnState.columns.first?.items.count == originalItems.count)
    }
    provider.finishRefresh()
    try #require(
      await waitUntil("移動後の完成一覧が反映されなかった") {
        source.lastCompletedTransfer != nil
      })
    #expect(!source.isRefreshing)
    #expect(source.items.count == 199)
    #expect(!source.items.contains(where: { $0.location == movedItem.location }))
    #expect(destination.items.count == 1)
  }
}

private final class TransferRefreshSnapshotProvider: FileBrowserStreamingProvider,
  FileBrowserTransferProvider, @unchecked Sendable
{
  let id = FileProviderID(rawValue: "scroll-refresh-fixture")
  let connectionID: FileProviderConnectionID? = nil
  let capabilities: FileProviderCapabilities = [.read, .write, .moveWithinProvider]
  var source: FileLocation { FileLocation(remotePath: "/source", providerID: id) }
  var destination: FileLocation { FileLocation(remotePath: "/destination", providerID: id) }
  private let lock = NSLock()
  private var moved = false
  private var pending: CheckedContinuation<[FileItem]?, Never>?
  private var refreshBatchIndex = 0

  var hasPendingRefresh: Bool { lock.withLock { pending != nil } }

  private var originalItems: [FileItem] {
    (0..<200).map {
      FileItem(
        url: URL(filePath: String(format: "/source/%03d.txt", $0)),
        providerID: id, isDirectory: false)
    }
  }

  func contents(of location: FileLocation) async throws -> [FileItem] {
    let didMove = lock.withLock { moved }
    if location == source { return didMove ? Array(originalItems.dropLast()) : originalItems }
    return didMove
      ? [
        FileItem(
          url: URL(filePath: "/destination/199.txt"), providerID: id,
          isDirectory: false)
      ] : []
  }

  func contentsStream(
    of location: FileLocation, includingHidden _: Bool, batchSize _: Int
  ) -> AsyncThrowingStream<[FileItem], Error> {
    let didMove = lock.withLock { moved }
    if location == source, didMove {
      lock.withLock { refreshBatchIndex = 0 }
      return AsyncThrowingStream(unfolding: { [self] in
        let index = lock.withLock {
          let value = refreshBatchIndex
          refreshBatchIndex += 1
          return value
        }
        if index == 0 { return Array(originalItems.prefix(5)) }
        guard index == 1 else { return nil }
        // 次のnext()は呼出元の第1バッチ処理が完了してから到達する。
        return await withCheckedContinuation { continuation in
          lock.withLock { pending = continuation }
        }
      })
    }
    return AsyncThrowingStream { continuation in
      let items: [FileItem] =
        location == source
        ? originalItems
        : (didMove
          ? [
            FileItem(
              url: URL(filePath: "/destination/199.txt"), providerID: id,
              isDirectory: false)
          ] : [])
      continuation.yield(items)
      continuation.finish()
    }
  }

  func finishRefresh() {
    let continuation = lock.withLock {
      let value = pending
      pending = nil
      return value
    }
    continuation?.resume(returning: Array(originalItems.dropFirst(5).dropLast()))
  }

  func parent(of _: FileLocation) -> FileLocation? { nil }
  func breadcrumbs(for _: FileLocation, constrainedTo _: FileLocation?) -> [FileBrowserBreadcrumb] {
    []
  }
  func createDirectory(named _: String, in _: FileLocation) async throws {}
  func rename(_: FileItem, to _: String) async throws {}
  func delete(_: FileItem) async throws {}
  func move(_: FileItem, to _: FileLocation, replacingExisting _: Bool) async throws {
    lock.withLock { moved = true }
  }
  func copy(_: FileItem, to _: FileLocation, replacingExisting _: Bool) async throws {}
  func removeAfterCrossProviderMove(_: FileItem) async throws {}
}
