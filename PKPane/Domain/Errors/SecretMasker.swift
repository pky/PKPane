import Foundation

enum SecretMasker {
  private static let userHomePathExpression = try! NSRegularExpression(
    pattern: #"/Users/[^/\s"'）)]+"#)
  private static let urlHomePathExpression = try! NSRegularExpression(
    pattern: #"(://[^/\s]+)~"#)
  private static let urlUserInfoExpression = try! NSRegularExpression(
    pattern: #"([A-Za-z][A-Za-z0-9+.-]*://)[^/\s]+@"#)
  private static let userAndHostExpression = try! NSRegularExpression(
    pattern: #"\S+@\S+"#)
  private static let cloudRootNameExpression = try! NSRegularExpression(
    pattern: #"(?<=/CloudStorage/)[^/\r\n"']+"#)

  static func maskHomeDirectory(_ text: String, homePath: String = NSHomeDirectory()) -> String {
    let homeMasked = homePath.isEmpty ? text : text.replacingOccurrences(of: homePath, with: "~")
    let usersMasked = replacingMatches(
      in: homeMasked,
      expression: userHomePathExpression,
      with: "~")
    return replacingMatches(
      in: usersMasked,
      expression: urlHomePathExpression,
      with: "$1/~")
  }

  static func maskURLUserInfo(_ text: String) -> String {
    replacingMatches(
      in: text,
      expression: urlUserInfoExpression,
      with: "$1")
  }

  static func maskForDisplay(_ text: String) -> String {
    replacingMatches(
      in: maskURLUserInfo(maskHomeDirectory(text)),
      expression: cloudRootNameExpression,
      with: "[cloud]")
  }

  static func maskForDisplay(_ error: Error) -> String {
    maskForDisplay(error.localizedDescription)
  }

  static func maskForLog(_ text: String) -> String {
    replacingMatches(
      in: maskForDisplay(text),
      expression: userAndHostExpression,
      with: "***@***")
  }

  private static func replacingMatches(
    in text: String,
    expression: NSRegularExpression,
    with template: String
  ) -> String {
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return expression.stringByReplacingMatches(
      in: text,
      range: range,
      withTemplate: template)
  }
}
