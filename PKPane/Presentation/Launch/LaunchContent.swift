struct LaunchContent: Equatable, Sendable {
  let title: String
  let message: String

  var windowTitle: String {
    title
  }

  static let initial = LaunchContent(
    title: "フォルダを選択",
    message: "ローカルまたはNASのフォルダを選択して開始します。"
  )
}
