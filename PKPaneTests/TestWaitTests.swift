import Testing

@testable import PKPane

struct TestWaitTests {
  @Test func 条件成立で真を返す() async {
    let satisfied = await waitUntil { true }
    #expect(satisfied)
  }

  @Test func 期限切れは黙らずIssueを記録して偽を返す() async {
    await withKnownIssue {
      let satisfied = await waitUntil(timeout: .milliseconds(50)) { false }
      #expect(satisfied == false)
    }
  }

  @Test func 遅延して成立する条件を拾う() async {
    let clock = ContinuousClock()
    let start = clock.now
    let satisfied = await waitUntil {
      clock.now - start > .milliseconds(30)
    }
    #expect(satisfied)
  }

  @Test func キャンセルされたらIssueを記録せず偽を返す() async {
    let task = Task {
      await waitUntil(timeout: .seconds(5)) { false }
    }
    task.cancel()
    let satisfied = await task.value
    #expect(satisfied == false)
  }
}
