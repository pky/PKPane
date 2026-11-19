import AppKit
import SwiftUI

/// ホバーで操作対象を変えても、入力中の操作を中断しないための条件。
struct PaneHoverActivationState {
  var isEnabled = true
  var isKeyWindow = true
  var hasAttachedSheet = false
  var isMenuTracking = false
  var pressedMouseButtons = 0
  var isEditingText = false

  var permitsActivation: Bool {
    isEnabled && isKeyWindow && !hasAttachedSheet && !isMenuTracking
      && pressedMouseButtons == 0 && !isEditingText
  }
}

struct PaneHoverActivationMonitor: NSViewRepresentable {
  let usesNativeList: Bool
  let isEnabled: () -> Bool
  let activate: () -> Void

  func makeNSView(context: Context) -> PaneHoverActivationMonitorView {
    PaneHoverActivationMonitorView(
      usesNativeList: usesNativeList, isEnabled: isEnabled, activate: activate)
  }

  func updateNSView(_ view: PaneHoverActivationMonitorView, context: Context) {
    view.usesNativeList = usesNativeList
    view.isEnabled = isEnabled
    view.activate = activate
    view.startEventMonitorIfNeeded()
  }

  static func dismantleNSView(_ view: PaneHoverActivationMonitorView, coordinator: ()) {
    view.stopEventMonitor()
  }
}

@MainActor
final class PaneHoverActivationMonitorView: NSView {
  var usesNativeList: Bool
  var isEnabled: () -> Bool
  var activate: () -> Void
  private var eventMonitor: Any?
  private weak var monitoredWindow: NSWindow?

  var isMonitoringEvents: Bool { eventMonitor != nil }
  override var acceptsFirstResponder: Bool { true }
  override var canBecomeKeyView: Bool { false }

  init(
    usesNativeList: Bool, isEnabled: @escaping () -> Bool, activate: @escaping () -> Void
  ) {
    self.usesNativeList = usesNativeList
    self.isEnabled = isEnabled
    self.activate = activate
    super.init(frame: .zero)
    // macOS 14以降は既定でbounds外もvisibleRectに含まれるため、監視範囲を制限する。
    clipsToBounds = true
  }

  required init?(coder: NSCoder) { nil }

  isolated deinit {
    stopEventMonitor()
  }

  // 背景の監視ビューはクリックやドロップを受け取らない。
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    startEventMonitorIfNeeded()
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    stopEventMonitor()
    super.viewWillMove(toWindow: newWindow)
  }

  func startEventMonitorIfNeeded() {
    guard eventMonitor == nil, let window else { return }
    // 背景のtracking areaへの配送に依存せず、所有窓へ届いた実移動だけを見る。
    // イベントは消費せず、一覧のホバープレビューなどにも従来どおり渡す。
    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
      guard let self, WindowEventRouting.belongsToWindow(event.window, owner: self.window)
      else { return event }
      self.handleMouseMoved(event)
      return event
    }
    guard eventMonitor != nil else { return }
    monitoredWindow = window
    PaneHoverWindowMouseMovement.begin(in: window)
  }

  func stopEventMonitor() {
    if let eventMonitor {
      NSEvent.removeMonitor(eventMonitor)
      self.eventMonitor = nil
    }
    if let monitoredWindow {
      PaneHoverWindowMouseMovement.end(in: monitoredWindow)
      self.monitoredWindow = nil
    }
  }

  private func handleMouseMoved(_ event: NSEvent) {
    processMouseMoved(
      at: event.locationInWindow, eventWindow: event.window,
      pressedMouseButtons: Int(NSEvent.pressedMouseButtons),
      isMenuTracking: RunLoop.current.currentMode == .eventTracking)
  }

  func processMouseMoved(
    at location: NSPoint, eventWindow: NSWindow?,
    pressedMouseButtons: Int, isMenuTracking: Bool
  ) {
    guard let window,
      WindowEventRouting.belongsToWindow(eventWindow, owner: window),
      !isHiddenOrHasHiddenAncestor,
      bounds.intersection(visibleRect).contains(convert(location, from: nil))
    else { return }
    let state = PaneHoverActivationState(
      isEnabled: isEnabled(), isKeyWindow: window.isKeyWindow,
      hasAttachedSheet: window.attachedSheet != nil || NSApp.modalWindow != nil,
      isMenuTracking: isMenuTracking, pressedMouseButtons: pressedMouseButtons,
      isEditingText: !KeyboardCommandRouter.handlesListCommands(for: window.firstResponder)
        || (window.firstResponder as? NSTextField)?.isEditable == true)
    guard state.permitsActivation else { return }

    // モデルの操作対象だけを変えると、矢印キーは旧ペインのNSTableViewへ届く。
    // 先にフォーカスを移し、拒否された場合は操作対象もそのままにする。
    let responder: NSResponder
    if usesNativeList {
      guard let table = focusTable(at: location, in: window) else { return }
      responder = table
    } else {
      // アイコンのControl-N/P等は既存の共通キーボードルーターが処理する。
      responder = self
    }
    guard window.makeFirstResponder(responder), window.firstResponder === responder else { return }
    activate()
  }

  private func focusTable(at location: NSPoint, in window: NSWindow) -> NSTableView? {
    guard let contentView = window.contentView else { return nil }
    let paneRect = convert(bounds.intersection(visibleRect), to: nil)
    let tables = visibleTables(in: contentView, intersecting: paneRect)
    return tables.first { $0.visibleRect.contains($0.convert(location, from: nil)) }
      ?? tables.first { !$0.selectedRowIndexes.isEmpty }
      ?? tables.first
  }

  private func visibleTables(in view: NSView, intersecting paneRect: NSRect) -> [NSTableView] {
    guard !view.isHiddenOrHasHiddenAncestor,
      paneRect.intersects(view.convert(view.visibleRect, to: nil))
    else { return [] }
    // テーブルの子（行・セル）は走査しない。ファイル件数に依存しない探索にする。
    if let table = view as? NSTableView { return [table] }
    return view.subviews.flatMap { visibleTables(in: $0, intersecting: paneRect) }
  }
}

/// 2ペインの片方が外れても受付を止めず、最後の監視解除時だけ元の設定へ戻す。
@MainActor
private enum PaneHoverWindowMouseMovement {
  private final class Registration {
    let originallyAccepted: Bool
    var count = 1

    init(originallyAccepted: Bool) {
      self.originallyAccepted = originallyAccepted
    }
  }

  private static let registrations = NSMapTable<NSWindow, Registration>(
    keyOptions: .weakMemory, valueOptions: .strongMemory)

  static func begin(in window: NSWindow) {
    if let registration = registrations.object(forKey: window) {
      registration.count += 1
    } else {
      registrations.setObject(
        Registration(originallyAccepted: window.acceptsMouseMovedEvents), forKey: window)
    }
    window.acceptsMouseMovedEvents = true
  }

  static func end(in window: NSWindow) {
    guard let registration = registrations.object(forKey: window) else { return }
    registration.count -= 1
    guard registration.count == 0 else { return }
    window.acceptsMouseMovedEvents = registration.originallyAccepted
    registrations.removeObject(forKey: window)
  }
}
