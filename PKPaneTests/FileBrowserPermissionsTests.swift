import Foundation
import Testing

@testable import PKPane

@MainActor
struct FileBrowserPermissionsTests {
  @Test("権限変更後は対象1件の詳細を再取得して一覧へ反映する")
  func refreshesUpdatedItemWithoutReloadingDirectory() async throws {
    let provider = RecordingPermissionsProvider()
    let root = FileLocation(remotePath: "/root", providerID: provider.id)
    let session = FileBrowserSession(
      provider: provider, initialLocation: root, transferQueue: .isolatedForTesting())
    session.load()
    await waitForLoading(session)
    let item = try #require(session.items.first)

    let updatedItem = try await session.setPosixPermissions(0o660, for: item)

    #expect(provider.recordedPermissions == [0o660])
    #expect(provider.contentsCallCount == 1)
    #expect(provider.detailCallCount == 1)
    #expect(updatedItem.posixPermissions == 0o660)
    #expect(session.items.first?.posixPermissions == 0o660)
  }

  private func waitForLoading(_ session: FileBrowserSession) async {
    await waitUntil("isLoadingが期限内にfalseにならなかった") {
      !session.isLoading
    }
  }
}

private final class RecordingPermissionsProvider: FileBrowserItemDetailProvider,
  FileBrowserPosixPermissionsProvider, @unchecked Sendable
{
  let id = FileProviderID(rawValue: "permissions-test")
  let connectionID: FileProviderConnectionID? = nil
  let capabilities: FileProviderCapabilities = [.read, .write]

  private let lock = NSLock()
  private var mode = 0o640
  private var recordedModes: [Int] = []
  private var contentsCalls = 0
  private var detailCalls = 0

  var recordedPermissions: [Int] { lock.withLock { recordedModes } }
  var contentsCallCount: Int { lock.withLock { contentsCalls } }
  var detailCallCount: Int { lock.withLock { detailCalls } }

  func contents(of _: FileLocation) async throws -> [FileItem] {
    lock.withLock {
      contentsCalls += 1
      return [makeItem(mode: mode)]
    }
  }

  func parent(of _: FileLocation) -> FileLocation? { nil }

  func breadcrumbs(
    for _: FileLocation,
    constrainedTo _: FileLocation?
  ) -> [FileBrowserBreadcrumb] { [] }

  func detailedItem(at _: FileLocation) async throws -> FileItem {
    lock.withLock {
      detailCalls += 1
      return makeItem(mode: mode)
    }
  }

  func setPosixPermissions(_ permissions: Int, at _: FileLocation) async throws {
    lock.withLock {
      mode = permissions
      recordedModes.append(permissions)
    }
  }

  private func makeItem(mode: Int) -> FileItem {
    FileItem(
      remotePath: "/root/report.txt",
      url: URL(string: "permissions-test://host/root/report.txt")!,
      providerID: id,
      isDirectory: false,
      size: 1,
      modifiedAt: Date(timeIntervalSince1970: 1),
      posixPermissions: mode)
  }
}
