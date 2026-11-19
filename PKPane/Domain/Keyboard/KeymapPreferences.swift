import AppKit
import Foundation
import Observation

enum KeyboardCommand: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
  case refresh
  case showOriginal
  case goBack
  case goForward
  case rename
  case open
  case quickLook
  case selectNext
  case selectPrevious
  case selectNextPage
  case selectPreviousPage
  case clearSelection
  case focusSearch
  case endSearch

  var id: Self { self }

  var displayName: String {
    switch self {
    case .showOriginal: String(localized: "オリジナルを表示")
    case .refresh: String(localized: "更新")
    case .goBack: String(localized: "戻る")
    case .goForward: String(localized: "進む")
    case .rename: String(localized: "名前を変更")
    case .open: String(localized: "開く")
    case .quickLook: String(localized: "Quick Look")
    case .selectNext: String(localized: "次の項目を選択")
    case .selectPrevious: String(localized: "前の項目を選択")
    case .selectNextPage: String(localized: "次のページを選択")
    case .selectPreviousPage: String(localized: "前のページを選択")
    case .clearSelection: String(localized: "選択を解除")
    case .focusSearch: String(localized: "検索へ移動")
    case .endSearch: String(localized: "検索を終了")
    }
  }

  var customizedShortcutRequiresListCommands: Bool {
    switch self {
    case .goBack, .goForward, .open, .showOriginal:
      false
    case .refresh, .rename, .quickLook, .selectNext, .selectPrevious, .selectNextPage,
      .selectPreviousPage, .clearSelection, .focusSearch, .endSearch:
      true
    }
  }
}

struct KeymapModifierFlags: OptionSet, Codable, Equatable, Hashable, Sendable {
  let rawValue: UInt8

  static let control = Self(rawValue: 1 << 0)
  static let option = Self(rawValue: 1 << 1)
  static let command = Self(rawValue: 1 << 2)
  static let shift = Self(rawValue: 1 << 3)

  static let all: Self = [.control, .option, .command, .shift]

  init(rawValue: UInt8) {
    self.rawValue = rawValue
  }

  init(_ flags: NSEvent.ModifierFlags) {
    var result: Self = []
    if flags.contains(.control) { result.insert(.control) }
    if flags.contains(.option) { result.insert(.option) }
    if flags.contains(.command) { result.insert(.command) }
    if flags.contains(.shift) { result.insert(.shift) }
    self = result
  }

  var eventModifierFlags: NSEvent.ModifierFlags {
    var result: NSEvent.ModifierFlags = []
    if contains(.control) { result.insert(.control) }
    if contains(.option) { result.insert(.option) }
    if contains(.command) { result.insert(.command) }
    if contains(.shift) { result.insert(.shift) }
    return result
  }

  var isValid: Bool {
    subtracting(.all).isEmpty
  }

  var displayText: String {
    var result = ""
    if contains(.control) { result += "⌃" }
    if contains(.option) { result += "⌥" }
    if contains(.shift) { result += "⇧" }
    if contains(.command) { result += "⌘" }
    return result
  }
}

struct KeymapShortcut: Codable, Equatable, Hashable, Sendable {
  let key: String
  let modifiers: KeymapModifierFlags

  init(key: String, modifiers: KeymapModifierFlags) {
    self.key = key.lowercased()
    self.modifiers = modifiers
  }

  init(characters: String, modifiers: NSEvent.ModifierFlags) {
    self.init(key: characters, modifiers: KeymapModifierFlags(modifiers))
  }

  var isValid: Bool {
    !key.isEmpty && modifiers.isValid
  }

  var displayText: String {
    modifiers.displayText + keyDisplayText
  }

  private var keyDisplayText: String {
    switch key {
    case "\r": String(localized: "Return")
    case " ": String(localized: "Space")
    case "\u{1B}": String(localized: "Esc")
    case String(UnicodeScalar(NSDownArrowFunctionKey)!): "↓"
    case String(UnicodeScalar(NSUpArrowFunctionKey)!): "↑"
    case String(UnicodeScalar(NSLeftArrowFunctionKey)!): "←"
    case String(UnicodeScalar(NSRightArrowFunctionKey)!): "→"
    case String(UnicodeScalar(NSDeleteFunctionKey)!): "⌫"
    case "\u{7F}": "⌫"
    default: key.uppercased()
    }
  }
}

struct KeyboardCommandBinding: Codable, Equatable, Hashable, Sendable {
  let shortcut: KeymapShortcut
  let requiresListCommands: Bool
}

struct KeyboardCommandMap: Codable, Equatable, Sendable {
  private struct PersistedAssignment: Codable {
    let command: String
    let bindings: [KeyboardCommandBinding]

    private enum CodingKeys: CodingKey {
      case command
      case bindings
    }

    init(command: String, bindings: [KeyboardCommandBinding]) {
      self.command = command
      self.bindings = bindings
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      command = try container.decode(String.self, forKey: .command)
      // 未知コマンドは将来版で割り当て表現が変わっていても無視できるよう、
      // bindingsのデコード失敗を一旦空として保持する。既知コマンドなら下で不正値になる。
      bindings = (try? container.decode([KeyboardCommandBinding].self, forKey: .bindings)) ?? []
    }
  }

  private var assignments: [KeyboardCommand: [KeyboardCommandBinding]]

  static let defaults = Self(
    assignments: [
      .showOriginal: [binding("r", [.command], requiresListCommands: false)],
      .refresh: [binding("r", [.control])],
      .goBack: [binding("[", [.command], requiresListCommands: false)],
      .goForward: [binding("]", [.command], requiresListCommands: false)],
      .rename: [binding("\r", [])],
      .open: [
        binding("o", [.command], requiresListCommands: false),
        binding(
          String(UnicodeScalar(NSDownArrowFunctionKey)!), [.command],
          requiresListCommands: true),
      ],
      .quickLook: [binding(" ", [])],
      .selectNext: [binding("n", [.control])],
      .selectPrevious: [binding("p", [.control])],
      .selectNextPage: [binding("v", [.control])],
      .selectPreviousPage: [binding("v", [.control, .option])],
      .clearSelection: [binding("\u{1B}", [])],
      .focusSearch: [binding("s", [.control])],
      .endSearch: [binding("g", [.control])],
    ])

  init(assignments: [KeyboardCommand: [KeyboardCommandBinding]]) {
    self.assignments = assignments
  }

  func bindings(for command: KeyboardCommand) -> [KeyboardCommandBinding] {
    assignments[command] ?? Self.defaults.assignments[command] ?? []
  }

  func command(
    for shortcut: KeymapShortcut,
    handlesListCommands: Bool
  ) -> KeyboardCommand? {
    KeyboardCommand.allCases.first { command in
      bindings(for: command).contains { binding in
        binding.shortcut == shortcut
          && (handlesListCommands || !binding.requiresListCommands)
      }
    }
  }

  func replacingBindings(
    for command: KeyboardCommand,
    with shortcut: KeymapShortcut
  ) -> Self {
    var updated = assignments
    updated[command] = [
      KeyboardCommandBinding(
        shortcut: shortcut,
        requiresListCommands: command.customizedShortcutRequiresListCommands)
    ]
    return Self(assignments: updated)
  }

  func restoringDefault(for command: KeyboardCommand) -> Self {
    var updated = assignments
    updated[command] = Self.defaults.bindings(for: command)
    return Self(assignments: updated)
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let persisted = try container.decode([PersistedAssignment].self)
    var decoded = Self.defaults.assignments
    // 既存の⌘Rカスタム割当を新コマンドの既定値で奪わない。
    if !persisted.contains(where: { $0.command == KeyboardCommand.showOriginal.rawValue }),
      persisted.contains(where: { assignment in
        assignment.bindings.contains {
          $0.shortcut == KeymapShortcut(key: "r", modifiers: [.command])
        }
      })
    {
      decoded[.showOriginal] = []
    }
    for assignment in persisted {
      guard let command = KeyboardCommand(rawValue: assignment.command) else { continue }
      guard !assignment.bindings.isEmpty || command == .showOriginal,
        assignment.bindings.allSatisfy({ $0.shortcut.isValid }),
        Set(assignment.bindings).count == assignment.bindings.count
      else {
        throw DecodingError.dataCorruptedError(
          in: container,
          debugDescription: "不正なキー割り当てです")
      }
      decoded[command] = assignment.bindings
    }
    let result = Self(assignments: decoded)
    guard KeyboardShortcutConflictDetector.duplicates(in: result).isEmpty else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "重複するキー割り当てです")
    }
    self = result
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(
      KeyboardCommand.allCases.map { command in
        PersistedAssignment(command: command.rawValue, bindings: bindings(for: command))
      })
  }

  private static func binding(
    _ key: String,
    _ modifiers: KeymapModifierFlags,
    requiresListCommands: Bool = true
  ) -> KeyboardCommandBinding {
    KeyboardCommandBinding(
      shortcut: KeymapShortcut(key: key, modifiers: modifiers),
      requiresListCommands: requiresListCommands)
  }
}

struct KeyboardShortcutConflict: Equatable, Hashable, Sendable {
  let shortcut: KeymapShortcut
  let commands: [KeyboardCommand]
}

enum KeyboardShortcutConflictDetector {
  static func duplicates(in keymap: KeyboardCommandMap) -> [KeyboardShortcutConflict] {
    var commandsByShortcut: [KeymapShortcut: Set<KeyboardCommand>] = [:]
    for command in KeyboardCommand.allCases {
      for binding in keymap.bindings(for: command) {
        commandsByShortcut[binding.shortcut, default: []].insert(command)
      }
    }
    return commandsByShortcut.compactMap { shortcut, commands in
      guard commands.count > 1 else { return nil }
      return KeyboardShortcutConflict(
        shortcut: shortcut,
        commands: commands.sorted { $0.rawValue < $1.rawValue })
    }
    .sorted { $0.shortcut.displayText < $1.shortcut.displayText }
  }

  static func menuConflicts(
    in keymap: KeyboardCommandMap,
    menuShortcuts: Set<KeymapShortcut>
  ) -> [KeyboardShortcutConflict] {
    KeyboardCommand.allCases.compactMap { command in
      let conflicts = keymap.bindings(for: command).filter {
        menuShortcuts.contains($0.shortcut)
      }
      return conflicts.first.map {
        KeyboardShortcutConflict(shortcut: $0.shortcut, commands: [command])
      }
    }
  }
}

enum KeymapPreferencesSaveResult: Equatable {
  case saved
  case duplicate([KeyboardShortcutConflict])
  case encodingFailed
}

/// 一覧操作のキー割り当てをUserDefaultsの1キーへ保存する。
@Observable
@MainActor
final class KeymapPreferencesStore {
  static let shared = KeymapPreferencesStore()

  private(set) var current: KeyboardCommandMap
  private let defaults: UserDefaults
  private let key = "keymap-preferences"

  init(defaults: UserDefaults? = nil) {
    self.defaults = defaults ?? Self.defaultUserDefaults
    current = Self.decode(from: self.defaults, key: key)
  }

  @discardableResult
  func save(_ keymap: KeyboardCommandMap) -> KeymapPreferencesSaveResult {
    let duplicates = KeyboardShortcutConflictDetector.duplicates(in: keymap)
    guard duplicates.isEmpty else { return .duplicate(duplicates) }
    guard let data = try? JSONEncoder().encode(keymap) else { return .encodingFailed }
    current = keymap
    defaults.set(data, forKey: key)
    return .saved
  }

  func remove() {
    defaults.removeObject(forKey: key)
    current = .defaults
  }

  private static func decode(from defaults: UserDefaults, key: String) -> KeyboardCommandMap {
    guard let data = defaults.data(forKey: key),
      let keymap = try? JSONDecoder().decode(KeyboardCommandMap.self, from: data)
    else {
      return .defaults
    }
    return keymap
  }

  private static var defaultUserDefaults: UserDefaults {
    PKPaneUserDefaults.resolve()
  }
}
