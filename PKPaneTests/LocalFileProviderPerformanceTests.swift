import Foundation
import Testing

@testable import PKPane

struct LocalFileProviderPerformanceTests {
  @MainActor
  @Test("隠し項目を含む1万項目で最初の表示と全件表示を計測する")
  func measuresIncrementalHiddenFileListing() async throws {
    let root = try Self.makeLargeDirectoryFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = LocalFileProvider()
    let session = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: root, providerID: provider.id),
      transferQueue: .isolatedForTesting())
    defer { session.invalidate() }
    let clock = ContinuousClock()
    let start = clock.now

    session.setShowsHiddenFiles(true, reload: false)
    session.load()
    while session.items.count < 100, session.isLoading || session.isRefreshing {
      await Task.yield()
    }
    let firstDisplayDuration = start.duration(to: clock.now)
    while session.isLoading || session.isRefreshing {
      await Task.yield()
    }
    let fullDisplayDuration = start.duration(to: clock.now)

    #expect(!session.items.isEmpty)
    #expect(session.items.count == 10_000)
    let names = session.items.map(\.name)
    #expect(
      names == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    // getattrlistbulk化によりサイズ・更新日時も列挙と同時に取得される(既知不整合Gの解消)。
    #expect(session.items.allSatisfy { $0.size != nil && $0.modifiedAt != nil })
    #expect(firstDisplayDuration < .milliseconds(100))
    #expect(fullDisplayDuration < .milliseconds(500))
    let message =
      "PKPane性能計測: 隠し項目1万件の最初の表示 \(Self.milliseconds(firstDisplayDuration))ms、全件表示 \(Self.milliseconds(fullDisplayDuration))ms"
    print(message)

    // 同じ1万件を使い、表示計測を温めずに同期列挙の性能も検証する。
    let synchronousListingDuration = try clock.measure {
      let items = try LocalFileProvider().contents(of: root, includingHidden: true)
      #expect(items.count == 10_000)
    }

    #expect(synchronousListingDuration < .seconds(2))
  }

  @MainActor
  @Test("通常表示の1万項目で最初の表示と全件表示を計測する")
  func measuresIncrementalVisibleFileListing() async throws {
    let root = try Self.makeLargeDirectoryFixture(includesHiddenItems: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = LocalFileProvider()
    let session = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: root, providerID: provider.id),
      transferQueue: .isolatedForTesting())
    defer { session.invalidate() }
    let clock = ContinuousClock()
    let start = clock.now

    session.load()
    while session.items.count < 100, session.isLoading || session.isRefreshing {
      await Task.yield()
    }
    let firstDisplayDuration = start.duration(to: clock.now)
    while session.isLoading || session.isRefreshing {
      await Task.yield()
    }
    let fullDisplayDuration = start.duration(to: clock.now)
    let listingCompletedAt = clock.now
    await PKPaneTests.waitUntil(
      timeout: .seconds(30),
      "初期Finderタグ補完が期限内に完了しなかった"
    ) {
      !session.isMetadataEnrichmentActive
    }
    let enrichmentDuration = listingCompletedAt.duration(to: clock.now)
    let measurement = try #require(session.lastMetadataEnrichmentMeasurement)

    #expect(session.items.count == 10_000)
    let names = session.items.map(\.name)
    #expect(
      names == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    // getattrlistbulk化によりサイズ・更新日時も列挙と同時に取得される(既知不整合Gの解消)。
    #expect(session.items.allSatisfy { $0.size != nil && $0.modifiedAt != nil })
    #expect(measurement.finderTagRequestCount == 64)
    #expect(measurement.successfulTagCount == 64)
    #expect(firstDisplayDuration < .milliseconds(100))
    #expect(fullDisplayDuration < .milliseconds(500))
    let message =
      "PKPane性能計測: 通常項目1万件の最初表示 "
      + "\(Self.milliseconds(firstDisplayDuration))ms、"
      + "全件表示 \(Self.milliseconds(fullDisplayDuration))ms、"
      + "初期Finderタグ補完 \(Self.milliseconds(enrichmentDuration))ms/"
      + "\(measurement.finderTagRequestCount)回"
    print(message)
  }

  @Test("1万項目の絞り込みと並べ替えを短時間で完了する")
  func filtersAndSortsTenThousandItemsQuickly() {
    let items = (0..<10_000).map { index in
      FileItem(
        url: URL(filePath: "/tmp/report-\(index).txt"), isDirectory: false,
        size: Int64(index))
    }

    let clock = ContinuousClock()
    let duration = clock.measure {
      let results = FileItemFilter.filteredAndSorted(
        items, matching: "report-9", matchMode: .literal,
        sortOrder: .name, ascending: true)
      #expect(!results.isEmpty)
    }

    #expect(duration < .milliseconds(500))
  }

  private static func makeLargeDirectoryFixture(includesHiddenItems: Bool = true) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for index in 0..<10_000 {
      let name =
        includesHiddenItems && index.isMultiple(of: 2)
        ? ".item-\(index).txt"
        : "item-\(index).txt"
      FileManager.default.createFile(
        atPath: root.appending(path: name).path,
        contents: Data())
    }
    return root
  }

  private static func milliseconds(_ duration: Duration) -> String {
    let components = duration.components
    let seconds = Double(components.seconds) * 1_000
    let attoseconds = Double(components.attoseconds) / 1_000_000_000_000_000
    let value = seconds + attoseconds
    return String(format: "%.1f", value)
  }
}
