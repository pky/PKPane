import AppKit
import SwiftUI

/// SwiftUIの詳細表示からNSTokenFieldを使うための薄い橋渡し。
/// Return・カンマ・フォーカス離脱で確定し、標準Finderタグ名を補完候補として返す。
struct FinderTagTokenField: NSViewRepresentable {
  @Binding var tagNames: [String]
  let candidates: [String]
  let isEnabled: Bool

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  func makeNSView(context: Context) -> NSTokenField {
    let tokenField = NSTokenField()
    tokenField.delegate = context.coordinator
    tokenField.target = context.coordinator
    tokenField.action = #selector(Coordinator.commit(_:))
    tokenField.tokenStyle = .rounded
    tokenField.completionDelay = 0
    tokenField.tokenizingCharacterSet = CharacterSet(charactersIn: ",\n")
    tokenField.objectValue = tagNames
    tokenField.setAccessibilityIdentifier("file-info-finder-tags")
    return tokenField
  }

  func updateNSView(_ tokenField: NSTokenField, context: Context) {
    context.coordinator.parent = self
    tokenField.isEnabled = isEnabled
    let displayedNames = context.coordinator.names(from: tokenField)
    if displayedNames != tagNames {
      tokenField.objectValue = tagNames
    }
  }

  @MainActor
  final class Coordinator: NSObject, NSTokenFieldDelegate {
    var parent: FinderTagTokenField

    init(parent: FinderTagTokenField) {
      self.parent = parent
    }

    @objc func commit(_ sender: NSTokenField) {
      let names = names(from: sender)
      guard names != parent.tagNames else { return }
      parent.tagNames = names
    }

    func controlTextDidEndEditing(_ notification: Notification) {
      guard let tokenField = notification.object as? NSTokenField else { return }
      commit(tokenField)
    }

    func tokenField(
      _ tokenField: NSTokenField,
      completionsForSubstring substring: String,
      indexOfToken tokenIndex: Int,
      indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?
    ) -> [Any]? {
      let matches = parent.candidates.filter {
        $0.localizedCaseInsensitiveContains(substring)
      }
      selectedIndex?.pointee = matches.isEmpty ? -1 : 0
      return matches
    }

    func tokenField(
      _ tokenField: NSTokenField,
      shouldAdd tokens: [Any],
      at index: Int
    ) -> [Any] {
      FinderTagEditing.normalizedNames(
        tokens.compactMap { value in
          if let string = value as? String { return string }
          if let string = value as? NSString { return string as String }
          return nil
        })
    }

    func names(from tokenField: NSTokenField) -> [String] {
      let objects = tokenField.objectValue as? [Any] ?? []
      return FinderTagEditing.normalizedNames(
        objects.compactMap { value in
          if let string = value as? String { return string }
          if let string = value as? NSString { return string as String }
          return nil
        })
    }
  }
}
