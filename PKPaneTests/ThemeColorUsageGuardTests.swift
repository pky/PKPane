import Foundation
import Testing

@testable import PKPane

struct ThemeColorUsageGuardTests {
  @Test("テーマ外の表示コードはアクセントと状態色を直書きしない")
  func presentationColorsStayInsideTheme() throws {
    let repositoryRoot = URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceRoot = repositoryRoot.appending(
      path: "PKPane/Presentation", directoryHint: .isDirectory)
    let approvedFiles: Set<String> = []
    let patterns = [
      #"\bColor\s*\.\s*(?:red|blue|green|orange|yellow)\b"#,
      #"\.\s*foreground(?:Style|Color)\s*\(\s*\.\s*(?:red|blue|green|orange|yellow)\b"#,
      #"\bColor\s*\.\s*accentColor\s*\.\s*opacity\s*\("#,
    ]
    let expressions = try patterns.map { try NSRegularExpression(pattern: $0) }
    let enumerator = try #require(
      FileManager.default.enumerator(
        at: sourceRoot,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]))
    var violations: [String] = []

    for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
      let relativePath = String(fileURL.path.dropFirst(sourceRoot.path.count + 1))
      guard !relativePath.hasPrefix("Theme/"), !approvedFiles.contains(relativePath) else {
        continue
      }
      let source = try String(contentsOf: fileURL, encoding: .utf8)
      let range = NSRange(source.startIndex..<source.endIndex, in: source)

      for expression in expressions {
        for match in expression.matches(in: source, range: range) {
          let matchRange = try #require(Range(match.range, in: source))
          let line = source[..<matchRange.lowerBound].filter { $0 == "\n" }.count + 1
          violations.append("\(relativePath):\(line): \(source[matchRange])")
        }
      }
    }

    #expect(violations.isEmpty, "色の直書き: \(violations.sorted())")
  }
}
