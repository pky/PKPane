import AppKit
import Foundation
import Observation
import SwiftUI
import Testing

@testable import PKPane

struct FileColumnPerformanceTests {
  @Test("1000件×10階層のカラム表示変換を短時間で完了する")
  func projectsTenDeepColumnsQuickly() {
    let columns = Self.makeColumns(depth: 10, itemsPerLevel: 1_000)

    let clock = ContinuousClock()
    var displayedColumns: [FileBrowserColumn] = []
    let duration = clock.measure {
      displayedColumns = FileBrowserColumnDisplay.columns(
        from: columns,
        matching: "item",
        sortOrder: .name,
        ascending: true,
        includesHiddenItems: true)
    }

    #expect(displayedColumns.count == 10)
    #expect(displayedColumns.flatMap(\.items).count == 10_000)
    #expect(displayedColumns.allSatisfy { $0.items.count == 1_000 })
    #expect(duration < .milliseconds(500))
    print(
      "PKPane性能計測: カラム1000件×10階層表示変換 "
        + "\(Self.milliseconds(duration))ms")
  }

  @MainActor
  @Test("深い移動先へのカラム切替で祖先を列挙せず移動先を左端にする")
  func switchesToDeepDestinationWithoutListingAncestors() async throws {
    let provider = LazyAncestorColumnProvider(depth: 6, largeAncestorItemCount: 10_000)
    let session = FileBrowserSession(
      provider: provider, initialLocation: provider.deepestLocation,
      transferQueue: .isolatedForTesting())
    session.load()
    await waitForColumnLoading(session)
    let listingCountBeforeSwitch = provider.contentsCallCount
    let selection = ColumnRenderSelection()
    var hostingView: NSHostingView<ColumnRenderHarness>?

    let clock = ContinuousClock()
    let duration = clock.measure {
      session.beginColumnBrowsing()
      let view = NSHostingView(
        rootView: ColumnRenderHarness(session: session, selection: selection))
      view.frame = NSRect(x: 0, y: 0, width: 720, height: 600)
      view.layoutSubtreeIfNeeded()
      hostingView = view
    }

    #expect(hostingView != nil)
    #expect(session.columnState.columns.map(\.location) == [provider.deepestLocation])
    #expect(provider.contentsCallCount == listingCountBeforeSwitch)
    #expect(duration < .milliseconds(100))

    await Task.yield()
    #expect(session.columnState.columns.map(\.location) == [provider.deepestLocation])
    #expect(provider.contentsCallCount == listingCountBeforeSwitch)
    #expect(session.columnState.columns.first?.items.count == 1)
    let metric =
      "PKPane性能計測: 6階層の移動先からカラム表示へ切替 "
      + "メインスレッド同期区間\(Self.milliseconds(duration))ms、祖先列挙0回"
    print(metric)
  }

  @MainActor
  @Test("1000件フォルダのカラムクリック実経路を計測する")
  func measuresThousandItemFolderClickPath() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appending(path: "pkpane-column-click-\(UUID().uuidString)", directoryHint: .isDirectory)
    let childURL = rootURL.appending(path: "Folder", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: childURL, withIntermediateDirectories: true)
    FileManager.default.createFile(
      atPath: rootURL.appending(path: "root-file.txt").path,
      contents: Data())
    for index in 0..<1_000 {
      FileManager.default.createFile(
        atPath: childURL.appending(path: String(format: "%04d-item.txt", index)).path,
        contents: Data())
    }
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let threshold = Duration.milliseconds(100)
    var bestClickDuration: Duration?
    var bestSelectionDuration: Duration?
    for attempt in 1...3 {
      let durations = try await measureThousandItemFolderClickPath(
        rootURL: rootURL,
        attempt: attempt)
      bestClickDuration = min(bestClickDuration ?? durations.click, durations.click)
      bestSelectionDuration = min(bestSelectionDuration ?? durations.selection, durations.selection)
      if durations.click < threshold, durations.selection < threshold {
        break
      }
    }

    let fastestClickDuration = try #require(bestClickDuration)
    let fastestSelectionDuration = try #require(bestSelectionDuration)
    #expect(fastestClickDuration < threshold)
    #expect(fastestSelectionDuration < threshold)
  }

  @MainActor
  private func measureThousandItemFolderClickPath(
    rootURL: URL,
    attempt: Int
  ) async throws -> (click: Duration, selection: Duration) {
    let provider = CountingColumnLocalProvider()
    let session = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(directoryURL: rootURL, providerID: provider.id),
      transferQueue: .isolatedForTesting())
    // 前試行のフォルダ監視・投影タスクが次試行の計測へ負荷として残らないよう、
    // 試行単位で必ず破棄する(途中の#require脱出も含む)。
    defer { session.invalidate() }
    session.load()
    await waitForColumnLoading(session)
    let rootLocation = session.currentLocation
    session.beginColumnBrowsing()
    try #require(!session.columnState.columns.isEmpty)
    let folder = try #require(
      session.columnState.columns[0].items.first(where: { $0.name == "Folder" }))
    let rootFile = try #require(
      session.columnState.columns[0].items.first(where: { $0.name == "root-file.txt" }))
    let selection = ColumnRenderSelection()
    let hostingView = NSHostingView(
      rootView: ColumnRenderHarness(session: session, selection: selection))
    hostingView.frame = NSRect(x: 0, y: 0, width: 720, height: 600)
    hostingView.layoutSubtreeIfNeeded()
    await settleRendering(hostingView)

    let projectionCountBeforeClick = session.columnItemsProjectionCount
    let childProjectionCountBeforeClick =
      session.columnItemsProjectionCountByLocation[folder.location, default: 0]
    let listingCountBeforeClick = provider.contentsCallCount(at: folder.location)
    let streamingListingCountBeforeClick =
      provider.streamingContentsCallCount(at: folder.location)
    let clock = ContinuousClock()
    var selectionDispatchDuration = Duration.zero
    var listingDuration = Duration.zero
    var renderingDuration = Duration.zero
    let duration = await clock.measure {
      selectionDispatchDuration = clock.measure {
        session.selectColumnItem(folder, inColumnAt: rootLocation)
        selection.urls = [folder.url]
      }
      listingDuration = await clock.measure {
        await waitForColumn(session, at: folder.location)
      }
      renderingDuration = await clock.measure {
        await settleRendering(hostingView)
      }
    }

    let projectedItems = session.columnItemsProjectionCount - projectionCountBeforeClick
    let childProjectedItems =
      session.columnItemsProjectionCountByLocation[folder.location, default: 0]
      - childProjectionCountBeforeClick
    let listingCount = provider.contentsCallCount(at: folder.location) - listingCountBeforeClick
    let streamingListingCount =
      provider.streamingContentsCallCount(at: folder.location)
      - streamingListingCountBeforeClick
    #expect(listingCount == 1)
    #expect(streamingListingCount == 1)
    #expect(childProjectedItems <= 1_000)
    print(
      "PKPane性能計測: カラム1000件フォルダクリック(試行\(attempt)) "
        + "\(Self.milliseconds(duration))ms、列挙\(listingCount)回、"
        + "表示変換\(childProjectedItems)項目、全カラム変換\(projectedItems)項目、"
        + "選択反映\(Self.milliseconds(selectionDispatchDuration))ms、"
        + "列挙待ち\(Self.milliseconds(listingDuration))ms、"
        + "描画安定待ち\(Self.milliseconds(renderingDuration))ms")

    let childColumn = try #require(
      session.columnState.columns.first(where: { $0.location == folder.location }))
    let childFile = try #require(childColumn.items.first)
    let projectionCountBeforeSelection = session.columnItemsProjectionCount
    let selectionDuration = await clock.measure {
      session.selectColumnItem(childFile, inColumnAt: folder.location)
      selection.urls = [childFile.url]
      await settleRendering(hostingView)
    }
    let selectionProjectedItems =
      session.columnItemsProjectionCount - projectionCountBeforeSelection
    #expect(selectionProjectedItems == 0)
    print(
      "PKPane性能計測: カラム1000件内の選択変更(試行\(attempt)) "
        + "\(Self.milliseconds(selectionDuration))ms、表示変換\(selectionProjectedItems)項目")

    let multipleSelection = Set(childColumn.items.prefix(2).map(\.url))
    let projectionCountBeforeMultipleSelection = session.columnItemsProjectionCount
    session.selectColumnItems(multipleSelection, inColumnAt: folder.location)
    selection.urls = multipleSelection
    await settleRendering(hostingView)
    let multipleSelectionProjectedItems =
      session.columnItemsProjectionCount - projectionCountBeforeMultipleSelection
    #expect(multipleSelectionProjectedItems == 0)
    #expect(session.columnState.columns.last?.selectedItemURLs == multipleSelection)
    print(
      "PKPane性能計測: カラム1000件内の複数選択変更 "
        + "表示変換\(multipleSelectionProjectedItems)項目")

    let listingCountBeforeReselection = provider.contentsCallCount(at: folder.location)
    session.selectColumnItem(rootFile, inColumnAt: rootLocation)
    session.selectColumnItem(folder, inColumnAt: rootLocation)
    await waitForColumn(session, at: folder.location)
    #expect(provider.contentsCallCount(at: folder.location) == listingCountBeforeReselection)

    return (duration, selectionDuration)
  }

  private static func makeColumns(depth: Int, itemsPerLevel: Int) -> [FileBrowserColumn] {
    let providerID = FileProviderID(rawValue: "column-performance")
    return (0..<depth).map { level in
      let directoryPath = "/level-\(level)"
      let location = FileLocation(remotePath: directoryPath, providerID: providerID)
      let items = (0..<itemsPerLevel).map { index in
        let name = String(format: "%04d-item", itemsPerLevel - index)
        let path = "\(directoryPath)/\(name)"
        return FileItem(
          remotePath: path,
          url: URL(string: "sftp://performance.invalid\(path)")!,
          providerID: providerID,
          isDirectory: index == 0)
      }
      return FileBrowserColumn(
        location: location,
        items: items,
        selectedItemURLs: Set(items.prefix(1).map(\.url)),
        isLoading: false)
    }
  }

  private static func milliseconds(_ duration: Duration) -> String {
    let components = duration.components
    let seconds = Double(components.seconds) * 1_000
    let attoseconds = Double(components.attoseconds) / 1_000_000_000_000_000
    return String(format: "%.2f", seconds + attoseconds)
  }

  @MainActor
  private func waitForColumnLoading(_ session: FileBrowserSession) async {
    await waitUntil(timeout: .seconds(5), "カラムの読み込みが期限内に完了しなかった") {
      !(session.isLoading || session.isRefreshing
        || session.columnState.columns.contains(where: \.isLoading))
    }
  }

  @MainActor
  private func waitForColumn(_ session: FileBrowserSession, at location: FileLocation) async {
    await waitUntil(timeout: .seconds(5), "指定カラムの読み込みが期限内に完了しなかった") {
      session.columnState.columns.first(where: { $0.location == location })?.isLoading == false
    }
  }

  @MainActor
  private func settleRendering(_ hostingView: NSHostingView<ColumnRenderHarness>) async {
    for _ in 0..<4 {
      await Task.yield()
      hostingView.layoutSubtreeIfNeeded()
    }
  }
}

private final class CountingColumnLocalProvider: FileBrowserStreamingProvider, @unchecked Sendable {
  private let wrapped = LocalFileProvider()
  private let lock = NSLock()
  private var callCount = 0
  private var callCountByLocation: [FileLocation: Int] = [:]
  private var streamingCallCountByLocation: [FileLocation: Int] = [:]

  var id: FileProviderID { wrapped.id }
  var connectionID: FileProviderConnectionID? { wrapped.connectionID }
  var capabilities: FileProviderCapabilities { wrapped.capabilities }
  var contentsCallCount: Int { lock.withLock { callCount } }
  func contentsCallCount(at location: FileLocation) -> Int {
    lock.withLock { callCountByLocation[location, default: 0] }
  }
  func streamingContentsCallCount(at location: FileLocation) -> Int {
    lock.withLock { streamingCallCountByLocation[location, default: 0] }
  }

  func contents(of location: FileLocation) async throws -> [FileItem] {
    recordContentsCall(at: location)
    return try await wrapped.contents(of: location)
  }

  func contents(of location: FileLocation, includingHidden: Bool) async throws -> [FileItem] {
    recordContentsCall(at: location)
    return try await wrapped.contents(of: location, includingHidden: includingHidden)
  }

  func contentsStream(
    of location: FileLocation,
    includingHidden: Bool,
    batchSize: Int
  ) -> AsyncThrowingStream<[FileItem], Error> {
    recordContentsCall(at: location, isStreaming: true)
    return wrapped.contentsStream(
      of: location,
      includingHidden: includingHidden,
      batchSize: batchSize)
  }

  func parent(of location: FileLocation) -> FileLocation? {
    wrapped.parent(of: location)
  }

  func breadcrumbs(
    for location: FileLocation,
    constrainedTo root: FileLocation?
  ) -> [FileBrowserBreadcrumb] {
    wrapped.breadcrumbs(for: location, constrainedTo: root)
  }

  private func recordContentsCall(at location: FileLocation, isStreaming: Bool = false) {
    lock.withLock {
      callCount += 1
      callCountByLocation[location, default: 0] += 1
      if isStreaming {
        streamingCallCountByLocation[location, default: 0] += 1
      }
    }
  }
}

private final class LazyAncestorColumnProvider: FileBrowserProvider, @unchecked Sendable {
  let id = FileProviderID(rawValue: "lazy-column-ancestor")
  let connectionID: FileProviderConnectionID? = nil
  let capabilities: FileProviderCapabilities = [.read]
  let deepestLocation: FileLocation

  private let lock = NSLock()
  private let parentByLocation: [FileLocation: FileLocation]
  private let itemsByLocation: [FileLocation: [FileItem]]
  private let ancestorLocation: FileLocation
  private let largeAncestorItemCount: Int
  private var callCount = 0
  private var activeCallCount = 0
  private var maximumActiveCallCount = 0

  var contentsCallCount: Int { lock.withLock { callCount } }
  var maximumConcurrentContentsCalls: Int { lock.withLock { maximumActiveCallCount } }

  init(depth: Int, largeAncestorItemCount: Int) {
    let providerID = FileProviderID(rawValue: "lazy-column-ancestor")
    let locations = (0..<depth).map { level in
      FileLocation(
        remotePath: "/" + (0...level).map { "level-\($0)" }.joined(separator: "/"),
        providerID: providerID)
    }
    deepestLocation = locations[depth - 1]
    ancestorLocation = locations[0]
    self.largeAncestorItemCount = largeAncestorItemCount
    parentByLocation = Dictionary(
      uniqueKeysWithValues: (1..<locations.count).map { (locations[$0], locations[$0 - 1]) })

    var contents: [FileLocation: [FileItem]] = [:]
    for (index, location) in locations.enumerated() {
      var items: [FileItem] = []
      if index + 1 < locations.count {
        items.append(Self.item(at: locations[index + 1], isDirectory: true))
      } else {
        let report = location.appending(pathComponent: "report.txt")!
        items.append(Self.item(at: report, isDirectory: false))
      }
      contents[location] = items
    }
    itemsByLocation = contents
  }

  func contents(of location: FileLocation) async throws -> [FileItem] {
    beginContentsCall()
    await Task.yield()
    endContentsCall()
    var items = itemsByLocation[location] ?? []
    // 正常な切替では列挙しない祖先の大量項目は、実際に要求された場合だけ作る。
    if location == ancestorLocation {
      for itemIndex in items.count..<largeAncestorItemCount {
        let itemLocation = location.appending(
          pathComponent: String(format: "%05d-item.txt", itemIndex))!
        items.append(Self.item(at: itemLocation, isDirectory: false))
      }
    }
    return items
  }

  func parent(of location: FileLocation) -> FileLocation? {
    parentByLocation[location]
  }

  func breadcrumbs(
    for location: FileLocation, constrainedTo root: FileLocation?
  ) -> [FileBrowserBreadcrumb] {
    []
  }

  private func beginContentsCall() {
    lock.withLock {
      callCount += 1
      activeCallCount += 1
      maximumActiveCallCount = max(maximumActiveCallCount, activeCallCount)
    }
  }

  private func endContentsCall() {
    lock.withLock {
      activeCallCount -= 1
    }
  }

  private static func item(at location: FileLocation, isDirectory: Bool) -> FileItem {
    let path = location.remotePath!
    return FileItem(
      remotePath: path,
      url: URL(string: "sftp://lazy-column.invalid\(path)")!,
      providerID: location.providerID,
      isDirectory: isDirectory)
  }
}

@MainActor
@Observable
private final class ColumnRenderSelection {
  var urls: Set<URL> = []
}

private struct ColumnRenderHarness: View {
  let session: FileBrowserSession
  let selection: ColumnRenderSelection

  var body: some View {
    FileBrowserContent(
      items: [],
      selectedItemURLs: Binding(
        get: { selection.urls },
        set: { selection.urls = $0 }),
      browserViewMode: .column,
      displayOptions: FileBrowserDisplayOptions(viewMode: .column),
      gitStatuses: nil,
      nameCell: { item in Text(item.name) },
      contextMenu: { _ in EmptyView() },
      select: { _ in },
      open: { _ in },
      supportsDragging: false,
      columns: session.displayColumns(
        matching: "", sortOrder: .name, ascending: true, includesHiddenItems: true),
      onSelectColumnItems: { _, _ in })
  }
}
