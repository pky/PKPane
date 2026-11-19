import Foundation
import Testing

@testable import PKPane

struct SyncBrowsingPathResolverTests {
  @Test("子フォルダへの相対移動を相手側へ適用する")
  func descendsIntoChild() throws {
    let move = try #require(
      SyncBrowsingRelativeMove.resolve(
        from: remote("/source"),
        to: remote("/source/X")))

    #expect(move.upwardLevelCount == 0)
    #expect(move.downwardComponents == ["X"])
    #expect(
      move.applying(to: remote("/backup", providerID: targetProviderID))
        == remote("/backup/X", providerID: targetProviderID))
  }

  @Test("親フォルダへの相対移動を相手側へ適用する")
  func ascendsToParent() throws {
    let move = try #require(
      SyncBrowsingRelativeMove.resolve(
        from: remote("/source/X"),
        to: remote("/source")))

    #expect(move.upwardLevelCount == 1)
    #expect(move.downwardComponents.isEmpty)
    #expect(
      move.applying(to: remote("/backup/X", providerID: targetProviderID))
        == remote("/backup", providerID: targetProviderID))
  }

  @Test("複数階層と兄弟間の相対移動を適用する")
  func movesAcrossMultipleLevels() throws {
    let move = try #require(
      SyncBrowsingRelativeMove.resolve(
        from: remote("/source/old/deep"),
        to: remote("/source/new/next")))

    #expect(move.upwardLevelCount == 2)
    #expect(move.downwardComponents == ["new", "next"])
    #expect(
      move.applying(to: remote("/backup/old/deep", providerID: targetProviderID))
        == remote("/backup/new/next", providerID: targetProviderID))
  }

  @Test("操作元と相手側のProviderが異なっても名前で追従する")
  func appliesAcrossProviders() throws {
    let sourceBefore = FileLocation(
      localURL: URL(fileURLWithPath: "/source/projects"), providerID: .local)
    let sourceAfter = FileLocation(
      localURL: URL(fileURLWithPath: "/source/projects/PKPane"), providerID: .local)
    let move = try #require(
      SyncBrowsingRelativeMove.resolve(from: sourceBefore, to: sourceAfter))

    #expect(
      move.applying(to: remote("/mirror", providerID: targetProviderID))
        == remote("/mirror/PKPane", providerID: targetProviderID))
  }

  @Test("相手側のルートより上へ出る相対移動は解決しない")
  func rejectsMoveBeyondTargetRoot() throws {
    let move = try #require(
      SyncBrowsingRelativeMove.resolve(
        from: remote("/source/one/two"),
        to: remote("/source")))

    #expect(move.applying(to: remote("/")) == nil)
  }

  private let sourceProviderID = FileProviderID(rawValue: "sync-source")
  private let targetProviderID = FileProviderID(rawValue: "sync-target")

  private func remote(_ path: String, providerID: FileProviderID? = nil) -> FileLocation {
    FileLocation(remotePath: path, providerID: providerID ?? sourceProviderID)
  }
}
