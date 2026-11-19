import Foundation
import Testing

@testable import PKPane

struct PKPaneUserDefaultsTests {
  @Test func ユニットテスト実行時はstandardを返さない() {
    let defaults = PKPaneUserDefaults.resolve(
      environment: ["XCTestConfigurationFilePath": "/tmp/dummy.xctestconfiguration"])
    #expect(defaults !== UserDefaults.standard)
  }

  @Test func uiテスト実行時は専用suiteを返す() {
    let defaults = PKPaneUserDefaults.resolve(environment: ["PKPANE_UI_TESTING": "1"])
    #expect(defaults !== UserDefaults.standard)
  }

  @Test func 通常実行時はstandardを返す() {
    let defaults = PKPaneUserDefaults.resolve(environment: [:])
    #expect(defaults === UserDefaults.standard)
  }

  @Test func ユニットテスト実行時のsuiteはプロセス毎() {
    let defaults = PKPaneUserDefaults.resolve(
      environment: ["XCTestConfigurationFilePath": "/tmp/dummy.xctestconfiguration"])
    defaults.set("probe", forKey: "PKPaneUserDefaultsTests.probe")
    #expect(UserDefaults.standard.string(forKey: "PKPaneUserDefaultsTests.probe") == nil)
    defaults.removeObject(forKey: "PKPaneUserDefaultsTests.probe")
  }
}
