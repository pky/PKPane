import Foundation
import Testing

@testable import PKPane

struct FileTreePerformanceTests {
  @Test("1万件の同一リスト行投影を表示世代内で再計算しない")
  @MainActor
  func reusesTenThousandRowProjectionWithinDisplayGeneration() async {
    let provider = LargeTreeRowsPerformanceProvider(itemCount: 10_000)
    let session = FileBrowserSession(
      provider: provider, initialLocation: provider.root, transferQueue: .isolatedForTesting())
    session.load()
    await waitUntil(timeout: .seconds(10), "1万件一覧の読込が期限内に完了しなかった") {
      session.items.count == 10_000 && !session.isLoading
    }
    let clock = ContinuousClock()
    var firstRows: [FileTreeRow] = []
    let firstDuration = clock.measure {
      firstRows = session.flattenedRows(
        matching: "", sortOrder: .name, ascending: true, includesHiddenItems: true)
    }
    var secondRows: [FileTreeRow] = []
    let secondDuration = clock.measure {
      secondRows = session.flattenedRows(
        matching: "", sortOrder: .name, ascending: true, includesHiddenItems: true)
    }

    print(
      "PKPane性能計測: リスト1万件行投影 初回\(Self.milliseconds(firstDuration))ms、"
        + "同条件2回目\(Self.milliseconds(secondDuration))ms")
    #expect(firstRows.count == 10_000)
    #expect(secondRows == firstRows)
    #expect(session.flattenedRowsComputationCount == 1)
    #expect(secondDuration < .milliseconds(2))
  }

  @Test("1000件×3階層のフラット化を短時間で完了する")
  func flattensThreeLevelsQuickly() {
    let fixture = Self.makeFixture(itemsPerLevel: 1_000)
    var treeState = FileTreeState()
    let rootGeneration = treeState.expand(fixture.rootFolder.location)!
    treeState.setChildren(
      fixture.levelOneItems, for: fixture.rootFolder.location, generation: rootGeneration)
    let childGeneration = treeState.expand(fixture.childFolder.location)!
    treeState.setChildren(
      fixture.levelTwoItems, for: fixture.childFolder.location, generation: childGeneration)

    let clock = ContinuousClock()
    var rows: [FileTreeRow] = []
    let duration = clock.measure {
      rows = FileTreeFlattening.flatten(
        rootItems: fixture.rootItems,
        treeState: treeState,
        sortOrder: .name,
        ascending: true)
    }

    #expect(rows.count == 3_000)
    #expect(rows.filter { $0.depth == 0 }.count == 1_000)
    #expect(rows.filter { $0.depth == 1 }.count == 1_000)
    #expect(rows.filter { $0.depth == 2 }.count == 1_000)
    #expect(duration < .milliseconds(100))
    print(
      "PKPane性能計測: ツリー1000件×3階層フラット化 "
        + "\(Self.milliseconds(duration))ms")
  }

  private struct Fixture {
    let rootItems: [FileItem]
    let rootFolder: FileItem
    let levelOneItems: [FileItem]
    let childFolder: FileItem
    let levelTwoItems: [FileItem]
  }

  private static func makeFixture(itemsPerLevel: Int) -> Fixture {
    let providerID = FileProviderID(rawValue: "tree-performance")
    let rootFolder = item(
      path: "/level-0/0000-folder", providerID: providerID, isDirectory: true)
    let childFolder = item(
      path: "/level-0/0000-folder/0000-folder", providerID: providerID,
      isDirectory: true)
    var rootItems = [rootFolder]
    rootItems.append(
      contentsOf: (1..<itemsPerLevel).map {
        item(path: "/level-0/\(padded($0))-item", providerID: providerID)
      })
    var levelOneItems = [childFolder]
    levelOneItems.append(
      contentsOf: (1..<itemsPerLevel).map {
        item(
          path: "/level-0/0000-folder/\(padded($0))-item", providerID: providerID)
      })
    let levelTwoItems = (0..<itemsPerLevel).map {
      item(
        path: "/level-0/0000-folder/0000-folder/\(padded($0))-item",
        providerID: providerID)
    }
    return Fixture(
      rootItems: rootItems,
      rootFolder: rootFolder,
      levelOneItems: levelOneItems,
      childFolder: childFolder,
      levelTwoItems: levelTwoItems)
  }

  private static func item(
    path: String, providerID: FileProviderID, isDirectory: Bool = false
  ) -> FileItem {
    let url = URL(string: "sftp://performance.invalid\(path)")!
    return FileItem(
      remotePath: path,
      url: url,
      providerID: providerID,
      isDirectory: isDirectory)
  }

  private static func padded(_ value: Int) -> String {
    String(format: "%04d", value)
  }

  private static func milliseconds(_ duration: Duration) -> String {
    let components = duration.components
    let seconds = Double(components.seconds) * 1_000
    let attoseconds = Double(components.attoseconds) / 1_000_000_000_000_000
    return String(format: "%.2f", seconds + attoseconds)
  }
}

private struct LargeTreeRowsPerformanceProvider: FileBrowserProvider {
  let id = FileProviderID(rawValue: "tree-performance-large-list")
  let connectionID: FileProviderConnectionID? = nil
  let capabilities: FileProviderCapabilities = [.read]
  let items: [FileItem]
  var root: FileLocation { FileLocation(remotePath: "/root", providerID: id) }

  init(itemCount: Int) {
    let providerID = FileProviderID(rawValue: "tree-performance-large-list")
    items = (0..<itemCount).map { index in
      let path = "/root/item-\(index).txt"
      return FileItem(
        remotePath: path,
        url: URL(string: "tree-performance-large-list://host\(path)")!,
        providerID: providerID,
        isDirectory: false,
        size: 1,
        modifiedAt: Date(timeIntervalSince1970: 1),
        tags: [])
    }
  }

  func contents(of _: FileLocation) async throws -> [FileItem] { items }

  func parent(of _: FileLocation) -> FileLocation? { nil }

  func breadcrumbs(
    for _: FileLocation,
    constrainedTo _: FileLocation?
  ) -> [FileBrowserBreadcrumb] { [] }
}
