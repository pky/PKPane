import Foundation
import Testing

@testable import PKPane

struct RemotePreviewCacheTests {
  @Test("同一キーへの並行取得は読み込みを一度だけ実行する")
  func coalescesConcurrentLoadsForSameKey() async throws {
    let fixture = try CacheFixture()
    defer { fixture.remove() }
    let cache = RemotePreviewCache(
      rootURL: fixture.root,
      legacyRootURL: fixture.legacyRoot)
    let key = Self.key(path: "/shared.txt")
    let loader = PreviewLoadRecorder()

    async let firstURL = cache.cachedURL(for: key, fileName: "shared.txt") {
      await loader.load()
    }
    async let secondURL = cache.cachedURL(for: key, fileName: "shared.txt") {
      await loader.load()
    }
    let (first, second) = try await (firstURL, secondURL)

    #expect(first == second)
    #expect(await loader.callCount == 1)
  }

  @Test("総量上限を超えると最古のリモートプレビューを削除する")
  func evictsOldestPreviewAboveByteLimit() async throws {
    let fixture = try CacheFixture()
    defer { fixture.remove() }
    let cache = RemotePreviewCache(
      rootURL: fixture.root,
      legacyRootURL: fixture.legacyRoot,
      maximumBytes: 5,
      maximumFileBytes: 5)
    let firstKey = Self.key(path: "/first.txt")
    let secondKey = Self.key(path: "/second.txt")

    let firstURL = try await cache.cachedURL(for: firstKey, fileName: "first.txt") {
      Data(repeating: 1, count: 3)
    }
    let secondURL = try await cache.cachedURL(for: secondKey, fileName: "second.txt") {
      Data(repeating: 2, count: 3)
    }

    #expect(!FileManager.default.fileExists(atPath: firstURL.path))
    #expect(FileManager.default.fileExists(atPath: secondURL.path))
  }

  @Test("既存エントリ照会は未命中時にファイルを作成しない")
  func lookupDoesNotCreateMissingPreview() async throws {
    let fixture = try CacheFixture()
    defer { fixture.remove() }
    let cache = RemotePreviewCache(
      rootURL: fixture.root,
      legacyRootURL: fixture.legacyRoot)

    let cachedURL = await cache.cachedURLIfPresent(for: Self.key(path: "/missing.txt"))

    #expect(cachedURL == nil)
    #expect(!FileManager.default.fileExists(atPath: fixture.root.path))
  }

  @Test("起動時に不正エントリと超過分と旧一時領域を清掃する")
  func cleansInvalidOverflowAndLegacyEntriesAtStartup() async throws {
    let fixture = try CacheFixture()
    defer { fixture.remove() }
    try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: fixture.legacyRoot,
      withIntermediateDirectories: true)
    try Data([0]).write(to: fixture.legacyRoot.appending(path: "old-preview"))
    let oldestURL = fixture.root.appending(path: "\(Self.key(path: "/old.txt").digest).txt")
    let newestURL = fixture.root.appending(path: "\(Self.key(path: "/new.txt").digest).txt")
    let invalidURL = fixture.root.appending(path: "invalid-entry.txt")
    let malformedKeyURL = fixture.root.appending(
      path: "\(Self.key(path: "/malformed.txt").digest).bad.extra")
    try Data(repeating: 1, count: 4).write(to: oldestURL)
    try Data(repeating: 2, count: 4).write(to: newestURL)
    try Data([3]).write(to: invalidURL)
    try Data([4]).write(to: malformedKeyURL)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 100)],
      ofItemAtPath: oldestURL.path)
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 200)],
      ofItemAtPath: newestURL.path)
    let cache = RemotePreviewCache(
      rootURL: fixture.root,
      legacyRootURL: fixture.legacyRoot,
      maximumBytes: 5,
      maximumFileBytes: 5)

    await cache.prepare()

    #expect(!FileManager.default.fileExists(atPath: oldestURL.path))
    #expect(FileManager.default.fileExists(atPath: newestURL.path))
    #expect(!FileManager.default.fileExists(atPath: invalidURL.path))
    #expect(!FileManager.default.fileExists(atPath: malformedKeyURL.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.legacyRoot.path))
  }

  private static func key(path: String) -> RemotePreviewCache.Key {
    RemotePreviewCache.Key(
      connectionID: FileProviderConnectionID(rawValue: "sftp-test"),
      remotePath: path,
      modifiedAt: Date(timeIntervalSince1970: 100),
      size: 3)
  }
}

private actor PreviewLoadRecorder {
  private(set) var callCount = 0

  func load() async -> Data {
    callCount += 1
    try? await Task.sleep(for: .milliseconds(50))
    return Data(repeating: 1, count: 3)
  }
}

private struct CacheFixture {
  let root: URL
  let legacyRoot: URL

  init() throws {
    let base = FileManager.default.temporaryDirectory
      .appending(path: "remote-preview-cache-\(UUID().uuidString)", directoryHint: .isDirectory)
    root = base.appending(path: "RemotePreviews", directoryHint: .isDirectory)
    legacyRoot = base.appending(path: "PKPanePreview", directoryHint: .isDirectory)
  }

  func remove() {
    try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
  }
}
