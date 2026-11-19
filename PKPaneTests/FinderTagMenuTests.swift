import AppKit
import Foundation
import SwiftUI
import Testing

@testable import PKPane

struct FinderTagMenuTests {
  private let labels = ["None", "Gray", "Green", "Purple", "Blue", "Yellow", "Red", "Orange"]

  @Test("直接設定の色タグはFinderと同じ7色順で名前を対応させる")
  func presentsSevenColorsInFinderOrder() {
    let item = FileItem(url: URL(filePath: "/tmp/file"), isDirectory: false, tags: [])

    let choices = FinderTagMenuModel.choices(
      for: [item], standardLabelNames: labels, canEdit: true)

    #expect(choices.map(\.color) == [.red, .orange, .yellow, .green, .blue, .purple, .gray])
    #expect(choices.map(\.name) == ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"])
    #expect(choices.allSatisfy { $0.isEnabled })
    #expect(choices.allSatisfy { !$0.isSelected })
  }

  @Test("複数選択では全項目に付いた色だけを選択済みにする")
  func marksOnlyCommonTagsSelected() {
    let file = FileItem(
      url: URL(filePath: "/tmp/file"), isDirectory: false, tags: ["Red", "Blue"])
    let folder = FileItem(
      url: URL(filePath: "/tmp/folder"), isDirectory: true, tags: ["Red", "独自"])

    let choices = FinderTagMenuModel.choices(
      for: [file, folder], standardLabelNames: labels, canEdit: true)

    #expect(choices.filter(\.isSelected).map(\.name) == ["Red"])
  }

  @Test("未補完と空選択は選択済み扱いにせず非対応には理由を付ける")
  func disablesUnsupportedChoicesWithReason() {
    let item = FileItem(url: URL(filePath: "/tmp/file"), isDirectory: false, tags: nil)
    let unsupported = FinderTagMenuModel.choices(
      for: [item], standardLabelNames: labels, canEdit: false)
    let empty = FinderTagMenuModel.choices(
      for: [], standardLabelNames: labels, canEdit: true)

    #expect(unsupported.count == 7)
    #expect(unsupported.allSatisfy { !$0.isEnabled && $0.disabledReason?.isEmpty == false })
    #expect(unsupported.allSatisfy { !$0.isSelected })
    #expect(empty.allSatisfy { !$0.isEnabled && !$0.isSelected })
  }
  @MainActor
  @Test("ファイルメニューのタグ編集は選択とProvider能力に応じて有効になる")
  func menuBarTagEditorRequiresSupportedSelection() {
    let model = AppMenuModel()
    var actions: [FileBrowserCommand.Action] = []
    model.register(
      context: AppMenuContext(
        isBrowserAvailable: true, selectedItemCount: 2, canEditFinderTags: true)
    ) { actions.append($0) }

    #expect(model.isEnabled(.editFinderTags))
    #expect(model.menuTitle(for: .editFinderTags) == "タグ…")
    model.perform(.editFinderTags)
    #expect(actions.count == 1)

    model.register(
      context: AppMenuContext(
        isBrowserAvailable: true, selectedItemCount: 2, canEditFinderTags: false)
    ) { actions.append($0) }
    #expect(!model.isEnabled(.editFinderTags))
    model.perform(.editFinderTags)
    #expect(actions.count == 1)

    model.register(
      context: AppMenuContext(
        isBrowserAvailable: true, selectedItemCount: 0, canEditFinderTags: true)
    ) { actions.append($0) }
    #expect(!model.isEnabled(.editFinderTags))
  }

  @MainActor
  @Test("リストとカラムは7色の標準パレットと選択状態と実行対象を保つ", arguments: [FileBrowserViewMode.list, .column])
  func nativePaletteKeepsChoicesStateAndActions(mode: FileBrowserViewMode) throws {
    let item = FileItem(url: URL(filePath: "/tmp/tagged-file"), isDirectory: false, tags: ["Red"])
    let choices = FinderTagMenuModel.choices(for: [item], standardLabelNames: labels, canEdit: true)
    var selectedNames: [String] = []
    let palette = FinderTagMenuModel.paletteItem(choices: choices) { selectedNames.append($0) }
    let rows = [FileTreeRow(item: item, depth: 0, isExpanded: false, isLoadingChildren: false)]
    var options = FileBrowserDisplayOptions()
    options.viewMode = mode
    let view = FileListView(
      items: rows, selectedItemURLs: .constant([]), displayOptions: options,
      gitStatuses: nil, nameCell: { Text($0.name) }, contextMenu: { _ in EmptyView() },
      open: { _ in }, presentation: mode == .column ? .column : .standard,
      contextMenuItems: { _ in [palette] })
    let coordinator = view.makeCoordinator()
    coordinator.items = rows
    let table = NSTableView()
    coordinator.rebuildColumns(displayOptions: options, tableView: table)
    table.dataSource = coordinator
    table.reloadData()
    let menu = NSMenu()
    coordinator.buildContextMenu(menu, forRow: 0, tableView: table)
    let native = try #require(menu.items.first?.submenu)

    #expect(native.presentationStyle == .palette)
    #expect(native.items.map(\.title) == choices.map(\.name))
    #expect(native.items.map(\.state) == [.on, .off, .off, .off, .off, .off, .off])
    #expect(native.items.allSatisfy { $0.image != nil })
    if #available(macOS 27.0, *) {
      #expect(native.items.allSatisfy { $0.preferredImageVisibility == .visible })
    }
    coordinator.handleContextMenuAction(native.items[1])
    #expect(selectedNames == ["Orange"])
  }

  @MainActor
  @Test("アイコン表示の共通ビルダーは7色を標準パレットにし選択状態と画像を保つ")
  func swiftUIPaletteKeepsChoicesStateAndImages() throws {
    let item = FileItem(url: URL(filePath: "/tmp/tagged-file"), isDirectory: false, tags: ["Red"])
    let choices = FinderTagMenuModel.choices(for: [item], standardLabelNames: labels, canEdit: true)
    var selectedNames: [String] = []
    let palette = FinderTagMenuModel.paletteItem(choices: choices) { selectedNames.append($0) }
    let menu = NSHostingMenu(rootView: fileContextMenuContent([palette]))
    menu.update()
    let native = try #require(menu.items.first?.submenu)
    native.update()

    #expect(native.presentationStyle == .palette)
    #expect(native.items.map(\.title) == choices.map(\.name))
    #expect(native.items.map(\.state) == [.on, .off, .off, .off, .off, .off, .off])
    #expect(native.items.allSatisfy { $0.image != nil })
    if #available(macOS 27.0, *) {
      #expect(native.items.allSatisfy { $0.preferredImageVisibility == .visible })
    }
    native.performActionForItem(at: 1)
    #expect(selectedNames == ["Orange"])
  }

  @MainActor
  @Test("タグ専用の選択設定では非表示のサムネイル取得を始めない")
  func tagOnlySelectionSkipsThumbnailLoading() async {
    let model = FileInfoContentModel()
    let item = FileItem(
      remotePath: "/image.jpg", url: URL(string: "sftp://example/image.jpg")!,
      providerID: FileProviderID(rawValue: "thumbnail-test"), isDirectory: false,
      size: 1, modifiedAt: nil, tags: [])
    var didResolveDetails = false
    var thumbnailReadCount = 0
    model.setSelection(
      [item],
      detailItem: { item in
        didResolveDetails = true
        return item
      },
      thumbnailURLResolver: { _ in
        thumbnailReadCount += 1
        return nil
      },
      loadThumbnail: false)
    while !didResolveDetails { await Task.yield() }
    for _ in 0..<20 { await Task.yield() }

    #expect(thumbnailReadCount == 0)
    #expect(model.headerImage == nil)
  }

}
