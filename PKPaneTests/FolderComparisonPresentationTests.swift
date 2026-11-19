import Foundation
import Testing

@testable import PKPane

@MainActor
struct FolderComparisonPresentationTests {
  @Test("差分フィルターが情報不足の一致行を隠しても、概要の不足件数を保持する")
  func reportsIncompleteMetadataOutsideFilteredRows() async throws {
    let provider = FolderComparisonRouteProvider(usesCommonIncompleteItem: true)
    let queue = TransferQueue.isolatedForTesting()
    let workspace = FileWorkspaceModel(
      initialBrowser: FileBrowserSession(
        provider: provider, initialLocation: routeLocation("/left"), transferQueue: queue))
    workspace.activatePane(.secondary)
    workspace.replaceActiveBrowser(
      with: FileBrowserSession(
        provider: provider, initialLocation: routeLocation("/right"), transferQueue: queue))
    let presentation = FolderComparisonPresentationState()
    #expect(presentation.handle(.compareFolders, workspace: workspace))
    let model = try #require(presentation.model)
    await waitUntil { !model.isComparing && model.snapshot != nil }
    model.filter = .different
    #expect(model.displayedEntries.isEmpty)
    #expect(model.incompleteMetadataCount == 1)
    #expect(model.snapshot?.entries.first?.status == .identical)
    presentation.dismiss()
  }

  @Test("移動メニュー操作からUIプレゼンテーションを経て比較モデルを起動する")
  func menuActionReachesComparisonModelThroughPresentationState() async throws {
    let transferQueue = TransferQueue.isolatedForTesting()
    let provider = FolderComparisonRouteProvider()
    let workspace = FileWorkspaceModel(
      initialBrowser: FileBrowserSession(
        provider: provider,
        initialLocation: routeLocation("/left"),
        transferQueue: transferQueue))
    workspace.activatePane(.secondary)
    workspace.replaceActiveBrowser(
      with: FileBrowserSession(
        provider: provider,
        initialLocation: routeLocation("/right"),
        transferQueue: transferQueue))
    let presentation = FolderComparisonPresentationState()
    let menu = AppMenuModel()
    menu.register(
      context: AppMenuContext(
        isBrowserAvailable: true,
        canCompareFolders: true,
        showsSecondaryPane: true)
    ) { action in
      _ = presentation.handle(action, workspace: workspace)
    }

    menu.perform(.compareFolders)
    let comparison = try #require(presentation.model)
    await waitUntil { !comparison.isComparing && comparison.snapshot != nil }

    #expect(comparison.snapshot?.entries.map(\.relativePath) == ["left.txt", "right.txt"])
    #expect(comparison.snapshot?.entries.map(\.status) == [.leftOnly, .rightOnly])
  }

  @Test("フォルダ比較の実経路は3表示モードで同じモデルを起動する")
  func presentationRouteIsIndependentOfViewMode() throws {
    let provider = FolderComparisonRouteProvider()
    let workspace = FileWorkspaceModel(
      initialBrowser: FileBrowserSession(
        provider: provider,
        initialLocation: routeLocation("/left"),
        transferQueue: .isolatedForTesting()))
    let presentation = FolderComparisonPresentationState()

    for mode in FileBrowserViewMode.selectableCases {
      workspace.setViewMode(mode)
      #expect(
        presentation.handle(
          .compareFolders,
          workspace: workspace))
      #expect(presentation.model != nil)
      presentation.dismiss()
    }
  }

  private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
    await PKPaneTests.waitUntil(
      "フォルダ比較プレゼンテーションの状態が期限内に条件を満たさなかった"
    ) {
      condition()
    }
  }
}

private struct FolderComparisonRouteProvider: FileBrowserProvider {
  var usesCommonIncompleteItem = false
  let id = FileProviderID(rawValue: "folder-comparison-route")
  let connectionID: FileProviderConnectionID? = nil
  let capabilities: FileProviderCapabilities = [.read]

  func contents(of location: FileLocation) async throws -> [FileItem] {
    if usesCommonIncompleteItem {
      return [routeItem("common.txt", parent: location.remotePath ?? "/")]
    }
    return switch location.remotePath {
    case "/left":
      [routeItem("left.txt", parent: "/left")]
    case "/right":
      [routeItem("right.txt", parent: "/right")]
    default:
      []
    }
  }

  func parent(of _: FileLocation) -> FileLocation? { nil }

  func breadcrumbs(
    for _: FileLocation,
    constrainedTo _: FileLocation?
  ) -> [FileBrowserBreadcrumb] { [] }
}

private func routeLocation(_ path: String) -> FileLocation {
  FileLocation(
    remotePath: path,
    providerID: FileProviderID(rawValue: "folder-comparison-route"))
}

private func routeItem(_ name: String, parent: String) -> FileItem {
  let path = "\(parent)/\(name)"
  return FileItem(
    remotePath: path,
    url: URL(string: "folder-comparison-route://host\(path)")!,
    providerID: FileProviderID(rawValue: "folder-comparison-route"),
    isDirectory: false,
    size: 1)
}
