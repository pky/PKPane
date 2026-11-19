import Foundation
import Synchronization
import Testing

@testable import PKPane

struct MountedVolumeProviderTests {
  @Test("NAS書き込みは8MBまたは200msごとに同期する")
  func batchesSMBProgressSynchronization() {
    var batcher = SMBTransferProgressBatcher()

    batcher.record(7 * 1_024 * 1_024)
    #expect(!batcher.requiresSynchronization(after: .milliseconds(199)))
    #expect(batcher.requiresSynchronization(after: .milliseconds(200)))
    #expect(batcher.acknowledge() == 7 * 1_024 * 1_024)

    batcher.record(8 * 1_024 * 1_024)
    #expect(batcher.requiresSynchronization(after: .zero))
    #expect(batcher.acknowledge() == 8 * 1_024 * 1_024)
    #expect(!batcher.hasPendingBytes)
  }

  @Test("NAS Providerは共通のFileLocationで一覧と同一Provider内移動を扱う")
  func supportsBrowserAndTransferContracts() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let archive = root.appending(path: "Archive", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
    let report = root.appending(path: "report.txt")
    try Data("内容".utf8).write(to: report)
    let profile = try NASConnectionProfile(
      displayName: "テストNAS", host: "nas.example.local", shareName: "Documents")
    let provider = MountedVolumeProvider(profile: profile, volumeURL: root)
    let rootLocation = FileLocation(localURL: root, providerID: provider.id)

    #expect(provider.capabilities.contains(.trash))
    let items = try await provider.contents(of: rootLocation)
    let item = try #require(items.first(where: { $0.name == "report.txt" }))

    try await provider.move(
      item,
      to: FileLocation(localURL: archive, providerID: provider.id))

    #expect(FileManager.default.fileExists(atPath: archive.appending(path: "report.txt").path))
    #expect(provider.parent(of: rootLocation) == nil)
  }

  @Test("NAS上書き移動のコピー失敗時は既存宛先と移動元を保持する")
  func replacingMoveFailureKeepsExistingDestinationAndSource() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceDirectory = root.appending(path: "source", directoryHint: .isDirectory)
    let destinationDirectory = root.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: sourceDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: destinationDirectory, withIntermediateDirectories: true)
    let source = sourceDirectory.appending(path: "report.txt")
    let destination = destinationDirectory.appending(path: "report.txt")
    try Data("新しい内容".utf8).write(to: source)
    try Data("既存内容".utf8).write(to: destination)
    let keptDuringCopy = Mutex(false)
    let localProvider = LocalFileProvider(
      isOnSameVolumeOverride: { _, _ in false },
      crossVolumeMoveCopy: { _, temporaryURL, _ in
        keptDuringCopy.withLock {
          $0 = (try? Data(contentsOf: destination)) == Data("既存内容".utf8)
        }
        try Data("途中内容".utf8).write(to: temporaryURL)
        throw CancellationError()
      })
    let provider = MountedVolumeProvider(volumeURL: root, localProvider: localProvider)
    let item = try provider.item(at: source)

    await #expect(throws: CancellationError.self) {
      try await provider.move(
        item,
        to: FileLocation(localURL: destinationDirectory, providerID: provider.id),
        replacingExisting: true)
    }

    #expect(keptDuringCopy.withLock { $0 })
    #expect(try Data(contentsOf: destination) == Data("既存内容".utf8))
    #expect(try Data(contentsOf: source) == Data("新しい内容".utf8))
  }

  @Test("NAS Providerは共通ストリーム転送でファイル内容を複製できる")
  func streamsFileDataThroughCommonTransferService() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let sourceURL = root.appending(path: "source.txt")
    let destinationURL = root.appending(path: "copy.txt")
    let contents = Data("NASからのストリーム転送".utf8)
    try contents.write(to: sourceURL)
    let profile = try NASConnectionProfile(
      displayName: "テストNAS", host: "nas.example.local", shareName: "Documents")
    let provider = MountedVolumeProvider(profile: profile, volumeURL: root)
    let rootLocation = FileLocation(localURL: root, providerID: provider.id)
    let sourceItem = try #require(try await provider.contents(of: rootLocation).first)

    try await ProviderFileTransferService().copy(
      item: sourceItem,
      from: provider,
      to: FileLocation(localURL: destinationURL, providerID: provider.id),
      using: provider)

    #expect(try Data(contentsOf: destinationURL) == contents)
  }

  @Test("帯域制限中のNAS同一シェア内コピーはカーネル高速パスを使わない")
  func limitedSameShareCopyUsesChunkFallback() async throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let destination = root.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let source = root.appending(path: "source.bin")
    let contents = Data(repeating: 0x4E, count: 1_024)
    try contents.write(to: source)
    let clock = VirtualTransferClock()
    let limiter = TransferRateLimiter(
      bytesPerSecond: 1_024,
      now: { clock.now },
      sleep: { duration in try await clock.sleep(for: duration) })
    let fastPathCalls = Mutex(0)
    let localProvider = LocalFileProvider(
      cancellableCopy: { sourceURL, destinationURL, isCancelled, progress in
        try CancellableFileCopier.copy(
          from: sourceURL,
          to: destinationURL,
          isCancelled: isCancelled,
          progress: progress,
          cloneAttempt: { _, _ in
            fastPathCalls.withLock { $0 += 1 }
            return false
          },
          copyfileAttempt: { _, _ in
            fastPathCalls.withLock { $0 += 1 }
            return false
          },
          rateLimiter: limiter,
          volumeIsLocal: { _ in false })
      })
    let provider = MountedVolumeProvider(volumeURL: root, localProvider: localProvider)
    let item = try provider.item(at: source)

    try await (provider as any FileBrowserProgressTransferProvider).copy(
      item,
      to: FileLocation(localURL: destination, providerID: provider.id),
      progress: { _ in })

    #expect(fastPathCalls.withLock { $0 } == 0)
    #expect(clock.elapsedSeconds == 1)
    #expect(try Data(contentsOf: destination.appending(path: "source.bin")) == contents)
  }
}
