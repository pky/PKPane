import Testing

@testable import PKPane

struct LaunchContentTests {
  @Test("初期画面にフォルダ選択の案内を表示する")
  func initialContentGuidesFolderSelection() {
    let content = LaunchContent.initial

    #expect(content.windowTitle == "フォルダを選択")
    #expect(content.windowTitle != "PKPane")
    #expect(content.title == "フォルダを選択")
    #expect(content.message == "ローカルまたはNASのフォルダを選択して開始します。")
  }
}
