import AppKit
import Foundation
import Testing

@testable import PKPane

@MainActor
struct FileInfoContentModelTests {
  @Test("詳細ペインのサムネイルサイズは利用可能幅からパディングを控除する")
  func detailsThumbnailSizeUsesAvailableWidth() {
    #expect(DetailsThumbnailSizing.displaySize(paneWidth: 250) == 218)
  }

  @Test("詳細ペインのサムネイルサイズは120から400に収める")
  func detailsThumbnailSizeIsClamped() {
    #expect(DetailsThumbnailSizing.displaySize(paneWidth: 100) == 120)
    #expect(DetailsThumbnailSizing.displaySize(paneWidth: 500) == 400)
  }

  @Test("詳細画像は表示上限より大きい512で生成する")
  func thumbnailRequestSizeSupportsMaximumDisplaySize() {
    #expect(FileInfoContentModel.thumbnailRequestSize == CGSize(width: 512, height: 512))
  }

  @Test("選択直後はitems.firstを即座にdisplayedItemへ反映する")
  func setSelectionReflectsFirstItemImmediately() {
    let model = FileInfoContentModel()
    let item = FileItem(url: URL(filePath: "/tmp/immediate.txt"), isDirectory: false)

    model.setSelection([item])

    #expect(model.displayedItem == item)
  }

  @Test("選択なしはdisplayedItemをnilにする")
  func setSelectionWithNoItemsClearsDisplayedItem() {
    let model = FileInfoContentModel()
    model.setSelection([FileItem(url: URL(filePath: "/tmp/a.txt"), isDirectory: false)])

    model.setSelection([])

    #expect(model.displayedItem == nil)
  }

  /// 選択を連打した状況(古い選択のdetailItem解決が新しい選択の後に届く)を再現し、
  /// 世代管理(SelectionGenerationTracker)によって古い結果が新しい選択の表示を
  /// 上書きしないことを確認する。
  @Test("選択を連打しても最後の選択のdetailItem結果だけが反映される")
  func rapidSelectionOnlyAppliesLatestDetailItemResult() async throws {
    let model = FileInfoContentModel()
    let itemA = FileItem(url: URL(filePath: "/tmp/details-a.txt"), isDirectory: false)
    let itemB = FileItem(url: URL(filePath: "/tmp/details-b.txt"), isDirectory: false)
    let detailedA = FileItem(
      url: URL(filePath: "/tmp/details-a.txt"), isDirectory: false, size: 111)
    let detailedB = FileItem(
      url: URL(filePath: "/tmp/details-b.txt"), isDirectory: false, size: 222)

    // itemAのdetailItemはわざと遅延させ、itemBのdetailItemより後に解決させる。
    model.setSelection([itemA]) { _ in
      try? await Task.sleep(for: .milliseconds(80))
      return detailedA
    }
    model.setSelection([itemB]) { _ in
      detailedB
    }

    await PKPaneTests.waitUntil("表示アイテムが期限内に切り替わらなかった") {
      model.displayedItem == detailedB
    }

    #expect(model.displayedItem == detailedB)
  }

  @Test("フェイクProviderのpreviewURLから詳細サムネイルを表示する")
  func loadsThumbnailThroughProviderPreviewURL() async throws {
    let thumbnailURL = try makePNGFile(color: .red)
    defer { try? FileManager.default.removeItem(at: thumbnailURL) }
    let provider = DetailThumbnailTestProvider { _ in thumbnailURL }
    let item = provider.item(path: "/archive/image.png")
    let browser = FileBrowserSession(
      provider: provider, initialLocation: provider.rootLocation,
      transferQueue: .isolatedForTesting())
    let model = FileInfoContentModel()

    model.setSelection(
      [item],
      thumbnailURLResolver: { try await browser.detailThumbnailURL(for: $0) })
    await waitForHeaderImage(model)

    #expect(model.displayedItem == item)
    #expect(model.headerImage != nil)
  }

  @Test("previewURLの解決失敗はエラーにせずアイコン表示を維持する")
  func previewURLFailureKeepsFallbackIcon() async {
    let probe = DetailThumbnailResolutionProbe()
    let provider = DetailThumbnailTestProvider { _ in
      await probe.markResolved()
      throw DetailThumbnailTestError.failed
    }
    let item = provider.item(path: "/archive/broken.png")
    let browser = FileBrowserSession(
      provider: provider, initialLocation: provider.rootLocation,
      transferQueue: .isolatedForTesting())
    let model = FileInfoContentModel()

    model.setSelection(
      [item],
      thumbnailURLResolver: { try await browser.detailThumbnailURL(for: $0) })
    await waitUntilAsync { await probe.didResolve }

    #expect(model.displayedItem == item)
    #expect(model.headerImage == nil)
  }

  @Test("選択変更後に届いた古いpreviewURLの結果を破棄する")
  func changingSelectionDiscardsStalePreviewURL() async throws {
    let staleURL = try makePNGFile(color: .red)
    let currentURL = try makePNGFile(color: .blue)
    defer {
      try? FileManager.default.removeItem(at: staleURL)
      try? FileManager.default.removeItem(at: currentURL)
    }
    let provider = DetailThumbnailTestProvider { item in
      if item.location.remotePath == "/archive/stale.png" {
        try? await Task.sleep(for: .milliseconds(100))
        return staleURL
      }
      return currentURL
    }
    let staleItem = provider.item(path: "/archive/stale.png")
    let currentItem = provider.item(path: "/archive/current.png")
    let browser = FileBrowserSession(
      provider: provider, initialLocation: provider.rootLocation,
      transferQueue: .isolatedForTesting())
    let model = FileInfoContentModel()
    let resolver: FileInfoContentModel.ThumbnailURLResolver = {
      try await browser.detailThumbnailURL(for: $0)
    }

    model.setSelection([staleItem], thumbnailURLResolver: resolver)
    model.setSelection([currentItem], thumbnailURLResolver: resolver)
    await waitForHeaderImage(model)
    try? await Task.sleep(for: .milliseconds(150))

    #expect(model.displayedItem == currentItem)
    #expect(model.headerImage != nil)
    #expect(
      FileThumbnailService.shared.cachedThumbnail(
        for: staleURL,
        modifiedAt: staleItem.modifiedAt,
        size: FileInfoContentModel.thumbnailRequestSize) == nil)
  }

  @Test("ローカル項目はpreviewURLを解決せず既存経路で表示する")
  func localThumbnailKeepsExistingPath() async throws {
    let thumbnailURL = try makePNGFile(color: .green)
    defer { try? FileManager.default.removeItem(at: thumbnailURL) }
    let item = FileItem(url: thumbnailURL, isDirectory: false)
    let model = FileInfoContentModel()
    var resolverCallCount = 0

    model.setSelection(
      [item],
      thumbnailURLResolver: { _ in
        resolverCallCount += 1
        return nil
      })
    await waitForHeaderImage(model)

    #expect(model.headerImage != nil)
    #expect(resolverCallCount == 0)
  }

  @Test("フォルダ内容計算は選択が変わると自動でキャンセルされる")
  func changingSelectionCancelsInProgressFolderScan() {
    // 実体のないパスでよい(FolderContentsScanner.scanはFileManager.enumeratorが
    // 空の列挙を返すだけで安全に完了する)。ここで検証したいのはキャンセル配線のみ。
    let root = FileManager.default.temporaryDirectory.appending(
      path: "inspector-scan-\(UUID().uuidString)", directoryHint: .isDirectory)

    let model = FileInfoContentModel()
    let folderItem = FileItem(url: root, isDirectory: true)
    model.setSelection([folderItem])
    model.startFolderScan(for: folderItem)
    #expect(model.folderScanPhase == .scanning)

    model.setSelection([])

    #expect(model.folderScanPhase == .idle)
  }

  @Test("権限がない項目ではアクセス権セクションを表示しない")
  func itemWithoutPermissionsHidesPermissionsSection() {
    let model = FileInfoContentModel()
    let item = FileItem(url: URL(filePath: "/tmp/no-permissions.txt"), isDirectory: false)

    model.setSelection([item])

    #expect(!model.hasPermissionsSection)
  }

  @Test("チェック変更は正しい権限値を適用して更新済み項目を反映する")
  func permissionToggleAppliesModeAndRefreshesItem() async {
    let model = FileInfoContentModel()
    let item = FileItem(
      url: URL(filePath: "/tmp/permissions.txt"),
      isDirectory: false,
      posixPermissions: 0o640)
    var receivedMode: Int?
    model.setSelection(
      [item],
      permissionUpdater: { _, mode in
        receivedMode = mode
        return FileItem(
          url: item.url,
          isDirectory: false,
          posixPermissions: mode)
      })

    model.setPermission(0o020, enabled: true)
    await waitForPermissionUpdate(model)

    #expect(receivedMode == 0o660)
    #expect(model.permissionMode == 0o660)
    #expect(model.displayedItem?.posixPermissions == 0o660)
    #expect(model.permissionOctalInput == "660")
  }

  @Test("権限変更に失敗した場合は表示値を変更前へ戻す")
  func permissionFailureRestoresPreviousMode() async {
    let model = FileInfoContentModel()
    let item = FileItem(
      url: URL(filePath: "/tmp/permissions-error.txt"),
      isDirectory: false,
      posixPermissions: 0o640)
    model.setSelection(
      [item],
      permissionUpdater: { _, _ in
        throw PermissionTestError.denied
      })

    model.setPermission(0o020, enabled: true)
    await waitForPermissionUpdate(model)

    #expect(model.permissionMode == 0o640)
    #expect(model.permissionOctalInput == "640")
    #expect(
      model.permissionErrorMessage
        == PKPaneErrorClassifier.classify(PermissionTestError.denied).displayMessage)
  }

  @Test("不完全な8進数入力は確定時に現在値へ戻す")
  func invalidOctalInputRestoresCurrentValue() {
    let model = FileInfoContentModel()
    let item = FileItem(
      url: URL(filePath: "/tmp/octal.txt"),
      isDirectory: false,
      posixPermissions: 0o640)
    model.setSelection([item])

    model.updatePermissionOctalInput("75")
    model.commitPermissionOctalInput()

    #expect(model.permissionOctalInput == "640")
    #expect(model.permissionMode == 0o640)
  }

  @Test("複数選択の共通タグを表示し編集差分を共有更新処理へ渡す")
  func commonFinderTagsUseSharedUpdater() async {
    let model = FileInfoContentModel()
    let first = FileItem(
      url: URL(filePath: "/tmp/tag-first.txt"), isDirectory: false,
      tags: ["共通", "個別A"])
    let second = FileItem(
      url: URL(filePath: "/tmp/tag-second.txt"), isDirectory: false,
      tags: ["共通", "個別B"])
    var receivedMutation: FinderTagMutation?
    model.setSelection(
      [first, second],
      finderTagUpdater: { items, mutation in
        receivedMutation = mutation
        return FinderTagUpdateResult(
          items: items.map { $0.replacingTags(mutation.applying(to: $0.tags)) },
          failedCount: 0,
          firstErrorDescription: nil)
      })

    #expect(model.finderTagNames == ["共通"])
    model.updateFinderTagNames(["追加"])
    await waitForFinderTagUpdate(model)

    #expect(receivedMutation?.additions == ["追加"])
    #expect(receivedMutation?.removals == ["共通"])
    #expect(model.finderTagNames == ["追加"])
  }

  private func waitForPermissionUpdate(_ model: FileInfoContentModel) async {
    await PKPaneTests.waitUntil("アクセス権の適用が期限内に完了しなかった") {
      !model.isApplyingPermissions
    }
  }

  private func waitForFinderTagUpdate(_ model: FileInfoContentModel) async {
    await PKPaneTests.waitUntil("Finderタグの適用が期限内に完了しなかった") {
      !model.isApplyingFinderTags
    }
  }

  private func waitForHeaderImage(_ model: FileInfoContentModel) async {
    await waitUntil { model.headerImage != nil }
  }

  private func waitUntil(_ condition: @MainActor () -> Bool) async {
    await PKPaneTests.waitUntil("ファイル情報モデルの状態が期限内に条件を満たさなかった") {
      condition()
    }
  }

  private func waitUntilAsync(_ condition: @Sendable () async -> Bool) async {
    await PKPaneTests.waitUntil(
      "ファイル情報モデルの非同期状態が期限内に条件を満たさなかった"
    ) {
      await condition()
    }
  }

  private func makePNGFile(color: NSColor) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
      path: "detail-thumbnail-\(UUID().uuidString).png")
    let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
      color.setFill()
      rect.fill()
      return true
    }
    let tiff = try #require(image.tiffRepresentation)
    let png = try #require(
      NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
    try png.write(to: url)
    return url
  }
}

private struct DetailThumbnailTestProvider: FileBrowserPreviewProvider {
  let id = FileProviderID(rawValue: "detail-thumbnail-test")
  let connectionID: FileProviderConnectionID? = nil
  let capabilities: FileProviderCapabilities = [.read]
  let rootLocation: FileLocation
  private let resolver: @Sendable (FileItem) async throws -> URL

  init(resolver: @escaping @Sendable (FileItem) async throws -> URL) {
    self.resolver = resolver
    rootLocation = FileLocation(remotePath: "/archive", providerID: id)
  }

  func item(path: String) -> FileItem {
    FileItem(
      remotePath: path,
      url: URL(string: "test://\(path)")!,
      providerID: id,
      isDirectory: false)
  }

  func contents(of _: FileLocation) async throws -> [FileItem] { [] }
  func parent(of _: FileLocation) -> FileLocation? { nil }
  func breadcrumbs(
    for _: FileLocation,
    constrainedTo _: FileLocation?
  ) -> [FileBrowserBreadcrumb] { [] }

  func previewURL(for item: FileItem) async throws -> URL {
    try await resolver(item)
  }

  func detailThumbnailURL(for item: FileItem) async throws -> URL? {
    try await previewURL(for: item)
  }
}

private enum DetailThumbnailTestError: Error {
  case failed
}

private actor DetailThumbnailResolutionProbe {
  private(set) var didResolve = false

  func markResolved() {
    didResolve = true
  }
}

private enum PermissionTestError: LocalizedError {
  case denied

  var errorDescription: String? { "アクセス権がありません。" }
}
