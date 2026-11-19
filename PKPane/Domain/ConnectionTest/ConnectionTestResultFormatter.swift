import Foundation

/// 接続テストの応答時間表示を、NAS/SFTP両プロトコルで統一した形式にする純関数。
enum ConnectionTestResultFormatter {
  /// 「応答 12ms」の形式へ整形する。
  static func successMessage(elapsed: Duration) -> String {
    "応答 \(milliseconds(elapsed))ms"
  }

  /// 複数ホップは接続順に並べ、単一ホップは従来の表示にする。
  static func hopSuccessMessage(_ hops: [(name: String, elapsed: Duration)]) -> String {
    if let hop = hops.first, hops.count == 1 {
      return successMessage(elapsed: hop.elapsed)
    }
    return hops.map { "\($0.name) \(milliseconds($0.elapsed))ms" }.joined(separator: " → ")
  }

  /// Durationをミリ秒(四捨五入・0以上)へ変換する。
  static func milliseconds(_ duration: Duration) -> Int {
    let seconds = Double(duration.components.seconds)
    let attoseconds = Double(duration.components.attoseconds)
    let totalMilliseconds = seconds * 1_000 + attoseconds / 1_000_000_000_000_000
    return max(0, Int(totalMilliseconds.rounded()))
  }
}
