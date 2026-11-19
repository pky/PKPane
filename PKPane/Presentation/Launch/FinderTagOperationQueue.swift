import Foundation

/// セッションを跨ぐタグ操作を、スレッドを塞がず読取から書込まで直列化する。
@MainActor
final class FinderTagOperationQueue {
  static let shared = FinderTagOperationQueue()
  private var tail: Task<FinderTagUpdateResult, Never>?
  private var tailID: UUID?

  func perform(
    items: [FileItem],
    operation: @escaping @MainActor () async -> FinderTagUpdateResult
  ) async -> FinderTagUpdateResult {
    let predecessor = tail
    let id = UUID()
    let task = Task { @MainActor in
      _ = await predecessor?.value
      guard !Task.isCancelled else {
        return FinderTagUpdateResult(
          items: items, failedCount: items.count,
          firstErrorDescription: PKPaneErrorClassifier.classify(CancellationError()).displayMessage)
      }
      return await operation()
    }
    tail = task
    tailID = id
    let result = await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
    // 後続が繋がっている場合はその参照を残し、最新の完了だけで保持を解放する。
    if tailID == id {
      tail = nil
      tailID = nil
    }
    return result
  }
}
