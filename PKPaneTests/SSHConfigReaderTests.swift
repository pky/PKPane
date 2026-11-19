import Foundation
import Synchronization
import Testing

@testable import PKPane

struct SSHConfigReaderTests {
  @Test("Bookmark経由のアクセスは本体の前後でスコープを開閉する")
  func withDirectoryAccessOpensScopeForBookmarkedState() throws {
    let folder = URL(filePath: "/Selected/.ssh")
    let recorder = SSHConfigScopeRecorder()
    let reader = makeScopedSSHConfigReader(folderURL: folder, recorder: recorder)

    let value = try reader.withDirectoryAccess {
      #expect(recorder.isActive)
      recorder.record("body")
      return 42
    }
    #expect(value == 42)
    #expect(recorder.events == ["start", "body", "stop"])
    #expect(recorder.accessedURLs == [folder])
    #expect(!recorder.isActive)

    recorder.reset()
    #expect(throws: CocoaError.self) {
      try reader.withDirectoryAccess { () throws -> Void in
        recorder.record("body")
        throw CocoaError(.fileReadCorruptFile)
      }
    }
    #expect(recorder.events == ["start", "body", "stop"])
    #expect(!recorder.isActive)

    recorder.reset()
    let loaded = try reader.loadDocument()
    #expect(loaded.folderURL == folder)
    #expect(recorder.events == ["start", "stop"])
    #expect(!recorder.isActive)

    recorder.reset()
    let directReader = SSHConfigReader(
      homeDirectory: URL(filePath: "/Users/test"), accessRepository: makeAccessRepository(),
      fileReader: { _ in "Host direct" }, scopedAccess: recorder.access)
    #expect(try directReader.withDirectoryAccess { 7 } == 7)
    #expect(recorder.events.isEmpty)
  }

  @Test("既定のホームはSandboxコンテナではなく実ユーザーのホームを使う")
  func defaultHomeDirectoryIsRealUserHome() throws {
    let expectedFolder = UserHomeDirectory.current.appending(path: ".ssh")
    let reader = SSHConfigReader(
      accessRepository: makeAccessRepository(),
      fileReader: { url in
        #expect(url == expectedFolder.appending(path: "config"))
        return "Host fixture"
      })
    #expect(try reader.loadDocument().folderURL == expectedFolder)

    // ad-hocテストでは両ホームが一致するため、Sandboxで危険な既定式も固定する。
    let sourceURL = URL(filePath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().appending(
        path: "PKPane/Infrastructure/SSHConfig/SSHConfigReader.swift")
    let source = try String(contentsOf: sourceURL, encoding: .utf8)
    #expect(
      !source.contains("homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser"))
  }

  @Test("直接configが無い場合も保存済みフォルダを優先する")
  func missingConfigPrefersSavedBookmark() throws {
    let home = URL(filePath: "/Users/test")
    let folder = URL(filePath: "/Selected/.ssh")
    let reader = SSHConfigReader(
      homeDirectory: home,
      accessRepository: makeAccessRepository(bookmarkedFolderURL: folder),
      fileReader: SSHConfigFileReaderStub(responses: [
        folder.appending(path: "config"): .text("Host selected")
      ]).read)

    #expect(reader.accessState() == .bookmarked(folder))
    let loaded = try reader.loadDocument()
    #expect(loaded.folderURL == folder)
    #expect(loaded.document.concreteAliases == ["selected"])
  }

  @Test("許可フォルダ内のInclude読取失敗を警告する")
  func includeReadFailureEmitsWarning() throws {
    let home = URL(filePath: "/Users/test")
    let folder = home.appending(path: ".ssh")
    let includeURL = folder.appending(path: "unreadable.conf")
    let reader = SSHConfigReader(
      homeDirectory: home, accessRepository: makeAccessRepository(),
      fileReader: SSHConfigFileReaderStub(responses: [
        folder.appending(path: "config"): .text("Include unreadable.conf\nHost kept"),
        includeURL: .cocoaNoPermission,
      ]).read)

    let loaded = try reader.loadDocument()

    #expect(loaded.document.concreteAliases == ["kept"])
    #expect(loaded.document.warnings.contains(.includeUnreadable(path: includeURL.path)))
  }

  @Test("configを直接読める場合は直接アクセスとして解析する")
  func directReadWhenConfigIsReadable() throws {
    let homeDirectory = URL(filePath: "/Users/test", directoryHint: .isDirectory)
    let configURL = homeDirectory.appending(path: ".ssh/config")
    let fileReader = SSHConfigFileReaderStub(responses: [
      configURL: .text(
        """
        Host files
          HostName files.example
        """)
    ])
    let reader = SSHConfigReader(
      homeDirectory: homeDirectory,
      accessRepository: makeAccessRepository(),
      fileReader: fileReader.read)

    #expect(reader.accessState() == .direct)

    let loaded = try reader.loadDocument()
    #expect(loaded.folderURL == homeDirectory.appending(path: ".ssh"))
    #expect(loaded.document.concreteAliases == ["files"])
  }

  @Test("直接読取がEACCESなら保存済みBookmarkへフォールバックする")
  func permissionErrorFallsBackToBookmark() throws {
    let homeDirectory = URL(filePath: "/Users/test", directoryHint: .isDirectory)
    let directConfigURL = homeDirectory.appending(path: ".ssh/config")
    let bookmarkedFolderURL = URL(
      filePath: "/Selected/.ssh", directoryHint: .isDirectory)
    let bookmarkedConfigURL = bookmarkedFolderURL.appending(path: "config")
    let fileReader = SSHConfigFileReaderStub(responses: [
      directConfigURL: .posixEACCES,
      bookmarkedConfigURL: .text(
        """
        Host gateway
          HostName gateway.example
        """),
    ])
    let reader = SSHConfigReader(
      homeDirectory: homeDirectory,
      accessRepository: makeAccessRepository(bookmarkedFolderURL: bookmarkedFolderURL),
      fileReader: fileReader.read)

    #expect(reader.accessState() == .bookmarked(bookmarkedFolderURL))

    let loaded = try reader.loadDocument()
    #expect(loaded.folderURL == bookmarkedFolderURL)
    #expect(loaded.document.concreteAliases == ["gateway"])
  }

  @Test("権限エラー時にBookmarkがなければアクセス不可にする")
  func permissionErrorWithoutBookmarkIsUnavailable() {
    let homeDirectory = URL(filePath: "/Users/test", directoryHint: .isDirectory)
    let configURL = homeDirectory.appending(path: ".ssh/config")
    let fileReader = SSHConfigFileReaderStub(responses: [configURL: .cocoaNoPermission])
    let reader = SSHConfigReader(
      homeDirectory: homeDirectory,
      accessRepository: makeAccessRepository(),
      fileReader: fileReader.read)

    #expect(reader.accessState() == .unavailable)
    do {
      _ = try reader.loadDocument()
      Issue.record("アクセス許可がなければconfigを読み込めてはいけません")
    } catch let error as SSHConfigReaderError {
      guard case .accessRequired = error else {
        Issue.record("accessRequired以外のエラーが返りました: \(error)")
        return
      }
    } catch {
      Issue.record("SSHConfigReaderError以外のエラーが返りました: \(error)")
    }
  }

  @Test("許可フォルダ外のIncludeを拒否して警告する")
  func includeOutsideFolderIsRefused() throws {
    let homeDirectory = URL(filePath: "/Users/test", directoryHint: .isDirectory)
    let configURL = homeDirectory.appending(path: ".ssh/config")
    let fileReader = SSHConfigFileReaderStub(responses: [
      configURL: .text(
        """
        Include /etc/ssh/external.conf
        Host files
          HostName files.example
        """),
      URL(filePath: "/etc/ssh/external.conf"): .text(
        """
        Host forbidden
          HostName forbidden.example
        """),
    ])
    let reader = SSHConfigReader(
      homeDirectory: homeDirectory,
      accessRepository: makeAccessRepository(),
      fileReader: fileReader.read)

    let loaded = try reader.loadDocument()

    #expect(
      loaded.document.warnings.contains(
        .includeOutsideAccessibleFolder(path: "/etc/ssh/external.conf")))
    #expect(loaded.document.concreteAliases == ["files"])
  }

  @Test("許可フォルダ外の秘密鍵パスを採用しない")
  func keyFileOutsideFolderIsNil() {
    let homeDirectory = URL(filePath: "/Users/test", directoryHint: .isDirectory)
    let folderURL = homeDirectory.appending(path: ".ssh", directoryHint: .isDirectory)
    let reader = SSHConfigReader(
      homeDirectory: homeDirectory,
      accessRepository: makeAccessRepository(),
      fileReader: SSHConfigFileReaderStub(responses: [:]).read)

    #expect(
      reader.normalizedKeyFileURL("/Users/test/.ssh/id_ed25519", within: folderURL)
        == folderURL.appending(path: "id_ed25519"))
    #expect(reader.normalizedKeyFileURL("/Users/test/.ssh-other/key", within: folderURL) == nil)
    #expect(reader.normalizedKeyFileURL("/etc/ssh/id_ed25519", within: folderURL) == nil)
  }

  private func makeAccessRepository(bookmarkedFolderURL: URL? = nil)
    -> SSHDirectoryAccessRepository
  {
    guard let bookmarkedFolderURL else {
      return SSHDirectoryAccessRepository(
        storage: ReaderSSHDirectoryBookmarkStorage(),
        codec: ReaderSSHDirectoryBookmarkCodec(resolvedBookmarkByData: [:]))
    }
    let bookmarkData = Data("ssh-directory-bookmark".utf8)
    return SSHDirectoryAccessRepository(
      storage: ReaderSSHDirectoryBookmarkStorage(bookmarkData: bookmarkData),
      codec: ReaderSSHDirectoryBookmarkCodec(resolvedBookmarkByData: [
        bookmarkData: ResolvedFolderBookmark(url: bookmarkedFolderURL, isStale: false)
      ]))
  }
}

// Readerとフォームで、スコープ内に永続化処理が入ることを同じ記録器で確認する。
final class SSHConfigScopeRecorder: Sendable {
  private struct State {
    var accessedURLs: [URL] = []
    var events: [String] = []
    var isActive = false
  }

  private let state = Mutex(State())

  var events: [String] { state.withLock { $0.events } }
  var accessedURLs: [URL] { state.withLock { $0.accessedURLs } }
  var isActive: Bool { state.withLock { $0.isActive } }

  func access(_ url: URL) -> (start: @Sendable () -> Bool, stop: @Sendable () -> Void) {
    state.withLock { $0.accessedURLs.append(url) }
    return (
      start: {
        self.state.withLock {
          $0.events.append("start")
          $0.isActive = true
        }
        return true
      },
      stop: {
        self.state.withLock {
          $0.events.append("stop")
          $0.isActive = false
        }
      }
    )
  }

  func record(_ event: String) {
    state.withLock { $0.events.append(event) }
  }

  func reset() {
    state.withLock { $0 = State() }
  }
}

func makeScopedSSHConfigReader(folderURL: URL, recorder: SSHConfigScopeRecorder)
  -> SSHConfigReader
{
  let data = Data("scoped-directory-fixture".utf8)
  let repository = SSHDirectoryAccessRepository(
    storage: ReaderSSHDirectoryBookmarkStorage(bookmarkData: data),
    codec: ReaderSSHDirectoryBookmarkCodec(resolvedBookmarkByData: [
      data: ResolvedFolderBookmark(url: folderURL, isStale: false)
    ]))
  return SSHConfigReader(
    homeDirectory: URL(filePath: "/Users/test"), accessRepository: repository,
    fileReader: { url in
      guard url == folderURL.appending(path: "config") else {
        throw CocoaError(.fileReadNoPermission)
      }
      return "Host fixture"
    }, scopedAccess: recorder.access)
}

private struct SSHConfigFileReaderStub: Sendable {
  enum Response: Sendable {
    case text(String)
    case cocoaNoPermission
    case posixEACCES
  }

  let responses: [URL: Response]

  func read(_ url: URL) throws -> String {
    guard let response = responses[url.standardizedFileURL] else {
      throw CocoaError(.fileNoSuchFile)
    }
    switch response {
    case .text(let text):
      return text
    case .cocoaNoPermission:
      throw CocoaError(.fileReadNoPermission)
    case .posixEACCES:
      throw POSIXError(.EACCES)
    }
  }
}

private final class ReaderSSHDirectoryBookmarkStorage: SSHDirectoryBookmarkStoring,
  @unchecked Sendable
{
  var bookmarkData: Data?

  init(bookmarkData: Data? = nil) {
    self.bookmarkData = bookmarkData
  }

  func loadBookmarkData() -> Data? {
    bookmarkData
  }

  func saveBookmarkData(_ data: Data) {
    bookmarkData = data
  }

  func removeBookmarkData() {
    bookmarkData = nil
  }
}

private struct ReaderSSHDirectoryBookmarkCodec: FolderBookmarkCoding {
  let resolvedBookmarkByData: [Data: ResolvedFolderBookmark]

  func createBookmark(for url: URL) throws -> Data {
    Data(url.path.utf8)
  }

  func resolveBookmark(_ data: Data) throws -> ResolvedFolderBookmark {
    try #require(resolvedBookmarkByData[data])
  }
}
