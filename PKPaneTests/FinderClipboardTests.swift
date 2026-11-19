import AppKit
import Foundation
import Testing
import ZIPFoundation

@testable import PKPane

@MainActor
struct FinderClipboardTests {
  @Test("ファイルURLを順番どおり専用pasteboardと交換できる")
  func exchangesFileURLsWithoutGeneralPasteboard() {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let clipboard = SystemFileClipboard(pasteboard: board)
    let urls = [URL(filePath: "/tmp/日本語.txt"), URL(filePath: "/tmp/second.txt")]
    let previous = clipboard.changeCount
    clipboard.write(urls)
    #expect(clipboard.changeCount != previous)
    #expect(clipboard.fileURLs == urls)
    board.clearContents()
    board.setString("文字列", forType: .string)
    #expect(clipboard.fileURLs.isEmpty)
  }

  @Test("外部clipboardを連続コピーし、移動成功後は再利用しない")
  func copiesExternalFilesRepeatedlyAndConsumesSuccessfulMove() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let clipboard = MemoryFileClipboard()
    clipboard.write([fixture.file])
    let destination = fixture.browser(at: fixture.destination)
    let workspace = FileWorkspaceModel(initialBrowser: destination, fileClipboard: clipboard)
    destination.load()
    await waitUntil { !destination.isLoading }
    workspace.pasteItems()
    let copied = fixture.destination.appending(path: "source.txt")
    await waitUntil { FileManager.default.fileExists(atPath: copied.path) }
    #expect(try Data(contentsOf: copied) == Data("保全".utf8))
    #expect(FileManager.default.fileExists(atPath: fixture.file.path))
    #expect(workspace.canPasteItems)
    let second = fixture.root.appending(path: "second", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    let next = fixture.browser(at: second)
    workspace.replaceActiveBrowser(with: next)
    workspace.pasteItems(moving: true)
    await waitUntil { !FileManager.default.fileExists(atPath: fixture.file.path) }
    await waitUntil { !workspace.canPasteItems }
    #expect(FileManager.default.fileExists(atPath: second.appending(path: "source.txt").path))
  }

  @Test("外部更新は古い内部clipboardより優先される")
  func externalUpdateInvalidatesInternalClipboard() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let clipboard = MemoryFileClipboard()
    let source = fixture.browser(at: fixture.source)
    let workspace = FileWorkspaceModel(initialBrowser: source, fileClipboard: clipboard)
    let active = workspace.activeTab.browser
    active.load()
    await waitUntil { !active.isLoading }
    workspace.activeTab.selectedItemURLs = [fixture.file]
    workspace.copySelectedItems()
    #expect(clipboard.fileURLs == [fixture.file])
    clipboard.write([])
    #expect(!workspace.canPasteItems)
  }

  @Test("存在しない外部ファイルの移動はエラーとなりclipboardを保持する")
  func missingExternalFileDoesNotConsumeClipboard() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let clipboard = MemoryFileClipboard()
    clipboard.write([fixture.root.appending(path: "missing")])
    let workspace = FileWorkspaceModel(
      initialBrowser: fixture.browser(at: fixture.destination), fileClipboard: clipboard)
    workspace.pasteItems(moving: true)
    #expect(workspace.activeTab.browser.errorMessage != nil)
    #expect(workspace.canPasteItems)
    #expect(FileManager.default.fileExists(atPath: fixture.file.path))
  }

  @Test("フォルダaliasを内部で開き、オリジナル表示も内部一覧へ移動する")
  func opensAndRevealsFolderAliasInternally() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let alias = fixture.source.appending(path: "folder alias")
    let data = try fixture.destination.bookmarkData(
      options: .suitableForBookmarkFile,
      includingResourceValuesForKeys: nil, relativeTo: nil)
    try URL.writeBookmarkData(data, to: alias)
    let item = try LocalFileProvider().item(at: alias)
    #expect(item.isAliasFile)
    let browser = fixture.browser(at: fixture.source)
    browser.open(item)
    await waitUntil { !browser.isLoading }
    #expect(
      browser.currentLocation.localURL?.resolvingSymlinksInPath()
        == fixture.destination.resolvingSymlinksInPath())
    browser.showOriginal(item)
    await waitUntil { !browser.isLoading }
    #expect(
      browser.currentLocation.localURL?.resolvingSymlinksInPath()
        == fixture.root.resolvingSymlinksInPath())
    #expect(
      browser.revealRequest?.itemURL.resolvingSymlinksInPath()
        == fixture.destination.resolvingSymlinksInPath())
  }

  @Test("外部clipboard更新でメニューと実行がその場で再評価される")
  func menuRevalidatesExternalClipboard() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let clipboard = MemoryFileClipboard()
    let workspace = FileWorkspaceModel(
      initialBrowser: fixture.browser(at: fixture.destination), fileClipboard: clipboard)
    let menu = AppMenuModel()
    menu.register(
      context: AppMenuContext(isBrowserAvailable: true),
      perform: { action in
        if case .paste = action { workspace.pasteItems() }
      }, canPaste: { workspace.canPasteItems(to: workspace.activeTab.browser) })
    #expect(!menu.isEnabled(.paste))
    clipboard.write([fixture.file])
    #expect(menu.isEnabled(.paste))
    clipboard.write([])
    #expect(!menu.isEnabled(.paste))
  }

  @Test("複数フォルダを開いても反対ペインを上書きしない")
  func opensAdditionalFoldersThroughWindowBoundary() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let second = fixture.source.appending(path: "second", directoryHint: .isDirectory)
    let first = fixture.source.appending(path: "first", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    let workspace = FileWorkspaceModel(initialBrowser: fixture.browser(at: fixture.source))
    let browser = workspace.activeTab.browser
    let opposite = try #require(workspace.tab(for: workspace.activePane.opposite))
    let previous = opposite.browser.currentLocation
    browser.load()
    await waitUntil { !browser.isLoading }
    workspace.activeTab.selectedItemURLs = [first, second]
    var opened: [FileLocation] = []
    workspace.onOpenAdditionalFolder = {
      opened.append($0)
      return true
    }
    workspace.openSelectedItem(in: workspace.activePane)
    await waitUntil { !browser.isLoading }
    #expect(opened.count == 1)
    #expect(
      Set([browser.currentLocation.localURL, opened.first?.localURL].compactMap { $0 }) == [
        first, second,
      ])
    #expect(opposite.browser.currentLocation == previous)
  }

  @Test("複数ZIPと連続した開くは全件を順に処理する", arguments: [false, true])
  func opensMultipleZIPsSequentially(repeatedRequests: Bool) async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let payload = fixture.source.appending(path: "payload")
    try Data("zip内容".utf8).write(to: payload)
    let urls = [
      fixture.source.appending(path: "one.zip"), fixture.source.appending(path: "two.zip"),
    ]
    for (index, url) in urls.enumerated() {
      let archive = try Archive(url: url, accessMode: .create)
      try archive.addEntry(with: "result\(index).txt", fileURL: payload)
    }
    let workspace = FileWorkspaceModel(initialBrowser: fixture.browser(at: fixture.source))
    let browser = workspace.activeTab.browser
    browser.load()
    await waitUntil { !browser.isLoading }
    workspace.activeTab.selectedItemURLs = Set(urls)
    if repeatedRequests {
      for url in urls {
        let item = try #require(browser.selectableItemsSnapshot.item(for: url))
        browser.openItems([item])
      }
    } else {
      workspace.openSelectedItem(in: workspace.activePane)
    }
    await waitUntil {
      FileManager.default.fileExists(atPath: fixture.source.appending(path: "result0.txt").path)
        && FileManager.default.fileExists(
          atPath: fixture.source.appending(path: "result1.txt").path)
        && !browser.isArchiving
    }
    #expect(browser.errorMessage == nil)
    #expect(urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
  }

  @Test("壊れたaliasは外部へ渡さずエラーを表示する")
  func brokenAliasReportsError() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let alias = fixture.source.appending(path: "broken")
    let data = try fixture.destination.bookmarkData(
      options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
    try URL.writeBookmarkData(data, to: alias)
    let item = try LocalFileProvider().item(at: alias)
    try FileManager.default.removeItem(at: fixture.destination)
    let browser = fixture.browser(at: fixture.source)
    browser.open(item)
    #expect(browser.errorMessage != nil)
    #expect(browser.currentLocation.localURL == fixture.source)
  }

  @Test("既存の⌘Rカスタム割当を新規オリジナル表示が奪わない")
  func preservesExistingCommandRCustomization() throws {
    let map = KeyboardCommandMap.defaults.replacingBindings(
      for: .refresh,
      with: KeymapShortcut(key: "r", modifiers: [.command]))
    let encoded = try JSONEncoder().encode(map)
    let entries = try #require(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
    let legacy = entries.filter { $0["command"] as? String != "showOriginal" }
    let decoded = try JSONDecoder().decode(
      KeyboardCommandMap.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(
      decoded.bindings(for: .refresh).map(\.shortcut) == [
        KeymapShortcut(key: "r", modifiers: [.command])
      ])
    #expect(decoded.bindings(for: .showOriginal).isEmpty)
    let roundTrip = try JSONDecoder().decode(
      KeyboardCommandMap.self, from: JSONEncoder().encode(decoded))
    #expect(roundTrip == decoded)
  }

  @Test("別窓の更新と終了で前面窓のメニューを変更しない")
  func menuRegistrationBelongsToCurrentWindow() {
    let menu = AppMenuModel()
    let first = UUID()
    let second = UUID()
    var commands: [String] = []
    menu.register(
      context: AppMenuContext(isBrowserAvailable: true, selectedItemCount: 1),
      perform: { _ in commands.append("first") }, ownerID: first)
    menu.register(
      context: AppMenuContext(isBrowserAvailable: true, selectedItemCount: 2),
      perform: { _ in commands.append("second") }, ownerID: second)
    menu.update(context: .unavailable, ownerID: first)
    menu.unregister(ownerID: first)
    #expect(menu.isRegisteredWindow(ownerID: second))
    #expect(menu.isEnabled(.openSelectedItem))
    menu.perform(.openSelectedItem)
    #expect(commands == ["second"])
    menu.unregister(ownerID: second)
    #expect(!menu.isEnabled(.openSelectedItem))
  }

  @Test("外部移動の同名衝突を既存確認へ出し、キャンセルで両方を保持する")
  func externalMoveConflictPreservesBothFiles() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let existing = fixture.destination.appending(path: "source.txt")
    try Data("既存".utf8).write(to: existing)
    let clipboard = MemoryFileClipboard()
    clipboard.write([fixture.file])
    let browser = fixture.browser(at: fixture.destination)
    browser.load()
    await waitUntil { !browser.isLoading }
    let workspace = FileWorkspaceModel(initialBrowser: browser, fileClipboard: clipboard)
    workspace.pasteItems(moving: true)
    await waitUntil { workspace.pendingTransferConflictBrowser != nil }
    let source = try #require(workspace.pendingTransferConflictBrowser)
    source.resolvePendingTransferConflict(.cancel, applyToRemaining: false)
    #expect(try Data(contentsOf: fixture.file) == Data("保全".utf8))
    #expect(try Data(contentsOf: existing) == Data("既存".utf8))
    #expect(workspace.canPasteItems)
  }

  @Test("重複外部URLを1件へまとめて転送する")
  func deduplicatesExternalURLs() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let clipboard = MemoryFileClipboard()
    clipboard.write([fixture.file, fixture.file])
    let workspace = FileWorkspaceModel(
      initialBrowser: fixture.browser(at: fixture.destination), fileClipboard: clipboard)
    workspace.pasteItems()
    await waitUntil {
      FileManager.default.fileExists(atPath: fixture.destination.appending(path: "source.txt").path)
    }
    #expect(FileManager.default.fileExists(atPath: fixture.file.path))
  }

  @Test("同じフォルダへの外部pasteエラーを表示対象へ届ける")
  func exposesExternalPreparationErrors() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let clipboard = MemoryFileClipboard()
    clipboard.write([fixture.file])
    let workspace = FileWorkspaceModel(
      initialBrowser: fixture.browser(at: fixture.source), fileClipboard: clipboard)
    workspace.pasteItems(moving: true)
    #expect(workspace.fileOperationErrorBrowser?.errorMessage != nil)
    #expect(FileManager.default.fileExists(atPath: fixture.file.path))
    #expect(workspace.canPasteItems)
  }

  @Test("複数親フォルダの外部ファイルをすべてコピーする")
  func copiesFilesFromMultipleParents() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let secondParent = fixture.root.appending(path: "other", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: secondParent, withIntermediateDirectories: true)
    let second = secondParent.appending(path: "other.txt")
    try Data("別の親".utf8).write(to: second)
    let clipboard = MemoryFileClipboard()
    clipboard.write([fixture.file, second])
    let workspace = FileWorkspaceModel(
      initialBrowser: fixture.browser(at: fixture.destination), fileClipboard: clipboard)
    workspace.pasteItems()
    await waitUntil {
      FileManager.default.fileExists(atPath: fixture.destination.appending(path: "source.txt").path)
        && FileManager.default.fileExists(
          atPath: fixture.destination.appending(path: "other.txt").path)
    }
    #expect(try Data(contentsOf: second) == Data("別の親".utf8))
    #expect(FileManager.default.fileExists(atPath: fixture.file.path))
  }

  @Test("共有外へ向くaliasを元のNAS Providerで開かない")
  func rejectsMountedAliasOutsideVolume() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let alias = fixture.source.appending(path: "outside alias")
    let data = try fixture.destination.bookmarkData(
      options: .suitableForBookmarkFile,
      includingResourceValuesForKeys: nil, relativeTo: nil)
    try URL.writeBookmarkData(data, to: alias)
    let provider = MountedVolumeProvider(volumeURL: fixture.source)
    let item = try LocalFileProvider().item(at: alias, providerID: provider.id)
    let browser = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(localURL: fixture.source, providerID: provider.id),
      transferQueue: .isolatedForTesting())
    browser.open(item)
    #expect(browser.errorMessage != nil)
    #expect(browser.currentLocation.localURL == fixture.source)
    browser.clearError()
    browser.showOriginal(item)
    #expect(browser.errorMessage != nil)
    #expect(browser.currentLocation.localURL == fixture.source)
  }

  @Test("展開取消と破棄で待機中の開くも停止する", arguments: [false, true])
  func cancelsPendingOpenBatch(invalidates: Bool) async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let browser = fixture.browser(at: fixture.source)
    let zip = fixture.source.appending(path: "broken.zip")
    try Data("無効なZIP".utf8).write(to: zip)
    browser.openItems([try LocalFileProvider().item(at: zip)])
    if invalidates { browser.invalidate() } else { browser.cancelArchiveOperation() }
    await Task.yield()
    #expect(!browser.isArchiving)
    #expect(browser.errorMessage == nil)
  }

  @MainActor
  private struct Fixture {
    let root: URL
    let source: URL
    let destination: URL
    let file: URL
    init() throws {
      root = FileManager.default.temporaryDirectory.appending(
        path: UUID().uuidString, directoryHint: .isDirectory)
      source = root.appending(path: "source", directoryHint: .isDirectory)
      destination = root.appending(path: "destination", directoryHint: .isDirectory)
      file = source.appending(path: "source.txt")
      try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
      try Data("保全".utf8).write(to: file)
    }
    func browser(at url: URL) -> FileBrowserSession {
      FileBrowserSession(
        provider: LocalFileProvider(),
        initialLocation: FileLocation(localURL: url, providerID: .local),
        transferQueue: .isolatedForTesting())
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
  }
}
