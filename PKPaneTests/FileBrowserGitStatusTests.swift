import Foundation
import Testing

@testable import PKPane

@MainActor
struct FileBrowserGitStatusTests {
  @Test("既定OFFの実ロード経路はGit検出と実行Providerを一度も呼ばない")
  func disabledPreferenceHasZeroProviderCalls() async {
    let fixture = makeFixture(name: "off")
    let statusProvider = RecordingSessionGitStatusProvider(statusesByDirectory: [:])
    let session = FileBrowserSession(
      provider: fixture.provider,
      initialLocation: fixture.root,
      transferQueue: .isolatedForTesting(),
      gitStatusPreferences: makePreferences(isEnabled: false),
      gitStatusProvider: statusProvider)

    session.load()
    await waitUntil { !session.isLoading && !session.isRefreshing }

    #expect(session.gitStatuses.isEmpty)
    #expect(await statusProvider.statusCallCount == 0)
    #expect(await statusProvider.invalidationCallCount == 0)
  }

  @Test("注入した有効設定からフォルダ表示の実ロード経路を通ってバッジ状態を反映する")
  func enabledPreferenceLoadsStatusesThroughSessionRoute() async {
    let preferences = makePreferences(isEnabled: true)

    let fixture = makeFixture(name: "enabled")
    let itemURL = fixture.root.localURL!.appending(path: "file.swift")
    let statusProvider = RecordingSessionGitStatusProvider(
      statusesByDirectory: [fixture.root.localURL!: [itemURL: .modified]])
    let session = FileBrowserSession(
      provider: fixture.provider,
      initialLocation: fixture.root,
      transferQueue: .isolatedForTesting(),
      gitStatusPreferences: preferences,
      gitStatusProvider: statusProvider)

    session.load()
    await waitUntil { session.gitStatuses[itemURL] == .modified }

    #expect(session.items.map(\.url) == [itemURL])
    #expect(await statusProvider.statusCallCount == 1)
  }

  @Test("明示更新はディレクトリキャッシュを無効化して状態を再取得する")
  func refreshInvalidatesDirectoryStatusCache() async {
    let fixture = makeFixture(name: "refresh")
    let itemURL = fixture.root.localURL!.appending(path: "file.swift")
    let statusProvider = RecordingSessionGitStatusProvider(
      statusesByDirectory: [fixture.root.localURL!: [itemURL: .modified]])
    let session = FileBrowserSession(
      provider: fixture.provider,
      initialLocation: fixture.root,
      transferQueue: .isolatedForTesting(),
      gitStatusPreferences: makePreferences(isEnabled: true),
      gitStatusProvider: statusProvider)
    session.load()
    await waitUntil { session.gitStatuses[itemURL] == .modified }

    session.refresh()
    await waitUntil {
      let statusCallCount = await statusProvider.statusCallCount
      let invalidationCallCount = await statusProvider.invalidationCallCount
      return statusCallCount == 2 && invalidationCallCount == 1
    }

    #expect(session.gitStatuses[itemURL] == .modified)
  }

  @Test("ナビゲーションは古いGit状態取得をキャンセルして移動先だけを反映する")
  func navigationCancelsPreviousStatusLoad() async {
    let fixture = makeFixture(name: "navigation")
    let secondURL = fixture.root.localURL!.appending(path: "second", directoryHint: .isDirectory)
    let secondLocation = FileLocation(directoryURL: secondURL, providerID: fixture.provider.id)
    let secondItemURL = secondURL.appending(path: "next.swift")
    let statusProvider = NavigationSessionGitStatusProvider(
      slowDirectory: fixture.root.localURL!,
      statusesByDirectory: [secondURL: [secondItemURL: .added]])
    let provider = GitStatusSessionProvider(
      id: fixture.provider.id,
      itemsByLocation: [
        fixture.root: fixture.provider.itemsByLocation[fixture.root] ?? [],
        secondLocation: [
          FileItem(url: secondItemURL, providerID: fixture.provider.id, isDirectory: false)
        ],
      ])
    let session = FileBrowserSession(
      provider: provider,
      initialLocation: fixture.root,
      transferQueue: .isolatedForTesting(),
      gitStatusPreferences: makePreferences(isEnabled: true),
      gitStatusProvider: statusProvider)

    session.load()
    await waitUntil { await statusProvider.didStartSlowRequest }
    session.load(location: secondLocation)
    await waitUntil { session.gitStatuses[secondItemURL] == .added }

    #expect(await statusProvider.cancellationCount == 1)
    #expect(session.currentLocation == secondLocation)
    #expect(session.gitStatuses.count == 1)
  }

  @Test("ON時の1000件でも一覧を先に表示しGit状態を1回の後追い更新で反映する")
  func thousandItemsRemainNonblockingWithGitStatusEnabled() async {
    let providerID = FileProviderID(rawValue: "git-status-thousand")
    let rootURL = URL(filePath: "/virtual/thousand", directoryHint: .isDirectory)
    let root = FileLocation(directoryURL: rootURL, providerID: providerID)
    let items = (0..<1_000).map { index in
      FileItem(
        url: rootURL.appending(path: "item-\(index).swift"),
        providerID: providerID,
        isDirectory: false)
    }
    let provider = GitStatusSessionProvider(id: providerID, itemsByLocation: [root: items])
    let statusProvider = DeferredSessionGitStatusProvider()
    let session = FileBrowserSession(
      provider: provider,
      initialLocation: root,
      transferQueue: .isolatedForTesting(),
      gitStatusPreferences: makePreferences(isEnabled: true),
      gitStatusProvider: statusProvider)

    session.load()
    await waitUntil {
      let didStart = await statusProvider.didStart
      return session.items.count == 1_000 && didStart
    }
    let replacementCountBeforeStatuses = session.itemsReplacementCount
    #expect(session.gitStatuses.isEmpty)

    await statusProvider.release(
      Dictionary(uniqueKeysWithValues: items.map { ($0.url, GitFileStatus.modified) }))
    await waitUntil { session.gitStatuses.count == 1_000 }

    #expect(session.items.count == 1_000)
    #expect(session.itemsReplacementCount == replacementCountBeforeStatuses)
    #expect(await statusProvider.callCount == 1)
  }

  @Test("設定をOFFへ戻すと進行中の取得をキャンセルして表示状態を消す")
  func disablingPreferenceCancelsInFlightStatusLoad() async {
    let fixture = makeFixture(name: "disable")
    let preferences = makePreferences(isEnabled: true)
    let statusProvider = NavigationSessionGitStatusProvider(
      slowDirectory: fixture.root.localURL!,
      statusesByDirectory: [:])
    let session = FileBrowserSession(
      provider: fixture.provider,
      initialLocation: fixture.root,
      transferQueue: .isolatedForTesting(),
      gitStatusPreferences: preferences,
      gitStatusProvider: statusProvider)
    session.load()
    await waitUntil { await statusProvider.didStartSlowRequest }

    preferences.isEnabled = false
    session.applyGitStatusPreference()
    await waitUntil { await statusProvider.cancellationCount == 1 }

    #expect(session.gitStatuses.isEmpty)
  }

  @Test("カラムの表示中Git状態を保持し右側を閉じた後に古い非表示状態から退避する")
  func columnBrowsingBoundsSessionStatusesByDirectory() async throws {
    let directoryCount = GitStatusCachePolicy.directoryLimit + 2
    let providerID = FileProviderID(rawValue: "git-status-column-lru")
    let rootURL = URL(filePath: "/virtual/column-lru", directoryHint: .isDirectory)
    let locations = (0..<directoryCount).map { depth in
      let url = (0..<depth).reduce(rootURL) { partialURL, index in
        partialURL.appending(path: "level-\(index)", directoryHint: .isDirectory)
      }
      return FileLocation(directoryURL: url, providerID: providerID)
    }
    let markerURLs = locations.enumerated().map { index, location in
      location.localURL!.appending(path: "marker-\(index).swift")
    }
    let shallowIndex = 5
    let alternateURL = locations[shallowIndex].localURL!.appending(
      path: "alternate", directoryHint: .isDirectory)
    let alternateLocation = FileLocation(directoryURL: alternateURL, providerID: providerID)
    let alternateMarkerURL = alternateURL.appending(path: "alternate-marker.swift")
    var itemsByLocation: [FileLocation: [FileItem]] = [:]
    var statusesByDirectory: [URL: [URL: GitFileStatus]] = [:]
    for (index, location) in locations.enumerated() {
      var items = [
        FileItem(url: markerURLs[index], providerID: providerID, isDirectory: false)
      ]
      if index + 1 < locations.count {
        items.insert(
          FileItem(
            url: locations[index + 1].localURL!,
            providerID: providerID,
            isDirectory: true),
          at: 0)
      }
      if index == shallowIndex {
        items.append(
          FileItem(url: alternateURL, providerID: providerID, isDirectory: true))
      }
      itemsByLocation[location] = items
      statusesByDirectory[location.localURL!] = [markerURLs[index]: .modified]
    }
    itemsByLocation[alternateLocation] = [
      FileItem(url: alternateMarkerURL, providerID: providerID, isDirectory: false)
    ]
    statusesByDirectory[alternateURL] = [alternateMarkerURL: .added]
    let provider = GitStatusSessionProvider(id: providerID, itemsByLocation: itemsByLocation)
    let statusProvider = RecordingSessionGitStatusProvider(
      statusesByDirectory: statusesByDirectory)
    let session = FileBrowserSession(
      provider: provider,
      initialLocation: locations[0],
      transferQueue: .isolatedForTesting(),
      gitStatusPreferences: makePreferences(isEnabled: true),
      gitStatusProvider: statusProvider)

    session.load()
    await waitUntil(timeout: .seconds(5)) {
      session.gitStatuses[markerURLs[0]] == .modified && !session.isLoading
    }
    session.beginColumnBrowsing()
    for index in 0..<(locations.count - 1) {
      let folder = try #require(itemsByLocation[locations[index]]?.first)
      session.selectColumnItem(folder, inColumnAt: locations[index])
      let destination = locations[index + 1]
      await waitUntil(timeout: .seconds(5)) {
        session.columnState.columns.first(where: { $0.location == destination })?.isLoading
          == false
          && session.gitStatuses[markerURLs[index + 1]] == .modified
      }
      #expect(session.gitStatuses[markerURLs[index + 1]] == .modified)
    }

    // 全カラムが表示中なら128件を超えてもバッジを保持する。この期待値は、表示中かを
    // 考慮しない修正前の純FIFO実装では失敗する。
    #expect(session.gitStatusTrackedDirectoryCount == directoryCount)
    #expect(session.gitStatuses.count == directoryCount)
    #expect(session.gitStatuses[markerURLs[0]] == .modified)

    let shallowFile = try #require(
      itemsByLocation[locations[shallowIndex]]?.first(where: { !$0.isDirectory }))
    session.selectColumnItem(shallowFile, inColumnAt: locations[shallowIndex])
    await waitUntil(timeout: .seconds(5)) {
      session.columnState.columns.count == shallowIndex + 1
    }

    #expect(
      session.columnState.columns.map(\.location)
        == Array(locations.prefix(shallowIndex + 1)))

    let alternateFolder = try #require(
      itemsByLocation[locations[shallowIndex]]?.first(where: { $0.url == alternateURL }))
    session.selectColumnItem(alternateFolder, inColumnAt: locations[shallowIndex])
    await waitUntil(timeout: .seconds(5)) {
      session.gitStatuses[alternateMarkerURL] == .added
        && session.gitStatusTrackedDirectoryCount == GitStatusCachePolicy.directoryLimit
    }

    #expect(session.gitStatusTrackedDirectoryCount == GitStatusCachePolicy.directoryLimit)
    #expect(session.gitStatuses.count == GitStatusCachePolicy.directoryLimit)
    #expect(session.columnState.columns.last?.location == alternateLocation)
    for index in 0...shallowIndex {
      #expect(session.gitStatuses[markerURLs[index]] == .modified)
    }
    #expect(session.gitStatuses[alternateMarkerURL] == .added)
    #expect(session.gitStatuses[markerURLs[shallowIndex + 1]] == nil)
    #expect(session.gitStatuses[markerURLs[shallowIndex + 2]] == nil)
    #expect(session.gitStatuses[markerURLs[shallowIndex + 3]] == nil)
    #expect(session.gitStatuses[markerURLs[shallowIndex + 4]] == .modified)
    let lastMarkerURL = try #require(markerURLs.last)
    #expect(session.gitStatuses[lastMarkerURL] == .modified)
  }

  @Test("公開Providerは外部gitプロセスを必要とするGit状態能力を持たない")
  func publicProvidersDoNotExposeGitStatus() {
    #expect(!LocalFileProvider().capabilities.contains(.gitStatus))
    #expect(
      !MountedVolumeProvider(volumeURL: URL(filePath: "/Volumes/Test"))
        .capabilities.contains(.gitStatus))
    #expect(!FileProviderCapabilities.read.contains(.gitStatus))
  }

  private func makePreferences(isEnabled: Bool) -> StubGitStatusPreferences {
    StubGitStatusPreferences(isEnabled: isEnabled)
  }

  private func makeFixture(name: String) -> GitStatusSessionFixture {
    let providerID = FileProviderID(rawValue: "git-status-\(name)")
    let rootURL = URL(filePath: "/virtual/\(name)", directoryHint: .isDirectory)
    let root = FileLocation(directoryURL: rootURL, providerID: providerID)
    let item = FileItem(
      url: rootURL.appending(path: "file.swift"),
      providerID: providerID,
      isDirectory: false)
    return GitStatusSessionFixture(
      root: root,
      provider: GitStatusSessionProvider(id: providerID, itemsByLocation: [root: [item]]))
  }

  private func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: @escaping @MainActor () async -> Bool
  ) async {
    await PKPaneTests.waitUntil(timeout: timeout, "Gitステータスの状態が期限内に条件を満たさなかった") {
      await condition()
    }
  }
}

private struct GitStatusSessionFixture {
  let root: FileLocation
  let provider: GitStatusSessionProvider
}

@MainActor
private final class StubGitStatusPreferences: GitStatusPreferenceReading {
  var isEnabled: Bool

  init(isEnabled: Bool) {
    self.isEnabled = isEnabled
  }
}

private actor DeferredSessionGitStatusProvider: GitStatusProviding {
  private(set) var callCount = 0
  private(set) var didStart = false
  private var continuation: CheckedContinuation<[URL: GitFileStatus], Never>?

  func statuses(in _: URL) async -> [URL: GitFileStatus] {
    callCount += 1
    didStart = true
    return await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func invalidate(directory _: URL) {}

  func release(_ statuses: [URL: GitFileStatus]) {
    continuation?.resume(returning: statuses)
    continuation = nil
  }
}

private struct GitStatusSessionProvider: FileBrowserProvider {
  let id: FileProviderID
  let connectionID: FileProviderConnectionID? = nil
  let capabilities: FileProviderCapabilities = [.read, .gitStatus]
  let itemsByLocation: [FileLocation: [FileItem]]

  func contents(of location: FileLocation) async throws -> [FileItem] {
    itemsByLocation[location] ?? []
  }

  func parent(of _: FileLocation) -> FileLocation? { nil }

  func breadcrumbs(
    for location: FileLocation,
    constrainedTo _: FileLocation?
  ) -> [FileBrowserBreadcrumb] {
    [FileBrowserBreadcrumb(location: location, name: location.localURL?.lastPathComponent ?? "")]
  }
}

private actor RecordingSessionGitStatusProvider: GitStatusProviding {
  private(set) var statusCallCount = 0
  private(set) var invalidationCallCount = 0
  let statusesByDirectory: [URL: [URL: GitFileStatus]]

  init(statusesByDirectory: [URL: [URL: GitFileStatus]]) {
    self.statusesByDirectory = statusesByDirectory
  }

  func statuses(in directory: URL) -> [URL: GitFileStatus] {
    statusCallCount += 1
    return statusesByDirectory[directory] ?? [:]
  }

  func invalidate(directory _: URL) {
    invalidationCallCount += 1
  }
}

private actor NavigationSessionGitStatusProvider: GitStatusProviding {
  private(set) var didStartSlowRequest = false
  private(set) var cancellationCount = 0
  let slowDirectory: URL
  let statusesByDirectory: [URL: [URL: GitFileStatus]]

  init(
    slowDirectory: URL,
    statusesByDirectory: [URL: [URL: GitFileStatus]]
  ) {
    self.slowDirectory = slowDirectory
    self.statusesByDirectory = statusesByDirectory
  }

  func statuses(in directory: URL) async -> [URL: GitFileStatus] {
    if directory == slowDirectory {
      didStartSlowRequest = true
      do {
        try await Task.sleep(for: .seconds(10))
      } catch {
        cancellationCount += 1
      }
      return [:]
    }
    return statusesByDirectory[directory] ?? [:]
  }

  func invalidate(directory _: URL) {}
}
