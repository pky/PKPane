import Foundation

enum FolderPaneID: String, CaseIterable, Codable, Identifiable, Sendable {
  case primary
  case secondary

  var id: Self { self }

  var title: String {
    switch self {
    case .primary: "左ペイン"
    case .secondary: "右ペイン"
    }
  }

  var opposite: FolderPaneID {
    switch self {
    case .primary: .secondary
    case .secondary: .primary
    }
  }
}

struct FolderPaneLayout: Equatable {
  private(set) var showsSecondaryPane = false
  private(set) var activePane: FolderPaneID = .primary
  private(set) var primaryTabID: UUID?
  private(set) var secondaryTabID: UUID?

  var activeTabID: UUID? {
    tabID(for: activePane)
  }

  var visiblePanes: [FolderPaneID] {
    showsSecondaryPane ? FolderPaneID.allCases : [activePane]
  }

  mutating func registerInitialTab(id: UUID) {
    guard activeTabID == nil else { return }
    assignTab(id: id, to: activePane)
  }

  mutating func restore(
    showsSecondaryPane: Bool,
    activePane: FolderPaneID,
    primaryTabID: UUID,
    secondaryTabID: UUID?
  ) {
    self.activePane = activePane
    self.primaryTabID = primaryTabID
    self.secondaryTabID = secondaryTabID
    self.showsSecondaryPane =
      showsSecondaryPane
      && secondaryTabID != nil
      && secondaryTabID != primaryTabID
  }

  mutating func showSecondaryPane(tabID: UUID) {
    guard let activeTabID, activeTabID != tabID else { return }
    showsSecondaryPane = true
    assignTab(id: tabID, to: activePane.opposite)
  }

  mutating func hideSecondaryPane() {
    showsSecondaryPane = false
  }

  mutating func activate(_ pane: FolderPaneID) {
    guard pane == activePane || showsSecondaryPane else { return }
    activePane = pane
  }

  mutating func assignTab(id: UUID, to pane: FolderPaneID) {
    if showsSecondaryPane,
      tabID(for: pane.opposite) == id
    {
      setTabID(tabID(for: pane), for: pane.opposite)
    }
    setTabID(id, for: pane)
  }

  mutating func removeTab(id: UUID, remainingTabIDs: [UUID]) {
    if primaryTabID == id {
      primaryTabID = replacementTabID(
        from: remainingTabIDs,
        excluding: showsSecondaryPane ? secondaryTabID : nil)
    }
    if secondaryTabID == id {
      secondaryTabID = replacementTabID(
        from: remainingTabIDs,
        excluding: showsSecondaryPane ? primaryTabID : nil)
    }
  }

  mutating func reset() {
    showsSecondaryPane = false
    activePane = .primary
    primaryTabID = nil
    secondaryTabID = nil
  }

  func tabID(for pane: FolderPaneID) -> UUID? {
    switch pane {
    case .primary: primaryTabID
    case .secondary: secondaryTabID
    }
  }

  func paneDisplaying(tabID: UUID) -> FolderPaneID? {
    visiblePanes.first { self.tabID(for: $0) == tabID }
  }

  private mutating func setTabID(_ tabID: UUID?, for pane: FolderPaneID) {
    switch pane {
    case .primary:
      primaryTabID = tabID
    case .secondary:
      secondaryTabID = tabID
    }
  }

  private func replacementTabID(
    from remainingTabIDs: [UUID],
    excluding excludedTabID: UUID?
  ) -> UUID? {
    remainingTabIDs.first { $0 != excludedTabID } ?? remainingTabIDs.first
  }
}
