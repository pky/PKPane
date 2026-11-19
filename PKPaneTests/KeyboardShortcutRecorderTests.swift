import AppKit
import Foundation
import Testing

@testable import PKPane

@MainActor
struct KeyboardShortcutRecorderTests {
  @Test("修飾なしEscは実録音経路をキャンセルして割り当てを変更しない")
  func escapeCancelsRecordingWithoutChangingAssignment() throws {
    let suiteName = "KeyboardShortcutRecorderTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = KeymapPreferencesStore(defaults: defaults)
    let model = PKPaneSettingsModel(
      appearanceStore: AppearancePreferencesStore(defaults: defaults),
      applyAppearance: { _ in },
      keymapStore: store,
      menuShortcutInventory: [])
    let keyboardTab = KeyboardSettingsView(model: model)
    let recorder = KeyboardShortcutRecorderView()
    var recordingEndedCount = 0
    recorder.onRecord = { shortcut in
      _ = keyboardTab.record(shortcut, for: .refresh)
    }
    recorder.onRecordingEnded = { recordingEndedCount += 1 }
    recorder.startRecordingIfNeeded()

    let returnedEvent = recorder.handleKeyDown(try escapeEvent())

    #expect(returnedEvent == nil)
    #expect(recordingEndedCount == 1)
    #expect(store.current == .defaults)
    #expect(!KeyboardShortcutRecordingState.isRecording)
  }

  private func escapeEvent() throws -> NSEvent {
    try #require(
      NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: "\u{1B}",
        charactersIgnoringModifiers: "\u{1B}",
        isARepeat: false,
        keyCode: 53))
  }
}
