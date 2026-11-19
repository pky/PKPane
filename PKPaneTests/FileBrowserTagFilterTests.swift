import Foundation
import Testing

@testable import PKPane

struct FileBrowserTagFilterTests {
  @Test("タグの部分一致と大文字小文字無視で一覧を絞り込む")
  func filtersByPartialCaseInsensitiveTagName() {
    let items = [
      makeItem(name: "first.txt", tags: ["重要書類"]),
      makeItem(name: "second.txt", tags: ["Review"]),
      makeItem(name: "third.txt", tags: ["赤\n6"]),
    ]

    #expect(filteredNames(items, matching: "tag:重要") == ["first.txt"])
    #expect(filteredNames(items, matching: "tag:review") == ["second.txt"])
    #expect(filteredNames(items, matching: "tag:赤") == ["third.txt"])
  }

  @Test("タグ不一致と未補完タグは一覧に含めない")
  func excludesMismatchedAndUnknownTags() {
    let items = [
      makeItem(name: "matched.txt", tags: ["仕事"]),
      makeItem(name: "mismatched.txt", tags: ["個人"]),
      makeItem(name: "unknown.txt", tags: nil),
    ]

    #expect(filteredNames(items, matching: "tag:仕事") == ["matched.txt"])
  }

  @Test("複数タグ条件と名前条件をANDで絞り込む")
  func combinesTagAndNameConditions() {
    let items = [
      makeItem(name: "月次報告書.txt", tags: ["仕事", "確認済み"]),
      makeItem(name: "月次メモ.txt", tags: ["仕事", "確認済み"]),
      makeItem(name: "週次報告書.txt", tags: ["仕事"]),
    ]

    #expect(
      filteredNames(items, matching: "tag:仕事 tag:確認 報告書")
        == ["月次報告書.txt"])
  }

  @Test("tag:なしの入力は従来どおり名前だけで絞り込む")
  func preservesNameOnlyFiltering() {
    let items = [
      makeItem(name: "REPORT.txt", tags: nil),
      makeItem(name: "notes.txt", tags: ["report"]),
    ]

    #expect(filteredNames(items, matching: "report") == ["REPORT.txt"])
  }

  @Test("正規表現モードは名前部分だけをタグ条件とANDで照合する")
  func filtersNameAsRegexWhileKeepingTagTermsLiteral() {
    let items = [
      makeItem(name: "月次報告書.txt", tags: ["仕事"]),
      makeItem(name: "週次報告書.txt", tags: ["仕事"]),
      makeItem(name: "月次報告書.md", tags: ["仕事"]),
      makeItem(name: "月次報告書.txt", tags: ["個人"]),
    ]

    #expect(
      filteredNames(items, matching: "tag:仕事 ^月次.*\\.txt$", matchMode: .regex)
        == ["月次報告書.txt"])
  }

  @MainActor
  @Test("setSearchTextの実経路で3表示モードへ同じタグ結果を出す")
  func filtersAllViewModesThroughSearchPipeline() async {
    let provider = ImmediateTagFilterProvider()
    let searchRecorder = SearchInvocationRecorder()
    let session = makeSession(provider: provider, searchRecorder: searchRecorder)
    session.load()
    await waitUntil { !session.isLoading && session.items.count == 3 }

    session.setSearchText("tag:仕事 報告書")
    await waitUntil { !session.isSearching }

    for configuredMode in FileBrowserViewMode.selectableCases {
      let effectiveMode = FileBrowserSearchPresentation.viewMode(
        configuredMode: configuredMode,
        isSearchActive: session.isSearchActive)
      let names: [String]
      switch effectiveMode {
      case .list:
        names = session.flattenedRows(
          matching: "",
          sortOrder: .name,
          ascending: true,
          includesHiddenItems: true
        ).map(\.item.name)
      case .icon:
        names = session.displayItems(
          matching: "",
          sortOrder: .name,
          ascending: true,
          includesHiddenItems: true
        ).map(\.name)
      case .column:
        names = []
        Issue.record("検索中のカラム表示はリストへ切り替わる必要があります")
      }
      #expect(names == ["月次報告書.txt"])
    }
    #expect(searchRecorder.searchCallCount == 0)
    #expect(session.searchScopeNotice == "tag: はこのフォルダ直下のみを対象に絞り込みます")
  }

  @MainActor
  @Test("正規表現モードをtag:併用の直下一覧フィルタへ伝播する")
  func appliesRegexToNamePartThroughTagSearchPipeline() async {
    let provider = ImmediateTagFilterProvider()
    let searchRecorder = SearchInvocationRecorder()
    let session = makeSession(provider: provider, searchRecorder: searchRecorder)
    session.load()
    await waitUntil { !session.isLoading && session.items.count == 3 }

    session.setSearchUsesRegex(true)
    session.setSearchText("tag:仕事 ^月次.*\\.txt$")
    await waitUntil { !session.isSearching }

    #expect(session.searchResults.map(\.item.name) == ["月次報告書.txt"])
    #expect(searchRecorder.searchCallCount == 0)
    #expect(session.searchScopeNotice == "tag: はこのフォルダ直下のみを対象に絞り込みます")
  }

  @MainActor
  @Test("タグ補完後は同じフィルタ条件の一覧へ項目が現れる")
  func followsTagMetadataEnrichment() async {
    let provider = DeferredTagMetadataProvider()
    let searchRecorder = SearchInvocationRecorder()
    let root = FileLocation(remotePath: "/root", providerID: provider.id)
    let session = FileBrowserSession(
      provider: provider,
      initialLocation: root,
      transferQueue: .isolatedForTesting(),
      searchDebounceDuration: .zero,
      providerSearchServiceFactory: { _ in searchRecorder })

    session.load()
    await waitUntil { session.items.count == 1 && session.items[0].tags == nil }
    session.setSearchText("tag:仕事")
    await waitUntil { !session.isSearching }
    #expect(session.searchResults.isEmpty)

    await provider.releaseTagMetadata()
    await waitUntil {
      session.items.first?.tags == ["仕事"]
        && session.searchResults.map(\.item.name) == ["report.txt"]
    }

    #expect(
      session.displayItems(
        matching: "",
        sortOrder: .name,
        ascending: true,
        includesHiddenItems: true
      ).map(\.name) == ["report.txt"])
    #expect(searchRecorder.searchCallCount == 0)
  }

  @MainActor
  @Test("連続したtag:入力では最新generationの結果だけを表示する")
  func keepsOnlyLatestTagFilterGeneration() async {
    let provider = ImmediateTagFilterProvider()
    let searchRecorder = SearchInvocationRecorder()
    let session = makeSession(provider: provider, searchRecorder: searchRecorder)
    session.load()
    await waitUntil { !session.isLoading && session.items.count == 3 }

    session.setSearchText("tag:仕事")
    session.setSearchText("tag:個人 メモ")
    await waitUntil { !session.isSearching }

    #expect(session.searchText == "tag:個人 メモ")
    #expect(session.searchResults.map(\.item.name) == ["個人メモ.txt"])
    #expect(searchRecorder.searchCallCount == 0)
  }

  @MainActor
  @Test("setSearchTextの実経路で現在フォルダの内容条件を除外して残余を絞り込む")
  func excludesContentTermThroughCurrentFolderSearchPipeline() async {
    let provider = ImmediateTagFilterProvider()
    let searchRecorder = SearchInvocationRecorder()
    let session = makeSession(provider: provider, searchRecorder: searchRecorder)
    session.load()
    await waitUntil { !session.isLoading && session.items.count == 3 }

    session.setSearchText("content:予算 tag:仕事 報告書")
    await waitUntil { !session.isSearching }

    #expect(session.searchResults.map(\.item.name) == ["月次報告書.txt"])
    #expect(session.searchScopeNotice == "この検索範囲では内容を検索できません")
    #expect(searchRecorder.searchCallCount == 0)

    session.setSearchText("content:日本語")
    await waitUntil { !session.isSearching }

    #expect(Set(session.searchResults.map(\.item.name)) == Set(session.items.map(\.name)))
    #expect(session.searchScopeNotice == "この検索範囲では内容を検索できません")
    #expect(searchRecorder.searchCallCount == 0)
  }

  @MainActor
  @Test("連続したcontent:入力でも最新generationの残余条件だけを表示する")
  func keepsOnlyLatestContentFilterGeneration() async {
    let provider = ImmediateTagFilterProvider()
    let searchRecorder = SearchInvocationRecorder()
    let session = makeSession(provider: provider, searchRecorder: searchRecorder)
    session.load()
    await waitUntil { !session.isLoading && session.items.count == 3 }

    session.setSearchText("content:旧 月次")
    session.setSearchText("content:新 tag:個人 メモ")
    await waitUntil { !session.isSearching }

    #expect(session.searchText == "content:新 tag:個人 メモ")
    #expect(session.searchResults.map(\.item.name) == ["個人メモ.txt"])
    #expect(searchRecorder.searchCallCount == 0)
  }

  private func filteredNames(
    _ items: [FileItem],
    matching query: String,
    matchMode: NameMatchMode = .literal
  ) -> [String] {
    FileItemFilter.filteredAndSorted(
      items, matching: query, matchMode: matchMode,
      sortOrder: .name, ascending: true
    ).map(\.name)
  }

  private func makeItem(name: String, tags: [String]?) -> FileItem {
    FileItem(
      url: URL(filePath: "/tmp/\(name)"),
      isDirectory: false,
      size: 1,
      modifiedAt: Date(timeIntervalSince1970: 1),
      tags: tags)
  }

  @MainActor
  private func makeSession(
    provider: ImmediateTagFilterProvider,
    searchRecorder: SearchInvocationRecorder
  ) -> FileBrowserSession {
    FileBrowserSession(
      provider: provider,
      initialLocation: provider.root,
      transferQueue: .isolatedForTesting(),
      searchDebounceDuration: .zero,
      providerSearchServiceFactory: { _ in searchRecorder })
  }

  @MainActor
  private func waitUntil(_ condition: () -> Bool) async {
    await PKPaneTests.waitUntil("タグフィルタの状態が期限内に条件を満たさなかった") {
      condition()
    }
  }
}

private final class ImmediateTagFilterProvider: FileBrowserProvider, @unchecked Sendable {
  let id = FileProviderID(rawValue: "immediate-tag-filter")
  let connectionID: FileProviderConnectionID? = nil
  let capabilities: FileProviderCapabilities = [.read, .finderTags]
  var root: FileLocation { FileLocation(remotePath: "/root", providerID: id) }

  func contents(of _: FileLocation) async throws -> [FileItem] {
    [
      makeItem(path: "/root/月次報告書.txt", tags: ["仕事"]),
      makeItem(path: "/root/週次報告書.txt", tags: ["個人"]),
      makeItem(path: "/root/個人メモ.txt", tags: ["個人"]),
    ]
  }

  func parent(of _: FileLocation) -> FileLocation? { nil }

  func breadcrumbs(
    for _: FileLocation,
    constrainedTo _: FileLocation?
  ) -> [FileBrowserBreadcrumb] { [] }

  private func makeItem(path: String, tags: [String]) -> FileItem {
    FileItem(
      remotePath: path,
      url: URL(string: "immediate-tag-filter://host\(path)")!,
      providerID: id,
      isDirectory: false,
      size: 1,
      modifiedAt: Date(timeIntervalSince1970: 1),
      tags: tags)
  }
}

private final class SearchInvocationRecorder: SearchService, @unchecked Sendable {
  private let lock = NSLock()
  private var callCount = 0

  var searchCallCount: Int { lock.withLock { callCount } }

  func search(_ query: SearchQuery) -> AsyncStream<SearchUpdate> {
    lock.withLock { callCount += 1 }
    return AsyncStream { continuation in
      continuation.yield(.finished(query.generation))
      continuation.finish()
    }
  }
}

private final class DeferredTagMetadataProvider: FileBrowserFinderTagMetadataProvider,
  @unchecked Sendable
{
  let id = FileProviderID(rawValue: "deferred-tag-metadata")
  let connectionID: FileProviderConnectionID? = nil
  let capabilities: FileProviderCapabilities = [.read, .finderTags]

  private let gate = TagMetadataGate()

  func contents(of _: FileLocation) async throws -> [FileItem] {
    [
      FileItem(
        remotePath: "/root/report.txt",
        url: URL(string: "deferred-tag-metadata://host/root/report.txt")!,
        providerID: id,
        isDirectory: false,
        size: 1,
        modifiedAt: Date(timeIntervalSince1970: 1),
        tags: nil)
    ]
  }

  func parent(of _: FileLocation) -> FileLocation? { nil }

  func breadcrumbs(
    for _: FileLocation,
    constrainedTo _: FileLocation?
  ) -> [FileBrowserBreadcrumb] { [] }

  func finderTagNames(at _: FileLocation) async throws -> [String] {
    await gate.wait()
    return ["仕事"]
  }

  func releaseTagMetadata() async {
    await gate.open()
  }
}

private actor TagMetadataGate {
  private var isOpen = false

  func wait() async {
    await waitUntil(timeout: .seconds(5), "タグメタデータゲートが期限内に開かなかった") {
      isOpen
    }
  }

  func open() {
    isOpen = true
  }
}
