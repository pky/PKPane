import Foundation
import Testing

@testable import PKPane

struct FTPListingPerformanceTests {
  @Test(
    "同じ宛先へのFTP移動でNとMを独立に変えて親一覧を10回計測する",
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
      let session = FTPListingMeasurementSession(entryCount: scenario.entries)
      let target = try FTPConnectionTarget(
        host: "fixture.invalid", port: 21, username: "fixture")
      let provider = FTPFileProvider(
        target: target, session: session, sessionFactory: { session })
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
      #expect(listings == scenario.files)
      #expect(await session.renameCount == scenario.files)
      #expect(await session.entryCount == scenario.entries + scenario.files)
    }
    let sorted = samples.sorted()
    let lower = try #require(sorted.prefix(sorted.count / 2).last)
    let upper = try #require(sorted.dropFirst(sorted.count / 2).first)
    try writeRV26Measurement(
      name: "rv26-09-ftp-listing",
      values: [
        "fileCount": scenario.files, "initialDestinationEntries": scenario.entries,
        "listingDelayMilliseconds": 1, "samplesMilliseconds": samples,
        "fixtureRenameCollisionLookup": "Set membership",
        "medianMilliseconds": (lower + upper) / 2,
        "maximumMilliseconds": try #require(sorted.last), "listingCounts": listingCounts,
      ])
  }
}

private actor FTPListingMeasurementSession: FTPClientSession {
  private var entries: [FTPDirectoryEntry]
  private var names: Set<String>
  var entryCount: Int { entries.count }
  private(set) var listingCount = 0
  private(set) var renameCount = 0

  init(entryCount: Int) {
    let initialEntries = (0..<entryCount).map {
      ftpListingEntry(name: "existing-\($0)")
    }
    entries = initialEntries
    names = Set(initialEntries.map(\.name))
  }

  func contents(of _: String) async throws -> [FTPDirectoryEntry] {
    listingCount += 1
    try await Task.sleep(for: .milliseconds(1))
    return entries
  }
  func createDirectory(at _: String) async throws {}
  func remove(at _: String, isDirectory _: Bool) async throws {}
  func rename(at _: String, to destination: String) async throws {
    let name = String(destination.split(separator: "/").last ?? "")
    // FTPのrenameは非置換を保証しない。計測では本番事前確認を経た新規名だけを使う。
    if names.insert(name).inserted { entries.append(ftpListingEntry(name: name)) }
    renameCount += 1
  }
  func streamFileContents(
    of _: String, receive _: @escaping @Sendable (Data) async throws -> Void
  ) async throws {
    throw FTPTransportError.connectionClosed
  }
  func writeFileContents(
    to _: String, chunks _: AsyncThrowingStream<Data, Error>,
    progress _: @escaping @Sendable (Int64) -> Void
  ) async throws {
    throw FTPTransportError.connectionClosed
  }
  func fileSize(at _: String) async throws -> Int64? { nil }
  func setPosixPermissions(_: Int, at _: String) async throws {}
  func isActive() async -> Bool { true }
  func close() async {}
}

private func ftpListingEntry(name: String) -> FTPDirectoryEntry {
  FTPDirectoryEntry(
    name: name, isDirectory: false, isSymbolicLink: false, size: 1,
    modifiedAt: nil, posixPermissions: nil, source: .mlsd)
}
