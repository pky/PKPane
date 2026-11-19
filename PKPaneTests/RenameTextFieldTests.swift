import AppKit
import Testing

@testable import PKPane

@MainActor
struct RenameTextFieldTests {
  @Test("フォーカス確立時、内容が元の名前のままならベース名だけを選択する")
  func appliesBaseNameSelectionWhenTextMatchesOriginal() throws {
    let field = RenameTextField.BaseNameSelectingTextField()
    field.originalFullName = "readme.txt"
    field.baseNameLength = 6
    field.stringValue = "readme.txt"
    let window = makeHostingWindow(for: field)

    #expect(window.makeFirstResponder(field))

    let editor = try #require(field.currentEditor())
    #expect(editor.selectedRange == NSRange(location: 0, length: 6))
  }

  @Test("ユーザーが編集した後にTab循環等で再フォーカスしても選択を上書きしない")
  func doesNotApplyBaseNameSelectionAfterUserEditsText() throws {
    let field = RenameTextField.BaseNameSelectingTextField()
    field.originalFullName = "readme.txt"
    // 元の名前("readme.txt")のベース名長(6)を、無関係な編集後テキストへ誤って
    // 適用すると"vacati"のように編集済みテキストの先頭が誤選択されてしまうことを
    // 確認するため、あえて短いbaseNameLengthのままにしておく。
    field.baseNameLength = 6
    field.stringValue = "vacation-photo.txt"  // ユーザーが編集済み(元の名前とは不一致)
    let window = makeHostingWindow(for: field)

    #expect(window.makeFirstResponder(field))

    let editor = try #require(field.currentEditor())
    // 内容ベースのガードにより何もしないため、becomeFirstResponder標準の全選択のまま。
    let fullLength = (field.stringValue as NSString).length
    #expect(editor.selectedRange == NSRange(location: 0, length: fullLength))
  }

  private func makeHostingWindow(for field: NSView) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView?.addSubview(field)
    return window
  }
}
