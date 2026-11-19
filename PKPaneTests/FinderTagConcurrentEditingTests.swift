import Foundation
import Testing

@testable import PKPane

@MainActor
struct FinderTagConcurrentEditingTests {
  @Test("別セッションの色操作と編集操作を直列化して互いの追加タグを消さない", arguments: [false, true])
  func preservesBothMutationsAcrossSessions(usesEditorMutation: Bool) async throws {
    let provider = DelayedFinderTagWriteProvider()
    let root = FileLocation(remotePath: "/root", providerID: provider.id)
    let firstSession = FileBrowserSession(
      provider: provider, initialLocation: root, transferQueue: .isolatedForTesting())
    let secondSession = FileBrowserSession(
      provider: provider, initialLocation: root, transferQueue: .isolatedForTesting())
    let item = provider.item
    let first = Task { await firstSession.toggleFinderTag(name: "赤", for: [item]) }
    await provider.gate.waitUntilFirstWriteStarted()
    var secondFinished = false
    let second = Task {
      let result: FinderTagUpdateResult
      if usesEditorMutation {
        result = await secondSession.updateFinderTags(
          FinderTagMutation(additions: ["青"], removals: []), for: [item])
      } else {
        result = await secondSession.toggleFinderTag(name: "青", for: [item])
      }
      secondFinished = true
      return result
    }

    // 直列化がなければ、停止中の最初の書込を追い越して2件目が完了する。
    // 正しい直列化では、この時間枠の間も先行操作の完了を非同期に待つ。
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(100))
    while !secondFinished && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(1))
    }
    await provider.gate.releaseFirstWrite()
    let firstResult = await first.value
    let secondResult = await second.value

    #expect(firstResult.failedCount == 0)
    #expect(secondResult.failedCount == 0)
    #expect(provider.currentTags == ["固有", "赤", "青"])
  }
  @Test("先行操作を待っているタグ変更をキャンセルすると書き込まない")
  func cancelledWaitingMutationDoesNotWrite() async throws {
    let provider = DelayedFinderTagWriteProvider()
    let root = FileLocation(remotePath: "/root", providerID: provider.id)
    let session = FileBrowserSession(
      provider: provider, initialLocation: root, transferQueue: .isolatedForTesting())
    let item = provider.item
    let first = Task { await session.toggleFinderTag(name: "赤", for: [item]) }
    await provider.gate.waitUntilFirstWriteStarted()
    let cancelled = Task {
      await session.updateFinderTags(FinderTagMutation(additions: ["青"], removals: []), for: [item])
    }
    cancelled.cancel()
    await provider.gate.releaseFirstWrite()
    let firstResult = await first.value
    let cancelledResult = await cancelled.value

    #expect(firstResult.failedCount == 0)
    #expect(cancelledResult.failedCount == 1)
    #expect(provider.currentTags == ["固有", "赤"])
  }

}

private actor FirstFinderTagWriteGate {
  private var didPause = false
  private var isStarted = false
  private var startedWaiters: [CheckedContinuation<Void, Never>] = []
  private var release: CheckedContinuation<Void, Never>?

  func waitUntilFirstWriteStarted() async {
    if isStarted { return }
    await withCheckedContinuation { startedWaiters.append($0) }
  }

  func pauseFirstWrite() async {
    guard !didPause else { return }
    didPause = true
    isStarted = true
    for waiter in startedWaiters { waiter.resume() }
    startedWaiters = []
    await withCheckedContinuation { release = $0 }
  }

  func releaseFirstWrite() {
    release?.resume()
    release = nil
  }
}

private final class DelayedFinderTagWriteProvider: FileBrowserItemDetailProvider,
  FileBrowserFinderTagProvider, @unchecked Sendable
{
  let id = FileProviderID(rawValue: "concurrent-finder-tag-test")
  let connectionID: FileProviderConnectionID? = nil
  let capabilities: FileProviderCapabilities = [.read, .write, .finderTags]
  let gate = FirstFinderTagWriteGate()
  private let lock = NSLock()
  private var storedTags = ["固有"]

  var currentTags: [String] { lock.withLock { storedTags } }
  var item: FileItem {
    FileItem(
      remotePath: "/root/file", url: URL(string: "finder-tag-test://host/root/file")!,
      providerID: id, isDirectory: false, size: 1, modifiedAt: nil, tags: nil)
  }

  func contents(of _: FileLocation) async throws -> [FileItem] { [item] }
  func parent(of _: FileLocation) -> FileLocation? { nil }
  func breadcrumbs(for _: FileLocation, constrainedTo _: FileLocation?) -> [FileBrowserBreadcrumb] {
    []
  }

  func detailedItem(at _: FileLocation) async throws -> FileItem {
    item.replacingTags(currentTags)
  }

  func setFinderTagNames(_ names: [String], at _: FileLocation) async throws {
    await gate.pauseFirstWrite()
    lock.withLock { storedTags = names }
  }
}
