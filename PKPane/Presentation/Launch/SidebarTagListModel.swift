import AppKit
import Observation

/// Finderの標準ラベルと、PKPaneが読み込み済み項目から把握した独自タグを、
/// サイドバー表示用の1つの一覧へまとめる。
@Observable
@MainActor
final class SidebarTagListModel {
  private let notificationCenter: NotificationCenter
  private let systemLabelNamesProvider: () -> [String]
  private var notificationToken: NSObjectProtocol?
  private var assignedTagNames: [String] = []

  private(set) var tags: [FinderTag] = []

  init(
    notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
    systemLabelNamesProvider: @escaping () -> [String] = {
      FinderTagPalette.systemLabelNames
    }
  ) {
    self.notificationCenter = notificationCenter
    self.systemLabelNamesProvider = systemLabelNamesProvider
  }

  func start() {
    guard notificationToken == nil else { return }
    notificationToken = notificationCenter.addObserver(
      forName: NSWorkspace.didChangeFileLabelsNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.reload()
      }
    }
    reload()
  }

  func stop() {
    if let notificationToken {
      notificationCenter.removeObserver(notificationToken)
      self.notificationToken = nil
    }
  }

  func updateAssignedTagNames(_ tagNames: [String]) {
    guard tagNames != assignedTagNames else { return }
    assignedTagNames = tagNames
    reload()
  }

  isolated deinit {
    if let notificationToken {
      notificationCenter.removeObserver(notificationToken)
    }
  }

  private func reload() {
    let labelNames = systemLabelNamesProvider()
    let standardTags = FinderTagPalette.tags(
      from: Array(labelNames.dropFirst()),
      standardLabelNames: labelNames)
    let assignedTags = FinderTagPalette.tags(
      from: assignedTagNames,
      standardLabelNames: labelNames)

    var seenNames = Set(standardTags.map(\.name))
    tags = standardTags + assignedTags.filter { seenNames.insert($0.name).inserted }
  }
}

enum SidebarTagSectionPresentation {
  static let sectionTitle = "タグ"

  static func isVisible(tags: [FinderTag]) -> Bool {
    !tags.isEmpty
  }

  static func accessibilityLabel(for tagName: String) -> String {
    "\(tagName)タグを検索"
  }
}

@MainActor
enum SidebarTagSearchAction {
  @discardableResult
  static func perform(tag: FinderTag, browser: FileBrowserSession?) -> Bool {
    guard let browser, browser.capabilities.contains(.finderTags) else { return false }
    browser.setSearchText("tag:\(tag.name)")
    return true
  }
}
