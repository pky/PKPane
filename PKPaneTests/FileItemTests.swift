import Foundation
import Testing
@testable import PKPane
struct FileItemTests {
  @Test("ローカルファイル項目の基本情報を保持する")
  func createsLocalFileItem() {
    let item = FileItem(url: URL(filePath: "/tmp/report.txt"), isDirectory: false, size: 12)
    #expect(item.name == "report.txt")
    #expect(item.isDirectory == false)
    #expect(item.size == 12)
  }

  @Test("詳細表示用のメタデータとリモートの場所を整形する")
  func formatsDetailMetadata() {
    let createdAt = Date(timeIntervalSince1970: 0)
    let item = FileItem(
      remotePath: "/srv/projects/report.txt",
      url: URL(string: "sftp://example.invalid/srv/projects/report.txt")!,
      providerID: FileProviderID(rawValue: "sftp-test"),
      isDirectory: false,
      createdAt: createdAt,
      tags: ["重要", "確認済み"],
      posixPermissions: 0o100640)

    #expect(item.displayParentPath == "/srv/projects")
    #expect(item.displayCreatedAt != "—")
    #expect(item.displayTags == "重要、確認済み")
    #expect(item.displayPermissions == "0640")
  }

  @Test("正規化済みURLと名前を指定したFileItemは標準イニシャライザと等しい")
  func normalizedInitializerMatchesStandardInitializer() {
    let url = URL(filePath: "/Users/tester/Documents", directoryHint: .isDirectory)
      .appending(path: "report.txt", directoryHint: .notDirectory)
    let standard = FileItem(url: url, isDirectory: false)
    let normalized = FileItem(
      normalizedLocalURL: url, name: "report.txt", isDirectory: false)
    #expect(standard == normalized)
  }

  @Test("複数選択の合計サイズはサイズ不明の項目を無視して判明分のみ合計する")
  func totalKnownSizeIgnoresUnknownSizes() {
    let items = [
      FileItem(url: URL(filePath: "/tmp/a.txt"), isDirectory: false, size: 100),
      FileItem(url: URL(filePath: "/tmp/b.txt"), isDirectory: false, size: nil),
      FileItem(url: URL(filePath: "/tmp/c.txt"), isDirectory: false, size: 50),
    ]
    #expect(items.totalKnownSize == 150)
  }

  @Test("空配列の合計サイズは0")
  func totalKnownSizeOfEmptyArrayIsZero() {
    let items: [FileItem] = []
    #expect(items.totalKnownSize == 0)
  }

  @Test("降順ソートは同値項目を互いに前とは判定せず入力順にも依存しない")
  func descendingSortUsesStrictDeterministicOrder() {
    let alpha = FileItem(
      url: URL(filePath: "/tmp/alpha.txt"), isDirectory: false, size: 100,
      modifiedAt: Date(timeIntervalSince1970: 100))
    let beta = FileItem(
      url: URL(filePath: "/tmp/beta.txt"), isDirectory: false, size: 100,
      modifiedAt: Date(timeIntervalSince1970: 100))

    for sortOrder in FileItemSortOrder.allCases {
      #expect(!sortOrder.areInIncreasingOrder(alpha, alpha, ascending: false))
    }

    let alphaFirst = FileItemFilter.filteredAndSorted(
      [alpha, beta], matching: "", matchMode: .literal, sortOrder: .size, ascending: false)
    let betaFirst = FileItemFilter.filteredAndSorted(
      [beta, alpha], matching: "", matchMode: .literal, sortOrder: .size, ascending: false)
    #expect(alphaFirst.map(\.url) == betaFirst.map(\.url))
  }

  @Test("localURLを持つ項目はサムネイルプレビュー対象")
  func localItemSupportsThumbnailPreview() {
    let item = FileItem(url: URL(filePath: "/tmp/report.txt"), isDirectory: false)
    #expect(item.supportsThumbnailPreview == true)
  }

  @Test("リモート項目はサムネイルプレビュー対象外")
  func remoteItemDoesNotSupportThumbnailPreview() {
    let item = FileItem(
      remotePath: "/srv/report.txt",
      url: URL(string: "sftp://example.invalid/srv/report.txt")!,
      providerID: FileProviderID(rawValue: "sftp-test"),
      isDirectory: false)
    #expect(item.supportsThumbnailPreview == false)
  }

  @Test("ローカルのフォルダはフォルダ内容走査に対応する")
  func localFolderSupportsFolderContentsScan() {
    let item = FileItem(
      url: URL(filePath: "/tmp/folder", directoryHint: .isDirectory), isDirectory: true)
    #expect(item.supportsFolderContentsScan == true)
  }

  @Test("リモートのフォルダはフォルダ内容走査に対応しない")
  func remoteFolderDoesNotSupportFolderContentsScan() {
    let item = FileItem(
      remotePath: "/srv/folder",
      url: URL(string: "sftp://example.invalid/srv/folder")!,
      providerID: FileProviderID(rawValue: "sftp-test"),
      isDirectory: true)
    #expect(item.supportsFolderContentsScan == false)
  }

  @Test("ローカルファイルはlocalURLのパスをクリップボード用パスとして返す")
  func pathForClipboardUsesLocalURLForLocalItems() {
    let item = FileItem(url: URL(filePath: "/tmp/report.txt"), isDirectory: false)
    #expect(item.pathForClipboard == "/tmp/report.txt")
  }

  @Test("リモートファイルはremotePathをクリップボード用パスとして返す")
  func pathForClipboardUsesRemotePathForRemoteItems() {
    let item = FileItem(
      remotePath: "/srv/report.txt",
      url: URL(string: "sftp://example.invalid/srv/report.txt")!,
      providerID: FileProviderID(rawValue: "sftp-test"),
      isDirectory: false)
    #expect(item.pathForClipboard == "/srv/report.txt")
  }
}
