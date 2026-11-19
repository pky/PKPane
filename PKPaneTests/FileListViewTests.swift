import AppKit
import SwiftUI
import Testing

@testable import PKPane

@MainActor
struct FileListViewTests {
  @Test("クラウドの新しい状態はリストとカラムの名前セルに同じ意味で表示する")
  func showsObservedCloudIndicatorsInListAndColumns() throws {
    for mode in [FileBrowserViewMode.list, .column] {
      for status in [CloudDownloadStatus.downloading, .failed, .unknown] {
        let item = FileItem(url: URL(filePath: "/tmp/cloud-fixture.txt"), isDirectory: false)
        var options = FileBrowserDisplayOptions()
        options.viewMode = mode
        let view = FileListView(
          items: treeRows([item]), selectedItemURLs: .constant([]), displayOptions: options,
          gitStatuses: nil, cloudDownloadStatuses: [item.url: status],
          nameCell: { item in Text(item.name) },
          contextMenu: { _ in EmptyView() }, open: { _ in })
        let coordinator = view.makeCoordinator()
        coordinator.items = treeRows([item])
        let table = NSTableView()
        coordinator.rebuildColumns(displayOptions: options, tableView: table)
        let column = try #require(table.tableColumns.first { $0.identifier.rawValue == "name" })
        let cell = try #require(
          coordinator.tableView(table, viewFor: column, row: 0) as? NSTableCellView)
        let stack = try #require(cell.subviews.compactMap { $0 as? NSStackView }.first)
        #expect(
          stack.arrangedSubviews.first?.accessibilityIdentifier() == status.indicatorIdentifier)
        #expect(stack.accessibilityLabel() == status.indicatorLabel)
        #expect((stack.arrangedSubviews.first as? NSImageView)?.toolTip == status.helpText)
        // アイコン表示も同じ共通ラベル関数を使用する。
        #expect(
          FileItemIndicatorAccessibility.label(cloudStatus: status, gitStatus: nil, tags: [])
            == status.indicatorLabel)
      }
    }
  }

  @Test("横優勢で始まったジェスチャは終了まで外側へ転送する")
  func horizontalGestureStaysForwardedThroughEndedPhase() {
    var state = ColumnScrollGestureRouting.State.idle

    let began = routeColumnScroll(
      phase: .began, deltaX: 12, deltaY: 3, state: state)
    state = began.nextState
    let changed = routeColumnScroll(
      phase: .changed, deltaX: 1, deltaY: 20, state: state)
    state = changed.nextState
    let ended = routeColumnScroll(
      phase: .ended, deltaX: 0, deltaY: 0, state: state)

    #expect(began.destination == .forward)
    #expect(changed.destination == .forward)
    #expect(ended.destination == .forward)
    #expect(ended.nextState == .forward)
  }

  @Test("縦優勢で始まったジェスチャは終了まで内側で処理する")
  func verticalGestureStaysLocalThroughEndedPhase() {
    var state = ColumnScrollGestureRouting.State.idle

    let began = routeColumnScroll(
      phase: .began, deltaX: 2, deltaY: 10, state: state)
    state = began.nextState
    let changed = routeColumnScroll(
      phase: .changed, deltaX: 30, deltaY: 1, state: state)
    state = changed.nextState
    let ended = routeColumnScroll(
      phase: .ended, deltaX: 0, deltaY: 0, state: state)

    #expect(began.destination == .local)
    #expect(changed.destination == .local)
    #expect(ended.destination == .local)
    #expect(ended.nextState == .local)
  }

  @Test("モメンタム終了まで直前の配送先を保持してから状態をリセットする")
  func momentumKeepsGestureDestinationUntilItEnds() {
    var state = routeColumnScroll(
      phase: .began, deltaX: 10, deltaY: 1, state: .idle
    ).nextState
    state = routeColumnScroll(phase: .ended, state: state).nextState

    let began = routeColumnScroll(momentumPhase: .began, state: state)
    state = began.nextState
    let changed = routeColumnScroll(momentumPhase: .changed, state: state)
    state = changed.nextState
    let ended = routeColumnScroll(momentumPhase: .ended, state: state)

    #expect(began.destination == .forward)
    #expect(changed.destination == .forward)
    #expect(ended.destination == .forward)
    #expect(ended.nextState == .idle)
  }

  @Test("状態リセット後の新しいジェスチャは方向を改めて判定する")
  func newGestureReevaluatesDirectionAfterMomentumReset() {
    let resetState = routeColumnScroll(
      momentumPhase: .ended, state: .forward
    ).nextState
    let nextGesture = routeColumnScroll(
      phase: .began, deltaX: 1, deltaY: 8, state: resetState)

    #expect(resetState == .idle)
    #expect(nextGesture.destination == .local)
    #expect(nextGesture.nextState == .local)
  }

  @Test("フェーズなしイベントは保持状態に関係なく1件ごとに方向を判定する")
  func phaseLessEventsRouteIndependently() {
    let horizontal = routeColumnScroll(deltaX: -8, deltaY: 2, state: .local)
    let vertical = routeColumnScroll(deltaX: 1, deltaY: -5, state: .forward)
    let tied = routeColumnScroll(deltaX: 4, deltaY: -4, state: .forward)

    #expect(horizontal.destination == .forward)
    #expect(horizontal.nextState == .local)
    #expect(vertical.destination == .local)
    #expect(vertical.nextState == .forward)
    #expect(tied.destination == .local)
    #expect(tied.nextState == .forward)
  }

  @Test("mayBeginは内側へ素通しして保持状態を変えない")
  func mayBeginPassesThroughWithoutChangingState() {
    let decision = routeColumnScroll(
      phase: .mayBegin, deltaX: 20, deltaY: 1, state: .forward)

    #expect(decision.destination == .local)
    #expect(decision.nextState == .forward)
  }

  @Test("外側スクロールは現在のチェーン、weakキャッシュ、superの順で解決する")
  func outerScrollDestinationUsesChainBeforeCacheAndSuper() {
    #expect(
      ColumnScrollOuterDestinationResolver.source(
        chainAvailable: true, cachedAvailable: true) == .chain)
    #expect(
      ColumnScrollOuterDestinationResolver.source(
        chainAvailable: false, cachedAvailable: true) == .cached)
    #expect(
      ColumnScrollOuterDestinationResolver.source(
        chainAvailable: false, cachedAvailable: false) == .none)
  }

  @Test("ゼロデルタ開始後は最初の横優勢デルタで外側への転送を確定する")
  func zeroDeltaBeganDefersUntilHorizontalChangedPhase() {
    let began = routeColumnScroll(phase: .began, state: .idle)
    let horizontal = routeColumnScroll(
      phase: .changed, deltaX: 9, deltaY: 2, state: began.nextState)
    let verticalAfterResolution = routeColumnScroll(
      phase: .changed, deltaX: 1, deltaY: 20, state: horizontal.nextState)

    #expect(began.destination == .local)
    #expect(began.nextState == .pending)
    #expect(horizontal.destination == .forward)
    #expect(horizontal.nextState == .forward)
    #expect(verticalAfterResolution.destination == .forward)
    #expect(verticalAfterResolution.nextState == .forward)
  }

  @Test("ゼロデルタ開始後は最初の縦優勢デルタで内側処理を確定する")
  func zeroDeltaBeganDefersUntilVerticalChangedPhase() {
    let began = routeColumnScroll(phase: .began, state: .idle)
    let vertical = routeColumnScroll(
      phase: .changed, deltaX: 2, deltaY: 9, state: began.nextState)

    #expect(began.nextState == .pending)
    #expect(vertical.destination == .local)
    #expect(vertical.nextState == .local)
  }

  @Test("通常フェーズが未確定ならモメンタムの横優勢デルタで転送を確定する")
  func pendingGestureResolvesFromHorizontalMomentum() {
    let began = routeColumnScroll(phase: .began, state: .idle)
    let ended = routeColumnScroll(phase: .ended, state: began.nextState)
    let momentum = routeColumnScroll(
      momentumPhase: .began, deltaX: 8, deltaY: 1, state: ended.nextState)

    #expect(ended.destination == .local)
    #expect(ended.nextState == .pending)
    #expect(momentum.destination == .forward)
    #expect(momentum.nextState == .forward)
  }

  @Test("未確定中のゼロデルタは内側へ渡して方向判定を保留する")
  func zeroDeltaChangedPhaseKeepsPendingState() {
    let began = routeColumnScroll(phase: .began, state: .idle)
    let changed = routeColumnScroll(phase: .changed, state: began.nextState)

    #expect(changed.destination == .local)
    #expect(changed.nextState == .pending)
  }

  @Test("未保持のカラムへ届いたモメンタムはイベントの方向から配送先を復元する")
  func idleStateRoutesMomentumFromCurrentEventDirection() {
    let horizontal = routeColumnScroll(
      momentumPhase: .changed, deltaX: 3, deltaY: 1, state: .idle)
    let vertical = routeColumnScroll(
      momentumPhase: .changed, deltaX: 1, deltaY: 3, state: .idle)

    #expect(horizontal.destination == .forward)
    #expect(horizontal.nextState == .forward)
    #expect(vertical.destination == .local)
    #expect(vertical.nextState == .local)
  }

  @Test("初動の縦優勢ノイズがあっても累積で横優勢なら外側へ転送する")
  func accumulatedDirectionOverridesInitialVerticalNoise() {
    let began = routeColumnScroll(
      phase: .began, deltaX: 1, deltaY: 2, state: .idle)
    let changed = routeColumnScroll(
      phase: .changed, deltaX: 4, deltaY: 1, state: began.nextState)

    #expect(began.destination == .local)
    #expect(changed.destination == .forward)
    #expect(changed.nextState == .forward)
  }

  @Test("累積デルタが閾値未満の間は内側処理のまま方向判定を保留する")
  func accumulatedDeltaBelowThresholdKeepsPendingState() {
    let began = routeColumnScroll(
      phase: .began, deltaX: 1, deltaY: 1, state: .idle)
    let changed = routeColumnScroll(
      phase: .changed, deltaX: 0.5, deltaY: 1, state: began.nextState)

    #expect(began.destination == .local)
    #expect(changed.destination == .local)
    #expect(changed.nextState.isPending)
    #expect(
      routeColumnScroll(
        phase: .changed, deltaX: 3, deltaY: 0, state: changed.nextState
      ).destination == .forward)
  }

  @Test("新しいbeganは以前の未確定累積を破棄して方向判定を開始する")
  func beganResetsPendingAccumulation() {
    let previous = routeColumnScroll(
      phase: .began, deltaX: 3, deltaY: 0, state: .idle)
    let restarted = routeColumnScroll(
      phase: .began, deltaX: 0, deltaY: 3, state: previous.nextState)
    let resolved = routeColumnScroll(
      phase: .changed, deltaX: 2, deltaY: 1, state: restarted.nextState)

    #expect(previous.destination == .local)
    #expect(restarted.destination == .local)
    #expect(resolved.destination == .local)
    #expect(resolved.nextState == .local)
  }

  @Test("通常フェーズ終了後もモメンタムデルタを累積して方向を確定する")
  func momentumCompletesPendingAccumulationAfterGestureEnded() {
    let began = routeColumnScroll(
      phase: .began, deltaX: 2, deltaY: 1, state: .idle)
    let changed = routeColumnScroll(
      phase: .changed, deltaX: 1, deltaY: 1, state: began.nextState)
    let ended = routeColumnScroll(phase: .ended, state: changed.nextState)
    let momentum = routeColumnScroll(
      momentumPhase: .began, deltaX: 2, deltaY: 1, state: ended.nextState)

    #expect(ended.destination == .local)
    #expect(momentum.destination == .forward)
    #expect(momentum.nextState == .forward)
  }

  @Test("beganは主配送先に関係なくbookendとして両送りする")
  func beganIsDeliveredAsBookend() {
    let pending = routeColumnScroll(phase: .began, state: .idle)
    let forward = routeColumnScroll(
      phase: .began, deltaX: 8, deltaY: 1, state: .idle)

    #expect(pending.destination == .local)
    #expect(pending.sendsBookend)
    #expect(forward.destination == .forward)
    #expect(forward.sendsBookend)
  }

  @Test("endedとcancelledは主配送先に関係なくbookendとして両送りする")
  func endedAndCancelledAreDeliveredAsBookends() {
    let ended = routeColumnScroll(phase: .ended, state: .forward)
    let cancelled = routeColumnScroll(phase: .cancelled, state: .local)

    #expect(ended.destination == .forward)
    #expect(ended.nextState == .forward)
    #expect(ended.sendsBookend)
    #expect(cancelled.destination == .local)
    #expect(cancelled.nextState == .idle)
    #expect(cancelled.sendsBookend)
  }

  @Test("別インスタンス相当のchangedでも共有状態から外側転送を継続する")
  func sharedRoutingStateContinuesAcrossScrollViewInstances() {
    ColumnScrollGestureRouting.resetSharedState()
    defer { ColumnScrollGestureRouting.resetSharedState() }

    let beganOnFirstInstance = ColumnScrollGestureRouting.routeShared(
      phase: .began,
      momentumPhase: .none,
      deltaX: 8,
      deltaY: 1)
    let changedWithIsolatedState = routeColumnScroll(
      phase: .changed, deltaX: 1, deltaY: 8, state: .idle)
    let changedOnSecondInstance = ColumnScrollGestureRouting.routeShared(
      phase: .changed,
      momentumPhase: .none,
      deltaX: 1,
      deltaY: 8)

    #expect(beganOnFirstInstance.destination == .forward)
    #expect(changedWithIsolatedState.destination == .local)
    #expect(changedOnSecondInstance.destination == .forward)
    #expect(changedOnSecondInstance.nextState == .forward)
  }

  @Test("縦ジェスチャはbookend以外を外側へ転送しない")
  func verticalGestureOnlyForwardsBookends() {
    ColumnScrollGestureRouting.resetSharedState()
    defer { ColumnScrollGestureRouting.resetSharedState() }

    let began = ColumnScrollGestureRouting.routeShared(
      phase: .began,
      momentumPhase: .none,
      deltaX: 1,
      deltaY: 8)
    let changed = ColumnScrollGestureRouting.routeShared(
      phase: .changed,
      momentumPhase: .none,
      deltaX: 20,
      deltaY: 1)
    let ended = ColumnScrollGestureRouting.routeShared(
      phase: .ended,
      momentumPhase: .none,
      deltaX: 0,
      deltaY: 0)
    let momentum = ColumnScrollGestureRouting.routeShared(
      phase: .none,
      momentumPhase: .changed,
      deltaX: 20,
      deltaY: 1)

    #expect(began.destination == .local)
    #expect(began.sendsBookend)
    #expect(changed.destination == .local)
    #expect(!changed.sendsBookend)
    #expect(ended.destination == .local)
    #expect(ended.sendsBookend)
    #expect(momentum.destination == .local)
    #expect(!momentum.sendsBookend)
  }

  @Test("別の列ヘッダを選ぶと列ごとの既定方向でソートする")
  func selectingDifferentColumnUsesItsDefaultDirection() {
    let state = FileListSortState(order: .name, ascending: true)

    #expect(
      state.applying(requestedOrder: .kind) == FileListSortState(order: .kind, ascending: true))
    #expect(
      state.applying(requestedOrder: .size) == FileListSortState(order: .size, ascending: false))
    #expect(
      state.applying(requestedOrder: .modifiedAt)
        == FileListSortState(order: .modifiedAt, ascending: false))
  }

  @Test("同じ列ヘッダを再クリックすると昇降を反転する")
  func selectingSameColumnTogglesDirection() {
    let descendingSize = FileListSortState(order: .size, ascending: false)

    #expect(
      descendingSize.applying(requestedOrder: .size)
        == FileListSortState(order: .size, ascending: true))
  }

  @Test("列挙されたFileItemを行数とセルの表示値へ変換する")
  func mapsRowsAndColumnValues() throws {
    let firstItem = FileItem(
      url: URL(filePath: "/tmp/report.txt"), isDirectory: false, size: 10,
      modifiedAt: Date(timeIntervalSince1970: 0))
    let secondItem = FileItem(
      url: URL(filePath: "/tmp/folder", directoryHint: .isDirectory), isDirectory: true)
    let items = [firstItem, secondItem]

    let coordinator = makeCoordinator(items: items, selection: .constant([]))
    let tableView = NSTableView()
    coordinator.rebuildColumns(
      displayOptions: FileBrowserDisplayOptions(
        showsKindColumn: true, showsSizeColumn: true, showsModifiedAtColumn: true,
        showsLocationColumn: true),
      tableView: tableView)

    #expect(coordinator.numberOfRows(in: tableView) == 2)

    let sizeColumn = try #require(
      tableView.tableColumns.first { $0.identifier.rawValue == "size" })
    let sizeView = try #require(
      coordinator.tableView(tableView, viewFor: sizeColumn, row: 0) as? NSTextField)
    #expect(sizeView.stringValue == firstItem.displaySize)

    let kindColumn = try #require(
      tableView.tableColumns.first { $0.identifier.rawValue == "kind" })
    let kindView = try #require(
      coordinator.tableView(tableView, viewFor: kindColumn, row: 1) as? NSTextField)
    #expect(kindView.stringValue == secondItem.kindDisplayName)

    let nameColumn = try #require(
      tableView.tableColumns.first { $0.identifier.rawValue == "name" })
    let nameView = try #require(
      coordinator.tableView(tableView, viewFor: nameColumn, row: 0) as? NSTableCellView)
    #expect(nameView.textField?.stringValue == firstItem.name)
    #expect(nameView.imageView?.image != nil)
  }

  @Test("可視セルの未補完項目は複数列から1バッチへ統合して通知する")
  func coalescesVisibleItemsAcrossColumns() async throws {
    let unknownItem = FileItem(
      url: URL(filePath: "/tmp/unknown.txt"), isDirectory: false, tags: nil)
    let knownItem = FileItem(
      url: URL(filePath: "/tmp/known.txt"), isDirectory: false, tags: ["既存"])
    var notifiedBatches = [[FileItem]]()
    let view = FileListView(
      items: treeRows([unknownItem, knownItem]),
      selectedItemURLs: .constant([]),
      displayOptions: FileBrowserDisplayOptions(),
      gitStatuses: nil,
      nameCell: { item in Text(item.name) },
      contextMenu: { _ in EmptyView() },
      open: { _ in },
      onVisibleItemsChange: { notifiedBatches.append($0) })
    let coordinator = view.makeCoordinator()
    coordinator.items = treeRows([unknownItem, knownItem])
    let tableView = NSTableView()
    coordinator.rebuildColumns(
      displayOptions: FileBrowserDisplayOptions(), tableView: tableView)

    for column in tableView.tableColumns {
      _ = coordinator.tableView(tableView, viewFor: column, row: 0)
      _ = coordinator.tableView(tableView, viewFor: column, row: 1)
    }
    await PKPaneTests.waitUntil(
      "可視セル通知が期限内に発行されなかった"
    ) {
      notifiedBatches.count == 1
    }

    #expect(notifiedBatches.count == 1)
    #expect(notifiedBatches.first?.map(\.url) == [unknownItem.url])
  }

  @Test("Git状態ドットは名前セルでタグドットの左隣に表示する")
  func nameCellShowsGitStatusBeforeFinderTags() throws {
    let item = FileItem(
      url: URL(filePath: "/tmp/changed.swift"),
      isDirectory: false,
      tags: ["重要\n6"])
    let view = FileListView(
      items: treeRows([item]),
      selectedItemURLs: .constant([]),
      displayOptions: FileBrowserDisplayOptions(),
      gitStatuses: [item.url: .modified],
      nameCell: { item in Text(item.name) },
      contextMenu: { _ in EmptyView() },
      open: { _ in })
    let coordinator = view.makeCoordinator()
    coordinator.items = treeRows([item])
    let tableView = NSTableView()
    coordinator.rebuildColumns(displayOptions: FileBrowserDisplayOptions(), tableView: tableView)
    let nameColumn = try #require(
      tableView.tableColumns.first { $0.identifier.rawValue == "name" })

    let cell = try #require(
      coordinator.tableView(tableView, viewFor: nameColumn, row: 0) as? NSTableCellView)
    let indicatorStack = try #require(cell.subviews.compactMap { $0 as? NSStackView }.first)

    #expect(indicatorStack.arrangedSubviews.count == 2)
    #expect(
      indicatorStack.arrangedSubviews.first?.accessibilityIdentifier()
        == "git-status-modified")
    #expect(indicatorStack.accessibilityLabel() == "Git変更あり、重要")
  }

  @Test("クラウド未ダウンロードマークはGit状態とタグの左隣に表示する")
  func nameCellShowsCloudStatusBeforeGitStatusAndFinderTags() throws {
    let item = FileItem(
      url: URL(filePath: "/tmp/cloud.swift"),
      isDirectory: false,
      tags: ["重要\n6"])
    let view = FileListView(
      items: treeRows([item]),
      selectedItemURLs: .constant([]),
      displayOptions: FileBrowserDisplayOptions(),
      gitStatuses: [item.url: .modified],
      cloudDownloadStatuses: [item.url: .notDownloaded],
      nameCell: { item in Text(item.name) },
      contextMenu: { _ in EmptyView() },
      open: { _ in })
    let coordinator = view.makeCoordinator()
    coordinator.items = treeRows([item])
    let tableView = NSTableView()
    coordinator.rebuildColumns(displayOptions: FileBrowserDisplayOptions(), tableView: tableView)
    let nameColumn = try #require(
      tableView.tableColumns.first { $0.identifier.rawValue == "name" })

    let cell = try #require(
      coordinator.tableView(tableView, viewFor: nameColumn, row: 0) as? NSTableCellView)
    let indicatorStack = try #require(cell.subviews.compactMap { $0 as? NSStackView }.first)

    #expect(indicatorStack.arrangedSubviews.count == 3)
    #expect(
      indicatorStack.arrangedSubviews.first?.accessibilityIdentifier()
        == "cloud-status-notDownloaded")
    #expect(indicatorStack.accessibilityLabel() == "未ダウンロード、Git変更あり、重要")
  }

  @Test("Git状態差分は項目配列を再投影せず名前列の該当行だけを更新対象にする")
  func gitStatusChangeKeepsItemProjectionStable() {
    let first = FileItem(url: URL(filePath: "/tmp/first.swift"), isDirectory: false)
    let second = FileItem(url: URL(filePath: "/tmp/second.swift"), isDirectory: false)
    let coordinator = makeCoordinator(items: [first, second], selection: .constant([]))
    let rows = coordinator.changedGitStatusRows(from: nil, to: [second.url: .added])

    #expect(rows == IndexSet(integer: 1))
  }

  @Test("クラウド状態差分は名前列の該当行だけを更新対象にする")
  func cloudStatusChangeReloadsOnlyChangedRows() {
    let first = FileItem(url: URL(filePath: "/tmp/first.swift"), isDirectory: false)
    let second = FileItem(url: URL(filePath: "/tmp/second.swift"), isDirectory: false)
    let coordinator = makeCoordinator(items: [first, second], selection: .constant([]))
    let rows = coordinator.changedCloudStatusRows(from: nil, to: [second.url: .notDownloaded])

    #expect(rows == IndexSet(integer: 1))
  }

  @Test("1万行中1件の状態差分は変更URLだけを行番号索引へ照合する")
  func statusChangeUsesRowIndex() {
    let items = (0..<10_000).map { index in
      FileItem(url: URL(filePath: "/tmp/status-\(index).txt"), isDirectory: false)
    }
    let coordinator = makeCoordinator(items: items, selection: .constant([]))
    let changedURL = items[9_999].url

    var gitRows = IndexSet()
    let duration = ContinuousClock().measure {
      gitRows = coordinator.changedGitStatusRows(from: [:], to: [changedURL: .modified])
    }
    print(
      "PKPane性能計測: 1万行中1件の状態差分 \(Self.milliseconds(duration))ms、行照合\(coordinator.lastStatusRowCandidateScanCount)件"
    )
    #expect(gitRows == IndexSet(integer: 9_999))
    #expect(coordinator.lastStatusRowCandidateScanCount == 1)

    let cloudRows = coordinator.changedCloudStatusRows(
      from: [:], to: [changedURL: .notDownloaded])
    #expect(cloudRows == IndexSet(integer: 9_999))
    #expect(coordinator.lastStatusRowCandidateScanCount == 1)
  }

  @Test("1万行末尾のURLから項目を1件の索引照合で取得する")
  func itemLookupUsesRowIndex() {
    let items = (0..<10_000).map { index in
      FileItem(url: URL(filePath: "/tmp/lookup-\(index).txt"), isDirectory: false)
    }
    let coordinator = makeCoordinator(items: items, selection: .constant([]))

    let found = coordinator.item(for: items[9_999].url)

    #expect(found == items[9_999])
    #expect(coordinator.lastItemLookupCandidateScanCount == 1)
  }

  @Test("showsXColumnがfalseの列は生成しない")
  func omitsDisabledColumns() {
    let coordinator = makeCoordinator(items: [], selection: .constant([]))
    let tableView = NSTableView()

    coordinator.rebuildColumns(displayOptions: FileBrowserDisplayOptions(), tableView: tableView)

    let identifiers = Set(tableView.tableColumns.map(\.identifier.rawValue))
    #expect(identifiers == ["name", "size", "modifiedAt"])
  }

  @Test("リスト/カラムの行高はアイコンサイズに追従する")
  func listRowHeightFollowsIconSize() {
    let tableView = NSTableView()

    FileListRowLayout.apply(.small, to: tableView)
    #expect(tableView.rowHeight == 20)

    FileListRowLayout.apply(.extraLarge, to: tableView)
    #expect(tableView.rowHeight == 40)
  }

  @Test("古い解像度で完了した非同期アイコンは現在のサイズと不一致なら破棄する")
  func iconResolutionResultAppliesOnlyWhenSizesMatch() {
    let previousSize = NSSize(width: 32, height: 32)
    let currentSize = NSSize(width: 64, height: 64)

    #expect(FileListIconResolution.shouldApply(previousSize, currentSize: previousSize))
    #expect(!FileListIconResolution.shouldApply(previousSize, currentSize: currentSize))
  }

  @Test("旧アイコン要求の完了は同じURLの新要求を実行中のまま保つ")
  func staleIconResolutionDoesNotFinishCurrentRequest() {
    let url = URL(filePath: "/tmp/preview.png")
    var requests = FileListIconResolutionRequests()

    let oldRequestID = requests.begin(for: url)
    #expect(oldRequestID != nil)
    requests.cancelAll()
    let currentRequestID = requests.begin(for: url)
    #expect(currentRequestID != nil)

    // サイズ変更前の旧要求が、新要求より後に完了する競合を再現する。
    if let oldRequestID {
      let finishedCurrentRequest = requests.finish(for: url, id: oldRequestID)
      #expect(!finishedCurrentRequest)
    }

    let duplicateRequestID = requests.begin(for: url)
    #expect(duplicateRequestID == nil)
  }

  @Test("アイコン要求は無効化と一覧退場時にTaskを取り消す")
  func iconResolutionCancellationFollowsVisibleItems() throws {
    let keptURL = URL(filePath: "/tmp/kept.png")
    let removedURL = URL(filePath: "/tmp/removed.png")
    var requests = FileListIconResolutionRequests()
    let reservedKeptID = requests.begin(for: keptURL)
    let reservedRemovedID = requests.begin(for: removedURL)
    let keptID = try #require(reservedKeptID)
    let removedID = try #require(reservedRemovedID)
    let keptTask = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
    let removedTask = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
    requests.attach(keptTask, for: keptURL, id: keptID)
    requests.attach(removedTask, for: removedURL, id: removedID)

    requests.cancelRequestsMissing(from: [keptURL: 0])

    #expect(!keptTask.isCancelled)
    #expect(removedTask.isCancelled)
    let duplicateKeptID = requests.begin(for: keptURL)
    let restartedRemovedID = requests.begin(for: removedURL)
    #expect(duplicateKeptID == nil)
    #expect(restartedRemovedID != nil)

    requests.cancelAll()
    #expect(keptTask.isCancelled)
  }

  @Test("カラム用ミニリストは名前列だけをヘッダなしのコンパクト表示にする")
  func columnMiniListUsesSingleCompactNameColumn() {
    let coordinator = makeCoordinator(items: [], selection: .constant([]))
    let tableView = ActivatingTableView()
    let initialRowHeight = tableView.rowHeight

    FileListPresentation.column.configure(tableView)
    coordinator.rebuildColumns(
      displayOptions: FileBrowserDisplayOptions(),
      presentation: .column,
      tableView: tableView)

    #expect(tableView.tableColumns.map(\.identifier.rawValue) == ["name"])
    #expect(tableView.headerView == nil)
    #expect(tableView.rowHeight == initialRowHeight)
    #expect(tableView.usesAlternatingRowBackgroundColors)
    #expect(tableView.allowsMultipleSelection)
  }

  @Test("カラム用ミニリストも複数選択同期と右クリックメニュー経路を使う")
  func columnMiniListReusesMultipleSelectionAndContextMenuBehavior() throws {
    let firstItem = FileItem(url: URL(filePath: "/tmp/a.txt"), isDirectory: false)
    let secondItem = FileItem(url: URL(filePath: "/tmp/b.txt"), isDirectory: false)
    var selection = Set<URL>()
    let view = FileListView(
      items: treeRows([firstItem, secondItem]),
      selectedItemURLs: Binding(get: { selection }, set: { selection = $0 }),
      displayOptions: FileBrowserDisplayOptions(),
      gitStatuses: nil,
      nameCell: { item in Text(item.name) },
      contextMenu: { _ in EmptyView() },
      open: { _ in },
      presentation: .column,
      contextMenuItems: { item in
        [FileContextMenuItem(title: "選択\(selection.count)件(\(item.name))") {}]
      })
    let coordinator = view.makeCoordinator()
    coordinator.items = treeRows([firstItem, secondItem])
    let tableView = ActivatingTableView()
    FileListPresentation.column.configure(tableView)
    coordinator.rebuildColumns(
      displayOptions: FileBrowserDisplayOptions(),
      presentation: .column,
      tableView: tableView)
    tableView.dataSource = coordinator
    tableView.delegate = coordinator
    tableView.reloadData()

    tableView.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
    coordinator.tableViewSelectionDidChange(
      Notification(name: NSTableView.selectionDidChangeNotification, object: tableView))
    let menu = NSMenu()
    coordinator.buildContextMenu(menu, forRow: 1, tableView: tableView)

    #expect(selection == [firstItem.url, secondItem.url])
    #expect(tableView.selectedRowIndexes == IndexSet([0, 1]))
    #expect(menu.items.map(\.title) == ["選択2件(b.txt)"])
  }

  @Test("列は常にdefaultWidth/minWidthで構築される(保存幅の概念なし)")
  func rebuildColumnsUsesDefaultWidths() throws {
    let displayOptions = FileBrowserDisplayOptions(
      showsKindColumn: true, showsSizeColumn: true, showsModifiedAtColumn: true,
      showsLocationColumn: true, showsTagsColumn: true)
    let coordinator = makeCoordinator(
      items: [], selection: .constant([]), displayOptions: displayOptions)
    let tableView = NSTableView()

    coordinator.rebuildColumns(displayOptions: displayOptions, tableView: tableView)

    let nameColumn = try #require(
      tableView.tableColumns.first { $0.identifier.rawValue == "name" })
    #expect(nameColumn.width == FileListColumn.name.defaultWidth)
    let sizeColumn = try #require(
      tableView.tableColumns.first { $0.identifier.rawValue == "size" })
    #expect(sizeColumn.width == FileListColumn.size.defaultWidth)
    let modifiedAtColumn = try #require(
      tableView.tableColumns.first { $0.identifier.rawValue == "modifiedAt" })
    #expect(modifiedAtColumn.width == FileListColumn.modifiedAt.defaultWidth)
    let tagsColumn = try #require(
      tableView.tableColumns.first { $0.identifier.rawValue == "tags" })
    #expect(tagsColumn.width == FileListColumn.tags.defaultWidth)
  }

  @Test("通常リストは列の自動リサイズを無効にし全列の手動リサイズを維持する")
  func standardListUsesManualColumnWidthDistribution() {
    let displayOptions = FileBrowserDisplayOptions(
      showsKindColumn: true, showsSizeColumn: true, showsModifiedAtColumn: true,
      showsLocationColumn: true)
    let coordinator = makeCoordinator(
      items: [], selection: .constant([]), displayOptions: displayOptions)
    let tableView = NSTableView()
    tableView.columnAutoresizingStyle = .noColumnAutoresizing

    coordinator.rebuildColumns(displayOptions: displayOptions, tableView: tableView)

    #expect(tableView.columnAutoresizingStyle == .noColumnAutoresizing)
    for tableColumn in tableView.tableColumns {
      #expect(!tableColumn.resizingMask.contains(.autoresizingMask))
      #expect(tableColumn.resizingMask.contains(.userResizingMask))
    }
  }

  @Test("縮小時は更新日時、サイズ、名前の順で最小幅まで圧縮する")
  func columnWidthsShrinkInPriorityOrder() {
    let first = FileListColumnWidthPolicy.applying(
      availableWidthChangeFrom: 560,
      to: 490,
      state: widthState(name: 300, size: 100, modifiedAt: 160))
    let second = FileListColumnWidthPolicy.applying(
      availableWidthChangeFrom: 490,
      to: 450,
      state: first)

    #expect(first.currentWidths[.modifiedAt] == 100)
    #expect(first.currentWidths[.size] == 90)
    #expect(first.currentWidths[.name] == 300)
    #expect(second.currentWidths[.modifiedAt] == 100)
    #expect(second.currentWidths[.size] == 60)
    #expect(second.currentWidths[.name] == 290)
  }

  @Test("タグ補助列は既存の列幅圧縮順に混ざらない")
  func tagsColumnDoesNotChangeWidthDistributionPriority() {
    let state = FileListColumnWidthState(
      currentWidths: [.name: 300, .size: 100, .modifiedAt: 160, .tags: 120],
      preferredWidths: [.size: 100, .modifiedAt: 160],
      minimumWidths: [.name: 160, .size: 60, .modifiedAt: 100, .tags: 80])

    let result = FileListColumnWidthPolicy.applying(
      availableWidthChangeFrom: 680,
      to: 610,
      state: state)

    #expect(result.currentWidths[.modifiedAt] == 100)
    #expect(result.currentWidths[.size] == 90)
    #expect(result.currentWidths[.name] == 300)
    #expect(result.currentWidths[.tags] == 120)
  }

  @Test("初期フィットでは名前だけを縮めてサイズと更新日時を希望幅で表示する")
  func fittingColumnWidthsPreservesPreferredMetadataWidths() {
    let result = FileListColumnWidthPolicy.fitting(
      availableWidth: 500,
      state: widthState(name: 480, size: 60, modifiedAt: 100))

    #expect(result.currentWidths[.name] == 240)
    #expect(result.currentWidths[.size] == 100)
    #expect(result.currentWidths[.modifiedAt] == 160)
  }

  @Test("名前が最小幅に達した後は場所、更新日時、サイズの順でフィットする")
  func fittingColumnWidthsShrinksMetadataInPriorityOrder() {
    var initial = widthState(name: 480, size: 60, modifiedAt: 100)
    initial.currentWidths[.location] = 100
    initial.preferredWidths[.location] = 200
    let result = FileListColumnWidthPolicy.fitting(
      availableWidth: 430,
      state: initial)

    #expect(result.currentWidths[.name] == 160)
    #expect(result.currentWidths[.location] == 100)
    #expect(result.currentWidths[.modifiedAt] == 100)
    #expect(result.currentWidths[.size] == 70)
  }

  @Test("初期フィットの余剰幅はすべて名前へ配分する")
  func fittingColumnWidthsAssignsSurplusToName() {
    let result = FileListColumnWidthPolicy.fitting(
      availableWidth: 700,
      state: widthState(name: 160, size: 60, modifiedAt: 100))

    #expect(result.currentWidths[.name] == 440)
    #expect(result.currentWidths[.size] == 100)
    #expect(result.currentWidths[.modifiedAt] == 160)
  }

  @Test("初期フィットでも手動指定した希望幅を優先する")
  func fittingColumnWidthsUsesManualPreferredWidths() {
    var initial = widthState(name: 480, size: 60, modifiedAt: 100)
    initial.preferredWidths[.size] = 130
    initial.preferredWidths[.modifiedAt] = 180
    let result = FileListColumnWidthPolicy.fitting(
      availableWidth: 600,
      state: initial)

    #expect(result.currentWidths[.name] == 290)
    #expect(result.currentWidths[.size] == 130)
    #expect(result.currentWidths[.modifiedAt] == 180)
  }

  @Test("初期フィットは列間余白を含めて表示幅へ収める")
  func fittingColumnWidthsIncludesIntercellSpacing() {
    let viewportWidth: CGFloat = 500
    let columnCount = 3
    let spacingWidth: CGFloat = 3
    let availableWidth = FileListColumnWidthPolicy.effectiveAvailableWidth(
      viewportWidth: viewportWidth,
      columnCount: columnCount,
      intercellSpacingWidth: spacingWidth)
    let result = FileListColumnWidthPolicy.fitting(
      availableWidth: availableWidth,
      state: widthState(name: 480, size: 60, modifiedAt: 100))
    let tableWidth =
      result.currentWidths.values.reduce(0, +)
      + spacingWidth * CGFloat(columnCount)

    #expect(result.currentWidths[.name] == 231)
    #expect(result.currentWidths[.size] == 100)
    #expect(result.currentWidths[.modifiedAt] == 160)
    #expect(tableWidth == viewportWidth)
  }

  @Test("列再構築後も表示列数分の余白を含めてフィットする")
  func rebuiltColumnWidthsIncludeIntercellSpacing() {
    let displayOptions = FileBrowserDisplayOptions(
      showsKindColumn: true, showsSizeColumn: true, showsModifiedAtColumn: true,
      showsLocationColumn: true)
    let coordinator = makeCoordinator(
      items: [], selection: .constant([]), displayOptions: displayOptions)
    let tableView = ActivatingTableView()
    FileListPresentation.standard.configure(tableView)
    coordinator.tableView = tableView
    coordinator.rebuildColumns(displayOptions: displayOptions, tableView: tableView)

    let viewportWidth: CGFloat = 600
    coordinator.redistributeColumns(
      toAvailableWidth: viewportWidth,
      resetReferenceWidth: true)
    let tableWidth =
      tableView.tableColumns.reduce(CGFloat.zero) { $0 + $1.width }
      + tableView.intercellSpacing.width * CGFloat(tableView.numberOfColumns)
    let laidOutWidth = tableView.rect(ofColumn: tableView.numberOfColumns - 1).maxX

    #expect(tableWidth == viewportWidth)
    #expect(laidOutWidth == viewportWidth)
  }

  @Test("狭幅では名前の後に更新日時とサイズを縮め余白込みで収める")
  func narrowFittingColumnWidthsIncludeIntercellSpacing() {
    let viewportWidth: CGFloat = 349
    let columnCount = 3
    let spacingWidth: CGFloat = 3
    let availableWidth = FileListColumnWidthPolicy.effectiveAvailableWidth(
      viewportWidth: viewportWidth,
      columnCount: columnCount,
      intercellSpacingWidth: spacingWidth)
    let result = FileListColumnWidthPolicy.fitting(
      availableWidth: availableWidth,
      state: widthState(name: 480, size: 60, modifiedAt: 100))
    let tableWidth =
      result.currentWidths.values.reduce(0, +)
      + spacingWidth * CGFloat(columnCount)

    #expect(result.currentWidths[.name] == 160)
    #expect(result.currentWidths[.modifiedAt] == 100)
    #expect(result.currentWidths[.size] == 80)
    #expect(tableWidth == viewportWidth)
  }

  @Test("全列最小幅でも不足する場合だけ横スクロールを許容する")
  func fittingColumnWidthsOverflowOnlyBelowAllMinimums() {
    let viewportWidth: CGFloat = 300
    let columnCount = 3
    let spacingWidth: CGFloat = 3
    let availableWidth = FileListColumnWidthPolicy.effectiveAvailableWidth(
      viewportWidth: viewportWidth,
      columnCount: columnCount,
      intercellSpacingWidth: spacingWidth)
    let result = FileListColumnWidthPolicy.fitting(
      availableWidth: availableWidth,
      state: widthState(name: 480, size: 60, modifiedAt: 100))
    let tableWidth =
      result.currentWidths.values.reduce(0, +)
      + spacingWidth * CGFloat(columnCount)

    #expect(result.currentWidths[.name] == 160)
    #expect(result.currentWidths[.modifiedAt] == 100)
    #expect(result.currentWidths[.size] == 60)
    #expect(tableWidth > viewportWidth)
  }

  @Test("初回の未確定幅を保留し最初の有効幅でフィットする")
  func initialColumnFitWaitsForValidViewportWidth() {
    let displayOptions = FileBrowserDisplayOptions(
      showsKindColumn: true, showsSizeColumn: true, showsModifiedAtColumn: true,
      showsLocationColumn: false)
    let coordinator = makeCoordinator(
      items: [], selection: .constant([]), displayOptions: displayOptions)
    let tableView = ActivatingTableView()
    FileListPresentation.standard.configure(tableView)
    coordinator.tableView = tableView
    coordinator.rebuildColumns(displayOptions: displayOptions, tableView: tableView)
    let initialWidths = tableView.tableColumns.map(\.width)

    coordinator.redistributeColumns(toAvailableWidth: 0, resetReferenceWidth: true)
    #expect(tableView.tableColumns.map(\.width) == initialWidths)

    let viewportWidth: CGFloat = 500
    coordinator.redistributeColumns(toAvailableWidth: viewportWidth)
    let tableWidth =
      tableView.tableColumns.reduce(CGFloat.zero) { $0 + $1.width }
      + tableView.intercellSpacing.width * CGFloat(tableView.numberOfColumns)

    #expect(tableWidth == viewportWidth)
  }

  @Test("全列が最小幅に達した後は追加の縮小を行わない")
  func columnWidthsStopAtMinimums() {
    let initial = widthState(name: 160, size: 60, modifiedAt: 100)
    let result = FileListColumnWidthPolicy.applying(
      availableWidthChangeFrom: 320,
      to: 100,
      state: initial)

    #expect(result == initial)
  }

  @Test("拡大時はサイズ、更新日時を希望幅へ戻してから残りを名前へ配分する")
  func columnWidthsRestoreInPriorityOrder() {
    let result = FileListColumnWidthPolicy.applying(
      availableWidthChangeFrom: 460,
      to: 610,
      state: widthState(name: 300, size: 60, modifiedAt: 100))

    #expect(result.currentWidths[.size] == 100)
    #expect(result.currentWidths[.modifiedAt] == 160)
    #expect(result.currentWidths[.name] == 350)
  }

  @Test("手動で既定より広げた列はその希望幅まで復元する")
  func columnWidthsRestoreManualPreferredWidth() {
    var initial = widthState(name: 300, size: 60, modifiedAt: 100)
    initial.preferredWidths[.size] = 130
    let result = FileListColumnWidthPolicy.applying(
      availableWidthChangeFrom: 460,
      to: 530,
      state: initial)

    #expect(result.currentWidths[.size] == 130)
    #expect(result.currentWidths[.modifiedAt] == 100)
    #expect(result.currentWidths[.name] == 300)
  }

  @Test("同じ幅だけ縮小して拡大すると元の列幅構成へ戻る")
  func columnWidthRoundTripIsSymmetric() {
    let initial = widthState(name: 300, size: 100, modifiedAt: 160)
    let shrunk = FileListColumnWidthPolicy.applying(
      availableWidthChangeFrom: 560,
      to: 460,
      state: initial)
    let restored = FileListColumnWidthPolicy.applying(
      availableWidthChangeFrom: 460,
      to: 560,
      state: shrunk)

    #expect(restored == initial)
  }

  @Test("場所列は最初に圧縮し最後に希望幅へ復元する")
  func locationColumnShrinksFirstAndRestoresLast() {
    var initial = widthState(name: 300, size: 100, modifiedAt: 160)
    initial.currentWidths[.location] = 200
    initial.preferredWidths[.location] = 200
    let shrunk = FileListColumnWidthPolicy.applying(
      availableWidthChangeFrom: 760,
      to: 630,
      state: initial)
    let restored = FileListColumnWidthPolicy.applying(
      availableWidthChangeFrom: 630,
      to: 760,
      state: shrunk)

    #expect(shrunk.currentWidths[.location] == 100)
    #expect(shrunk.currentWidths[.modifiedAt] == 130)
    #expect(shrunk.currentWidths[.size] == 100)
    #expect(restored == initial)
  }

  @Test("名前列を手動で縮めた後も拡大の残余は現在の名前幅へ加算する")
  func manualNameWidthReceivesRemainingExpansion() {
    let result = FileListColumnWidthPolicy.applying(
      availableWidthChangeFrom: 360,
      to: 480,
      state: widthState(name: 200, size: 60, modifiedAt: 100))

    #expect(result.currentWidths[.size] == 100)
    #expect(result.currentWidths[.modifiedAt] == 160)
    #expect(result.currentWidths[.name] == 220)
  }

  @Test("NSTableViewの選択変更をselectedItemURLsへ反映する")
  func propagatesTableSelectionToBinding() throws {
    let firstItem = FileItem(url: URL(filePath: "/tmp/a.txt"), isDirectory: false)
    let secondItem = FileItem(url: URL(filePath: "/tmp/b.txt"), isDirectory: false)
    var selection = Set<URL>()
    let coordinator = makeCoordinator(
      items: [firstItem, secondItem],
      selection: Binding(get: { selection }, set: { selection = $0 }))
    let tableView = NSTableView()
    coordinator.rebuildColumns(displayOptions: FileBrowserDisplayOptions(), tableView: tableView)
    coordinator.items = treeRows([firstItem, secondItem])
    tableView.dataSource = coordinator
    tableView.reloadData()
    tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)

    coordinator.tableViewSelectionDidChange(
      Notification(name: NSTableView.selectionDidChangeNotification, object: tableView))

    #expect(selection == [secondItem.url])
  }

  @Test("selectedItemURLsの変更を実際に異なる場合だけNSTableViewの選択へ反映する")
  func syncsModelSelectionOnlyWhenDifferent() {
    let firstItem = FileItem(url: URL(filePath: "/tmp/a.txt"), isDirectory: false)
    let secondItem = FileItem(url: URL(filePath: "/tmp/b.txt"), isDirectory: false)
    let thirdItem = FileItem(url: URL(filePath: "/tmp/c.txt"), isDirectory: false)
    let selectedItemURLs: Set<URL> = [firstItem.url, thirdItem.url]
    let coordinator = makeCoordinator(
      items: [firstItem, secondItem, thirdItem], selection: .constant(selectedItemURLs))
    coordinator.items = treeRows([firstItem, secondItem, thirdItem])
    let tableView = NSTableView()
    coordinator.rebuildColumns(displayOptions: FileBrowserDisplayOptions(), tableView: tableView)
    tableView.dataSource = coordinator
    tableView.reloadData()

    coordinator.syncSelectionFromModel(selectedItemURLs, tableView: tableView)

    #expect(tableView.selectedRowIndexes == IndexSet([0, 2]))
  }

  @Test("1万件一覧の単一選択を全件走査せず行番号へ変換する")
  func syncsSingleSelectionInLargeListWithoutFullScan() {
    let items = (0..<10_000).map { index in
      FileItem(
        url: URL(filePath: "/tmp/list-selection-\(index).txt"),
        isDirectory: false)
    }
    let targetURL = items[9_999].url
    let coordinator = makeCoordinator(items: items, selection: .constant([targetURL]))
    let tableView = NSTableView()
    coordinator.rebuildColumns(displayOptions: FileBrowserDisplayOptions(), tableView: tableView)
    tableView.dataSource = coordinator
    tableView.reloadData()
    let clock = ContinuousClock()

    let duration = clock.measure {
      coordinator.syncSelectionFromModel([targetURL], tableView: tableView)
    }

    print(
      "PKPane性能計測: AppKitリスト1万件の単一選択同期 "
        + "\(Self.milliseconds(duration))ms/"
        + "\(coordinator.lastSelectionCandidateScanCount)件照合")
    #expect(tableView.selectedRowIndexes == IndexSet(integer: 9_999))
    #expect(coordinator.lastSelectionCandidateScanCount == 1)
    #expect(duration < .milliseconds(16))
  }

  // 2026-08-12 退行調査: mouseDown冒頭のonActivate()(ペイン切替等のSwiftUI状態変更)が
  // 誘発する非同期再描画がAppKitのマウス追跡完了前にupdateNSView→syncSelectionFromModelを
  // 走らせると、AppKitがCommand/Shiftクリックで確定させつつある選択(拡張後)が、まだ
  // 追いついていない古いモデル値で上書きされてしまう。ActivatingTableView.mouseDownと
  // NSTableViewの内部タイミングは単体テストから直接駆動できないため、この2テストは
  // 「AppKitが選択を拡張したがモデルへの書き戻し通知がまだ処理されていない」状態を
  // isHandlingClickSelectionで表現し、syncSelectionFromModelがその状態でAppKit側の
  // 選択を尊重する(=拡張を上書きしない)ことを検証する。
  @Test("mouseDown処理中はAppKitが確定させつつある選択拡張をモデルの古い値で上書きしない")
  func syncSelectionFromModelSkipsWhileHandlingClickSelection() {
    let itemA = FileItem(url: URL(filePath: "/tmp/a.txt"), isDirectory: false)
    let itemB = FileItem(url: URL(filePath: "/tmp/b.txt"), isDirectory: false)
    let itemC = FileItem(url: URL(filePath: "/tmp/c.txt"), isDirectory: false)
    let items = [itemA, itemB, itemC]
    let coordinator = makeCoordinator(items: items, selection: .constant([itemA.url]))
    let tableView = ActivatingTableView()
    coordinator.rebuildColumns(displayOptions: FileBrowserDisplayOptions(), tableView: tableView)
    tableView.dataSource = coordinator
    tableView.allowsMultipleSelection = true
    tableView.reloadData()
    tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

    // AppKitが内部的にCommand+クリックで選択を[0, 2]へ拡張したが、対応する
    // tableViewSelectionDidChange通知(→モデルへの書き戻し)がまだ処理されていない状態を模す。
    tableView.selectRowIndexes(IndexSet([0, 2]), byExtendingSelection: false)
    #expect(tableView.selectedRowIndexes == IndexSet([0, 2]))

    // この時点でモデル側の選択はまだ古い(aのみ)。mouseDown処理中を表すフラグを立てた状態で
    // syncSelectionFromModelが呼ばれても、AppKitが確定させつつある拡張を上書きしてはならない。
    tableView.isHandlingClickSelection = true
    coordinator.syncSelectionFromModel([itemA.url], tableView: tableView)

    #expect(tableView.selectedRowIndexes == IndexSet([0, 2]))
  }

  @Test("mouseDown処理中でなければ従来どおりモデルの選択をNSTableViewへ反映する")
  func syncSelectionFromModelAppliesWhenNotHandlingClickSelection() {
    let itemA = FileItem(url: URL(filePath: "/tmp/a.txt"), isDirectory: false)
    let itemB = FileItem(url: URL(filePath: "/tmp/b.txt"), isDirectory: false)
    let itemC = FileItem(url: URL(filePath: "/tmp/c.txt"), isDirectory: false)
    let items = [itemA, itemB, itemC]
    let coordinator = makeCoordinator(items: items, selection: .constant([itemA.url]))
    let tableView = ActivatingTableView()
    coordinator.rebuildColumns(displayOptions: FileBrowserDisplayOptions(), tableView: tableView)
    tableView.dataSource = coordinator
    tableView.allowsMultipleSelection = true
    tableView.reloadData()
    tableView.selectRowIndexes(IndexSet([0, 2]), byExtendingSelection: false)

    // mouseDown処理中でない(=キーボード操作等、通常の経路)場合は従来どおりモデルの値を
    // NSTableViewへ強制反映する(この回帰保護がなければStep3以降の選択反映が壊れる)。
    tableView.isHandlingClickSelection = false
    coordinator.syncSelectionFromModel([itemA.url], tableView: tableView)

    #expect(tableView.selectedRowIndexes == IndexSet(integer: 0))
  }

  @Test("末尾への追記のみの場合は挿入だけで済み全件reloadDataにならない")
  func streamingTailAppendProducesInsertOnlyDiff() {
    let oldItems = makeRows(names: ["a.txt", "b.txt", "c.txt"])
    let newItems = makeRows(names: ["a.txt", "b.txt", "c.txt", "d.txt", "e.txt"])

    let diff = FileListView<Text, EmptyView>.Coordinator.computeDiff(from: oldItems, to: newItems)

    #expect(diff.removed.isEmpty)
    #expect(diff.updated.isEmpty)
    #expect(diff.inserted == IndexSet([3, 4]))
    #expect(!diff.usesFullReload)
  }

  @Test("複数回のバッチpublishで毎回挿入のみが積み上がる")
  func multipleStreamingBatchesEachProduceInsertOnlyDiff() {
    let batch1 = makeRows(names: ["a.txt", "b.txt"])
    let batch2 = makeRows(names: ["a.txt", "b.txt", "c.txt", "d.txt"])
    let batch3 = makeRows(names: ["a.txt", "b.txt", "c.txt", "d.txt", "e.txt", "f.txt"])

    let diff1 = FileListView<Text, EmptyView>.Coordinator.computeDiff(from: [], to: batch1)
    let diff2 = FileListView<Text, EmptyView>.Coordinator.computeDiff(from: batch1, to: batch2)
    let diff3 = FileListView<Text, EmptyView>.Coordinator.computeDiff(from: batch2, to: batch3)

    // 空配列からの初回はreloadDataフォールバック(自然な初期表示)。
    #expect(diff1.usesFullReload)
    // 以降の追記バッチは挿入のみ。
    #expect(diff2.removed.isEmpty && diff2.updated.isEmpty && !diff2.usesFullReload)
    #expect(diff2.inserted == IndexSet([2, 3]))
    #expect(diff3.removed.isEmpty && diff3.updated.isEmpty && !diff3.usesFullReload)
    #expect(diff3.inserted == IndexSet([4, 5]))
  }

  @Test("同じ項目でも内容が変わった行はupdatedとして検出する")
  func detectsContentUpdateForSameURL() {
    let oldItems = makeRows(names: ["a.txt", "b.txt", "c.txt", "d.txt", "e.txt"])
    var newItems = oldItems
    newItems[1] = treeRow(
      FileItem(
        url: oldItems[1].item.url, isDirectory: false, size: 999,
        modifiedAt: Date(timeIntervalSince1970: 123)))

    let diff = FileListView<Text, EmptyView>.Coordinator.computeDiff(from: oldItems, to: newItems)

    #expect(diff.removed.isEmpty)
    #expect(diff.inserted.isEmpty)
    #expect(diff.updated == IndexSet(integer: 1))
    #expect(!diff.usesFullReload)
  }

  @Test("同じFileItemでも展開状態(isExpanded)が変わった行はupdatedとして検出する")
  func detectsTreeExpansionChangeForSameURL() {
    let folderItem = FileItem(
      url: URL(filePath: "/tmp/folder", directoryHint: .isDirectory), isDirectory: true)
    let oldItems = [treeRow(folderItem, isExpanded: false)]
    let newItems = [treeRow(folderItem, isExpanded: true)]

    let diff = FileListView<Text, EmptyView>.Coordinator.computeDiff(from: oldItems, to: newItems)

    #expect(diff.updated == IndexSet(integer: 0))
    #expect(diff.removed.isEmpty)
    #expect(diff.inserted.isEmpty)
  }

  @Test("差分率が高い場合はreloadDataへフォールバックする")
  func fallsBackToFullReloadWhenDiffRatioIsHigh() {
    let oldItems = makeRows(names: ["a.txt", "b.txt", "c.txt", "d.txt"])
    let newItems = makeRows(names: ["w.txt", "x.txt", "y.txt", "z.txt"])

    let diff = FileListView<Text, EmptyView>.Coordinator.computeDiff(from: oldItems, to: newItems)

    #expect(diff.usesFullReload)
  }

  @Test("移動元の行を削除してもスクロール位置を保持する", arguments: [1, 70, 180, 200])
  func preservesScrollPositionWhenVisibleSourceRowIsRemoved(removedCount: Int) throws {
    let oldItems = makeRows(names: (0..<200).map { String(format: "%03d.txt", $0) })
    let coordinator = makeCoordinatorFromRows(oldItems, selection: .constant([]))
    let tableView = NSTableView()
    coordinator.rebuildColumns(displayOptions: FileBrowserDisplayOptions(), tableView: tableView)
    tableView.dataSource = coordinator
    tableView.delegate = coordinator
    FileListRowLayout.apply(.medium, to: tableView)
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
    scrollView.documentView = tableView
    tableView.reloadData()
    tableView.layoutSubtreeIfNeeded()
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: 1600))
    scrollView.reflectScrolledClipView(scrollView.contentView)
    let previousY = scrollView.contentView.bounds.minY
    #expect(previousY > 0)
    let visibleRow = tableView.row(at: NSPoint(x: 0, y: previousY + 20))
    #expect(visibleRow >= 0)
    tableView.selectRowIndexes(IndexSet(integer: visibleRow), byExtendingSelection: false)
    let firstRemovedRow = min(visibleRow, oldItems.count - removedCount)
    let newItems = oldItems.enumerated().filter {
      !(firstRemovedRow..<(firstRemovedRow + removedCount)).contains($0.offset)
    }.map(\.element)

    FileListRowLayout.apply(.medium, to: tableView)
    coordinator.items = newItems
    coordinator.applyDiff(from: oldItems, to: newItems, tableView: tableView)
    coordinator.syncSelectionFromModel([], tableView: tableView)

    // 空一覧では列ヘッダ分だけ負の原点が許されるため、AppKitの有効範囲へ制限する。
    var previousBounds = scrollView.contentView.bounds
    previousBounds.origin.y = previousY
    let expectedBounds = scrollView.contentView.constrainBoundsRect(previousBounds)
    #expect(scrollView.contentView.bounds.minY == expectedBounds.minY)
    #expect(tableView.numberOfRows == 200 - removedCount)
  }

  @Test("差分適用後もNSTableViewの行数が新配列と一致し選択がURLベースで再マップされる")
  func applyDiffUpdatesRowCountAndRemapsSelectionByURL() {
    let oldItems = makeRows(names: ["a.txt", "b.txt", "c.txt"])
    let newItems = makeRows(names: ["a.txt", "b.txt", "c.txt", "d.txt"])
    let coordinator = makeCoordinatorFromRows(
      oldItems, selection: .constant([oldItems[2].item.url]))
    let tableView = NSTableView()
    coordinator.rebuildColumns(displayOptions: FileBrowserDisplayOptions(), tableView: tableView)
    tableView.dataSource = coordinator
    tableView.reloadData()

    coordinator.items = newItems
    coordinator.applyDiff(from: oldItems, to: newItems, tableView: tableView)
    coordinator.syncSelectionFromModel([oldItems[2].item.url], tableView: tableView)

    #expect(tableView.numberOfRows == 4)
    #expect(tableView.selectedRowIndexes == IndexSet(integer: 2))
    #expect(
      coordinator.lastListDiffMeasurement
        == ListDiffMeasurement(
          oldItemCount: 3,
          newItemCount: 4,
          removedCount: 0,
          insertedCount: 1,
          updatedCount: 0,
          usedFullReload: false))
  }

  @Test("選択中の行を含む差分削除(removeRows)でも空集合がモデルへ書き戻されない")
  func guardsAgainstSelectionBackflowWhenSelectedRowIsRemoved() throws {
    // removeRows(at:)は選択中の行そのものを削除する場合に限りAppKitが
    // tableViewSelectionDidChangeを実際に発火させる(選択が0件になるため)。
    // reloadData()自体は選択をサイレントにクリアするだけで通知は発火しないため、
    // このテストは差分率30%以下でincremental removeRowsに倒れるケースで検証する。
    let oldItems = makeRows(names: [
      "a.txt", "b.txt", "c.txt", "d.txt", "e.txt", "f.txt", "g.txt", "h.txt", "i.txt", "j.txt",
    ])
    let removedURL = try #require(oldItems.first { $0.item.name == "e.txt" }).item.url
    let newItems = oldItems.filter { $0.item.url != removedURL }
    let survivingURL = try #require(oldItems.first { $0.item.name == "a.txt" }).item.url
    let spy = SelectionBindingSpy(initial: [removedURL, survivingURL])
    let coordinator = makeCoordinatorFromRows(oldItems, selection: spy.binding)
    let tableView = NSTableView()
    coordinator.rebuildColumns(displayOptions: FileBrowserDisplayOptions(), tableView: tableView)
    tableView.dataSource = coordinator
    tableView.delegate = coordinator
    tableView.reloadData()
    let removedOldRow = try #require(oldItems.firstIndex { $0.item.url == removedURL })
    let survivingOldRow = try #require(oldItems.firstIndex { $0.item.url == survivingURL })
    tableView.selectRowIndexes(
      IndexSet([removedOldRow, survivingOldRow]), byExtendingSelection: false)
    let writeCountBeforeDiff = spy.writeCount

    coordinator.items = newItems
    let diff = FileListView<Text, EmptyView>.Coordinator.computeDiff(from: oldItems, to: newItems)
    #expect(!diff.usesFullReload)  // この検証の前提: removeRows経路(選択中の行が削除される)であること
    coordinator.applyDiff(from: oldItems, to: newItems, tableView: tableView)

    // removeRowsが選択中の行(e.txt)を削除するとAppKitはtableViewSelectionDidChangeを実際に
    // 発火させるが、その変化(選択が空/縮小したという事実)がselectedItemURLs(モデル)へ
    // 書き戻されてはいけない(生き残っているa.txtの選択まで消えてしまうため)。
    #expect(spy.writeCount == writeCountBeforeDiff)
    #expect(spy.value == [removedURL, survivingURL])

    // updateNSViewが直後に行うのと同じ手順で、モデル側の選択をURLベースで再適用する。
    let expectedNewRow = try #require(newItems.firstIndex { $0.item.url == survivingURL })
    coordinator.syncSelectionFromModel(spy.value, tableView: tableView)

    #expect(tableView.selectedRowIndexes == IndexSet(integer: expectedNewRow))
  }

  @Test("型選択の照会文字列は項目名を返す")
  func typeSelectStringReturnsItemName() {
    let firstItem = FileItem(url: URL(filePath: "/tmp/report.txt"), isDirectory: false)
    let coordinator = makeCoordinator(items: [firstItem], selection: .constant([]))
    let tableView = NSTableView()

    let result = coordinator.tableView(tableView, typeSelectStringFor: nil, row: 0)

    #expect(result == "report.txt")
  }

  @Test("右クリックした行のcontextMenuItemsからNSMenuの項目を構築する")
  func buildsContextMenuFromDataForClickedRow() throws {
    let firstItem = FileItem(url: URL(filePath: "/tmp/a.txt"), isDirectory: false)
    let secondItem = FileItem(url: URL(filePath: "/tmp/b.txt"), isDirectory: false)
    var openedNames = [String]()
    let view = FileListView(
      items: treeRows([firstItem, secondItem]),
      selectedItemURLs: .constant([]),
      displayOptions: FileBrowserDisplayOptions(),
      gitStatuses: nil,
      nameCell: { item in Text(item.name) },
      contextMenu: { _ in EmptyView() },
      open: { _ in },
      contextMenuItems: { item in
        [
          FileContextMenuItem(title: "開く(\(item.name))") { openedNames.append(item.name) },
          FileContextMenuItem(title: "無効な項目", isEnabled: false) {},
          FileContextMenuItem(title: "削除", isDestructive: true) {},
        ]
      })
    let coordinator = view.makeCoordinator()
    coordinator.items = treeRows([firstItem, secondItem])
    let tableView = NSTableView()
    coordinator.rebuildColumns(displayOptions: FileBrowserDisplayOptions(), tableView: tableView)
    tableView.dataSource = coordinator
    tableView.reloadData()
    let menu = NSMenu()

    coordinator.buildContextMenu(menu, forRow: 1, tableView: tableView)

    #expect(menu.items.map(\.title) == ["開く(b.txt)", "無効な項目", "削除"])
    #expect(menu.items[0].isEnabled)
    #expect(!menu.items[1].isEnabled)
    #expect(menu.items[2].isEnabled)
    // 右クリックされた行(1)が未選択だった場合はFinder同様その行だけを単独選択する。
    #expect(tableView.selectedRowIndexes == IndexSet(integer: 1))

    // NSMenuItemのtarget/actionは実際のクリックで発火するAppKitの標準機構(信頼して検証しない)。
    // ここではmenu構築時に保持したデータが正しいクロージャを指していることだけを確認する。
    coordinator.currentContextMenuItems[0].action()
    #expect(openedNames == ["b.txt"])
  }

  @Test("systemImage・セパレータ・サブメニューを含むcontextMenuItemsからNSMenuを構築する")
  func buildsContextMenuWithIconsSeparatorsAndSubmenu() throws {
    let firstItem = FileItem(url: URL(filePath: "/tmp/a.txt"), isDirectory: false)
    var firedTitles = [String]()
    let view = FileListView(
      items: treeRows([firstItem]),
      selectedItemURLs: .constant([]),
      displayOptions: FileBrowserDisplayOptions(),
      gitStatuses: nil,
      nameCell: { item in Text(item.name) },
      contextMenu: { _ in EmptyView() },
      open: { _ in },
      contextMenuItems: { _ in
        [
          FileContextMenuItem(title: "開く", systemImage: "arrow.up.forward.app") {
            firedTitles.append("開く")
          },
          .separator(),
          FileContextMenuItem(
            title: "パスをコピー",
            systemImage: "doc.on.clipboard",
            children: [
              FileContextMenuItem(title: "パス") { firedTitles.append("パス") },
              FileContextMenuItem(title: "ファイル名") { firedTitles.append("ファイル名") },
            ]),
        ]
      })
    let coordinator = view.makeCoordinator()
    coordinator.items = treeRows([firstItem])
    let tableView = NSTableView()
    coordinator.rebuildColumns(displayOptions: FileBrowserDisplayOptions(), tableView: tableView)
    tableView.dataSource = coordinator
    tableView.reloadData()
    let menu = NSMenu()

    coordinator.buildContextMenu(menu, forRow: 0, tableView: tableView)

    try #require(menu.items.count == 3)
    #expect(menu.items[0].title == "開く")
    #expect(menu.items[0].image != nil)
    #expect(menu.items[1].isSeparatorItem)
    let submenuItem = menu.items[2]
    #expect(submenuItem.title == "パスをコピー")
    #expect(submenuItem.image != nil)
    #expect(submenuItem.submenu?.items.map(\.title) == ["パス", "ファイル名"])

    // サブメニュー項目もrepresentedObject経由でactionへたどり着けること(tag/index非依存)。
    let pathMenuItem = try #require(submenuItem.submenu?.items.first)
    coordinator.handleContextMenuAction(pathMenuItem)
    #expect(firedTitles == ["パス"])
  }

  @Test("実アプリアイコンは開く候補のNSMenuサブメニューまで保持される")
  func openWithApplicationImageSurvivesNativeSubmenu() throws {
    let item = FileItem(url: URL(filePath: "/tmp/image.txt"), isDirectory: false)
    let application = URL(filePath: "/System/Applications/TextEdit.app")
    let sourceIcon = NSWorkspace.shared.icon(forFile: application.path)
    let builder = OpenWithApplicationMenu(
      applications: { _ in [application] }, defaultApplication: { _ in nil },
      applicationIcon: { _ in sourceIcon })
    var children = builder.items(for: item.url, open: { _, _ in }, chooseOther: {})
    children[0].systemImage = "app.dashed"
    let view = FileListView(
      items: treeRows([item]), selectedItemURLs: .constant([]),
      displayOptions: FileBrowserDisplayOptions(), gitStatuses: nil,
      nameCell: { Text($0.name) }, contextMenu: { _ in EmptyView() }, open: { _ in },
      contextMenuItems: { _ in
        [FileContextMenuItem(title: "このアプリケーションで開く", children: children)]
      })
    let coordinator = view.makeCoordinator()
    coordinator.items = treeRows([item])
    let tableView = NSTableView()
    coordinator.rebuildColumns(displayOptions: FileBrowserDisplayOptions(), tableView: tableView)
    tableView.dataSource = coordinator
    tableView.reloadData()
    let menu = NSMenu()
    coordinator.buildContextMenu(menu, forRow: 0, tableView: tableView)

    let nativeIcon = try #require(menu.items.first?.submenu?.items.first?.image)
    let candidateIcon = try #require(children.first?.nsImage)
    #expect(nativeIcon === candidateIcon)
    #expect(nativeIcon.size == NSSize(width: 16, height: 16))
    #expect(nativeIcon.tiffRepresentation != nil)
    #expect(!nativeIcon.isTemplate)
  }

  @Test("SwiftUIメニューは候補アプリ画像を省略しない")
  func swiftUIMenuKeepsApplicationImageVisible() throws {
    let image =
      NSWorkspace.shared.icon(forFile: "/System/Applications/TextEdit.app").copy() as! NSImage
    image.size = NSSize(width: 16, height: 16)
    let children = [FileContextMenuItem(title: "TextEdit", nsImage: image)]
    // アイコン表示の右クリックとメニューバーが使う共通ビルダーを実NSMenuへ変換する。
    let menu = NSHostingMenu(
      rootView: fileContextMenuContent([
        FileContextMenuItem(title: "このアプリケーションで開く", children: children)
      ]))
    menu.update()
    let submenu = try #require(menu.items.first?.submenu)
    submenu.update()
    let candidate = try #require(submenu.items.first)
    #expect(candidate.image != nil)
    if #available(macOS 27.0, *) {
      #expect(candidate.preferredImageVisibility == .visible)
    }
  }

  @Test("リストとカラムの候補アプリ画像を省略しない", arguments: [FileBrowserViewMode.list, .column])
  func nativeOpenWithApplicationImageStaysVisible(mode: FileBrowserViewMode) throws {
    let item = FileItem(url: URL(filePath: "/tmp/visible-image.txt"), isDirectory: false)
    let image =
      NSWorkspace.shared.icon(forFile: "/System/Applications/TextEdit.app").copy() as! NSImage
    image.size = NSSize(width: 16, height: 16)
    var options = FileBrowserDisplayOptions()
    options.viewMode = mode
    let view = FileListView(
      items: treeRows([item]), selectedItemURLs: .constant([]), displayOptions: options,
      gitStatuses: nil, nameCell: { Text($0.name) }, contextMenu: { _ in EmptyView() },
      open: { _ in }, presentation: mode == .column ? .column : .standard,
      contextMenuItems: { _ in
        [
          FileContextMenuItem(
            title: "このアプリケーションで開く",
            children: [
              FileContextMenuItem(title: "TextEdit", nsImage: image)
            ])
        ]
      })
    let coordinator = view.makeCoordinator()
    coordinator.items = treeRows([item])
    let table = NSTableView()
    coordinator.rebuildColumns(displayOptions: options, tableView: table)
    table.dataSource = coordinator
    table.reloadData()
    let menu = NSMenu()
    coordinator.buildContextMenu(menu, forRow: 0, tableView: table)
    let candidate = try #require(menu.items.first?.submenu?.items.first)
    #expect(candidate.image != nil)
    if #available(macOS 27.0, *) {
      #expect(candidate.preferredImageVisibility == .visible)
    }
  }

  @Test("無効化されたメニュー項目はhandleContextMenuAction経由でも実行されない")
  func disabledContextMenuItemDoesNotFireViaHandler() throws {
    let firstItem = FileItem(url: URL(filePath: "/tmp/a.txt"), isDirectory: false)
    var fired = false
    let view = FileListView(
      items: treeRows([firstItem]),
      selectedItemURLs: .constant([]),
      displayOptions: FileBrowserDisplayOptions(),
      gitStatuses: nil,
      nameCell: { item in Text(item.name) },
      contextMenu: { _ in EmptyView() },
      open: { _ in },
      contextMenuItems: { _ in
        [FileContextMenuItem(title: "無効な項目", isEnabled: false) { fired = true }]
      })
    let coordinator = view.makeCoordinator()
    coordinator.items = treeRows([firstItem])
    let tableView = NSTableView()
    coordinator.rebuildColumns(displayOptions: FileBrowserDisplayOptions(), tableView: tableView)
    tableView.dataSource = coordinator
    tableView.reloadData()
    let menu = NSMenu()
    coordinator.buildContextMenu(menu, forRow: 0, tableView: tableView)
    let menuItem = try #require(menu.items.first)

    // NSMenu.autoenablesItems(既定true)がisEnabled=falseを上書きして見かけ上有効化されて
    // しまった場合を模して、handleContextMenuAction自体がisEnabledを再確認し空振りすることを
    // 検証する(makeNSViewのautoenablesItems=falseとあわせた二重の防御)。
    menuItem.isEnabled = true
    coordinator.handleContextMenuAction(menuItem)

    #expect(!fired)
  }

  @Test("supportsDragging=trueの行はNSURLをpasteboardWriterとして返す")
  func pasteboardWriterProvidesRowURLWhenDraggingSupported() throws {
    let firstItem = FileItem(url: URL(filePath: "/tmp/a.txt"), isDirectory: false)
    let view = FileListView(
      items: treeRows([firstItem]),
      selectedItemURLs: .constant([]),
      displayOptions: FileBrowserDisplayOptions(),
      gitStatuses: nil,
      nameCell: { item in Text(item.name) },
      contextMenu: { _ in EmptyView() },
      open: { _ in },
      supportsDragging: true)
    let coordinator = view.makeCoordinator()
    coordinator.items = treeRows([firstItem])
    let tableView = NSTableView()

    let writer = try #require(
      coordinator.tableView(tableView, pasteboardWriterForRow: 0) as? NSURL)

    #expect(writer as URL == firstItem.url)
  }

  @Test("supportsDragging=falseならpasteboardWriterはnilを返す")
  func pasteboardWriterReturnsNilWhenDraggingDisabled() {
    let firstItem = FileItem(url: URL(filePath: "/tmp/a.txt"), isDirectory: false)
    let view = FileListView(
      items: treeRows([firstItem]),
      selectedItemURLs: .constant([]),
      displayOptions: FileBrowserDisplayOptions(),
      gitStatuses: nil,
      nameCell: { item in Text(item.name) },
      contextMenu: { _ in EmptyView() },
      open: { _ in },
      supportsDragging: false)
    let coordinator = view.makeCoordinator()
    coordinator.items = treeRows([firstItem])
    let tableView = NSTableView()

    let writer = coordinator.tableView(tableView, pasteboardWriterForRow: 0)

    #expect(writer == nil)
  }

  @Test("範囲外の行のpasteboardWriterはnilを返す")
  func pasteboardWriterReturnsNilForOutOfRangeRow() {
    let coordinator = makeCoordinator(items: [], selection: .constant([]))
    let tableView = NSTableView()

    let writer = coordinator.tableView(tableView, pasteboardWriterForRow: 0)

    #expect(writer == nil)
  }

  @Test("ファイルURLを含むペーストボードはドロップを受け入れる")
  func acceptsDropContainingFileURLs() {
    let coordinator = makeCoordinator(items: [], selection: .constant([]))
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let droppedURL = URL(filePath: "/tmp/dropped.txt")
    pasteboard.writeObjects([droppedURL as NSURL])

    #expect(coordinator.canAcceptDrop(from: pasteboard))
  }

  @Test("ファイルURLを含まないペーストボードはドロップを拒否する")
  func rejectsDropWithoutFileURLs() {
    let coordinator = makeCoordinator(items: [], selection: .constant([]))
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.setString("plain text", forType: .string)

    #expect(!coordinator.canAcceptDrop(from: pasteboard))
  }

  @Test("acceptDropはドロップされたURLをonDropURLsへ委譲する")
  func acceptDropDelegatesURLsToCallback() {
    let firstDropped = URL(filePath: "/tmp/dropped-1.txt")
    let secondDropped = URL(filePath: "/tmp/dropped-2.txt")
    var receivedURLs: [URL] = []
    let view = FileListView(
      items: [FileTreeRow](),
      selectedItemURLs: .constant([]),
      displayOptions: FileBrowserDisplayOptions(),
      gitStatuses: nil,
      nameCell: { item in Text(item.name) },
      contextMenu: { _ in EmptyView() },
      open: { _ in },
      onDropURLs: { urls in
        receivedURLs = urls
        return true
      })
    let coordinator = view.makeCoordinator()
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.writeObjects([firstDropped as NSURL, secondDropped as NSURL])

    let accepted = coordinator.acceptDrop(from: pasteboard)

    #expect(accepted)
    #expect(Set(receivedURLs) == [firstDropped, secondDropped])
  }

  @Test("onDropURLsが未指定のときは既定でfalseを返しドロップを何もしない")
  func acceptDropDefaultsToRejectingWhenNoCallbackProvided() {
    let coordinator = makeCoordinator(items: [], selection: .constant([]))
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.writeObjects([URL(filePath: "/tmp/dropped.txt") as NSURL])

    #expect(!coordinator.acceptDrop(from: pasteboard))
  }

  @Test("フォルダ行だけを行ドロップ先として解決する")
  func resolvesOnlyDirectoryRowsAsDropFolders() {
    let file = FileItem(url: URL(filePath: "/tmp/file.txt"), isDirectory: false)
    let folder = FileItem(url: URL(filePath: "/tmp/folder"), isDirectory: true)
    let coordinator = makeCoordinator(items: [file, folder], selection: .constant([]))

    #expect(coordinator.dropFolder(at: 0) == nil)
    #expect(coordinator.dropFolder(at: 1) == folder)
    #expect(coordinator.dropFolder(at: -1) == nil)
    #expect(coordinator.dropFolder(at: 2) == nil)
  }

  @Test("フォルダ行へのacceptDropは対象フォルダ付きコールバックへ委譲する")
  func acceptDropDelegatesURLsToFolderCallback() {
    let droppedURL = URL(filePath: "/tmp/dropped.txt")
    let folder = FileItem(url: URL(filePath: "/tmp/folder"), isDirectory: true)
    var receivedFolder: FileItem?
    var didCallBackgroundDrop = false
    let view = FileListView(
      items: treeRows([folder]),
      selectedItemURLs: .constant([]),
      displayOptions: FileBrowserDisplayOptions(),
      gitStatuses: nil,
      nameCell: { item in Text(item.name) },
      contextMenu: { _ in EmptyView() },
      open: { _ in },
      onDropURLs: { _ in
        didCallBackgroundDrop = true
        return false
      },
      onDropURLsIntoFolder: { urls, destination in
        receivedFolder = destination
        return urls == [droppedURL]
      })
    let coordinator = view.makeCoordinator()
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.writeObjects([droppedURL as NSURL])

    let accepted = coordinator.acceptDrop(from: pasteboard, into: folder)

    #expect(accepted)
    #expect(receivedFolder == folder)
    #expect(!didCallBackgroundDrop)
  }

  @Test("範囲外の行ではNSMenuを空にする")
  func buildsEmptyContextMenuForOutOfRangeRow() {
    let firstItem = FileItem(url: URL(filePath: "/tmp/a.txt"), isDirectory: false)
    let coordinator = makeCoordinator(items: [firstItem], selection: .constant([]))
    let tableView = NSTableView()
    coordinator.rebuildColumns(displayOptions: FileBrowserDisplayOptions(), tableView: tableView)
    tableView.dataSource = coordinator
    tableView.reloadData()
    let menu = NSMenu()
    menu.addItem(NSMenuItem(title: "残存項目", action: nil, keyEquivalent: ""))

    coordinator.buildContextMenu(menu, forRow: -1, tableView: tableView)

    #expect(menu.items.isEmpty)
  }

  @Test("範囲外の行へのbeginInlineRenameは何もしない")
  func beginInlineRenameIgnoresOutOfRangeRow() {
    let firstItem = FileItem(url: URL(filePath: "/tmp/a.txt"), isDirectory: false)
    let coordinator = makeCoordinator(items: [firstItem], selection: .constant([firstItem.url]))
    let tableView = NSTableView()
    coordinator.rebuildColumns(displayOptions: FileBrowserDisplayOptions(), tableView: tableView)
    tableView.dataSource = coordinator
    tableView.reloadData()
    coordinator.tableView = tableView
    tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

    coordinator.beginInlineRename(atRow: 5)

    #expect(coordinator.inlineRenamingURL == nil)
  }

  @Test("選択中の行と異なる行へのbeginInlineRenameは何もしない")
  func beginInlineRenameIgnoresRowNotMatchingSelection() {
    let firstItem = FileItem(url: URL(filePath: "/tmp/a.txt"), isDirectory: false)
    let secondItem = FileItem(url: URL(filePath: "/tmp/b.txt"), isDirectory: false)
    let coordinator = makeCoordinator(
      items: [firstItem, secondItem], selection: .constant([firstItem.url]))
    let tableView = NSTableView()
    coordinator.rebuildColumns(displayOptions: FileBrowserDisplayOptions(), tableView: tableView)
    tableView.dataSource = coordinator
    tableView.reloadData()
    coordinator.tableView = tableView
    // 選択(0行目)とは異なる1行目に対して呼ばれた場合(選択がクリック後に変化した等)
    tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

    coordinator.beginInlineRename(atRow: 1)

    #expect(coordinator.inlineRenamingURL == nil)
  }

  @Test("シングルクリック・名前列・単一選択済み行・アクティブ済みペインならリネーム対象")
  func isRenameEligibleClickAcceptsCanonicalCase() {
    #expect(
      ActivatingTableView.isRenameEligibleClick(
        clickCount: 1,
        modifierFlags: [],
        clickedRow: 2,
        isNameColumn: true,
        selectedRowIndexes: IndexSet(integer: 2),
        wasPaneAlreadyActive: true))
  }

  @Test("ダブルクリックはリネーム対象にしない(開く動作に譲る)")
  func isRenameEligibleClickRejectsDoubleClick() {
    #expect(
      !ActivatingTableView.isRenameEligibleClick(
        clickCount: 2,
        modifierFlags: [],
        clickedRow: 0,
        isNameColumn: true,
        selectedRowIndexes: IndexSet(integer: 0),
        wasPaneAlreadyActive: true))
  }

  @Test("名前列以外のクリックはリネーム対象にしない")
  func isRenameEligibleClickRejectsNonNameColumn() {
    #expect(
      !ActivatingTableView.isRenameEligibleClick(
        clickCount: 1,
        modifierFlags: [],
        clickedRow: 0,
        isNameColumn: false,
        selectedRowIndexes: IndexSet(integer: 0),
        wasPaneAlreadyActive: true))
  }

  @Test("非アクティブペインへの最初のクリック(切替目的)はリネーム対象にしない")
  func isRenameEligibleClickRejectsClickThatActivatesPane() {
    #expect(
      !ActivatingTableView.isRenameEligibleClick(
        clickCount: 1,
        modifierFlags: [],
        clickedRow: 0,
        isNameColumn: true,
        selectedRowIndexes: IndexSet(integer: 0),
        wasPaneAlreadyActive: false))
  }

  @Test("commandやshiftを伴うクリック(選択操作)はリネーム対象にしない")
  func isRenameEligibleClickRejectsSelectionModifierClick() {
    #expect(
      !ActivatingTableView.isRenameEligibleClick(
        clickCount: 1,
        modifierFlags: [.command],
        clickedRow: 0,
        isNameColumn: true,
        selectedRowIndexes: IndexSet(integer: 0),
        wasPaneAlreadyActive: true))
    #expect(
      !ActivatingTableView.isRenameEligibleClick(
        clickCount: 1,
        modifierFlags: [.shift],
        clickedRow: 0,
        isNameColumn: true,
        selectedRowIndexes: IndexSet(integer: 0),
        wasPaneAlreadyActive: true))
  }

  @Test("複数選択中のクリックはリネーム対象にしない")
  func isRenameEligibleClickRejectsMultipleSelection() {
    #expect(
      !ActivatingTableView.isRenameEligibleClick(
        clickCount: 1,
        modifierFlags: [],
        clickedRow: 0,
        isNameColumn: true,
        selectedRowIndexes: IndexSet([0, 1]),
        wasPaneAlreadyActive: true))
  }

  @Test("クリックした行が選択中の行と異なる場合はリネーム対象にしない")
  func isRenameEligibleClickRejectsMismatchedRow() {
    #expect(
      !ActivatingTableView.isRenameEligibleClick(
        clickCount: 1,
        modifierFlags: [],
        clickedRow: 1,
        isNameColumn: true,
        selectedRowIndexes: IndexSet(integer: 0),
        wasPaneAlreadyActive: true))
  }

  @Test("行の外(余白)のクリックはリネーム対象にしない")
  func isRenameEligibleClickRejectsRowOutOfBounds() {
    #expect(
      !ActivatingTableView.isRenameEligibleClick(
        clickCount: 1,
        modifierFlags: [],
        clickedRow: -1,
        isNameColumn: true,
        selectedRowIndexes: IndexSet(),
        wasPaneAlreadyActive: true))
  }

  // MARK: - フォルダその場展開(開閉三角)

  @Test("展開可能な行(フォルダ)には開閉三角ボタンが表示され識別子が付く")
  func nameCellShowsDisclosureButtonForExpandableRow() throws {
    let folderItem = FileItem(
      url: URL(filePath: "/tmp/folder", directoryHint: .isDirectory), isDirectory: true)
    let row = FileTreeRow(item: folderItem, depth: 1, isExpanded: true, isLoadingChildren: false)
    let coordinator = makeCoordinatorFromRows([row], selection: .constant([]))
    let tableView = NSTableView()
    coordinator.rebuildColumns(displayOptions: FileBrowserDisplayOptions(), tableView: tableView)
    let nameColumn = try #require(
      tableView.tableColumns.first { $0.identifier.rawValue == "name" })

    let cellView = try #require(
      coordinator.tableView(tableView, viewFor: nameColumn, row: 0) as? NSTableCellView)
    let disclosureButton = try #require(
      cellView.subviews.compactMap { $0 as? NSButton }.first {
        $0.accessibilityIdentifier() == "file-disclosure-folder"
      })

    #expect(!disclosureButton.isHidden)
  }

  @Test("展開不可な行(ファイル)には開閉三角ボタンが表示されない")
  func nameCellHidesDisclosureButtonForFile() throws {
    let fileItem = FileItem(url: URL(filePath: "/tmp/report.txt"), isDirectory: false)
    let row = FileTreeRow(item: fileItem, depth: 0, isExpanded: false, isLoadingChildren: false)
    let coordinator = makeCoordinatorFromRows([row], selection: .constant([]))
    let tableView = NSTableView()
    coordinator.rebuildColumns(displayOptions: FileBrowserDisplayOptions(), tableView: tableView)
    let nameColumn = try #require(
      tableView.tableColumns.first { $0.identifier.rawValue == "name" })

    let cellView = try #require(
      coordinator.tableView(tableView, viewFor: nameColumn, row: 0) as? NSTableCellView)
    let disclosureButton = try #require(cellView.subviews.compactMap { $0 as? NSButton }.first)

    #expect(disclosureButton.isHidden)
  }

  @Test("子ロード中はスピナーを表示し開閉三角を隠す")
  func nameCellShowsLoadingIndicatorWhileChildrenLoad() throws {
    let folderItem = FileItem(
      url: URL(filePath: "/tmp/folder", directoryHint: .isDirectory), isDirectory: true)
    let row = FileTreeRow(item: folderItem, depth: 0, isExpanded: true, isLoadingChildren: true)
    let coordinator = makeCoordinatorFromRows([row], selection: .constant([]))
    let tableView = NSTableView()
    coordinator.rebuildColumns(displayOptions: FileBrowserDisplayOptions(), tableView: tableView)
    let nameColumn = try #require(
      tableView.tableColumns.first { $0.identifier.rawValue == "name" })

    let cellView = try #require(
      coordinator.tableView(tableView, viewFor: nameColumn, row: 0) as? NSTableCellView)
    let disclosureButton = try #require(cellView.subviews.compactMap { $0 as? NSButton }.first)
    let spinner = try #require(cellView.subviews.compactMap { $0 as? NSProgressIndicator }.first)

    #expect(disclosureButton.isHidden)
    #expect(!spinner.isHidden)
  }

  @Test("→キーは未展開フォルダをexpandへ、展開済み・ファイルはnoneへ")
  func rightArrowActionExpandsUnexpandedFolderOnly() {
    let folder = FileItem(
      url: URL(filePath: "/tmp/folder", directoryHint: .isDirectory), isDirectory: true)
    let file = FileItem(url: URL(filePath: "/tmp/report.txt"), isDirectory: false)
    let collapsedRow = FileTreeRow(
      item: folder, depth: 0, isExpanded: false, isLoadingChildren: false)
    let expandedRow = FileTreeRow(
      item: folder, depth: 0, isExpanded: true, isLoadingChildren: false)
    let fileRow = FileTreeRow(item: file, depth: 0, isExpanded: false, isLoadingChildren: false)

    #expect(
      FileTreeKeyboardNavigation.rightArrowAction(selectedRow: collapsedRow)
        == .expand(folder.url))
    #expect(FileTreeKeyboardNavigation.rightArrowAction(selectedRow: expandedRow) == .none)
    #expect(FileTreeKeyboardNavigation.rightArrowAction(selectedRow: fileRow) == .none)
    #expect(FileTreeKeyboardNavigation.rightArrowAction(selectedRow: nil) == .none)
  }

  @Test("←キーは展開済みフォルダをcollapseへ、未展開の子は親行のselectParentへ")
  func leftArrowActionCollapsesOrSelectsParent() {
    let root = FileItem(
      url: URL(filePath: "/tmp/root", directoryHint: .isDirectory), isDirectory: true)
    let child = FileItem(url: URL(filePath: "/tmp/root/child.txt"), isDirectory: false)
    let rootRow = FileTreeRow(item: root, depth: 0, isExpanded: true, isLoadingChildren: false)
    let childRow = FileTreeRow(item: child, depth: 1, isExpanded: false, isLoadingChildren: false)
    let rows = [rootRow, childRow]

    #expect(
      FileTreeKeyboardNavigation.leftArrowAction(
        selectedRow: rootRow, rows: rows, selectedIndex: 0)
        == .collapse(root.url))
    #expect(
      FileTreeKeyboardNavigation.leftArrowAction(
        selectedRow: childRow, rows: rows, selectedIndex: 1)
        == .selectParent(root.url))
  }

  @Test("深さ0の未展開行は←キーで何もしない")
  func leftArrowActionDoesNothingAtRootDepthWhenNotExpanded() {
    let root = FileItem(
      url: URL(filePath: "/tmp/root", directoryHint: .isDirectory), isDirectory: true)
    let rootRow = FileTreeRow(item: root, depth: 0, isExpanded: false, isLoadingChildren: false)

    #expect(
      FileTreeKeyboardNavigation.leftArrowAction(
        selectedRow: rootRow, rows: [rootRow], selectedIndex: 0) == .none)
  }

  @Test("孫行の←キーは直近の親(祖父母ではなく)へ選択移動する")
  func leftArrowActionSelectsNearestAncestorNotRoot() {
    let root = FileItem(
      url: URL(filePath: "/tmp/root", directoryHint: .isDirectory), isDirectory: true)
    let child = FileItem(
      url: URL(filePath: "/tmp/root/child", directoryHint: .isDirectory), isDirectory: true)
    let grandchild = FileItem(url: URL(filePath: "/tmp/root/child/leaf.txt"), isDirectory: false)
    let rootRow = FileTreeRow(item: root, depth: 0, isExpanded: true, isLoadingChildren: false)
    let childRow = FileTreeRow(item: child, depth: 1, isExpanded: true, isLoadingChildren: false)
    let grandchildRow = FileTreeRow(
      item: grandchild, depth: 2, isExpanded: false, isLoadingChildren: false)
    let rows = [rootRow, childRow, grandchildRow]

    #expect(
      FileTreeKeyboardNavigation.leftArrowAction(
        selectedRow: grandchildRow, rows: rows, selectedIndex: 2)
        == .selectParent(child.url))
  }

  private func treeRow(
    _ item: FileItem, depth: Int = 0, isExpanded: Bool = false, isLoadingChildren: Bool = false
  ) -> FileTreeRow {
    FileTreeRow(
      item: item, depth: depth, isExpanded: isExpanded, isLoadingChildren: isLoadingChildren)
  }

  private func routeColumnScroll(
    phase: ColumnScrollGestureRouting.Phase = .none,
    momentumPhase: ColumnScrollGestureRouting.Phase = .none,
    deltaX: Double = 0,
    deltaY: Double = 0,
    state: ColumnScrollGestureRouting.State
  ) -> ColumnScrollGestureRouting.Decision {
    ColumnScrollGestureRouting.route(
      phase: phase,
      momentumPhase: momentumPhase,
      deltaX: deltaX,
      deltaY: deltaY,
      state: state)
  }

  private func treeRows(_ items: [FileItem]) -> [FileTreeRow] {
    items.map { treeRow($0) }
  }

  private func makeItems(names: [String]) -> [FileItem] {
    names.map { name in
      FileItem(url: URL(filePath: "/tmp/\(name)"), isDirectory: false)
    }
  }

  private func makeRows(names: [String]) -> [FileTreeRow] {
    treeRows(makeItems(names: names))
  }

  private static func milliseconds(_ duration: Duration) -> String {
    let components = duration.components
    let seconds = Double(components.seconds) * 1_000
    let attoseconds = Double(components.attoseconds) / 1_000_000_000_000_000
    return String(format: "%.2f", seconds + attoseconds)
  }

  private func widthState(
    name: CGFloat,
    size: CGFloat,
    modifiedAt: CGFloat
  ) -> FileListColumnWidthState {
    FileListColumnWidthState(
      currentWidths: [.name: name, .size: size, .modifiedAt: modifiedAt],
      preferredWidths: [.size: 100, .modifiedAt: 160],
      minimumWidths: [.name: 160, .size: 60, .modifiedAt: 100, .location: 100])
  }

  private func makeCoordinator(
    items: [FileItem],
    selection: Binding<Set<URL>>,
    displayOptions: FileBrowserDisplayOptions = FileBrowserDisplayOptions()
  ) -> FileListView<Text, EmptyView>.Coordinator {
    makeCoordinatorFromRows(treeRows(items), selection: selection, displayOptions: displayOptions)
  }

  private func makeCoordinatorFromRows(
    _ rows: [FileTreeRow],
    selection: Binding<Set<URL>>,
    displayOptions: FileBrowserDisplayOptions = FileBrowserDisplayOptions()
  ) -> FileListView<Text, EmptyView>.Coordinator {
    let view = FileListView(
      items: rows,
      selectedItemURLs: selection,
      displayOptions: displayOptions,
      gitStatuses: nil,
      nameCell: { item in Text(item.name) },
      contextMenu: { _ in EmptyView() },
      open: { _ in })
    let coordinator = view.makeCoordinator()
    coordinator.items = rows
    return coordinator
  }
}

/// 選択Bindingの書き戻し回数・値を記録するスパイ。逆流ガードの検証専用。
@MainActor
private final class SelectionBindingSpy {
  private(set) var writeCount = 0
  private(set) var writtenValues: [Set<URL>] = []
  var value: Set<URL> {
    didSet {
      writeCount += 1
      writtenValues.append(value)
    }
  }

  init(initial: Set<URL>) {
    value = initial
  }

  var binding: Binding<Set<URL>> {
    Binding(get: { self.value }, set: { self.value = $0 })
  }
}
