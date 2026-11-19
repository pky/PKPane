import AppKit
import SwiftUI
import Testing

@testable import PKPane

@MainActor
struct PaneHoverActivationTests {
  @Test("アプリへ届いた移動イベントから背景ペインへ配送してフォーカスを移す")
  func applicationEventReachesPaneBehindNativeList() throws {
    let fixture = Fixture()
    defer { fixture.monitor.removeFromSuperview() }
    var activations = 0
    fixture.monitor.activate = { activations += 1 }
    #expect(!fixture.window.isVisible)
    let event = try movementEvent(in: fixture.window, at: NSPoint(x: 350, y: 100))
    #expect(event.window === fixture.window)

    NSApp.sendEvent(event)

    #expect(activations == 1)
    #expect(fixture.window.firstResponder === fixture.target)
  }

  @Test("SwiftUIの背景でクリックを受けない監視ビューにも実イベントが届く")
  func applicationEventReachesSwiftUIBackground() throws {
    let fixture = Fixture()
    fixture.monitor.removeFromSuperview()
    fixture.sourceScroll.removeFromSuperview()
    fixture.targetScroll.removeFromSuperview()
    var activations = 0
    let hosting = NSHostingView(
      rootView: HStack(spacing: 0) {
        HoverNativeList(scrollView: fixture.sourceScroll)
        HoverNativeList(scrollView: fixture.targetScroll)
          .background {
            PaneHoverActivationMonitor(
              usesNativeList: true, isEnabled: { true }, activate: { activations += 1 }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
      }.frame(width: 400, height: 200))
    fixture.window.contentView = hosting
    hosting.layoutSubtreeIfNeeded()
    defer { fixture.window.contentView = nil }
    let monitor = try #require(descendantMonitor(in: hosting))
    #expect(monitor.bounds.width > 0 && monitor.bounds.height > 0)
    #expect(monitor.isMonitoringEvents)
    #expect(fixture.window.makeFirstResponder(fixture.source))
    #expect(!fixture.window.isVisible)
    let location = monitor.convert(
      NSPoint(x: monitor.bounds.midX, y: monitor.bounds.midY), to: nil)

    NSApp.sendEvent(try movementEvent(in: fixture.window, at: location))

    #expect(activations == 1)
    #expect(fixture.window.firstResponder === fixture.target)
  }

  @Test("移動イベントの受付は同一窓の全監視ビューが外れるまで維持して元へ戻す")
  func sharesWindowMouseMoveAcceptanceUntilLastMonitorIsRemoved() {
    let window = HoverTestWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
      styleMask: [], backing: .buffered, defer: true)
    window.acceptsMouseMovedEvents = false
    let first = PaneHoverActivationMonitorView(
      usesNativeList: false, isEnabled: { true }, activate: {})
    let second = PaneHoverActivationMonitorView(
      usesNativeList: false, isEnabled: { true }, activate: {})
    window.contentView?.addSubview(first)
    window.contentView?.addSubview(second)
    #expect(window.acceptsMouseMovedEvents)
    first.removeFromSuperview()
    #expect(window.acceptsMouseMovedEvents)
    second.removeFromSuperview()
    #expect(!window.acceptsMouseMovedEvents)
  }

  @Test("元から移動イベントを受け付けていた窓の設定は解除後も保つ")
  func preservesExistingWindowMouseMoveAcceptance() {
    let window = HoverTestWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
      styleMask: [], backing: .buffered, defer: true)
    window.acceptsMouseMovedEvents = true
    let monitor = PaneHoverActivationMonitorView(
      usesNativeList: false, isEnabled: { true }, activate: {})
    window.contentView?.addSubview(monitor)
    monitor.removeFromSuperview()
    #expect(window.acceptsMouseMovedEvents)
  }

  @Test("イベント配送は別窓と範囲外を無視し、解除した監視には届かない")
  func eventDeliveryStaysWithinOwnerAndLifetime() throws {
    let fixture = Fixture()
    var activations = 0
    fixture.monitor.activate = { activations += 1 }
    let other = HoverTestWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
      styleMask: [], backing: .buffered, defer: false)
    NSApp.sendEvent(try movementEvent(in: other, at: NSPoint(x: 350, y: 100)))
    NSApp.sendEvent(try movementEvent(in: fixture.window, at: NSPoint(x: 50, y: 100)))
    #expect(activations == 0)
    fixture.monitor.removeFromSuperview()
    NSApp.sendEvent(try movementEvent(in: fixture.window, at: NSPoint(x: 350, y: 100)))
    #expect(activations == 0)
    #expect(fixture.window.firstResponder === fixture.source)
  }

  @Test("入力中・ドラッグ中・非キーウインドウ・シート・メニューでは切り替えない")
  func blocksConflictingInteractions() {
    #expect(PaneHoverActivationState().permitsActivation)
    var states = Array(repeating: PaneHoverActivationState(), count: 7)
    states[0].isEnabled = false
    states[1].isKeyWindow = false
    states[2].hasAttachedSheet = true
    states[3].isMenuTracking = true
    states[4].pressedMouseButtons = 1
    states[5].pressedMouseButtons = 2
    states[6].isEditingText = true
    for state in states {
      #expect(!state.permitsActivation)
    }
  }

  @Test("一覧への移動では選択を変えずフォーカスを移した後にペインを切り替える")
  func focusesTableBeforeActivationWithoutChangingSelection() {
    let fixture = Fixture()
    fixture.target.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
    var activations = 0
    fixture.monitor.activate = { [weak window = fixture.window, weak target = fixture.target] in
      #expect(window?.firstResponder === target)
      activations += 1
    }
    fixture.move()
    #expect(activations == 1)
    #expect(fixture.target.selectedRowIndexes == IndexSet(integer: 1))
    #expect(fixture.source.selectedRowIndexes.isEmpty)
  }

  @Test("アイコンでは古い一覧からフォーカスを外して共通キー操作を維持する")
  func iconFocusLeavesOldTable() {
    let fixture = Fixture()
    fixture.monitor.usesNativeList = false
    var activations = 0
    fixture.monitor.activate = { activations += 1 }
    fixture.move()
    #expect(activations == 1)
    #expect(fixture.window.firstResponder === fixture.monitor)
    #expect(KeyboardCommandRouter.handlesListCommands(for: fixture.window.firstResponder))
  }

  @Test("カラム表示ではポインタの下にあるカラムを優先する")
  func focusesPointedColumn() {
    let fixture = Fixture()
    fixture.targetScroll.frame.size.width = 80
    let scroll = NSScrollView(frame: NSRect(x: 280, y: 0, width: 120, height: 200))
    let second = NSTableView(frame: scroll.bounds)
    second.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")))
    second.headerView = nil
    scroll.documentView = second
    fixture.window.contentView?.addSubview(scroll)
    fixture.move()
    #expect(fixture.window.firstResponder === second)
  }

  @Test("パンくずの上では選択のある可視カラムにフォーカスを移す")
  func breadcrumbFocusPrefersSelectedColumn() {
    let fixture = Fixture()
    fixture.targetScroll.frame.size.height = 150
    fixture.target.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
    let scroll = NSScrollView(frame: NSRect(x: 280, y: 0, width: 120, height: 150))
    let second = NSTableView(frame: scroll.bounds)
    second.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")))
    second.headerView = nil
    scroll.documentView = second
    fixture.window.contentView?.addSubview(scroll)
    fixture.move(location: NSPoint(x: 350, y: 180))
    #expect(fixture.window.firstResponder === fixture.target)
  }

  @Test("名前変更や検索のテキスト編集中はフォーカスと操作対象を保持する")
  func preservesTextEditing() {
    let fixture = Fixture()
    let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
    fixture.window.contentView?.addSubview(editor)
    #expect(fixture.window.makeFirstResponder(editor))
    var activations = 0
    fixture.monitor.activate = { activations += 1 }
    fixture.move()
    #expect(activations == 0)
    #expect(fixture.window.firstResponder === editor)
  }

  @Test("ドラッグとメニュー追跡中にはフォーカスを奪わない")
  func preservesFocusDuringDragAndMenu() {
    let fixture = Fixture()
    var activations = 0
    fixture.monitor.activate = { activations += 1 }
    fixture.move(pressedMouseButtons: 1)
    fixture.move(isMenuTracking: true)
    #expect(activations == 0)
    #expect(fixture.window.firstResponder === fixture.source)
  }

  @Test("別ウインドウ・ペイン外・非キーウインドウの移動は無視する")
  func ignoresOtherWindowsAndOutsidePane() {
    let fixture = Fixture()
    let other = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
    var activations = 0
    fixture.monitor.activate = { activations += 1 }
    fixture.move(eventWindow: other)
    #expect(activations == 0)
    let outside = fixture.monitor.convert(NSPoint(x: 50, y: 100), from: nil)
    #expect(
      !fixture.monitor.visibleRect.contains(outside),
      "監視frame=\(fixture.monitor.frame)、bounds=\(fixture.monitor.bounds)、visible=\(fixture.monitor.visibleRect)、変換後=\(outside)"
    )
    fixture.move(location: NSPoint(x: 50, y: 100))
    #expect(activations == 0)
    fixture.window.isKeyForTesting = false
    fixture.move()
    #expect(activations == 0)
    #expect(fixture.window.firstResponder === fixture.source)
  }

  @Test("既に操作対象なら移動ごとの再処理とフォーカス変更を行わない")
  func skipsAlreadyActivePane() {
    let fixture = Fixture()
    fixture.monitor.isEnabled = { false }
    var activations = 0
    fixture.monitor.activate = { activations += 1 }
    fixture.move()
    #expect(activations == 0)
    #expect(fixture.window.firstResponder === fixture.source)
  }

  @Test("フォーカスを移せなかった場合は操作対象も変えない")
  func failedFocusDoesNotActivate() {
    let fixture = Fixture()
    fixture.window.rejectFocusForTesting = true
    var activations = 0
    fixture.monitor.activate = { activations += 1 }
    fixture.move()
    #expect(activations == 0)
    #expect(fixture.window.firstResponder === fixture.source)
  }

  @Test("ウインドウから外れた監視ビューはイベント監視を終了する")
  func removesMonitorWhenDetached() {
    let fixture = Fixture()
    #expect(fixture.monitor.isMonitoringEvents)
    fixture.monitor.removeFromSuperview()
    #expect(!fixture.monitor.isMonitoringEvents)
  }

  @Test("監視ビューは明示的にフォーカス可能だがTabの巡回先には加えない")
  func monitorDoesNotJoinTabTraversal() {
    let fixture = Fixture()
    #expect(fixture.monitor.acceptsFirstResponder)
    #expect(!fixture.monitor.canBecomeKeyView)
  }

  @Test("キーボード切替や再描画だけでは静止ポインタ側へ戻さない")
  func changingConfigurationDoesNotActivate() {
    let fixture = Fixture()
    var activations = 0
    fixture.monitor.activate = { activations += 1 }
    fixture.monitor.isEnabled = { false }
    fixture.monitor.isEnabled = { true }
    fixture.monitor.startEventMonitorIfNeeded()
    #expect(activations == 0)
    #expect(fixture.window.firstResponder === fixture.source)
  }
}

@MainActor
private func movementEvent(in window: NSWindow, at location: NSPoint) throws -> NSEvent {
  let event = try #require(
    NSEvent.mouseEvent(
      with: .mouseMoved, location: location, modifierFlags: [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, eventNumber: 0,
      clickCount: 0, pressure: 0))
  try #require(event.window === window)
  return event
}

@MainActor
private func descendantMonitor(in view: NSView) -> PaneHoverActivationMonitorView? {
  if let monitor = view as? PaneHoverActivationMonitorView { return monitor }
  for subview in view.subviews {
    if let monitor = descendantMonitor(in: subview) { return monitor }
  }
  return nil
}

private struct HoverNativeList: NSViewRepresentable {
  let scrollView: NSScrollView

  func makeNSView(context: Context) -> NSScrollView { scrollView }
  func updateNSView(_ view: NSScrollView, context: Context) {}
}

@MainActor
private final class HoverTestWindow: NSWindow {
  var isKeyForTesting = true
  var rejectFocusForTesting = false
  override var isKeyWindow: Bool { isKeyForTesting }

  override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
    !rejectFocusForTesting && super.makeFirstResponder(responder)
  }
}

@MainActor
private final class HoverTableDataSource: NSObject, NSTableViewDataSource {
  func numberOfRows(in tableView: NSTableView) -> Int { 3 }
}

@MainActor
private final class Fixture {
  let window = HoverTestWindow(
    contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
    styleMask: [], backing: .buffered, defer: false)
  let source = NSTableView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
  let target = NSTableView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
  let sourceScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
  let targetScroll = NSScrollView(frame: NSRect(x: 200, y: 0, width: 200, height: 200))
  let monitor = PaneHoverActivationMonitorView(
    usesNativeList: true, isEnabled: { true }, activate: {})
  let dataSource = HoverTableDataSource()

  init() {
    window.isReleasedWhenClosed = false
    source.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")))
    target.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")))
    source.headerView = nil
    target.headerView = nil
    source.dataSource = dataSource
    target.dataSource = dataSource
    source.reloadData()
    target.reloadData()
    sourceScroll.documentView = source
    targetScroll.documentView = target
    monitor.frame = targetScroll.frame
    window.contentView?.addSubview(monitor)
    window.contentView?.addSubview(sourceScroll)
    window.contentView?.addSubview(targetScroll)
    #expect(monitor.frame == NSRect(x: 200, y: 0, width: 200, height: 200))
    #expect(window.makeFirstResponder(source))
    #expect(window.firstResponder === source)
  }

  func move(
    location: NSPoint = NSPoint(x: 350, y: 100),
    eventWindow: NSWindow? = nil,
    pressedMouseButtons: Int = 0,
    isMenuTracking: Bool = false
  ) {
    monitor.processMouseMoved(
      at: location, eventWindow: eventWindow ?? window,
      pressedMouseButtons: pressedMouseButtons, isMenuTracking: isMenuTracking)
  }
}
