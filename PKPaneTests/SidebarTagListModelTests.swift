import AppKit
import Foundation
import Testing

@testable import PKPane

@MainActor
struct SidebarTagListModelTests {
  private let labels = ["なし", "グレイ", "グリーン", "パープル", "ブルー", "イエロー", "レッド", "オレンジ"]

  @Test("開始時にFinder標準タグを色付きで列挙する")
  func startLoadsFinderLabelsWithColors() {
    let model = makeModel()

    model.start()

    #expect(model.tags.map(\.name) == Array(labels.dropFirst()))
    #expect(model.tags.map(\.color) == [.gray, .green, .purple, .blue, .yellow, .red, .orange])
  }

  @Test("読み込み済み項目の独自タグを標準タグへ重複なく追加する")
  func assignedTagsAreMergedWithoutDuplicates() {
    let model = makeModel()
    model.start()

    model.updateAssignedTagNames(["レッド\n6", "仕事\n4", "仕事"])

    #expect(model.tags.map(\.name) == Array(labels.dropFirst()) + ["仕事"])
    #expect(model.tags.last?.color == .blue)
  }

  @Test("Finderラベル変更通知で一覧を更新する")
  func fileLabelNotificationReloadsTags() {
    let notificationCenter = NotificationCenter()
    let source = LabelSource(labels: labels)
    let model = SidebarTagListModel(
      notificationCenter: notificationCenter,
      systemLabelNamesProvider: { source.labels })
    model.start()
    source.labels = ["なし", "灰色"]

    notificationCenter.post(name: NSWorkspace.didChangeFileLabelsNotification, object: nil)

    #expect(model.tags == [FinderTag(name: "灰色", color: .gray)])
  }

  @Test("停止後はFinderラベル変更通知に反応しない")
  func stopRemovesNotificationObserver() {
    let notificationCenter = NotificationCenter()
    let source = LabelSource(labels: labels)
    let model = SidebarTagListModel(
      notificationCenter: notificationCenter,
      systemLabelNamesProvider: { source.labels })
    model.start()
    model.stop()
    source.labels = ["なし", "灰色"]

    notificationCenter.post(name: NSWorkspace.didChangeFileLabelsNotification, object: nil)

    #expect(model.tags.map(\.name) == Array(labels.dropFirst()))
  }

  @Test("タグが空ならセクションを隠す")
  func emptyTagsHideSection() {
    #expect(!SidebarTagSectionPresentation.isVisible(tags: []))
    #expect(
      SidebarTagSectionPresentation.isVisible(
        tags: [FinderTag(name: "仕事", color: .blue)]))
  }

  @Test("タグ行は検索対象が分かるアクセシビリティ名を持つ")
  func tagRowHasSearchAccessibilityLabel() {
    #expect(
      SidebarTagSectionPresentation.accessibilityLabel(for: "仕事")
        == "仕事タグを検索")
  }

  @Test("タグクリックはローカルの既存tag検索経路を呼ぶ")
  func tagClickUsesExistingSearchPathForLocalBrowser() {
    let provider = LocalFileProvider()
    let session = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(
        localURL: URL(filePath: "/tmp"), providerID: provider.id),
      transferQueue: .isolatedForTesting(),
      searchDebounceDuration: .seconds(60))

    let didSearch = SidebarTagSearchAction.perform(
      tag: FinderTag(name: "仕事", color: .blue),
      browser: session)

    #expect(didSearch)
    #expect(session.searchText == "tag:仕事")
  }

  @Test("Finderタグ能力がない接続ではタグクリックを無効にする")
  func tagClickIsDisabledWithoutFinderTagCapability() {
    let provider = NoTagProvider()
    let session = FileBrowserSession(
      provider: provider, initialLocation: provider.root, transferQueue: .isolatedForTesting())

    let didSearch = SidebarTagSearchAction.perform(
      tag: FinderTag(name: "仕事", color: .blue),
      browser: session)

    #expect(!didSearch)
    #expect(session.searchText.isEmpty)
  }

  private func makeModel() -> SidebarTagListModel {
    SidebarTagListModel(
      notificationCenter: NotificationCenter(),
      systemLabelNamesProvider: { labels })
  }
}

@MainActor
private final class LabelSource {
  var labels: [String]

  init(labels: [String]) {
    self.labels = labels
  }
}

private final class NoTagProvider: FileBrowserProvider, @unchecked Sendable {
  let id = FileProviderID(rawValue: "sidebar-no-tag")
  let connectionID: FileProviderConnectionID? = nil
  let capabilities: FileProviderCapabilities = [.read]
  var root: FileLocation { FileLocation(remotePath: "/", providerID: id) }

  func contents(of _: FileLocation) async throws -> [FileItem] { [] }
  func parent(of _: FileLocation) -> FileLocation? { nil }
  func breadcrumbs(
    for _: FileLocation,
    constrainedTo _: FileLocation?
  ) -> [FileBrowserBreadcrumb] { [] }
}
