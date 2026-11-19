import Foundation
import Testing

@testable import PKPane

struct SFTPMoveListingContractTests {
  @Test("通常移動の成功は宛先全列挙なしでrenameし、削除しない")
  func successfulMoveDoesNotListDestination() async throws {
    let fixture = SFTPMoveListingFixture(mode: .success)
    try await move(using: fixture)
    #expect(await fixture.listingCount == 0)
    #expect(await fixture.renameCount == 1)
    #expect(await fixture.removalCount == 0)
  }

  @Test(
    "既存名・リンク・確定時の外部作成はrename拒否後だけ一覧で分類する",
    arguments: [SFTPMoveListingFixture.Mode.existing, .symbolicLink, .externalCreation])
  fileprivate func refusesExistingDestination(mode: SFTPMoveListingFixture.Mode) async throws {
    let fixture = SFTPMoveListingFixture(mode: mode)
    await #expect(throws: CocoaError(.fileWriteFileExists)) { try await move(using: fixture) }
    #expect(await fixture.listingCount == 1)
    #expect(await fixture.renameCount == 1)
    #expect(await fixture.removalCount == 0)
  }

  @Test(
    "一覧失敗と衝突以外のrename失敗は元エラーを保持する",
    arguments: [SFTPMoveListingFixture.Mode.listingUnavailable, .renameDenied])
  fileprivate func preservesRenameFailure(mode: SFTPMoveListingFixture.Mode) async throws {
    let fixture = SFTPMoveListingFixture(mode: mode)
    await #expect(throws: SFTPMoveListingFailure.renameDenied) { try await move(using: fixture) }
    #expect(await fixture.listingCount == 1)
    #expect(await fixture.renameCount == 1)
    #expect(await fixture.removalCount == 0)
  }

  @Test("取消を衝突へ再分類せず追加一覧も削除も実行しない")
  func preservesCancellationWithoutListing() async throws {
    let fixture = SFTPMoveListingFixture(mode: .cancelled)
    await #expect(throws: CancellationError.self) { try await move(using: fixture) }
    #expect(await fixture.listingCount == 0)
    #expect(await fixture.renameCount == 1)
    #expect(await fixture.removalCount == 0)
  }

  @Test("明示置換は実体確認と一覧と削除を維持する")
  func replacementStillChecksDestination() async throws {
    let fixture = SFTPMoveListingFixture(mode: .replacement)
    try await move(using: fixture, replacingExisting: true)
    #expect(await fixture.realPathCount == 2)
    #expect(await fixture.listingCount == 1)
    #expect(await fixture.renameCount == 1)
    #expect(await fixture.removalCount == 1)
  }

  @Test("同じ場所と子孫への移動をrename先行に変えない", arguments: [false, true])
  func keepsLocationGuards(descendant: Bool) async throws {
    let fixture = SFTPMoveListingFixture(mode: .success)
    let target = try SFTPConnectionTarget(host: "fixture.invalid", port: 22, username: "fixture")
    let provider = SFTPFileProvider(target: target, directoryListing: fixture)
    let item = FileItem(
      remotePath: "/source/report.txt", url: URL(filePath: "/source/report.txt"),
      providerID: provider.id, isDirectory: descendant)
    let destination = FileLocation(
      remotePath: descendant ? "/source/report.txt/child" : "/source", providerID: provider.id)
    if descendant {
      await #expect(throws: SFTPFileProviderError.invalidLocation) {
        try await provider.move(item, to: destination, replacingExisting: false)
      }
    } else {
      try await provider.move(item, to: destination, replacingExisting: false)
    }
    #expect(await fixture.listingCount == 0)
    #expect(await fixture.renameCount == 0)
    #expect(await fixture.removalCount == 0)
  }

  private func move(using fixture: SFTPMoveListingFixture, replacingExisting: Bool = false)
    async throws
  {
    let target = try SFTPConnectionTarget(host: "fixture.invalid", port: 22, username: "fixture")
    let provider = SFTPFileProvider(target: target, directoryListing: fixture)
    let item = FileItem(
      remotePath: "/source/report.txt", url: URL(filePath: "/source/report.txt"),
      providerID: provider.id, isDirectory: false, size: 1)
    let destination = FileLocation(remotePath: "/destination", providerID: provider.id)
    try await provider.move(item, to: destination, replacingExisting: replacingExisting)
  }
}

private enum SFTPMoveListingFailure: Error, Equatable {
  case listingUnavailable, renameDenied
}

private actor SFTPMoveListingFixture: SFTPClientSession {
  enum Mode: Sendable, Equatable {
    case success, existing, symbolicLink, externalCreation, listingUnavailable
    case renameDenied, cancelled, replacement
  }
  private let mode: Mode
  private var destinationWasRemoved = false
  private var externalWasCreated = false
  private(set) var listingCount = 0
  private(set) var renameCount = 0
  private(set) var removalCount = 0
  private(set) var realPathCount = 0

  init(mode: Mode) { self.mode = mode }

  func contents(of _: String) async throws -> [SFTPDirectoryEntry] {
    listingCount += 1
    switch mode {
    case .listingUnavailable:
      throw SFTPMoveListingFailure.listingUnavailable
    case .existing, .symbolicLink, .replacement:
      return [
        SFTPDirectoryEntry(
          name: "report.txt", isDirectory: false,
          isSymbolicLink: mode == .symbolicLink)
      ]
    case .externalCreation where externalWasCreated:
      return [SFTPDirectoryEntry(name: "report.txt", isDirectory: false)]
    default:
      return []
    }
  }

  func rename(at _: String, to _: String) async throws {
    renameCount += 1
    switch mode {
    case .success: return
    case .replacement where destinationWasRemoved: return
    case .cancelled: throw CancellationError()
    case .listingUnavailable, .renameDenied: throw SFTPMoveListingFailure.renameDenied
    case .externalCreation:
      externalWasCreated = true
      throw CocoaError(.fileWriteFileExists)
    default: throw CocoaError(.fileWriteFileExists)
    }
  }
  func realPath(of path: String) async throws -> String {
    realPathCount += 1
    return path
  }
  func remove(at _: String, isDirectory _: Bool) async throws {
    removalCount += 1
    destinationWasRemoved = true
  }
  func createDirectory(at _: String) async throws {}
  func close() async throws {}
}
