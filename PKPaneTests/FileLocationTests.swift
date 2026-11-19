import Foundation
import Testing

@testable import PKPane

struct FileLocationTests {
  @Test("ローカル位置はProviderと標準化URLを保持する")
  func createsLocalLocation() {
    let location = FileLocation(localURL: URL(filePath: "/tmp/../tmp/report.txt"))

    #expect(location.providerID == .local)
    #expect(location.localURL == URL(filePath: "/tmp/report.txt"))
    #expect(location.remotePath == nil)
  }

  @Test("リモート位置はProviderとパスを保持する")
  func createsRemoteLocation() {
    let providerID = FileProviderID(rawValue: "sftp-profile-1")
    let location = FileLocation(remotePath: "/documents/report.txt", providerID: providerID)

    #expect(location.providerID == providerID)
    #expect(location.localURL == nil)
    #expect(location.remotePath == "/documents/report.txt")
  }

  @Test("転送先の子要素をローカルとリモートで共通に組み立てる")
  func appendsPathComponentForEachLocationKind() {
    let providerID = FileProviderID(rawValue: "sftp-profile-1")

    #expect(
      FileLocation(localURL: URL(filePath: "/tmp/archive"))
        .appending(pathComponent: "report.txt")
        == FileLocation(localURL: URL(filePath: "/tmp/archive/report.txt")))
    #expect(
      FileLocation(remotePath: ".", providerID: providerID)
        .appending(pathComponent: "report.txt")?.remotePath
        == "./report.txt")
    #expect(
      FileLocation(remotePath: "/archive", providerID: providerID)
        .appending(pathComponent: "report.txt")?.remotePath
        == "/archive/report.txt")
    #expect(
      FileLocation(remotePath: "/", providerID: providerID)
        .appending(pathComponent: "../x") == nil)
  }

  @Test("ローカルProviderの操作能力を公開する")
  func exposesLocalProviderCapabilities() {
    let capabilities = LocalFileProvider().capabilities

    #expect(capabilities.contains([.read, .write, .trash, .observeChanges]))
    #expect(capabilities.contains(.cloudDownloadStatus))
    #expect(!capabilities.contains(.resumeTransfer))
  }

  @Test("iCloudのダウンロード状態を表示用の値型へ変換する")
  func convertsCloudDownloadStatuses() {
    #expect(
      CloudDownloadStatus(URLUbiquitousItemDownloadingStatus.notDownloaded) == .notDownloaded)
    #expect(CloudDownloadStatus(URLUbiquitousItemDownloadingStatus.downloaded) == .downloaded)
    #expect(CloudDownloadStatus(URLUbiquitousItemDownloadingStatus.current) == .current)
  }

  @Test("クラウド管理フォルダをパスとubiquitous属性で判定する")
  func detectsCloudManagedFolders() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "CloudDownloadStatusTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appending(path: "home", directoryHint: .isDirectory)
    let mobileDocuments = home.appending(
      path: "Library/Mobile Documents", directoryHint: .isDirectory)
    let cloudStorage = home.appending(path: "Library/CloudStorage", directoryHint: .isDirectory)
    let ordinary = home.appending(path: "Downloads", directoryHint: .isDirectory)
    let linkedMobileDocuments = root.appending(path: "linked-mobile", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: mobileDocuments, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: cloudStorage, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: ordinary, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: linkedMobileDocuments, withDestinationURL: mobileDocuments)

    let cases: [(URL, Bool, Bool)] = [
      (ordinary, false, false),
      (
        mobileDocuments.appending(path: "com.example.app", directoryHint: .isDirectory), false, true
      ),
      (cloudStorage.appending(path: "iCloud Drive", directoryHint: .isDirectory), false, true),
      (linkedMobileDocuments, false, true),
      (ordinary, true, true),
    ]

    for (folderURL, ubiquitous, expected) in cases {
      #expect(
        isCloudManagedFolder(folderURL, homeDirectory: home, isUbiquitousItem: { _ in ubiquitous })
          == expected)
    }
  }

  @Test("正規化済みURL用イニシャライザは標準イニシャライザと同じ値になる")
  func normalizedInitializerMatchesStandardInitializer() {
    let url = URL(filePath: "/Users/tester/Documents/report.txt")
    let standard = FileLocation(localURL: url)
    let normalized = FileLocation(normalizedLocalURL: url.standardizedFileURL)
    #expect(standard == normalized)
    #expect(standard.hashValue == normalized.hashValue)
  }

  @Test("ローカルディレクトリ位置はシンボリックリンクを解決して同値にする")
  func normalizesDirectorySymlink() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(
        path: "FileLocationTests-\(UUID().uuidString)",
        directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }

    let actualDirectory = root.appending(path: "actual", directoryHint: .isDirectory)
    let linkedDirectory = root.appending(path: "linked", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: actualDirectory, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: linkedDirectory, withDestinationURL: actualDirectory)

    #expect(
      FileLocation(directoryURL: actualDirectory)
        == FileLocation(directoryURL: linkedDirectory))
  }
}
