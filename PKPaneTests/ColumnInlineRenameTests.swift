import AppKit
import SwiftUI
import Testing

@testable import PKPane

@MainActor
struct ColumnInlineRenameTests {
  @Test("カラム表示のインラインリネームは元の項目と新しい名前を1回だけ通知する")
  func columnInlineRenameCommitsOriginalItemAndNewNameOnce() throws {
    try expectInlineRenameCommit(in: .column)
  }

  @Test("リスト表示のインラインリネームは元の項目と新しい名前を1回だけ通知する")
  func listInlineRenameCommitsOriginalItemAndNewNameOnce() throws {
    try expectInlineRenameCommit(in: .list)
  }

  private func expectInlineRenameCommit(in mode: FileBrowserViewMode) throws {
    let item = FileItem(url: URL(filePath: "/tmp/a.txt"), isDirectory: false)
    let column = FileBrowserColumn(
      location: FileLocation(localURL: item.url.deletingLastPathComponent()),
      items: [item], selectedItemURLs: [item.url], isLoading: false)
    var options = FileBrowserDisplayOptions()
    options.viewMode = mode
    var committed: [(item: FileItem, name: String)] = []
    let view = FileBrowserContent(
      items: [item],
      selectedItemURLs: .constant([item.url]),
      browserViewMode: mode,
      displayOptions: options,
      gitStatuses: nil,
      nameCell: { item in Text(item.name) },
      contextMenu: { _ in EmptyView() },
      select: { _ in },
      open: { _ in },
      supportsDragging: false,
      isActivePane: { true },
      onCommitInlineRename: { item, name in committed.append((item, name)) },
      columns: [column],
      onSelectColumnItems: { _, _ in })
    let hosting = NSHostingView(rootView: view.frame(width: 400, height: 300))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentView = hosting
    hosting.layoutSubtreeIfNeeded()

    let table = try #require(findTable(in: hosting))
    let coordinator = try #require(table.delegate as? FileListView<Text, EmptyView>.Coordinator)
    table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    table.layoutSubtreeIfNeeded()
    coordinator.beginInlineRename(atRow: 0)
    let editor = try #require(window.firstResponder as? NSTextView)
    #expect(editor.isFieldEditor)

    // キーウインドウに依存せず、このテストのフィールドエディタへ入力を届ける。
    for (characters, keyCode) in [("x", UInt16(7)), ("y", 16), ("\r", 36)] {
      let event = try keyEvent(characters, keyCode: keyCode, window: window)
      window.sendEvent(event)
      if characters == "y" {
        #expect(editor.string == "xy.txt")
      }
    }

    try #require(committed.count == 1)
    #expect(committed[0].item == item)
    #expect(committed[0].name == "xy.txt")
  }

  private func keyEvent(
    _ characters: String, keyCode: UInt16, window: NSWindow
  ) throws -> NSEvent {
    try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
  }

  private func findTable(in view: NSView) -> NSTableView? {
    if let table = view as? NSTableView { return table }
    for subview in view.subviews {
      if let table = findTable(in: subview) { return table }
    }
    return nil
  }
}
