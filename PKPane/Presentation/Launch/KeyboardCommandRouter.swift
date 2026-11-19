import AppKit
import SwiftUI

enum KeyboardCommandMonitorDecision: Equatable {
  case handle(KeyboardCommand)
  case deferToAppMenu
  case passThrough
}

@MainActor
struct KeyboardCommandRouter {
  static func command(
    for event: NSEvent,
    keymap: KeyboardCommandMap? = nil
  ) -> KeyboardCommand? {
    return command(
      characters: event.charactersIgnoringModifiers,
      modifiers: event.modifierFlags,
      handlesListCommands: handlesListCommands(for: event.window?.firstResponder),
      keyCode: event.keyCode,
      keymap: keymap ?? KeymapPreferencesStore.shared.current)
  }

  static func command(
    characters: String?,
    modifiers: NSEvent.ModifierFlags,
    handlesListCommands: Bool,
    keyCode _: UInt16? = nil,
    keymap: KeyboardCommandMap = .defaults
  ) -> KeyboardCommand? {
    guard let characters else { return nil }
    return keymap.command(
      for: KeymapShortcut(characters: characters, modifiers: modifiers),
      handlesListCommands: handlesListCommands)
  }

  static func handlesListCommands(for responder: NSResponder?) -> Bool {
    !isTextEditing(responder)
  }

  static func monitorDecision(
    for event: NSEvent,
    keymap: KeyboardCommandMap? = nil
  ) -> KeyboardCommandMonitorDecision {
    let resolvedKeymap = keymap ?? KeymapPreferencesStore.shared.current
    guard let characters = event.charactersIgnoringModifiers else { return .passThrough }
    let shortcut = KeymapShortcut(characters: characters, modifiers: event.modifierFlags)
    guard
      let command = resolvedKeymap.command(
        for: shortcut,
        handlesListCommands: handlesListCommands(for: event.window?.firstResponder))
    else {
      return .passThrough
    }

    // 既定バインディングは従来どおりルーターが先に消費する。メニューへ譲るのは、
    // ユーザーが変更した当該コマンドの割り当てが静的メニューと衝突した場合だけ。
    let isCustomized =
      resolvedKeymap.bindings(for: command) != KeyboardCommandMap.defaults.bindings(for: command)
    if isCustomized, AppMenuCommands.shortcutInventory.contains(shortcut) {
      return .deferToAppMenu
    }
    return .handle(command)
  }

  private static func isTextEditing(_ responder: NSResponder?) -> Bool {
    guard let textView = responder as? NSTextView else { return false }
    return textView.isEditable || textView.hasMarkedText()
  }
}

struct KeyboardCommandMonitor: NSViewRepresentable {
  let handle: (KeyboardCommand) -> Void

  func makeNSView(context: Context) -> KeyboardCommandMonitorView {
    KeyboardCommandMonitorView(handle: handle)
  }

  func updateNSView(_ view: KeyboardCommandMonitorView, context: Context) {
    view.handle = handle
    view.startEventMonitorIfNeeded()
  }
}

struct TableDoubleClickMonitor: NSViewRepresentable {
  let open: () -> Void
  let rename: () -> Void

  func makeNSView(context: Context) -> TableDoubleClickMonitorView {
    TableDoubleClickMonitorView(open: open, rename: rename)
  }

  func updateNSView(_ view: TableDoubleClickMonitorView, context: Context) {
    view.open = open
    view.rename = rename
    view.startEventMonitorIfNeeded()
  }
}

@MainActor
final class KeyboardCommandMonitorView: NSView {
  var handle: (KeyboardCommand) -> Void
  private var eventMonitor: Any?

  init(handle: @escaping (KeyboardCommand) -> Void) {
    self.handle = handle
    super.init(frame: .zero)
  }

  required init?(coder: NSCoder) {
    nil
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    removeEventMonitor()
    startEventMonitorIfNeeded()
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow == nil {
      removeEventMonitor()
    }
    super.viewWillMove(toWindow: newWindow)
  }

  func startEventMonitorIfNeeded() {
    guard eventMonitor == nil, window != nil else { return }
    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, WindowEventRouting.belongsToWindow(event.window, owner: self.window),
        !KeyboardShortcutRecordingState.isRecording
      else {
        return event
      }
      switch KeyboardCommandRouter.monitorDecision(for: event) {
      case .handle(let command):
        self.handle(command)
        return nil
      case .deferToAppMenu, .passThrough:
        return event
      }
    }
  }

  private func removeEventMonitor() {
    if let eventMonitor {
      NSEvent.removeMonitor(eventMonitor)
      self.eventMonitor = nil
    }
  }
}

@MainActor
final class TableDoubleClickMonitorView: NSView {
  var open: () -> Void
  var rename: () -> Void
  private var eventMonitor: Any?
  private var pendingRename: DispatchWorkItem?

  init(open: @escaping () -> Void, rename: @escaping () -> Void) {
    self.open = open
    self.rename = rename
    super.init(frame: .zero)
  }

  required init?(coder: NSCoder) {
    nil
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    removeEventMonitor()
    startEventMonitorIfNeeded()
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow == nil {
      removeEventMonitor()
    }
    super.viewWillMove(toWindow: newWindow)
  }

  func startEventMonitorIfNeeded() {
    guard eventMonitor == nil, window != nil else { return }
    eventMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDown, .leftMouseDragged]
    ) { [weak self] event in
      guard let self, WindowEventRouting.belongsToWindow(event.window, owner: self.window)
      else { return event }
      if event.type == .leftMouseDragged {
        self.cancelPendingRename()
        return event
      }
      guard self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else {
        return event
      }
      self.cancelPendingRename()
      if event.clickCount == 2 {
        DispatchQueue.main.async { [weak self] in
          self?.open()
        }
      } else if event.clickCount == 1, self.isSelectedRow(at: event.locationInWindow) {
        let workItem = DispatchWorkItem { [weak self] in
          self?.rename()
        }
        self.pendingRename = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
      }
      return event
    }
  }

  private func isSelectedRow(at location: NSPoint) -> Bool {
    guard let contentView = window?.contentView,
      let hitView = contentView.hitTest(contentView.convert(location, from: nil)),
      let tableView = enclosingTableView(for: hitView)
    else {
      return false
    }
    let row = tableView.row(at: tableView.convert(location, from: nil))
    return row >= 0
      && tableView.selectedRowIndexes.count == 1
      && tableView.selectedRowIndexes.contains(row)
  }

  private func enclosingTableView(for view: NSView) -> NSTableView? {
    var currentView: NSView? = view
    while let view = currentView {
      if let tableView = view as? NSTableView {
        return tableView
      }
      currentView = view.superview
    }
    return nil
  }

  private func cancelPendingRename() {
    pendingRename?.cancel()
    pendingRename = nil
  }

  private func removeEventMonitor() {
    cancelPendingRename()
    if let eventMonitor {
      NSEvent.removeMonitor(eventMonitor)
      self.eventMonitor = nil
    }
  }
}

/// ローカルイベントモニターはアプリ全体へ届くため、所有ウインドウを照合する。
@MainActor
enum WindowEventRouting {
  static func belongsToWindow(_ eventWindow: NSWindow?, owner: NSWindow?) -> Bool {
    guard let eventWindow, let owner else { return false }
    return eventWindow === owner
  }
}
