import Foundation

/// 選択変更のたびに増分する世代番号を管理する。非同期処理(詳細取得・サムネイル生成)の
/// 結果を反映する直前に、開始時点で発行された世代がまだ最新かどうかを確認することで、
/// 選択を連打したときに古い結果が新しい選択の表示を上書きしてしまう競合を防ぐ。
/// FolderContentsScanner.CancellationTokenの識別子比較と同じ考え方を、複数の非同期経路
/// (詳細取得・サムネイル生成)で共有できるよう一般化したもの。
@MainActor
final class SelectionGenerationTracker {
  private(set) var currentGeneration = 0

  /// 新しい世代を開始し、その世代番号を返す。呼び出し側はこの番号を非同期処理へ持ち回り、
  /// 結果を反映する直前にisCurrent(_:)で確認する。
  func advance() -> Int {
    currentGeneration &+= 1
    return currentGeneration
  }

  /// 渡した世代が依然として最新(advance以降に別の世代が発行されていない)かどうか。
  func isCurrent(_ generation: Int) -> Bool {
    generation == currentGeneration
  }
}
