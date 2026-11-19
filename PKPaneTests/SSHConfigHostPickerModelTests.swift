import Foundation
import Testing

@testable import PKPane

@MainActor
struct SSHConfigHostPickerModelTests {
  @Test("1000別名と200ブロックの候補事前計算は50ms以内に収まる")
  func precomputesThousandAliasesWithinBudget() {
    let blocks = (0..<200).map { block in
      SSHConfigHostBlock(
        patterns: (0..<5).map { "host\(block * 5 + $0)" },
        directives: [
          SSHConfigDirective(
            keyword: "hostname", value: "server\(block).example", line: block * 2 + 1),
          SSHConfigDirective(keyword: "user", value: "fixture", line: block * 2 + 2),
        ])
    }
    let document = SSHConfigDocument(
      blocks: blocks, warnings: [], baseDirectory: "/Users/test/.ssh")
    let folder = URL(filePath: "/Users/test/.ssh")
    let clock = ContinuousClock()
    var best = Duration.seconds(60)
    for _ in 0..<3 {
      let start = clock.now
      let model = SSHConfigHostPickerModel(document: document, folderURL: folder, initialQuery: "")
      best = min(best, start.duration(to: clock.now))
      #expect(model.results.count == 1000)
      #expect(model.results.first?.hostName == "server0.example")
      #expect(model.results.last?.alias == "host999")
      #expect(model.results.last?.hostName == "server199.example")
    }
    #expect(best < .milliseconds(50), "候補事前計算の最良値: \(best)")
  }

  @Test("ワイルドカードの多い1000別名と200ブロックの候補事前計算は50ms以内に収まる")
  func precomputesWildcardHeavyDocumentWithinBudget() {
    let wildcardPatterns = ["*.example", "host-?", "!internal"]
    let blocks = (0..<200).map { block in
      SSHConfigHostBlock(
        patterns: (0..<5).map { "host\(block * 5 + $0)" }
          + [wildcardPatterns[block % wildcardPatterns.count]],
        directives: [
          SSHConfigDirective(
            keyword: "hostname", value: "server\(block).example", line: block * 2 + 1),
          SSHConfigDirective(keyword: "user", value: "fixture", line: block * 2 + 2),
        ])
    }
    let document = SSHConfigDocument(
      blocks: blocks, warnings: [], baseDirectory: "/Users/test/.ssh")
    let folder = URL(filePath: "/Users/test/.ssh")
    let clock = ContinuousClock()
    var best = Duration.seconds(60)
    for _ in 0..<3 {
      let start = clock.now
      let model = SSHConfigHostPickerModel(document: document, folderURL: folder, initialQuery: "")
      best = min(best, start.duration(to: clock.now))
      #expect(model.results.count == 1000)
      #expect(model.results.first?.hostName == "server0.example")
      #expect(model.results.last?.alias == "host999")
      #expect(model.results.last?.hostName == "server199.example")
    }
    #expect(best < .milliseconds(50), "候補事前計算の最良値: \(best)")
  }

  @Test("入力ごとに候補を絞り込み前方一致を先に並べる")
  func incrementalSearchRanksPrefixFirst() {
    let model = SSHConfigHostPickerModel(
      document: hostDocument(),
      folderURL: URL(filePath: "/Users/test/.ssh", directoryHint: .isDirectory),
      initialQuery: "fil")

    #expect(model.results.map(\.alias) == ["files", "files-dev"])

    model.query = "dev"

    #expect(model.results.map(\.alias) == ["files-dev"])
  }

  @Test("選択した別名を解決済みの接続情報として確定する")
  func confirmReturnsResolvedResultForSelectedAlias() throws {
    let model = SSHConfigHostPickerModel(
      document: hostDocument(),
      folderURL: URL(filePath: "/Users/test/.ssh", directoryHint: .isDirectory),
      initialQuery: "files")
    model.selectedAlias = "files"

    let result = try #require(model.confirm())

    #expect(result.final.alias == "files")
    #expect(result.final.hostName == "files.example")
    #expect(result.final.port == 22)
    #expect(result.final.username == "tester")
    #expect(result.jumpHops.map(\.alias) == ["gateway"])
    #expect(result.jumpHops.map(\.hostName) == ["gateway.example"])
    #expect(result.jumpHops.map(\.username) == ["ops"])
  }

  @Test("別名を直接指定すると選択して解決する")
  func confirmingAliasDirectlySelectsAndResolves() throws {
    let model = SSHConfigHostPickerModel(
      document: hostDocument(),
      folderURL: URL(filePath: "/Users/test/.ssh", directoryHint: .isDirectory),
      initialQuery: "")

    let result = try #require(model.confirm(alias: "gateway"))

    #expect(model.selectedAlias == "gateway")
    #expect(result.final.alias == "gateway")
  }

  @Test("候補にない別名を直接指定すると選択を変えずnilを返す")
  func confirmingUnknownAliasReturnsNil() {
    let model = SSHConfigHostPickerModel(
      document: hostDocument(),
      folderURL: URL(filePath: "/Users/test/.ssh", directoryHint: .isDirectory),
      initialQuery: "")
    model.selectedAlias = "files"

    #expect(model.confirm(alias: "nope") == nil)
    #expect(model.selectedAlias == "files")
  }

  @Test("選択を候補の上下へ移動する")
  func moveSelectionMovesUpAndDown() {
    let model = SSHConfigHostPickerModel(
      document: hostDocument(),
      folderURL: URL(filePath: "/Users/test/.ssh", directoryHint: .isDirectory),
      initialQuery: "")

    #expect(model.selectedAlias == "gateway")

    model.moveSelection(by: 1)
    #expect(model.selectedAlias == "files")

    model.moveSelection(by: -1)
    #expect(model.selectedAlias == "gateway")
  }

  @Test("選択移動は候補の両端を越えない")
  func moveSelectionStopsAtBoundaries() {
    let model = SSHConfigHostPickerModel(
      document: hostDocument(),
      folderURL: URL(filePath: "/Users/test/.ssh", directoryHint: .isDirectory),
      initialQuery: "")

    model.moveSelection(by: -1)
    #expect(model.selectedAlias == "gateway")

    model.moveSelection(by: 1)
    model.moveSelection(by: 1)
    model.moveSelection(by: 1)
    #expect(model.selectedAlias == "files-dev")
  }

  private func hostDocument() -> SSHConfigDocument {
    SSHConfigParser.parse(
      """
      Host gateway
        HostName gateway.example
        User ops
      Host files
        HostName files.example
        User tester
        ProxyJump gateway
      Host files-dev
        HostName development.example
        User developer
      """,
      includeResolver: { _ in [] },
      baseDirectory: "/Users/test/.ssh")
  }
}
