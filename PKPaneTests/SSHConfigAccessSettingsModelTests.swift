import Foundation
import Testing

@testable import PKPane

@MainActor
struct SSHConfigAccessSettingsModelTests {
  @Test("フォルダBookmarkの保存失敗は分類済みエラーで通知する")
  func chooseFolderSaveFailureIsReported() throws {
    let folder = URL(filePath: "/Selected/.ssh")
    let fixturePath = "/Users/someone/.ssh/config"
    let failure = NSError(
      domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
      userInfo: [NSLocalizedDescriptionKey: "保存失敗: \(fixturePath)"])
    let storage = SettingsSSHDirectoryBookmarkStorage()
    let repository = SSHDirectoryAccessRepository(
      storage: storage,
      codec: SettingsSSHDirectoryBookmarkCodec(createError: failure))
    let model = SSHConfigAccessSettingsModel(
      reader: makeReader(repository: repository, permitsDirectRead: false), repository: repository
    )

    model.chooseFolder(folder)

    let message = try #require(model.errorMessage)
    #expect(message == PKPaneErrorClassifier.classify(failure).displayMessage)
    #expect(!message.contains("/Users/"))
    #expect(model.state == .unavailable)
    #expect(storage.saveCount == 0)
    #expect(storage.bookmarkData == nil)
  }

  @Test(
    "初期状態はReaderのアクセス状態を反映する",
    arguments: [
      SSHConfigAccessState.direct,
      .bookmarked(URL(filePath: "/Selected/.ssh", directoryHint: .isDirectory)),
      .unavailable,
    ])
  func initialStateReflectsReaderAccessState(expectedState: SSHConfigAccessState) {
    let folderURL = URL(filePath: "/Selected/.ssh", directoryHint: .isDirectory)
    let storage = SettingsSSHDirectoryBookmarkStorage(
      bookmarkData: expectedState == .bookmarked(folderURL)
        ? Data(folderURL.absoluteString.utf8) : nil)
    let repository = SSHDirectoryAccessRepository(
      storage: storage, codec: SettingsSSHDirectoryBookmarkCodec())
    let reader = makeReader(repository: repository, permitsDirectRead: expectedState == .direct)

    let model = SSHConfigAccessSettingsModel(reader: reader, repository: repository)

    #expect(reader.accessState() == expectedState)
    #expect(model.state == expectedState)
  }

  @Test("フォルダ選択でBookmarkを保存し選択済み状態へ移る")
  func chooseFolderSavesBookmarkAndUpdatesState() throws {
    let folderURL = URL(filePath: "/Selected/.ssh", directoryHint: .isDirectory)
    let storage = SettingsSSHDirectoryBookmarkStorage()
    let repository = SSHDirectoryAccessRepository(
      storage: storage, codec: SettingsSSHDirectoryBookmarkCodec())
    let reader = makeReader(repository: repository, permitsDirectRead: false)
    let model = SSHConfigAccessSettingsModel(reader: reader, repository: repository)
    #expect(model.state == .unavailable)

    model.chooseFolder(folderURL)

    #expect(storage.saveCount == 1)
    #expect(try repository.restore() == folderURL)
    #expect(model.state == .bookmarked(folderURL))
  }

  @Test("解除で保存済みBookmarkを削除し未設定状態へ移る")
  func revokeRemovesBookmarkAndUpdatesState() throws {
    let folderURL = URL(filePath: "/Selected/.ssh", directoryHint: .isDirectory)
    let storage = SettingsSSHDirectoryBookmarkStorage(
      bookmarkData: Data(folderURL.absoluteString.utf8))
    let repository = SSHDirectoryAccessRepository(
      storage: storage, codec: SettingsSSHDirectoryBookmarkCodec())
    let reader = makeReader(repository: repository, permitsDirectRead: false)
    let model = SSHConfigAccessSettingsModel(reader: reader, repository: repository)
    #expect(model.state == .bookmarked(folderURL))

    model.revoke()

    #expect(storage.removeCount == 1)
    #expect(storage.bookmarkData == nil)
    #expect(try repository.restore() == nil)
    #expect(model.state == .unavailable)
  }

  @Test("直接アクセス中の解除は保存先に触れず状態とBookmarkを保持する")
  func revokeDoesNotTouchRepositoryWhenAccessIsDirect() {
    let folderURL = URL(filePath: "/Selected/.ssh", directoryHint: .isDirectory)
    let bookmarkData = Data(folderURL.absoluteString.utf8)
    let storage = SettingsSSHDirectoryBookmarkStorage(bookmarkData: bookmarkData)
    let repository = SSHDirectoryAccessRepository(
      storage: storage, codec: SettingsSSHDirectoryBookmarkCodec())
    let reader = makeReader(repository: repository, permitsDirectRead: true)
    let model = SSHConfigAccessSettingsModel(reader: reader, repository: repository)
    #expect(model.state == .direct)
    let loadCount = storage.loadCount
    let saveCount = storage.saveCount
    let removeCount = storage.removeCount

    model.revoke()

    #expect(model.state == .direct)
    #expect(storage.bookmarkData == bookmarkData)
    #expect(storage.loadCount == loadCount)
    #expect(storage.saveCount == saveCount)
    #expect(storage.removeCount == removeCount)
  }

  private func makeReader(
    repository: SSHDirectoryAccessRepository,
    permitsDirectRead: Bool
  ) -> SSHConfigReader {
    SSHConfigReader(
      homeDirectory: URL(filePath: "/Users/test", directoryHint: .isDirectory),
      accessRepository: repository,
      fileReader: SettingsSSHConfigFileReaderStub(permitsDirectRead: permitsDirectRead).read)
  }
}

private struct SettingsSSHConfigFileReaderStub: Sendable {
  let permitsDirectRead: Bool

  func read(_ url: URL) throws -> String {
    guard permitsDirectRead else { throw CocoaError(.fileReadNoPermission) }
    return "Host test"
  }
}

private final class SettingsSSHDirectoryBookmarkStorage: SSHDirectoryBookmarkStoring {
  var bookmarkData: Data?
  private(set) var loadCount = 0
  private(set) var saveCount = 0
  private(set) var removeCount = 0

  init(bookmarkData: Data? = nil) {
    self.bookmarkData = bookmarkData
  }

  func loadBookmarkData() -> Data? {
    loadCount += 1
    return bookmarkData
  }

  func saveBookmarkData(_ data: Data) {
    saveCount += 1
    bookmarkData = data
  }

  func removeBookmarkData() {
    removeCount += 1
    bookmarkData = nil
  }
}

private struct SettingsSSHDirectoryBookmarkCodec: FolderBookmarkCoding {
  var createError: NSError? = nil

  func createBookmark(for url: URL) throws -> Data {
    if let createError { throw createError }
    return Data(url.absoluteString.utf8)
  }

  func resolveBookmark(_ data: Data) throws -> ResolvedFolderBookmark {
    let absoluteString = try #require(String(data: data, encoding: .utf8))
    let url = try #require(URL(string: absoluteString))
    return ResolvedFolderBookmark(url: url, isStale: false)
  }
}
