import Foundation
import Synchronization
import Testing

@testable import PKPane

@MainActor
struct TransferPreparationTests {
  @Test("深いFTPフォルダの公開move経路の開始前列挙と遅延を記録する")
  func measuresRenamePreparation() async throws {
    var samples: [Double] = []
    var counts: [Int] = []
    for _ in 0..<10 {
      let fixture = try await RenamePreparationFixture.make()
      defer { fixture.cleanup() }
      let clock = ContinuousClock()
      let start = clock.now
      fixture.source.move(fixture.source.items, to: fixture.destination)
      await waitUntil { fixture.client.renameStartedAt.withLock { $0 != nil } }
      let renameStart = try #require(fixture.client.renameStartedAt.withLock { $0 })
      let elapsed = start.duration(to: renameStart).components
      samples.append(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
      counts.append(fixture.client.subtreeListingCount.withLock { $0 })
      let job = try await fixture.finishedJob()
      #expect(job.state == .completed)
      #expect(counts.last == 0)
      #expect(job.totalBytes == nil)
    }
    let sorted = samples.sorted()
    let output: [String: Any] = [
      "condition": "Debugモデル経路・実FTPFileProvider・20階層・各列挙2ms注入・10試行",
      "build": "Debug・標準テストホスト", "os": ProcessInfo.processInfo.operatingSystemVersionString,
      "transport": "記録client・実ネットワークなし", "cache": "試行ごとに新規fixture",
      "samplesMilliseconds": samples, "medianMilliseconds": (sorted[4] + sorted[5]) / 2,
      "maximumMilliseconds": sorted[9], "subtreeListingCounts": counts,
    ]
    let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted])
    try data.write(to: URL(filePath: "/private/tmp/pkpane-rv26-10-after.json"))
  }

  @Test("rename失敗と公開再試行も内容列挙や元削除を行わない")
  func renameFailureKeepsPreparationAndRetrySafe() async throws {
    let fixture = try await RenamePreparationFixture.make()
    defer { fixture.cleanup() }
    fixture.client.failsNextRename.withLock { $0 = true }
    fixture.source.move(fixture.source.items, to: fixture.destination)
    let failed = try await fixture.finishedJob()
    #expect(failed.state == .failed)
    #expect(fixture.client.subtreeListingCount.withLock { $0 } == 0)
    #expect(fixture.client.removalCount.withLock { $0 } == 0)
    fixture.source.retryLastTransfer()
    await waitUntil {
      (await fixture.queue.allJobs()).first?.state == .completed && !fixture.source.isTransferring
    }
    #expect(fixture.client.subtreeListingCount.withLock { $0 } == 0)
    #expect(fixture.client.removalCount.withLock { $0 } == 0)
  }

  @Test("同一ボリュームの公開folder moveは実体をrenameし、サイズ目的の子列挙を行わない")
  func localRenameDoesNotEnumerateContents() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = root.appending(path: "src")
    let targetURL = root.appending(path: "dst")
    let treeURL = sourceURL.appending(path: "tree")
    try FileManager.default.createDirectory(at: treeURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true)
    try Data("preserved".utf8).write(to: treeURL.appending(path: "leaf.txt"))
    let provider = CountingLocalPreparationProvider(tree: FileLocation(localURL: treeURL))
    let queue = TransferQueue.isolatedForTesting()
    let source = FileBrowserSession(
      provider: provider, initialLocation: FileLocation(localURL: sourceURL), transferQueue: queue)
    let destination = FileBrowserSession(
      provider: provider, initialLocation: FileLocation(localURL: targetURL), transferQueue: queue)
    defer {
      source.invalidate()
      destination.invalidate()
    }
    source.load()
    destination.load()
    await waitUntil { !source.isLoading && !destination.isLoading && source.items.count == 1 }
    source.move(source.items, to: destination)
    await waitUntil { !source.isTransferring }
    let jobs = await queue.allJobs()
    #expect(try #require(jobs.first).state == .completed)
    #expect(provider.childListingCount.withLock { $0 } == 0)
    #expect(!FileManager.default.fileExists(atPath: treeURL.path))
    #expect(
      try Data(contentsOf: targetURL.appending(path: "tree/leaf.txt")) == Data("preserved".utf8))
  }

  @Test("同一FTPフォルダのコピーは再帰総量集計を維持する")
  func copyKeepsRecursiveByteTotal() async throws {
    let fixture = try await RenamePreparationFixture.make()
    defer { fixture.cleanup() }
    fixture.source.copy(fixture.source.items, to: fixture.destination)
    let job = try await fixture.finishedJob()
    #expect(job.state == .completed)
    #expect(job.totalBytes == 64)
    #expect(fixture.client.subtreeListingCount.withLock { $0 } >= 20)
  }
}

@MainActor
private struct RenamePreparationFixture {
  let source: FileBrowserSession
  let destination: FileBrowserSession
  let queue: TransferQueue
  let client: RenamePreparationFTPClient

  static func make() async throws -> Self {
    let client = RenamePreparationFTPClient()
    let target = try FTPConnectionTarget(host: "preparation.invalid", username: "fixture")
    let provider = FTPFileProvider(target: target, session: client, sessionFactory: { client })
    let queue = TransferQueue.isolatedForTesting()
    let source = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: "/src", providerID: provider.id),
      transferQueue: queue)
    let destination = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(remotePath: "/dst", providerID: provider.id),
      transferQueue: queue)
    source.load()
    destination.load()
    await waitUntil { !source.isLoading && !destination.isLoading && source.items.count == 1 }
    return Self(source: source, destination: destination, queue: queue, client: client)
  }
  func finishedJob() async throws -> TransferJob {
    await waitUntil {
      let jobs = await queue.allJobs()
      return jobs.first?.state.isTerminal == true && !source.isTransferring
    }
    let jobs = await queue.allJobs()
    return try #require(jobs.first)
  }
  func cleanup() {
    source.invalidate()
    destination.invalidate()
  }
}

private final class RenamePreparationFTPClient: FTPClientSession, @unchecked Sendable {
  let subtreeListingCount = Mutex(0)
  let failsNextRename = Mutex(false)
  let removalCount = Mutex(0)
  let renameStartedAt = Mutex<ContinuousClock.Instant?>(nil)

  func contents(of path: String) async throws -> [FTPDirectoryEntry] {
    if path == "/dst" { return [] }
    if path == "/src" { return [entry(name: "tree", directory: true)] }
    guard path.hasPrefix("/src/tree") else { return [] }
    subtreeListingCount.withLock { $0 += 1 }
    try await Task.sleep(for: .milliseconds(2))
    let depth = path.split(separator: "/").count - 2
    return [entry(name: depth < 19 ? "child" : "leaf.bin", directory: depth < 19)]
  }
  private func entry(name: String, directory: Bool) -> FTPDirectoryEntry {
    FTPDirectoryEntry(
      name: name, isDirectory: directory, isSymbolicLink: false,
      size: directory ? nil : 64, modifiedAt: nil, posixPermissions: nil, source: .mlsd)
  }
  func createDirectory(at _: String) async throws {}
  func remove(at _: String, isDirectory _: Bool) async throws { removalCount.withLock { $0 += 1 } }
  func rename(at _: String, to _: String) async throws {
    renameStartedAt.withLock { $0 = ContinuousClock().now }
    let shouldFail = failsNextRename.withLock { value in
      let result = value
      value = false
      return result
    }
    if shouldFail { throw CocoaError(.fileWriteUnknown) }
  }
  func streamFileContents(of _: String, receive: @escaping @Sendable (Data) async throws -> Void)
    async throws
  {
    try await receive(Data(repeating: 0x41, count: 64))
  }
  func writeFileContents(
    to _: String, chunks: AsyncThrowingStream<Data, Error>,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws {
    var bytes: Int64 = 0
    for try await chunk in chunks {
      bytes += Int64(chunk.count)
      progress(bytes)
    }
  }
  func fileSize(at _: String) async throws -> Int64? { 64 }
  func setPosixPermissions(_: Int, at _: String) async throws {}
  func isActive() async -> Bool { true }
  func close() async {}
}

private final class CountingLocalPreparationProvider: FileBrowserTransferProvider,
  @unchecked Sendable
{
  let local = LocalFileProvider()
  let tree: FileLocation
  let childListingCount = Mutex(0)
  let id = FileProviderID.local
  let connectionID: FileProviderConnectionID? = nil
  let capabilities: FileProviderCapabilities = [.read, .write, .moveWithinProvider]
  init(tree: FileLocation) { self.tree = tree }
  func contents(of location: FileLocation) async throws -> [FileItem] {
    if location == tree { childListingCount.withLock { $0 += 1 } }
    return try await local.contents(of: location)
  }
  func parent(of location: FileLocation) -> FileLocation? { local.parent(of: location) }
  func breadcrumbs(for location: FileLocation, constrainedTo root: FileLocation?)
    -> [FileBrowserBreadcrumb]
  {
    local.breadcrumbs(for: location, constrainedTo: root)
  }
  func createDirectory(named name: String, in location: FileLocation) async throws {
    try await local.createDirectory(named: name, in: location)
  }
  func rename(_ item: FileItem, to name: String) async throws {
    try await local.rename(item, to: name)
  }
  func delete(_ item: FileItem) async throws { try await local.delete(item) }
  func move(_ item: FileItem, to location: FileLocation, replacingExisting: Bool) async throws {
    try await local.move(item, to: location, replacingExisting: replacingExisting)
  }
  func copy(_ item: FileItem, to location: FileLocation, replacingExisting: Bool) async throws {
    try await local.copy(item, to: location, replacingExisting: replacingExisting)
  }
  func removeAfterCrossProviderMove(_ item: FileItem) async throws {
    try await local.removeAfterCrossProviderMove(item)
  }
}
