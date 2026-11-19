import AppKit
import SwiftUI

/// リネームダイアログ専用のテキストフィールド。フォーカス確立時にAppKitが行う既定の
/// 全選択を、ベース名(拡張子を除く部分)だけの選択へ差し替える。
///
/// 従来はSwiftUIの.alert()がホストするTextFieldに対し、NSTextView.didBeginEditing/
/// didChangeSelection通知を購読して後付けで選択範囲を変更していたが、実機では
/// AppKitの既定の全選択が後勝ちして機能しないことが確認された(task-4-report.md参照)。
/// 本ビューはNSTextFieldのbecomeFirstResponder()自体をオーバーライドし、
/// superが行う全選択が完了した直後に選択範囲を上書きすることで確実に反映させる
/// (「選択範囲を後から変える」ではなく「選択が確定する経路そのものに割り込む」)。
/// XCUITest経由の操作は表示直後の再フォーカスを伴うことがあるため、初回だけでなく
/// becomeFirstResponder()が呼ばれるたびに適用を試みる。ただし内容ベースのガード
/// (stringValueが元の名前のままのときだけ適用)を設け、ユーザーが編集した後に
/// Tab循環やクリックでフィールドへ戻ってきても、編集済みテキストの先頭が
/// 元の名前由来のbaseNameLengthで誤って選択・上書きされないようにする。
struct RenameTextField: NSViewRepresentable {
  @Binding var text: String
  let originalFullName: String
  let baseNameLength: Int
  let onCommit: () -> Void
  let onCancel: () -> Void

  final class BaseNameSelectingTextField: NSTextField {
    var baseNameLength: Int = 0
    /// フィールド生成時点の元の名前。updateNSViewでは更新せず固定する。
    var originalFullName: String = ""

    override func becomeFirstResponder() -> Bool {
      let didBecomeFirstResponder = super.becomeFirstResponder()
      // stringValueが元の名前と一致する間だけ適用する内容ベースのガード。
      // ユーザーが編集済みの場合はbaseNameLengthがもはや無関係なため何もしない。
      guard didBecomeFirstResponder, stringValue == originalFullName,
        let editor = currentEditor()
      else {
        return didBecomeFirstResponder
      }
      let fullLength = (stringValue as NSString).length
      let selectionLength = min(baseNameLength, fullLength)
      editor.selectedRange = NSRange(location: 0, length: selectionLength)
      return didBecomeFirstResponder
    }
  }

  final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: RenameTextField

    init(parent: RenameTextField) {
      self.parent = parent
    }

    func controlTextDidChange(_ obj: Notification) {
      guard let field = obj.object as? NSTextField else { return }
      parent.text = field.stringValue
    }

    /// Return/Escapeはフィールドエディタが真っ先に受け取るため、シート側のボタンの
    /// keyboardShortcutより先にここで確実に処理する。
    func control(
      _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
    ) -> Bool {
      if commandSelector == #selector(NSResponder.insertNewline(_:)) {
        parent.onCommit()
        return true
      }
      if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
        parent.onCancel()
        return true
      }
      return false
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  func makeNSView(context: Context) -> BaseNameSelectingTextField {
    let field = BaseNameSelectingTextField()
    field.baseNameLength = baseNameLength
    field.originalFullName = originalFullName
    field.stringValue = text
    field.delegate = context.coordinator
    field.isBordered = true
    field.bezelStyle = .roundedBezel
    field.setAccessibilityLabel("名前")
    // .alert()ホスト時は表示と同時に自動でフォーカスされていたが、.sheet()では
    // 明示的にファーストレスポンダへ要求しない限りフォーカスされない。
    DispatchQueue.main.async { [weak field] in
      guard let field, let window = field.window else { return }
      window.makeFirstResponder(field)
    }
    return field
  }

  func updateNSView(_ nsView: BaseNameSelectingTextField, context: Context) {
    context.coordinator.parent = self
    if nsView.stringValue != text {
      nsView.stringValue = text
    }
    nsView.baseNameLength = baseNameLength
    // originalFullNameはmakeNSView時点(フィールド生成時)の値のまま固定する。ここで
    // 毎回上書きすると、内容ベースのガード(stringValue == originalFullName)が
    // ユーザーの編集後も常にtrueのまま(=ガードとして機能しなく)なってしまう。
  }
}
