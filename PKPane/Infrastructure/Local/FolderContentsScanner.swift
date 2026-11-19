import Foundation

/// フォルダ配下を再帰走査し、内容の合計サイズと件数を計算する。ローカル/マウント済み
/// NASのlocalURLに対してのみ動作する(SFTP等リモートは呼び出し側で除外すること)。
enum FolderContentsScanner {
  struct Summary: Equatable, Sendable {
    var totalSize: Int64
    var itemCount: Int
  }

  /// キャンセル要求を安全に伝えるトークン。走査はバックグラウンドスレッドで進む一方、
  /// キャンセル指示はMainActor(UIのボタン操作)から届くため、ロックで保護する。
  final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
      lock.lock()
      cancelled = true
      lock.unlock()
    }

    var isCancelled: Bool {
      lock.lock()
      defer { lock.unlock() }
      return cancelled
    }
  }

  /// フォルダ配下(サブフォルダ含む)を再帰列挙し、ファイルの合計サイズと項目数
  /// (ファイル・フォルダ双方)を返す。同期・ブロッキング処理のため、呼び出し側は
  /// 必ずMainActor外(Task.detached等)から呼ぶこと。cancellationTokenがキャンセル
  /// 済みになった時点でCancellationErrorを投げ、走査を打ち切る。
  static func scan(at url: URL, cancellationToken: CancellationToken) throws -> Summary {
    if cancellationToken.isCancelled { throw CancellationError() }

    let fileManager = FileManager.default
    guard
      let enumerator = fileManager.enumerator(
        at: url,
        includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
        options: [])
    else {
      return Summary(totalSize: 0, itemCount: 0)
    }

    var totalSize: Int64 = 0
    var itemCount = 0
    for case let fileURL as URL in enumerator {
      if cancellationToken.isCancelled { throw CancellationError() }
      let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
      itemCount += 1
      if values?.isDirectory != true {
        totalSize += Int64(values?.fileSize ?? 0)
      }
    }
    return Summary(totalSize: totalSize, itemCount: itemCount)
  }
}
