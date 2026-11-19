import Foundation
import Testing

@testable import PKPane

@MainActor
struct RemoteEditControllerTests {
  @Test("作業コピーの保存は一度だけ安全にSFTPへ同期する")
  func synchronizesChangedWorkingCopyOnlyOnce() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = RemoteEditTestProvider()
    let controller = RemoteEditController(rootURL: root, openWorkingCopy: { _ in })
    let item = await provider.remoteItem()

    await controller.startEditing(item, using: provider)
    let session = try #require(controller.sessions.first)
    try Data("編集後".utf8).write(to: session.workingCopyURL, options: .atomic)

    await controller.synchronizeNow(for: session.id)
    await controller.synchronizeNow(for: session.id)

    #expect(await provider.contents() == Data("編集後".utf8))
    #expect(await provider.uploadCount() == 1)
    #expect(controller.sessions.first?.state == .synced)
  }

  @Test("リモート側の変更があると未同期コピーを保持して競合にする")
  func preservesWorkingCopyWhenRemoteChanged() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let provider = RemoteEditTestProvider()
    let controller = RemoteEditController(rootURL: root, openWorkingCopy: { _ in })
    let item = await provider.remoteItem()

    await controller.startEditing(item, using: provider)
    let session = try #require(controller.sessions.first)
    try Data("ローカル変更".utf8).write(to: session.workingCopyURL, options: .atomic)
    await provider.changeRemotely(to: Data("リモート変更".utf8))

    await controller.synchronizeNow(for: session.id)

    #expect(controller.sessions.first?.state == .conflict)
    #expect(controller.conflictSessionID == session.id)
    #expect(await provider.contents() == Data("リモート変更".utf8))
    #expect(FileManager.default.fileExists(atPath: session.workingCopyURL.path))
  }

  @Test("未同期セッションは保存済み作業コピーとともに復元される")
  func restoresUnsyncedSession() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let workingCopy = root.appending(path: "recovery/report.txt")
    try FileManager.default.createDirectory(
      at: workingCopy.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try Data("未同期".utf8).write(to: workingCopy)
    let providerID = FileProviderID(rawValue: "sftp-test")
    let location = FileLocation(remotePath: "/report.txt", providerID: providerID)
    let record = RemoteEditSession(
      providerID: providerID,
      remoteLocation: location,
      workingCopyURL: workingCopy,
      originalName: "report.txt",
      baseline: RemoteEditBaseline(
        item: FileItem(
          remotePath: "/report.txt",
          url: URL(string: "sftp://example.com/report.txt")!,
          providerID: providerID,
          isDirectory: false)),
      lastSyncedRevision: "before",
      state: .unsynced)
    let store = RemoteEditSessionStore(url: root.appending(path: "sessions.json"))
    try store.save([record])

    let controller = RemoteEditController(rootURL: root, store: store, openWorkingCopy: { _ in })

    #expect(controller.sessions == [record])
    #expect(controller.hasUnsyncedChanges)
  }

  private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appending(
      path: UUID().uuidString,
      directoryHint: .isDirectory)
  }
}

private actor RemoteEditTestProvider: RemoteEditProvider {
  let id = FileProviderID(rawValue: "sftp-test")
  let connectionID: FileProviderConnectionID? = nil
  let capabilities: FileProviderCapabilities = [.read, .write]
  private var data = Data("初期値".utf8)
  private var modifiedAt = Date(timeIntervalSinceReferenceDate: 100)
  private var uploads = 0

  func contents(of _: FileLocation) async throws -> [FileItem] { [] }
  nonisolated func parent(of _: FileLocation) -> FileLocation? { nil }
  nonisolated func breadcrumbs(
    for _: FileLocation,
    constrainedTo _: FileLocation?
  ) -> [FileBrowserBreadcrumb] { [] }

  func downloadWorkingCopy(for _: FileItem, to localURL: URL) async throws {
    try FileManager.default.createDirectory(
      at: localURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try data.write(to: localURL, options: .atomic)
  }

  func item(at location: FileLocation) async throws -> FileItem? {
    guard location == remoteItem().location else { return nil }
    return remoteItem()
  }

  func uploadWorkingCopySafely(from localURL: URL, to _: FileLocation) async throws {
    data = try Data(contentsOf: localURL)
    modifiedAt.addTimeInterval(1)
    uploads += 1
  }

  func remoteItem() -> FileItem {
    FileItem(
      remotePath: "/report.txt",
      url: URL(string: "sftp://example.com/report.txt")!,
      providerID: id,
      isDirectory: false,
      size: Int64(data.count),
      modifiedAt: modifiedAt)
  }

  func changeRemotely(to data: Data) {
    self.data = data
    modifiedAt.addTimeInterval(1)
  }

  func contents() -> Data { data }
  func uploadCount() -> Int { uploads }
}
