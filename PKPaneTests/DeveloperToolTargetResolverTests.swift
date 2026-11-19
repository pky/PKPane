import Foundation
import Testing

@testable import PKPane

struct DeveloperToolTargetResolverTests {
  @Test("フォルダ選択時はそのフォルダをターミナル対象にする")
  func terminalUsesSelectedDirectory() {
    let root = localURL("root")
    let directory = FileItem(url: root.appending(path: "folder"), isDirectory: true)

    #expect(
      DeveloperToolTargetResolver.terminalDirectory(
        selectedItems: [directory], currentLocation: FileLocation(localURL: root))
        == directory.url)
  }

  @Test("未選択時は現在のフォルダをターミナル対象にする")
  func terminalUsesCurrentDirectoryWithoutSelection() {
    let root = localURL("root")

    #expect(
      DeveloperToolTargetResolver.terminalDirectory(
        selectedItems: [], currentLocation: FileLocation(localURL: root)) == root)
  }

  @Test("複数選択時は一覧順の先頭項目をターミナル対象にする")
  func terminalUsesFirstSelectedItem() {
    let root = localURL("root")
    let first = FileItem(url: root.appending(path: "first"), isDirectory: true)
    let second = FileItem(url: root.appending(path: "second"), isDirectory: true)

    #expect(
      DeveloperToolTargetResolver.terminalDirectory(
        selectedItems: [first, second], currentLocation: FileLocation(localURL: root))
        == first.url)
  }

  @Test("ファイル選択時は親フォルダをターミナル対象にする")
  func terminalUsesParentOfSelectedFile() {
    let root = localURL("root")
    let file = FileItem(url: root.appending(path: "file.txt"), isDirectory: false)

    let resolved = DeveloperToolTargetResolver.terminalDirectory(
      selectedItems: [file], currentLocation: FileLocation(localURL: root))
    #expect(resolved?.path == root.path)
  }

  @Test("SFTPではターミナル対象を解決しない")
  func terminalRejectsRemoteLocation() {
    let providerID = FileProviderID(rawValue: "sftp:test")
    let location = FileLocation(remotePath: "/home/test", providerID: providerID)
    let item = FileItem(
      remotePath: "/home/test/folder", url: URL(string: "sftp://example/folder")!,
      providerID: providerID, isDirectory: true)

    #expect(
      DeveloperToolTargetResolver.terminalDirectory(
        selectedItems: [item], currentLocation: location) == nil)
    #expect(
      DeveloperToolTargetResolver.terminalDirectory(
        selectedItems: [], currentLocation: location) == nil)
  }

  private func localURL(_ name: String) -> URL {
    URL(fileURLWithPath: "/tmp/developer-tool-tests/\(name)")
  }
}
