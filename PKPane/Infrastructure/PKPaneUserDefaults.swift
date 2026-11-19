import Foundation

/// アプリ全体のUserDefaults解決。テスト実行が実ユーザー設定を汚染しないよう、
/// UIテストは固定suite、ユニットテストはプロセス毎suiteへ隔離する
/// (2026-08-28テスト崩壊の教訓: テストから実ユーザーパスへの書き込みは汚染バグ)。
enum PKPaneUserDefaults {
  static func resolve(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> UserDefaults {
    if environment["PKPANE_UI_TESTING"] == "1" {
      return UserDefaults(suiteName: "com.pky.PKPane.ui-tests") ?? .standard
    }
    if TestEnvironmentDetector.isRunningTests(environment: environment) {
      return unitTestDefaults
    }
    return .standard
  }

  private static let unitTestSuiteName =
    "com.pky.PKPane.unit-tests.\(ProcessInfo.processInfo.processIdentifier)"

  private static nonisolated(unsafe) let unitTestDefaults: UserDefaults = {
    let defaults = UserDefaults(suiteName: unitTestSuiteName) ?? .standard
    atexit_b {
      UserDefaults().removePersistentDomain(forName: unitTestSuiteName)
    }
    return defaults
  }()
}
