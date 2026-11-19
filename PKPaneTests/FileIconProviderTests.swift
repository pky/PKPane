import AppKit
import Testing

@testable import PKPane

@MainActor
struct FileIconProviderTests {
  @Test("同じ拡張子のアイコンはキャッシュから同一インスタンスが返る")
  func cachesIconByExtension() {
    let provider = FileIconProvider()
    let first = FileItem(
      url: URL(fileURLWithPath: "/tmp/a.txt"), isDirectory: false)
    let second = FileItem(
      url: URL(fileURLWithPath: "/tmp/b.txt"), isDirectory: false)
    let firstIcon = provider.icon(for: first)
    let secondIcon = provider.icon(for: second)
    #expect(firstIcon === secondIcon)
  }

  @Test("フォルダとファイルで異なるアイコンが返る")
  func distinguishesFolderFromFile() {
    let provider = FileIconProvider()
    let folder = FileItem(
      url: URL(fileURLWithPath: "/tmp/folder", isDirectory: true), isDirectory: true)
    let file = FileItem(
      url: URL(fileURLWithPath: "/tmp/file.txt"), isDirectory: false)
    let folderIcon = provider.icon(for: folder)
    let fileIcon = provider.icon(for: file)
    #expect(folderIcon !== fileIcon)
  }

  @Test(".appのresolvedIconは実アイコンを返す")
  func resolvesRealIconForApplicationBundle() async {
    let provider = FileIconProvider()
    let calculatorURL = URL(fileURLWithPath: "/System/Applications/Calculator.app")
    let item = FileItem(url: calculatorURL, isDirectory: true)
    let resolved = await provider.resolvedIcon(for: item, size: NSSize(width: 32, height: 32))
    #expect(resolved != nil)
    #expect(provider.cachedResolvedIcon(for: item, size: NSSize(width: 32, height: 32)) != nil)

    provider.removeAll()

    #expect(provider.cachedResolvedIcon(for: item, size: NSSize(width: 32, height: 32)) == nil)
  }

  @Test("リモート(sftp)URLはresolvedIconがnilを返す")
  func returnsNilForRemoteURL() async throws {
    let provider = FileIconProvider()
    let remoteURL = try #require(URL(string: "sftp://host/path/file.txt"))
    let item = FileItem(
      remotePath: "/path/file.txt", url: remoteURL, providerID: FileProviderID(rawValue: "sftp"),
      isDirectory: false)
    let resolved = await provider.resolvedIcon(for: item, size: NSSize(width: 32, height: 32))
    #expect(resolved == nil)
  }

  @Test("シンボリックリンクは実体の種別に関わらずlinkシンボルのアイコンを返す")
  func returnsLinkIconForSymbolicLink() async {
    let provider = FileIconProvider()
    let symbolicLinkToFolder = FileItem(
      url: URL(fileURLWithPath: "/tmp/link-to-folder"), isDirectory: true, isSymbolicLink: true)
    let symbolicLinkToFile = FileItem(
      url: URL(fileURLWithPath: "/tmp/link-to-file.txt"), isDirectory: false,
      isSymbolicLink: true)
    let regularFile = FileItem(url: URL(fileURLWithPath: "/tmp/plain.txt"), isDirectory: false)

    let linkIcon = provider.icon(for: symbolicLinkToFolder)
    // 実体がフォルダでもファイルでも、シンボリックリンクである限り同じlinkシンボルを返す。
    #expect(linkIcon === provider.icon(for: symbolicLinkToFile))
    #expect(linkIcon !== provider.icon(for: regularFile))

    // resolvedIconはリンク系を対象外とし、実体の実アイコン・サムネイルへ差し替えない。
    let resolved = await provider.resolvedIcon(
      for: symbolicLinkToFolder, size: NSSize(width: 32, height: 32))
    #expect(resolved == nil)
  }

  @Test("解決不能だったURLは既知失敗として記録されTaskの再試行を避けられる")
  func marksUnresolvableAfterFailedResolution() async throws {
    let provider = FileIconProvider()
    let url = FileManager.default.temporaryDirectory.appending(
      path: "unresolvable-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("plain text".utf8).write(to: url)
    let item = FileItem(url: url, isDirectory: false)

    #expect(provider.isKnownUnresolvable(for: item, size: NSSize(width: 32, height: 32)) == false)
    let resolved = await provider.resolvedIcon(for: item, size: NSSize(width: 32, height: 32))
    #expect(resolved == nil)
    #expect(provider.isKnownUnresolvable(for: item, size: NSSize(width: 32, height: 32)) == true)
  }

  @Test("同じ項目でも要求サイズが異なればキャッシュが別エントリになる")
  func cachesResolvedIconSeparatelyPerRequestedSize() async {
    let provider = FileIconProvider()
    let calculatorURL = URL(fileURLWithPath: "/System/Applications/Calculator.app")
    let item = FileItem(url: calculatorURL, isDirectory: true)

    _ = await provider.resolvedIcon(for: item, size: NSSize(width: 32, height: 32))
    #expect(provider.cachedResolvedIcon(for: item, size: NSSize(width: 32, height: 32)) != nil)
    #expect(provider.cachedResolvedIcon(for: item, size: NSSize(width: 128, height: 128)) == nil)

    _ = await provider.resolvedIcon(for: item, size: NSSize(width: 128, height: 128))
    #expect(provider.cachedResolvedIcon(for: item, size: NSSize(width: 32, height: 32)) != nil)
    #expect(provider.cachedResolvedIcon(for: item, size: NSSize(width: 128, height: 128)) != nil)
  }

  @Test("取り消した実アイコン解決を解決不能として記録しない")
  func cancellationDoesNotMarkResolutionAsFailed() async {
    let provider = FileIconProvider()
    let item = FileItem(
      url: URL(fileURLWithPath: "/tmp/cancelled-preview.png"), isDirectory: false)
    let size = NSSize(width: 32, height: 32)
    let task = Task { @MainActor in
      await provider.resolvedIcon(for: item, size: size)
    }

    task.cancel()
    _ = await task.value

    #expect(!provider.isKnownUnresolvable(for: item, size: size))
  }
}
