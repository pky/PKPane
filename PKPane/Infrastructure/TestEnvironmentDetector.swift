import Foundation

/// テストランナー(XCTest/Swift Testing)内での実行かどうかを環境変数から判定する。
/// テスト実行時は実ユーザーのApplication Supportへ書き込むべきではない既定パス
/// (転送履歴・アーカイブ展開キャッシュ・リモートプレビューキャッシュなど)が
/// この判定を共有し、プロセス毎の一時パスへ切り替える。
enum TestEnvironmentDetector {
  static func isRunningTests(environment: [String: String]) -> Bool {
    environment["XCTestConfigurationFilePath"] != nil
      || environment["XCTestSessionIdentifier"] != nil
  }
}
