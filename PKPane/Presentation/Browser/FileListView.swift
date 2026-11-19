import AppKit
import SwiftUI
import os

/// フォルダその場展開の階層1段あたりのインデント幅。
private let treeIndentPerLevel: CGFloat = 16
/// 開閉三角(またはロードスピナー)が占める正方形のスロット幅。展開不可な行(ファイル)でも
/// 同じ幅を確保することで、Finder同様に同じ深さの項目名が三角の有無に関わらず揃う。
private let treeDisclosureSlotWidth: CGFloat = 13

/// 同じNSTableView実装を通常リストとカラム1本のミニリストで共有するための表示構成。
/// カラム表示は名前列だけを使い、ヘッダを無効にする。交互背景、複数選択、行高と
/// ネイティブセル、選択同期、右クリックメニューは通常リストと同じ経路を通す。
enum FileListPresentation: Equatable {
  case standard
  case column

  var viewMode: FileBrowserViewMode {
    switch self {
    case .standard: .list
    case .column: .column
    }
  }

  @MainActor
  func configure(_ tableView: ActivatingTableView) {
    let mode = viewMode
    tableView.style = .plain
    tableView.usesAutomaticRowHeights = false
    tableView.usesAlternatingRowBackgroundColors = FileBrowserCapability.supports(
      .alternatingRowBackgrounds, for: mode)
    tableView.allowsMultipleSelection = FileBrowserCapability.supports(
      .multipleSelection, for: mode)
    tableView.allowsEmptySelection = true
    tableView.headerView =
      FileBrowserCapability.supports(.tableColumnHeaders, for: mode)
      ? NSTableHeaderView() : nil
    tableView.columnAutoresizingStyle =
      FileBrowserCapability.supports(.listColumnWidthDistribution, for: mode)
      ? .noColumnAutoresizing : .firstColumnOnlyAutoresizingStyle
  }
}

/// リスト/カラムのアイコンサイズからNSTableViewへ反映する行レイアウト。
@MainActor
enum FileListRowLayout {
  static func apply(_ iconSize: IconGridSize, to tableView: NSTableView) {
    tableView.rowHeight = iconSize.listRowHeight
  }
}

/// 非同期に解決したアイコンを現在の表示サイズへ適用してよいかを判定する。
enum FileListIconResolution {
  static func shouldApply(_ resolvedSize: NSSize, currentSize: NSSize) -> Bool {
    resolvedSize == currentSize
  }
}

/// 名前列の非同期アイコン解決が同じURLで重複しないよう、実行中の要求を管理する。
struct FileListIconResolutionRequests {
  struct RequestID: Equatable {
    fileprivate let rawValue = UUID()
  }

  private struct Request {
    let id: RequestID
    var task: Task<Void, Never>?
  }

  private var requestsByURL: [URL: Request] = [:]

  mutating func begin(for url: URL) -> RequestID? {
    guard requestsByURL[url] == nil else { return nil }
    let id = RequestID()
    requestsByURL[url] = Request(id: id, task: nil)
    return id
  }

  mutating func attach(_ task: Task<Void, Never>, for url: URL, id: RequestID) {
    guard requestsByURL[url]?.id == id else {
      task.cancel()
      return
    }
    requestsByURL[url]?.task = task
  }

  @discardableResult
  mutating func finish(for url: URL, id: RequestID) -> Bool {
    guard requestsByURL[url]?.id == id else { return false }
    requestsByURL.removeValue(forKey: url)
    return true
  }

  mutating func cancelAll() {
    for request in requestsByURL.values {
      request.task?.cancel()
    }
    requestsByURL.removeAll()
  }

  mutating func cancelRequestsMissing(from rowIndexByURL: [URL: Int]) {
    let missingURLs = requestsByURL.keys.filter { rowIndexByURL[$0] == nil }
    for url in missingURLs {
      requestsByURL.removeValue(forKey: url)?.task?.cancel()
    }
  }
}

/// カラム内ミニリストが受け取ったスクロールイベントを、ジェスチャ単位で内側の縦一覧か
/// 外側の横ScrollViewへ振り分ける純粋な状態機械。AppKitのNSEventから独立させ、指を
/// 離した後のモメンタムまで同じ配送先を保持する規則を単体テスト可能にする。
enum ColumnScrollGestureRouting {
  enum Phase: String, Equatable {
    case none
    case mayBegin
    case began
    case changed
    case ended
    case cancelled
  }

  enum Destination: String, Equatable {
    case local
    case forward
  }

  struct State: Equatable {
    fileprivate enum Stage: String, Equatable {
      case idle
      case pending
      case local
      case forward
    }

    fileprivate let stage: Stage
    fileprivate let accumulatedDeltaX: Double
    fileprivate let accumulatedDeltaY: Double

    static let idle = State(stage: .idle, accumulatedDeltaX: 0, accumulatedDeltaY: 0)
    static let pending = State(stage: .pending, accumulatedDeltaX: 0, accumulatedDeltaY: 0)
    static let local = State(stage: .local, accumulatedDeltaX: 0, accumulatedDeltaY: 0)
    static let forward = State(stage: .forward, accumulatedDeltaX: 0, accumulatedDeltaY: 0)

    fileprivate var destination: Destination? {
      switch stage {
      case .idle, .pending: nil
      case .local: .local
      case .forward: .forward
      }
    }

    var isPending: Bool {
      stage == .pending
    }

    fileprivate static func accumulating(deltaX: Double, deltaY: Double) -> State {
      State(
        stage: .pending,
        accumulatedDeltaX: deltaX,
        accumulatedDeltaY: deltaY)
    }
  }

  struct Decision: Equatable {
    let destination: Destination
    let nextState: State
    let sendsBookend: Bool

    fileprivate init(
      destination: Destination,
      nextState: State,
      sendsBookend: Bool = false
    ) {
      self.destination = destination
      self.nextState = nextState
      self.sendsBookend = sendsBookend
    }
  }

  /// トラックパッドの1ジェスチャを、イベントを受け取るカラムが替わっても同じ状態で扱う。
  @MainActor
  private(set) static var sharedState: State = .idle

  @MainActor
  static func routeShared(
    phase: Phase,
    momentumPhase: Phase,
    deltaX: Double,
    deltaY: Double
  ) -> Decision {
    let decision = route(
      phase: phase,
      momentumPhase: momentumPhase,
      deltaX: deltaX,
      deltaY: deltaY,
      state: sharedState)
    sharedState = decision.nextState
    return decision
  }

  @MainActor
  static func resetSharedState() {
    sharedState = .idle
  }

  static func route(
    phase: Phase,
    momentumPhase: Phase,
    deltaX: Double,
    deltaY: Double,
    state: State
  ) -> Decision {
    let sendsBookend = phase == .began || phase == .ended || phase == .cancelled

    // mayBeginは方向がまだ確定していない予告イベントなので、内側へ素通しし状態も変えない。
    if phase == .mayBegin {
      return Decision(destination: .local, nextState: state)
    }

    // モメンタムは指を離す直前のジェスチャと同じ配送先を使う。配送元のカラムが
    // 入れ替わってidleへ届いた場合は、そのイベント自体の方向から配送先を復元する。
    if momentumPhase != .none {
      let decision: Decision
      if state == .idle {
        let destination = dominantDestination(deltaX: deltaX, deltaY: deltaY)
        decision = Decision(
          destination: destination,
          nextState: routingState(for: destination))
      } else if state.isPending {
        decision = accumulatingDecision(deltaX: deltaX, deltaY: deltaY, state: state)
      } else {
        decision = Decision(destination: state.destination ?? .local, nextState: state)
      }
      let nextState: State =
        momentumPhase == .ended || momentumPhase == .cancelled ? .idle : decision.nextState
      return Decision(
        destination: decision.destination,
        nextState: nextState,
        sendsBookend: sendsBookend)
    }

    switch phase {
    case .began:
      // 新しいジェスチャでは以前の未確定累積を破棄し、このイベントから計測し直す。
      let decision = accumulatingDecision(deltaX: deltaX, deltaY: deltaY, state: .pending)
      return Decision(
        destination: decision.destination,
        nextState: decision.nextState,
        sendsBookend: true)
    case .changed:
      guard state.isPending else {
        return Decision(destination: state.destination ?? .local, nextState: state)
      }
      return accumulatingDecision(deltaX: deltaX, deltaY: deltaY, state: state)
    case .ended:
      return Decision(
        destination: state.destination ?? .local,
        nextState: state,
        sendsBookend: true)
    case .cancelled:
      return Decision(
        destination: state.destination ?? .local,
        nextState: .idle,
        sendsBookend: true)
    case .none:
      // 物理ホイール等はジェスチャ状態を持たないため、イベントごとに方向を判定する。
      return Decision(
        destination: dominantDestination(deltaX: deltaX, deltaY: deltaY), nextState: state)
    case .mayBegin:
      // 冒頭で処理済み。switchを網羅するため残す。
      return Decision(destination: .local, nextState: state)
    }
  }

  private static func dominantDestination(deltaX: Double, deltaY: Double) -> Destination {
    abs(deltaX) > abs(deltaY) ? .forward : .local
  }

  private static func accumulatingDecision(
    deltaX: Double,
    deltaY: Double,
    state: State
  ) -> Decision {
    let accumulatedDeltaX = state.accumulatedDeltaX + abs(deltaX)
    let accumulatedDeltaY = state.accumulatedDeltaY + abs(deltaY)
    guard max(accumulatedDeltaX, accumulatedDeltaY) >= 4 else {
      return Decision(
        destination: .local,
        nextState: .accumulating(
          deltaX: accumulatedDeltaX,
          deltaY: accumulatedDeltaY))
    }

    let destination = dominantDestination(
      deltaX: accumulatedDeltaX,
      deltaY: accumulatedDeltaY)
    return Decision(destination: destination, nextState: routingState(for: destination))
  }

  private static func routingState(for destination: Destination) -> State {
    destination == .forward ? .forward : .local
  }
}

/// 外側スクロールビューの解決順を、ビュー階層の探索自体から分離した純関数。
/// 現在のチェーンを常に優先し、見つからない場合だけ最後に確認できたweakキャッシュを使う。
enum ColumnScrollOuterDestinationResolver {
  enum Source: String, Equatable {
    case chain
    case cached
    case none
  }

  static func source(chainAvailable: Bool, cachedAvailable: Bool) -> Source {
    if chainAvailable { return .chain }
    if cachedAvailable { return .cached }
    return .none
  }
}

/// カラム表示の各ミニリスト専用スクロールビュー。横優勢で始まったジェスチャを外側の
/// SwiftUI横ScrollViewへ転送し、その後のモメンタムイベントも同じ経路へ流す。
@MainActor
final class ColumnMiniListScrollView: NSScrollView {
  private static let scrollLog = OSLog(subsystem: "com.pky.PKPane", category: "column-scroll")

  private weak var lastKnownOuterScrollView: NSScrollView?

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    let resolution = resolveOuterScrollView()
    logAttachment(event: "viewDidMoveToSuperview", resolution: resolution)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    let resolution = resolveOuterScrollView()
    logAttachment(event: "viewDidMoveToWindow", resolution: resolution)
  }

  override func scrollWheel(with event: NSEvent) {
    let previousState = ColumnScrollGestureRouting.sharedState
    let decision = ColumnScrollGestureRouting.routeShared(
      phase: Self.routingPhase(from: event.phase),
      momentumPhase: Self.routingPhase(from: event.momentumPhase),
      deltaX: Double(event.scrollingDeltaX),
      deltaY: Double(event.scrollingDeltaY))
    let resolution = resolveOuterScrollView()
    let delivery = deliveryDescription(decision: decision, resolution: resolution)

    os_log(
      .debug,
      log: Self.scrollLog,
      "scrollWheel phase=%{public}llu momentumPhase=%{public}llu deltaX=%{public}.3f deltaY=%{public}.3f destination=%{public}@ bookend=%{public}d delivery=%{public}@ stateBefore=%{public}@ stateAfter=%{public}@ accumulatedX=%{public}.3f accumulatedY=%{public}.3f outer=%{public}@ hasSuperview=%{public}d",
      UInt64(event.phase.rawValue),
      UInt64(event.momentumPhase.rawValue),
      Double(event.scrollingDeltaX),
      Double(event.scrollingDeltaY),
      decision.destination.rawValue,
      decision.sendsBookend ? 1 : 0,
      delivery,
      previousState.stage.rawValue,
      decision.nextState.stage.rawValue,
      decision.nextState.accumulatedDeltaX,
      decision.nextState.accumulatedDeltaY,
      resolution.source.rawValue,
      superview == nil ? 0 : 1)

    if decision.sendsBookend {
      super.scrollWheel(with: event)
      resolution.scrollView?.scrollWheel(with: event)
      return
    }

    guard decision.destination == .forward, let outerScrollView = resolution.scrollView else {
      super.scrollWheel(with: event)
      return
    }
    outerScrollView.scrollWheel(with: event)
  }

  private func deliveryDescription(
    decision: ColumnScrollGestureRouting.Decision,
    resolution: (
      scrollView: NSScrollView?, source: ColumnScrollOuterDestinationResolver.Source
    )
  ) -> String {
    if decision.sendsBookend {
      return resolution.scrollView == nil ? "bookend-local-only" : "bookend-local+forward"
    }
    if decision.destination == .forward {
      return resolution.scrollView == nil ? "local-fallback" : "forward"
    }
    return "local"
  }

  private func resolveOuterScrollView() -> (
    scrollView: NSScrollView?, source: ColumnScrollOuterDestinationResolver.Source
  ) {
    let chainScrollView = currentOuterScrollView
    if let chainScrollView {
      lastKnownOuterScrollView = chainScrollView
    }
    let source = ColumnScrollOuterDestinationResolver.source(
      chainAvailable: chainScrollView != nil,
      cachedAvailable: lastKnownOuterScrollView != nil)
    switch source {
    case .chain:
      return (chainScrollView, source)
    case .cached:
      return (lastKnownOuterScrollView, source)
    case .none:
      return (nil, source)
    }
  }

  private var currentOuterScrollView: NSScrollView? {
    var ancestor = superview
    while let current = ancestor {
      if let scrollView = current as? NSScrollView {
        return scrollView
      }
      ancestor = current.superview
    }
    return nil
  }

  private func logAttachment(
    event: String,
    resolution: (
      scrollView: NSScrollView?, source: ColumnScrollOuterDestinationResolver.Source
    )
  ) {
    os_log(
      .debug,
      log: Self.scrollLog,
      "%{public}@ outer=%{public}@ hasSuperview=%{public}d hasWindow=%{public}d",
      event,
      resolution.source.rawValue,
      superview == nil ? 0 : 1,
      window == nil ? 0 : 1)
  }

  private static func routingPhase(from phase: NSEvent.Phase) -> ColumnScrollGestureRouting.Phase {
    if phase.contains(.cancelled) { return .cancelled }
    if phase.contains(.ended) { return .ended }
    if phase.contains(.began) { return .began }
    if phase.contains(.changed) || phase.contains(.stationary) { return .changed }
    if phase.contains(.mayBegin) { return .mayBegin }
    return .none
  }
}

/// 別のカラム用ミニリストへキーボードフォーカスを移す要求。generationで同じURLへの
/// 再移動も区別し、対象NSTableViewだけが要求を1回処理する。
struct FileListFocusRequest: Equatable {
  let generation: Int
  let itemURL: URL
}

/// FileBrowserContentの.list分岐が使うNSTableViewラッパー。
/// セルはすべてネイティブ(名前列はNSTableCellView+NSImageView(SF Symbol)+
/// NSTextField(labelWithString:)、他の列はNSTextField単体)で構築し、
/// makeView(withIdentifier:)で再利用する。選択時の文字色反転はNSTableCellViewの
/// 標準機構(backgroundStyle)に任せる。
///
/// nameCellクロージャはFileBrowserContentの公開インターフェース維持のため引数として
/// 残しているが、.listではネイティブセルを使うため呼び出さない(未使用)。
/// リネームUIは既存のシート(SFTPBrowserView.ProviderBrowserViewのrenamingItem)経由で
/// 完結しており、nameCellクロージャの実行結果には依存しない。
/// クリックのたびにonActivateを呼ぶNSTableViewサブクラス。選択状態が変化しないクリック
/// (既に選択済みの行の再クリック、選択が空のままの余白クリックなど)はNSTableView
/// SelectionDidChangeNotificationが発火せず、Coordinator.tableViewSelectionDidChangeの
/// 選択差分ガード(変化がなければselectedItemURLsへ書き戻さない最適化)に阻まれて
/// ペイン切替が届かない。選択状態の変化と独立にクリックそのものを検知することで、
/// そのペインを常に操作対象へ切り替える。
enum FileListColumn: String, Hashable {
  case name, kind, size, modifiedAt, location, tags

  var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }

  var title: String {
    switch self {
    case .name: String(localized: "名前")
    case .kind: String(localized: "種類")
    case .size: String(localized: "サイズ")
    case .modifiedAt: String(localized: "更新日時")
    case .location: String(localized: "場所")
    case .tags: String(localized: "タグ")
    }
  }

  var minWidth: CGFloat {
    switch self {
    case .name: 160
    case .kind: 90
    case .size: 56
    case .modifiedAt: 96
    case .location: 100
    case .tags: 80
    }
  }

  /// 列の初期幅。サイズ・更新日時・場所は内容を読みやすい希望幅を持ち、ペイン縮小時だけ
  /// minWidthまで段階的に圧縮する。nameは残り幅を受け取るため広めにする。
  var defaultWidth: CGFloat {
    switch self {
    case .name: 480
    case .kind: 90
    case .size: 80
    case .modifiedAt: 140
    case .location: 160
    case .tags: 120
    }
  }

  var sortOrder: FileItemSortOrder? {
    switch self {
    case .name: .name
    case .kind: .kind
    case .size: .size
    case .modifiedAt: .modifiedAt
    case .location, .tags: nil
    }
  }
}

/// ペイン幅の増減に応じて列幅を増分配分するための値型。
/// preferredWidthsはサイズ・更新日時・場所について、最後にユーザーが指定した幅を保持する。
struct FileListColumnWidthState: Equatable {
  var currentWidths: [FileListColumn: CGFloat]
  var preferredWidths: [FileListColumn: CGFloat]
  let minimumWidths: [FileListColumn: CGFloat]
}

/// NSTableViewの自動リサイズから独立した列幅配分規則。現在幅へ利用可能幅の差分だけを
/// 適用するため、名前列を手動で縮めた状態や、他列の手動希望幅を失わない。
enum FileListColumnWidthPolicy {
  /// NSTableView.style=.plainでは左右インセットはないが、各列のセル幅に加えて
  /// intercellSpacing.widthが列数分必要になる。クリップ幅からこの余白を引き、
  /// 列幅だけに配分できる実効幅を返す。
  static func effectiveAvailableWidth(
    viewportWidth: CGFloat,
    columnCount: Int,
    intercellSpacingWidth: CGFloat
  ) -> CGFloat {
    let spacingWidth = max(0, intercellSpacingWidth) * CGFloat(max(0, columnCount))
    return max(0, viewportWidth - spacingWidth)
  }

  /// 初期配置と列再構築時に、現在のクリップ幅へ列を絶対配分する。
  /// 補助列はユーザーの希望幅を優先し、残りを名前列へ与える。名前列が最小幅に達しても
  /// 収まらない場合だけ、通常の縮小順と同じく場所、更新日時、サイズの順で圧縮する。
  static func fitting(
    availableWidth: CGFloat,
    state: FileListColumnWidthState
  ) -> FileListColumnWidthState {
    var result = state
    for column in [FileListColumn.size, .modifiedAt, .location] {
      guard result.currentWidths[column] != nil else { continue }
      let minimumWidth = result.minimumWidths[column] ?? column.minWidth
      let preferredWidth = result.preferredWidths[column] ?? column.defaultWidth
      result.currentWidths[column] = max(minimumWidth, preferredWidth)
    }

    guard result.currentWidths[.name] != nil else { return result }
    let nameMinimumWidth = result.minimumWidths[.name] ?? FileListColumn.name.minWidth
    let otherWidth = result.currentWidths.reduce(CGFloat.zero) { partialResult, entry in
      entry.key == .name ? partialResult : partialResult + entry.value
    }
    result.currentWidths[.name] = max(nameMinimumWidth, availableWidth - otherWidth)

    var shortage = max(0, result.currentWidths.values.reduce(0, +) - availableWidth)
    for column in [FileListColumn.location, .modifiedAt, .size] {
      guard shortage > 0, let currentWidth = result.currentWidths[column] else { continue }
      let minimumWidth = result.minimumWidths[column] ?? column.minWidth
      let reduction = min(shortage, max(0, currentWidth - minimumWidth))
      result.currentWidths[column] = currentWidth - reduction
      shortage -= reduction
    }
    return result
  }

  static func applying(
    availableWidthChangeFrom oldAvailableWidth: CGFloat,
    to newAvailableWidth: CGFloat,
    state: FileListColumnWidthState
  ) -> FileListColumnWidthState {
    var result = state
    var remaining = abs(newAvailableWidth - oldAvailableWidth)
    guard remaining > 0 else { return result }

    if newAvailableWidth < oldAvailableWidth {
      for column in [FileListColumn.location, .modifiedAt, .size, .name] {
        guard let currentWidth = result.currentWidths[column] else { continue }
        let minimumWidth = result.minimumWidths[column] ?? currentWidth
        let reduction = min(remaining, max(0, currentWidth - minimumWidth))
        result.currentWidths[column] = currentWidth - reduction
        remaining -= reduction
        if remaining == 0 { break }
      }
      return result
    }

    for column in [FileListColumn.size, .modifiedAt, .location] {
      guard let currentWidth = result.currentWidths[column],
        let preferredWidth = result.preferredWidths[column]
      else { continue }
      let increase = min(remaining, max(0, preferredWidth - currentWidth))
      result.currentWidths[column] = currentWidth + increase
      remaining -= increase
      if remaining == 0 { return result }
    }
    if let nameWidth = result.currentWidths[.name] {
      result.currentWidths[.name] = nameWidth + remaining
    }
    return result
  }
}

/// 一覧列ヘッダからのソート要求に対する次の状態を決める純粋な値型。
/// 別列を選んだ場合の既定方向と、同じ列の再クリック時の反転を一箇所に集約する。
struct FileListSortState: Equatable {
  let order: FileItemSortOrder
  let ascending: Bool

  func applying(requestedOrder: FileItemSortOrder) -> Self {
    guard requestedOrder != order else {
      return Self(order: order, ascending: !ascending)
    }
    return Self(order: requestedOrder, ascending: requestedOrder.defaultAscending)
  }
}

extension FileItemSortOrder {
  /// 列ヘッダを初めて選んだときの既定方向。名前・種類は昇順、数値・日時は降順にする。
  fileprivate var defaultAscending: Bool {
    switch self {
    case .name, .kind: true
    case .size, .modifiedAt: false
    }
  }
}

/// リスト表示のフォルダその場展開における←→キーの次の動作を決める純粋な値型。
/// NSResponderのmoveLeft/moveRightから呼ばれる薄い配線(ActivatingTableView.moveLeft/
/// moveRight、Coordinator.handleLeftArrow/handleRightArrow)から分離し、単体テスト可能にする。
enum FileTreeKeyboardAction: Equatable {
  case expand(URL)
  case collapse(URL)
  case selectParent(URL)
  case none
}

enum FileTreeKeyboardNavigation {
  /// →キー: 選択中の1件がフォルダかつ未展開なら展開する。展開済み・非フォルダ・
  /// 複数選択(呼び出し側がselectedRowをnilにする)はnoneを返し、既定動作(何もしない)に委ねる。
  static func rightArrowAction(selectedRow: FileTreeRow?) -> FileTreeKeyboardAction {
    guard let selectedRow, selectedRow.isExpandable, !selectedRow.isExpanded else { return .none }
    return .expand(selectedRow.item.url)
  }

  /// ←キー: 選択中の1件が展開済みフォルダなら折りたたむ。展開済みでなければ、深さが
  /// 1つ浅い直近の祖先行(親フォルダ行)へ選択を移動する。ルート直下(depth 0)や
  /// 該当行が見つからない場合はnoneを返す。
  static func leftArrowAction(
    selectedRow: FileTreeRow?, rows: [FileTreeRow], selectedIndex: Int?
  ) -> FileTreeKeyboardAction {
    guard let selectedRow else { return .none }
    if selectedRow.isExpandable, selectedRow.isExpanded {
      return .collapse(selectedRow.item.url)
    }
    guard selectedRow.depth > 0, let selectedIndex else { return .none }
    for index in stride(from: selectedIndex - 1, through: 0, by: -1) {
      if rows[index].depth < selectedRow.depth {
        return .selectParent(rows[index].item.url)
      }
    }
    return .none
  }
}

/// isRenameEligibleClickを単体テストから直接呼べるようアクセスレベルはinternal
/// (既定)のまま。テスト以外の外部からはFileListView経由でのみ使う想定。
final class ActivatingTableView: NSTableView {
  private var themePalette = ThemePalette.standard
  private var standardBackgroundColor: NSColor?
  private(set) var themeContentColor: NSColor?
  private(set) var themeAlternatingRowColor: NSColor?

  /// テーマ変更時だけ色を解決し、表示中の行だけを再描画する。
  func applyTheme(_ palette: ThemePalette) {
    guard themePalette != palette else { return }
    themePalette = palette
    themeContentColor = palette.contentBackground?.nsColor
    themeAlternatingRowColor = palette.alternatingRowBackground?.nsColor
    if let themeContentColor {
      if standardBackgroundColor == nil {
        standardBackgroundColor = backgroundColor
      }
      backgroundColor = themeContentColor
    } else if let standardBackgroundColor {
      backgroundColor = standardBackgroundColor
      self.standardBackgroundColor = nil
    }
    needsDisplay = true
    enumerateAvailableRowViews { rowView, _ in
      rowView.needsDisplay = true
    }
  }

  override func drawBackground(inClipRect clipRect: NSRect) {
    guard let themeContentColor else {
      super.drawBackground(inClipRect: clipRect)
      return
    }
    // 空行領域も含め、実際の行ビューと同じ周期でテーマの交互背景を描く。
    themeContentColor.setFill()
    clipRect.fill()
    let rowStride = rowHeight + intercellSpacing.height
    guard usesAlternatingRowBackgroundColors, let themeAlternatingRowColor,
      rowStride > 0, !clipRect.isEmpty
    else { return }
    let firstRow = max(0, Int(floor(clipRect.minY / rowStride)))
    let lastRow = Int(ceil(clipRect.maxY / rowStride))
    themeAlternatingRowColor.setFill()
    // 全件走査を避け、再描画が必要な矩形に交差する奇数行だけを塗る。
    for row in stride(from: firstRow | 1, to: lastRow, by: 2) {
      NSRect(
        x: clipRect.minX, y: CGFloat(row) * rowStride,
        width: clipRect.width, height: rowStride
      ).intersection(clipRect).fill()
    }
  }

  var onActivate: () -> Void = {}
  /// クリック時点でこのペインが既にアクティブだったかを返す。onActivate()を呼ぶと
  /// アクティブ状態が変わってしまうため、onActivate()より前に判定する必要がある
  /// (インラインリネームは「既にアクティブなペインへの再クリック」でのみ始まり、
  /// 非アクティブペインを操作対象へ切り替えるための最初のクリックでは始めない)。
  var isPaneActiveBeforeClick: () -> Bool = { false }
  /// インライン編集の開始要求(対象行インデックスを渡す)。
  var onRequestInlineRename: (Int) -> Void = { _ in }
  /// →キーの処理要求(keyDown(with:)から呼ばれる)。フォルダその場展開の対象になりうる
  /// 場合はtrueを返して処理済みとし、それ以外(展開対象なし等)はfalseを返して既定動作へ委ねる。
  var onRequestExpandSelection: () -> Bool = { false }
  /// ←キーの処理要求(keyDown(with:)から呼ばれる)。折りたたみ・親行選択の対象になりうる
  /// 場合はtrueを返して処理済みとし、それ以外はfalseを返して既定動作へ委ねる。
  var onRequestCollapseSelection: () -> Bool = { false }

  /// mouseDown処理中(AppKit自身がCommand/Shiftクリックによる選択拡張を確定させている最中)は
  /// true。mouseDown冒頭のonActivate()はSwiftUI側の状態(操作対象ペイン等)を変更するため、
  /// 非同期の再描画がスケジュールされうる。その再描画がAppKitのクリック処理の完了(=拡張後の
  /// 選択がtableViewSelectionDidChange経由でモデルへ書き戻される)より先に走ると、
  /// FileListView.updateNSViewが呼ぶsyncSelectionFromModelが古いモデル値でAppKitの選択を
  /// 上書きしてしまう。この間だけモデル側からの同期を見送ることでその競合を塞ぐ
  /// (isRenameEligibleClick同様、単体テストから直接検証できるようアクセスレベルはinternal)。
  var isHandlingClickSelection = false

  private var pendingInlineRename: DispatchWorkItem?

  /// クリックがインラインリネームの開始条件を満たすか判定する純粋関数。
  /// mouseDownの座標→行/列変換や選択状態はNSTableViewから渡してもらい、判定ロジック
  /// 自体は副作用なく単体テストできるよう分離している。
  static func isRenameEligibleClick(
    clickCount: Int,
    modifierFlags: NSEvent.ModifierFlags,
    clickedRow: Int,
    isNameColumn: Bool,
    selectedRowIndexes: IndexSet,
    wasPaneAlreadyActive: Bool
  ) -> Bool {
    clickCount == 1
      && clickedRow >= 0
      && isNameColumn
      && wasPaneAlreadyActive
      && modifierFlags.intersection([.command, .shift]).isEmpty
      && selectedRowIndexes == IndexSet(integer: clickedRow)
  }

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    let clickedRow = row(at: point)
    let clickedColumnIndex = column(at: point)
    let isNameColumn =
      clickedColumnIndex >= 0
      && tableColumns.indices.contains(clickedColumnIndex)
      && tableColumns[clickedColumnIndex].identifier == FileListColumn.name.identifier
    let isRenameCandidate = Self.isRenameEligibleClick(
      clickCount: event.clickCount,
      modifierFlags: event.modifierFlags,
      clickedRow: clickedRow,
      isNameColumn: isNameColumn,
      selectedRowIndexes: selectedRowIndexes,
      wasPaneAlreadyActive: isPaneActiveBeforeClick())

    cancelPendingInlineRename()
    isHandlingClickSelection = true
    onActivate()
    super.mouseDown(with: event)
    isHandlingClickSelection = false

    guard isRenameCandidate else { return }
    // ドラッグへ発展した場合はmouseDraggedで、ダブルクリックだった場合は次のmouseDownの
    // 冒頭でそれぞれキャンセルされる。doubleClickInterval後もキャンセルされていなければ
    // シングルクリックのみで確定したとみなし編集を開始する(標準的な遅延編集パターン)。
    let workItem = DispatchWorkItem { [weak self] in
      // 待機中にホバーで別ペインへ移った場合は旧ペインの編集を始めない。
      guard let self, self.isPaneActiveBeforeClick() else { return }
      self.onRequestInlineRename(clickedRow)
    }
    pendingInlineRename = workItem
    DispatchQueue.main.asyncAfter(
      deadline: .now() + NSEvent.doubleClickInterval, execute: workItem)
  }

  override func mouseDragged(with event: NSEvent) {
    cancelPendingInlineRename()
    super.mouseDragged(with: event)
  }

  override func rightMouseDown(with event: NSEvent) {
    cancelPendingInlineRename()
    onActivate()
    super.rightMouseDown(with: event)
  }

  // ←→キーはNSResponderの標準アクションメソッド(moveLeft:/moveRight:)経由の
  // オーバーライドではなく、keyDown(with:)でNSEvent.specialKeyを直接判定する。
  // NSTableViewは左右矢印キーの扱いが内部実装依存(列選択・水平スクロール等の余地があり、
  // interpretKeyEvents経由でmoveLeft:/moveRight:へ確実に到達する保証がない)なため、
  // 生イベントを直接見ることでその不確実性を排除する。修飾キー付き(⌘←/⌘→の戻る・進む等)
  // は対象外にし、既存のKeyboardCommandRouter経由の挙動と衝突しないようにする。
  override func keyDown(with event: NSEvent) {
    guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
    else {
      super.keyDown(with: event)
      return
    }
    switch event.specialKey {
    case .rightArrow where onRequestExpandSelection():
      return
    case .leftArrow where onRequestCollapseSelection():
      return
    default:
      super.keyDown(with: event)
    }
  }

  private func cancelPendingInlineRename() {
    pendingInlineRename?.cancel()
    pendingInlineRename = nil
  }
}

/// 選択ハイライトはAppKitへ任せ、テーマ指定がある行の下地だけを塗る。
private final class ThemedTableRowView: NSTableRowView {
  weak var tableView: ActivatingTableView?

  override func drawBackground(in dirtyRect: NSRect) {
    guard !isGroupRowStyle,
      let tableView, let contentColor = tableView.themeContentColor
    else {
      super.drawBackground(in: dirtyRect)
      return
    }
    let row = tableView.row(for: self)
    let color =
      tableView.usesAlternatingRowBackgroundColors && row >= 0 && row % 2 == 1
      ? tableView.themeAlternatingRowColor ?? contentColor : contentColor
    color.setFill()
    dirtyRect.fill()
  }
}

/// 名前列セルの実体。展開三角・子ロード中スピナーの部品と、行の深さに応じて変わる
/// インデント制約への参照を、makeView(withIdentifier:)による再利用時にも差し替えられる
/// よう保持する。
private final class NameCellView: NSTableCellView {
  let disclosureButton = NSButton()
  let loadingIndicator = NSProgressIndicator()
  let folderChevron = NSImageView()
  let tagDotsStack = NSStackView()
  var indentConstraint: NSLayoutConstraint!
  var disclosureWidthConstraint: NSLayoutConstraint!
  var textTrailingToCellConstraint: NSLayoutConstraint!
  var textTrailingToChevronConstraint: NSLayoutConstraint!
  var textTrailingToDotsConstraint: NSLayoutConstraint!
  var dotsTrailingToCellConstraint: NSLayoutConstraint!
  var dotsTrailingToChevronConstraint: NSLayoutConstraint!
  var iconWidthConstraint: NSLayoutConstraint!
  var iconHeightConstraint: NSLayoutConstraint!
}

struct FileListView<NameCell: View, ItemContextMenu: View>: NSViewRepresentable {
  @Environment(\.themePalette) private var themePalette
  /// 展開状態を反映した深さ付き行配列。展開を一切使わない場合は全行depth 0・
  /// isExpanded falseとなり、既存の平坦な一覧と完全に同じ見た目・挙動になる。
  let items: [FileTreeRow]
  @Binding var selectedItemURLs: Set<URL>
  let displayOptions: FileBrowserDisplayOptions
  /// OFF時はnil。名前セルはnilならGit用の辞書参照とビュー構築を行わない。
  let gitStatuses: [URL: GitFileStatus]?
  /// OFF時はnil。名前セルはnilならクラウド状態の辞書参照とビュー構築を行わない。
  var cloudDownloadStatuses: [URL: CloudDownloadStatus]? = nil
  /// 現在のソート状態。列ヘッダの標準インジケータ表示に使う。
  var sortOrder: FileItemSortOrder = .name
  var sortAscending = true
  /// ソート可能な列ヘッダがクリックされたときの要求。状態の更新は呼び出し元が担う。
  var onSortRequest: (FileItemSortOrder) -> Void = { _ in }
  let nameCell: (FileItem) -> NameCell
  // FileBrowserContentのインターフェース維持のため引数として残しているが、.iconのみで使う
  // (.listはcontextMenuItemsのデータからNSMenuを構築する)。
  let contextMenu: (FileItem) -> ItemContextMenu
  let open: (FileItem) -> Void
  /// 通常リストか、カラム1本を構成する名前列だけのミニリストか。
  var presentation: FileListPresentation = .standard
  /// テーブル内のクリック(行・余白どちらも、左右クリックとも)のたびに呼ばれる。
  /// 選択の変化とは独立に「このペインを操作対象にする」ためのコールバック。既定は何もしない。
  var onActivate: () -> Void = {}
  /// このペインが現在操作対象かどうか。クリック時点(onActivate呼び出し前)の判定に使う。
  /// インラインリネームは「既にアクティブなペインへの再クリック」でのみ始まる。
  var isActivePane: () -> Bool = { false }
  /// インラインリネームが確定した(Enterで確定・元の名前から変更あり)ときに呼ばれる。
  /// 実際のリネームAPI呼び出し・検証・エラー表示は呼び出し元の既存rename経路に委ねる。
  var onCommitInlineRename: (FileItem, String) -> Void = { _, _ in }
  /// itemsの内容が実際に変わったことを示す軽量な世代値(例: FileBrowserSessionの
  /// displayItemsComputationCount)。呼び出し元が提供できる場合はこれを比較に使い、
  /// 全itemsの深い比較(O(n))を避ける。nilの場合は安全側に倒して毎回差分計算する。
  var itemsRevision: Int? = nil
  /// 右クリックされた行のNSMenuをデータから構築する。
  var contextMenuItems: (FileItem) -> [FileContextMenuItem] = { _ in [] }
  /// 行の外(余白)の右クリックのNSMenuをデータから構築する。ペースト等、対象アイテムに
  /// 依存しない操作用(既定は空=メニューを出さない)。
  var backgroundContextMenuItems: () -> [FileContextMenuItem] = { [] }
  /// 行からのドラッグアウトを許可するか(FileBrowserContent.supportsDraggingをそのまま受け取る)。
  var supportsDragging: Bool = true
  /// テーブルへドロップされたファイルURL群を既存のペインレベル処理へ委譲するコールバック。
  /// 既定はfalseを返す(何もしない)。
  var onDropURLs: ([URL]) -> Bool = { _ in false }
  /// フォルダ行へドロップされたファイルURL群を、その行のフォルダ内へ転送するコールバック。
  /// 行の展開状態には依存しない。既定はfalseを返す(何もしない)。
  var onDropURLsIntoFolder: ([URL], FileItem) -> Bool = { _, _ in false }
  /// 開閉三角のクリック・←→キーによる展開/折りたたみ要求。第2引数はOption同時押し
  /// (配下全展開/全折りたたみ)かどうか。既定は何もしない(展開機能を使わない呼び出し元は
  /// 触れる必要がない)。
  var onToggleExpand: (FileItem, Bool) -> Void = { _, _ in }
  /// カラム表示専用。←→キーで隣のミニリストへ移動する要求。通常リストでは呼ばれない。
  var onMoveToPreviousColumn: () -> Bool = { false }
  var onMoveToNextColumn: () -> Bool = { false }
  /// 対象ミニリストをfirst responderにし、指定行を可視化する要求。
  var focusRequest: FileListFocusRequest? = nil
  /// FileBrowserSession.browseSignpostIDをそのまま受け取る。クリック(open)→列挙開始→
  /// 最初の行描画→全件描画→操作可能の区間へ「最初の行描画」を相関させるために使う。
  var browseSignpostID: OSSignpostID? = nil
  /// AppKitが実際にセルを要求した未補完項目をまとめて通知する。複数列の同じ行はURLで
  /// 統合し、次のMainActorターンに1回だけ通知するため、スクロール中の呼び出しを増幅しない。
  var onVisibleItemsChange: (([FileItem]) -> Void)? = nil

  func makeNSView(context: Context) -> NSScrollView {
    let tableView = ActivatingTableView()
    tableView.onActivate = { [weak coordinator = context.coordinator] in
      coordinator?.parent.onActivate()
    }
    tableView.isPaneActiveBeforeClick = { [weak coordinator = context.coordinator] in
      coordinator?.parent.isActivePane() ?? false
    }
    tableView.onRequestInlineRename = { [weak coordinator = context.coordinator] row in
      coordinator?.beginInlineRename(atRow: row)
    }
    tableView.onRequestExpandSelection = { [weak coordinator = context.coordinator] in
      coordinator?.handleRightArrow() ?? false
    }
    tableView.onRequestCollapseSelection = { [weak coordinator = context.coordinator] in
      coordinator?.handleLeftArrow() ?? false
    }
    presentation.configure(tableView)
    tableView.applyTheme(themePalette)
    FileListRowLayout.apply(displayOptions.iconSize, to: tableView)
    tableView.dataSource = context.coordinator
    tableView.delegate = context.coordinator
    tableView.target = context.coordinator
    tableView.doubleAction = #selector(Coordinator.handleDoubleClick(_:))
    let menu = NSMenu()
    menu.delegate = context.coordinator
    // NSMenu.autoenablesItemsは既定でtrue。表示直前にAppKitが各NSMenuItem.targetへ
    // validateMenuItem(:)を問い合わせ、未実装(Coordinatorは未実装でactionへ常に応答する)
    // だとisEnabled=falseで構築した項目も表示直前に上書きで有効化されてしまう。
    // buildContextMenuが設定したisEnabledをそのまま尊重させるため無効化する。
    menu.autoenablesItems = false
    tableView.menu = menu
    context.coordinator.tableView = tableView

    // ドラッグアウト(pasteboardWriterForRow)は登録不要。ドロップインはファイルURL型を
    // 受け取れるよう明示的に登録する(現行の.dropDestination(for: URL.self)と同じ型)。
    tableView.registerForDraggedTypes([.fileURL])
    tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
    tableView.setDraggingSourceOperationMask(.copy, forLocal: true)

    // ホバープレビュー(0.5秒静止でサムネイル+メタデータをポップオーバー表示)用の
    // マウス位置検出。.inVisibleRectで可視領域の変化に自動追従させる。
    let trackingArea = NSTrackingArea(
      rect: .zero,
      options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: context.coordinator,
      userInfo: nil)
    tableView.addTrackingArea(trackingArea)

    let mode = presentation.viewMode
    let scrollView: NSScrollView =
      FileBrowserCapability.supports(.columnScrollRouting, for: mode)
      ? ColumnMiniListScrollView() : NSScrollView()
    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = FileBrowserCapability.supports(
      .horizontalTableScroller, for: mode)
    scrollView.drawsBackground = false
    context.coordinator.observeWidthChanges(in: scrollView)
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let tableView = scrollView.documentView as? ActivatingTableView else { return }
    let coordinator = context.coordinator
    coordinator.parent = self

    // NavigationSplitView配下でaccessibilityIdentifierが外側からこのNSScrollViewへ
    // 適用された場合に備え、XCUITestのapp.tables[...]照会が拾えるようNSTableView側にも
    // 同じ識別子を反映する(SwiftUI ← → AppKitのAX役割の橋渡し)。
    let identifier = scrollView.accessibilityIdentifier()
    if !identifier.isEmpty {
      tableView.setAccessibilityIdentifier(identifier)
    }

    // 列構成(表示ON/OFF)が変わった場合だけ列を再構築する。両ペインは各々のNSTableViewが
    // 自分の列幅を持つ(共有stateには持たせない)ため、ここでは表示ON/OFFの変化だけを見る。
    let visibleColumnSignature = displayOptions.visibleColumnSignature
    let columnsChanged =
      coordinator.lastPresentation != presentation
      || coordinator.lastDisplayOptions?.visibleColumnSignature != visibleColumnSignature
    if columnsChanged {
      presentation.configure(tableView)
      coordinator.rebuildColumns(
        displayOptions: displayOptions, presentation: presentation, tableView: tableView)
      scrollView.hasHorizontalScroller = FileBrowserCapability.supports(
        .horizontalTableScroller, for: presentation.viewMode)
    }
    tableView.applyTheme(themePalette)
    let iconSizeChanged = coordinator.lastDisplayOptions?.iconSize != displayOptions.iconSize
    FileListRowLayout.apply(displayOptions.iconSize, to: tableView)
    if iconSizeChanged {
      coordinator.invalidateIconResolutionRequests()
      tableView.reloadData()
    }
    coordinator.lastDisplayOptions = displayOptions
    coordinator.lastPresentation = presentation
    coordinator.syncSortIndicators(
      sortOrder: sortOrder, ascending: sortAscending, tableView: tableView)
    coordinator.redistributeColumns(
      toAvailableWidth: scrollView.contentView.bounds.width,
      resetReferenceWidth: columnsChanged)

    // NavigationSplitViewの選択同期レース(Forums 749620)対策+性能: itemsRevisionが
    // 前回と一致するなら内容変化がないと確定できるためO(n)深比較ごと省略する。
    // revisionがnil(呼び出し元が世代を提供しない)の場合は安全側に倒し毎回差分計算する。
    if coordinator.lastItemsRevision != itemsRevision || itemsRevision == nil {
      let oldItems = coordinator.items
      coordinator.items = items
      coordinator.lastItemsRevision = itemsRevision
      coordinator.applyDiff(
        from: oldItems,
        to: items,
        tableView: tableView,
        browseSignpostID: browseSignpostID)
      // 空→非空に限定すると、旧一覧から直接遷移するキャッシュ命中経路でB3を
      // 取りこぼす。同じbrowse signpost IDでは1回だけ発火する。
      if !items.isEmpty, let signpostID = browseSignpostID,
        coordinator.lastFirstVisibleCellSignpostRawValue != signpostID.rawValue
      {
        coordinator.lastFirstVisibleCellSignpostRawValue = signpostID.rawValue
        BrowsePerformanceSignpost.event(
          .firstVisibleCellConfigured,
          signpostID: signpostID,
          itemCount: items.count)
      }
    }

    if coordinator.lastGitStatuses != gitStatuses {
      coordinator.reloadChangedGitStatusRows(
        from: coordinator.lastGitStatuses,
        to: gitStatuses,
        tableView: tableView)
      coordinator.lastGitStatuses = gitStatuses
    }

    if coordinator.lastCloudDownloadStatuses != cloudDownloadStatuses {
      coordinator.reloadChangedCloudStatusRows(
        from: coordinator.lastCloudDownloadStatuses,
        to: cloudDownloadStatuses,
        tableView: tableView)
      coordinator.lastCloudDownloadStatuses = cloudDownloadStatuses
    }

    coordinator.syncSelectionFromModel(selectedItemURLs, tableView: tableView)
    if let focusRequest, coordinator.lastFocusRequestGeneration != focusRequest.generation {
      coordinator.lastFocusRequestGeneration = focusRequest.generation
      coordinator.focus(itemURL: focusRequest.itemURL, tableView: tableView)
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  @MainActor
  final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate,
    NSTextFieldDelegate
  {
    var parent: FileListView
    var items: [FileTreeRow] = [] {
      didSet {
        var updatedRowIndexByURL: [URL: Int] = [:]
        updatedRowIndexByURL.reserveCapacity(items.count)
        for (index, row) in items.enumerated() where updatedRowIndexByURL[row.item.url] == nil {
          updatedRowIndexByURL[row.item.url] = index
        }
        rowIndexByURL = updatedRowIndexByURL
        iconResolutionRequests.cancelRequestsMissing(from: updatedRowIndexByURL)
      }
    }
    var lastDisplayOptions: FileBrowserDisplayOptions?
    var lastPresentation: FileListPresentation?
    var lastItemsRevision: Int?
    private(set) var lastListDiffMeasurement: ListDiffMeasurement?
    var lastFirstVisibleCellSignpostRawValue: UInt64?
    var lastGitStatuses: [URL: GitFileStatus]?
    var lastCloudDownloadStatuses: [URL: CloudDownloadStatus]?
    var lastFocusRequestGeneration: Int?
    weak var tableView: NSTableView?
    private var isApplyingModelSelection = false
    private var rowIndexByURL: [URL: Int] = [:]
    private(set) var lastSelectionCandidateScanCount = 0
    private(set) var lastStatusRowCandidateScanCount = 0
    private(set) var lastItemLookupCandidateScanCount = 0
    /// buildContextMenuで構築した項目。NSMenuItem.tagで対応するactionを引くために保持する
    /// (テスト観測用にsetのみprivateにしている)。
    private(set) var currentContextMenuItems: [FileContextMenuItem] = []
    /// ホバープレビュー用の状態。0.5秒静止でポップオーバーを出し、行を離れる・
    /// コンテキストメニュー表示・ドラッグ開始・リスト更新のいずれでもキャンセルする。
    private var hoverTimer: Timer?
    private var hoverRow: Int = -1
    private var previewPopover: NSPopover?
    /// ポップオーバー表示中だけウィンドウのキー喪失を監視する(presentHoverPreviewで登録、
    /// cancelHoverPreviewで解除。登録漏れ・解除漏れが無いよう常に対で扱う)。
    private var windowResignKeyObserver: NSObjectProtocol?
    /// インライン編集中の項目のURL。編集していない間はnil。configureNameCellが、この
    /// URLの行だけテキスト内容・編集可能状態への上書きをスキップするために参照する
    /// (非同期のアイコン解決によるセル再構成が、編集中の入力を消してしまわないようにするため)。
    private(set) var inlineRenamingURL: URL?
    /// ペイン幅の差分配分に使う直前の実効列幅。クリップ幅からNSTableViewの列間余白を
    /// 除いた値を保持し、通常のフレーム変更時だけ旧幅として使う。
    private var lastAvailableColumnWidth: CGFloat?
    /// サイズ・更新日時・場所列について、最後の手動指定幅(初回はdefaultWidth)を保持する。
    /// 自動圧縮中の現在幅とは分離し、ペイン再拡大時の復元先に使う。
    private var preferredColumnWidths: [FileListColumn: CGFloat] = [:]
    private var isApplyingColumnWidths = false
    private weak var observedClipView: NSClipView?
    private var pendingVisibleItemsByURL: [URL: FileItem] = [:]
    private var visibleItemsNotificationTask: Task<Void, Never>?

    init(parent: FileListView) {
      self.parent = parent
    }

    func item(for url: URL) -> FileItem? {
      lastItemLookupCandidateScanCount = 1
      guard let row = rowIndexByURL[url], items.indices.contains(row) else { return nil }
      return items[row].item
    }

    func reloadChangedGitStatusRows(
      from oldStatuses: [URL: GitFileStatus]?,
      to newStatuses: [URL: GitFileStatus]?,
      tableView: NSTableView
    ) {
      let rows = changedGitStatusRows(from: oldStatuses, to: newStatuses)
      let nameColumn = tableView.column(withIdentifier: FileListColumn.name.identifier)
      guard !rows.isEmpty, nameColumn >= 0 else { return }
      tableView.reloadData(
        forRowIndexes: rows,
        columnIndexes: IndexSet(integer: nameColumn))
    }

    func changedGitStatusRows(
      from oldStatuses: [URL: GitFileStatus]?,
      to newStatuses: [URL: GitFileStatus]?
    ) -> IndexSet {
      changedStatusRows(from: oldStatuses, to: newStatuses)
    }

    func reloadChangedCloudStatusRows(
      from oldStatuses: [URL: CloudDownloadStatus]?,
      to newStatuses: [URL: CloudDownloadStatus]?,
      tableView: NSTableView
    ) {
      let rows = changedCloudStatusRows(from: oldStatuses, to: newStatuses)
      let nameColumn = tableView.column(withIdentifier: FileListColumn.name.identifier)
      guard !rows.isEmpty, nameColumn >= 0 else { return }
      tableView.reloadData(
        forRowIndexes: rows,
        columnIndexes: IndexSet(integer: nameColumn))
    }

    func changedCloudStatusRows(
      from oldStatuses: [URL: CloudDownloadStatus]?,
      to newStatuses: [URL: CloudDownloadStatus]?
    ) -> IndexSet {
      changedStatusRows(from: oldStatuses, to: newStatuses)
    }

    private func changedStatusRows<Value: Equatable>(
      from oldStatuses: [URL: Value]?,
      to newStatuses: [URL: Value]?
    ) -> IndexSet {
      let oldStatuses = oldStatuses ?? [:]
      let newStatuses = newStatuses ?? [:]
      let changedURLs = Set(
        Set(oldStatuses.keys).union(newStatuses.keys).filter {
          oldStatuses[$0] != newStatuses[$0]
        })
      lastStatusRowCandidateScanCount = changedURLs.count
      return IndexSet(changedURLs.compactMap { rowIndexByURL[$0] })
    }

    // CoordinatorはNSObjectを継承するためisolated deinitの対象外(nonisolatedのまま)。
    // 表示モード切替(.list→.icon)等、通常のキャンセル経路(applyDiff/menuNeedsUpdate/
    // pasteboardWriterForRow)を通らずにCoordinatorが解放されるケースでタイマー・
    // ポップオーバー・通知observerを確実に後始末する。Coordinatorの生成・破棄は常に
    // MainActor上(SwiftUIのmakeCoordinator/更新サイクル)で起こる前提でassumeIsolatedを使う。
    deinit {
      MainActor.assumeIsolated {
        visibleItemsNotificationTask?.cancel()
        cancelHoverPreview()
        NotificationCenter.default.removeObserver(self)
      }
    }

    func observeWidthChanges(in scrollView: NSScrollView) {
      let clipView = scrollView.contentView
      guard observedClipView !== clipView else { return }
      if let observedClipView {
        NotificationCenter.default.removeObserver(
          self, name: NSView.frameDidChangeNotification, object: observedClipView)
      }
      observedClipView = clipView
      clipView.postsFrameChangedNotifications = true
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(clipViewFrameDidChange(_:)),
        name: NSView.frameDidChangeNotification,
        object: clipView)
    }

    @objc private func clipViewFrameDidChange(_ notification: Notification) {
      guard let clipView = notification.object as? NSClipView else { return }
      redistributeColumns(toAvailableWidth: clipView.bounds.width)
    }

    /// 現在の列幅へ、前回からの利用可能幅の差分だけを優先順位どおりに配分する。
    /// 列の表示ON/OFF時は、再構築後の幅合計を旧available相当として再計算することで、
    /// 追加列が必要とする幅や削除列が空けた幅も同じ規則で処理する。
    func redistributeColumns(
      toAvailableWidth viewportWidth: CGFloat,
      resetReferenceWidth: Bool = false
    ) {
      guard
        FileBrowserCapability.supports(
          .listColumnWidthDistribution, for: parent.presentation.viewMode),
        let tableView
      else {
        lastAvailableColumnWidth = nil
        return
      }
      // makeNSView直後はクリップ幅が0のままupdateNSViewへ入ることがある。この値を
      // 初期幅として確定せず、最初の有効なframeDidChange/updateNSViewで必ずfittingする。
      guard viewportWidth > 0 else {
        if resetReferenceWidth {
          lastAvailableColumnWidth = nil
        }
        return
      }
      let currentWidths = Dictionary(
        uniqueKeysWithValues: tableView.tableColumns.compactMap { tableColumn in
          FileListColumn(rawValue: tableColumn.identifier.rawValue).map { ($0, tableColumn.width) }
        })
      guard !currentWidths.isEmpty else {
        lastAvailableColumnWidth = nil
        return
      }
      let availableWidth = FileListColumnWidthPolicy.effectiveAvailableWidth(
        viewportWidth: viewportWidth,
        columnCount: currentWidths.count,
        intercellSpacingWidth: tableView.intercellSpacing.width)
      let currentWidthSum = currentWidths.values.reduce(0, +)
      let state = FileListColumnWidthState(
        currentWidths: currentWidths,
        preferredWidths: preferredColumnWidths,
        minimumWidths: Dictionary(
          uniqueKeysWithValues: currentWidths.keys.map { ($0, $0.minWidth) }))
      if resetReferenceWidth || lastAvailableColumnWidth == nil {
        let result = FileListColumnWidthPolicy.fitting(
          availableWidth: availableWidth,
          state: state)
        lastAvailableColumnWidth = availableWidth
        applyColumnWidths(result.currentWidths, replacing: currentWidths, to: tableView)
        return
      }
      let referenceWidth: CGFloat
      if let lastAvailableColumnWidth, availableWidth > lastAvailableColumnWidth {
        // 全列が最小幅で横スクロール中なら、ペインが列幅合計へ戻るまでは復元しない。
        // 名前列の手動縮小で余白がある場合はlastAvailableColumnWidthのほうが大きいため、
        // ペイン拡大分は裁定どおりそのまま名前列へ加算される。
        referenceWidth = max(lastAvailableColumnWidth, currentWidthSum)
      } else if let lastAvailableColumnWidth, availableWidth < lastAvailableColumnWidth {
        // 手動縮小で余白がある場合は、余白を使い切ってから列の圧縮を始める。
        referenceWidth = min(lastAvailableColumnWidth, currentWidthSum)
      } else {
        referenceWidth = lastAvailableColumnWidth ?? availableWidth
      }
      let result = FileListColumnWidthPolicy.applying(
        availableWidthChangeFrom: referenceWidth,
        to: availableWidth,
        state: state)
      lastAvailableColumnWidth = availableWidth
      applyColumnWidths(result.currentWidths, replacing: currentWidths, to: tableView)
    }

    private func applyColumnWidths(
      _ newWidths: [FileListColumn: CGFloat],
      replacing currentWidths: [FileListColumn: CGFloat],
      to tableView: NSTableView
    ) {
      guard newWidths != currentWidths else { return }
      isApplyingColumnWidths = true
      defer { isApplyingColumnWidths = false }
      for tableColumn in tableView.tableColumns {
        guard let column = FileListColumn(rawValue: tableColumn.identifier.rawValue),
          let width = newWidths[column],
          width != tableColumn.width
        else { continue }
        tableColumn.width = width
      }
    }

    /// .noColumnAutoresizingではユーザーが動かした列だけが通知対象になる。自動配分中の通知は
    /// ガードで捨て、復元対象列の手動幅だけを次回拡大時の希望幅として記録する。
    func tableViewColumnDidResize(_ notification: Notification) {
      guard !isApplyingColumnWidths,
        let tableColumn = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
        let column = FileListColumn(rawValue: tableColumn.identifier.rawValue),
        [.size, .modifiedAt, .location].contains(column)
      else { return }
      preferredColumnWidths[column] = tableColumn.width
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
      items.count
    }

    /// NSTrackingArea(owner: self)からの転送で呼ばれる(NSObjectのためコンパイル時の
    /// 型チェックは効かず@objcが必須)。行が変わるたびにタイマーを張り直し、0.5秒後も
    /// 同じ行にとどまっていればプレビューを出す。
    @objc func mouseMoved(with event: NSEvent) {
      guard let tableView else { return }
      let point = tableView.convert(event.locationInWindow, from: nil)
      let row = tableView.row(at: point)
      guard row != hoverRow else { return }
      hoverRow = row
      cancelHoverPreview()
      guard row >= 0, row < items.count else { return }
      let item = items[row].item
      // ローカルファイルのみ(SFTP等のリモートはサムネイル生成にダウンロードが必要なため対象外)
      guard item.url.isFileURL, !item.isDirectory else { return }
      hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) {
        [weak self] _ in
        Task { @MainActor in
          self?.presentHoverPreview(for: item, row: row)
        }
      }
    }

    @objc func mouseExited(with event: NSEvent) {
      hoverRow = -1
      cancelHoverPreview()
    }

    private func presentHoverPreview(for item: FileItem, row: Int) {
      guard let tableView,
        // 表示直前の再検証: ドラッグ・メニュー表示・スクロールで行が変わっていたら出さない
        // (ドラッグ開始はpasteboardWriterForRowのcancelHoverPreview呼び出しで別途担保する)
        row == hoverRow, row < items.count, items[row].item.url == item.url,
        let window = tableView.window,
        window.isKeyWindow
      else { return }
      let popover = NSPopover()
      popover.behavior = .semitransient
      popover.animates = false
      popover.contentViewController = NSHostingController(
        rootView: FilePreviewContentView(item: item))
      let rowRect = tableView.rect(ofRow: row)
      popover.show(relativeTo: rowRect, of: tableView, preferredEdge: .maxX)
      previewPopover = popover
      // ウィンドウがキーを失った場合(他ウィンドウ・他アプリへフォーカスが移った場合)は
      // 行を離れるmouseExitedが発火しないため、明示的にポップオーバーを閉じる。
      windowResignKeyObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.didResignKeyNotification, object: window, queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          self?.cancelHoverPreview()
        }
      }
    }

    private func cancelHoverPreview() {
      hoverTimer?.invalidate()
      hoverTimer = nil
      previewPopover?.close()
      previewPopover = nil
      if let windowResignKeyObserver {
        NotificationCenter.default.removeObserver(windowResignKeyObserver)
        self.windowResignKeyObserver = nil
      }
      // hoverRowをリセットしないと、コンテキストメニュー表示等でキャンセルされた後に
      // マウスが同じ行に留まっていた場合、mouseMovedのguard row != hoverRowに弾かれて
      // 再表示されない(mouseExited以外の全キャンセル経路で同じ行への復帰を保証するため)。
      hoverRow = -1
    }

    /// 差分が大きい場合(削除+追加+更新が全体のこの割合を超える場合)は個別アニメーションより
    /// reloadData()一発のほうが速く確実なため、そちらへフォールバックする。
    static var diffFallbackRatioThreshold: Double { 0.3 }

    struct RowDiff: Equatable {
      var removed = IndexSet()
      var inserted = IndexSet()
      /// 新配列でのインデックス。同じURL(同じ項目)だがsize/modifiedAt/depth/isExpanded等の
      /// 内容が変わった行(フォルダの展開/折りたたみ・ロード中状態の切り替えもここに含まれる)。
      var updated = IndexSet()
      var usesFullReload = false
    }

    /// oldItems/newItemsが名前順にソート済みという前提で2ポインタ走査し、
    /// insert/remove/updateへ変換する。ソート順の前提が崩れていても(例:サイズ順表示中や
    /// ツリー展開でルート項目の間に子項目が挿入される場合)走査自体は必ず全項目を消費して
    /// 終了し、結果として差分率が上がりreloadDataへフォールバックするだけで、表示内容が
    /// 壊れることはない(すべての旧項目は「URL一致→updated判定」か「removed」のどちらかに、
    /// すべての新項目は「URL一致」か「inserted」のどちらかに必ず分類されるため)。
    static func computeDiff(from oldItems: [FileTreeRow], to newItems: [FileTreeRow]) -> RowDiff {
      guard !oldItems.isEmpty, !newItems.isEmpty else {
        return RowDiff(
          removed: IndexSet(oldItems.indices), inserted: IndexSet(newItems.indices),
          usesFullReload: true)
      }

      var diff = RowDiff()
      var oldIndex = 0
      var newIndex = 0
      while oldIndex < oldItems.count, newIndex < newItems.count {
        let oldRow = oldItems[oldIndex]
        let newRow = newItems[newIndex]
        if oldRow.item.url == newRow.item.url {
          if oldRow != newRow {
            diff.updated.insert(newIndex)
          }
          oldIndex += 1
          newIndex += 1
        } else if oldRow.item.name.localizedStandardCompare(newRow.item.name)
          == .orderedAscending
        {
          diff.removed.insert(oldIndex)
          oldIndex += 1
        } else {
          diff.inserted.insert(newIndex)
          newIndex += 1
        }
      }
      while oldIndex < oldItems.count {
        diff.removed.insert(oldIndex)
        oldIndex += 1
      }
      while newIndex < newItems.count {
        diff.inserted.insert(newIndex)
        newIndex += 1
      }

      // insertは既存行を動かさない末尾追記が典型(ストリーミング読込)なので件数に関わらず安価。
      // 「差分率が高い」の対象は既存行の入れ替わり(削除+更新)であり、それがoldItemsの
      // 3割を超える場合だけreloadDataへフォールバックする。
      let churnCount = diff.removed.count + diff.updated.count
      let ratio = Double(churnCount) / Double(max(oldItems.count, 1))
      diff.usesFullReload = ratio > diffFallbackRatioThreshold
      return diff
    }

    /// 計算した差分をNSTableViewへ適用する。差分率が高い場合はreloadData()一発にする。
    /// reloadData/removeRows/insertRowsはNSTableView側の選択を変化させることがあり、
    /// その変化がtableViewSelectionDidChange経由でモデルへ逆流(誤った選択のselectedItemURLsへの
    /// 書き戻し)しないようisApplyingModelSelectionで抑止する。呼び出し元(updateNSView)が
    /// この直後に必ずsyncSelectionFromModelを呼ぶため、正しい選択はURLベースで復元される。
    func applyDiff(
      from oldItems: [FileTreeRow],
      to newItems: [FileTreeRow],
      tableView: NSTableView,
      browseSignpostID: OSSignpostID? = nil
    ) {
      if let browseSignpostID {
        BrowsePerformanceSignpost.beginListDiff(
          signpostID: browseSignpostID,
          oldItemCount: oldItems.count,
          newItemCount: newItems.count)
      }
      var measurement: ListDiffMeasurement?
      defer {
        if let measurement, let browseSignpostID {
          BrowsePerformanceSignpost.endListDiff(
            signpostID: browseSignpostID,
            measurement: measurement)
          BrowsePerformanceSignpost.event(
            .listDiffApplied,
            signpostID: browseSignpostID,
            itemCount: newItems.count)
        }
      }
      // リスト更新で行番号の対応関係が崩れるため、表示中のホバープレビューは無条件で閉じる。
      cancelHoverPreview()
      // インライン編集中の項目が外部要因(他ペインからの削除・監視による外部変更反映等)で
      // 一覧から消えた場合、編集セッションを持ったまま行の対応関係が崩れないよう
      // 行の入れ替え処理より前にキャンセルしておく。
      if let url = inlineRenamingURL, !newItems.contains(where: { $0.item.url == url }) {
        if let row = oldItems.firstIndex(where: { $0.item.url == url }),
          let cellView = tableView.view(
            atColumn: tableView.column(withIdentifier: FileListColumn.name.identifier),
            row: row, makeIfNecessary: false) as? NSTableCellView,
          let textField = cellView.textField
        {
          cancelInlineRename(textField)
        } else {
          inlineRenamingURL = nil
        }
      }
      isApplyingModelSelection = true
      defer { isApplyingModelSelection = false }
      let diff = Self.computeDiff(from: oldItems, to: newItems)
      let diffMeasurement = ListDiffMeasurement(
        oldItemCount: oldItems.count,
        newItemCount: newItems.count,
        removedCount: diff.removed.count,
        insertedCount: diff.inserted.count,
        updatedCount: diff.updated.count,
        usedFullReload: diff.usesFullReload)
      measurement = diffMeasurement
      lastListDiffMeasurement = diffMeasurement
      guard !diff.usesFullReload else {
        tableView.reloadData()
        return
      }
      tableView.beginUpdates()
      if !diff.removed.isEmpty {
        tableView.removeRows(at: diff.removed, withAnimation: [])
      }
      if !diff.inserted.isEmpty {
        tableView.insertRows(at: diff.inserted, withAnimation: [])
      }
      tableView.endUpdates()
      if !diff.updated.isEmpty {
        tableView.reloadData(
          forRowIndexes: diff.updated,
          columnIndexes: IndexSet(0..<max(tableView.numberOfColumns, 1)))
      }
    }

    /// 列の追加・削除に応じて列を再構築する。ユーザーが手動でリサイズした幅は
    /// (同じ列が再度有効になった場合に備えて)引き継ぎ、初出の列だけ既定幅を使う。
    /// 列構成が変わると既存行のセルもそのままでは新しい列に追従しないため、最後に
    /// reloadData()で明示的に再取得させる。
    func rebuildColumns(
      displayOptions: FileBrowserDisplayOptions,
      presentation: FileListPresentation = .standard,
      tableView: NSTableView
    ) {
      let previousWidths = Dictionary(
        uniqueKeysWithValues: tableView.tableColumns.map { ($0.identifier, $0.width) })
      for column in tableView.tableColumns {
        tableView.removeTableColumn(column)
      }
      addColumn(
        .name, presentation: presentation, tableView: tableView,
        previousWidths: previousWidths)
      let mode = presentation.viewMode
      if FileBrowserCapability.supports(.metadataColumns, for: mode),
        displayOptions.showsKindColumn
      {
        addColumn(
          .kind, presentation: presentation, tableView: tableView,
          previousWidths: previousWidths)
      }
      if FileBrowserCapability.supports(.metadataColumns, for: mode),
        displayOptions.showsSizeColumn
      {
        addColumn(
          .size, presentation: presentation, tableView: tableView,
          previousWidths: previousWidths)
      }
      if FileBrowserCapability.supports(.metadataColumns, for: mode),
        displayOptions.showsModifiedAtColumn
      {
        addColumn(
          .modifiedAt, presentation: presentation, tableView: tableView,
          previousWidths: previousWidths)
      }
      if FileBrowserCapability.supports(.metadataColumns, for: mode),
        displayOptions.showsLocationColumn
      {
        addColumn(
          .location, presentation: presentation, tableView: tableView,
          previousWidths: previousWidths)
      }
      if FileBrowserCapability.supports(.metadataColumns, for: mode),
        displayOptions.showsTagsColumn
      {
        addColumn(
          .tags, presentation: presentation, tableView: tableView,
          previousWidths: previousWidths)
      }
      // 通常リストはペイン幅の差分を純関数で配分する。カラム用ミニリストは従来どおり
      // 単一の名前列を表示幅へ追従させる。
      tableView.columnAutoresizingStyle =
        FileBrowserCapability.supports(.listColumnWidthDistribution, for: mode)
        ? .noColumnAutoresizing : .firstColumnOnlyAutoresizingStyle
      tableView.reloadData()
    }

    private func addColumn(
      _ column: FileListColumn,
      presentation: FileListPresentation,
      tableView: NSTableView,
      previousWidths: [NSUserInterfaceItemIdentifier: CGFloat]
    ) {
      let tableColumn = NSTableColumn(identifier: column.identifier)
      tableColumn.title = column.title
      tableColumn.minWidth = column.minWidth
      // 通常リストでは全列を自前配分し、カラム用ミニリストの名前列だけは従来の
      // autoresizingを維持する。ユーザーの手動リサイズはどの列でも許可する。
      tableColumn.resizingMask =
        FileBrowserCapability.supports(.columnNameChevron, for: presentation.viewMode)
          && column == .name
        ? [.userResizingMask, .autoresizingMask] : [.userResizingMask]
      if [.size, .modifiedAt, .location].contains(column),
        preferredColumnWidths[column] == nil
      {
        preferredColumnWidths[column] = column.defaultWidth
      }
      tableColumn.width =
        previousWidths[column.identifier] ?? preferredColumnWidths[column] ?? column.defaultWidth
      tableView.addTableColumn(tableColumn)
    }

    /// 現在のソート列だけに標準の昇降インジケータを表示する。表示オプションシートや
    /// メニューから状態が変わった場合もupdateNSView経由でここへ到達する。
    func syncSortIndicators(
      sortOrder: FileItemSortOrder, ascending: Bool, tableView: NSTableView
    ) {
      for tableColumn in tableView.tableColumns {
        let column = FileListColumn(rawValue: tableColumn.identifier.rawValue)
        let indicator: NSImage?
        if column?.sortOrder == sortOrder {
          indicator = NSImage(
            systemSymbolName: ascending ? "chevron.up" : "chevron.down",
            accessibilityDescription: nil)
        } else {
          indicator = nil
        }
        tableView.setIndicatorImage(indicator, in: tableColumn)
      }
    }

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
      guard let column = FileListColumn(rawValue: tableColumn.identifier.rawValue),
        let sortOrder = column.sortOrder
      else { return }
      parent.onSortRequest(sortOrder)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow _: Int) -> NSTableRowView? {
      let identifier = NSUserInterfaceItemIdentifier("themed-file-row")
      let rowView =
        tableView.makeView(withIdentifier: identifier, owner: nil)
        as? ThemedTableRowView ?? ThemedTableRowView()
      rowView.identifier = identifier
      rowView.tableView = tableView as? ActivatingTableView
      return rowView
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
      -> NSView?
    {
      guard let column = tableColumn.flatMap({ FileListColumn(rawValue: $0.identifier.rawValue) }),
        row < items.count
      else {
        return nil
      }
      let treeRow = items[row]
      let item = treeRow.item
      if item.tags == nil, parent.onVisibleItemsChange != nil {
        scheduleVisibleItemNotification(item)
      }
      switch column {
      case .name:
        return nameCellView(for: treeRow, tableView: tableView)
      case .kind:
        return textCellView(
          .kind, text: item.kindDisplayName, alignment: .left, tableView: tableView)
      case .size:
        return textCellView(.size, text: item.displaySize, alignment: .right, tableView: tableView)
      case .modifiedAt:
        return textCellView(
          .modifiedAt, text: item.displayModifiedAt, alignment: .left, tableView: tableView)
      case .location:
        return textCellView(
          .location, text: item.displayParentPath, alignment: .left, tableView: tableView,
          isSecondary: true)
      case .tags:
        return textCellView(
          .tags, text: item.displayTags, alignment: .left, tableView: tableView)
      }
    }

    private func scheduleVisibleItemNotification(_ item: FileItem) {
      pendingVisibleItemsByURL[item.url] = item
      guard visibleItemsNotificationTask == nil else { return }
      visibleItemsNotificationTask = Task { @MainActor [weak self] in
        await Task.yield()
        guard !Task.isCancelled, let self else { return }
        let visibleItems = Array(self.pendingVisibleItemsByURL.values)
        self.pendingVisibleItemsByURL.removeAll(keepingCapacity: true)
        self.visibleItemsNotificationTask = nil
        guard !visibleItems.isEmpty else { return }
        self.parent.onVisibleItemsChange?(visibleItems)
      }
    }

    /// 名前列: NSTableCellView+NSImageView(SF Symbol)+NSTextField(labelWithString:)の
    /// ネイティブ構成に、フォルダその場展開の開閉三角・子ロード中スピナー・深さに応じた
    /// インデントを加えたもの。選択時の文字色反転はNSTableCellViewのbackgroundStyle機構に
    /// 任せるため明示的な色設定はしない。
    private func nameCellView(for row: FileTreeRow, tableView: NSTableView) -> NSTableCellView {
      let identifier = FileListColumn.name.identifier
      let cellView: NameCellView
      if let reused = tableView.makeView(withIdentifier: identifier, owner: self)
        as? NameCellView,
        reused.imageView != nil, reused.textField != nil
      {
        cellView = reused
      } else {
        cellView = Self.makeNameCellView(identifier: identifier)
      }
      configureNameCell(cellView, for: row)
      return cellView
    }

    private static func makeNameCellView(identifier: NSUserInterfaceItemIdentifier)
      -> NameCellView
    {
      let cellView = NameCellView()
      cellView.identifier = identifier

      let disclosureButton = cellView.disclosureButton
      disclosureButton.translatesAutoresizingMaskIntoConstraints = false
      disclosureButton.isBordered = false
      disclosureButton.imagePosition = .imageOnly
      disclosureButton.setButtonType(.momentaryChange)
      disclosureButton.title = ""

      let loadingIndicator = cellView.loadingIndicator
      loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
      loadingIndicator.style = .spinning
      loadingIndicator.controlSize = .small
      loadingIndicator.isDisplayedWhenStopped = false

      let imageView = NSImageView()
      imageView.translatesAutoresizingMaskIntoConstraints = false
      imageView.imageScaling = .scaleProportionallyDown

      let textField = NSTextField(labelWithString: "")
      textField.translatesAutoresizingMaskIntoConstraints = false
      textField.lineBreakMode = .byTruncatingMiddle

      let folderChevron = cellView.folderChevron
      folderChevron.translatesAutoresizingMaskIntoConstraints = false
      folderChevron.imageScaling = .scaleProportionallyDown
      folderChevron.image = NSImage(
        systemSymbolName: "chevron.right", accessibilityDescription: "フォルダを開く")
      folderChevron.contentTintColor = .secondaryLabelColor
      folderChevron.setAccessibilityIdentifier("file-column-chevron")

      let tagDotsStack = cellView.tagDotsStack
      tagDotsStack.translatesAutoresizingMaskIntoConstraints = false
      tagDotsStack.orientation = .horizontal
      tagDotsStack.spacing = 3
      tagDotsStack.alignment = .centerY

      cellView.addSubview(disclosureButton)
      cellView.addSubview(loadingIndicator)
      cellView.addSubview(imageView)
      cellView.addSubview(textField)
      cellView.addSubview(tagDotsStack)
      cellView.addSubview(folderChevron)
      cellView.imageView = imageView
      cellView.textField = textField

      let indentConstraint = disclosureButton.leadingAnchor.constraint(
        equalTo: cellView.leadingAnchor)
      cellView.indentConstraint = indentConstraint
      let disclosureWidthConstraint = disclosureButton.widthAnchor.constraint(
        equalToConstant: treeDisclosureSlotWidth)
      cellView.disclosureWidthConstraint = disclosureWidthConstraint
      let textTrailingToCellConstraint = textField.trailingAnchor.constraint(
        lessThanOrEqualTo: cellView.trailingAnchor)
      cellView.textTrailingToCellConstraint = textTrailingToCellConstraint
      let textTrailingToChevronConstraint = textField.trailingAnchor.constraint(
        lessThanOrEqualTo: folderChevron.leadingAnchor, constant: -4)
      cellView.textTrailingToChevronConstraint = textTrailingToChevronConstraint
      let textTrailingToDotsConstraint = textField.trailingAnchor.constraint(
        lessThanOrEqualTo: tagDotsStack.leadingAnchor, constant: -6)
      cellView.textTrailingToDotsConstraint = textTrailingToDotsConstraint
      let dotsTrailingToCellConstraint = tagDotsStack.trailingAnchor.constraint(
        equalTo: cellView.trailingAnchor, constant: -4)
      cellView.dotsTrailingToCellConstraint = dotsTrailingToCellConstraint
      let dotsTrailingToChevronConstraint = tagDotsStack.trailingAnchor.constraint(
        equalTo: folderChevron.leadingAnchor, constant: -5)
      cellView.dotsTrailingToChevronConstraint = dotsTrailingToChevronConstraint
      let iconWidthConstraint = imageView.widthAnchor.constraint(equalToConstant: 16)
      cellView.iconWidthConstraint = iconWidthConstraint
      let iconHeightConstraint = imageView.heightAnchor.constraint(equalToConstant: 16)
      cellView.iconHeightConstraint = iconHeightConstraint

      NSLayoutConstraint.activate([
        indentConstraint,
        disclosureButton.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
        disclosureWidthConstraint,
        disclosureButton.heightAnchor.constraint(equalToConstant: treeDisclosureSlotWidth),
        loadingIndicator.centerXAnchor.constraint(equalTo: disclosureButton.centerXAnchor),
        loadingIndicator.centerYAnchor.constraint(equalTo: disclosureButton.centerYAnchor),
        imageView.leadingAnchor.constraint(equalTo: disclosureButton.trailingAnchor, constant: 4),
        imageView.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
        iconWidthConstraint,
        iconHeightConstraint,
        textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
        textTrailingToCellConstraint,
        textField.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
        tagDotsStack.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
        folderChevron.trailingAnchor.constraint(equalTo: cellView.trailingAnchor, constant: -6),
        folderChevron.centerYAnchor.constraint(equalTo: cellView.centerYAnchor),
        folderChevron.widthAnchor.constraint(equalToConstant: 8),
        folderChevron.heightAnchor.constraint(equalToConstant: 12),
      ])
      return cellView
    }

    /// 実アイコン解決の非同期タスクが進行中のURL集合。スクロールで同じ行が何度も
    /// 構築される際に重複Taskを発行しないための管理。
    private var iconResolutionRequests = FileListIconResolutionRequests()

    func invalidateIconResolutionRequests() {
      iconResolutionRequests.cancelAll()
    }

    private var rowIconResolutionSize: NSSize {
      parent.displayOptions.iconSize.listResolvedIconSize
    }

    private func configureNameCell(_ cellView: NameCellView, for row: FileTreeRow) {
      guard let imageView = cellView.imageView, let textField = cellView.textField else { return }
      let item = row.item
      let mode = parent.presentation.viewMode
      let showsColumnChevron = FileBrowserCapability.supports(.columnNameChevron, for: mode)
      let supportsTreeExpansion = FileBrowserCapability.supports(.listTreeExpansion, for: mode)
      let iconPointSize = parent.displayOptions.iconSize.listIconPointSize
      cellView.iconWidthConstraint.constant = iconPointSize
      cellView.iconHeightConstraint.constant = iconPointSize
      cellView.indentConstraint.constant =
        supportsTreeExpansion ? CGFloat(row.depth) * treeIndentPerLevel : 0
      cellView.disclosureWidthConstraint.constant =
        supportsTreeExpansion ? treeDisclosureSlotWidth : 0
      cellView.textTrailingToCellConstraint.isActive = !showsColumnChevron
      cellView.textTrailingToChevronConstraint.isActive = showsColumnChevron
      cellView.folderChevron.isHidden = !showsColumnChevron || !item.isDirectory
      configureStatusAndTagDots(
        in: cellView, for: item, showsColumnChevron: showsColumnChevron)

      cellView.loadingIndicator.isHidden = !supportsTreeExpansion || !row.isLoadingChildren
      if supportsTreeExpansion, row.isLoadingChildren {
        cellView.loadingIndicator.startAnimation(nil)
      } else {
        cellView.loadingIndicator.stopAnimation(nil)
      }
      if supportsTreeExpansion, row.isExpandable, !row.isLoadingChildren {
        cellView.disclosureButton.isHidden = false
        cellView.disclosureButton.image = NSImage(
          systemSymbolName: row.isExpanded ? "chevron.down" : "chevron.right",
          accessibilityDescription: row.isExpanded ? "折りたたむ" : "展開する")
        cellView.disclosureButton.target = self
        cellView.disclosureButton.action = #selector(handleDisclosureClick(_:))
        cellView.disclosureButton.setAccessibilityIdentifier("file-disclosure-\(item.name)")
      } else {
        cellView.disclosureButton.isHidden = true
        cellView.disclosureButton.image = nil
        cellView.disclosureButton.target = nil
        cellView.disclosureButton.action = nil
        cellView.disclosureButton.setAccessibilityIdentifier(nil)
      }

      let provider = FileIconProvider.shared
      if let resolved = provider.cachedResolvedIcon(for: item, size: rowIconResolutionSize) {
        // キャッシュヒット時は同期で即時反映し、reloadDataは発生させない。
        imageView.image = resolved
      } else {
        imageView.image = provider.icon(for: item)
        resolveIconAsync(for: item)
      }
      // インライン編集中の行は、非同期アイコン解決によるセル再構成が入力中のテキストや
      // 編集可能状態を消してしまわないよう、内容へは一切触れない。
      guard inlineRenamingURL != item.url else { return }
      textField.stringValue = item.name
      // 再利用されたセルビューがインライン編集後のisEditable=trueや識別子付きのまま
      // 渡ってくることがないよう、通常表示のたびに防御的に編集不可へ戻す。
      textField.isEditable = false
      textField.isSelectable = false
      textField.setAccessibilityIdentifier(nil)
    }

    private func configureStatusAndTagDots(
      in cellView: NameCellView,
      for item: FileItem,
      showsColumnChevron: Bool
    ) {
      for view in cellView.tagDotsStack.arrangedSubviews {
        cellView.tagDotsStack.removeArrangedSubview(view)
        view.removeFromSuperview()
      }
      let supportsTagDisplay = FileBrowserCapability.supports(
        .finderTagDisplay,
        for: parent.presentation.viewMode)
      let tags = supportsTagDisplay ? FinderTagPalette.systemTags(from: item.tags) : []
      let summary = FinderTagDisplaySummary.make(from: tags)
      let gitStatus: GitFileStatus?
      if let statuses = parent.gitStatuses,
        FileBrowserCapability.supports(.gitStatusDisplay, for: parent.presentation.viewMode)
      {
        gitStatus = statuses[item.url]
      } else {
        gitStatus = nil
      }
      let cloudStatus: CloudDownloadStatus?
      if let statuses = parent.cloudDownloadStatuses,
        FileBrowserCapability.supports(
          .cloudDownloadStatusDisplay,
          for: parent.presentation.viewMode)
      {
        cloudStatus = statuses[item.url]
      } else {
        cloudStatus = nil
      }
      let hasIndicators =
        cloudStatus?.indicatorLabel != nil || gitStatus != nil || !summary.visibleTags.isEmpty
      cellView.tagDotsStack.isHidden = !hasIndicators
      cellView.textTrailingToCellConstraint.isActive = !hasIndicators && !showsColumnChevron
      cellView.textTrailingToChevronConstraint.isActive = !hasIndicators && showsColumnChevron
      cellView.textTrailingToDotsConstraint.isActive = hasIndicators
      cellView.dotsTrailingToCellConstraint.isActive = hasIndicators && !showsColumnChevron
      cellView.dotsTrailingToChevronConstraint.isActive = hasIndicators && showsColumnChevron
      guard hasIndicators else { return }

      var accessibilityLabels: [String] = []
      if let status = cloudStatus, let symbol = status.indicatorSystemImage,
        let label = status.indicatorLabel
      {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        let imageView = NSImageView(image: image ?? NSImage())
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        imageView.contentTintColor = .secondaryLabelColor
        imageView.setAccessibilityIdentifier(status.indicatorIdentifier)
        imageView.toolTip = status.helpText
        cellView.tagDotsStack.addArrangedSubview(imageView)
        accessibilityLabels.append(label)
      }
      if let gitStatus {
        let dot = NSView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = GitStatusIndicatorStyle.color(for: gitStatus).cgColor
        dot.setAccessibilityIdentifier("git-status-\(gitStatus.rawValue)")
        NSLayoutConstraint.activate([
          dot.widthAnchor.constraint(equalToConstant: 8),
          dot.heightAnchor.constraint(equalToConstant: 8),
        ])
        cellView.tagDotsStack.addArrangedSubview(dot)
        accessibilityLabels.append(GitStatusIndicatorStyle.accessibilityLabel(for: gitStatus))
      }

      for tag in summary.visibleTags {
        let dot = NSView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        if tag.color == .none {
          dot.layer?.backgroundColor = NSColor.clear.cgColor
          dot.layer?.borderColor = NSColor.secondaryLabelColor.cgColor
          dot.layer?.borderWidth = 1
        } else {
          dot.layer?.backgroundColor = FinderTagPalette.nsColor(for: tag.color).cgColor
        }
        NSLayoutConstraint.activate([
          dot.widthAnchor.constraint(equalToConstant: 8),
          dot.heightAnchor.constraint(equalToConstant: 8),
        ])
        cellView.tagDotsStack.addArrangedSubview(dot)
      }
      accessibilityLabels.append(contentsOf: tags.map(\.name))
      cellView.tagDotsStack.setAccessibilityElement(true)
      cellView.tagDotsStack.setAccessibilityLabel(accessibilityLabels.joined(separator: "、"))
    }

    /// 開閉三角がクリックされたときの処理。クリック時点でtableView.row(for:)から実際の
    /// 行を引き直す(セル再利用や行の入れ替わりによるクロージャ捕捉値の陳腐化を避けるため、
    /// handleDoubleClick等の他ハンドラと同じ「クリック時点で引き直す」方針)。
    @objc private func handleDisclosureClick(_ sender: NSButton) {
      guard let tableView else { return }
      let row = tableView.row(for: sender)
      guard row >= 0, row < items.count else { return }
      let isOptionClick = NSEvent.modifierFlags.contains(.option)
      parent.onToggleExpand(items[row].item, isOptionClick)
    }

    /// ActivatingTableView.onRequestExpandSelectionから呼ばれる(→キー)。単一選択でのみ
    /// 動作する(複数選択・選択なしはfalseを返し既定動作へ委ねる)。
    func handleRightArrow() -> Bool {
      if FileBrowserCapability.supports(
        .columnNavigation, for: parent.presentation.viewMode)
      {
        return parent.onMoveToNextColumn()
      }
      guard let tableView, tableView.selectedRowIndexes.count == 1,
        let selectedIndex = tableView.selectedRowIndexes.first,
        items.indices.contains(selectedIndex)
      else { return false }
      let action = FileTreeKeyboardNavigation.rightArrowAction(selectedRow: items[selectedIndex])
      guard case .expand(let url) = action, let item = item(for: url)
      else { return false }
      parent.onToggleExpand(item, false)
      return true
    }

    /// ActivatingTableView.onRequestCollapseSelectionから呼ばれる(←キー)。単一選択でのみ
    /// 動作する。
    func handleLeftArrow() -> Bool {
      if FileBrowserCapability.supports(
        .columnNavigation, for: parent.presentation.viewMode)
      {
        return parent.onMoveToPreviousColumn()
      }
      guard let tableView, tableView.selectedRowIndexes.count == 1,
        let selectedIndex = tableView.selectedRowIndexes.first,
        items.indices.contains(selectedIndex)
      else { return false }
      let action = FileTreeKeyboardNavigation.leftArrowAction(
        selectedRow: items[selectedIndex], rows: items, selectedIndex: selectedIndex)
      switch action {
      case .collapse(let url):
        guard let item = item(for: url) else { return false }
        parent.onToggleExpand(item, false)
        return true
      case .selectParent(let url):
        parent.selectedItemURLs = [url]
        return true
      case .expand, .none:
        return false
      }
    }

    /// 水平キー操作の移動先ミニリストを実際のfirst responderにする。以後の↑↓キーは
    /// NSTableView標準の行移動として処理され、ローカルイベントモニターを必要としない。
    func focus(itemURL: URL, tableView: NSTableView) {
      if let row = rowIndexByURL[itemURL] {
        if tableView.selectedRowIndexes != IndexSet(integer: row) {
          isApplyingModelSelection = true
          tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
          isApplyingModelSelection = false
        }
        tableView.scrollRowToVisible(row)
      }
      tableView.window?.makeFirstResponder(tableView)
    }

    /// アプリの実アイコン・画像等のミニサムネイルを非同期解決し、その行がまだ同じURLを
    /// 表示している場合だけ名前列を再描画する。SFTP等のリモートはFileIconProvider側で
    /// nilを返すため無駄なreloadは発生しない。
    private func resolveIconAsync(for item: FileItem) {
      let provider = FileIconProvider.shared
      let requestedSize = rowIconResolutionSize
      guard item.url.isFileURL,
        !provider.isKnownUnresolvable(for: item, size: requestedSize),
        let requestID = iconResolutionRequests.begin(for: item.url)
      else { return }
      let url = item.url
      let task = Task { @MainActor [weak self] in
        let resolved = await FileIconProvider.shared.resolvedIcon(
          for: item, size: requestedSize)
        guard let self else { return }
        guard self.iconResolutionRequests.finish(for: url, id: requestID),
          !Task.isCancelled, resolved != nil,
          FileListIconResolution.shouldApply(
            requestedSize, currentSize: self.rowIconResolutionSize),
          let tableView = self.tableView,
          let row = self.rowIndexByURL[url]
        else { return }
        let nameColumnIndex = tableView.column(withIdentifier: FileListColumn.name.identifier)
        guard nameColumnIndex >= 0 else { return }
        tableView.reloadData(
          forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: nameColumnIndex))
      }
      iconResolutionRequests.attach(task, for: url, id: requestID)
    }

    private func textCellView(
      _ column: FileListColumn,
      text: String,
      alignment: NSTextAlignment,
      tableView: NSTableView,
      isSecondary: Bool = false
    ) -> NSTextField {
      let textField: NSTextField
      if let reused = tableView.makeView(withIdentifier: column.identifier, owner: self)
        as? NSTextField
      {
        textField = reused
      } else {
        textField = NSTextField(labelWithString: "")
        textField.identifier = column.identifier
        textField.lineBreakMode = .byTruncatingMiddle
      }
      textField.stringValue = text
      textField.alignment = alignment
      textField.textColor = isSecondary ? .secondaryLabelColor : .labelColor
      return textField
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
      guard !isApplyingModelSelection, let tableView = notification.object as? NSTableView else {
        return
      }
      let selectedURLs = Set(
        tableView.selectedRowIndexes.compactMap { row in
          row < items.count ? items[row].item.url : nil
        })
      if parent.selectedItemURLs != selectedURLs {
        parent.selectedItemURLs = selectedURLs
      }
    }

    /// モデル側(キーボード操作等によるselectedItemURLsの変更)をNSTableViewへ反映する。
    /// 実際に選択が異なる場合のみselectRowIndexesし、tableViewSelectionDidChangeへの
    /// 逆流をisApplyingModelSelectionで防ぐ。
    func syncSelectionFromModel(_ selectedItemURLs: Set<URL>, tableView: NSTableView) {
      // AppKitがCommand/Shiftクリックによる選択拡張を確定させている最中(ActivatingTableView.
      // mouseDown内、onActivate()起因の非同期再描画が割り込みうる区間)は、モデル側の値がまだ
      // 追いついていない可能性があるため同期を見送る。クリック処理が完了すれば通常の
      // tableViewSelectionDidChange経路でモデルへ書き戻され、次のupdateNSViewで
      // 改めて正しい値が同期されるため、選択を取りこぼすことはない。
      if let activatingTableView = tableView as? ActivatingTableView,
        activatingTableView.isHandlingClickSelection
      {
        return
      }
      lastSelectionCandidateScanCount = selectedItemURLs.count
      let desiredIndexes = IndexSet(selectedItemURLs.compactMap { rowIndexByURL[$0] })
      guard tableView.selectedRowIndexes != desiredIndexes else { return }
      isApplyingModelSelection = true
      tableView.selectRowIndexes(desiredIndexes, byExtendingSelection: false)
      isApplyingModelSelection = false
    }

    @objc func handleDoubleClick(_ sender: NSTableView) {
      guard sender.clickedRow >= 0, sender.clickedRow < items.count else { return }
      parent.open(items[sender.clickedRow].item)
    }

    /// ActivatingTableView.onRequestInlineRenameから呼ばれる。呼び出し時点で行や選択が
    /// (スクロール・データ更新・キー操作等で)変化していれば安全側に倒し何もしない。
    func beginInlineRename(atRow row: Int) {
      guard let tableView, row >= 0, row < items.count,
        tableView.selectedRowIndexes == IndexSet(integer: row)
      else { return }
      cancelHoverPreview()
      let item = items[row].item
      let nameColumnIndex = tableView.column(withIdentifier: FileListColumn.name.identifier)
      guard nameColumnIndex >= 0,
        let cellView = tableView.view(atColumn: nameColumnIndex, row: row, makeIfNecessary: false)
          as? NSTableCellView,
        let textField = cellView.textField
      else { return }
      inlineRenamingURL = item.url
      textField.isEditable = true
      textField.isSelectable = true
      textField.delegate = self
      // isEditable/isSelectableの切り替えでAXロールが変わりうるため、UIテストが
      // ロールに依存せず確実に見つけられるよう明示的な識別子を付ける。
      textField.setAccessibilityIdentifier("file-name-inline-edit")
      guard let window = tableView.window, window.makeFirstResponder(textField) else {
        endInlineRename(textField)
        return
      }
      // ベース名(拡張子を除く部分。フォルダは拡張子を除かず全体)だけを選択する
      // (RenameTextField.swiftの既存シートと同じ選択範囲の考え方)。
      if let editor = textField.currentEditor() {
        let fullLength = (textField.stringValue as NSString).length
        let baseNameLength =
          item.isDirectory
          ? fullLength
          : (item.url.deletingPathExtension().lastPathComponent as NSString).length
        editor.selectedRange = NSRange(location: 0, length: min(baseNameLength, fullLength))
      }
    }

    /// Return/Escapeはフィールドエディタが真っ先に受け取るため、RenameTextField.swiftの
    /// Coordinatorと同じパターンでここに割り込んで確実に処理する。
    func control(
      _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
    ) -> Bool {
      guard let textField = control as? NSTextField else { return false }
      if commandSelector == #selector(NSResponder.insertNewline(_:)) {
        commitInlineRename(textField)
        return true
      }
      if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
        cancelInlineRename(textField)
        return true
      }
      return false
    }

    /// Tabキーでの移動やフォーカスロスなど、Enter/Escape以外の経路で編集が終了した場合を
    /// 確定として扱う(Finder同様、値が変わっていれば適用する)。commit/cancelは終了時に
    /// isEditable=falseへ戻すため、既に後始末済み(=commit/cancel経由で終わった)なら
    /// isEditableがfalseになっており、ここでは何もしない。
    func controlTextDidEndEditing(_ obj: Notification) {
      guard let textField = obj.object as? NSTextField, textField.isEditable else { return }
      commitInlineRename(textField)
    }

    private func commitInlineRename(_ textField: NSTextField) {
      defer { endInlineRename(textField) }
      guard let url = inlineRenamingURL, let item = item(for: url) else {
        return
      }
      let newName = textField.stringValue
      // 値が変わっていなければFinder同様に何もしない(既存rename経路への無駄な呼び出しを
      // 避ける)。空文字・重複名などの実際の検証は既存rename経路(呼び出し元のonCommit
      // InlineRename)にそのまま委ねる。
      guard newName != item.name else { return }
      parent.onCommitInlineRename(item, newName)
    }

    private func cancelInlineRename(_ textField: NSTextField) {
      if let url = inlineRenamingURL, let item = item(for: url) {
        textField.stringValue = item.name
      }
      endInlineRename(textField)
    }

    /// delegateをnilにしてから最後にfirstResponderを外す順序が重要:
    /// window.makeFirstResponder(tableView)はテキストフィールドの編集終了を同期的に
    /// 発生させうるため、先にdelegate=nilにしておかないとcontrolTextDidEndEditingが
    /// 再入してcommit/cancelを二重に呼んでしまう。
    private func endInlineRename(_ textField: NSTextField) {
      inlineRenamingURL = nil
      textField.delegate = nil
      textField.isEditable = false
      textField.isSelectable = false
      textField.setAccessibilityIdentifier(nil)
      if let window = textField.window, window.firstResponder === textField.currentEditor() {
        window.makeFirstResponder(tableView)
      }
    }

    /// 型選択(キー入力で該当する項目へジャンプする標準機構)は名前で行う。
    func tableView(
      _ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int
    )
      -> String?
    {
      guard row < items.count else { return nil }
      return items[row].item.name
    }

    /// 右クリック(またはメニューキー)のたびにAppKitから呼ばれ、その時点でtableView.clickedRowを
    /// 対象行としてメニューを再構築する。
    func menuNeedsUpdate(_ menu: NSMenu) {
      // コンテキストメニュー表示中にホバープレビューが重なって出ないようにする。
      cancelHoverPreview()
      guard let tableView else {
        menu.removeAllItems()
        currentContextMenuItems = []
        return
      }
      buildContextMenu(menu, forRow: tableView.clickedRow, tableView: tableView)
    }

    /// menuNeedsUpdateから行番号(tableView.clickedRow)を明示的に渡す形へ分離したもの。
    /// tableView.clickedRowはAppKitの内部実装が右クリック時にのみ設定する読み取り専用
    /// プロパティでテストから直接制御できないため、単体テストはこちらを直接呼ぶ。
    /// 右クリックされた行が現在の選択に含まれない場合はFinder同様その行だけを単独選択してから
    /// メニュー項目を評価する(contextMenuItemsクロージャは呼び出し元がselectedItemURLs由来の
    /// 選択集合を見て複数選択時の挙動を決めるため、正しい選択状態で呼ぶ必要がある)。
    func buildContextMenu(_ menu: NSMenu, forRow row: Int, tableView: NSTableView) {
      menu.removeAllItems()
      currentContextMenuItems = []
      // 行の外(余白)の右クリックはFinder同様、選択は変えずに背景用メニュー
      // (ペースト等、対象アイテムに依存しない操作)を出す。
      guard row >= 0, row < items.count else {
        currentContextMenuItems = parent.backgroundContextMenuItems()
        populateMenu(menu, from: currentContextMenuItems)
        return
      }
      if !tableView.selectedRowIndexes.contains(row) {
        isApplyingModelSelection = true
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        isApplyingModelSelection = false
        let selectedURLs = Set(
          tableView.selectedRowIndexes.compactMap { row in
            row < items.count ? items[row].item.url : nil
          })
        if parent.selectedItemURLs != selectedURLs {
          parent.selectedItemURLs = selectedURLs
        }
      }
      let clickedItem = items[row].item
      currentContextMenuItems = parent.contextMenuItems(clickedItem)
      populateMenu(menu, from: currentContextMenuItems)
    }

    /// FileContextMenuItem.action(値型のクロージャ)をNSMenuItem.representedObjectへ
    /// 保持するためのラッパー(NSMenuItemのrepresentedObjectはAnyObjectが必要なため)。
    /// これによりトップレベル項目・サブメニュー項目のどちらもtag/indexに頼らず
    /// 自分自身のactionへ直接たどり着ける。
    private final class ContextMenuActionBox: NSObject {
      let isEnabled: Bool
      let action: () -> Void
      init(isEnabled: Bool, action: @escaping () -> Void) {
        self.isEnabled = isEnabled
        self.action = action
      }
    }

    private func populateMenu(_ menu: NSMenu, from menuItems: [FileContextMenuItem]) {
      for menuItem in menuItems {
        if menuItem.isSeparator {
          menu.addItem(.separator())
          continue
        }
        let nsMenuItem = NSMenuItem(title: menuItem.title, action: nil, keyEquivalent: "")
        nsMenuItem.toolTip = menuItem.disabledReason
        nsMenuItem.state = menuItem.isSelected == true ? .on : .off
        if let image = menuItem.nsImage {
          nsMenuItem.image = image
          // macOS 27以降は自動設定だと画像が省略されるため、候補アプリは明示する。
          if #available(macOS 27.0, *) {
            nsMenuItem.preferredImageVisibility = .visible
          }
        } else if let systemImage = menuItem.systemImage {
          nsMenuItem.image = NSImage(
            systemSymbolName: systemImage, accessibilityDescription: nil)
        }
        if menuItem.isDestructive {
          nsMenuItem.attributedTitle = NSAttributedString(
            string: menuItem.title, attributes: [.foregroundColor: NSColor.systemRed])
        }
        if !menuItem.children.isEmpty {
          let submenu = NSMenu()
          if menuItem.isPalette {
            submenu.presentationStyle = .palette
            submenu.autoenablesItems = false
          }
          populateMenu(submenu, from: menuItem.children)
          nsMenuItem.submenu = submenu
          nsMenuItem.isEnabled = menuItem.isEnabled
        } else {
          nsMenuItem.target = self
          nsMenuItem.action = #selector(handleContextMenuAction(_:))
          nsMenuItem.isEnabled = menuItem.isEnabled
          nsMenuItem.representedObject = ContextMenuActionBox(
            isEnabled: menuItem.isEnabled, action: menuItem.action)
        }
        menu.addItem(nsMenuItem)
      }
    }

    @objc func handleContextMenuAction(_ sender: NSMenuItem) {
      // autoenablesItems=falseの設定漏れ・将来の変更に備えた防御。isEnabled=falseの項目は
      // NSMenuItem.isEnabledが正しく反映されていれば本来クリック自体が届かないが、
      // 何らかの理由で有効化されて発火してもここで確実に空振りさせる(representedObjectが
      // 保持する構築時点のisEnabledを見るため、NSMenuItem.isEnabledの後書き換えに影響されない)。
      guard let box = sender.representedObject as? ContextMenuActionBox, box.isEnabled else {
        return
      }
      box.action()
    }

    /// ドラッグアウト: 行のURLをNSPasteboardWritingとして提供する(現行.draggable(item.url)相当)。
    /// ドラッグ開始行が既存の複数選択に含まれる場合、AppKitは選択中の各行についてこのメソッドを
    /// 呼び出し自動的にまとめてドラッグする(行ごとの個別実装は不要)。
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int)
      -> NSPasteboardWriting?
    {
      // ドラッグ開始時にホバープレビューが出しっぱなしにならないようにする。
      cancelHoverPreview()
      guard parent.supportsDragging, row >= 0, row < items.count else { return nil }
      return items[row].item.url as NSURL
    }

    /// ドロップイン: フォルダ行では標準の行上ハイライトを表示し、そのフォルダ内を転送先に
    /// する。ファイル行・余白は従来どおり現在フォルダへのペイン背景ドロップとして扱う。
    func tableView(
      _ tableView: NSTableView,
      validateDrop info: NSDraggingInfo,
      proposedRow row: Int,
      proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
      guard canAcceptDrop(from: info.draggingPasteboard) else { return [] }
      if dropFolder(at: row) != nil {
        tableView.setDropRow(row, dropOperation: .on)
      } else {
        tableView.setDropRow(-1, dropOperation: .on)
      }
      // 実際の移動/コピーは既存のワークスペース判定(Optionコピー強制を含む)へ委譲する。
      return .generic
    }

    func tableView(
      _ tableView: NSTableView,
      acceptDrop info: NSDraggingInfo,
      row: Int,
      dropOperation: NSTableView.DropOperation
    ) -> Bool {
      return acceptDrop(from: info.draggingPasteboard, into: dropFolder(at: row))
    }

    /// validateDrop/acceptDropの実処理。NSDraggingInfoはAppKitがドラッグセッション中にのみ
    /// 生成する読み取り専用プロトコルでテストから直接構築できないため、NSPasteboard単体を
    /// 受け取る形に分離しテストから直接呼べるようにする
    /// (buildContextMenu(_:forRow:tableView:)と同じ「AppKit内部プロパティを引数化する」パターン)。
    func canAcceptDrop(from pasteboard: NSPasteboard) -> Bool {
      pasteboard.canReadObject(
        forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    func dropFolder(at row: Int) -> FileItem? {
      guard row >= 0, row < items.count else { return nil }
      let item = items[row].item
      return item.isDirectory ? item : nil
    }

    func acceptDrop(from pasteboard: NSPasteboard, into folder: FileItem? = nil) -> Bool {
      guard
        let urls = pasteboard.readObjects(
          forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
        !urls.isEmpty
      else {
        return false
      }
      if let folder {
        return parent.onDropURLsIntoFolder(urls, folder)
      }
      return parent.onDropURLs(urls)
    }
  }
}
