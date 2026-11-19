import AppKit

/// シートが消えきるまで待つ。onDismiss はシートが消えきる前に呼ばれることがあり、
/// その直後に出す別のシートやダイアログが閉じかけのシートと重なって潰れるのを避ける。
enum SheetSettlementWaiter {
  /// シートが無くなれば true、`timeout` まで残り続けたら false を返す。
  @MainActor
  static func wait(
    isSheetAttached: () -> Bool,
    timeout: Duration = .seconds(2),
    interval: Duration = .milliseconds(50),
    sleep: (Duration) async -> Void = { try? await Task.sleep(for: $0) }
  ) async -> Bool {
    var elapsed = Duration.zero
    while isSheetAttached() {
      if elapsed >= timeout { return false }
      await sleep(interval)
      elapsed += interval
    }
    return true
  }

  @MainActor
  static func anyWindowHasAttachedSheet() -> Bool {
    NSApp.windows.contains { $0.attachedSheet != nil }
  }
}
