import Foundation
import Testing

@testable import PKPane

struct SFTPListingPerformanceTests {
  @Test(
    "同じ宛先へのSFTP移動でNとMを独立に変えて親一覧を10回計測する",
    .enabled(
      if: ProcessInfo.processInfo.environment["PKPANE_RV26_MEASUREMENTS"] == "1",
      "RV26前後計測時だけ10回の遅延フィクスチャを実行する"),
    arguments: [
      (files: 1, entries: 0), (files: 1, entries: 10_000),
      (files: 100, entries: 0), (files: 100, entries: 10_000),
      (files: 1_000, entries: 0), (files: 1_000, entries: 10_000),
    ])
  func measuresRepeatedDestinationListing(scenario: (files: Int, entries: Int)) async throws {
    var samples: [Double] = []
    var listingCounts: [Int] = []
    for _ in 0..<10 {
      let session = SFTPListingMeasurementSession(entryCount: scenario.entries)
      let target = try SFTPConnectionTarget(
        host: "fixture.invalid", port: 22, username: "fixture")
      let provider = SFTPFileProvider(target: target, directoryListing: session)
      let destination = FileLocation(remotePath: "/destination", providerID: provider.id)
      let clock = ContinuousClock()
      let start = clock.now
      for index in 0..<scenario.files {
        let item = FileItem(
          remotePath: "/source/source-\(index)",
          url: URL(fileURLWithPath: "/source/source-\(index)"),
          providerID: provider.id, isDirectory: false, size: 1)
        try await provider.move(item, to: destination, replacingExisting: false)
      }
      let duration = start.duration(to: clock.now).components
      samples.append(Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15)
      let listings = await session.listingCount
      listingCounts.append(listings)
      #expect(listings == 0)
      #expect(await session.renameCount == scenario.files)
      #expect(await session.entryCount == scenario.entries + scenario.files)
    }
    let sorted = samples.sorted()
    let lower = try #require(sorted.prefix(sorted.count / 2).last)
    let upper = try #require(sorted.dropFirst(sorted.count / 2).first)
    try writeRV26Measurement(
      name: "rv26-09-sftp-listing",
      values: [
        "fileCount": scenario.files, "initialDestinationEntries": scenario.entries,
        "phase": "after",
        "listingDelayMilliseconds": 1, "samplesMilliseconds": samples,
        "fixtureRenameCollisionLookup": "Set membership",
        "medianMilliseconds": (lower + upper) / 2,
        "maximumMilliseconds": try #require(sorted.last), "listingCounts": listingCounts,
      ])
  }
}

private actor SFTPListingMeasurementSession: SFTPClientSession {
  private var entries: [SFTPDirectoryEntry]
  private var names: Set<String>
  var entryCount: Int { entries.count }
  private(set) var listingCount = 0
  private(set) var renameCount = 0

  init(entryCount: Int) {
    let initialEntries = (0..<entryCount).map {
      SFTPDirectoryEntry(name: "existing-\($0)", isDirectory: false, size: 1)
    }
    entries = initialEntries
    names = Set(initialEntries.map(\.name))
  }

  func contents(of _: String) async throws -> [SFTPDirectoryEntry] {
    listingCount += 1
    try await Task.sleep(for: .milliseconds(1))
    return entries
  }
  func createDirectory(at _: String) async throws {}
  func remove(at _: String, isDirectory _: Bool) async throws {}
  func rename(at _: String, to destination: String) async throws {
    let name = String(destination.split(separator: "/").last ?? "")
    guard names.insert(name).inserted else {
      throw CocoaError(.fileWriteFileExists)
    }
    entries.append(SFTPDirectoryEntry(name: name, isDirectory: false, size: 1))
    renameCount += 1
  }
  func close() async throws {}
}
