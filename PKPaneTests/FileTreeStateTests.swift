import Foundation
import Testing

@testable import PKPane

struct FileTreeStateTests {
  private static func folder(_ name: String) -> FileItem {
    FileItem(url: URL(filePath: "/tmp/tree-root/\(name)"), isDirectory: true)
  }

  private static func file(_ name: String, size: Int64 = 0) -> FileItem {
    FileItem(url: URL(filePath: "/tmp/tree-root/\(name)"), isDirectory: false, size: size)
  }

  private static func child(_ parent: FileItem, _ name: String, isDirectory: Bool = false)
    -> FileItem
  {
    FileItem(url: parent.url.appending(path: name), isDirectory: isDirectory)
  }

  // MARK: - flatten: 互換性(展開なし)

  @Test("展開が一切ない場合、通常のソート済み一覧と同じ深さ0の行配列になる")
  func flattenWithoutExpansionMatchesFlatList() {
    let items = [Self.folder("beta"), Self.file("alpha.txt"), Self.folder("gamma")]
    let rows = FileTreeFlattening.flatten(
      rootItems: items, treeState: FileTreeState(), sortOrder: .name, ascending: true)

    #expect(rows.map(\.item.name) == ["alpha.txt", "beta", "gamma"])
    #expect(rows.allSatisfy { $0.depth == 0 })
    #expect(rows.allSatisfy { !$0.isExpanded })
  }

  // MARK: - flatten: 展開

  @Test("展開したフォルダの直後に子項目が深さ1で挿入される")
  func flattenInsertsChildrenAfterExpandedFolder() {
    let beta = Self.folder("beta")
    let items = [beta, Self.file("alpha.txt")]
    var treeState = FileTreeState()
    treeState.expand(beta.location)
    let children = [Self.child(beta, "b2.txt"), Self.child(beta, "b1.txt")]
    treeState.setChildren(
      children, for: beta.location, generation: treeState.currentGeneration(for: beta.location))

    let rows = FileTreeFlattening.flatten(
      rootItems: items, treeState: treeState, sortOrder: .name, ascending: true)

    #expect(rows.map(\.item.name) == ["alpha.txt", "beta", "b1.txt", "b2.txt"])
    #expect(rows.first { $0.item.name == "beta" }?.depth == 0)
    #expect(rows.first { $0.item.name == "beta" }?.isExpanded == true)
    #expect(rows.first { $0.item.name == "b1.txt" }?.depth == 1)
    #expect(rows.first { $0.item.name == "b2.txt" }?.depth == 1)
  }

  @Test("多段展開で孫項目まで正しい深さで並ぶ")
  func flattenHandlesMultipleNestingLevels() {
    let beta = Self.folder("beta")
    let betaChildFolder = Self.child(beta, "inner", isDirectory: true)
    var treeState = FileTreeState()
    treeState.expand(beta.location)
    treeState.setChildren(
      [betaChildFolder], for: beta.location,
      generation: treeState.currentGeneration(for: beta.location))
    treeState.expand(betaChildFolder.location)
    let grandchild = Self.child(betaChildFolder, "leaf.txt")
    treeState.setChildren(
      [grandchild], for: betaChildFolder.location,
      generation: treeState.currentGeneration(for: betaChildFolder.location))

    let rows = FileTreeFlattening.flatten(
      rootItems: [beta], treeState: treeState, sortOrder: .name, ascending: true)

    #expect(rows.map(\.item.name) == ["beta", "inner", "leaf.txt"])
    #expect(rows.map(\.depth) == [0, 1, 2])
  }

  @Test("折りたたんだフォルダの配下は非表示になるが兄弟には影響しない")
  func flattenHidesCollapsedSubtree() {
    let beta = Self.folder("beta")
    let gamma = Self.folder("gamma")
    var treeState = FileTreeState()
    treeState.expand(beta.location)
    treeState.setChildren(
      [Self.child(beta, "b1.txt")], for: beta.location,
      generation: treeState.currentGeneration(for: beta.location))
    treeState.collapse(beta.location)

    let rows = FileTreeFlattening.flatten(
      rootItems: [beta, gamma], treeState: treeState, sortOrder: .name, ascending: true)

    #expect(rows.map(\.item.name) == ["beta", "gamma"])
    #expect(rows.first { $0.item.name == "beta" }?.isExpanded == false)
  }

  @Test("折りたたんでも子項目キャッシュは保持され、再展開で読み直しなしに復元できる")
  func collapseThenReExpandRestoresChildrenWithoutReload() {
    let beta = Self.folder("beta")
    var treeState = FileTreeState()
    let firstGeneration = treeState.expand(beta.location)
    #expect(firstGeneration != nil)
    treeState.setChildren(
      [Self.child(beta, "b1.txt")], for: beta.location, generation: firstGeneration!)
    treeState.collapse(beta.location)

    // 再展開: キャッシュがあるためロード要求(非nilの世代)は発行されない。
    let secondGeneration = treeState.expand(beta.location)
    #expect(secondGeneration == nil)

    let rows = FileTreeFlattening.flatten(
      rootItems: [beta], treeState: treeState, sortOrder: .name, ascending: true)
    #expect(rows.map(\.item.name) == ["beta", "b1.txt"])
  }

  @Test("各階層は親の並び順に関わらず独立にソートされる")
  func flattenSortsEachLevelIndependently() {
    let beta = Self.folder("beta")
    var treeState = FileTreeState()
    treeState.expand(beta.location)
    let unsortedChildren = [
      Self.child(beta, "z.txt"), Self.child(beta, "a.txt"), Self.child(beta, "m.txt"),
    ]
    treeState.setChildren(
      unsortedChildren, for: beta.location,
      generation: treeState.currentGeneration(for: beta.location))

    let rows = FileTreeFlattening.flatten(
      rootItems: [beta], treeState: treeState, sortOrder: .name, ascending: false)

    // ascending: false なので降順(zが先)。子も同じ降順で独立に並ぶ。
    #expect(rows.map(\.item.name) == ["beta", "z.txt", "m.txt", "a.txt"])
  }

  // MARK: - 選択除去

  @Test("折りたたみ後は見えなくなった項目の選択が除去される")
  func selectionRemovesHiddenRowsAfterCollapse() {
    let beta = Self.folder("beta")
    let childItem = Self.child(beta, "b1.txt")
    var treeState = FileTreeState()
    treeState.expand(beta.location)
    treeState.setChildren(
      [childItem], for: beta.location, generation: treeState.currentGeneration(for: beta.location)
    )
    var rows = FileTreeFlattening.flatten(
      rootItems: [beta], treeState: treeState, sortOrder: .name, ascending: true)
    let selectionWhileExpanded = FileTreeFlattening.selection(
      [beta.url, childItem.url], visibleIn: rows)
    #expect(selectionWhileExpanded == [beta.url, childItem.url])

    treeState.collapse(beta.location)
    rows = FileTreeFlattening.flatten(
      rootItems: [beta], treeState: treeState, sortOrder: .name, ascending: true)
    let selectionAfterCollapse = FileTreeFlattening.selection(
      [beta.url, childItem.url], visibleIn: rows)
    #expect(selectionAfterCollapse == [beta.url])
  }

  // MARK: - 世代管理

  @Test("初回のexpandは世代1を発行し、既に展開済みの再expandはnilを返す")
  func expandGeneratesGenerationOnlyOnce() {
    var treeState = FileTreeState()
    let location = Self.folder("beta").location
    let firstGeneration = treeState.expand(location)
    #expect(firstGeneration == 1)
    #expect(treeState.isLoadingChildren(of: location))

    let secondGeneration = treeState.expand(location)
    #expect(secondGeneration == nil)
  }

  @Test("世代が一致しない結果は古いものとして破棄される")
  func setChildrenDiscardsStaleGeneration() {
    var treeState = FileTreeState()
    let location = Self.folder("beta").location
    let generation = treeState.expand(location)!
    // 折りたたんで開き直す(=次の世代が発行される)。
    treeState.collapse(location)
    let nextGeneration = treeState.expand(location)!
    #expect(nextGeneration == generation + 1)

    // 古い世代の結果が遅れて届いても採用されない。
    let accepted = treeState.setChildren(
      [Self.child(Self.folder("beta"), "stale.txt")], for: location, generation: generation)
    #expect(accepted == false)
    #expect(treeState.children(of: location) == nil)
    #expect(treeState.isLoadingChildren(of: location))

    // 新しい世代の結果は採用される。
    let acceptedNew = treeState.setChildren(
      [Self.child(Self.folder("beta"), "fresh.txt")], for: location, generation: nextGeneration)
    #expect(acceptedNew)
    #expect(treeState.children(of: location)?.first?.name == "fresh.txt")
    #expect(!treeState.isLoadingChildren(of: location))
  }

  @Test("失敗報告も世代が一致する場合だけpendingを解除する")
  func failedLoadOnlyClearsMatchingGeneration() {
    var treeState = FileTreeState()
    let location = Self.folder("beta").location
    let generation = treeState.expand(location)!

    treeState.failedLoad(for: location, generation: generation - 1)
    #expect(treeState.isLoadingChildren(of: location))

    treeState.failedLoad(for: location, generation: generation)
    #expect(!treeState.isLoadingChildren(of: location))
  }

  @Test("resetで展開状態・キャッシュ・世代がすべてクリアされる")
  func resetClearsAllState() {
    var treeState = FileTreeState()
    let location = Self.folder("beta").location
    let generation = treeState.expand(location)!
    treeState.setChildren([], for: location, generation: generation)

    treeState.reset()

    #expect(treeState.isEmpty)
    #expect(treeState.children(of: location) == nil)
    #expect(treeState.currentGeneration(for: location) == 0)
    #expect(!treeState.isLoadingChildren(of: location))
  }

  // MARK: - 性能

  @Test("1万行規模のフラット化を短時間で完了する")
  func flattensTenThousandRowsQuickly() {
    // 100フォルダ×100子項目=1万行。各フォルダを展開した状態でフラット化する。
    let folderCount = 100
    let childCount = 100
    let folders = (0..<folderCount).map { Self.folder("folder-\($0)") }
    var treeState = FileTreeState()
    for folderItem in folders {
      let generation = treeState.expand(folderItem.location)!
      let children = (0..<childCount).map { Self.child(folderItem, "item-\($0).txt") }
      treeState.setChildren(children, for: folderItem.location, generation: generation)
    }

    let clock = ContinuousClock()
    var rows: [FileTreeRow] = []
    let duration = clock.measure {
      rows = FileTreeFlattening.flatten(
        rootItems: folders, treeState: treeState, sortOrder: .name, ascending: true)
    }

    #expect(rows.count == folderCount * (childCount + 1))
    #expect(duration < .milliseconds(200))
    print("PKPane性能計測: ツリー1万行フラット化 \(Self.milliseconds(duration))ms")
  }

  private static func milliseconds(_ duration: Duration) -> String {
    let components = duration.components
    let seconds = Double(components.seconds) * 1_000
    let attoseconds = Double(components.attoseconds) / 1_000_000_000_000_000
    let value = seconds + attoseconds
    return String(format: "%.1f", value)
  }
}
