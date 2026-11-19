import AppKit
import SwiftUI
import os

enum GitStatusIndicatorStyle {
  static func color(for status: GitFileStatus) -> NSColor {
    switch status {
    case .modified:
      .systemOrange
    case .added, .untracked:
      .systemGreen
    case .conflicted:
      .systemRed
    }
  }

  static func accessibilityLabel(for status: GitFileStatus) -> String {
    switch status {
    case .modified:
      String(localized: "Git変更あり")
    case .added:
      String(localized: "Git追加")
    case .untracked:
      String(localized: "Git未追跡")
    case .conflicted:
      String(localized: "Git競合")
    }
  }
}

/// コンテキストメニュー1項目分のデータ表現。.list(NSMenu)と.icon(SwiftUI .contextMenu)の
/// 両方が同じデータソースから項目を構築できるようにするための共通形式。
/// systemImage(アイコン)・isSeparator(区切り線)・children(サブメニュー)は両ビルダーが
/// 共通に解釈する(NSMenuビルダー: FileListView.Coordinator.populateMenu、
/// SwiftUIビルダー: fileContextMenuContent、いずれもこのファイル・FileListView.swiftを参照)。
/// childrenが空でない項目はサブメニューとして描画され、自身のactionは呼ばれない。
struct FileContextMenuItem: Identifiable {
  let id = UUID()
  let title: String
  var systemImage: String? = nil
  /// SF Symbolでは表現できない実画像(アプリアイコン等)。指定時はsystemImageより優先。
  var nsImage: NSImage? = nil
  var isEnabled: Bool = true
  /// 無効項目を非表示にせず、接続や対象によって利用できない理由を説明する。
  var disabledReason: String? = nil
  var isDestructive: Bool = false
  var isSeparator: Bool = false
  var children: [FileContextMenuItem] = []
  var isPalette = false
  var isSelected: Bool? = nil
  var action: () -> Void = {}

  /// 区切り線を表すエントリ。ForEach用にidはインスタンスごとに新規発行する(同一idの
  /// 複数区切り線が並ぶとSwiftUIのID一意性が崩れるため、静的な共有インスタンスにしない)。
  static func separator() -> FileContextMenuItem {
    FileContextMenuItem(title: "", isSeparator: true)
  }
}

/// メニューバーと各表示モードで共有する候補生成。再描画時の列挙と画像取得を繰り返さない。
@MainActor
final class OpenWithApplicationMenu {
  private struct Application {
    let url: URL
    let title: String
    let icon: NSImage
  }

  private let applications: (URL) -> [URL]
  private let defaultApplication: (URL) -> URL?
  private let applicationName: (URL) -> String
  private let applicationIcon: (URL) -> NSImage
  private struct CachedApplications {
    let expiresAt: Date
    let applications: [Application]
  }

  private let now: () -> Date
  private var cache: [URL: CachedApplications] = [:]
  private var cacheOrder: [URL] = []

  init(
    applications: @escaping (URL) -> [URL] = { NSWorkspace.shared.urlsForApplications(toOpen: $0) },
    defaultApplication: @escaping (URL) -> URL? = {
      NSWorkspace.shared.urlForApplication(toOpen: $0)
    },
    applicationName: @escaping (URL) -> String = {
      FileManager.default.displayName(atPath: $0.path)
    },
    applicationIcon: @escaping (URL) -> NSImage = { NSWorkspace.shared.icon(forFile: $0.path) },
    now: @escaping () -> Date = Date.init
  ) {
    self.applications = applications
    self.defaultApplication = defaultApplication
    self.applicationName = applicationName
    self.applicationIcon = applicationIcon
    self.now = now
  }

  func invalidate() {
    cache.removeAll()
    cacheOrder.removeAll()
  }

  func items(
    for localURL: URL,
    open: @escaping (URL, URL) -> Void,
    chooseOther: @escaping () -> Void
  ) -> [FileContextMenuItem] {
    guard localURL.isFileURL else { return [] }
    let candidates: [Application]
    if let cached = cache[localURL], cached.expiresAt > now() {
      candidates = cached.applications
    } else {
      var urls = applications(localURL)
      if let defaultURL = defaultApplication(localURL) {
        urls.removeAll { $0 == defaultURL }
        urls.insert(defaultURL, at: 0)
      }
      var seen = Set<URL>()
      candidates = urls.filter { seen.insert($0).inserted }.map { url in
        // NSWorkspaceの共有画像を変えず、メニュー用の16ptコピーを保持する。
        let icon = applicationIcon(url).copy() as! NSImage
        icon.size = NSSize(width: 16, height: 16)
        return Application(url: url, title: applicationName(url), icon: icon)
      }
      cacheOrder.removeAll { $0 == localURL }
      if cacheOrder.count == 32, let oldest = cacheOrder.first {
        cache.removeValue(forKey: oldest)
        cacheOrder.removeFirst()
      }
      // インストールや既定アプリ変更も次の取得へ反映できるよう、30秒で再取得する。
      cache[localURL] = CachedApplications(
        expiresAt: now().addingTimeInterval(30), applications: candidates)
      cacheOrder.append(localURL)
    }
    var result = candidates.map { application in
      FileContextMenuItem(title: application.title, nsImage: application.icon) {
        open(localURL, application.url)
      }
    }
    if !result.isEmpty { result.append(.separator()) }
    result.append(
      FileContextMenuItem(
        title: String(localized: "その他…"), systemImage: "ellipsis", action: chooseOther))
    return result
  }
}

/// FileContextMenuItemの配列をSwiftUIの.contextMenu本体として描画する共通ビルダー
/// (.icon側およびメニューバー)。区切り線・アイコン・サブメニューに対応する。NSMenu側は
/// FileListView.Coordinator.populateMenu。
///
/// 再帰呼び出し(サブメニューの中身)は`some View`の不透明型がそれ自身を参照できない制約を
/// 避けるためAnyViewで型消去する。メニューは項目数が少なく描画頻度も右クリック時のみのため、
/// 型消去のコストは無視できる。
@ViewBuilder
func fileContextMenuContent(_ items: [FileContextMenuItem]) -> some View {
  ForEach(items) { item in
    if item.isSeparator {
      Divider()
    } else if item.isPalette {
      ControlGroup {
        AnyView(fileContextMenuContent(item.children))
      }
      .controlGroupStyle(.palette)
    } else if let isSelected = item.isSelected {
      Toggle(isOn: Binding(get: { isSelected }, set: { _ in item.action() })) {
        fileContextMenuLabel(item)
      }
      .disabled(!item.isEnabled)
      .help(item.disabledReason ?? item.title)
    } else if !item.children.isEmpty {
      Menu {
        AnyView(fileContextMenuContent(item.children))
      } label: {
        fileContextMenuLabel(item)
      }
      .disabled(!item.isEnabled)
      .help(item.disabledReason ?? item.title)
    } else {
      Button(role: item.isDestructive ? .destructive : nil, action: item.action) {
        fileContextMenuLabel(item)
      }
      .disabled(!item.isEnabled)
      .help(item.disabledReason ?? item.title)
    }
  }
}

@ViewBuilder
private func fileContextMenuLabel(_ item: FileContextMenuItem) -> some View {
  if let nsImage = item.nsImage {
    Label {
      Text(item.title)
    } icon: {
      Image(nsImage: nsImage)
    }
    // macOS 27以降のメニューでも候補アプリの識別に必要な画像を表示する。
    .labelStyle(.titleAndIcon)
  } else if let systemImage = item.systemImage {
    Label(item.title, systemImage: systemImage)
  } else {
    Text(item.title)
  }
}

/// アイコン表示(.icon)のCommand/Shiftクリックによる複数選択の計算を、SwiftUIの状態(@State)や
/// NSEvent.modifierFlagsから切り離した純粋関数として分離したもの。現在の選択・アンカー(直近の
/// 通常クリックまたはCommand+クリックの対象)・表示順のitems配列を入力に、次の選択状態と
/// 次のアンカーを返す。単体テストはこの型を直接呼び出す(FileBrowserContent.handleIconClickは
/// NSEvent.modifierFlagsを読むだけの薄い配線に留める)。
enum IconGridSelection: Equatable {
  struct Result: Equatable {
    var selectedURLs: Set<URL>
    var anchorURL: URL?
  }

  /// 通常クリック: 単独選択。アンカーはクリックした項目に更新する。
  static func selectingSingle(_ url: URL) -> Result {
    Result(selectedURLs: [url], anchorURL: url)
  }

  /// Command+クリック: 対象の選択をトグル(追加/解除)する。アンカーはクリックした項目に
  /// 更新する(Finder同様、以降のShift+クリックは直近のCommand+クリックからも起点を引き継ぐ)。
  static func togglingCommandClick(_ url: URL, currentSelection: Set<URL>) -> Result {
    var selection = currentSelection
    if selection.contains(url) {
      selection.remove(url)
    } else {
      selection.insert(url)
    }
    return Result(selectedURLs: selection, anchorURL: url)
  }

  /// Shift+クリック: アンカーから対象までの表示順範囲を選択する。アンカーが未設定
  /// (まだ何も選択していない状態でいきなりShift+クリックした場合)や、アンカー・対象が
  /// 現在のitems配列に見つからない場合は単独選択にフォールバックする。
  static func selectingRange(to url: URL, anchorURL: URL?, items: [FileItem]) -> Result {
    guard let anchorURL,
      let anchorIndex = items.firstIndex(where: { $0.url == anchorURL }),
      let targetIndex = items.firstIndex(where: { $0.url == url })
    else {
      return selectingSingle(url)
    }
    let range =
      anchorIndex <= targetIndex ? anchorIndex...targetIndex : targetIndex...anchorIndex
    let selection = Set(items[range].map(\.url))
    // アンカー自体は据え置く(Finder同様、Shift+クリックを繰り返しても起点は動かない)。
    return Result(selectedURLs: selection, anchorURL: anchorURL)
  }
}

struct FileBrowserContent<NameCell: View, ItemContextMenu: View>: View {
  @Environment(\.themePalette) private var themePalette
  let items: [FileItem]
  @Binding var selectedItemURLs: Set<URL>
  let browserViewMode: FileBrowserViewMode
  let displayOptions: FileBrowserDisplayOptions
  /// OFF時はnilを必須指定し、各セルで辞書参照やインジケータ構築を行わない。
  let gitStatuses: [URL: GitFileStatus]?
  /// OFF時はnilを必須指定し、各セルでクラウド状態の辞書参照やインジケータ構築を行わない。
  var cloudDownloadStatuses: [URL: CloudDownloadStatus]? = nil
  /// .listの列ヘッダのソート状態と変更要求。アイコン表示でも並び順は同じ状態を使う。
  var sortOrder: FileItemSortOrder = .name
  var sortAscending = true
  var onSortRequest: (FileItemSortOrder) -> Void = { _ in }
  let nameCell: (FileItem) -> NameCell
  let contextMenu: (FileItem) -> ItemContextMenu
  let select: (FileItem) -> Void
  /// .iconのCommand/Shiftクリックによる複数選択の確定結果(IconGridSelectionが計算した
  /// 選択集合)をそのまま反映するコールバック。既定は何もしない(呼び出し元が複数選択に
  /// 対応しない場合、Command/Shiftクリックは選択に影響を与えないだけで安全に無視される)。
  var selectItems: (Set<URL>) -> Void = { _ in }
  let open: (FileItem) -> Void
  let supportsDragging: Bool
  /// .listでテーブル内をクリックするたびに呼ばれる(FileListView.onActivateへそのまま転送)。
  /// .iconは項目のButton自体が常にselectを発火するため使わない(既定は何もしない)。
  var onActivate: () -> Void = {}
  /// このペインが現在操作対象かどうか(FileListView.isActivePaneへそのまま転送)。
  var isActivePane: () -> Bool = { false }
  /// .listのインラインリネームが確定したときに呼ばれる(FileListView.onCommitInlineRenameへ
  /// そのまま転送)。.iconでは使わない(既存のシートベースのリネーム動線を維持)。
  var onCommitInlineRename: (FileItem, String) -> Void = { _, _ in }
  /// itemsが実際に変わったことを示す軽量な世代値(FileBrowserSession.displayItemsComputationCount
  /// など)。呼び出し元が提供できない場合はnilのままでよい(FileListView側で安全側にフォールバックする)。
  var itemsRevision: Int? = nil
  /// .listのネイティブNSMenu用にデータ化されたコンテキストメニュー項目。既定は空(項目なし)。
  var contextMenuItems: (FileItem) -> [FileContextMenuItem] = { _ in [] }
  /// 項目の外(余白)を右クリックしたときのメニュー項目(ペースト等)。既定は空。
  /// .listはFileListView.backgroundContextMenuItemsへ、.iconはScrollView自体の
  /// .contextMenuへそれぞれ同じデータソースから配線する。
  var backgroundContextMenuItems: () -> [FileContextMenuItem] = { [] }
  /// .listでテーブルへドロップされたファイルURL群を受け取る。既存の.dropDestinationと
  /// 同じ処理へ委譲する想定(既定はfalseを返す=何もしない)。
  var onDropURLs: ([URL]) -> Bool = { _ in false }
  /// .listのフォルダ行へドロップされたファイルURL群を、その行のフォルダ内へ転送する。
  var onDropURLsIntoFolder: ([URL], FileItem) -> Bool = { _, _ in false }
  /// .columnの各カラム背景へドロップされたファイルURL群を、そのカラムの場所へ転送する。
  var onDropURLsIntoLocation: ([URL], FileLocation) -> Bool = { _, _ in false }
  /// .list専用: 展開状態を反映した深さ付き行配列(フォルダその場展開)。未指定(nil)の場合は
  /// itemsをすべて深さ0・未展開として扱い、展開機能を使わない既存の見た目と完全互換になる。
  /// .iconはこの値を参照しない(展開はリスト表示専用の機能のため)。
  var listRows: [FileTreeRow]? = nil
  /// .list専用: 開閉三角のクリック・←→キーによる展開/折りたたみ要求(第2引数はOption同時押し)。
  /// 既定は何もしない。
  var onToggleExpand: (FileItem, Bool) -> Void = { _, _ in }
  /// .column専用: 左から右へ並べる階層カラム。未指定時は空表示になる。
  var columns: [FileBrowserColumn] = []
  /// .column専用: カラム内の選択集合。第2引数は選択元カラムの場所。
  /// 全表示モードの呼び出し元が配線要否を明示するため、既定値を持たせない。
  let onSelectColumnItems: (Set<URL>, FileLocation) -> Void
  /// .column専用: 対象カラムの個別幅変更要求。第1引数は対象カラムの場所。
  var onColumnWidthChange: (FileLocation, Double) -> Void = { _, _ in }
  /// FileBrowserSession.browseSignpostIDをそのまま受け取り.listへ転送する
  /// (クリック→列挙→描画→操作可能のos_signpost計測、詳細はFileListView参照)。
  var browseSignpostID: OSSignpostID? = nil
  /// 実際に表示された未補完項目をFileBrowserSessionのFinderタグ小バッチへ渡す。
  var onVisibleItemsChange: (([FileItem]) -> Void)? = nil
  /// ZIP作成後など、一覧へ反映済みの項目を表示モード固有のスクロール位置へ追従させる要求。
  var revealRequest: FileItemRevealRequest? = nil
  /// .iconのShift+クリック範囲選択の起点(直近の通常クリックまたはCommand+クリックの対象)。
  /// このビュー(ペイン)固有のUI状態でありモデルへは反映しない。
  @State private var selectionAnchorURL: URL?

  var body: some View {
    switch browserViewMode {
    case .list:
      let rows =
        listRows
        ?? items.map {
          FileTreeRow(item: $0, depth: 0, isExpanded: false, isLoadingChildren: false)
        }
      FileListView(
        items: rows,
        selectedItemURLs: $selectedItemURLs,
        displayOptions: displayOptions,
        gitStatuses: gitStatuses,
        cloudDownloadStatuses: cloudDownloadStatuses,
        sortOrder: sortOrder,
        sortAscending: sortAscending,
        onSortRequest: onSortRequest,
        nameCell: nameCell,
        contextMenu: contextMenu,
        open: open,
        onActivate: onActivate,
        isActivePane: isActivePane,
        onCommitInlineRename: onCommitInlineRename,
        itemsRevision: itemsRevision,
        contextMenuItems: contextMenuItems,
        backgroundContextMenuItems: backgroundContextMenuItems,
        supportsDragging: supportsDragging,
        onDropURLs: onDropURLs,
        onDropURLsIntoFolder: onDropURLsIntoFolder,
        onToggleExpand: onToggleExpand,
        focusRequest: focusRequest(for: rows),
        browseSignpostID: browseSignpostID,
        onVisibleItemsChange: onVisibleItemsChange)
    case .icon:
      let iconSize = displayOptions.iconSize
      ScrollViewReader { proxy in
        ScrollView {
          LazyVGrid(
            columns: [
              GridItem(
                .adaptive(
                  minimum: iconSize.gridColumnRange.lowerBound,
                  maximum: iconSize.gridColumnRange.upperBound),
                spacing: 12)
            ],
            spacing: 12
          ) {
            ForEach(items) { item in
              FileGridItemView(
                item: item,
                isSelected: selectedItemURLs.contains(item.url),
                supportsDragging: supportsDragging,
                iconSize: iconSize,
                gitStatus: gitStatuses?[item.url],
                cloudStatus: cloudDownloadStatuses?[item.url],
                onTap: { handleIconClick(item) },
                onOpen: { open(item) },
                contextMenu: { contextMenu(item) }
              )
              .equatable()
              .id(item.url)
              .onAppear {
                guard item.tags == nil else { return }
                onVisibleItemsChange?([item])
              }
            }
          }
          .padding(12)
        }
        .background(themePalette.contentBackground?.color)
        // アイコン外(グリッドの余白)を右クリックしたときの背景メニュー。個々のアイコンが
        // 自前の.contextMenuを持つため、アイコン上での右クリックはそちらが優先され、
        // 余白での右クリックだけがこちらへ落ちてくる(SwiftUI標準の入れ子解決)。
        .contextMenu {
          fileContextMenuContent(backgroundContextMenuItems())
        }
        .onChange(of: revealRequest) { _, request in
          guard let request, items.contains(where: { $0.url == request.itemURL }) else { return }
          proxy.scrollTo(request.itemURL, anchor: .center)
        }
      }
    case .column:
      FileColumnBrowserView(
        columns: columns,
        displayOptions: displayOptions,
        gitStatuses: gitStatuses,
        cloudDownloadStatuses: cloudDownloadStatuses,
        nameCell: nameCell,
        select: onSelectColumnItems,
        focus: select,
        open: open,
        contextMenuItems: contextMenuItems,
        backgroundContextMenuItems: backgroundContextMenuItems,
        supportsDragging: supportsDragging,
        onActivate: onActivate,
        isActivePane: isActivePane,
        onCommitInlineRename: onCommitInlineRename,
        onDropURLsIntoFolder: onDropURLsIntoFolder,
        onDropURLsIntoLocation: onDropURLsIntoLocation,
        onColumnWidthChange: onColumnWidthChange,
        onVisibleItemsChange: onVisibleItemsChange,
        revealRequest: revealRequest)
    }
  }

  private func focusRequest(for visibleRows: [FileTreeRow]) -> FileListFocusRequest? {
    // 通常時(revealRequestなし)に全行のURL配列を毎回生成しない。要求がある稀な場合だけ
    // 対象URLを走査する。
    guard let revealRequest,
      visibleRows.contains(where: { $0.item.url == revealRequest.itemURL })
    else { return nil }
    return FileListFocusRequest(
      generation: revealRequest.generation,
      itemURL: revealRequest.itemURL)
  }

  /// .iconのアイコンButtonアクション。修飾キーはSwiftUIのイベント経由では取得できないため、
  /// ドロップ自動判定のOption検出と同じ手法でNSEvent.modifierFlags(クリック時点のグローバルな
  /// 修飾キー状態)を直接参照する。選択の計算自体はIconGridSelection(純粋関数)に委譲し、
  /// ここではその結果をアンカー状態とselectItems/selectへ反映する薄い配線に留める。
  private func handleIconClick(_ item: FileItem) {
    let modifiers = NSEvent.modifierFlags
    if modifiers.contains(.command) {
      let result = IconGridSelection.togglingCommandClick(
        item.url, currentSelection: selectedItemURLs)
      selectionAnchorURL = result.anchorURL
      selectItems(result.selectedURLs)
    } else if modifiers.contains(.shift) {
      let result = IconGridSelection.selectingRange(
        to: item.url, anchorURL: selectionAnchorURL, items: items)
      selectionAnchorURL = result.anchorURL
      selectItems(result.selectedURLs)
    } else {
      selectionAnchorURL = item.url
      select(item)
    }
  }
}

/// キー移動先のカラムが横スクロール領域へ完全に収まっているかを判定する純関数。
enum FileColumnScrollVisibility {
  static func needsScroll(columnFrame: CGRect?, viewportFrame: CGRect) -> Bool {
    guard let columnFrame, !viewportFrame.isEmpty else { return true }
    return columnFrame.minX < viewportFrame.minX || columnFrame.maxX > viewportFrame.maxX
  }
}

private enum FileColumnScrollCoordinateSpace {
  static let name = "file-column-browser-scroll"
}

private struct FileColumnVisibilityPreferenceKey: PreferenceKey {
  static var defaultValue: [FileLocation: Bool] { [:] }

  static func reduce(value: inout [FileLocation: Bool], nextValue: () -> [FileLocation: Bool]) {
    value.merge(nextValue(), uniquingKeysWith: { _, newValue in newValue })
  }
}

/// 水平ScrollViewに単一階層の縦リストを並べるカラム表示。項目ドラッグ、フォルダ行・
/// カラム背景へのドロップ、上下左右キーによる行・カラム移動もここで統合する。
private struct FileColumnBrowserView<NameCell: View>: View {
  @Environment(\.themePalette) private var themePalette
  let columns: [FileBrowserColumn]
  let displayOptions: FileBrowserDisplayOptions
  let gitStatuses: [URL: GitFileStatus]?
  let cloudDownloadStatuses: [URL: CloudDownloadStatus]?
  let nameCell: (FileItem) -> NameCell
  let select: (Set<URL>, FileLocation) -> Void
  let focus: (FileItem) -> Void
  let open: (FileItem) -> Void
  let contextMenuItems: (FileItem) -> [FileContextMenuItem]
  let backgroundContextMenuItems: () -> [FileContextMenuItem]
  let supportsDragging: Bool
  let onActivate: () -> Void
  let isActivePane: () -> Bool
  let onCommitInlineRename: (FileItem, String) -> Void
  let onDropURLsIntoFolder: ([URL], FileItem) -> Bool
  let onDropURLsIntoLocation: ([URL], FileLocation) -> Bool
  let onColumnWidthChange: (FileLocation, Double) -> Void
  let onVisibleItemsChange: (([FileItem]) -> Void)?
  let revealRequest: FileItemRevealRequest?

  @State private var focusGeneration = 0
  @State private var focusRequest: ColumnFocusRequest?
  @State private var fullyVisibleColumns = Set<FileLocation>()
  @State private var scrollGeneration = 0
  @State private var scrollRequest: ColumnScrollRequest?

  private struct ColumnFocusRequest: Equatable {
    let location: FileLocation
    let request: FileListFocusRequest
  }

  private struct ColumnScrollRequest: Equatable {
    let generation: Int
    let location: FileLocation
    let anchor: UnitPoint
  }

  var body: some View {
    GeometryReader { viewport in
      ScrollViewReader { proxy in
        ScrollView(.horizontal) {
          LazyHStack(spacing: 0) {
            ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
              HStack(spacing: 0) {
                columnView(column, index: index)
                columnResizeHandle(column, index: index)
              }
              .id(column.id)
              .background {
                GeometryReader { geometry in
                  Color.clear.preference(
                    key: FileColumnVisibilityPreferenceKey.self,
                    value: [
                      column.id: !FileColumnScrollVisibility.needsScroll(
                        columnFrame: geometry.frame(
                          in: .named(FileColumnScrollCoordinateSpace.name)),
                        viewportFrame: CGRect(origin: .zero, size: viewport.size))
                    ])
                }
              }
            }
          }
        }
        .background(themePalette.contentBackground?.color)
        .coordinateSpace(name: FileColumnScrollCoordinateSpace.name)
        .onPreferenceChange(FileColumnVisibilityPreferenceKey.self) { visibility in
          fullyVisibleColumns = Set(visibility.compactMap { $0.value ? $0.key : nil })
        }
        // 右端の場所が変わるのはユーザーが子フォルダを開いたときだけなので、
        // その場合に限って新しいカラムへ追従する。
        .onChange(of: columns.last?.id) { _, lastID in
          guard let lastID else { return }
          requestScroll(to: lastID, anchor: .trailing)
        }
        .onChange(of: scrollRequest) { _, request in
          guard let request else { return }
          withAnimation(.easeInOut(duration: 0.22)) {
            proxy.scrollTo(request.location, anchor: request.anchor)
          }
        }
        .onChange(of: revealRequest) { _, request in
          guard let request,
            columns.contains(where: {
              $0.location == request.directoryLocation
                && $0.items.contains(where: { $0.url == request.itemURL })
            })
          else { return }
          requestScroll(to: request.directoryLocation, anchor: .trailing)
        }
        .contextMenu {
          fileContextMenuContent(backgroundContextMenuItems())
        }
      }
    }
  }

  private func columnView(_ column: FileBrowserColumn, index: Int) -> some View {
    ZStack {
      FileColumnMiniList(
        column: column,
        index: index,
        displayOptions: displayOptions,
        gitStatuses: gitStatuses,
        cloudDownloadStatuses: cloudDownloadStatuses,
        nameCell: nameCell,
        contextMenuItems: contextMenuItems,
        backgroundContextMenuItems: backgroundContextMenuItems,
        select: select,
        open: open,
        activate: onActivate,
        isActivePane: isActivePane,
        onCommitInlineRename: onCommitInlineRename,
        supportsDragging: supportsDragging,
        onDropURLsIntoFolder: onDropURLsIntoFolder,
        onDropURLsIntoLocation: onDropURLsIntoLocation,
        onVisibleItemsChange: onVisibleItemsChange,
        onMoveToPreviousColumn: {
          moveColumnFocus(from: column.location, direction: .left)
        },
        onMoveToNextColumn: {
          moveColumnFocus(from: column.location, direction: .right)
        },
        focusRequest: revealFocusRequest(for: column)
          ?? (focusRequest?.location == column.location ? focusRequest?.request : nil))
      if column.isLoading, column.items.isEmpty {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .accessibilityIdentifier("file-column-loading-\(index)")
          .allowsHitTesting(false)
      } else if column.items.isEmpty {
        Text("空のフォルダ")
          .font(.caption)
          .foregroundStyle(.secondary)
          .allowsHitTesting(false)
      }
    }
    .frame(width: effectiveColumnWidth(for: column))
    .frame(maxHeight: .infinity)
    .background(themePalette.contentBackground?.color ?? Color(nsColor: .controlBackgroundColor))
    .accessibilityIdentifier(columnAccessibilityIdentifier(at: index))
  }

  private func columnAccessibilityIdentifier(at index: Int) -> String {
    if index == columns.count - 1 {
      return "file-browser-column-current"
    }
    if index == columns.count - 2 {
      return "file-browser-column-parent"
    }
    return "file-browser-column-\(index)"
  }

  private func columnResizeHandle(_ column: FileBrowserColumn, index: Int) -> some View {
    ZStack {
      ColumnResizeHandle(
        width: effectiveColumnWidth(for: column),
        accessibilityIdentifier: index == columns.count - 1
          ? "file-column-resize-handle-current"
          : "file-column-resize-handle-\(index)",
        onWidthChange: { width in
          onColumnWidthChange(column.location, width)
        })
      Rectangle()
        .fill(themePalette.separator?.color ?? Color(nsColor: .separatorColor))
        .frame(width: 1)
        .allowsHitTesting(false)
    }
    .frame(width: 9)
    .frame(maxHeight: .infinity)
  }

  private func moveColumnFocus(
    from location: FileLocation, direction: FileColumnHorizontalDirection
  ) -> Bool {
    guard let activeColumnIndex = columns.firstIndex(where: { $0.location == location }) else {
      return false
    }
    let result = FileColumnKeyboardNavigation.handlingResult(
      in: columns, activeColumnIndex: activeColumnIndex, direction: direction)
    let target: FileColumnKeyboardNavigation.Target
    switch result {
    case .move(let movementTarget):
      target = movementTarget
    case .handledWithoutMovement:
      return true
    case .unhandled:
      return false
    }
    let targetLocation = columns[target.columnIndex].location
    switch direction {
    case .left:
      focus(target.item)
    case .right:
      select([target.item.url], targetLocation)
    }
    focusGeneration &+= 1
    focusRequest = ColumnFocusRequest(
      location: targetLocation,
      request: FileListFocusRequest(
        generation: focusGeneration &* 2 &+ 1,
        itemURL: target.item.url))
    if !fullyVisibleColumns.contains(targetLocation) {
      let anchor: UnitPoint
      switch direction {
      case .left: anchor = .leading
      case .right: anchor = .trailing
      }
      requestScroll(to: targetLocation, anchor: anchor)
    }
    return true
  }

  private func requestScroll(to location: FileLocation, anchor: UnitPoint) {
    scrollGeneration &+= 1
    scrollRequest = ColumnScrollRequest(
      generation: scrollGeneration, location: location, anchor: anchor)
  }

  private func revealFocusRequest(for column: FileBrowserColumn) -> FileListFocusRequest? {
    guard let revealRequest,
      revealRequest.directoryLocation == column.location,
      column.items.contains(where: { $0.url == revealRequest.itemURL })
    else { return nil }
    // キー移動要求は奇数、外部の表示要求は偶数に分離し、同じ世代番号の衝突を避ける。
    return FileListFocusRequest(
      generation: revealRequest.generation &* 2,
      itemURL: revealRequest.itemURL)
  }

  private func effectiveColumnWidth(for column: FileBrowserColumn) -> Double {
    FileBrowserColumnWidth.clamped(column.widthOverride ?? displayOptions.columnWidth)
  }
}

/// 横ScrollView内でもドラッグ開始後のマウスイベントを最後まで保持するAppKit製の境界。
/// SwiftUIのDragGestureでは幅変更によって境界自身が移動するとScrollView側へ競合が移り、
/// 実操作でもドラッグが0ptのまま終了しうるため、NSViewのmouseDraggedで直接追跡する。
private struct ColumnResizeHandle: NSViewRepresentable {
  let width: Double
  let accessibilityIdentifier: String
  let onWidthChange: (Double) -> Void

  func makeNSView(context: Context) -> TrackingView {
    TrackingView()
  }

  func updateNSView(_ view: TrackingView, context: Context) {
    view.width = FileBrowserColumnWidth.clamped(width)
    view.onWidthChange = onWidthChange
    view.setAccessibilityElement(true)
    view.setAccessibilityRole(.splitter)
    view.setAccessibilityIdentifier(accessibilityIdentifier)
    view.setAccessibilityLabel("カラム幅を変更")
    view.setAccessibilityValue("\(Int(width.rounded()))")
  }

  final class TrackingView: NSView {
    var width = FileBrowserColumnWidth.defaultValue
    var onWidthChange: (Double) -> Void = { _ in }

    private var dragStartX: CGFloat?
    private var dragStartWidth = FileBrowserColumnWidth.defaultValue

    override func mouseDown(with event: NSEvent) {
      dragStartX = event.locationInWindow.x
      dragStartWidth = width
    }

    override func mouseDragged(with event: NSEvent) {
      updateWidth(for: event)
    }

    override func mouseUp(with event: NSEvent) {
      updateWidth(for: event)
      dragStartX = nil
    }

    override func resetCursorRects() {
      addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    private func updateWidth(for event: NSEvent) {
      guard let dragStartX else { return }
      let translation = event.locationInWindow.x - dragStartX
      onWidthChange(FileBrowserColumnWidth.clamped(dragStartWidth + Double(translation)))
    }
  }
}

/// カラム1本を既存FileListViewの名前列だけで表示するミニリスト。選択と右クリックは
/// FileListView.Coordinatorへ委譲し、SwiftUIで行を自前描画しない。
private struct FileColumnMiniList<NameCell: View>: View {
  let column: FileBrowserColumn
  let index: Int
  let displayOptions: FileBrowserDisplayOptions
  let gitStatuses: [URL: GitFileStatus]?
  let cloudDownloadStatuses: [URL: CloudDownloadStatus]?
  let nameCell: (FileItem) -> NameCell
  let contextMenuItems: (FileItem) -> [FileContextMenuItem]
  let backgroundContextMenuItems: () -> [FileContextMenuItem]
  let select: (Set<URL>, FileLocation) -> Void
  let open: (FileItem) -> Void
  let activate: () -> Void
  let isActivePane: () -> Bool
  let onCommitInlineRename: (FileItem, String) -> Void
  let supportsDragging: Bool
  let onDropURLsIntoFolder: ([URL], FileItem) -> Bool
  let onDropURLsIntoLocation: ([URL], FileLocation) -> Bool
  let onVisibleItemsChange: (([FileItem]) -> Void)?
  let onMoveToPreviousColumn: () -> Bool
  let onMoveToNextColumn: () -> Bool
  let focusRequest: FileListFocusRequest?

  var body: some View {
    FileListView(
      items: column.items.map {
        FileTreeRow(item: $0, depth: 0, isExpanded: false, isLoadingChildren: false)
      },
      selectedItemURLs: selection,
      displayOptions: displayOptions,
      gitStatuses: gitStatuses,
      cloudDownloadStatuses: cloudDownloadStatuses,
      nameCell: nameCell,
      contextMenu: { _ in EmptyView() },
      open: open,
      presentation: .column,
      onActivate: activate,
      isActivePane: isActivePane,
      onCommitInlineRename: onCommitInlineRename,
      itemsRevision: column.itemsRevision,
      contextMenuItems: contextMenuItems,
      backgroundContextMenuItems: backgroundContextMenuItems,
      supportsDragging: supportsDragging,
      onDropURLs: { urls in onDropURLsIntoLocation(urls, column.location) },
      onDropURLsIntoFolder: onDropURLsIntoFolder,
      onMoveToPreviousColumn: onMoveToPreviousColumn,
      onMoveToNextColumn: onMoveToNextColumn,
      focusRequest: focusRequest,
      onVisibleItemsChange: onVisibleItemsChange)
  }

  private var selection: Binding<Set<URL>> {
    Binding(
      get: { column.selectedItemURLs },
      set: { selectedURLs in
        guard selectedURLs != column.selectedItemURLs else { return }
        select(selectedURLs, column.location)
      })
  }
}

/// .iconの1セル分の見た目。選択変更のたびに全セルのbodyが再評価されるのを防ぐため、
/// FileBrowserContentのForEachから独立したEquatableなサブビューへ分離している
/// (性能検証: doc/plans/2026-08-12-multi-selection.md Step4)。==はitemとisSelectedと
/// supportsDraggingとiconSizeだけを比較し、クロージャ(onTap/onOpen/contextMenu)は比較対象に
/// 含めない(クロージャはEquatableにできない上、呼び出し元が構築するたびに新しいインスタンスに
/// なるが実際に描画へ影響する値ではないため)。呼び出し元は`.equatable()`を必ず付与すること
/// (単なるEquatable準拠だけではSwiftUIの差分評価がスキップされない)。iconSizeは表示オプション
/// またはメニューバーの拡大/縮小で全セル一斉に変わるため、変化時は全セルが1回ずつ再評価される
/// (選択変更時のような1件だけの部分再評価とは異なる、意図した全件更新)。
private struct FileGridItemView<ItemContextMenu: View>: View, @MainActor Equatable {
  @Environment(\.themePalette) private var themePalette
  let item: FileItem
  let isSelected: Bool
  let supportsDragging: Bool
  let iconSize: IconGridSize
  let gitStatus: GitFileStatus?
  let cloudStatus: CloudDownloadStatus?
  let onTap: () -> Void
  let onOpen: () -> Void
  let contextMenu: () -> ItemContextMenu

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.item == rhs.item && lhs.isSelected == rhs.isSelected
      && lhs.supportsDragging == rhs.supportsDragging && lhs.iconSize == rhs.iconSize
      && lhs.gitStatus == rhs.gitStatus
      && lhs.cloudStatus == rhs.cloudStatus
  }

  var body: some View {
    Button(action: onTap) {
      VStack(spacing: 6) {
        FileGridIconView(item: item, iconSize: iconSize)
        Text(item.name)
          .lineLimit(2)
          .multilineTextAlignment(.center)
          .frame(maxWidth: .infinity)
        FileItemIndicators(
          item: item,
          mode: .icon,
          cloudStatus: cloudStatus,
          gitStatus: gitStatus)
      }
      .frame(maxWidth: .infinity, minHeight: iconSize.cellMinHeight)
      .padding(8)
      .background(
        isSelected ? themePalette.accentFill(.selection) : Color.clear,
        in: RoundedRectangle(cornerRadius: 6)
      )
      .contentShape(RoundedRectangle(cornerRadius: 6))
    }
    .buttonStyle(.plain)
    .fileItemDrag(item.url, enabled: supportsDragging)
    .contextMenu {
      contextMenu()
    }
    .simultaneousGesture(
      TapGesture(count: 2).onEnded {
        onOpen()
      }
    )
    .accessibilityIdentifier("file-icon-\(item.name)")
    .accessibilityLabel(item.name)
  }
}

private struct FileItemIndicators: View {
  let item: FileItem
  let mode: FileBrowserViewMode
  let cloudStatus: CloudDownloadStatus?
  let gitStatus: GitFileStatus?

  var body: some View {
    let supportsTags = FileBrowserCapability.supports(.finderTagDisplay, for: mode)
    let supportsGitStatus = FileBrowserCapability.supports(.gitStatusDisplay, for: mode)
    let supportsCloudStatus = FileBrowserCapability.supports(.cloudDownloadStatusDisplay, for: mode)
    let tags = supportsTags ? FinderTagPalette.systemTags(from: item.tags) : []
    let displayedCloudStatus = supportsCloudStatus ? cloudStatus : nil
    let displayedGitStatus = supportsGitStatus ? gitStatus : nil
    if displayedCloudStatus?.indicatorLabel != nil || displayedGitStatus != nil || !tags.isEmpty {
      let summary = FinderTagDisplaySummary.make(from: tags)
      let accessibilityLabel = FileItemIndicatorAccessibility.label(
        cloudStatus: displayedCloudStatus,
        gitStatus: displayedGitStatus,
        tags: tags)
      HStack(spacing: 3) {
        if let status = displayedCloudStatus, let symbol = status.indicatorSystemImage,
          let label = status.indicatorLabel
        {
          Image(systemName: symbol)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .accessibilityLabel(label)
            .accessibilityIdentifier(status.indicatorIdentifier ?? "cloud-status")
            .help(status.helpText)
        }
        if let displayedGitStatus {
          Circle()
            .fill(Color(nsColor: GitStatusIndicatorStyle.color(for: displayedGitStatus)))
            .frame(width: 8, height: 8)
            .accessibilityLabel(
              GitStatusIndicatorStyle.accessibilityLabel(for: displayedGitStatus)
            )
            .accessibilityIdentifier("git-status-\(displayedGitStatus.rawValue)")
        }
        ForEach(Array(summary.visibleTags.enumerated()), id: \.offset) { _, tag in
          let displayColor =
            tag.color == .none
            ? Color.clear
            : Color(nsColor: FinderTagPalette.nsColor(for: tag.color))
          Circle()
            .fill(displayColor)
            .overlay {
              if tag.color == .none {
                Circle().stroke(Color.secondary, lineWidth: 1)
              }
            }
            .frame(width: 8, height: 8)
        }
      }
      .frame(height: 8)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(accessibilityLabel)
    }
  }
}

enum FileItemIndicatorAccessibility {
  static func label(
    cloudStatus: CloudDownloadStatus? = nil,
    gitStatus: GitFileStatus?,
    tags: [FinderTag]
  ) -> String {
    let accessibilityLabels =
      (cloudStatus.flatMap { $0.indicatorLabel }.map { [$0] } ?? [])
      + (gitStatus.map { [GitStatusIndicatorStyle.accessibilityLabel(for: $0)] } ?? [])
      + tags.map(\.name)
    return accessibilityLabels.joined(separator: "、")
  }
}

extension View {
  @ViewBuilder
  fileprivate func fileItemDrag(_ url: URL, enabled: Bool) -> some View {
    if enabled {
      draggable(url)
    } else {
      self
    }
  }
}

/// アイコンモード用のグリッドアイコン。同期の拡張子アイコンを即時表示し、
/// アプリの実アイコン・画像等のミニサムネイルが解決でき次第差し替える。
/// iconSizeが変わるとtask(id:)が再発行され、新しいサイズで改めて解決する
/// (キャッシュキーにサイズを含むFileIconProvider側の対応と合わせて、サイズ切替時に
/// 別サイズの画像が誤って流用されないようにしている)。
private struct FileGridIconView: View {
  let item: FileItem
  let iconSize: IconGridSize
  @State private var resolvedIcon: NSImage?

  private struct ResolutionKey: Equatable {
    let url: URL
    let iconSize: IconGridSize
  }

  var body: some View {
    Image(nsImage: resolvedIcon ?? FileIconProvider.shared.icon(for: item))
      .resizable()
      .aspectRatio(contentMode: .fit)
      .frame(width: iconSize.iconPointSize, height: iconSize.iconPointSize)
      .task(id: ResolutionKey(url: item.url, iconSize: iconSize)) {
        let provider = FileIconProvider.shared
        let size = CGSize(width: iconSize.iconPointSize, height: iconSize.iconPointSize)
        if let cached = provider.cachedResolvedIcon(for: item, size: size) {
          resolvedIcon = cached
          return
        }
        resolvedIcon = nil
        guard !provider.isKnownUnresolvable(for: item, size: size) else { return }
        resolvedIcon = await provider.resolvedIcon(for: item, size: size)
      }
  }
}
