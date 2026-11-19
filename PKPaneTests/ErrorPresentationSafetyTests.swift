import Foundation
import Testing

@testable import PKPane

struct ErrorPresentationSafetyTests {
  @Test("プロダクションコードの生エラー文字列は統制された入口だけで扱う")
  func rawLocalizedDescriptionsStayInsideApprovedSources() throws {
    let repositoryRoot = URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceRoot = repositoryRoot.appending(path: "PKPane", directoryHint: .isDirectory)
    let approvedFiles: Set<String> = [
      "Domain/ConnectionTest/ConnectionErrorClassifier.swift",
      "Domain/Errors/PKPaneErrorClassifier.swift",
      "Domain/Errors/SecretMasker.swift",
    ]
    let enumerator = try #require(
      FileManager.default.enumerator(
        at: sourceRoot,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]))
    var violations: [String] = []

    for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
      let relativePath = String(fileURL.path.dropFirst(sourceRoot.path.count + 1))
      guard !approvedFiles.contains(relativePath) else { continue }
      let source = try String(contentsOf: fileURL, encoding: .utf8)
      if source.contains("localizedDescription") {
        violations.append(relativePath)
      }
    }

    #expect(violations.sorted().isEmpty, "違反ファイル: \(violations.sorted())")
  }
}
