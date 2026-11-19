import Foundation
import Testing

@testable import PKPane

struct TransferVerificationTests {
  @Test("サイズ不一致は検証失敗として報告する")
  func throwsSizeMismatchWhenActualBytesDiffer() async throws {
    let provider = StubSizeDetailProvider(size: 900)
    let location = FileLocation(remotePath: "/report.txt", providerID: provider.id)

    await #expect(throws: TransferVerificationError.self) {
      try await TransferSizeVerifier.verify(
        itemName: "report.txt",
        expectedBytes: 1_000,
        isSymbolicLink: false,
        at: location,
        using: provider)
    }
  }

  @Test("シンボリックリンクはサイズが一致しなくても検証をスキップする")
  func skipsVerificationForSymbolicLinks() async throws {
    let provider = StubSizeDetailProvider(size: 900)
    let location = FileLocation(remotePath: "/link", providerID: provider.id)

    // リンク自体の長さとsourceのitem.sizeに対応関係が無いため、不一致があっても
    // 検証失敗として扱わない(誤検知回避)。
    try await TransferSizeVerifier.verify(
      itemName: "link",
      expectedBytes: 1_000,
      isSymbolicLink: true,
      at: location,
      using: provider)
  }

  @Test("実サイズ取得手段を持たないProviderでは静かに検証をスキップする")
  func skipsVerificationWhenProviderCannotReportSize() async throws {
    let provider = NoDetailProvider()
    let location = FileLocation(remotePath: "/report.txt", providerID: provider.id)

    try await TransferSizeVerifier.verify(
      itemName: "report.txt",
      expectedBytes: 1_000,
      isSymbolicLink: false,
      at: location,
      using: provider)
  }

  @Test("FileBrowserItemSizeProviderが両対応の場合は軽量経路を優先する")
  func prefersLightweightSizeProviderWhenBothAreAvailable() async throws {
    let provider = DualCapabilityProvider(sizeProviderValue: 1_000, detailProviderValue: 900)
    let location = FileLocation(remotePath: "/report.txt", providerID: provider.id)

    // detailProviderの値(900)が使われれば不一致で例外になるはず。例外が出ないことは
    // 軽量なsizeProvider経路(1_000、期待値と一致)が優先された証拠。
    try await TransferSizeVerifier.verify(
      itemName: "report.txt",
      expectedBytes: 1_000,
      isSymbolicLink: false,
      at: location,
      using: provider)
  }
}

private struct StubSizeDetailProvider: FileBrowserItemDetailProvider {
  let id = FileProviderID(rawValue: "stub-size-detail")
  let connectionID: FileProviderConnectionID? = nil
  let capabilities: FileProviderCapabilities = [.read]
  let size: Int64

  func contents(of _: FileLocation) async throws -> [FileItem] { [] }
  func parent(of _: FileLocation) -> FileLocation? { nil }
  func breadcrumbs(
    for _: FileLocation, constrainedTo _: FileLocation?
  ) -> [FileBrowserBreadcrumb] { [] }

  func detailedItem(at location: FileLocation) async throws -> FileItem {
    FileItem(
      remotePath: location.remotePath ?? "/",
      url: URL(fileURLWithPath: location.remotePath ?? "/"),
      providerID: id,
      isDirectory: false,
      size: size)
  }
}

private struct NoDetailProvider: FileBrowserProvider {
  let id = FileProviderID(rawValue: "no-detail")
  let connectionID: FileProviderConnectionID? = nil
  let capabilities: FileProviderCapabilities = [.read]

  func contents(of _: FileLocation) async throws -> [FileItem] { [] }
  func parent(of _: FileLocation) -> FileLocation? { nil }
  func breadcrumbs(
    for _: FileLocation, constrainedTo _: FileLocation?
  ) -> [FileBrowserBreadcrumb] { [] }
}

private struct DualCapabilityProvider: FileBrowserItemDetailProvider, FileBrowserItemSizeProvider {
  let id = FileProviderID(rawValue: "dual-capability")
  let connectionID: FileProviderConnectionID? = nil
  let capabilities: FileProviderCapabilities = [.read]
  let sizeProviderValue: Int64
  let detailProviderValue: Int64

  func contents(of _: FileLocation) async throws -> [FileItem] { [] }
  func parent(of _: FileLocation) -> FileLocation? { nil }
  func breadcrumbs(
    for _: FileLocation, constrainedTo _: FileLocation?
  ) -> [FileBrowserBreadcrumb] { [] }

  func itemSize(at _: FileLocation) async throws -> Int64? { sizeProviderValue }

  func detailedItem(at location: FileLocation) async throws -> FileItem {
    FileItem(
      remotePath: location.remotePath ?? "/",
      url: URL(fileURLWithPath: location.remotePath ?? "/"),
      providerID: id,
      isDirectory: false,
      size: detailProviderValue)
  }
}
