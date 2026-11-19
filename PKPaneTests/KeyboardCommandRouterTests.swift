import AppKit
import Carbon.HIToolbox
import Testing

@testable import PKPane

@MainActor
struct KeyboardCommandRouterTests {
  @Test("別ウインドウのキー入力とマウス入力を処理しない")
  func filtersEventsByOwningWindow() {
    let first = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
    let second = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
    #expect(WindowEventRouting.belongsToWindow(first, owner: first))
    #expect(!WindowEventRouting.belongsToWindow(second, owner: first))
    #expect(!WindowEventRouting.belongsToWindow(nil, owner: first))
    #expect(!WindowEventRouting.belongsToWindow(first, owner: nil))
  }

  @Test("既定テーブルの全割り当てを現行の適用文脈どおり振り分ける")
  func routesEveryDefaultBindingWithExactContext() {
    for command in KeyboardCommand.allCases {
      for binding in KeyboardCommandMap.defaults.bindings(for: command) {
        #expect(
          KeyboardCommandRouter.command(
            characters: binding.shortcut.key,
            modifiers: binding.shortcut.modifiers.eventModifierFlags,
            handlesListCommands: true) == command)
        #expect(
          KeyboardCommandRouter.command(
            characters: binding.shortcut.key,
            modifiers: binding.shortcut.modifiers.eventModifierFlags,
            handlesListCommands: false)
            == (binding.requiresListCommands ? nil : command))
      }
    }
  }

  @Test("カスタム割り当ては新しいキーだけを即時に振り分ける")
  func routesOnlyCustomizedShortcut() {
    let customized = KeyboardCommandMap.defaults.replacingBindings(
      for: .refresh,
      with: KeymapShortcut(key: "u", modifiers: [.control, .option]))

    #expect(
      KeyboardCommandRouter.command(
        characters: "u",
        modifiers: [.control, .option],
        handlesListCommands: true,
        keymap: customized) == .refresh)
    #expect(
      KeyboardCommandRouter.command(
        characters: "r",
        modifiers: [.control],
        handlesListCommands: true,
        keymap: customized) == nil)
  }

  @Test("イベント実経路も渡された最新テーブルを参照する")
  func eventRouteUsesCurrentKeymap() throws {
    let customized = KeyboardCommandMap.defaults.replacingBindings(
      for: .quickLook,
      with: KeymapShortcut(key: "l", modifiers: [.control]))
    let event = try #require(
      NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [.control],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: "l",
        charactersIgnoringModifiers: "l",
        isARepeat: false,
        keyCode: UInt16(kVK_ANSI_L)))

    #expect(KeyboardCommandRouter.command(for: event, keymap: customized) == .quickLook)
  }

  @Test("既定のCommand Oは実イベントモニターがルーターの開くとして消費する")
  func defaultCommandORemainsOnRouterPath() throws {
    let customizedElsewhere = KeyboardCommandMap.defaults.replacingBindings(
      for: .refresh,
      with: KeymapShortcut(key: "u", modifiers: [.control]))

    #expect(
      KeyboardCommandRouter.monitorDecision(
        for: try keyEvent(characters: "o", modifiers: [.command]),
        keymap: .defaults) == .handle(.open))
    #expect(
      KeyboardCommandRouter.monitorDecision(
        for: try keyEvent(characters: "o", modifiers: [.command]),
        keymap: customizedElsewhere) == .handle(.open))
  }

  @Test("カスタム割り当てがメニューと衝突した場合だけ実イベントモニターがメニューへ譲る")
  func onlyCustomizedMenuConflictDefersToMenu() throws {
    let menuConflict = KeyboardCommandMap.defaults.replacingBindings(
      for: .refresh,
      with: KeymapShortcut(key: "c", modifiers: [.command]))
    let nonConflict = KeyboardCommandMap.defaults.replacingBindings(
      for: .refresh,
      with: KeymapShortcut(key: "u", modifiers: [.control]))

    #expect(
      KeyboardCommandRouter.monitorDecision(
        for: try keyEvent(characters: "c", modifiers: [.command]),
        keymap: menuConflict) == .deferToAppMenu)
    #expect(
      KeyboardCommandRouter.monitorDecision(
        for: try keyEvent(characters: "u", modifiers: [.control]),
        keymap: nonConflict) == .handle(.refresh))
  }

  @Test("一覧用のControlキー操作を振り分ける")
  func routesListCommands() {
    #expect(
      KeyboardCommandRouter.command(
        characters: "n", modifiers: [.control], handlesListCommands: true) == .selectNext)
    #expect(
      KeyboardCommandRouter.command(
        characters: "v", modifiers: [.control, .option], handlesListCommands: true)
        == .selectPreviousPage)
    #expect(
      KeyboardCommandRouter.command(
        characters: "\r", modifiers: [], handlesListCommands: true) == .rename)
    #expect(
      KeyboardCommandRouter.command(
        characters: "[", modifiers: [.command], handlesListCommands: true) == .goBack)
    #expect(
      KeyboardCommandRouter.command(
        characters: "]", modifiers: [.command], handlesListCommands: true) == .goForward)
    #expect(
      KeyboardCommandRouter.command(
        characters: "o", modifiers: [.command], handlesListCommands: true) == .open)
    #expect(
      KeyboardCommandRouter.command(
        characters: "s", modifiers: [.control], handlesListCommands: true) == .focusSearch)
    #expect(
      KeyboardCommandRouter.command(
        characters: "g", modifiers: [.control], handlesListCommands: true) == .endSearch)
    #expect(
      KeyboardCommandRouter.command(
        characters: String(UnicodeScalar(NSDownArrowFunctionKey)!),
        modifiers: [.command],
        handlesListCommands: true) == .open)
  }

  @Test("メニューへ移したCommandキー操作を処理しない")
  func ignoresMenuCommands() {
    for (characters, modifiers) in [
      ("1", NSEvent.ModifierFlags.command),
      ("2", NSEvent.ModifierFlags.command),
      ("n", [.command, .shift]),
      ("g", [.command, .shift]),
      ("i", NSEvent.ModifierFlags.command),
      ("y", NSEvent.ModifierFlags.command),
      (".", [.command, .shift]),
    ] {
      #expect(
        KeyboardCommandRouter.command(
          characters: characters, modifiers: modifiers, handlesListCommands: true) == nil)
    }
  }

  @Test("Finderの⌘Rをオリジナル表示へ振り分ける")
  func routesShowOriginalShortcut() {
    #expect(
      KeyboardCommandRouter.command(
        characters: "r", modifiers: [.command], handlesListCommands: true) == .showOriginal)
  }

  @Test("同期ブラウズのOption Command Yをメニューへ渡す")
  func ignoresSyncBrowsingMenuShortcut() {
    #expect(
      KeyboardCommandRouter.command(
        characters: "y",
        modifiers: [.command, .option],
        handlesListCommands: true) == nil)
  }

  @Test("Quick SelectのOption Command Aをメニューへ渡す")
  func ignoresQuickSelectMenuShortcut() {
    #expect(
      KeyboardCommandRouter.command(
        characters: "a",
        modifiers: [.command, .option],
        handlesListCommands: true) == nil)
  }

  @Test("Quick OpenのShift Command Oをメニューへ渡す")
  func ignoresQuickOpenMenuShortcut() {
    #expect(
      KeyboardCommandRouter.command(
        characters: "o",
        modifiers: [.command, .shift],
        handlesListCommands: true) == nil)
  }

  @Test("テキスト編集時は一覧用キーを処理しない")
  func ignoresListCommandsWhileTextEditing() {
    let textView = NSTextView()
    textView.isEditable = true

    #expect(!KeyboardCommandRouter.handlesListCommands(for: textView))
    #expect(
      KeyboardCommandRouter.command(
        characters: "n", modifiers: [.control],
        handlesListCommands: KeyboardCommandRouter.handlesListCommands(for: textView)) == nil)
  }

  @Test("メニューのCommandキー操作はテキスト編集時に処理しない")
  func ignoresMenuCommandsWhileTextEditing() {
    #expect(
      KeyboardCommandRouter.command(
        characters: ".",
        modifiers: [.command, .shift],
        handlesListCommands: false,
        keyCode: UInt16(kVK_ANSI_Period)) == nil)
  }

  @Test("日本語IME変換中は一覧用キーを処理しない")
  func ignoresListCommandsWhileComposingJapaneseText() {
    let textView = NSTextView()
    textView.isEditable = true
    textView.setMarkedText(
      "にほんご", selectedRange: NSRange(location: 0, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))

    #expect(textView.hasMarkedText())
    #expect(!KeyboardCommandRouter.handlesListCommands(for: textView))
    #expect(
      KeyboardCommandRouter.command(
        characters: "n", modifiers: [.control],
        handlesListCommands: KeyboardCommandRouter.handlesListCommands(for: textView)) == nil)
  }

  private func keyEvent(
    characters: String,
    modifiers: NSEvent.ModifierFlags
  ) throws -> NSEvent {
    try #require(
      NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: 0))
  }
}
