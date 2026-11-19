import AppKit
import Observation

/// FileInfoView(⌘Iダイアログ)と詳細ペイン(インスペクタ)の両方が使う、選択項目の表示状態を
/// 管理する共有モデル。表示対象の選択(単一/複数/なし→呼び出し側が解決した代替1件)が
/// 変わるたびにsetSelection(_:detailItem:)を呼ぶことで、ヘッダ画像の非同期読み込みと
/// フォルダ内容計算のライフサイクルを一元管理する。二重実装を避けるため、この状態管理・
/// 非同期処理はここに集約し、Viewはこのモデルが公開する値をそのまま描画する(FileInfoContent
/// 参照)。
@Observable
@MainActor
final class FileInfoContentModel {
  typealias PermissionUpdater = @MainActor (FileItem, Int) async throws -> FileItem
  typealias FinderTagUpdater =
    @MainActor ([FileItem], FinderTagMutation) async -> FinderTagUpdateResult
  typealias ThumbnailURLResolver = @MainActor (FileItem) async throws -> URL?

  static let thumbnailRequestSize = CGSize(width: 512, height: 512)

  enum FolderScanPhase: Equatable {
    case idle
    case scanning
    case completed(FolderContentsScanner.Summary)
    case failed
  }

  private(set) var displayedItem: FileItem?
  private(set) var headerImage: NSImage?
  private(set) var folderScanPhase: FolderScanPhase = .idle
  private(set) var permissionMode: Int?
  private(set) var permissionOctalInput = ""
  private(set) var isApplyingPermissions = false
  private(set) var permissionErrorMessage: String?
  private(set) var finderTagNames: [String] = []
  private(set) var isApplyingFinderTags = false
  private(set) var finderTagErrorMessage: String?

  private let generationTracker = SelectionGenerationTracker()
  private var selectionTask: Task<Void, Never>?
  private var folderScanTask: Task<Void, Never>?
  private var folderScanCancellationToken: FolderContentsScanner.CancellationToken?
  private var permissionTask: Task<Void, Never>?
  private var permissionUpdater: PermissionUpdater?
  private var finderTagTask: Task<Void, Never>?
  private var finderTagUpdater: FinderTagUpdater?
  private var thumbnailURLResolver: ThumbnailURLResolver?
  private var shouldLoadThumbnail = true
  private var selectedItems: [FileItem] = []

  var hasPermissionsSection: Bool { permissionMode != nil }
  var canEditPermissions: Bool { permissionUpdater != nil }
  var canEditFinderTags: Bool { finderTagUpdater != nil }
  var finderTagCandidates: [String] {
    Array(FinderTagPalette.systemLabelNames.dropFirst())
  }

  /// 表示対象の選択が変わるたびに呼ぶ。items.firstを即座にdisplayedItemへ反映してから、
  /// 単一選択かつdetailItemが渡されていれば非同期で詳細版へ差し替え、続けてヘッダ画像を
  /// 読み込む。世代管理(SelectionGenerationTracker)により、選択を連打しても最後に呼ばれた
  /// setSelectionの結果だけが反映される(古い非同期結果は破棄される)。複数選択・選択なしは
  /// 詳細取得・サムネイル生成いずれも行わない(性能上、無駄な非同期処理を発生させない)。
  /// 選択が変わった時点で進行中のフォルダ内容計算は必ずキャンセルする。
  func setSelection(
    _ items: [FileItem],
    detailItem: ((FileItem) async -> FileItem)? = nil,
    permissionUpdater: PermissionUpdater? = nil,
    finderTagUpdater: FinderTagUpdater? = nil,
    thumbnailURLResolver: ThumbnailURLResolver? = nil,
    loadThumbnail: Bool = true
  ) {
    let selectionChanged = selectedItems.map(\.location) != items.map(\.location)
    cancelFolderScan()
    selectionTask?.cancel()
    permissionTask?.cancel()
    if selectionChanged {
      finderTagTask?.cancel()
      isApplyingFinderTags = false
      finderTagErrorMessage = nil
    }
    let generation = generationTracker.advance()
    selectedItems = items
    displayedItem = items.first
    headerImage = nil
    isApplyingPermissions = false
    permissionErrorMessage = nil
    self.permissionUpdater = permissionUpdater
    self.finderTagUpdater = finderTagUpdater
    self.thumbnailURLResolver = thumbnailURLResolver
    shouldLoadThumbnail = loadThumbnail
    configurePermissionState(for: items.count == 1 ? items.first : nil)
    configureFinderTagState(for: items)

    guard let firstItem = items.first, items.count == 1 else { return }

    selectionTask = Task { [weak self] in
      guard let self else { return }
      var resolvedItem = firstItem
      if let detailItem {
        resolvedItem = await detailItem(firstItem)
        guard self.generationTracker.isCurrent(generation) else { return }
        self.displayedItem = resolvedItem
        self.selectedItems = [resolvedItem]
        self.configurePermissionState(for: resolvedItem)
        self.configureFinderTagState(for: [resolvedItem])
      }
      self.loadHeaderImage(for: resolvedItem, generation: generation)
    }
  }

  func isPermissionEnabled(_ bit: Int) -> Bool {
    guard let permissionMode else { return false }
    return permissionMode & bit == bit
  }

  func setPermission(_ bit: Int, enabled: Bool) {
    guard let permissionMode else { return }
    applyPermissions(PosixPermissions.setting(bit, enabled: enabled, in: permissionMode))
  }

  func updatePermissionOctalInput(_ value: String) {
    guard PosixPermissions.isValidPartialOctalInput(value) else { return }
    permissionOctalInput = value
  }

  func commitPermissionOctalInput() {
    guard let currentMode = permissionMode else { return }
    guard let mode = PosixPermissions.mode(fromOctalString: permissionOctalInput) else {
      permissionOctalInput = PosixPermissions.octalString(for: currentMode)
      return
    }
    applyPermissions(mode)
  }

  func updateFinderTagNames(_ requestedNames: [String]) {
    guard !isApplyingFinderTags, let finderTagUpdater else { return }
    let normalizedNames = FinderTagEditing.normalizedNames(requestedNames)
    let mutation = FinderTagEditing.mutation(
      from: finderTagNames,
      to: normalizedNames)
    guard !mutation.isEmpty else { return }

    let items = selectedItems
    let selectedLocations = items.map(\.location)
    finderTagNames = normalizedNames
    finderTagErrorMessage = nil
    isApplyingFinderTags = true
    finderTagTask = Task { [weak self] in
      guard let self else { return }
      let result = await finderTagUpdater(items, mutation)
      guard self.selectedItems.map(\.location) == selectedLocations else { return }
      self.selectedItems = result.items
      if result.items.count == 1 {
        self.displayedItem = result.items.first
      }
      self.configureFinderTagState(for: result.items)
      self.finderTagErrorMessage = result.errorMessage
      self.isApplyingFinderTags = false
    }
  }

  private func applyPermissions(_ mode: Int) {
    guard !isApplyingPermissions,
      let previousMode = permissionMode,
      let item = displayedItem,
      let permissionUpdater
    else { return }
    let normalizedMode = PosixPermissions.normalizedMode(mode)
    guard normalizedMode != previousMode else {
      permissionOctalInput = PosixPermissions.octalString(for: previousMode)
      return
    }

    selectionTask?.cancel()
    let generation = generationTracker.advance()
    permissionMode = normalizedMode
    permissionOctalInput = PosixPermissions.octalString(for: normalizedMode)
    permissionErrorMessage = nil
    isApplyingPermissions = true
    let itemLocation = item.location

    permissionTask = Task { [weak self] in
      guard let self else { return }
      do {
        let updatedItem = try await permissionUpdater(item, normalizedMode)
        guard self.displayedItem?.location == itemLocation else { return }
        self.displayedItem = updatedItem
        self.configurePermissionState(for: updatedItem)
      } catch {
        guard self.displayedItem?.location == itemLocation else { return }
        self.permissionMode = previousMode
        self.permissionOctalInput = PosixPermissions.octalString(for: previousMode)
        self.permissionErrorMessage = PKPaneErrorClassifier.classify(error).displayMessage
      }
      guard self.displayedItem?.location == itemLocation else { return }
      self.isApplyingPermissions = false
      if self.headerImage == nil, let displayedItem = self.displayedItem {
        self.loadHeaderImage(for: displayedItem, generation: generation)
      }
    }
  }

  private func loadHeaderImage(for item: FileItem, generation: Int) {
    guard shouldLoadThumbnail, item.supportsThumbnailPreview || thumbnailURLResolver != nil else {
      return
    }
    let thumbnailURLResolver = thumbnailURLResolver
    selectionTask = Task { [weak self] in
      guard let self else { return }
      let thumbnailURL: URL
      if let localURL = item.location.localURL {
        thumbnailURL = localURL
      } else {
        do {
          guard let resolvedURL = try await thumbnailURLResolver?(item) else { return }
          thumbnailURL = resolvedURL
        } catch {
          // 詳細サムネイルは補助表示なので、解決失敗時は従来のアイコンへ静かに戻す。
          return
        }
      }
      guard !Task.isCancelled, self.generationTracker.isCurrent(generation) else { return }
      let thumbnail = await FileThumbnailService.shared.thumbnail(
        for: thumbnailURL,
        modifiedAt: item.modifiedAt,
        size: Self.thumbnailRequestSize)
      guard !Task.isCancelled, self.generationTracker.isCurrent(generation) else { return }
      self.headerImage = thumbnail
    }
  }

  private func configurePermissionState(for item: FileItem?) {
    permissionMode = item?.posixPermissions.map(PosixPermissions.normalizedMode(_:))
    permissionOctalInput = permissionMode.map(PosixPermissions.octalString(for:)) ?? ""
    permissionErrorMessage = nil
  }

  private func configureFinderTagState(for items: [FileItem]) {
    finderTagNames = FinderTagEditing.commonNames(in: items)
  }

  func startFolderScan(for item: FileItem) {
    guard let localURL = item.location.localURL else { return }
    let token = FolderContentsScanner.CancellationToken()
    folderScanCancellationToken = token
    folderScanPhase = .scanning
    folderScanTask = Task {
      do {
        let summary = try await Task.detached(priority: .utility) {
          try FolderContentsScanner.scan(at: localURL, cancellationToken: token)
        }.value
        // 完了時点で既に別の走査(新しいトークン)へ差し替わっている場合、
        // 古いタスクの結果で状態を上書きしない。
        guard folderScanCancellationToken === token else { return }
        folderScanPhase = .completed(summary)
      } catch {
        guard folderScanCancellationToken === token else { return }
        folderScanPhase = token.isCancelled ? .idle : .failed
      }
    }
  }

  func cancelFolderScan() {
    folderScanCancellationToken?.cancel()
    folderScanTask?.cancel()
    folderScanTask = nil
    if folderScanPhase == .scanning {
      folderScanPhase = .idle
    }
  }
}
