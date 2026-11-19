import Foundation
import Testing

@testable import PKPane

@MainActor
struct FileBrowserFinderTagTests {
  @Test("追加と削除を全選択項目へ書き込み一覧キャッシュへ反映する")
  func updatesAllSelectedItemsAndCachedListing() async throws {
    let provider = RecordingFinderTagProvider()
    let root = FileLocation(remotePath: "/root", providerID: provider.id)
    let session = FileBrowserSession(
      provider: provider, initialLocation: root, transferQueue: .isolatedForTesting())
    session.load()
    await waitForLoading(session)
    let items = session.items
    let mutation = FinderTagEditing.mutation(from: ["共通"], to: ["追加"])

    let result = await session.updateFinderTags(mutation, for: items)

    #expect(result.failedCount == 0)
    #expect(
      provider.recordedTagNames == [
        "/root/first.txt": ["個別A", "追加"],
        "/root/second.txt": ["個別B", "追加"],
      ])
    #expect(
      session.items.map { $0.tags ?? [] } == [
        ["個別A", "追加"],
        ["個別B", "追加"],
      ])
    #expect(session.loadedFinderTagNames == ["個別A", "追加", "個別B"])
  }

  @Test("一部の書き込み失敗は成功項目を保ち失敗件数を返す")
  func reportsPartialFailure() async throws {
    let provider = RecordingFinderTagProvider(failingPath: "/root/second.txt")
    let root = FileLocation(remotePath: "/root", providerID: provider.id)
    let session = FileBrowserSession(
      provider: provider, initialLocation: root, transferQueue: .isolatedForTesting())
    session.load()
    await waitForLoading(session)
    let mutation = FinderTagEditing.mutation(from: ["共通"], to: ["共通", "追加"])

    let result = await session.updateFinderTags(mutation, for: session.items)

    #expect(result.failedCount == 1)
    #expect(result.errorMessage?.contains("1件") == true)
    try #require(result.items.count == 2)
    #expect(result.items[0].tags == ["共通", "個別A", "追加"])
    #expect(result.items[1].tags == ["共通", "個別B"])
  }

  @Test("未補完の複数項目へタグを追加してもディスク上の既存タグを保持する")
  func preservesExistingTagsWhenSelectedItemsHaveUnknownTags() async {
    let provider = RecordingFinderTagProvider()
    let root = FileLocation(remotePath: "/root", providerID: provider.id)
    let session = FileBrowserSession(
      provider: provider, initialLocation: root, transferQueue: .isolatedForTesting())
    let selectedItems = [
      provider.itemWithUnknownTags(path: "/root/first.txt"),
      provider.itemWithUnknownTags(path: "/root/second.txt"),
    ]
    let mutation = FinderTagMutation(additions: ["追加"], removals: [])

    let result = await session.updateFinderTags(mutation, for: selectedItems)

    #expect(result.failedCount == 0)
    #expect(
      provider.recordedTagNames == [
        "/root/first.txt": ["共通", "個別A", "追加"],
        "/root/second.txt": ["共通", "個別B", "追加"],
      ])
  }

  @Test("タグだけ欠けた1000件は初期表示分だけを補完しフル詳細を取得しない")
  func enrichesOnlyInitialTagBatchWithoutFullDetails() async throws {
    let provider = TagOnlyMetadataProvider(itemCount: 1_000)
    let root = FileLocation(remotePath: "/root", providerID: provider.id)
    let session = FileBrowserSession(
      provider: provider, initialLocation: root, transferQueue: .isolatedForTesting())

    session.load()
    await waitUntil(timeout: .seconds(10)) {
      session.items.count == 1_000
        && !session.isLoading
        && !session.isMetadataEnrichmentActive
    }

    #expect(session.items.count == 1_000)
    #expect(session.items.prefix(64).allSatisfy { $0.tags == ["既存"] })
    #expect(session.items.dropFirst(64).allSatisfy { $0.tags == nil })
    #expect(provider.finderTagMetadataCallCount == 64)
    #expect(provider.detailedItemCallCount == 0)
    #expect(!session.isMetadataEnrichmentActive)
    #expect(session.metadataEnrichmentRunCount == 1)
    let measurement = try #require(session.lastMetadataEnrichmentMeasurement)
    #expect(
      measurement
        == MetadataEnrichmentMeasurement(
          fullDetailRequestCount: 0,
          finderTagRequestCount: 64,
          successfulDetailCount: 0,
          successfulTagCount: 64,
          appliedItemCount: 64,
          wasCancelled: false))
  }

  @Test("1万件一覧のサイドバータグ名再参照で項目を再走査しない")
  func reusesLoadedFinderTagNamesWithoutRescanningItems() async {
    let provider = TagOnlyMetadataProvider(itemCount: 10_000)
    let root = FileLocation(remotePath: "/root", providerID: provider.id)
    let session = FileBrowserSession(
      provider: provider, initialLocation: root, transferQueue: .isolatedForTesting())

    session.load()
    await waitUntil(timeout: .seconds(10)) {
      session.items.count == 10_000 && !session.isMetadataEnrichmentActive
    }
    let countBeforeRead = session.sidebarFinderTagItemProjectionCount
    let clock = ContinuousClock()

    let firstTagNames = session.loadedFinderTagNames
    let countAfterFirstRead = session.sidebarFinderTagItemProjectionCount
    let secondReadDuration = clock.measure {
      _ = session.loadedFinderTagNames
    }
    let countAfterSecondRead = session.sidebarFinderTagItemProjectionCount

    print(
      "PKPane性能計測: サイドバーFinderタグ1万件再参照 "
        + "\(secondReadDuration)/"
        + "\(countAfterSecondRead - countAfterFirstRead)件走査")
    #expect(firstTagNames == ["既存"])
    #expect(countAfterFirstRead == countBeforeRead)
    #expect(countAfterSecondRead == countAfterFirstRead)
    #expect(secondReadDuration < .milliseconds(16))
  }

  @Test("1万件でも初期範囲外の可視項目だけを1フレーム以内に追加要求する")
  func enrichesOnlyNewlyVisibleItemsAfterInitialBatch() async {
    let provider = TagOnlyMetadataProvider(itemCount: 10_000)
    let root = FileLocation(remotePath: "/root", providerID: provider.id)
    let session = FileBrowserSession(
      provider: provider, initialLocation: root, transferQueue: .isolatedForTesting())

    session.load()
    await waitUntil(timeout: .seconds(10)) {
      session.items.count == 10_000 && !session.isMetadataEnrichmentActive
    }
    let visibleItems = Array(session.items[5_000..<5_020])

    let clock = ContinuousClock()
    let requestDuration = clock.measure {
      session.enrichFinderTags(forVisibleItems: visibleItems)
    }
    print("PKPane性能計測: 可視Finderタグ追加要求 \(requestDuration)")
    #expect(requestDuration < .milliseconds(16))
    await waitUntil(timeout: .seconds(10)) {
      !session.isMetadataEnrichmentActive
        && visibleItems.allSatisfy { visibleItem in
          session.items.first(where: { $0.url == visibleItem.url })?.tags == ["既存"]
        }
    }

    #expect(provider.finderTagMetadataCallCount == 84)
    #expect(session.items[4_999].tags == nil)
    #expect(session.items[5_020].tags == nil)
  }

  @Test("tag検索は初期範囲外も補完して完全な結果を返す")
  func tagSearchEnrichesAllRemainingItems() async {
    let provider = TagOnlyMetadataProvider(itemCount: 10_000, taggedIndices: [9_999])
    let root = FileLocation(remotePath: "/root", providerID: provider.id)
    let session = FileBrowserSession(
      provider: provider,
      initialLocation: root,
      transferQueue: .isolatedForTesting(),
      searchDebounceDuration: .zero)

    session.load()
    await waitUntil(timeout: .seconds(10)) {
      session.items.count == 10_000 && !session.isMetadataEnrichmentActive
    }
    session.setSearchText("tag:仕事")
    await waitUntil(timeout: .seconds(10)) {
      !session.isMetadataEnrichmentActive
        && session.searchResults.map(\.item.name) == ["item-9999.txt"]
    }

    print(
      "PKPane性能計測: tag検索全件補完準備 "
        + "\(session.lastMetadataEnrichmentPreparationDuration)")
    print(
      "PKPane性能計測: tag検索全件反映 "
        + "\(session.lastMetadataEnrichmentApplicationDuration)")
    #expect(session.lastMetadataEnrichmentPreparationDuration < .milliseconds(16))
    #expect(session.lastMetadataEnrichmentApplicationDuration < .milliseconds(16))
    #expect(provider.finderTagMetadataCallCount == 10_000)
    #expect(session.items.allSatisfy { $0.tags != nil })
  }

  @Test("展開ツリーも初期64件と新たに見えた項目だけを補完する")
  func enrichesOnlyVisibleExpandedTreeItems() async throws {
    let provider = TagOnlyMetadataProvider(nestedChildCount: 1_000)
    let root = FileLocation(remotePath: "/root", providerID: provider.id)
    let session = FileBrowserSession(
      provider: provider, initialLocation: root, transferQueue: .isolatedForTesting())

    session.load()
    await waitUntil(timeout: .seconds(10)) {
      session.items.count == 1 && !session.isMetadataEnrichmentActive
    }
    let folder = try #require(session.items.first)
    session.toggleExpansion(of: folder)
    await waitUntil(timeout: .seconds(10)) {
      guard let children = session.treeState.children(of: folder.location) else { return false }
      return children.count == 1_000
        && children.prefix(64).allSatisfy { $0.tags == ["既存"] }
        && provider.finderTagMetadataCallCount == 65
    }
    let visibleItems = try #require(session.treeState.children(of: folder.location)).dropFirst(500)
      .prefix(20)

    session.enrichFinderTags(forVisibleItems: Array(visibleItems))
    await waitUntil(timeout: .seconds(10)) {
      guard let children = session.treeState.children(of: folder.location) else { return false }
      return !session.isMetadataEnrichmentActive
        && children[500..<520].allSatisfy { $0.tags == ["既存"] }
    }

    let children = try #require(session.treeState.children(of: folder.location))
    #expect(provider.finderTagMetadataCallCount == 85)
    #expect(children[499].tags == nil)
    #expect(children[520].tags == nil)
  }

  private func waitForLoading(_ session: FileBrowserSession) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(10))
    while session.isLoading, clock.now < deadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(!session.isLoading, "読み込みが期限内に完了しなかった")
  }

  private func waitUntil(
    timeout: Duration,
    _ condition: @escaping @MainActor () -> Bool
  ) async {
    await PKPaneTests.waitUntil(timeout: timeout, "Finderタグの状態が期限内に条件を満たさなかった") {
      condition()
    }
  }
}

private final class RecordingFinderTagProvider: FileBrowserItemDetailProvider,
  FileBrowserFinderTagProvider, @unchecked Sendable
{
  let id = FileProviderID(rawValue: "finder-tags-test")
  let connectionID: FileProviderConnectionID? = nil
  let capabilities: FileProviderCapabilities = [.read, .write, .finderTags]

  private let lock = NSLock()
  private let failingPath: String?
  private var tagsByPath: [String: [String]] = [
    "/root/first.txt": ["共通", "個別A"],
    "/root/second.txt": ["共通", "個別B"],
  ]
  private var recorded: [String: [String]] = [:]

  init(failingPath: String? = nil) {
    self.failingPath = failingPath
  }

  var recordedTagNames: [String: [String]] { lock.withLock { recorded } }

  func contents(of _: FileLocation) async throws -> [FileItem] {
    lock.withLock {
      tagsByPath.keys.sorted().map(makeItem(path:))
    }
  }

  func parent(of _: FileLocation) -> FileLocation? { nil }

  func breadcrumbs(
    for _: FileLocation,
    constrainedTo _: FileLocation?
  ) -> [FileBrowserBreadcrumb] { [] }

  func detailedItem(at location: FileLocation) async throws -> FileItem {
    guard let path = location.remotePath else { throw FinderTagTestError.writeDenied }
    return lock.withLock { makeItem(path: path) }
  }

  func setFinderTagNames(_ tagNames: [String], at location: FileLocation) async throws {
    guard let path = location.remotePath, path != failingPath else {
      throw FinderTagTestError.writeDenied
    }
    lock.withLock {
      tagsByPath[path] = tagNames
      recorded[path] = tagNames
    }
  }

  func itemWithUnknownTags(path: String) -> FileItem {
    FileItem(
      remotePath: path,
      url: URL(string: "finder-tags-test://host\(path)")!,
      providerID: id,
      isDirectory: false,
      size: 1,
      modifiedAt: Date(timeIntervalSince1970: 1),
      tags: nil)
  }

  private func makeItem(path: String) -> FileItem {
    FileItem(
      remotePath: path,
      url: URL(string: "finder-tags-test://host\(path)")!,
      providerID: id,
      isDirectory: false,
      size: 1,
      modifiedAt: Date(timeIntervalSince1970: 1),
      tags: tagsByPath[path] ?? [])
  }
}

private enum FinderTagTestError: LocalizedError {
  case writeDenied

  var errorDescription: String? { "タグを書き込めません。" }
}

private final class TagOnlyMetadataProvider: FileBrowserItemDetailProvider,
  FileBrowserFinderTagMetadataProvider, @unchecked Sendable
{
  let id = FileProviderID(rawValue: "finder-tag-metadata-test")
  let connectionID: FileProviderConnectionID? = nil
  let capabilities: FileProviderCapabilities = [.read, .finderTags]

  private let itemCount: Int
  private let nestedChildCount: Int?
  private let taggedIndices: Set<Int>?
  private let lock = NSLock()
  private var fullDetailCalls = 0
  private var tagMetadataCalls = 0

  init(itemCount: Int, taggedIndices: Set<Int>? = nil) {
    self.itemCount = itemCount
    self.nestedChildCount = nil
    self.taggedIndices = taggedIndices
  }

  init(nestedChildCount: Int) {
    self.itemCount = 0
    self.nestedChildCount = nestedChildCount
    self.taggedIndices = nil
  }

  var detailedItemCallCount: Int { lock.withLock { fullDetailCalls } }
  var finderTagMetadataCallCount: Int { lock.withLock { tagMetadataCalls } }

  func contents(of location: FileLocation) async throws -> [FileItem] {
    if let nestedChildCount {
      if location.remotePath == "/root" {
        return [
          FileItem(
            remotePath: "/root/folder",
            url: URL(string: "finder-tag-metadata-test://host/root/folder")!,
            providerID: id,
            isDirectory: true,
            size: nil,
            modifiedAt: Date(timeIntervalSince1970: 1),
            tags: nil)
        ]
      }
      return makeItems(count: nestedChildCount, parentPath: "/root/folder")
    }
    return makeItems(count: itemCount, parentPath: "/root")
  }

  private func makeItems(count: Int, parentPath: String) -> [FileItem] {
    (0..<count).map { index in
      let path = "\(parentPath)/item-\(index).txt"
      return FileItem(
        remotePath: path,
        url: URL(string: "finder-tag-metadata-test://host\(path)")!,
        providerID: id,
        isDirectory: false,
        size: 1,
        modifiedAt: Date(timeIntervalSince1970: 1),
        tags: nil)
    }
  }

  func parent(of _: FileLocation) -> FileLocation? { nil }

  func breadcrumbs(
    for _: FileLocation,
    constrainedTo _: FileLocation?
  ) -> [FileBrowserBreadcrumb] { [] }

  func detailedItem(at location: FileLocation) async throws -> FileItem {
    lock.withLock { fullDetailCalls += 1 }
    guard let path = location.remotePath else { throw CocoaError(.fileNoSuchFile) }
    return FileItem(
      remotePath: path,
      url: URL(string: "finder-tag-metadata-test://host\(path)")!,
      providerID: id,
      isDirectory: false,
      size: 1,
      modifiedAt: Date(timeIntervalSince1970: 1),
      tags: ["既存"])
  }

  func finderTagNames(at location: FileLocation) async throws -> [String] {
    lock.withLock { tagMetadataCalls += 1 }
    guard let taggedIndices else { return ["既存"] }
    let index = location.remotePath.flatMap { path in
      path.split(separator: "-").last?
        .split(separator: ".").first.flatMap { Int($0) }
    }
    return index.map(taggedIndices.contains) == true ? ["仕事"] : []
  }
}
