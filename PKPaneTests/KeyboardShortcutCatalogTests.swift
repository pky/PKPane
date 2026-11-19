import AppKit
import Testing

@testable import PKPane

@MainActor
struct KeyboardShortcutCatalogTests {
  @Test("AppMenuItemの全項目をショートカット一覧へ載せる")
  func includesEveryAppMenuItem() {
    let entries = KeyboardShortcutCatalog.make(
      context: .unavailable,
      keymap: .defaults)
    let identifiers = Set(entries.map(\.id))

    #expect(AppMenuItem.allCases.allSatisfy { identifiers.contains($0.rawValue) })
    #expect(entries.map(\.category).contains(.fileOperations))
    #expect(entries.map(\.category).contains(.pane))
    #expect(entries.map(\.category).contains(.other))
  }

  @Test("カスタマイズ後の一覧操作キーを固定メニューキーと合わせて表示する")
  func reflectsCustomizedKeymap() throws {
    let customized = KeyboardCommandMap.defaults.replacingBindings(
      for: .open,
      with: KeymapShortcut(key: "u", modifiers: [.command, .option]))
    let entries = KeyboardShortcutCatalog.make(
      context: .unavailable,
      keymap: customized)
    let open = try #require(entries.first { $0.id == AppMenuItem.openSelectedItem.rawValue })

    #expect(open.shortcuts.contains(KeymapShortcut(key: "o", modifiers: [.command])))
    #expect(open.shortcuts.contains(KeymapShortcut(key: "u", modifiers: [.command, .option])))
    #expect(
      !open.shortcuts.contains(
        KeymapShortcut(
          key: String(UnicodeScalar(NSDownArrowFunctionKey)!),
          modifiers: [.command])))
  }

  @Test("タイトルと実効ショートカットの部分一致で絞り込む")
  func filtersByTitleAndShortcut() {
    let entries = KeyboardShortcutCatalog.make(
      context: .unavailable,
      keymap: .defaults)

    #expect(
      KeyboardShortcutCatalog.filtered(entries, query: "Quick Look").map(\.title)
        == ["Quick Look"])
    #expect(
      KeyboardShortcutCatalog.filtered(entries, query: "⌘⇧O").map(\.title)
        == ["クイックオープン…"])
  }

  @Test("ショートカット一覧表示は登録中の画面だけへ委譲する")
  func presentationBridgeFollowsRegistration() {
    let model = AppMenuModel()
    var presentationCount = 0

    model.showKeyboardShortcuts()
    model.registerKeyboardShortcuts { presentationCount += 1 }
    #expect(model.canShowKeyboardShortcuts)
    model.showKeyboardShortcuts()
    model.unregisterKeyboardShortcuts()
    model.showKeyboardShortcuts()

    #expect(presentationCount == 1)
    #expect(!model.canShowKeyboardShortcuts)
  }
}
