import Foundation
import Testing

@testable import PKPane

@MainActor
struct FileBrowserDirectoryCacheTests {
  @Test("上限を1件超えると最古のディレクトリを追い出す")
  func evictsOldestDirectoryAboveLimit() async {
    let provider = DirectoryCacheTestProvider()
    let locations = ["/first", "/second", "/third"].map {
      FileLocation(remotePath: $0, providerID: provider.id)
    }
    let session = FileBrowserSession(
      provider: provider,
      initialLocation: locations[0],
      transferQueue: .isolatedForTesting(),
      directoryCacheLimit: 2)

    session.load()
    await waitForLoading(session)
    for location in locations.dropFirst() {
      session.open(location: location)
      await waitForLoading(session)
    }

    #expect(session.directorySnapshotCacheCount == 2)
    #expect(!session.hasCachedDirectorySnapshot(at: locations[0]))
    #expect(session.hasCachedDirectorySnapshot(at: locations[1]))
    #expect(session.hasCachedDirectorySnapshot(at: locations[2]))
    #expect(session.hasCachedDirectorySnapshot(at: session.currentLocation))
    session.invalidate()
  }

  @Test("表示中カラムは全件ピン留めなら上限超過して保持する")
  func keepsDisplayedColumnsPinned() async throws {
    let provider = DirectoryCacheTestProvider(includesChildDirectory: true)
    let root = FileLocation(remotePath: ".", providerID: provider.id)
    let child = FileLocation(remotePath: "./child", providerID: provider.id)
    let session = FileBrowserSession(
      provider: provider,
      initialLocation: root,
      transferQueue: .isolatedForTesting(),
      directoryCacheLimit: 1)
    session.load()
    await waitForLoading(session)
    session.beginColumnBrowsing()
    let childItem = try #require(session.items.first(where: { $0.isDirectory }))

    session.selectColumnItem(childItem, inColumnAt: root)
    await waitForColumnLoading(session, at: child)

    #expect(session.directorySnapshotCacheCount == 2)
    #expect(session.hasCachedDirectorySnapshot(at: root))
    #expect(session.hasCachedDirectorySnapshot(at: child))
    session.invalidate()
  }

  @Test("展開中ツリーは現在地でも表示中カラムでもなくても上限超過して保持する")
  func keepsExpandedTreeDirectoryPinned() async throws {
    let provider = DirectoryCacheTestProvider(includesChildDirectory: true)
    let root = FileLocation(remotePath: ".", providerID: provider.id)
    let firstChild = FileLocation(remotePath: "./child", providerID: provider.id)
    let secondChild = FileLocation(remotePath: "./second-child", providerID: provider.id)
    let session = FileBrowserSession(
      provider: provider,
      initialLocation: root,
      transferQueue: .isolatedForTesting(),
      directoryCacheLimit: 2)
    session.load()
    await waitForLoading(session)
    let firstChildItem = try #require(
      session.items.first(where: { $0.location == firstChild }))
    let secondChildItem = try #require(
      session.items.first(where: { $0.location == secondChild }))

    session.beginColumnBrowsing()
    session.selectColumnItem(firstChildItem, inColumnAt: root)
    await waitForColumnLoading(session, at: firstChild)
    session.endColumnBrowsing()
    session.open(location: root)
    await waitForLoading(session)
    session.toggleExpansion(of: firstChildItem)
    await waitForTreeLoading(session, at: firstChild)

    session.beginColumnBrowsing()
    session.selectColumnItem(secondChildItem, inColumnAt: root)
    await waitForColumnLoading(session, at: secondChild)

    #expect(session.currentLocation == secondChild)
    #expect(session.treeState.isExpanded(firstChild))
    #expect(!session.columnState.columns.contains(where: { $0.location == firstChild }))
    #expect(session.directorySnapshotCacheCount == 3)
    #expect(session.hasCachedDirectorySnapshot(at: firstChild))
    session.invalidate()
  }

  @Test("上限内の戻る操作はキャッシュ内容を同期的に復元する")
  func restoresCachedItemsImmediatelyWhenGoingBack() async {
    let provider = DirectoryCacheTestProvider()
    let first = FileLocation(remotePath: "/first", providerID: provider.id)
    let second = FileLocation(remotePath: "/second", providerID: provider.id)
    let session = FileBrowserSession(
      provider: provider,
      initialLocation: first,
      transferQueue: .isolatedForTesting(),
      directoryCacheLimit: 2)
    session.load()
    await waitForLoading(session)
    let firstItems = session.items
    session.open(location: second)
    await waitForLoading(session)

    session.goBack()

    #expect(session.currentLocation == first)
    #expect(session.items == firstItems)
    #expect(session.isRefreshing)
    await waitForLoading(session)
    session.invalidate()
  }

  @Test("キャッシュ読み取りで触れたディレクトリの追い出し順を更新する")
  func touchChangesDirectoryEvictionOrder() async {
    let provider = DirectoryCacheTestProvider()
    let locations = ["/first", "/second", "/third"].map {
      FileLocation(remotePath: $0, providerID: provider.id)
    }
    let session = FileBrowserSession(
      provider: provider,
      initialLocation: locations[0],
      transferQueue: .isolatedForTesting(),
      directoryCacheLimit: 2)

    session.load()
    await waitForLoading(session)
    session.open(location: locations[1])
    await waitForLoading(session)
    session.open(location: locations[0])
    await waitForLoading(session)
    session.open(location: locations[2])
    await waitForLoading(session)

    #expect(session.hasCachedDirectorySnapshot(at: locations[0]))
    #expect(!session.hasCachedDirectorySnapshot(at: locations[1]))
    #expect(session.hasCachedDirectorySnapshot(at: locations[2]))
    session.invalidate()
  }

  @Test("項目置換の判定走査はディレクトリの追い出し順を変えない")
  func replacingCachedItemPreservesDirectoryEvictionOrder() async {
    let cachedPaths = ["/first", "/second", "/third"]
    let fourthPath = "/fourth"

    for oldestPath in cachedPaths {
      let provider = DirectoryCacheReplacementTestProvider()
      let locations = Dictionary(
        uniqueKeysWithValues: (cachedPaths + [fourthPath]).map {
          ($0, FileLocation(remotePath: $0, providerID: provider.id))
        })
      let session = FileBrowserSession(
        provider: provider,
        initialLocation: locations[cachedPaths[0]]!,
        transferQueue: .isolatedForTesting(),
        directoryCacheLimit: 3)
      session.load()
      await waitForLoading(session)
      for path in cachedPaths.dropFirst() {
        session.open(location: locations[path]!)
        await waitForLoading(session)
      }

      let newerPaths = cachedPaths.filter { $0 != oldestPath }
      for path in [oldestPath] + newerPaths {
        session.open(location: locations[path]!)
        await waitForLoading(session)
      }
      let unrelatedItem = provider.item(at: "/outside/item.txt")
      let result = await session.updateFinderTags(
        FinderTagMutation(additions: ["更新"], removals: []),
        for: [unrelatedItem])

      #expect(result.failedCount == 0)
      session.open(location: locations[fourthPath]!)
      await waitForLoading(session)

      #expect(!session.hasCachedDirectorySnapshot(at: locations[oldestPath]!))
      #expect(session.hasCachedDirectorySnapshot(at: locations[fourthPath]!))
      session.invalidate()
    }
  }

  private func waitForLoading(_ session: FileBrowserSession) async {
    await waitUntil("セッションの読み込みが期限内に完了しなかった") {
      !(session.isLoading || session.isRefreshing)
    }
  }

  private func waitForColumnLoading(
    _ session: FileBrowserSession,
    at location: FileLocation
  ) async {
    await waitUntil("カラムの読み込みが期限内に完了しなかった") {
      session.columnState.columns.first(where: { $0.location == location })?.isLoading == false
    }
  }

  private func waitForTreeLoading(
    _ session: FileBrowserSession,
    at location: FileLocation
  ) async {
    await waitUntil("ツリーの子読み込みが期限内に完了しなかった") {
      !session.treeState.isLoadingChildren(of: location)
    }
  }
}

private struct DirectoryCacheTestProvider: FileBrowserProvider {
  let id = FileProviderID(rawValue: "directory-cache-test")
  let connectionID: FileProviderConnectionID? = nil
  let capabilities: FileProviderCapabilities = [.read]
  let includesChildDirectory: Bool

  init(includesChildDirectory: Bool = false) {
    self.includesChildDirectory = includesChildDirectory
  }

  func contents(of location: FileLocation) async throws -> [FileItem] {
    if includesChildDirectory, location.remotePath == "." {
      return [
        FileItem(
          remotePath: "./child",
          url: URL(filePath: "/child", directoryHint: .isDirectory),
          providerID: id,
          isDirectory: true),
        FileItem(
          remotePath: "./second-child",
          url: URL(filePath: "/second-child", directoryHint: .isDirectory),
          providerID: id,
          isDirectory: true),
      ]
    }
    let path = location.remotePath ?? "/unknown"
    let itemName = path.replacingOccurrences(of: "/", with: "-") + "-item.txt"
    return [
      FileItem(
        remotePath: "\(path)/\(itemName)",
        url: URL(filePath: "/\(itemName)"),
        providerID: id,
        isDirectory: false)
    ]
  }

  func parent(of location: FileLocation) -> FileLocation? {
    location.deletingLastPathComponent()
  }

  func breadcrumbs(
    for _: FileLocation,
    constrainedTo _: FileLocation?
  ) -> [FileBrowserBreadcrumb] { [] }
}

private final class DirectoryCacheReplacementTestProvider: FileBrowserItemDetailProvider,
  FileBrowserFinderTagProvider, @unchecked Sendable
{
  let id = FileProviderID(rawValue: "directory-cache-replacement-test")
  let connectionID: FileProviderConnectionID? = nil
  let capabilities: FileProviderCapabilities = [.read, .write, .finderTags]

  private let lock = NSLock()
  private var tagsByPath: [String: [String]] = [:]

  func contents(of location: FileLocation) async throws -> [FileItem] {
    let directoryPath = location.remotePath ?? "/unknown"
    return [item(at: "\(directoryPath)/item.txt")]
  }

  func parent(of location: FileLocation) -> FileLocation? {
    location.deletingLastPathComponent()
  }

  func breadcrumbs(
    for _: FileLocation,
    constrainedTo _: FileLocation?
  ) -> [FileBrowserBreadcrumb] { [] }

  func detailedItem(at location: FileLocation) async throws -> FileItem {
    item(at: location.remotePath ?? "/unknown")
  }

  func setFinderTagNames(_ tagNames: [String], at location: FileLocation) async throws {
    guard let path = location.remotePath else { return }
    lock.withLock {
      tagsByPath[path] = tagNames
    }
  }

  func item(at path: String) -> FileItem {
    let tags = lock.withLock { tagsByPath[path] ?? [] }
    return FileItem(
      remotePath: path,
      url: URL(string: "directory-cache-replacement-test://host\(path)")!,
      providerID: id,
      isDirectory: false,
      size: 1,
      modifiedAt: Date(timeIntervalSince1970: 1),
      tags: tags)
  }
}
