import Foundation

enum SFTPChunkedTransfer {
  /// 読み出し(ダウンロード)用チャンクサイズ。CitadelのSFTPFile.readは内部分割を
  /// 行わないため、32,000ちょうどが1チャンク=1リクエスト往復のまま最適。
  static let defaultChunkSize = 32_000

  /// 書き込み(アップロード)用チャンクサイズ。CitadelのSFTPFile.writeは内部で常に
  /// 32,000バイト単位へ直列サブスライスするためワイヤ粒度はこの値に関係なく32,000の
  /// ままだが、PKPane側のパイプライン通過回数(BoundedChunkPipe/SFTPPipelinedWriterの
  /// Mutexロックやタスク生成などの1チャンク固定コスト)は256KBへ広げることで1/8に
  /// 減る。32,000のままだと固定コストが支配的になりチャンクレートが半減する
  /// (実測763/秒→375/秒)ため、256KBに再調整する。
  static let uploadChunkSize = 262_144

  static func copy(
    chunkSize: Int = defaultChunkSize,
    read: (UInt64, Int) async throws -> Data,
    write: (Data, UInt64) async throws -> Void
  ) async throws -> Int64 {
    precondition(chunkSize > 0)

    var offset: UInt64 = 0
    while true {
      try Task.checkCancellation()
      let chunk = try await read(offset, chunkSize)
      guard !chunk.isEmpty else { return Int64(offset) }
      try Task.checkCancellation()
      try await write(chunk, offset)
      offset += UInt64(chunk.count)
    }
  }
}
