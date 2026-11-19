import Testing

/// 条件が真になるまでポーリングし、期限切れなら必ずIssueを記録する共通待機ヘルパー。
/// 黙る期限待機は2026-08-28テスト崩壊の増幅器(1件の失敗が数百件を巻き添え)だったため、
/// テスト内の期限待機はすべてこの関数へ委譲する。
@discardableResult
func waitUntil(
  timeout: Duration = .seconds(5),
  pollInterval: Duration = .milliseconds(5),
  _ message: @autoclosure @escaping () -> String = "期限までに条件を満たしませんでした",
  sourceLocation: SourceLocation = #_sourceLocation,
  isolation: isolated (any Actor)? = #isolation,
  condition: () async -> Bool
) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while !(await condition()) {
    if Task.isCancelled {
      return false
    }
    guard clock.now < deadline else {
      Issue.record(Comment(rawValue: message()), sourceLocation: sourceLocation)
      return false
    }
    do {
      try await Task.sleep(for: pollInterval)
    } catch {
      return false
    }
  }
  return true
}
