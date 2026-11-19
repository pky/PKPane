import AppKit
import Foundation
import Testing

@testable import PKPane

@MainActor
struct KeymapPreferencesStoreTests {
  @Test("既定キーマップは現行の全割り当てと適用文脈に一致する")
  func defaultKeymapParity() {
    let downArrow = String(UnicodeScalar(NSDownArrowFunctionKey)!)
    let expected: [KeyboardCommand: [KeyboardCommandBinding]] = [
      .refresh: [binding("r", [.control])],
      .showOriginal: [binding("r", [.command], requiresListCommands: false)],
      .goBack: [binding("[", [.command], requiresListCommands: false)],
      .goForward: [binding("]", [.command], requiresListCommands: false)],
      .rename: [binding("\r", [])],
      .open: [
        binding("o", [.command], requiresListCommands: false),
        binding(downArrow, [.command]),
      ],
      .quickLook: [binding(" ", [])],
      .selectNext: [binding("n", [.control])],
      .selectPrevious: [binding("p", [.control])],
      .selectNextPage: [binding("v", [.control])],
      .selectPreviousPage: [binding("v", [.control, .option])],
      .clearSelection: [binding("\u{1B}", [])],
      .focusSearch: [binding("s", [.control])],
      .endSearch: [binding("g", [.control])],
    ]

    #expect(Set(expected.keys) == Set(KeyboardCommand.allCases))
    for command in KeyboardCommand.allCases {
      #expect(KeyboardCommandMap.defaults.bindings(for: command) == expected[command])
    }
  }

  @Test("重複割り当ては保存を拒否して現在値を維持する")
  func rejectsDuplicateAssignments() {
    let (defaults, suiteName) = isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = KeymapPreferencesStore(defaults: defaults)
    let duplicate = KeymapShortcut(key: "r", modifiers: [.control])
    let invalid = store.current.replacingBindings(for: .open, with: duplicate)

    let result = store.save(invalid)

    guard case .duplicate(let conflicts) = result else {
      Issue.record("重複割り当てが拒否されませんでした")
      return
    }
    #expect(conflicts.map(\.commands) == [[.open, .refresh]])
    #expect(store.current == .defaults)
  }

  @Test("メニュー目録との衝突を純関数で警告判定する")
  func detectsMenuConflicts() {
    let shortcut = KeymapShortcut(key: "q", modifiers: [.command])
    let keymap = KeyboardCommandMap.defaults.replacingBindings(for: .refresh, with: shortcut)

    let conflicts = KeyboardShortcutConflictDetector.menuConflicts(
      in: keymap,
      menuShortcuts: [shortcut])

    #expect(conflicts == [KeyboardShortcutConflict(shortcut: shortcut, commands: [.refresh])])
  }

  @Test("ストアはカスタム割り当てを1キーで往復する")
  func roundTripsCustomKeymap() {
    let (defaults, suiteName) = isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let shortcut = KeymapShortcut(key: "u", modifiers: [.control, .option])
    let customized = KeyboardCommandMap.defaults.replacingBindings(
      for: .refresh,
      with: shortcut)
    let store = KeymapPreferencesStore(defaults: defaults)

    #expect(store.save(customized) == .saved)

    let reloaded = KeymapPreferencesStore(defaults: defaults)
    #expect(reloaded.current == customized)
    #expect(defaults.dictionaryRepresentation().keys.contains("keymap-preferences"))
  }

  @Test("不正値は全既定へ戻し未知コマンドは無視する")
  func fallsBackFromInvalidValuesAndIgnoresUnknownCommands() throws {
    let (defaults, suiteName) = isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let invalidJSON = Data(
      #"[{"command":"refresh","bindings":[]}]"#.utf8)
    defaults.set(invalidJSON, forKey: "keymap-preferences")
    #expect(KeymapPreferencesStore(defaults: defaults).current == .defaults)

    let defaultData = try JSONEncoder().encode(KeyboardCommandMap.defaults)
    var object = try #require(
      JSONSerialization.jsonObject(with: defaultData) as? [[String: Any]])
    let unknownAssignment: [String: Any] = [
      "command": "futureCommand",
      "futureBindings": [],
    ]
    object.append(unknownAssignment)
    defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: "keymap-preferences")

    #expect(KeymapPreferencesStore(defaults: defaults).current == .defaults)
  }

  private func binding(
    _ key: String,
    _ modifiers: KeymapModifierFlags,
    requiresListCommands: Bool = true
  ) -> KeyboardCommandBinding {
    KeyboardCommandBinding(
      shortcut: KeymapShortcut(key: key, modifiers: modifiers),
      requiresListCommands: requiresListCommands)
  }

  private func isolatedDefaults() -> (UserDefaults, String) {
    let suiteName = "KeymapPreferencesStoreTests-\(UUID().uuidString)"
    return (UserDefaults(suiteName: suiteName)!, suiteName)
  }
}
