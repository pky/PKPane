import Foundation
import Testing

@testable import PKPane

struct CacheDefaultURLTests {
  private let testEnvironment = ["XCTestConfigurationFilePath": "/tmp/dummy.xctestconfiguration"]
  private let productionEnvironment: [String: String] = [:]

  @Test func アーカイブ展開キャッシュはテスト実行時にプロセス毎一時パスを使う() {
    let url = ArchiveExtractionCache.defaultRootURL(environment: testEnvironment)
    #expect(url.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    #expect(url.path.contains("\(ProcessInfo.processInfo.processIdentifier)"))
  }

  @Test func アーカイブ展開キャッシュは通常実行時にApplicationSupportを使う() {
    let url = ArchiveExtractionCache.defaultRootURL(environment: productionEnvironment)
    #expect(url.path.contains("Application Support"))
    #expect(url.path.contains("ArchivePreviews"))
  }

  @Test func リモートプレビューキャッシュはテスト実行時にプロセス毎一時パスを使う() {
    let url = RemotePreviewCache.defaultRootURL(environment: testEnvironment)
    #expect(url.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    #expect(url.path.contains("\(ProcessInfo.processInfo.processIdentifier)"))
  }

  @Test func リモートプレビューキャッシュは通常実行時にApplicationSupportを使う() {
    let url = RemotePreviewCache.defaultRootURL(environment: productionEnvironment)
    #expect(url.path.contains("Application Support"))
    #expect(url.path.contains("RemotePreviews"))
  }

  @Test @MainActor func リモート編集はテスト実行時にプロセス毎一時パスを使う() {
    let url = RemoteEditController.defaultRootURL(environment: testEnvironment)
    #expect(url.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    #expect(url.path.contains("\(ProcessInfo.processInfo.processIdentifier)"))
  }

  @Test @MainActor func リモート編集は通常実行時にApplicationSupportを使う() {
    let url = RemoteEditController.defaultRootURL(environment: productionEnvironment)
    #expect(url.path.contains("Application Support"))
    #expect(url.path.contains("RemoteEdits"))
  }
}
