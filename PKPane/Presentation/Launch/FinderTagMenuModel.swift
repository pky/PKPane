import Foundation

struct FinderTagMenuChoice: Identifiable {
  var id: Int { color.rawValue }
  let color: FinderTagColor
  let name: String
  let isSelected: Bool
  let isEnabled: Bool
  let disabledReason: String?
}

enum FinderTagMenuModel {
  static let colorOrder: [FinderTagColor] = [.red, .orange, .yellow, .green, .blue, .purple, .gray]

  @MainActor
  static func paletteItem(
    choices: [FinderTagMenuChoice], select: @escaping (String) -> Void
  ) -> FileContextMenuItem {
    let children = choices.map { choice in
      FileContextMenuItem(
        title: choice.name,
        nsImage: FinderTagPaletteImage.make(color: choice.color, isSelected: choice.isSelected),
        isEnabled: choice.isEnabled, disabledReason: choice.disabledReason,
        isSelected: choice.isSelected
      ) { select(choice.name) }
    }
    return FileContextMenuItem(
      title: String(localized: "タグ"), isEnabled: choices.contains { $0.isEnabled },
      disabledReason: choices.first?.disabledReason, children: children, isPalette: true)
  }

  static func choices(
    for items: [FileItem], standardLabelNames: [String], canEdit: Bool
  ) -> [FinderTagMenuChoice] {
    let commonNames = Set(FinderTagEditing.commonNames(in: items))
    return colorOrder.compactMap { color in
      guard standardLabelNames.indices.contains(color.rawValue) else { return nil }
      let name = standardLabelNames[color.rawValue]
      let enabled = canEdit && !items.isEmpty && !name.isEmpty
      let reason: String? =
        !canEdit
        ? String(localized: "この接続ではFinderタグを変更できません。")
        : items.isEmpty ? String(localized: "項目を選択してください。") : nil
      return FinderTagMenuChoice(
        color: color, name: name, isSelected: commonNames.contains(name),
        isEnabled: enabled, disabledReason: reason)
    }
  }
}
