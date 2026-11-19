import Foundation

/// inFlight計上の不変条件(inFlight>=1なら未回収の子タスクが必ず存在する)が破れたことを示す
/// 内部ロジックエラー。到達不能のはずだが、万一到達した場合に黙って成功扱いにしないための防御。
struct SFTPPipelineInvariantError: LocalizedError {
  var errorDescription: String? { "SFTP転送の内部状態が不整合です。" }
}

/// SFTP書き込みのスライディングウィンドウ。直列往復(チャンクサイズ÷RTTが上限)を、
/// 最大maxInFlight並行の先行発行で多重化する。opensshのnum_requests=64に相当する手法。
struct SFTPPipelinedWriter: Sendable {
  let maxInFlight: Int

  /// アップロードチャンクを256KB(SFTPChunkedTransfer.uploadChunkSize)へ広げたため、
  /// ワイヤ上の並行リクエスト数をM1実測(50MB/s時)相当の約24チェーンへ揃える。
  /// 48のままだと256KB×48≈12MB in-flightとなり必要以上に膨らむ。
  init(maxInFlight: Int = 24) {
    precondition(maxInFlight > 0)
    self.maxInFlight = maxInFlight
  }

  func write(
    chunks: AsyncThrowingStream<Data, Error>,
    performWrite: @escaping @Sendable (Data, UInt64) async throws -> Void,
    progress: @escaping @Sendable (Int64) -> Void
  ) async throws {
    // エラー時の挙動: group.next()がthrowするとwithThrowingTaskGroupが残タスクをキャンセルして
    // 脱出する。performWrite(実環境ではfile.write)はキャンセル非対応だが、上位のSFTPStallGuard
    // のonAbort(接続close)が残awaitを解放するため、stallGuard.runに包まれていれば回収される。
    try await withThrowingTaskGroup(of: Int.self) { group in
      var nextOffset: UInt64 = 0
      var inFlight = 0
      var confirmedBytes: Int64 = 0
      for try await chunk in chunks {
        if inFlight >= maxInFlight {
          // inFlight>=1のはずなのでnilは返らない。黙って成功扱いにしないための防御。
          guard let completed = try await group.next() else {
            assertionFailure("SFTPPipelinedWriter: inFlight計上の不変条件が破れた")
            throw SFTPPipelineInvariantError()
          }
          inFlight -= 1
          confirmedBytes += Int64(completed)
          progress(confirmedBytes)
        }
        let offset = nextOffset
        nextOffset += UInt64(chunk.count)
        group.addTask {
          try await performWrite(chunk, offset)
          return chunk.count
        }
        inFlight += 1
      }
      while let completed = try await group.next() {
        confirmedBytes += Int64(completed)
        progress(confirmedBytes)
      }
    }
  }
}

/// SFTP読み出しのスライディングウィンドウ。先読みした結果をオフセット順に組み立てて渡す。
struct SFTPPipelinedReader: Sendable {
  let maxInFlight: Int
  let chunkSize: Int

  /// ダウンロードは32,000バイト固定(SFTPChunkedTransfer.defaultChunkSize)のまま
  /// 変更していないため、in-flight量もopensshのnum_requests=64に近い48を維持する
  /// (32,000×48≈1.5MB)。アップロード側(SFTPPipelinedWriter)とは非対称。
  init(maxInFlight: Int = 48, chunkSize: Int) {
    precondition(maxInFlight > 0)
    precondition(chunkSize > 0)
    self.maxInFlight = maxInFlight
    self.chunkSize = chunkSize
  }

  // エラー時の挙動: group.next()がthrowするとwithThrowingTaskGroupが残タスクをキャンセルして脱出する。
  // performRead(実環境ではfile.read)はキャンセル非対応だが、上位のSFTPStallGuardのonAbort(接続close)
  // が残awaitを解放するため、stallGuard.runに包まれていれば回収される。
  func read(
    performRead: @escaping @Sendable (UInt64, Int) async throws -> Data,
    receive: @escaping @Sendable (Data) async throws -> Void
  ) async throws {
    // タスクの結果は(発行時オフセット, 要求バイト数, 実際に返ったデータ)。要求バイト数が要るのは、
    // 空でも要求量に満たない読みを検知して不足分の追加読みを発行するため(下記コメント参照)。
    try await withThrowingTaskGroup(of: (offset: UInt64, requestedLength: Int, data: Data).self) {
      group in
      var issuedOffset: UInt64 = 0
      var deliverOffset: UInt64 = 0
      var pending: [UInt64: Data] = [:]
      var inFlight = 0
      var reachedEnd = false

      func issue(offset: UInt64, length: Int) {
        group.addTask { (offset, length, try await performRead(offset, length)) }
        inFlight += 1
      }

      func issueNext() {
        let offset = issuedOffset
        issuedOffset += UInt64(chunkSize)
        issue(offset: offset, length: chunkSize)
      }

      while inFlight < maxInFlight, !reachedEnd {
        issueNext()
      }
      while inFlight > 0 {
        // inFlight>=1のはずなのでnilは返らない。黙って成功扱いにしないための防御。
        guard let (offset, requestedLength, data) = try await group.next() else {
          assertionFailure("SFTPPipelinedReader: inFlight計上の不変条件が破れた")
          throw SFTPPipelineInvariantError()
        }
        inFlight -= 1
        var issuedGap = false

        if data.isEmpty {
          // EOFは空読みでのみ判定する。SFTPサーバーはEOF以外でも要求量未満を返しうるため、
          // 「短い読み=EOF」とは仮定しない(下のelse ifで不足分を追加発行して補う)。
          reachedEnd = true
        } else if data.count < requestedLength {
          // EOFではない短い読み。届いた分は通常どおりpendingへ積み、残りは即座に追加発行する。
          // 追加読みのオフセットはoffset+data.countなのでdeliverOffsetの進み方(実長ベース)と
          // 自然に噛み合い、後続のpendingキーとずれない。
          pending[offset] = data
          issue(offset: offset + UInt64(data.count), length: requestedLength - data.count)
          issuedGap = true
        } else {
          pending[offset] = data
        }

        while let next = pending.removeValue(forKey: deliverOffset) {
          if !next.isEmpty {
            try await receive(next)
          }
          deliverOffset += UInt64(next.count)
        }
        // 短い読みで既にissue()済みの場合はここでissueNext()すると
        // reap(-1)に対してissue+issueNextで+1発行となりinFlightが際限なく
        // 増え続けてしまう。ギャップ読みを発行済みのイテレーションではスキップする。
        if !reachedEnd, !issuedGap {
          issueNext()
        }
      }
    }
  }
}

/// CitadelのSFTPFileを並行書き込みタスクへ渡すためのラッパー。
/// 安全性の根拠: SFTPFileの格納プロパティはhandle/path/clientすべてlet、
/// sendRequestはeventLoop.flatSubmitでイベントループ上に直列化され、
/// requestIdはNIOLockedValueBoxで採番されるため、並行write呼び出しは競合しない。
struct UncheckedSendableSFTPFileBox<Value>: @unchecked Sendable {
  let value: Value
  init(_ value: Value) { self.value = value }
}
