import Foundation
import Testing

@testable import PKPane

struct TestDescriptionsTests {
  @Test @MainActor func セッションのテスト表示は再帰リフレクションを走らせない短文() {
    let provider = LocalFileProvider()
    let session = FileBrowserSession(
      provider: provider,
      initialLocation: FileLocation(
        localURL: URL(filePath: NSHomeDirectory()),
        providerID: provider.id),
      transferQueue: .isolatedForTesting())
    #expect((session as any CustomTestStringConvertible).testDescription == "FileBrowserSession")
  }
}
