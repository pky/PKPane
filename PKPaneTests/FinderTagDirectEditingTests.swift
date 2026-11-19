import Darwin
import Foundation
import Testing

@testable import PKPane

@MainActor
struct FinderTagDirectEditingTests {
  @Test("直接設定は未補完の全項目に共通するタグを読み直して削除する")
  func directToggleRemovesCommonTagWithoutErasingIndividualTags() async {
    let provider = DirectFinderTagProvider()
    let root = FileLocation(remotePath: "/root", providerID: provider.id)
    let session = FileBrowserSession(
      provider: provider, initialLocation: root, transferQueue: .isolatedForTesting())
    let items = [
      provider.itemWithUnknownTags(path: "/root/first.txt"),
      provider.itemWithUnknownTags(path: "/root/second.txt"),
    ]

    let result = await session.toggleFinderTag(name: "共通", for: items)

    #expect(result.failedCount == 0)
    #expect(
      provider.recordedTagNames == [
        "/root/first.txt": ["個別A"],
        "/root/second.txt": ["個別B"],
      ])
  }

  @Test("直接設定は混在タグを全項目に追加し各項目の既存タグを保持する")
  func directToggleAddsMixedTagToEntireSelection() async {
    let provider = DirectFinderTagProvider()
    let root = FileLocation(remotePath: "/root", providerID: provider.id)
    let session = FileBrowserSession(
      provider: provider, initialLocation: root, transferQueue: .isolatedForTesting())
    let items = [
      provider.itemWithUnknownTags(path: "/root/first.txt"),
      provider.itemWithUnknownTags(path: "/root/second.txt"),
    ]

    let result = await session.toggleFinderTag(name: "個別A", for: items)

    #expect(result.failedCount == 0)
    #expect(
      provider.recordedTagNames == [
        "/root/second.txt": ["共通", "個別B", "個別A"]
      ])
    #expect(
      result.items.map { $0.tags ?? [] } == [
        ["共通", "個別A"], ["共通", "個別B", "個別A"],
      ])
  }

  @Test("直接設定は単一項目への新規タグ追加と再クリック削除に対応する")
  func directToggleAddsThenRemovesForSingleItem() async {
    let provider = DirectFinderTagProvider()
    let root = FileLocation(remotePath: "/root", providerID: provider.id)
    let session = FileBrowserSession(
      provider: provider, initialLocation: root, transferQueue: .isolatedForTesting())
    let item = provider.itemWithUnknownTags(path: "/root/first.txt")

    let added = await session.toggleFinderTag(name: "新規", for: [item])
    #expect(added.items.first?.tags == ["共通", "個別A", "新規"])
    let removed = await session.toggleFinderTag(name: "新規", for: added.items)
    #expect(removed.failedCount == 0)
    #expect(removed.items.first?.tags == ["共通", "個別A"])
  }

  @Test("直接設定は対象のタグ読取に失敗すると一件も書き込まない")
  func directToggleDoesNotWriteWhenReadingSelectionFails() async {
    let provider = DirectFinderTagProvider(failingReadPath: "/root/second.txt")
    let root = FileLocation(remotePath: "/root", providerID: provider.id)
    let session = FileBrowserSession(
      provider: provider, initialLocation: root, transferQueue: .isolatedForTesting())
    let items = [
      provider.itemWithUnknownTags(path: "/root/first.txt"),
      provider.itemWithUnknownTags(path: "/root/second.txt"),
    ]

    let result = await session.toggleFinderTag(name: "新規", for: items)

    #expect(result.failedCount > 0)
    #expect(result.errorMessage != nil)
    #expect(provider.recordedTagNames.isEmpty)
  }

  @Test("直接設定は一部の書込失敗を集計し成功項目を残す")
  func directToggleReportsPartialWriteFailure() async {
    let provider = DirectFinderTagProvider(failingPath: "/root/second.txt")
    let root = FileLocation(remotePath: "/root", providerID: provider.id)
    let session = FileBrowserSession(
      provider: provider, initialLocation: root, transferQueue: .isolatedForTesting())
    let items = [
      provider.itemWithUnknownTags(path: "/root/first.txt"),
      provider.itemWithUnknownTags(path: "/root/second.txt"),
    ]

    let result = await session.toggleFinderTag(name: "新規", for: items)

    #expect(result.failedCount == 1)
    #expect(provider.recordedTagNames == ["/root/first.txt": ["共通", "個別A", "新規"]])
    #expect(result.items.first?.tags == ["共通", "個別A", "新規"])
  }
  @Test("タグがnilの詳細結果は空タグと区別し直接設定と既存更新の書込を止める")
  func refusesUnknownMetadataWithoutWriting() async {
    let provider = DirectFinderTagProvider(unknownReadPath: "/root/first.txt")
    let root = FileLocation(remotePath: "/root", providerID: provider.id)
    let session = FileBrowserSession(
      provider: provider, initialLocation: root, transferQueue: .isolatedForTesting())
    let item = provider.itemWithUnknownTags(path: "/root/first.txt")

    let direct = await session.toggleFinderTag(name: "新規", for: [item])
    #expect(direct.failedCount == 1)
    #expect(provider.recordedTagNames.isEmpty)

    let existing = await session.updateFinderTags(
      FinderTagMutation(additions: ["新規"], removals: []), for: [item])
    #expect(existing.failedCount == 1)
    #expect(provider.recordedTagNames.isEmpty)
  }

  @Test("実ローカルの無タグファイルとフォルダへ色タグを追加して解除できる")
  func togglesColorForUntaggedLocalFileAndFolder() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let fileURL = rootURL.appendingPathComponent("file.txt")
    let folderURL = rootURL.appendingPathComponent("folder")
    try Data().write(to: fileURL)
    try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: false)
    let provider = LocalFileProvider()
    let session = FileBrowserSession(
      provider: provider, initialLocation: FileLocation(localURL: rootURL),
      transferQueue: .isolatedForTesting())
    let items = [
      FileItem(url: fileURL, isDirectory: false), FileItem(url: folderURL, isDirectory: true),
    ]
    let labels = FinderTagPalette.systemLabelNames
    let name = try #require(
      labels.indices.contains(FinderTagColor.red.rawValue)
        ? labels[FinderTagColor.red.rawValue] : nil)
    try #require(!name.isEmpty)
    for item in items {
      let readBack = try await provider.finderTagNames(at: item.location)
      #expect(readBack == [])
    }

    let added = await session.toggleFinderTag(name: name, for: items)
    #expect(added.failedCount == 0)
    for item in items {
      let readBack = try await provider.finderTagNames(at: item.location)
      if readBack != [name], let url = item.location.localURL {
        diagnoseLocalTags(at: url, readBack: readBack, expected: name)
      }
      #expect(readBack == [name])
    }
    let removed = await session.toggleFinderTag(name: name, for: added.items)
    #expect(removed.failedCount == 0)
    for item in items {
      let readBack = try await provider.finderTagNames(at: item.location)
      #expect(readBack == [])
    }
  }

  private func diagnoseLocalTags(at url: URL, readBack: [String], expected: String) {
    let key = "com.apple.metadata:_kMDItemUserTags"
    let size = getxattr(url.path, key, nil, 0, 0, 0)
    var rawTags: Any = "未取得"
    if size >= 0 {
      var data = Data(count: size)
      let count = data.withUnsafeMutableBytes {
        getxattr(url.path, key, $0.baseAddress, $0.count, 0, 0)
      }
      if count >= 0 {
        rawTags =
          (try? PropertyListSerialization.propertyList(from: Data(data.prefix(count)), format: nil))
          ?? "plist不正"
      }
    } else {
      rawTags = "xattr errno=\(errno)"
    }
    let fresh = URL(fileURLWithPath: url.path)
    var cleared = url
    cleared.removeAllCachedResourceValues()
    let freshNames = try? fresh.resourceValues(forKeys: [.tagNamesKey]).tagNames
    let clearedNames = try? cleared.resourceValues(forKeys: [.tagNamesKey]).tagNames
    print(
      "PKPaneタグ診断 expected=\(expected) readBack=\(readBack) raw=\(rawTags) fresh=\(String(describing: freshNames)) cleared=\(String(describing: clearedNames))"
    )
  }

}

private final class DirectFinderTagProvider: FileBrowserItemDetailProvider,
  FileBrowserFinderTagProvider, @unchecked Sendable
{
  let id = FileProviderID(rawValue: "finder-tags-test")
  let connectionID: FileProviderConnectionID? = nil
  let capabilities: FileProviderCapabilities = [.read, .write, .finderTags]

  private let lock = NSLock()
  private let failingPath: String?
  private let failingReadPath: String?
  private let unknownReadPath: String?
  private var tagsByPath: [String: [String]] = [
    "/root/first.txt": ["共通", "個別A"],
    "/root/second.txt": ["共通", "個別B"],
  ]
  private var recorded: [String: [String]] = [:]

  init(failingPath: String? = nil, failingReadPath: String? = nil, unknownReadPath: String? = nil) {
    self.failingPath = failingPath
    self.failingReadPath = failingReadPath
    self.unknownReadPath = unknownReadPath
  }

  var recordedTagNames: [String: [String]] { lock.withLock { recorded } }

  func contents(of _: FileLocation) async throws -> [FileItem] {
    lock.withLock {
      tagsByPath.keys.sorted().map(makeItem(path:))
    }
  }

  func parent(of _: FileLocation) -> FileLocation? { nil }

  func breadcrumbs(
    for _: FileLocation,
    constrainedTo _: FileLocation?
  ) -> [FileBrowserBreadcrumb] { [] }

  func detailedItem(at location: FileLocation) async throws -> FileItem {
    guard let path = location.remotePath, path != failingReadPath else {
      throw DirectFinderTagTestError.writeDenied
    }
    return lock.withLock { makeItem(path: path) }
  }

  func setFinderTagNames(_ tagNames: [String], at location: FileLocation) async throws {
    guard let path = location.remotePath, path != failingPath else {
      throw DirectFinderTagTestError.writeDenied
    }
    lock.withLock {
      tagsByPath[path] = tagNames
      recorded[path] = tagNames
    }
  }

  func itemWithUnknownTags(path: String) -> FileItem {
    FileItem(
      remotePath: path,
      url: URL(string: "finder-tags-test://host\(path)")!,
      providerID: id,
      isDirectory: false,
      size: 1,
      modifiedAt: Date(timeIntervalSince1970: 1),
      tags: nil)
  }

  private func makeItem(path: String) -> FileItem {
    FileItem(
      remotePath: path,
      url: URL(string: "finder-tags-test://host\(path)")!,
      providerID: id,
      isDirectory: false,
      size: 1,
      modifiedAt: Date(timeIntervalSince1970: 1),
      tags: path == unknownReadPath ? nil : tagsByPath[path] ?? [])
  }
}

private enum DirectFinderTagTestError: LocalizedError {
  case writeDenied

  var errorDescription: String? { "タグを書き込めません。" }
}
