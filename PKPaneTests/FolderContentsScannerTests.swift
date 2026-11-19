import Foundation
import Testing

@testable import PKPane

struct FolderContentsScannerTests {
  @Test("フォルダ配下のファイルサイズと件数を再帰合計する")
  func scanSumsSizeAndCountRecursively() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "scan-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try Data(repeating: 0, count: 10).write(to: root.appending(path: "a.txt"))
    let subdirectory = root.appending(path: "sub", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
    try Data(repeating: 0, count: 20).write(to: subdirectory.appending(path: "b.txt"))

    let token = FolderContentsScanner.CancellationToken()
    let summary = try FolderContentsScanner.scan(at: root, cancellationToken: token)

    #expect(summary.totalSize == 30)
    // ファイル2件 + サブフォルダ1件 = 3項目
    #expect(summary.itemCount == 3)
  }

  @Test("空フォルダはサイズ0・件数0を返す")
  func scanOfEmptyFolderReturnsZero() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "scan-empty-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let token = FolderContentsScanner.CancellationToken()
    let summary = try FolderContentsScanner.scan(at: root, cancellationToken: token)

    #expect(summary.totalSize == 0)
    #expect(summary.itemCount == 0)
  }

  @Test("キャンセル済みトークンで走査を開始すると即座にCancellationErrorを投げる")
  func scanThrowsWhenAlreadyCancelled() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "scan-cancel-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(repeating: 0, count: 10).write(to: root.appending(path: "a.txt"))

    let token = FolderContentsScanner.CancellationToken()
    token.cancel()

    #expect(throws: CancellationError.self) {
      try FolderContentsScanner.scan(at: root, cancellationToken: token)
    }
  }
}
