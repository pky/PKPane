import Foundation
import Testing

@testable import PKPane

struct SMBSharePathTests {
  private let volumeURL = URL(fileURLWithPath: "/Volumes/TeamShare", isDirectory: true)
  private let remountingURL = URL(string: "smb://nas.example.local/TeamShare")!

  @Test("共有ルート直下をSMB共有パスへ変換する")
  func resolvesShareRoot() throws {
    let path = try #require(resolve("/Volumes/TeamShare"))

    #expect(path.host == "nas.example.local")
    #expect(path.shareName == "TeamShare")
    #expect(path.relativePathComponents.isEmpty)
  }

  @Test("共有内の深い階層をSMB共有パスへ変換する")
  func resolvesNestedPath() throws {
    let path = try #require(resolve("/Volumes/TeamShare/Projects/PKPane/README.md"))

    #expect(path.relativePathComponents == ["Projects", "PKPane", "README.md"])
    #expect(path.createPath == "Projects\\PKPane\\README.md")
  }

  @Test("CREATE用パスはNFC化してバックスラッシュで区切る")
  func normalizesCreatePath() {
    let path = SMBSharePath(
      host: "nas.example.local",
      shareName: "TeamShare",
      relativePathComponents: ["Documents", "cafe\u{301}.txt"])

    #expect(path.createPath == "Documents\\caf\u{00E9}.txt")
    #expect(!path.createPath.contains("/"))
  }

  @Test("SMBではないボリュームは変換しない")
  func rejectsNonSMBVolume() {
    let folderURL = URL(fileURLWithPath: "/Volumes/External/notes.txt")
    let externalVolumeURL = URL(fileURLWithPath: "/Volumes/External", isDirectory: true)
    let path = SMBSharePath(
      folderURL: folderURL,
      mountedVolumeURLs: [externalVolumeURL],
      remountingURLForVolume: { _ in URL(string: "file:///Volumes/External") })

    #expect(path == nil)
  }

  @Test("末尾スラッシュ付きのパスも共有内相対パスへ変換する")
  func resolvesTrailingSlash() throws {
    let path = try #require(resolve("/Volumes/TeamShare/Projects/"))

    #expect(path.relativePathComponents == ["Projects"])
  }

  private func resolve(_ path: String) -> SMBSharePath? {
    SMBSharePath(
      folderURL: URL(fileURLWithPath: path),
      mountedVolumeURLs: [volumeURL],
      remountingURLForVolume: { _ in remountingURL })
  }
}
