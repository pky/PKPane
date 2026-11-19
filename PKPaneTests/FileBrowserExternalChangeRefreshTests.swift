import Foundation
import Testing

@testable import PKPane

@MainActor
struct FileBrowserExternalChangeRefreshTests {
  @Test("T1 右端を開いたまま祖先カラムへの外部追加が反映される")
  func refreshesVisibleAncestorColumn() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    try await fixture.openDeepestColumn()
    try await Task.sleep(for: .milliseconds(300))

    let startedAt = ContinuousClock.now
    try fixture.create("external.txt", in: fixture.second)
    await expectWithinTwoSeconds(since: startedAt, "祖先カラムに追加が反映されませんでした") {
      fixture.columnNames(at: fixture.second)?.contains("external.txt") == true
    }
    #expect(fixture.session.currentLocation == fixture.deepest)
    #expect(!fixture.session.items.contains { $0.name == "external.txt" })
  }

  @Test("T2 閉じたカラムへの外部追加は開き直したときに表示される")
  func closesAncestorWatcherAndRefreshesOnReopen() async throws {
    let provider = ListingProvider()
    let fixture = try Fixture(provider: provider)
    defer { fixture.close() }
    try await fixture.openDeepestColumn()
    try await Task.sleep(for: .milliseconds(300))
    try fixture.select("sibling", in: fixture.root)
    try await fixture.waitForColumn(fixture.sibling)

    let session = fixture.session
    try #require(session.columnState.columns.map(\.location) == [fixture.root, fixture.sibling])
    let retainedColumns = fixture.columnNamesByLocation
    let closedReads = await provider.readCount(at: fixture.second)
    try fixture.create("external.txt", in: fixture.second)
    let observeUntil = ContinuousClock.now.advanced(by: .seconds(2))
    var currentReads = closedReads
    await waitUntil("閉じたカラムの監視解除を確認できませんでした") {
      currentReads = await provider.readCount(at: fixture.second)
      return currentReads != closedReads || fixture.columnNamesByLocation != retainedColumns
        || session.errorMessage != nil || ContinuousClock.now >= observeUntil
    }
    #expect(currentReads == closedReads)
    #expect(fixture.columnNamesByLocation == retainedColumns)
    #expect(session.currentLocation == fixture.sibling)
    #expect(session.errorMessage == nil)

    try fixture.select("one", in: fixture.root)
    try await fixture.waitForColumn(fixture.first)
    try fixture.select("two", in: fixture.first)
    try await fixture.waitForColumn(fixture.second)
    await waitUntil("開き直したカラムに追加が反映されませんでした") {
      fixture.columnNames(at: fixture.second)?.contains("external.txt") == true
    }
  }

  @Test("T3 監視の再列挙にタグ編集が割り込んでも追加とタグが反映される")
  func watcherRevalidationOverlappingTagEdit() async throws {
    let provider = GatedLocalProvider()
    let fixture = try Fixture(provider: provider)
    defer { fixture.close() }
    try await fixture.openDeepestColumn()
    try await Task.sleep(for: .milliseconds(300))
    try fixture.create("control.txt", in: fixture.deepest)
    let watcherReady = await waitUntil("右端の監視で確認用ファイルが反映されませんでした") {
      fixture.columnNames(at: fixture.deepest)?.contains("control.txt") == true
        && !fixture.session.isRevalidatingInBackground
    }
    try #require(watcherReady)

    let session = fixture.session
    let seed = try #require(session.items.first { $0.name == "seed.txt" })
    await provider.pauseNextRead(at: fixture.deepest)
    defer { Task { await provider.releaseRead() } }
    try fixture.create("external.txt", in: fixture.deepest)
    let observed = await waitUntil("外部作成が監視経由の再列挙に届きませんでした") {
      await provider.pausedNames?.contains("external.txt") == true
        && session.isRevalidatingInBackground
    }
    try #require(observed)
    let replacementsBeforeEdit = session.itemsReplacementCount
    let tag = "回帰テスト用"
    let edit = await session.toggleFinderTag(name: tag, for: [seed])
    try #require(edit.failedCount == 0)
    try #require(session.itemsReplacementCount > replacementsBeforeEdit)
    try #require(session.items.first { $0.location == seed.location }?.tags == [tag])
    try #require(session.currentLocation == fixture.deepest)
    try #require(!session.items.contains { $0.name == "external.txt" })

    let startedAt = ContinuousClock.now
    await provider.releaseRead()
    await expectWithinTwoSeconds(since: startedAt, "再列挙の再開後に追加が反映されませんでした") {
      session.items.contains { $0.name == "external.txt" }
        && fixture.columnNames(at: fixture.deepest)?.contains("external.txt") == true
    }
    #expect(session.currentLocation == fixture.deepest)
    #expect(session.items.first { $0.location == seed.location }?.tags == [tag])
    #expect(
      session.columnState.columns.last?.items.first { $0.location == seed.location }?.tags == [tag])
  }

  @Test("T4 前景復帰相当の再検証で表示中の場所が更新される", arguments: FileBrowserViewMode.selectableCases)
  func revalidatesDisplayedLocations(mode: FileBrowserViewMode) async throws {
    let provider = ListingProvider()
    let fixture = try Fixture(provider: provider)
    defer { fixture.close() }
    let session = fixture.session
    let displayedLocations: [FileLocation]
    switch mode {
    case .column:
      try await fixture.openDeepestColumn()
      displayedLocations = [fixture.root, fixture.first, fixture.second, fixture.deepest]
      try #require(session.columnState.columns.map(\.location) == displayedLocations)
    case .list:
      try await fixture.loadRoot()
      try await fixture.expandFirstFolder()
      displayedLocations = [fixture.root, fixture.first]
    case .icon:
      try await fixture.loadRoot()
      displayedLocations = [fixture.root]
    }
    try await Task.sleep(for: .milliseconds(300))

    let addedName = "memory-only.txt"
    for location in displayedLocations {
      await provider.addFile(named: addedName, in: location)
    }
    let startedAt = ContinuousClock.now
    session.revalidateDisplayedLocations()
    await expectWithinTwoSeconds(since: startedAt, "表示中の場所に追加項目が反映されませんでした") {
      switch mode {
      case .column:
        displayedLocations.allSatisfy { fixture.columnNames(at: $0)?.contains(addedName) == true }
      case .list:
        Set(fixture.listRows().filter { $0.item.name == addedName }.map(\.depth)) == [0, 1]
      case .icon:
        session.displayItems(
          matching: "", sortOrder: .name, ascending: true, includesHiddenItems: false
        )
        .contains { $0.name == addedName }
      }
    }
  }

  @Test("T5 リモートは列挙せずワークスペースの両タブを再列挙する")
  func skipsRemoteAndRevalidatesBothWorkspaceTabs() async throws {
    let remoteProvider = ListingProvider(
      id: FileProviderID(rawValue: "external-refresh-test-remote"))
    let remoteLocation = FileLocation(remotePath: "/", providerID: remoteProvider.id)
    let remote = FileBrowserSession(
      provider: remoteProvider, initialLocation: remoteLocation,
      transferQueue: .isolatedForTesting())
    defer { remote.invalidate() }
    remote.load()
    let remoteLoaded = await waitUntil("リモートの初回列挙が完了しませんでした") {
      let initialReads = await remoteProvider.totalReadCount
      return initialReads > 0 && !remote.isLoading
    }
    try #require(remoteLoaded)
    try #require(remote.currentLocation.localURL == nil)
    let remoteReads = await remoteProvider.totalReadCount

    let provider = ListingProvider()
    let fixture = try Fixture(provider: provider)
    defer { fixture.close() }
    let workspace = FileWorkspaceModel(
      initialBrowser: fixture.session, fileClipboard: MemoryFileClipboard())
    let primary = try #require(workspace.tab(for: .primary)?.browser)
    let secondary = try #require(workspace.tab(for: .secondary)?.browser)
    defer { secondary.invalidate() }
    try #require(workspace.tabs.count == 2)
    try #require(primary !== secondary)
    try await fixture.loadRoot()
    secondary.load(location: fixture.first)
    let secondaryLoaded = await waitUntil("セカンダリペインの初回列挙が完了しませんでした") {
      secondary.currentLocation == fixture.first && !secondary.isLoading
        && secondary.items.contains { $0.name == "two" }
    }
    try #require(secondaryLoaded)
    try await Task.sleep(for: .milliseconds(300))

    await provider.addFile(named: "primary.txt", in: fixture.root)
    await provider.addFile(named: "secondary.txt", in: fixture.first)
    remote.revalidateDisplayedLocations()
    let observeUntil = ContinuousClock.now.advanced(by: .seconds(2))
    workspace.revalidateDisplayedLocations()
    await waitUntil("両タブの現在地に追加項目が反映されませんでした") {
      primary.currentLocation == fixture.root && primary.items.contains { $0.name == "primary.txt" }
        && secondary.currentLocation == fixture.first
        && secondary.items.contains { $0.name == "secondary.txt" }
    }
    var currentRemoteReads = remoteReads
    await waitUntil("リモートが再列挙の対象外であることを確認できませんでした") {
      currentRemoteReads = await remoteProvider.totalReadCount
      return currentRemoteReads != remoteReads || ContinuousClock.now >= observeUntil
    }
    #expect(currentRemoteReads == remoteReads)
  }

  private func expectWithinTwoSeconds(
    since startedAt: ContinuousClock.Instant,
    _ message: String,
    sourceLocation: SourceLocation = #_sourceLocation,
    condition: () -> Bool
  ) async {
    // 共通待機の既定期限を使い、反映までの実測時間を別に検証する。
    let appeared = await waitUntil(message, sourceLocation: sourceLocation) { condition() }
    if appeared {
      #expect(
        startedAt.duration(to: .now) <= .seconds(2), Comment(rawValue: message),
        sourceLocation: sourceLocation)
    }
  }

  @Test("T6 前景復帰の再検証で現在地と祖先カラムの補完済み属性を保持する")
  func preservesEnrichedMetadataDuringForegroundRevalidation() async throws {
    let provider = MetadataListingProvider()
    let fixture = try Fixture(provider: provider)
    defer { fixture.close() }
    let session = fixture.session
    let ancestor = fixture.second
    let current = fixture.deepest
    let seedName = "metadata.txt"
    await provider.listing.addFile(named: seedName, in: ancestor)
    await provider.listing.addFile(named: seedName, in: current)

    let ancestorURL = try #require(ancestor.localURL)
    let currentURL = try #require(current.localURL)
    let expectedAncestor = MetadataListingProvider.enrichedItem(
      at: ancestorURL.appending(path: seedName))
    let expectedCurrent = MetadataListingProvider.enrichedItem(
      at: currentURL.appending(path: seedName))
    var ancestorColumn: FileBrowserColumn? {
      session.columnState.columns.first { $0.location == ancestor }
    }
    var ancestorItem: FileItem? { ancestorColumn?.items.first { $0.name == seedName } }
    var currentItem: FileItem? { session.items.first { $0.name == seedName } }

    try await fixture.loadRoot()
    session.beginColumnBrowsing()
    try fixture.select("one", in: fixture.root)
    try await fixture.waitForColumn(fixture.first)
    try fixture.select("two", in: fixture.first)
    try await fixture.waitForColumn(ancestor)
    let ancestorEnriched = await waitUntil("祖先になるカラムの属性が補完されませんでした") {
      ancestorItem == expectedAncestor && !session.isMetadataEnrichmentActive
    }
    try #require(ancestorEnriched)
    try fixture.select("three", in: ancestor)
    try await fixture.waitForColumn(current)
    let currentEnriched = await waitUntil("現在地の属性が補完されませんでした") {
      currentItem == expectedCurrent && !session.isMetadataEnrichmentActive
    }
    try #require(currentEnriched)
    try #require(ancestorItem == expectedAncestor)
    try await Task.sleep(for: .milliseconds(300))

    let ancestorReads = await provider.listing.readCount(at: ancestor)
    let currentReads = await provider.listing.readCount(at: current)
    let replacements = session.itemsReplacementCount
    let ancestorRevision = ancestorColumn?.itemsRevision
    session.revalidateDisplayedLocations()
    let reread = await waitUntil("現在地と祖先カラムの再列挙が完了しませんでした") {
      let rereadAncestor = await provider.listing.readCount(at: ancestor)
      let rereadCurrent = await provider.listing.readCount(at: current)
      return rereadAncestor > ancestorReads && rereadCurrent > currentReads
        && !session.isRevalidatingInBackground
    }
    try #require(reread)

    // 祖先カラムには再検証中フラグがないため、列挙後の差し替えも観測する。
    let observeUntil = ContinuousClock.now.advanced(by: .seconds(2))
    await waitUntil {
      ancestorColumn?.itemsRevision != ancestorRevision || ContinuousClock.now >= observeUntil
    }
    #expect(currentItem == expectedCurrent)
    #expect(ancestorItem == expectedAncestor)
    #expect(ancestorColumn?.itemsRevision == ancestorRevision)
    let replacementsAfterReread = session.itemsReplacementCount
    #expect(replacementsAfterReread == replacements)

    // メモリ上だけで項目を加え、前景復帰の再検証経路で表示に反映する。
    let addedName = MetadataListingProvider.addedName
    await provider.listing.addFile(named: addedName, in: ancestor)
    await provider.listing.addFile(named: addedName, in: current)
    session.revalidateDisplayedLocations()
    let additionsDisplayed = await waitUntil("現在地と祖先カラムに追加項目が表示されませんでした") {
      session.items.contains { $0.name == addedName }
        && ancestorColumn?.items.contains { $0.name == addedName } == true
        && !session.isRevalidatingInBackground && !session.isMetadataEnrichmentActive
    }
    try #require(additionsDisplayed)
    #expect(currentItem == expectedCurrent)
    #expect(ancestorItem == expectedAncestor)
    let replacementsAfterAddition = session.itemsReplacementCount
    #expect(replacementsAfterAddition == replacementsAfterReread + 1)
  }

  @Test("T7 前景復帰の再検証で未読込タブを列挙しない")
  func skipsUnloadedLocalTabDuringForegroundRevalidation() async throws {
    let provider = ListingProvider()
    let fixture = try Fixture(provider: provider)
    defer { fixture.close() }

    fixture.session.revalidateDisplayedLocations()
    let observeUntil = ContinuousClock.now.advanced(by: .seconds(2))
    var reads = 0
    await waitUntil {
      reads = await provider.totalReadCount
      return reads > 0 || ContinuousClock.now >= observeUntil
    }
    #expect(reads == 0)
  }

  @Test("T8 祖先カラムになった直後の外部追加が反映される")
  func refreshesColumnWhenExternalFileAppearsImmediatelyAfterItBecomesAncestor() async throws {
    let fixture = try Fixture()
    defer { fixture.close() }
    try await fixture.loadRoot()
    fixture.session.beginColumnBrowsing()
    try fixture.select("one", in: fixture.root)
    try await fixture.waitForColumn(fixture.first)

    let startedAt = ContinuousClock.now
    try fixture.select("two", in: fixture.first)
    try fixture.create("external.txt", in: fixture.first)
    await expectWithinTwoSeconds(since: startedAt, "祖先化直後の追加が反映されませんでした") {
      fixture.columnNames(at: fixture.first)?.contains("external.txt") == true
    }
  }
}

@MainActor
private struct Fixture {
  let root: FileLocation
  let first: FileLocation
  let second: FileLocation
  let deepest: FileLocation
  let sibling: FileLocation
  let session: FileBrowserSession

  init(provider: any FileBrowserProvider = LocalFileProvider()) throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent()
    let rootURL = repository.appending(path: ".derived-data/external-change-refresh-fixtures")
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let firstURL = rootURL.appending(path: "one", directoryHint: .isDirectory)
    let secondURL = firstURL.appending(path: "two", directoryHint: .isDirectory)
    let deepestURL = secondURL.appending(path: "three", directoryHint: .isDirectory)
    let siblingURL = rootURL.appending(path: "sibling", directoryHint: .isDirectory)
    do {
      try FileManager.default.createDirectory(at: deepestURL, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: siblingURL, withIntermediateDirectories: false)
      try Data().write(to: deepestURL.appending(path: "seed.txt"))
    } catch {
      try? FileManager.default.removeItem(at: rootURL)
      throw error
    }
    root = FileLocation(directoryURL: rootURL, providerID: provider.id)
    first = FileLocation(directoryURL: firstURL, providerID: provider.id)
    second = FileLocation(directoryURL: secondURL, providerID: provider.id)
    deepest = FileLocation(directoryURL: deepestURL, providerID: provider.id)
    sibling = FileLocation(directoryURL: siblingURL, providerID: provider.id)
    session = FileBrowserSession(
      provider: provider, initialLocation: root, transferQueue: .isolatedForTesting())
  }

  func close() {
    session.invalidate()
    if let url = root.localURL {
      try? FileManager.default.removeItem(at: url)
    }
  }

  func loadRoot() async throws {
    session.load()
    let loaded = await waitUntil("初期フォルダの列挙が完了しませんでした") {
      session.currentLocation == root && !session.isLoading
        && session.items.contains { $0.name == "one" }
    }
    try #require(loaded)
  }

  func openDeepestColumn() async throws {
    try await loadRoot()
    session.beginColumnBrowsing()
    for (name, from, to) in [
      ("one", root, first), ("two", first, second), ("three", second, deepest),
    ] {
      try select(name, in: from)
      try await waitForColumn(to)
    }
    try #require(session.items.contains { $0.name == "seed.txt" })
  }

  func select(_ name: String, in location: FileLocation) throws {
    let column = try #require(session.columnState.columns.first { $0.location == location })
    let item = try #require(column.items.first { $0.name == name })
    session.selectColumnItems([item.url], inColumnAt: location)
  }

  func waitForColumn(_ location: FileLocation) async throws {
    let loaded = await waitUntil("目的のカラムが右端に表示されませんでした") {
      session.currentLocation == location && session.columnState.columns.last?.location == location
        && session.columnState.columns.last?.isLoading == false
    }
    try #require(loaded)
  }

  func create(_ name: String, in location: FileLocation) throws {
    let url = try #require(location.localURL).appending(path: name)
    try Data("外部作成".utf8).write(to: url)
  }

  func columnNames(at location: FileLocation) -> [String]? {
    session.columnState.columns.first { $0.location == location }?.items.map(\.name)
  }

  var columnNamesByLocation: [FileLocation: [String]] {
    Dictionary(
      uniqueKeysWithValues: session.columnState.columns.map { ($0.location, $0.items.map(\.name)) })
  }

  func expandFirstFolder() async throws {
    let item = try #require(session.items.first { $0.name == "one" })
    session.toggleExpansion(of: item)
    let loaded = await waitUntil("展開したフォルダの列挙が完了しませんでした") {
      listRows().contains { $0.item.name == "two" && $0.depth == 1 }
    }
    try #require(loaded)
  }

  func listRows() -> [FileTreeRow] {
    session.flattenedRows(
      matching: "", sortOrder: .name, ascending: true, includesHiddenItems: false)
  }
}

// ローカルの初期一覧にメモリ上の項目を加え、再列挙の有無を数える。
private actor ListingProvider: FileBrowserProvider {
  nonisolated let id: FileProviderID
  nonisolated let connectionID: FileProviderConnectionID? = nil
  nonisolated let capabilities: FileProviderCapabilities = [.read]
  private let local = LocalFileProvider()
  private var addedItems: [FileLocation: [FileItem]] = [:]
  private var reads: [FileLocation: Int] = [:]

  init(id: FileProviderID = .local) {
    self.id = id
  }

  func addFile(named name: String, in location: FileLocation) {
    guard let url = location.localURL else { return }
    addedItems[location, default: []].append(
      FileItem(url: url.appending(path: name), providerID: id, isDirectory: false))
  }

  func readCount(at location: FileLocation) -> Int {
    reads[location, default: 0]
  }

  var totalReadCount: Int {
    reads.values.reduce(0, +)
  }

  func contents(of location: FileLocation) async throws -> [FileItem] {
    reads[location, default: 0] += 1
    guard location.localURL != nil else { return [] }
    let additions = addedItems[location, default: []]
    let items = try await local.contents(of: location)
    return items + additions
  }

  nonisolated func parent(of location: FileLocation) -> FileLocation? {
    local.parent(of: location)
  }

  nonisolated func breadcrumbs(
    for location: FileLocation, constrainedTo root: FileLocation?
  ) -> [FileBrowserBreadcrumb] {
    if location.localURL == nil {
      return [FileBrowserBreadcrumb(location: location, name: "リモート")]
    }
    return local.breadcrumbs(for: location, constrainedTo: root)
  }
}

// 列挙結果が確定した後に返却を止め、タグ編集が割り込む順序を固定する。
private actor GatedLocalProvider: FileBrowserProvider, FileBrowserFinderTagProvider,
  FileBrowserItemDetailProvider
{
  nonisolated let id: FileProviderID = .local
  nonisolated let connectionID: FileProviderConnectionID? = nil
  nonisolated let capabilities: FileProviderCapabilities = [.read, .finderTags]
  private let local = LocalFileProvider()
  private var pauseAt: FileLocation?
  private var gate: CheckedContinuation<Void, Never>?
  private var tags: [FileLocation: [String]] = [:]
  private(set) var pausedNames: [String]?

  func pauseNextRead(at location: FileLocation) {
    pauseAt = location
  }

  func releaseRead() {
    pauseAt = nil
    gate?.resume()
    gate = nil
  }

  func contents(of location: FileLocation) async throws -> [FileItem] {
    let items = try await local.contents(of: location).map { item in
      guard let names = tags[item.location] else { return item }
      return item.replacingTags(names)
    }
    if pauseAt == location, items.contains(where: { $0.name == "external.txt" }) {
      pauseAt = nil
      pausedNames = items.map(\.name)
      await withCheckedContinuation { gate = $0 }
    }
    return items
  }

  nonisolated func parent(of location: FileLocation) -> FileLocation? {
    local.parent(of: location)
  }

  nonisolated func breadcrumbs(
    for location: FileLocation, constrainedTo root: FileLocation?
  ) -> [FileBrowserBreadcrumb] {
    local.breadcrumbs(for: location, constrainedTo: root)
  }

  func detailedItem(at location: FileLocation) async throws -> FileItem {
    try await local.detailedItem(at: location).replacingTags(tags[location, default: []])
  }

  func setFinderTagNames(_ tagNames: [String], at location: FileLocation) async throws {
    tags[location] = tagNames
  }
}

// 既存の補完対象は列挙時に属性を省き、追加項目は初めから属性を揃える。
private struct MetadataListingProvider: FileBrowserItemDetailProvider {
  static let addedName = "added.txt"
  let id: FileProviderID = .local
  let connectionID: FileProviderConnectionID? = nil
  let capabilities: FileProviderCapabilities = [.read, .finderTags]
  let listing = ListingProvider()
  private let local = LocalFileProvider()

  func contents(of location: FileLocation) async throws -> [FileItem] {
    try await listing.contents(of: location).map { item in
      item.name == Self.addedName ? Self.enrichedItem(at: item.url) : item
    }
  }

  func detailedItem(at location: FileLocation) async throws -> FileItem {
    if let url = location.localURL, url.lastPathComponent == "metadata.txt" {
      return Self.enrichedItem(at: url)
    }
    return try await local.detailedItem(at: location)
  }

  static func enrichedItem(at url: URL) -> FileItem {
    FileItem(
      url: url, isDirectory: false, size: 128, modifiedAt: Date(timeIntervalSince1970: 42),
      tags: ["補完済み"])
  }

  func parent(of location: FileLocation) -> FileLocation? {
    listing.parent(of: location)
  }

  func breadcrumbs(
    for location: FileLocation, constrainedTo root: FileLocation?
  ) -> [FileBrowserBreadcrumb] {
    listing.breadcrumbs(for: location, constrainedTo: root)
  }
}
