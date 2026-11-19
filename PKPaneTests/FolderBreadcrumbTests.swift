import Foundation
import Testing

@testable import PKPane

struct FolderBreadcrumbTests {
  @Test("起点から現在地までのパンくずを作成する")
  func createsBreadcrumbsWithinRoot() {
    let root = URL(fileURLWithPath: "/Users/tester/Documents")
    let current = root.appending(path: "Projects/PKPane", directoryHint: .isDirectory)

    let breadcrumbs = FolderBreadcrumb.make(root: root, current: current)

    #expect(breadcrumbs.map(\.name) == ["Documents", "Projects", "PKPane"])
    #expect(
      breadcrumbs.map(\.url) == [
        root,
        root.appending(path: "Projects", directoryHint: .isDirectory),
        current,
      ])
  }

  @Test("起点外の場所にはパンくずを作成しない")
  func rejectsLocationOutsideRoot() {
    let root = URL(fileURLWithPath: "/Users/tester/Documents")
    let outside = URL(fileURLWithPath: "/Users/tester/Downloads")

    #expect(FolderBreadcrumb.make(root: root, current: outside).isEmpty)
  }
}
