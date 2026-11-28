import Darwin
import Foundation
import Synchronization
import Testing

@testable import PKPane

struct LocalFileProviderDeleteAccessTests {
  private let directory = URL(
    filePath: "/Library/PKPaneDeleteAccessSample", directoryHint: .isDirectory)

  private var item: FileItem {
    item(in: directory)
  }

  private func item(in directory: URL) -> FileItem {
    FileItem(
      remotePath: "/Applications/PKPaneSample.app",
      url: directory.appending(path: "PKPaneSample.app", directoryHint: .isDirectory),
      providerID: .local,
      isDirectory: true)
  }

  @Test("P1 SandboxでEPERMを受けると実URLの親に書き込み許可を求める")
  func requiresWriteAccessToActualParentForSandboxEPERM() async throws {
    let grants = WriteAccessGrantsSpy()
    let trash = MoveToTrashSpy(errors: [NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
    let provider = LocalFileProvider(
      moveToTrash: trash.move, isSandboxed: { true }, writeAccessGrants: grants)

    do {
      try await provider.delete(item)
      Issue.record("書き込み許可を要求せず削除が完了した")
    } catch FileBrowserOperationError.writeAccessRequired(let requestedDirectory) {
      #expect(requestedDirectory.standardizedFileURL.path == directory.path)
    }
    #expect(trash.calls == [item.url])
    #expect(grants.activationCalls.map(\.path) == [directory.path])
    #expect(grants.savedDirectories.isEmpty)
  }

  @Test("P2 Sandbox外のEACCESは保存済みの許可を調べず権限不足を返す")
  func reportsPermissionDenialOutsideSandboxWithoutLookingUpGrants() async throws {
    let grants = WriteAccessGrantsSpy(activation: .activated)
    let trash = MoveToTrashSpy(errors: [NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))])
    let provider = LocalFileProvider(
      moveToTrash: trash.move, isSandboxed: { false }, writeAccessGrants: grants)

    do {
      try await provider.delete(item)
      Issue.record("権限不足を報告せず削除が完了した")
    } catch FileBrowserOperationError.insufficientPermission(let itemName) {
      #expect(itemName == item.name)
    }
    #expect(trash.calls == [item.url])
    #expect(grants.activationCalls.isEmpty)
    #expect(grants.savedDirectories.isEmpty)
  }

  @Test("P3 保存済みの許可を有効化した場合に同じ項目の削除を1回やり直す")
  func retriesTrashExactlyOnceAfterActivatingSavedGrant() async throws {
    let grants = WriteAccessGrantsSpy(activation: .activated)
    let trash = MoveToTrashSpy(errors: [NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
    let provider = LocalFileProvider(
      moveToTrash: trash.move, isSandboxed: { true }, writeAccessGrants: grants)

    try await provider.delete(item)

    #expect(trash.calls == [item.url, item.url])
    #expect(grants.activationCalls.map(\.path) == [directory.path])
    #expect(grants.savedDirectories.isEmpty)
  }

  @Test("P4 許可が有効な状態で拒否された削除は再試行せず権限不足を返す")
  func reportsPermissionDenialForAlreadyActiveGrantWithoutRetry() async throws {
    let grants = WriteAccessGrantsSpy(activation: .alreadyActive)
    let trash = MoveToTrashSpy(errors: [CocoaError(.fileWriteNoPermission) as NSError])
    let provider = LocalFileProvider(
      moveToTrash: trash.move, isSandboxed: { true }, writeAccessGrants: grants)

    do {
      try await provider.delete(item)
      Issue.record("権限不足を報告せず削除が完了した")
    } catch FileBrowserOperationError.insufficientPermission(let itemName) {
      #expect(itemName == item.name)
    }
    #expect(trash.calls == [item.url])
    #expect(grants.activationCalls.map(\.path) == [directory.path])
    #expect(grants.savedDirectories.isEmpty)
  }

  @Test("P5 ENOENTは元のエラーのまま返し、許可を調べない")
  func preservesNonPermissionTrashError() async {
    let grants = WriteAccessGrantsSpy(activation: .activated)
    let expectedError = NSError(
      domain: NSPOSIXErrorDomain, code: Int(ENOENT),
      userInfo: [NSLocalizedDescriptionKey: "テスト項目が見つかりません。"])
    let trash = MoveToTrashSpy(errors: [expectedError])
    let provider = LocalFileProvider(
      moveToTrash: trash.move, isSandboxed: { true }, writeAccessGrants: grants)

    do {
      try await provider.delete(item)
      Issue.record("削除時のENOENTが失われた")
    } catch {
      #expect((error as NSError) == expectedError)
    }
    #expect(trash.calls == [item.url])
    #expect(grants.activationCalls.isEmpty)
    #expect(grants.savedDirectories.isEmpty)
  }

  @Test("P6 Cocoaエラーが包むEACCESも書き込み許可の要求に変換する")
  func recognizesEACCESUnderlyingCocoaError() async throws {
    let grants = WriteAccessGrantsSpy()
    let error = NSError(
      domain: NSCocoaErrorDomain, code: CocoaError.fileWriteUnknown.rawValue,
      userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))])
    let trash = MoveToTrashSpy(errors: [error])
    let provider = LocalFileProvider(
      moveToTrash: trash.move, isSandboxed: { true }, writeAccessGrants: grants)

    do {
      try await provider.delete(item)
      Issue.record("内包されたEACCESが書き込み許可の要求にならなかった")
    } catch FileBrowserOperationError.writeAccessRequired(let requestedDirectory) {
      #expect(requestedDirectory.standardizedFileURL.path == directory.path)
    }
    #expect(trash.calls == [item.url])
    #expect(grants.activationCalls.map(\.path) == [directory.path])
    #expect(grants.savedDirectories.isEmpty)
  }

  @Test("P7 実URLの親が/System配下なら保存済みの許可を調べず権限不足を返す")
  func reportsPermissionDenialForSystemDirectoryWithoutLookingUpGrants() async {
    let directory = URL(filePath: "/System/Applications", directoryHint: .isDirectory)
    let item = item(in: directory)
    let grants = WriteAccessGrantsSpy()
    let trash = MoveToTrashSpy(errors: [NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
    let provider = LocalFileProvider(
      moveToTrash: trash.move, isSandboxed: { true }, writeAccessGrants: grants)

    do {
      try await provider.delete(item)
      Issue.record("権限不足を報告せず削除が完了した")
    } catch FileBrowserOperationError.insufficientPermission(let itemName) {
      #expect(itemName == item.name)
    } catch {
      Issue.record("権限不足と異なるエラーが返った: \(error)")
    }
    #expect(trash.calls == [item.url])
    #expect(grants.activationCalls.isEmpty)
    #expect(grants.savedDirectories.isEmpty)
  }

  @Test("P8 /SystemX配下では実URLの親に書き込み許可を求める")
  func requiresWriteAccessOutsideTheSystemPathComponent() async throws {
    let directory = URL(filePath: "/SystemX/Applications", directoryHint: .isDirectory)
    let item = item(in: directory)
    let grants = WriteAccessGrantsSpy()
    let trash = MoveToTrashSpy(errors: [NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])
    let provider = LocalFileProvider(
      moveToTrash: trash.move, isSandboxed: { true }, writeAccessGrants: grants)

    do {
      try await provider.delete(item)
      Issue.record("書き込み許可を要求せず削除が完了した")
    } catch FileBrowserOperationError.writeAccessRequired(let requestedDirectory) {
      #expect(requestedDirectory.standardizedFileURL.path == directory.path)
    }
    #expect(trash.calls == [item.url])
    #expect(grants.activationCalls.map(\.path) == [directory.path])
    #expect(grants.savedDirectories.isEmpty)
  }
}

@MainActor
struct FileBrowserSessionDeleteAccessTests {
  private let root = URL(filePath: "/virtual/pkpane-delete-access", directoryHint: .isDirectory)

  @Test("S1 2件目で許可を求め、先に削除した項目を一覧と検索結果から外す")
  func requestsOnlyUnprocessedItemsAndRefreshesPartialSuccess() async throws {
    let (session, provider, grants, items) = try await startDeletion(withSearch: true)
    let remaining = Array(items.dropFirst())

    let request: FileBrowserWriteAccessRequest = try #require(session.pendingWriteAccessRequest)
    #expect(request.directory.path == applications.path)
    #expect(request.items == remaining)
    #expect(await provider.deleteCalls == Array(items.prefix(2)))
    #expect(session.items == remaining)
    #expect(session.errorMessage == nil)
    #expect(grants.savedDirectories.isEmpty)
    await waitUntil("削除済みの項目が検索結果に残っている") {
      session.searchResults.map(\.item) == remaining
    }
  }

  @Test("S2 同じフォルダの許可を1回保存し、失敗した項目から削除を再開する")
  func savesGrantAndRetriesOnlyPendingItems() async throws {
    let (session, provider, grants, items) = try await startDeletion()
    let request = try #require(session.pendingWriteAccessRequest)

    session.grantWriteAccess(request.directory)
    await waitUntil {
      !session.isLoading && session.items.isEmpty
    }

    #expect(grants.savedDirectories == [request.directory])
    #expect(await provider.deleteCalls == Array(items.prefix(2)) + Array(items.dropFirst()))
    #expect(session.pendingWriteAccessRequest == nil)
    #expect(session.errorMessage == nil)
  }

  @Test(
    "S3 パス文字列が前方一致するだけのフォルダや子フォルダを許可として使わない",
    arguments: ["App", "Applications/Utilities", "Elsewhere"])
  func rejectsSelectedFolderThatDoesNotCoverRequest(selectedPath: String) async throws {
    let (session, provider, grants, items) = try await startDeletion()
    try #require(session.pendingWriteAccessRequest != nil)

    session.grantWriteAccess(root.appending(path: selectedPath, directoryHint: .isDirectory))
    await waitUntil { !session.isLoading && session.errorMessage != nil }

    #expect(grants.savedDirectories.isEmpty)
    #expect(await provider.deleteCalls == Array(items.prefix(2)))
    #expect(session.pendingWriteAccessRequest == nil)
    #expect(try #require(session.errorMessage).contains(applications.lastPathComponent))
  }

  @Test("S4 同じフォルダで削除に再失敗すると権限不足を表示し、許可を再要求しない")
  func reportsPermissionDenialWhenSameDirectoryStillNeedsAccess() async throws {
    let (session, provider, grants, items) = try await startDeletion(deniesAfterGrant: true)
    let request = try #require(session.pendingWriteAccessRequest)
    let blocked = try #require(items.dropFirst().first)

    session.grantWriteAccess(request.directory)
    await waitUntil { !session.isLoading && session.errorMessage != nil }

    let expectedError = FileBrowserOperationError.insufficientPermission(itemName: blocked.name)
    #expect(session.errorMessage == PKPaneErrorClassifier.classify(expectedError).displayMessage)
    #expect(session.pendingWriteAccessRequest == nil)
    #expect(grants.savedDirectories == [request.directory])
    #expect(await provider.deleteCalls == Array(items.prefix(2)) + [blocked])
  }

  @Test("S5 許可をキャンセルすると要求が消え、残りの項目を削除しない")
  func cancelsRequestWithoutRetryingDeletion() async throws {
    let (session, provider, grants, items) = try await startDeletion()
    try #require(session.pendingWriteAccessRequest != nil)

    session.cancelWriteAccessRequest()
    await waitUntil { !session.isLoading }

    #expect(session.pendingWriteAccessRequest == nil)
    #expect(await provider.deleteCalls == Array(items.prefix(2)))
    #expect(grants.savedDirectories.isEmpty)
    #expect(session.items == Array(items.dropFirst()))
    #expect(session.errorMessage == nil)
  }

  @Test("S6 祖先フォルダを選ぶと要求されたフォルダの許可を1回保存し、残りの削除を再開する")
  func savesRequestedDirectoryWhenAncestorIsSelectedAndResumesDeletion() async throws {
    let (session, provider, grants, items) = try await startDeletion()
    let request = try #require(session.pendingWriteAccessRequest)

    session.grantWriteAccess(request.directory.deletingLastPathComponent())
    await waitUntil { !session.isLoading && session.items.isEmpty }

    #expect(grants.savedDirectories == [request.directory])
    #expect(await provider.deleteCalls == Array(items.prefix(2)) + Array(items.dropFirst()))
    #expect(session.pendingWriteAccessRequest == nil)
    #expect(session.errorMessage == nil)
  }

  @Test("S7 先に削除した項目の一覧を再読込できなければ、許可要求と再読込エラーを表示する")
  func preservesClassifiedReloadErrorWhenRequestingWriteAccess() async throws {
    let reloadError = CocoaError(.fileReadNoPermission)
    let (session, provider, grants, items) = try await startDeletion(reloadError: reloadError)

    let request = try #require(session.pendingWriteAccessRequest)
    #expect(request.directory == applications)
    #expect(request.items == Array(items.dropFirst()))
    #expect(await provider.deleteCalls == Array(items.prefix(2)))
    #expect(await provider.reloadFailures == 1)
    #expect(session.errorMessage == PKPaneErrorClassifier.classify(reloadError).displayMessage)
    #expect(grants.savedDirectories.isEmpty)
  }

  private var applications: URL {
    root.appending(path: "Applications", directoryHint: .isDirectory)
  }

  private func startDeletion(
    withSearch: Bool = false,
    deniesAfterGrant: Bool = false,
    reloadError: CocoaError? = nil
  ) async throws -> (
    FileBrowserSession, WriteAccessRequiredProvider, WriteAccessGrantsSpy, [FileItem]
  ) {
    let directory = applications
    let items = (1...3).map { index in
      FileItem(
        url: directory.appending(path: "sample-\(index).app", directoryHint: .notDirectory),
        isDirectory: false)
    }
    let blocked = try #require(items.dropFirst().first)
    let grants = WriteAccessGrantsSpy()
    let location = FileLocation(localURL: directory)
    let provider = WriteAccessRequiredProvider(
      location: location, items: items, blocked: blocked, directory: directory,
      reloadError: reloadError,
      canDeleteBlockedItem: { !deniesAfterGrant && !grants.savedDirectories.isEmpty })
    let session = FileBrowserSession(
      provider: provider, initialLocation: location, transferQueue: .isolatedForTesting(),
      searchDebounceDuration: .zero, writeAccessGrants: grants)

    session.load()
    await waitUntil { !session.isLoading && session.items == items }
    if withSearch {
      session.setSearchText("sample")
      await waitUntil { !session.isSearching && session.searchResults.map(\.item) == items }
    }

    session.delete(items)
    await waitUntil { !session.isLoading }
    return (session, provider, grants, items)
  }
}

struct FolderWriteAccessGrantStoreTests {
  @Test("G1 保存は同じパスで重複せず、有効な許可は同一パスと子に限って再利用する")
  func matchesWholePathComponentsAndDoesNotStoreOrStartDuplicateGrants() throws {
    let suite = "com.pky.PKPane.delete-access-tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let starts = Mutex<[URL]>([])
    let store = FolderWriteAccessGrantStore(
      defaults: defaults, codec: PathOnlyGrantBookmarkCodec(),
      startAccessing: { url in
        starts.withLock { $0.append(url) }
        return true
      })
    let app = URL(filePath: "/App", directoryHint: .isDirectory)
    let child = app.appending(path: "Utilities", directoryHint: .isDirectory)
    let applications = URL(filePath: "/Applications", directoryHint: .isDirectory)

    try store.save(app)
    try store.save(app)

    #expect(store.activateGrant(covering: applications) == .none)
    #expect(store.activateGrant(covering: app) == .alreadyActive)
    #expect(store.activateGrant(covering: child) == .alreadyActive)
    #expect(starts.withLock { $0.map(\.path) } == [app.path])
    let storedBookmarks = defaults.persistentDomain(forName: suite)?.values.compactMap {
      $0 as? [Data]
    }
    #expect(storedBookmarks == [[Data(app.path.utf8)]])
  }

  @Test("C1 権限不足をaccessDeniedに分類し、表示文言に項目名とFinderの案内を含める")
  func includesItemAndFinderGuidanceInPermissionError() {
    let itemName = "Example Delete Access.app"
    let error = FileBrowserOperationError.insufficientPermission(itemName: itemName)
    let classified = PKPaneErrorClassifier.classify(error)

    #expect(classified.category == .accessDenied)
    #expect(classified.displayMessage.contains(itemName))
    #expect(classified.displayMessage.contains("Finder"))
  }
}

private final class MoveToTrashSpy: Sendable {
  private let errors: [NSError]
  private let recordedCalls = Mutex<[URL]>([])

  var calls: [URL] { recordedCalls.withLock { $0 } }

  init(errors: [NSError]) {
    self.errors = errors
  }

  func move(_ url: URL) throws {
    try recordedCalls.withLock { calls in
      calls.append(url)
      if calls.count <= errors.count {
        throw errors[calls.count - 1]
      }
    }
  }
}

private final class WriteAccessGrantsSpy: FolderWriteAccessGrantStoring {
  private let activation: GrantActivation
  private let recordedActivations = Mutex<[URL]>([])
  private let recordedSaves = Mutex<[URL]>([])

  var activationCalls: [URL] { recordedActivations.withLock { $0 } }
  var savedDirectories: [URL] { recordedSaves.withLock { $0 } }

  init(activation: GrantActivation = .none) {
    self.activation = activation
  }

  func save(_ directoryURL: URL) throws {
    recordedSaves.withLock { $0.append(directoryURL) }
  }

  func activateGrant(covering url: URL) -> GrantActivation {
    recordedActivations.withLock { $0.append(url) }
    return activation
  }
}

private actor WriteAccessRequiredProvider: FileBrowserTrashProvider {
  let id: FileProviderID = .local
  let connectionID: FileProviderConnectionID? = nil
  let capabilities: FileProviderCapabilities = [.read, .write, .trash]
  private let location: FileLocation
  private let blocked: FileItem
  private let directory: URL
  private let reloadError: CocoaError?
  private let canDeleteBlockedItem: @Sendable () -> Bool
  private var items: [FileItem]
  private var hasDeletedItem = false
  private(set) var deleteCalls: [FileItem] = []
  private(set) var reloadFailures = 0

  init(
    location: FileLocation,
    items: [FileItem],
    blocked: FileItem,
    directory: URL,
    reloadError: CocoaError?,
    canDeleteBlockedItem: @escaping @Sendable () -> Bool
  ) {
    self.location = location
    self.items = items
    self.blocked = blocked
    self.directory = directory
    self.reloadError = reloadError
    self.canDeleteBlockedItem = canDeleteBlockedItem
  }

  func contents(of location: FileLocation) async throws -> [FileItem] {
    guard location == self.location else { return [] }
    if hasDeletedItem, let reloadError {
      reloadFailures += 1
      throw reloadError
    }
    return items
  }

  nonisolated func parent(of _: FileLocation) -> FileLocation? { nil }

  nonisolated func breadcrumbs(
    for _: FileLocation,
    constrainedTo _: FileLocation?
  ) -> [FileBrowserBreadcrumb] { [] }

  func createDirectory(named _: String, in _: FileLocation) async throws {}

  func rename(_: FileItem, to _: String) async throws {}

  func delete(_ item: FileItem) async throws {
    deleteCalls.append(item)
    guard items.contains(item) else { throw CocoaError(.fileNoSuchFile) }
    if item == blocked, !canDeleteBlockedItem() {
      throw FileBrowserOperationError.writeAccessRequired(directory: directory)
    }
    items.removeAll { $0 == item }
    hasDeletedItem = true
  }
}

private struct PathOnlyGrantBookmarkCodec: FolderBookmarkCoding, Sendable {
  func createBookmark(for url: URL) throws -> Data {
    Data(url.standardizedFileURL.path.utf8)
  }

  func resolveBookmark(_ data: Data) throws -> ResolvedFolderBookmark {
    guard let path = String(data: data, encoding: .utf8) else {
      throw CocoaError(.fileReadCorruptFile)
    }
    return ResolvedFolderBookmark(
      url: URL(filePath: path, directoryHint: .isDirectory), isStale: false)
  }
}
