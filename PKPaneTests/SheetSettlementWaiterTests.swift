import Foundation
import Testing

@testable import PKPane

/// 呼び出し回数と待ち時間の引数を記録する。実時間は使わない。
@MainActor
private final class WaiterProbe {
  private(set) var attachedCalls = 0
  private(set) var sleeps: [Duration] = []
  private let attachedWhile: @MainActor (Int) -> Bool

  /// `attachedWhile` には何回目の確認か(1始まり)を渡し、シートが付いているかを返す。
  init(attachedWhile: @escaping @MainActor (Int) -> Bool) {
    self.attachedWhile = attachedWhile
  }

  func isSheetAttached() -> Bool {
    attachedCalls += 1
    return attachedWhile(attachedCalls)
  }

  func sleep(_ duration: Duration) {
    sleeps.append(duration)
  }
}

@MainActor
struct SheetSettlementWaiterTests {
  @Test("W1: シートが無ければ待たずにtrueを返す")
  func returnsImmediatelyWhenNoSheetIsAttached() async {
    let probe = WaiterProbe { _ in false }

    let settled = await SheetSettlementWaiter.wait(
      isSheetAttached: { probe.isSheetAttached() },
      sleep: { probe.sleep($0) })

    #expect(settled)
    #expect(probe.attachedCalls == 1)
    #expect(probe.sleeps.isEmpty)
  }

  @Test("W2: シートが消えるまで間隔ごとに再確認してtrueを返す")
  func pollsAtIntervalUntilSheetDisappears() async {
    let probe = WaiterProbe { $0 <= 3 }

    let settled = await SheetSettlementWaiter.wait(
      isSheetAttached: { probe.isSheetAttached() },
      timeout: .seconds(2),
      interval: .milliseconds(50),
      sleep: { probe.sleep($0) })

    #expect(settled)
    #expect(probe.attachedCalls == 4)
    #expect(probe.sleeps == Array(repeating: .milliseconds(50), count: 3))
  }

  @Test("W3: シートが残り続けたら上限で諦めてfalseを返す")
  func givesUpAfterTimeoutWhileSheetStaysAttached() async {
    let probe = WaiterProbe { _ in true }

    let settled = await SheetSettlementWaiter.wait(
      isSheetAttached: { probe.isSheetAttached() },
      timeout: .milliseconds(200),
      interval: .milliseconds(50),
      sleep: { probe.sleep($0) })

    #expect(!settled)
    #expect(probe.sleeps.count == 4)
    #expect(probe.attachedCalls == 5)
  }

  @Test("W4: フェイクのsleepでは実時間を使わず1秒以内に終わる")
  func doesNotDependOnWallClockTime() async {
    let clock = ContinuousClock()
    let start = clock.now

    let neverSettles = WaiterProbe { _ in true }
    _ = await SheetSettlementWaiter.wait(
      isSheetAttached: { neverSettles.isSheetAttached() },
      sleep: { neverSettles.sleep($0) })
    let settlesLater = WaiterProbe { $0 <= 3 }
    _ = await SheetSettlementWaiter.wait(
      isSheetAttached: { settlesLater.isSheetAttached() },
      sleep: { settlesLater.sleep($0) })
    let noSheet = WaiterProbe { _ in false }
    _ = await SheetSettlementWaiter.wait(
      isSheetAttached: { noSheet.isSheetAttached() },
      sleep: { noSheet.sleep($0) })

    #expect(start.duration(to: clock.now) < .seconds(1))
    // 既定値(timeout 2秒 / interval 50ms)では上限までのsleepがちょうど40回になる。
    #expect(neverSettles.sleeps.count == 40)
  }
}
