import Testing

@testable import PKPane

@MainActor
struct SelectionGenerationTrackerTests {
  @Test("世代を進めるたびに新しい番号を発行する")
  func advanceIssuesIncrementingGenerations() {
    let tracker = SelectionGenerationTracker()

    #expect(tracker.advance() == 1)
    #expect(tracker.advance() == 2)
    #expect(tracker.advance() == 3)
  }

  @Test("最新の世代だけがisCurrentでtrueになる")
  func isCurrentOnlyMatchesLatestGeneration() {
    let tracker = SelectionGenerationTracker()
    let first = tracker.advance()
    let second = tracker.advance()

    #expect(tracker.isCurrent(first) == false)
    #expect(tracker.isCurrent(second) == true)
  }

  /// 選択を連打した状況(世代を立て続けに進める)を模し、最新以外の世代の結果は
  /// すべて「破棄すべき」と判定されることを確認する。
  @Test("連続した選択変更では最新の世代だけが結果を反映してよいと判定される")
  func rapidSelectionChangesDiscardStaleGenerations() throws {
    let tracker = SelectionGenerationTracker()
    let generations = (0..<5).map { _ in tracker.advance() }

    let staleResultsThatWouldWronglyApply = generations.dropLast().filter { tracker.isCurrent($0) }

    #expect(staleResultsThatWouldWronglyApply.isEmpty)
    let latestGeneration = try #require(generations.last)
    #expect(tracker.isCurrent(latestGeneration))
  }
}
