import Darwin
import Foundation
import Testing

@testable import PKPane

struct UserHomeDirectoryTests {
  @Test("ログインユーザーのホームはSandboxのDataではなくpasswdのホームと一致する")
  func usesAccountHomeDirectory() throws {
    let account = try #require(getpwuid(getuid()))
    let path = String(cString: try #require(account.pointee.pw_dir))
    #expect(UserHomeDirectory.current == URL(filePath: path).standardizedFileURL)
  }

  @Test("標準お気に入りはコンテナに依存せずユーザーホームの直下を指す")
  func standardCandidatesUseExplicitHome() {
    let home = URL(filePath: "/Users/sidebar-fixture")
    let candidates = UserHomeDirectory.standardFolderURLs(home: home)
    #expect(
      candidates.map(\.path) == [
        "/Users/sidebar-fixture/Desktop", "/Users/sidebar-fixture/Downloads",
        "/Users/sidebar-fixture/Documents", "/Users/sidebar-fixture/Pictures",
        "/Users/sidebar-fixture/Movies", "/Users/sidebar-fixture", "/Applications",
      ])
  }

  @Test("自アプリコンテナのルートだけを識別し一般Dataやコンテナ内の子を除外しない")
  func detectsOnlyOwnContainerHome() {
    let home = URL(filePath: "/Users/sidebar-fixture")
    let container = home.appending(
      path: "Library/Containers/\(Bundle.main.bundleIdentifier ?? "com.pky.PKPane")/Data")
    #expect(UserHomeDirectory.isAppContainerHome(container, home: home))
    #expect(!UserHomeDirectory.isAppContainerHome(home.appending(path: "Data"), home: home))
    #expect(
      !UserHomeDirectory.isAppContainerHome(container.appending(path: "Documents"), home: home))
    #expect(
      !UserHomeDirectory.isAppContainerHome(
        home.appending(path: "Library/Containers/another-app/Data"), home: home))
    #expect(!UserHomeDirectory.isAppContainerHome(UserHomeDirectory.current))
  }

  @Test("未許可の書類も日本語と英語で標準フォルダ名を表示し同名の任意フォルダは変えない")
  func localizesOnlyStandardFolderPaths() throws {
    let home = URL(filePath: "/Users/sidebar-fixture")
    let documents = home.appending(path: "Documents")
    let japanesePath = try #require(Bundle.main.path(forResource: "ja", ofType: "lproj"))
    let englishPath = try #require(Bundle.main.path(forResource: "en", ofType: "lproj"))
    let japanese = try #require(Bundle(path: japanesePath))
    let english = try #require(Bundle(path: englishPath))
    #expect(
      UserHomeDirectory.localizedStandardFolderName(
        for: documents, home: home, bundle: japanese) == "書類")
    #expect(
      UserHomeDirectory.localizedStandardFolderName(
        for: documents, home: home, bundle: english) == "Documents")
    #expect(
      UserHomeDirectory.localizedStandardFolderName(
        for: home.appending(path: "Project/Documents"), home: home) == nil)
    let unresolved = SavedFolderLocation(
      id: UUID(), name: "Documents", url: nil,
      lastKnownPath: UserHomeDirectory.current.appending(path: "Documents").path)
    #expect(unresolved.requiresAuthorization)
    #expect(unresolved.sidebarSystemImage == "doc")
    #expect(
      unresolved.displayName
        == UserHomeDirectory.localizedStandardFolderName(
          for: UserHomeDirectory.current.appending(path: "Documents")))
  }
}
