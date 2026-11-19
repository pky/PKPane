import AppKit
import SwiftUI

@MainActor
enum KeyboardShortcutRecordingState {
  static var isRecording = false
}

struct KeyboardShortcutRecorder: NSViewRepresentable {
  @Binding var isRecording: Bool
  let onRecord: (KeymapShortcut) -> Void

  func makeNSView(context: Context) -> KeyboardShortcutRecorderView {
    KeyboardShortcutRecorderView()
  }

  func updateNSView(_ view: KeyboardShortcutRecorderView, context: Context) {
    view.onRecord = onRecord
    view.onRecordingEnded = { isRecording = false }
    if isRecording {
      view.startRecordingIfNeeded()
    } else {
      view.stopRecording()
    }
  }

  static func dismantleNSView(_ view: KeyboardShortcutRecorderView, coordinator: ()) {
    view.stopRecording()
  }
}

@MainActor
final class KeyboardShortcutRecorderView: NSView {
  var onRecord: (KeymapShortcut) -> Void = { _ in }
  var onRecordingEnded: () -> Void = {}
  private var eventMonitor: Any?

  func startRecordingIfNeeded() {
    guard eventMonitor == nil else { return }
    KeyboardShortcutRecordingState.isRecording = true
    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self else { return event }
      return self.handleKeyDown(event)
    }
  }

  /// ローカルイベントモニターが使う実処理。修飾なしEscは割り当てず録音だけを終了する。
  func handleKeyDown(_ event: NSEvent) -> NSEvent? {
    guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else {
      return event
    }
    let modifiers = KeymapModifierFlags(event.modifierFlags)
    if characters == "\u{1B}", modifiers.isEmpty {
      stopRecording()
      onRecordingEnded()
      return nil
    }
    let shortcut = KeymapShortcut(key: characters, modifiers: modifiers)
    guard shortcut.isValid else { return event }
    onRecord(shortcut)
    stopRecording()
    onRecordingEnded()
    return nil
  }

  func stopRecording() {
    KeyboardShortcutRecordingState.isRecording = false
    guard let eventMonitor else { return }
    NSEvent.removeMonitor(eventMonitor)
    self.eventMonitor = nil
  }
}
