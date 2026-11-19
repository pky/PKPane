import Foundation
import Testing

@testable import PKPane

struct TransferJobStoreDefaultURLTests {
  @Test("テスト環境の既定URLは一時ディレクトリ配下のプロセス毎パスになる")
  func defaultURLUnderTestEnvironmentIsPerProcessTemporaryPath() {
    let url = JSONTransferJobStore.defaultURL(
      environment: ["XCTestConfigurationFilePath": "/tmp/config.xctestconfiguration"])

    let temporaryPath = FileManager.default.temporaryDirectory.path
    #expect(url.path.hasPrefix(temporaryPath))
    #expect(!url.path.contains("Application Support"))
    #expect(url.path.contains(String(ProcessInfo.processInfo.processIdentifier)))
  }

  @Test("非テスト環境の既定URLはApplication Support配下の共有パスになる")
  func defaultURLWithoutTestEnvironmentIsApplicationSupportPath() {
    let url = JSONTransferJobStore.defaultURL(environment: [:])

    #expect(url.path.hasSuffix("PKPane/transfer-jobs.json"))
    #expect(url.path.contains("Application Support"))
  }

  @Test("テストランナー内で生成した既定ストアは実ユーザーの保存先へ触れない")
  func defaultStoreInsideTestRunnerDoesNotTouchRealUserFile() {
    let store = JSONTransferJobStore()

    #expect(!store.url.path.contains("Application Support"))
  }
}
