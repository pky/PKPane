import Foundation
import Observation

/// サイドバー各セクションの開閉状態を端末内へ永続化する。
@Observable
@MainActor
final class SidebarSectionExpansionModel {
  enum SectionID: String, CaseIterable, Sendable {
    case favorites
    case locations
    case recents
    case connections
    case tags
  }

  private let defaults: UserDefaults
  private let key = "sidebar-collapsed-sections"
  private(set) var collapsedSections: Set<SectionID>

  init(defaults: UserDefaults? = nil) {
    let defaults = defaults ?? PKPaneUserDefaults.resolve()
    self.defaults = defaults
    collapsedSections = Set(
      (defaults.stringArray(forKey: key) ?? []).compactMap(SectionID.init(rawValue:)))
  }

  func isExpanded(_ section: SectionID) -> Bool {
    !collapsedSections.contains(section)
  }

  func setExpanded(_ expanded: Bool, for section: SectionID) {
    if expanded {
      collapsedSections.remove(section)
    } else {
      collapsedSections.insert(section)
    }
    if collapsedSections.isEmpty {
      defaults.removeObject(forKey: key)
    } else {
      defaults.set(collapsedSections.map(\.rawValue).sorted(), forKey: key)
    }
  }
}
